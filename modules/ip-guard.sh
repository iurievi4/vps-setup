#!/usr/bin/env bash
# ==============================================================================
# VPS IP Guard — Модуль блокировки нежелательного трафика, сканеров и ботов
# https://github.com/iurievi4/vps-setup
# ==============================================================================
set -Eeuo pipefail

CONF_DIR="/etc/vps-ip-guard"
CONF_FILE="${CONF_DIR}/ip-guard.conf"
MANUAL_LIST="${CONF_DIR}/manual.list"
CACHE_DIR="${CONF_DIR}/lists"
STATS_FILE="${CACHE_DIR}/stats.env"

# Глобальная переменная для временных каталогов (защита от unbound variable в trap)
IP_GUARD_TMP_DIR=""

cleanup_tmp() {
    if [[ -n "${IP_GUARD_TMP_DIR:-}" && -d "$IP_GUARD_TMP_DIR" ]]; then
        rm -rf -- "$IP_GUARD_TMP_DIR"
    fi
}
trap cleanup_tmp EXIT

# 1. Загрузка конфигурационного файла (если существует)
if [[ -f "$CONF_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONF_FILE"
fi

# 2. Значения по умолчанию (используются, только если не переопределены в $CONF_FILE)
: "${ENABLE_IPV4:=true}"
: "${ENABLE_IPV6:=auto}"
: "${SET_V4:=VPS-IP-GUARD-V4}"
: "${SET_V6:=VPS-IP-GUARD-V6}"
: "${CHAIN_NAME:=VPS-IP-GUARD}"
: "${IPSET_HASHSIZE:=16384}"
: "${IPSET_MAXELEM:=262144}"

# Эталонные источники списков (shadow-netlab/traffic-guard-lists)
: "${RKN_GOV_URL:=https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/government_networks.list}"
: "${ANTISCANNER_URL:=https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list}"
: "${SKIPA_URL:=https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/skipa.list}"

: "${CURL_CONNECT_TIMEOUT:=10}"
: "${CURL_MAX_TIME:=60}"
: "${MIN_REQUIRED_ENTRIES:=50}"

# Цвета для вывода в консоль
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"
C_BLUE="\033[1;34m"
C_CYAN="\033[1;36m"
C_RESET="\033[0m"

log_info()  { echo -e "${C_BLUE}[INFO]${C_RESET} $*"; }
log_ok()    { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
log_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
log_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*"; }
log_step()  { echo -e "${C_CYAN}[*]${C_RESET} $*"; }

# ------------------------------------------------------------------------------
# Проверка необходимых системных утилит
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
    return 0
}

# ------------------------------------------------------------------------------
# Проверка поддержки IPv6 ядром и системой
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
# Нормализация и валидация адресов (IPv4 / IPv6)
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
    return 0
}

# ------------------------------------------------------------------------------
# Скачивание и валидация отдельного источника
# ------------------------------------------------------------------------------
fetch_and_validate_source() {
    local source_name="$1"
    local source_url="$2"
    local out_v4="$3"
    local out_v6="$4"
    local count_var_name="$5"

    local raw_file="${IP_GUARD_TMP_DIR}/${source_name}.raw"
    local norm_v4_file="${IP_GUARD_TMP_DIR}/${source_name}.v4"
    local norm_v6_file="${IP_GUARD_TMP_DIR}/${source_name}.v6"

    if ! curl -fsSL --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" "$source_url" -o "$raw_file" 2>/dev/null; then
        log_error "${source_name} : сбой загрузки по HTTP (${source_url})"
        return 1
    fi

    if [[ ! -s "$raw_file" ]]; then
        log_error "${source_name} : получен пустой файл"
        return 1
    fi

    normalize_v4 < "$raw_file" > "$norm_v4_file"
    local v4_count
    v4_count=$(wc -l < "$norm_v4_file")

    if [[ "$v4_count" -eq 0 ]]; then
        log_error "${source_name} : не найдено ни одного валидного IPv4 префикса"
        return 1
    fi

    cat "$norm_v4_file" >> "$out_v4"

    if is_ipv6_active; then
        normalize_v6 < "$raw_file" > "$norm_v6_file"
        cat "$norm_v6_file" >> "$out_v6"
    fi

    printf -v "$count_var_name" "%d" "$v4_count"
    printf "  ${C_GREEN}[OK]${C_RESET} %-25s : %d IPv4\n" "$source_name" "$v4_count"
    return 0
}

# ------------------------------------------------------------------------------
# Атомарное обновление списков
# ------------------------------------------------------------------------------
update_lists() {
    local extra_legacy_dump="${1:-}"

    check_dependencies
    mkdir -p "$CACHE_DIR" "$CONF_DIR"

    IP_GUARD_TMP_DIR="$(mktemp -d /tmp/ip-guard-update.XXXXXX)"

    local raw_v4="${IP_GUARD_TMP_DIR}/all_v4.txt"
    local raw_v6="${IP_GUARD_TMP_DIR}/all_v6.txt"
    local restore_v4="${IP_GUARD_TMP_DIR}/restore_v4.ipset"
    local restore_v6="${IP_GUARD_TMP_DIR}/restore_v6.ipset"
    touch "$raw_v4" "$raw_v6"

    log_info "Загрузка внешних списков..."

    local failed_sources=0
    local count_gov=0
    local count_antiscan=0
    local count_skipa=0

    # 1. Government networks list
    if [[ -n "${RKN_GOV_URL:-}" ]]; then
        if ! fetch_and_validate_source "government_networks.list" "$RKN_GOV_URL" "$raw_v4" "$raw_v6" count_gov; then
            failed_sources=$((failed_sources + 1))
        fi
    fi

    # 2. Antiscanner list
    if [[ -n "${ANTISCANNER_URL:-}" ]]; then
        if ! fetch_and_validate_source "antiscanner.list" "$ANTISCANNER_URL" "$raw_v4" "$raw_v6" count_antiscan; then
            failed_sources=$((failed_sources + 1))
        fi
    fi

    # 3. Skipa list
    if [[ -n "${SKIPA_URL:-}" ]]; then
        if ! fetch_and_validate_source "skipa.list" "$SKIPA_URL" "$raw_v4" "$raw_v6" count_skipa; then
            failed_sources=$((failed_sources + 1))
        fi
    fi

    if [[ "$failed_sources" -gt 0 ]]; then
        log_warn "Проверка источников завершилась с ошибками (${failed_sources} недоступно)."
        cleanup_tmp
        return 1
    fi

    # 4. Подключение ручного чёрного списка (Manual Blacklist)
    local count_manual=0
    if [[ -f "$MANUAL_LIST" && -s "$MANUAL_LIST" ]]; then
        normalize_v4 < "$MANUAL_LIST" >> "$raw_v4"
        if is_ipv6_active; then
            normalize_v6 < "$MANUAL_LIST" >> "$raw_v6"
        fi
        count_manual=$(normalize_v4 < "$MANUAL_LIST" | wc -l)
    fi
    printf "  ${C_GREEN}[OK]${C_RESET} %-25s : %d entries\n" "Manual blacklist" "$count_manual"

    # 5. Если переданы сохраненные записи из legacy AntiScanner
    local count_legacy=0
    if [[ -n "$extra_legacy_dump" && -f "$extra_legacy_dump" ]]; then
        normalize_v4 < "$extra_legacy_dump" >> "$raw_v4"
        count_legacy=$(normalize_v4 < "$extra_legacy_dump" | wc -l)
        printf "  ${C_GREEN}[OK]${C_RESET} %-25s : %d entries\n" "Legacy AntiScanner set" "$count_legacy"
    fi

    local total_raw
    total_raw=$((count_gov + count_antiscan + count_skipa + count_manual + count_legacy))

    # 6. Дедупликация и подсчет уникальных сетей
    log_info "Формирование объединённого списка..."
    sort -u "$raw_v4" -o "${raw_v4}.sorted"
    local total_v4
    total_v4=$(wc -l < "${raw_v4}.sorted")
    local dupes_collapsed
    dupes_collapsed=$((total_raw - total_v4))

    printf "  ${C_GREEN}[OK]${C_RESET} %-25s : %d networks\n" "Unique IPv4 networks" "$total_v4"

    # Проверка общего порога
    if [[ "$total_v4" -lt "$MIN_REQUIRED_ENTRIES" ]]; then
        log_error "Общий объём записей ($total_v4) меньше минимального порога ($MIN_REQUIRED_ENTRIES)."
        cleanup_tmp
        return 1
    fi

    # 7. Атомарное создание и swap временного ipset
    log_info "Создание временного ipset..."
    local temp_set_v4="${SET_V4}-TMP"
    ipset create "$temp_set_v4" hash:net family inet hashsize "$IPSET_HASHSIZE" maxelem "$IPSET_MAXELEM" -exist
    ipset flush "$temp_set_v4"

    awk -v setname="$temp_set_v4" '{print "add " setname " " $1 " -exist"}' "${raw_v4}.sorted" > "$restore_v4"
    if ! ipset restore < "$restore_v4"; then
        log_error "Ошибка наполнения временного набора ipset!"
        ipset destroy "$temp_set_v4" 2>/dev/null || true
        cleanup_tmp
        return 1
    fi
    log_ok "Validation passed"

    # Swap
    log_info "Atomic swap..."
    ipset create "$SET_V4" hash:net family inet hashsize "$IPSET_HASHSIZE" maxelem "$IPSET_MAXELEM" -exist
    ipset swap "$SET_V4" "$temp_set_v4"
    ipset destroy "$temp_set_v4" 2>/dev/null || true
    log_ok "${SET_V4} active"

    # Сохраняем в локальный кэш
    cp "${raw_v4}.sorted" "${CACHE_DIR}/active_v4.list"

    # Сохраняем детальную статистику
    local update_time
    update_time="$(date '+%Y-%m-%d %H:%M:%S')"
    cat <<EOF > "$STATS_FILE"
UPDATE_TIMESTAMP="${update_time}"
COUNT_GOV=${count_gov}
COUNT_ANTISCAN=${count_antiscan}
COUNT_SKIPA=${count_skipa}
COUNT_MANUAL=${count_manual}
COUNT_LEGACY=${count_legacy}
COUNT_TOTAL_RAW=${total_raw}
COUNT_DUPES=${dupes_collapsed}
COUNT_UNIQUE=${total_v4}
EOF
    echo "${update_time} - IPv4: ${total_v4} (из ${total_raw} сырых записей, схлопнуто дублей: ${dupes_collapsed})" > "${CACHE_DIR}/last_update.txt"

    # 8. Обработка IPv6 (если активен)
    if is_ipv6_active; then
        sort -u "$raw_v6" -o "${raw_v6}.sorted"
        local total_v6
        total_v6=$(wc -l < "${raw_v6}.sorted")
        if [[ "$total_v6" -gt 0 ]]; then
            local temp_set_v6="${SET_V6}-TMP"
            ipset create "$temp_set_v6" hash:net family inet6 hashsize "$IPSET_HASHSIZE" maxelem "$IPSET_MAXELEM" -exist
            ipset flush "$temp_set_v6"
            awk -v setname="$temp_set_v6" '{print "add " setname " " $1 " -exist"}' "${raw_v6}.sorted" > "$restore_v6"
            ipset restore < "$restore_v6" 2>/dev/null || true
            ipset create "$SET_V6" hash:net family inet6 hashsize "$IPSET_HASHSIZE" maxelem "$IPSET_MAXELEM" -exist
            ipset swap "$SET_V6" "$temp_set_v6"
            ipset destroy "$temp_set_v6" 2>/dev/null || true
            cp "${raw_v6}.sorted" "${CACHE_DIR}/active_v6.list"
        fi
    fi

    init_firewall
    log_ok "Firewall rule active"

    cleanup_tmp
    return 0
}

# ------------------------------------------------------------------------------
# Проверка жизнеспособности (Health check)
# ------------------------------------------------------------------------------
health_check() {
    log_info "Health check..."
    if ! ipset list -n 2>/dev/null | grep -qw "$SET_V4"; then
        log_error "Health check failed: набор $SET_V4 отсутствует!"
        return 1
    fi

    local count
    count=$(ipset list "$SET_V4" 2>/dev/null | grep -c '^[0-9]' || echo 0)
    if [[ "$count" -lt "$MIN_REQUIRED_ENTRIES" ]]; then
        log_error "Health check failed: количество записей ($count) меньше порога!"
        return 1
    fi

    if ! iptables -L "$CHAIN_NAME" -n &>/dev/null; then
        log_error "Health check failed: цепочка iptables $CHAIN_NAME отсутствует!"
        return 1
    fi

    if ! iptables -C INPUT -j "$CHAIN_NAME" 2>/dev/null; then
        log_error "Health check failed: переход в $CHAIN_NAME отсутствует в цепочке INPUT!"
        return 1
    fi

    log_ok "IP Guard is operational"
    return 0
}

# ------------------------------------------------------------------------------
# Безопасная миграция с legacy AntiScanner
# ------------------------------------------------------------------------------
migrate_legacy_antiscanner() {
    echo -e "\n${C_CYAN}======================================================${C_RESET}"
    echo -e "${C_CYAN}               Миграция VPS IP Guard                  ${C_RESET}"
    echo -e "${C_CYAN}======================================================${C_RESET}\n"

    local legacy_detected=false
    local legacy_count=0
    local legacy_dump="/tmp/legacy_antiscan_export.txt"
    rm -f "$legacy_dump"

    if ipset list -n 2>/dev/null | grep -qw "SCANNERS-BLOCK-V4"; then
        legacy_detected=true
        ipset list SCANNERS-BLOCK-V4 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}' > "$legacy_dump" || true
        legacy_count=$(wc -l < "$legacy_dump" 2>/dev/null || echo 0)
        log_info "Legacy AntiScanner обнаружен"
        log_info "Старый набор: ${legacy_count} networks"
    elif systemctl list-unit-files 2>/dev/null | grep -qw "antiscan.service" || [[ -f /usr/local/sbin/antiscan-update.sh ]]; then
        legacy_detected=true
        log_info "Legacy AntiScanner обнаружен (сервис/скрипт)"
    fi

    # Шаг 1: Загрузка и сборка списков
    if ! update_lists "$legacy_dump"; then
        echo ""
        log_warn "External lists validation failed."
        log_warn "Atomic update cancelled."
        if [[ "$legacy_detected" == "true" ]]; then
            log_info "Existing legacy AntiScanner remains ENABLED."
        fi
        log_error "Migration NOT completed."
        rm -f "$legacy_dump"
        return 1
    fi

    # Шаг 2: Проверка здоровья новой защиты
    if ! health_check; then
        echo ""
        log_error "Health check failed. Новая защита не подтверждена!"
        if [[ "$legacy_detected" == "true" ]]; then
            log_info "Legacy AntiScanner remains ENABLED."
        fi
        log_error "Migration NOT completed."
        rm -f "$legacy_dump"
        return 1
    fi

    # Шаг 3: Отключение legacy AntiScanner ТОЛЬКО при 100% успехе
    if [[ "$legacy_detected" == "true" ]]; then
        log_info "Отключение legacy AntiScanner..."
        systemctl stop antiscan.timer 2>/dev/null || true
        systemctl disable antiscan.timer 2>/dev/null || true
        systemctl stop antiscan.service 2>/dev/null || true
        systemctl disable antiscan.service 2>/dev/null || true

        iptables -D INPUT -j SCANNERS-BLOCK 2>/dev/null || true
        iptables -F SCANNERS-BLOCK 2>/dev/null || true
        iptables -X SCANNERS-BLOCK 2>/dev/null || true
        ipset destroy SCANNERS-BLOCK-V4 2>/dev/null || true

        log_ok "Legacy AntiScanner disabled"
    fi

    rm -f "$legacy_dump"

    echo -e "\n${C_CYAN}======================================================${C_RESET}"
    echo -e "${C_CYAN}                 MIGRATION COMPLETED                  ${C_RESET}"
    echo -e "${C_CYAN}======================================================${C_RESET}\n"
    return 0
}

