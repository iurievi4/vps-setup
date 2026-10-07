#!/usr/bin/env bash
# ==============================================================================
# VPS IP Guard — Модуль блокировки нежелательного трафика, сканеров и ботов
# https://github.com/iurievi4/vps-setup
# ==============================================================================
set -euo pipefail

CONF_DIR="/etc/vps-ip-guard"
CONF_FILE="${CONF_DIR}/ip-guard.conf"
MANUAL_LIST="${CONF_DIR}/manual.list"
CACHE_DIR="${CONF_DIR}/lists"

# Дефолтные параметры (переопределяются через $CONF_FILE)
ENABLE_IPV4=true
ENABLE_IPV6="auto"
SET_V4="VPS-IP-GUARD-V4"
SET_V6="VPS-IP-GUARD-V6"
CHAIN_NAME="VPS-IP-GUARD"
IPSET_HASHSIZE=16384
IPSET_MAXELEM=262144
RKN_GOV_URL="https://raw.githubusercontent.com/Flecksis/rkn-guard/main/lists/government_networks.list"
ANTISCANNER_URL="https://raw.githubusercontent.com/Flecksis/rkn-guard/main/lists/antiscanner.list"
SKIPA_URL="https://raw.githubusercontent.com/Flecksis/rkn-guard/main/lists/skipa.list"
CURL_CONNECT_TIMEOUT=15
CURL_MAX_TIME=60
MIN_REQUIRED_ENTRIES=100