# ------------------------------------------------------------------------------
# Быстрая загрузка из локального кэша
# ------------------------------------------------------------------------------
reload_from_cache() {
    check_dependencies
    init_firewall

    if [[ -f "${CACHE_DIR}/active_v4.list" && -s "${CACHE_DIR}/active_v4.list" ]]; then
        log_info "Восстановление списка IPv4 из локального кэша..."
        ipset flush "$SET_V4" 2>/dev/null || true
        awk -v setname="$SET_V4" '{print "add " setname " " $1 " -exist"}' "${CACHE_DIR}/active_v4.list" | ipset restore
        log_ok "Список IPv4 восстановлен из кэша."
    else
        log_warn "Локальный кэш отсутствует, выполняем первичное обновление..."
        update_lists
    fi

    if is_ipv6_active && [[ -f "${CACHE_DIR}/active_v6.list" && -s "${CACHE_DIR}/active_v6.list" ]]; then
        ipset flush "$SET_V6" 2>/dev/null || true
        awk -v setname="$SET_V6" '{print "add " setname " " $1 " -exist"}' "${CACHE_DIR}/active_v6.list" | ipset restore
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Ручной чёрный список (ban / unban / list)
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
        log_ok "Адрес/подсеть $target заблокирован(а) в $SET_V4 и сохранён(а) в $MANUAL_LIST"
    elif echo "$target" | normalize_v6 | grep -q .; then
        if is_ipv6_active; then
            if ! grep -qxF "$target" "$MANUAL_LIST"; then
                echo "$target" >> "$MANUAL_LIST"
                sort -u "$MANUAL_LIST" -o "$MANUAL_LIST"
            fi
            init_firewall
            ipset add "$SET_V6" "$target" -exist 2>/dev/null || true
            log_ok "IPv6 $target заблокирован в $SET_V6 и сохранён в $MANUAL_LIST"
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
    log_ok "Адрес $target разблокирован и удалён из $MANUAL_LIST."
}

show_manual_list() {
    echo -e "${C_CYAN}==============================================================${C_RESET}"
    echo -e "${C_CYAN}             РУЧНОЙ ЧЁРНЫЙ СПИСОК                             ${C_RESET}"
    echo -e "${C_CYAN}==============================================================${C_RESET}"
    echo "Файл: ${MANUAL_LIST}"
    local count=0
    if [[ -f "$MANUAL_LIST" && -s "$MANUAL_LIST" ]]; then
        count=$(wc -l < "$MANUAL_LIST")
        echo -e "Записей: ${C_GREEN}${count}${C_RESET}\n"
        cat -n "$MANUAL_LIST"
    else
        echo -e "Записей: 0\n"
        echo "Ручной чёрный список пуст."
    fi
    echo ""
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

    local m_count=0
    if [[ -f "$MANUAL_LIST" ]]; then
        m_count=$(wc -l < "$MANUAL_LIST")
    fi
    echo -e "Manual Blacklist:        ${C_GREEN}${m_count} записей${C_RESET} ($MANUAL_LIST)"

    # Подробная раскладка по источникам и дедупликации
    if [[ -f "$STATS_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$STATS_FILE"
        echo ""
        echo -e "${C_BLUE}--- Источники и дедупликация (Обновлено: ${UPDATE_TIMESTAMP:-Н/Д}) ---${C_RESET}"
        printf "  • %-26s : %5d\n" "Government networks" "${COUNT_GOV:-0}"
        printf "  • %-26s : %5d\n" "AntiScanner list" "${COUNT_ANTISCAN:-0}"
        printf "  • %-26s : %5d\n" "SkipA list" "${COUNT_SKIPA:-0}"
        if [[ "${COUNT_LEGACY:-0}" -gt 0 ]]; then
            printf "  • %-26s : %5d\n" "Legacy AntiScanner" "${COUNT_LEGACY}"
        fi
        printf "  • %-26s : %5d\n" "Manual blacklist" "${COUNT_MANUAL:-0}"
        echo "  ────────────────────────────────────────────"
        printf "  %-28s : %5d\n" "Всего получено записей" "${COUNT_TOTAL_RAW:-0}"
        printf "  %-28s : %5d\n" "Дубликатов схлопнуто" "${COUNT_DUPES:-0}"
        printf "  ${C_GREEN}%-28s : %5d${C_RESET}\n" "Уникальных в ipset" "${COUNT_UNIQUE:-0}"
    elif [[ -f "${CACHE_DIR}/last_update.txt" ]]; then
        echo -e "\nПоследнее обновление: $(cat "${CACHE_DIR}/last_update.txt")"
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
    log_info "Установка systemd юнитов для автозагрузки и обновления..."

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
    log_ok "Systemd сервис и таймер автообновления активны."
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
    log_ok "Правила iptables для $CHAIN_NAME удалены."
}

# ------------------------------------------------------------------------------
# Точка входа CLI
# ------------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        install)
            check_dependencies
            mkdir -p "$CONF_DIR" "$CACHE_DIR"
            [[ ! -f "$MANUAL_LIST" ]] && touch "$MANUAL_LIST"
            if migrate_legacy_antiscanner; then
                install_systemd
                log_ok "Установка VPS IP Guard завершена успешно."
            else
                log_error "Установка не завершена из-за ошибок миграции."
                exit 1
            fi
            ;;
        update)
            update_lists
            ;;
        reload)
            reload_from_cache
            ;;
        reinit)
            init_firewall
            log_ok "Правила фаервола $CHAIN_NAME переинициализированы."
            ;;
        check-firewall)
            if iptables -C INPUT -j "$CHAIN_NAME" 2>/dev/null; then
                log_ok "Правило перехода INPUT -> $CHAIN_NAME активно."
            else
                log_warn "Правило перехода отсутствует в INPUT!"
            fi
            iptables -L "$CHAIN_NAME" -v -n 2>/dev/null || log_error "Цепочка $CHAIN_NAME отсутствует!"
            ;;
        check-ipset)
            if ipset list -n 2>/dev/null | grep -qw "$SET_V4"; then
                local c
                c=$(ipset list "$SET_V4" | grep -c '^[0-9]' || echo 0)
                log_ok "Набор $SET_V4 существует ($c записей)."
            else
                log_error "Набор $SET_V4 не найден!"
            fi
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
        list|list-manual)
            show_manual_list
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
            echo "  list           - Показать текущий ручной чёрный список"
            echo "  reinit         - Перезапустить/перепроверить правила в iptables"
            echo "  check-firewall - Проверить правила iptables"
            echo "  check-ipset    - Проверить ipset"
            echo "  stop           - Временно отключить цепочки фильтрации в iptables"
            exit 1
            ;;
    esac
fi

return 0 2>/dev/null || true