# Загрузка пользовательского конфига
if [[ -f "$CONF_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONF_FILE"
fi

# Цвета для терминала
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"
C_BLUE="\033[1;34m"
C_CYAN="\033[1;36m"
C_RESET="\033[0m"

log_info()  { echo -e "${C_GREEN}[INFO]${C_RESET} $*"; }
log_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
log_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*"; }
log_step()  { echo -e "${C_BLUE}[*]${C_RESET} $*"; }

# ------------------------------------------------------------------------------
# Проверка зависимостей
# ------------------------------------------------------------------------------
check_dependencies() {
    local missing=()
    for bin in ipset iptables curl awk sed grep sort tr; do
        if ! command -v "$bin" &>/dev/null; then
            missing+=("$bin")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Отсутствуют обязательные утилиты: ${missing[*]}"
        log_info "Установите их: apt-get update && apt-get install -y ipset iptables curl"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Определение активности IPv6 в ядре и системе
# ------------------------------------------------------------------------------
is_ipv6_active() {
    if [[ "$ENABLE_IPV6" == "false" ]]; then
        return 1
    fi
    if [[ ! -f /proc/net/if_inet6 ]] || ! command -v ip6tables &>/dev/null; then
        return 1
    fi
    local disable_ipv6
    disable_ipv6=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "1")
    if [[ "$disable_ipv6" == "1" ]]; then
        return 1
    fi
    if ! ip6tables -L -n &>/dev/null; then
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Нормализация и валидация IPv4 / IPv6
# ------------------------------------------------------------------------------
normalize_v4() {
    grep -Ev '^(#|[[:space:]]*$)' | \
    sed 's/#.*//g; s/[[:space:]]//g' | \
    awk '
    function valid_octet(o) { return (o ~ /^[0-9]+$/ && o >= 0 && o <= 255); }
    function valid_prefix(p) { return (p ~ /^[0-9]+$/ && p >= 0 && p <= 32); }
    {
        split($0, parts, "/");
        ip = parts[1];
        prefix = parts[2];
        split(ip, octets, ".");
        if (length(octets) == 4 &&
            valid_octet(octets[1]) && valid_octet(octets[2]) &&
            valid_octet(octets[3]) && valid_octet(octets[4])) {
            if (prefix == "" || valid_prefix(prefix)) {
                print $0;
            }
        }
    }'
}

normalize_v6() {
    grep -Ev '^(#|[[:space:]]*$)' | \
    sed 's/#.*//g; s/[[:space:]]//g' | \
    grep -E '^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}(/([0-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8]))?$' || true
}

# ------------------------------------------------------------------------------
# Инициализация цепочек iptables и наборов ipset
# ------------------------------------------------------------------------------
init_firewall() {
    if [[ "$ENABLE_IPV4" == "true" ]]; then
        ipset create "$SET_V4" hash:net family inet hashsize "$IPSET_HASHSIZE" maxelem "$IPSET_MAXELEM" -exist
        iptables -N "$CHAIN_NAME" 2>/dev/null || true

        if ! iptables -C INPUT -j "$CHAIN_NAME" 2>/dev/null; then
            iptables -I INPUT 1 -j "$CHAIN_NAME"
        fi

        if ! iptables -C "$CHAIN_NAME" -m set --match-set "$SET_V4" src -j DROP 2>/dev/null; then
            iptables -A "$CHAIN_NAME" -m set --match-set "$SET_V4" src -j DROP
        fi
    fi

    if is_ipv6_active; then
        ipset create "$SET_V6" hash:net family inet6 hashsize "$IPSET_HASHSIZE" maxelem "$IPSET_MAXELEM" -exist
        ip6tables -N "$CHAIN_NAME" 2>/dev/null || true

        if ! ip6tables -C INPUT -j "$CHAIN_NAME" 2>/dev/null; then
            ip6tables -I INPUT 1 -j "$CHAIN_NAME"
        fi

        if ! ip6tables -C "$CHAIN_NAME" -m set --match-set "$SET_V6" src -j DROP 2>/dev/null; then
            ip6tables -A "$CHAIN_NAME" -m set --match-set "$SET_V6" src -j DROP
        fi
    fi
}

# ------------------------------------------------------------------------------
# Атомарное обновление списков
# ------------------------------------------------------------------------------
update_lists() {
    check_dependencies
    mkdir -p "$CACHE_DIR" "$CONF_DIR"
    local tmp_dir
    tmp_dir=$(mktemp -d /tmp/ip-guard-update.XXXXXX)
    trap 'rm -rf "$tmp_dir"' EXIT

    local raw_v4="${tmp_dir}/raw_v4.txt"
    local raw_v6="${tmp_dir}/raw_v6.txt"
    local restore_v4="${tmp_dir}/restore_v4.ipset"
    local restore_v6="${tmp_dir}/restore_v6.ipset"
    touch "$raw_v4" "$raw_v6"

    log_step "Скачивание списков из настроенных источников..."

    local urls=()
    [[ -n "${RKN_GOV_URL:-}" ]] && urls+=("$RKN_GOV_URL")
    [[ -n "${ANTISCANNER_URL:-}" ]] && urls+=("$ANTISCANNER_URL")
    [[ -n "${SKIPA_URL:-}" ]] && urls+=("$SKIPA_URL")

    local success_downloads=0
    for url in "${urls[@]}"; do
        local file="${tmp_dir}/download.tmp"
        if curl -sSL --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" "$url" -o "$file" 2>/dev/null; then
            normalize_v4 < "$file" >> "$raw_v4"
            if is_ipv6_active; then
                normalize_v6 < "$file" >> "$raw_v6"
            fi
            ((success_downloads++))
            log_info "✓ Загружено: $url"
        else
            log_warn "✗ Ошибка загрузки: $url (продолжаем с доступными источниками)"
        fi
    done

    # Добавляем manual.list
    if [[ -f "$MANUAL_LIST" ]]; then
        normalize_v4 < "$MANUAL_LIST" >> "$raw_v4"
        if is_ipv6_active; then
            normalize_v6 < "$MANUAL_LIST" >> "$raw_v6"
        fi
        log_info "✓ Добавлен локальный manual.list"
    fi

    sort -u "$raw_v4" -o "${raw_v4}.sorted"
    local count_v4
    count_v4=$(wc -l < "${raw_v4}.sorted")

    if [[ "$count_v4" -lt "$MIN_REQUIRED_ENTRIES" ]]; then
        log_error "Количество записей ($count_v4) меньше минимального порога ($MIN_REQUIRED_ENTRIES)."
        log_error "Атомарное обновление отменено во избежание сброса защиты. Работает текущий набор."
        return 1
    fi

    log_info "Подготовлено валидных IPv4 префиксов/адресов: $count_v4"

    local temp_set_v4="${SET_V4}-TMP"
    ipset create "$temp_set_v4" hash:net family inet hashsize "$IPSET_HASHSIZE" maxelem "$IPSET_MAXELEM" -exist
    ipset flush "$temp_set_v4"

    awk -v setname="$temp_set_v4" '{print "add " setname " " $1 " -exist"}' "${raw_v4}.sorted" > "$restore_v4"
    ipset restore < "$restore_v4"

    ipset create "$SET_V4" hash:net family inet hashsize "$IPSET_HASHSIZE" maxelem "$IPSET_MAXELEM" -exist
    ipset swap "$SET_V4" "$temp_set_v4"
    ipset destroy "$temp_set_v4"

    cp "${raw_v4}.sorted" "${CACHE_DIR}/active_v4.list"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - IPv4: $count_v4" > "${CACHE_DIR}/last_update.txt"
    log_info "✓ Набор $SET_V4 атомарно обновлён ($count_v4 записей)."

    if is_ipv6_active; then
        sort -u "$raw_v6" -o "${raw_v6}.sorted"
        local count_v6
        count_v6=$(wc -l < "${raw_v6}.sorted")
        if [[ "$count_v6" -gt 0 ]]; then
            local temp_set_v6="${SET_V6}-TMP"
            ipset create "$temp_set_v6" hash:net family inet6 hashsize "$IPSET_HASHSIZE" maxelem "$IPSET_MAXELEM" -exist
            ipset flush "$temp_set_v6"
            awk -v setname="$temp_set_v6" '{print "add " setname " " $1 " -exist"}' "${raw_v6}.sorted" > "$restore_v6"
            ipset restore < "$restore_v6"
            ipset create "$SET_V6" hash:net family inet6 hashsize "$IPSET_HASHSIZE" maxelem "$IPSET_MAXELEM" -exist
            ipset swap "$SET_V6" "$temp_set_v6"
            ipset destroy "$temp_set_v6"
            cp "${raw_v6}.sorted" "${CACHE_DIR}/active_v6.list"
            echo "$(date '+%Y-%m-%d %H:%M:%S') - IPv6: $count_v6" >> "${CACHE_DIR}/last_update.txt"
            log_info "✓ Набор $SET_V6 атомарно обновлён ($count_v6 записей)."
        fi
    fi

    init_firewall
    return 0
}

# ------------------------------------------------------------------------------
# Быстрая загрузка из локального кэша
# ------------------------------------------------------------------------------
reload_from_cache() {
    check_dependencies
    init_firewall
    if [[ -f "${CACHE_DIR}/active_v4.list" ]]; then
        log_info "Восстановление IPv4 списка из локального кэша..."
        ipset flush "$SET_V4" 2>/dev/null || true
        awk -v setname="$SET_V4" '{print "add " setname " " $1 " -exist"}' "${CACHE_DIR}/active_v4.list" | ipset restore
        log_info "Список IPv4 успешно восстановлен."
    else
        log_warn "Локальный кэш отсутствует, выполняем первичное обновление списков..."
        update_lists
    fi

    if is_ipv6_active && [[ -f "${CACHE_DIR}/active_v6.list" ]]; then
        ipset flush "$SET_V6" 2>/dev/null || true
        awk -v setname="$SET_V6" '{print "add " setname " " $1 " -exist"}' "${CACHE_DIR}/active_v6.list" | ipset restore
    fi
}

# ------------------------------------------------------------------------------
# Безопасная миграция с legacy AntiScanner
# ------------------------------------------------------------------------------
migrate_legacy_antiscanner() {
    log_step "Проверка наличия существующего AntiScanner..."
    local legacy_detected=false

    if ipset list -n 2>/dev/null | grep -qw "SCANNERS-BLOCK-V4"; then
        log_info "Обнаружен активный набор: SCANNERS-BLOCK-V4"
        legacy_detected=true
    fi

    if systemctl list-unit-files 2>/dev/null | grep -qw "antiscan.service" || [[ -f /usr/local/sbin/antiscan-update.sh ]]; then
        log_info "Обнаружены компоненты legacy AntiScanner (service/timer/script)"
        legacy_detected=true
    fi

    if [[ "$legacy_detected" != "true" ]]; then
        log_info "Старый AntiScanner не обнаружен. Выполняется штатная установка."
        return 0
    fi

    echo -e "${C_CYAN}======================================================${C_RESET}"
    echo -e "${C_CYAN}       Запуск безопасной миграции на VPS IP Guard     ${C_RESET}"
    echo -e "${C_CYAN}======================================================${C_RESET}"

    local legacy_dump="/tmp/legacy_antiscan_export.txt"
    rm -f "$legacy_dump"
    if ipset list -n 2>/dev/null | grep -qw "SCANNERS-BLOCK-V4"; then
        ipset list SCANNERS-BLOCK-V4 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}' > "$legacy_dump" || true
        local exp_count
        exp_count=$(wc -l < "$legacy_dump" 2>/dev/null || echo 0)
        log_info "Сохранено $exp_count записей из старого SCANNERS-BLOCK-V4 во временный буфер."
    fi

    init_firewall
    if ! update_lists; then
        log_warn "Обновление из внешних источников завершилось с предупреждением. Загружаем сохранённые данные..."
        if [[ -s "$legacy_dump" ]]; then
            while read -r entry; do
                ipset add "$SET_V4" "$entry" -exist 2>/dev/null || true
            done < "$legacy_dump"
        fi
    fi

    if [[ -s "$legacy_dump" ]]; then
        while read -r entry; do
            ipset add "$SET_V4" "$entry" -exist 2>/dev/null || true
        done < "$legacy_dump"
        rm -f "$legacy_dump"
    fi

    log_info "Отключение служб и таймеров старого AntiScanner..."
    systemctl stop antiscan.timer 2>/dev/null || true
    systemctl disable antiscan.timer 2>/dev/null || true
    systemctl stop antiscan.service 2>/dev/null || true
    systemctl disable antiscan.service 2>/dev/null || true

    iptables -D INPUT -j SCANNERS-BLOCK 2>/dev/null || true
    iptables -F SCANNERS-BLOCK 2>/dev/null || true
    iptables -X SCANNERS-BLOCK 2>/dev/null || true
    ipset destroy SCANNERS-BLOCK-V4 2>/dev/null || true

    log_info "✓ Миграция завершена! Старый AntiScanner деактивирован, $CHAIN_NAME защищает систему."
}

# ------------------------------------------------------------------------------
# Ручной чёрный список (ban / unban)
# ------------------------------------------------------------------------------
ban_ip() {
    local raw_target="${1:-}"
    local target
    target=$(echo "$raw_target" | tr -d '[:space:]')
    if [[ -z "$target" ]]; then
        log_error "Использование: ip-guard ban <IP|CIDR>"
        return 1
    fi

    mkdir -p "$CONF_DIR"
    touch "$MANUAL_LIST"

    if echo "$target" | normalize_v4 | grep -q .; then
        if ! grep -qxF "$target" "$MANUAL_LIST"; then
            echo "$target" >> "$MANUAL_LIST"
            sort -u "$MANUAL_LIST" -o "$MANUAL_LIST"
        fi
        init_firewall
        ipset add "$SET_V4" "$target" -exist 2>/dev/null || true
        log_info "✓ Адрес/подсеть $target заблокирован(а) в $SET_V4 и добавлен(а) в $MANUAL_LIST"
    elif echo "$target" | normalize_v6 | grep -q .; then
        if is_ipv6_active; then
            if ! grep -qxF "$target" "$MANUAL_LIST"; then
                echo "$target" >> "$MANUAL_LIST"
                sort -u "$MANUAL_LIST" -o "$MANUAL_LIST"
            fi
            init_firewall
            ipset add "$SET_V6" "$target" -exist 2>/dev/null || true
            log_info "✓ IPv6 $target заблокирован в $SET_V6 и добавлен в $MANUAL_LIST"
        else
            log_error "IPv6 не активен на сервере."
            return 1
        fi
    else
        log_error "Некорректный IP или CIDR: $target"
        return 1
    fi
}

unban_ip() {
    local raw_target="${1:-}"
    local target
    target=$(echo "$raw_target" | tr -d '[:space:]')
    if [[ -z "$target" ]]; then
        log_error "Использование: ip-guard unban <IP|CIDR>"
        return 1
    fi

    if [[ -f "$MANUAL_LIST" ]]; then
        grep -vFx "$target" "$MANUAL_LIST" > "${MANUAL_LIST}.tmp" || true
        mv "${MANUAL_LIST}.tmp" "$MANUAL_LIST"
    fi

    ipset del "$SET_V4" "$target" 2>/dev/null || true
    if is_ipv6_active; then
        ipset del "$SET_V6" "$target" 2>/dev/null || true
    fi
    log_info "✓ Адрес $target разблокирован и удалён из $MANUAL_LIST."
}

# ------------------------------------------------------------------------------
# Статус и статистика
# ------------------------------------------------------------------------------
show_status() {
    echo -e "${C_CYAN}======================================================${C_RESET}"
    echo -e "${C_CYAN}           VPS IP Guard — Текущий статус              ${C_RESET}"
    echo -e "${C_CYAN}======================================================${C_RESET}"

    if ipset list -n 2>/dev/null | grep -qw "$SET_V4"; then
        local count_v4
        count_v4=$(ipset list "$SET_V4" 2>/dev/null | grep -c '^[0-9]' || echo 0)
        echo -e "IPv4 Набор (${C_BLUE}$SET_V4${C_RESET}):   ${C_GREEN}Активен${C_RESET} (${count_v4} записей)"
    else
        echo -e "IPv4 Набор (${C_BLUE}$SET_V4${C_RESET}):   ${C_RED}Не создан${C_RESET}"
    fi

    if is_ipv6_active; then
        if ipset list -n 2>/dev/null | grep -qw "$SET_V6"; then
            local count_v6
            count_v6=$(ipset list "$SET_V6" 2>/dev/null | grep -c '^[0-9a-fA-F]' || echo 0)
            echo -e "IPv6 Набор (${C_BLUE}$SET_V6${C_RESET}):   ${C_GREEN}Активен${C_RESET} (${count_v6} записей)"
        else
            echo -e "IPv6 Набор (${C_BLUE}$SET_V6${C_RESET}):   ${C_YELLOW}Не создан${C_RESET}"
        fi
    else
        echo -e "IPv6 Поддержка:          ${C_YELLOW}Отключена в системе (IPv4-only режим)${C_RESET}"
    fi

    if [[ -f "$MANUAL_LIST" ]]; then
        local m_count
        m_count=$(wc -l < "$MANUAL_LIST")
        echo -e "Manual Blacklist:        ${C_GREEN}${m_count} записей${C_RESET} ($MANUAL_LIST)"
    fi

    if [[ -f "${CACHE_DIR}/last_update.txt" ]]; then
        echo -e "Последнее обновление:    $(cat "${CACHE_DIR}/last_update.txt")"
    fi

    echo ""
    echo -e "${C_BLUE}--- Статистика заблокированных пакетов (iptables) ---${C_RESET}"
    if iptables -L "$CHAIN_NAME" -v -n 2>/dev/null; then
        :
    else
        echo "Цепочка iptables $CHAIN_NAME отсутствует"
    fi

    if is_ipv6_active; then
        echo -e "\n${C_BLUE}--- Статистика IPv6 (ip6tables) ---${C_RESET}"
        ip6tables -L "$CHAIN_NAME" -v -n 2>/dev/null || true
    fi

    echo ""
    echo -e "${C_BLUE}--- Таймер автоматического обновления ---${C_RESET}"
    if systemctl is-active vps-ip-guard-update.timer &>/dev/null; then
        echo -e "vps-ip-guard-update.timer: ${C_GREEN}Активен${C_RESET}"
        systemctl list-timers vps-ip-guard-update.timer --no-pager 2>/dev/null || true
    else
        echo -e "vps-ip-guard-update.timer: ${C_YELLOW}Не запущен или отсутствует${C_RESET}"
    fi
}

# ------------------------------------------------------------------------------
# Установка Systemd юнитов
# ------------------------------------------------------------------------------
install_systemd() {
    log_step "Установка systemd юнитов для автозагрузки и обновления..."

    cat <<EOF > /etc/systemd/system/vps-ip-guard.service
[Unit]
Description=VPS IP Guard Firewall Rule Loader
After=network-pre.target ufw.service
Before=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/ip-guard reload
ExecStop=/usr/local/sbin/ip-guard stop

[Install]
WantedBy=multi-user.target
EOF

    cat <<EOF > /etc/systemd/system/vps-ip-guard-update.service
[Unit]
Description=VPS IP Guard List Updater
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ip-guard update
EOF

    cat <<EOF > /etc/systemd/system/vps-ip-guard-update.timer
[Unit]
Description=Run VPS IP Guard update twice daily

[Timer]
OnCalendar=*-*-* 04,16:00:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable vps-ip-guard.service
    systemctl enable --now vps-ip-guard-update.timer
    log_info "✓ Systemd сервис и таймер автообновления активны."
}

# ------------------------------------------------------------------------------
# Остановка и очистка правил
# ------------------------------------------------------------------------------
stop_guard() {
    log_info "Остановка VPS IP Guard (снятие блокировок)..."
    iptables -D INPUT -j "$CHAIN_NAME" 2>/dev/null || true
    iptables -F "$CHAIN_NAME" 2>/dev/null || true
    iptables -X "$CHAIN_NAME" 2>/dev/null || true
    if is_ipv6_active; then
        ip6tables -D INPUT -j "$CHAIN_NAME" 2>/dev/null || true
        ip6tables -F "$CHAIN_NAME" 2>/dev/null || true
        ip6tables -X "$CHAIN_NAME" 2>/dev/null || true
    fi
    log_info "Правила iptables для $CHAIN_NAME удалены."
}

# ------------------------------------------------------------------------------
# Точка входа CLI (только при прямом вызове)
# ------------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        install)
            check_dependencies
            mkdir -p "$CONF_DIR" "$CACHE_DIR"
            [[ ! -f "$MANUAL_LIST" ]] && touch "$MANUAL_LIST"
            migrate_legacy_antiscanner
            install_systemd
            log_info "Установка VPS IP Guard завершена успешно."
            ;;
        update)
            update_lists
            ;;
        reload)
            reload_from_cache
            ;;
        stop)
            stop_guard
            ;;
        ban)
            ban_ip "${2:-}"
            ;;
        unban)
            unban_ip "${2:-}"
            ;;
        status|stats)
            show_status
            ;;
        *)
            echo "VPS IP Guard"
            echo "Использование: ip-guard <команда>"
            echo ""
            echo "Команды:"
            echo "  install        - Полная установка, миграция со старого AntiScanner, регистрация systemd"
            echo "  update         - Атомарная загрузка и обновление списков из сети"
            echo "  reload         - Быстрая загрузка списков из локального кэша"
            echo "  status         - Просмотр состояния сетов, счетчиков заблокированных пакетов"
            echo "  ban <IP/CIDR>  - Добавить IP или подсеть в ручной чёрный список"
            echo "  unban <IP/CIDR>- Удалить IP или подсеть из чёрного списка"
            echo "  stop           - Временно отключить цепочки фильтрации в iptables"
            exit 1
            ;;
    esac
fi

return 0 2>/dev/null || true
