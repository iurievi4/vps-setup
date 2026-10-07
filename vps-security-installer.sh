#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# VPS SECURITY INSTALLER
#
# Назначение:
#   Отдельная установка/настройка Fail2ban + VPS IP Guard + Cloudflare WARP
#   на уже работающем Debian/Ubuntu VPS.
#
# Повторный запуск безопасен: существующие конфиги не затираются без backup.
###############################################################################

# Проверка прав root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    printf '\n\033[1;31m[ERROR]\033[0m Этот скрипт требует прав root (запустите через sudo).\n\n' >&2
    exit 1
fi

SSH_PORT="$(sshd -T 2>/dev/null | awk '$1=="port" {print $2; exit}' || true)"
SSH_PORT="${SSH_PORT:-22}"

WARP_PORT="40000"

F2B_CONF="/etc/fail2ban/jail.d/vps-setup.local"
F2B_BACKUP="/etc/fail2ban/jail.d/vps-setup.local.bak.$(date +%Y%m%d-%H%M%S)"

# Переменные VPS IP Guard
IP_GUARD_DIR="/etc/vps-ip-guard"
IP_GUARD_CONF="${IP_GUARD_DIR}/ip-guard.conf"
IP_GUARD_MANUAL="${IP_GUARD_DIR}/manual.list"
IP_GUARD_CACHE="${IP_GUARD_DIR}/cache"
IP_GUARD_STATE="${IP_GUARD_DIR}/state"
IP_GUARD_BIN="/usr/local/sbin/ip-guard"
IP_GUARD_SET_V4="VPS-IP-GUARD-V4"
IP_GUARD_CHAIN="VPS-IP-GUARD"

log(){ printf '\n\033[1;32m>>> %s\033[0m\n' "$*"; }
ok(){ printf '  \033[1;32m[OK]\033[0m %s\n' "$*"; }
warn(){ printf '  \033[1;33m[WARN]\033[0m %s\n' "$*"; }
die(){ printf '  \033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

log "Проверка базовых зависимостей"
apt-get update -qq
apt-get install -y -qq curl ipset iptables gnupg ca-certificates lsb-release cron >/dev/null 2>&1 \
    || apt-get install -y -qq curl ipset iptables gnupg ca-certificates cron >/dev/null
ok "curl / ipset / iptables / gnupg / ca-certificates / cron установлены"

###############################################################################
# FAIL2BAN
###############################################################################
log "Fail2ban: проверка и установка"

if command -v fail2ban-client >/dev/null 2>&1; then
    F2B_VER="$(fail2ban-client version 2>/dev/null || true)"
    ok "Fail2ban уже установлен${F2B_VER:+: $F2B_VER}"
else
    apt-get install -y fail2ban
    command -v fail2ban-client >/dev/null 2>&1 || die "Fail2ban не установился."
    ok "Fail2ban установлен"
fi

mkdir -p /etc/fail2ban/jail.d

if [[ -f "$F2B_CONF" ]]; then
    cp -a "$F2B_CONF" "$F2B_BACKUP"
    ok "Предыдущий vps-setup.local сохранён: $F2B_BACKUP"
fi

# Не трогаем jail.conf и jail.local: Fail2ban рекомендует пользовательские
# переопределения в jail.d/*.local. Это также снижает риск конфликта с 3x-ui.
cat > "$F2B_CONF" <<EOF_F2B
# Managed by security installer
# SSH protection for this VPS

[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

# SSH is logged to systemd journal on modern Debian/Ubuntu.
[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
backend = systemd
maxretry = 3
findtime = 10m
bantime = 24h

# Long-term repeat offenders.
[recidive]
enabled = true
logpath = /var/log/fail2ban.log
banaction = %(banaction_allports)s
bantime = 1w
findtime = 1d
maxretry = 3
EOF_F2B
chmod 644 "$F2B_CONF"

# Проверяем конфигурацию до рестарта.
if ! fail2ban-client -t >/tmp/fail2ban-config-test.txt 2>&1; then
    cat /tmp/fail2ban-config-test.txt >&2
    [[ -f "$F2B_BACKUP" ]] && cp -a "$F2B_BACKUP" "$F2B_CONF"
    die "Ошибка конфигурации Fail2ban. Изменения откатены."
fi

systemctl enable --now fail2ban
systemctl restart fail2ban
sleep 1
systemctl is-active --quiet fail2ban || die "Служба Fail2ban не запустилась."
ok "Fail2ban запущен"

fail2ban-client status sshd >/dev/null 2>&1 || die "Jail sshd не активен."
ok "Jail sshd активен, порт: ${SSH_PORT}"

if fail2ban-client status recidive >/dev/null 2>&1; then
    ok "Jail recidive активен"
else
    warn "Jail recidive не активен — проверьте /var/log/fail2ban.log"
fi


###############################################################################
# VPS IP GUARD
###############################################################################
log "VPS IP Guard: установка и инициализация"

mkdir -p "$IP_GUARD_DIR" "$IP_GUARD_CACHE" "$IP_GUARD_STATE" /usr/local/sbin
[[ ! -f "$IP_GUARD_MANUAL" ]] && touch "$IP_GUARD_MANUAL"

# 1. Создание конфигурации (если отсутствует)
if [[ ! -f "$IP_GUARD_CONF" ]]; then
    cat > "$IP_GUARD_CONF" <<'EOF_CONF'
# /etc/vps-ip-guard/ip-guard.conf
ENABLE_IPV4=true
ENABLE_IPV6="auto"
SET_V4="VPS-IP-GUARD-V4"
SET_V6="VPS-IP-GUARD-V6"
CHAIN_NAME="VPS-IP-GUARD"
IPSET_HASHSIZE=16384
IPSET_MAXELEM=262144

# Источники списков (shadow-netlab/traffic-guard-lists)
RKN_GOV_URL="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/government_networks.list"
SCANNER_LIST_URL="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list"
SKIPA_URL="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/skipa.list"

CURL_CONNECT_TIMEOUT=10
CURL_MAX_TIME=60
MIN_TOTAL_NETWORKS=50
EOF_CONF
    chmod 644 "$IP_GUARD_CONF"
    ok "Создан конфигурационный файл: $IP_GUARD_CONF"
fi

# 2. Установка автономного бинарника /usr/local/sbin/ip-guard
cat > "$IP_GUARD_BIN" <<'EOF_IPGUARD'
#!/usr/bin/env bash
# ==============================================================================
# VPS IP Guard — Автономный модуль фильтрации нежелательного трафика и сканеров
# https://github.com/iurievi4/vps-setup
# ==============================================================================
set -Eeuo pipefail

CONF_DIR="/etc/vps-ip-guard"
CONF_FILE="${CONF_DIR}/ip-guard.conf"
MANUAL_LIST="${CONF_DIR}/manual.list"
CACHE_DIR="${CONF_DIR}/cache"
STATE_DIR="${CONF_DIR}/state"
STATS_FILE="${STATE_DIR}/stats.env"
LAST_UPDATE_FILE="${STATE_DIR}/last_update.txt"

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

# 2. Значения по умолчанию
: "${ENABLE_IPV4:=true}"
: "${ENABLE_IPV6:=auto}"
: "${SET_V4:=VPS-IP-GUARD-V4}"
: "${SET_V6:=VPS-IP-GUARD-V6}"
: "${CHAIN_NAME:=VPS-IP-GUARD}"
: "${IPSET_HASHSIZE:=16384}"
: "${IPSET_MAXELEM:=262144}"

# Источники списков
: "${SOURCE_GOVERNMENT_URL:=https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/government_networks.list}"
: "${SOURCE_SCANNER_URL:=https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list}"
: "${SOURCE_SKIPA_URL:=https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/skipa.list}"

: "${CURL_CONNECT_TIMEOUT:=10}"
: "${CURL_MAX_TIME:=60}"
: "${MIN_TOTAL_NETWORKS:=50}"

# Цвета для вывода в консоль
C_GREEN="[1;32m"
C_YELLOW="[1;33m"
C_RED="[1;31m"
C_BLUE="[1;34m"
C_CYAN="[1;36m"
C_RESET="[0m"

log_info()  { echo -e "${C_BLUE}[INFO]${C_RESET} $*"; }
log_ok()    { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
log_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
log_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*"; }
log_step()  { echo -e "${C_CYAN}[*]${C_RESET} $*"; }

# ------------------------------------------------------------------------------
# Проверка системных утилит
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
# Проверка поддержки IPv6
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
    local cache_target="$6"

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

    cp "$norm_v4_file" "$cache_target"
    cat "$norm_v4_file" >> "$out_v4"

    if is_ipv6_active; then
        normalize_v6 < "$raw_file" > "$norm_v6_file"
        cat "$norm_v6_file" >> "$out_v6"
    fi

    printf -v "$count_var_name" "%d" "$v4_count"
    printf "  ${C_GREEN}[OK]${C_RESET} %-25s : %d IPv4
" "$source_name" "$v4_count"
    return 0
}

# ------------------------------------------------------------------------------
# Атомарное обновление списков (Интернет -> Проверка -> Swap)
# ------------------------------------------------------------------------------
update_lists() {
    check_dependencies
    mkdir -p "$CACHE_DIR" "$CONF_DIR" "$STATE_DIR"

    IP_GUARD_TMP_DIR="$(mktemp -d /tmp/ip-guard-update.XXXXXX)"

    local raw_v4="${IP_GUARD_TMP_DIR}/all_v4.txt"
    local raw_v6="${IP_GUARD_TMP_DIR}/all_v6.txt"
    local restore_v4="${IP_GUARD_TMP_DIR}/restore_v4.ipset"
    local restore_v6="${IP_GUARD_TMP_DIR}/restore_v6.ipset"
    touch "$raw_v4" "$raw_v6"

    log_info "Загрузка внешних списков..."

    local failed_sources=0
    local count_gov=0
    local count_scanner=0
    local count_skipa=0

    # 1. Government networks list
    if [[ -n "${SOURCE_GOVERNMENT_URL:-}" ]]; then
        if ! fetch_and_validate_source "government_networks.list" "$SOURCE_GOVERNMENT_URL" "$raw_v4" "$raw_v6" count_gov "${CACHE_DIR}/government.list"; then
            failed_sources=$((failed_sources + 1))
        fi
    fi

    # 2. Scanner list
    if [[ -n "${SOURCE_SCANNER_URL:-}" ]]; then
        if ! fetch_and_validate_source "antiscanner.list" "$SOURCE_SCANNER_URL" "$raw_v4" "$raw_v6" count_scanner "${CACHE_DIR}/scanner.list"; then
            failed_sources=$((failed_sources + 1))
        fi
    fi

    # 3. Skipa list
    if [[ -n "${SOURCE_SKIPA_URL:-}" ]]; then
        if ! fetch_and_validate_source "skipa.list" "$SOURCE_SKIPA_URL" "$raw_v4" "$raw_v6" count_skipa "${CACHE_DIR}/skipa.list"; then
            failed_sources=$((failed_sources + 1))
        fi
    fi

    if [[ "$failed_sources" -gt 0 ]]; then
        log_warn "Проверка источников завершилась с ошибками (${failed_sources} недоступно)."
        log_warn "Атомарное обновление отменено. Текущий активный ipset не изменён."
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
    printf "  ${C_GREEN}[OK]${C_RESET} %-25s : %d entries
" "Manual blacklist" "$count_manual"

    local total_raw
    total_raw=$((count_gov + count_scanner + count_skipa + count_manual))

    # 5. Дедупликация и подсчет уникальных сетей
    log_info "Формирование объединённого списка..."
    sort -u "$raw_v4" -o "${raw_v4}.sorted"
    local total_v4
    total_v4=$(wc -l < "${raw_v4}.sorted")
    local dupes_collapsed
    dupes_collapsed=$((total_raw - total_v4))

    printf "  ${C_GREEN}[OK]${C_RESET} %-25s : %d networks
" "Unique IPv4 networks" "$total_v4"

    if [[ "$total_v4" -lt "$MIN_TOTAL_NETWORKS" ]]; then
        log_error "Общий объём записей ($total_v4) меньше минимального порога ($MIN_TOTAL_NETWORKS)."
        cleanup_tmp
        return 1
    fi

    # 6. Атомарное создание и swap временного ipset
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

    # Сохраняем в кэш активный список
    cp "${raw_v4}.sorted" "${CACHE_DIR}/active_v4.list"

    # Сохраняем детальную статистику
    local update_time
    update_time="$(date '+%Y-%m-%d %H:%M:%S')"
    cat <<EOF > "$STATS_FILE"
UPDATE_TIMESTAMP="${update_time}"
COUNT_GOV=${count_gov}
COUNT_SCANNER=${count_scanner}
COUNT_SKIPA=${count_skipa}
COUNT_MANUAL=${count_manual}
COUNT_TOTAL_RAW=${total_raw}
COUNT_DUPES=${dupes_collapsed}
COUNT_UNIQUE=${total_v4}
EOF
    echo "${update_time} - IPv4: ${total_v4} (из ${total_raw} сырых записей, схлопнуто дублей: ${dupes_collapsed})" > "$LAST_UPDATE_FILE"

    # 7. Обработка IPv6 (если активен)
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
    if [[ "$count" -lt "$MIN_TOTAL_NETWORKS" ]]; then
        log_error "Health check failed: количество записей ($count) меньше порога ($MIN_TOTAL_NETWORKS)!"
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
# Быстрая загрузка из локального кэша (БЕЗ обращения в Интернет)
# ------------------------------------------------------------------------------
reload_from_cache() {
    check_dependencies
    init_firewall

    if [[ -f "${CACHE_DIR}/active_v4.list" && -s "${CACHE_DIR}/active_v4.list" ]]; then
        log_info "Восстановление списка IPv4 из локального кэша..."
        ipset flush "$SET_V4" 2>/dev/null || true
        awk -v setname="$SET_V4" '{print "add " setname " " $1 " -exist"}' "${CACHE_DIR}/active_v4.list" | ipset restore
        log_ok "Список IPv4 восстановлен из локального кэша."
    else
        log_warn "Локальный кэш пуст или отсутствует. Выполните 'ip-guard update'."
        return 1
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
    echo -e "${C_CYAN}                   Ручной чёрный список                       ${C_RESET}"
    echo -e "${C_CYAN}==============================================================${C_RESET}
"
    if [[ -f "$MANUAL_LIST" && -s "$MANUAL_LIST" ]]; then
        local count
        count=$(grep -c '^[0-9a-fA-F]' "$MANUAL_LIST" || echo 0)
        echo -e "Количество: ${count}
"
        cat "$MANUAL_LIST"
    else
        echo "Ручной чёрный список пуст."
    fi
    echo ""
}

# ------------------------------------------------------------------------------
# Статус и статистика
# ------------------------------------------------------------------------------
show_status() {
    echo -e "${C_CYAN}=============================================================${C_RESET}"
    echo -e "${C_CYAN}                 VPS IP GUARD STATUS                         ${C_RESET}"
    echo -e "${C_CYAN}=============================================================${C_RESET}"

    # 1. Службы
    if systemctl is-active vps-ip-guard.service &>/dev/null; then
        echo -e "Service          : ${C_GREEN}RUNNING${C_RESET}"
    else
        echo -e "Service          : ${C_YELLOW}INACTIVE${C_RESET}"
    fi

    if systemctl is-active vps-ip-guard-update.timer &>/dev/null; then
        echo -e "Timer            : ${C_GREEN}ACTIVE${C_RESET}"
    else
        echo -e "Timer            : ${C_YELLOW}INACTIVE${C_RESET}"
    fi

    echo -e "IPv4             : ${C_GREEN}ENABLED${C_RESET}"
    if is_ipv6_active; then
        echo -e "IPv6             : ${C_GREEN}ENABLED${C_RESET}"
    else
        echo -e "IPv6             : ${C_YELLOW}DISABLED${C_RESET}"
    fi

    echo ""
    # 2. Наборы и фаервол
    local count_v4=0
    if ipset list -n 2>/dev/null | grep -qw "$SET_V4"; then
        count_v4=$(ipset list "$SET_V4" 2>/dev/null | grep -c '^[0-9]' || echo 0)
        echo -e "IPv4 ipset       : ${C_GREEN}ACTIVE${C_RESET}"
        echo -e "Networks         : ${C_GREEN}${count_v4}${C_RESET}"
    else
        echo -e "IPv4 ipset       : ${C_RED}NOT ACTIVE${C_RESET}"
        echo -e "Networks         : 0"
    fi

    if is_ipv6_active; then
        if ipset list -n 2>/dev/null | grep -qw "$SET_V6"; then
            local count_v6
            count_v6=$(ipset list "$SET_V6" 2>/dev/null | grep -c '^[0-9a-fA-F]' || echo 0)
            echo -e "IPv6 ipset       : ${C_GREEN}ACTIVE${C_RESET} (${count_v6} networks)"
        fi
    fi

    local m_count=0
    if [[ -f "$MANUAL_LIST" ]]; then
        m_count=$(grep -c '^[0-9a-fA-F]' "$MANUAL_LIST" || echo 0)
    fi
    echo -e "Manual blacklist : ${m_count}"

    # Кэш
    if [[ -f "${CACHE_DIR}/active_v4.list" && -s "${CACHE_DIR}/active_v4.list" ]]; then
        echo -e "Cache            : ${C_GREEN}OK${C_RESET}"
    else
        echo -e "Cache            : ${C_YELLOW}EMPTY${C_RESET}"
    fi

    # Проверка цепочки iptables
    if iptables -C INPUT -j "$CHAIN_NAME" 2>/dev/null; then
        echo -e "Firewall         : ${C_GREEN}ACTIVE${C_RESET}"
    else
        echo -e "Firewall         : ${C_RED}INACTIVE${C_RESET} (правило перехода не найдено в INPUT!)"
    fi

    # Источники и дедупликация
    echo ""
    echo "Sources:"
    if [[ -f "$STATS_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$STATS_FILE"
        printf "  Government    : %d
" "${COUNT_GOV:-0}"
        printf "  Scanner       : %d
" "${COUNT_SCANNER:-0}"
        printf "  SKIPA         : %d
" "${COUNT_SKIPA:-0}"
        if [[ "${COUNT_MANUAL:-0}" -gt 0 ]]; then
            printf "  Manual        : %d
" "${COUNT_MANUAL:-0}"
        fi
        echo ""
        printf "Duplicates       : %d
" "${COUNT_DUPES:-0}"
        printf "Unique networks  : %d
" "${COUNT_UNIQUE:-0}"
    else
        printf "  Government    : N/A
"
        printf "  Scanner       : N/A
"
        printf "  SKIPA         : N/A
"
    fi

    local last_update="N/A"
    if [[ -f "$LAST_UPDATE_FILE" ]]; then
        last_update=$(cat "$LAST_UPDATE_FILE" 2>/dev/null || echo "N/A")
    elif [[ -n "${UPDATE_TIMESTAMP:-}" ]]; then
        last_update="$UPDATE_TIMESTAMP"
    fi

    local next_update="N/A"
    if systemctl is-active vps-ip-guard-update.timer &>/dev/null; then
        next_update=$(systemctl list-timers vps-ip-guard-update.timer --no-pager 2>/dev/null | awk 'NR==2 {print $1, $2, $3, $4}')
        [[ -z "$next_update" ]] && next_update="Активен (ожидание)"
    fi

    echo ""
    echo "Last update      : $last_update"
    echo "Next update      : $next_update"

    echo ""
    echo -e "${C_BLUE}--- Blocked packets statistics (iptables) ---${C_RESET}"
    if iptables -L "$CHAIN_NAME" -v -n 2>/dev/null; then
        :
    else
        echo "Цепочка iptables $CHAIN_NAME отсутствует"
    fi

    if is_ipv6_active; then
        echo -e "
${C_BLUE}--- Blocked packets statistics IPv6 (ip6tables) ---${C_RESET}"
        ip6tables -L "$CHAIN_NAME" -v -n 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Установка Systemd юнитов
# ВНИМАНИЕ: ExecStop намеренно ОТСУТСТВУЕТ, чтобы остановка службы не снимала фаервол!
# ------------------------------------------------------------------------------
install_systemd() {
    log_info "Установка systemd юнитов для автозагрузки и обновления..."

    # Основной сервис: только загрузка при старте ОС, без ExecStop!
    cat <<EOF > /etc/systemd/system/vps-ip-guard.service
[Unit]
Description=VPS IP Guard Firewall Rule Loader
After=network-pre.target ufw.service
Before=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/ip-guard reload

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
Description=Run VPS IP Guard update

[Timer]
OnBootSec=15min
OnUnitActiveSec=24h
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable vps-ip-guard.service
    systemctl start vps-ip-guard.service
    systemctl enable --now vps-ip-guard-update.timer
    log_ok "Systemd сервис и таймер автообновления активны."
}

# ------------------------------------------------------------------------------
# Чистая установка модуля
# ------------------------------------------------------------------------------
install_module() {
    check_dependencies
    mkdir -p "$CONF_DIR" "$CACHE_DIR" "$STATE_DIR"
    [[ ! -f "$MANUAL_LIST" ]] && touch "$MANUAL_LIST"

    init_firewall
    if ! update_lists; then
        log_error "Первичное обновление списков завершилось с ошибкой."
        return 1
    fi

    if ! health_check; then
        log_error "Проверка работоспособности не пройдена."
        return 1
    fi

    install_systemd
    log_ok "Установка и настройка VPS IP Guard успешно завершена!"
    return 0
}

# ------------------------------------------------------------------------------
# Остановка и очистка правил (только для ручного вызова, НЕ для systemd!)
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
            install_module
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
            echo "  install        - Установить и настроить VPS IP Guard"
            echo "  update         - Атомарно обновить списки из сети"
            echo "  reload         - Восстановить активный список из локального кэша"
            echo "  status         - Показать состояние IP Guard"
            echo "  ban <IP/CIDR>  - Добавить IP или подсеть в ручной чёрный список"
            echo "  unban <IP/CIDR>- Удалить IP или подсеть из ручного чёрного списка"
            echo "  list           - Показать текущий ручной чёрный список"
            echo "  reinit         - Перезапустить правила в iptables"
            echo "  check-firewall - Проверить правила iptables"
            echo "  check-ipset    - Проверить ipset"
            echo "  stop           - Временно отключить фильтрацию IP Guard"
            exit 1
            ;;
    esac
fi

return 0 2>/dev/null || true
EOF_IPGUARD

chmod 755 "$IP_GUARD_BIN"
ok "Бинарник VPS IP Guard установлен: $IP_GUARD_BIN"

# 3. Первичный запуск установки и загрузки базы
"$IP_GUARD_BIN" install

systemctl daemon-reload
systemctl enable vps-ip-guard.service
systemctl start vps-ip-guard.service
systemctl enable --now vps-ip-guard-update.timer

ipset list "$IP_GUARD_SET_V4" >/dev/null 2>&1 || die "VPS IP Guard ipset не создан."
iptables -C INPUT -j "$IP_GUARD_CHAIN" >/dev/null 2>&1 || die "VPS IP Guard DROP цепочка не подключена к INPUT."
ok "VPS IP Guard активен и защищает систему"

###############################################################################
# CLOUDFLARE WARP (SOCKS5 PROXY)
###############################################################################
log "Cloudflare WARP: проверка и настройка (SOCKS5 :${WARP_PORT})"

run_warp_cli() {
    warp-cli --accept-tos "$@" 2>/dev/null || warp-cli "$@" 2>/dev/null
}

if ! command -v warp-cli >/dev/null 2>&1; then
    log "Установка пакета cloudflare-warp..."
    mkdir -p /usr/share/keyrings
    if ! curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null; then
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --dearmor > /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null || true
    fi

    DISTRO_CODENAME=""
    if command -v lsb_release >/dev/null 2>&1; then
        DISTRO_CODENAME="$(lsb_release -cs 2>/dev/null || true)"
    fi
    if [[ -z "$DISTRO_CODENAME" && -f /etc/os-release ]]; then
        DISTRO_CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
    fi
    if [[ -z "$DISTRO_CODENAME" && -f /etc/os-release ]]; then
        DISTRO_CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-}")"
    fi

    if [[ -z "$DISTRO_CODENAME" ]]; then
        warn "Не удалось автоматически определить codename дистрибутива, используем 'bookworm'"
        DISTRO_CODENAME="bookworm"
    fi

    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${DISTRO_CODENAME} main" \
        > /etc/apt/sources.list.d/cloudflare-client.list

    apt-get update -qq
    apt-get install -y cloudflare-warp || die "Не удалось установить cloudflare-warp."
    ok "Пакет cloudflare-warp установлен"
else
    ok "Cloudflare WARP уже установлен"
fi

systemctl daemon-reload
systemctl enable --now warp-svc
sleep 2
systemctl is-active --quiet warp-svc || die "Служба warp-svc не запустилась."
ok "Служба warp-svc активна"

for _ in {1..10}; do
    if run_warp_cli status >/dev/null 2>&1 || run_warp_cli registration show >/dev/null 2>&1 || run_warp_cli account >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

if ! run_warp_cli registration show >/dev/null 2>&1 && ! run_warp_cli account >/dev/null 2>&1; then
    run_warp_cli registration new >/dev/null 2>&1 || run_warp_cli register >/dev/null 2>&1 || true
    ok "Клиент Cloudflare WARP зарегистрирован"
else
    ok "Регистрация Cloudflare WARP уже существует"
fi

run_warp_cli mode proxy >/dev/null 2>&1 || run_warp_cli set-mode proxy >/dev/null 2>&1 || true
run_warp_cli proxy port "$WARP_PORT" >/dev/null 2>&1 || run_warp_cli set-proxy-port "$WARP_PORT" >/dev/null 2>&1 || true
run_warp_cli connect >/dev/null 2>&1 || true

warp_listening=0
for _ in {1..10}; do
    if ss -lnt 2>/dev/null | grep -qE ":${WARP_PORT}[[:space:]]"; then
        warp_listening=1
        break
    fi
    sleep 1
done

if [[ "$warp_listening" -eq 1 ]]; then
    ok "Cloudflare WARP SOCKS5 прокси запущен на 127.0.0.1:${WARP_PORT}"
else
    warn "Порт ${WARP_PORT} пока не отвечает, warp-svc продолжает установку соединения"
fi

###############################################################################
# MOTD SECURITY STATUS
###############################################################################
log "MOTD: настройка статуса защиты"

MOTD_FILE="/etc/update-motd.d/99-custom-sysinfo"
MOTD_SECURITY_FILE="/etc/update-motd.d/98-security-status"

if [[ -f "$MOTD_FILE" ]]; then
    echo
    echo "Найден существующий $MOTD_FILE"
    echo
    echo "1) Интегрировать статусы безопасности в $MOTD_FILE"
    echo "2) Создать отдельный $MOTD_SECURITY_FILE"
    echo "3) Ничего не менять"
    echo
    read -r -p "Выбор [1-3] (по умолчанию 1): " MOTD_CHOICE || MOTD_CHOICE="1"
    MOTD_CHOICE="${MOTD_CHOICE:-1}"
else
    echo
    echo "$MOTD_FILE не найден."
    echo
    echo "1) Создать $MOTD_SECURITY_FILE"
    echo "2) Ничего не менять"
    echo
    read -r -p "Выбор [1-2] (по умолчанию 1): " MOTD_CHOICE || MOTD_CHOICE="1"
    MOTD_CHOICE="${MOTD_CHOICE:-1}"
    [[ "$MOTD_CHOICE" == "1" ]] && MOTD_CHOICE=2 || MOTD_CHOICE=3
fi

if [[ "$MOTD_CHOICE" == "1" && -f "$MOTD_FILE" ]]; then
    MOTD_BACKUP="${MOTD_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$MOTD_FILE" "$MOTD_BACKUP"
    ok "Резервная копия MOTD: $MOTD_BACKUP"

    python3 - "$MOTD_FILE" <<'PY_MOTD'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
s = path.read_text()

# Удаляем старые управляемые блоки
s = re.sub(r'\n?# === SECURITY STATUS BEGIN ===\n.*?\n# === SECURITY STATUS END ===\n?', '\n', s, flags=re.S)

marker = 'СТАТУС СЛУЖБ:'
if marker not in s:
    raise SystemExit('Не найден блок "СТАТУС СЛУЖБ" в 99-custom-sysinfo')

# 1. Логика вычисления статусов
block = r"""# === SECURITY STATUS BEGIN ===
check_active_security() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

if check_active_security fail2ban; then
    STATUS_FAIL2BAN="${GREEN_B}RUNNING${NONE}"
else
    STATUS_FAIL2BAN="${RED_B}STOPPED${NONE}"
fi

if check_active_security fail2ban && fail2ban-client status sshd >/dev/null 2>&1; then
    F2B_BANNED="$(fail2ban-client status sshd 2>/dev/null | awk -F: '/Currently banned:/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')"
    F2B_BANNED="${F2B_BANNED:-0}"
    STATUS_SSH_JAIL="${GREEN_B}OK | banned: ${F2B_BANNED}${NONE}"
else
    STATUS_SSH_JAIL="${RED_B}FAIL${NONE}"
fi

if check_active_security fail2ban && fail2ban-client status recidive >/dev/null 2>&1; then
    STATUS_RECIDIVE="${GREEN_B}OK${NONE}"
else
    STATUS_RECIDIVE="${GRAY}N/A${NONE}"
fi

if iptables -C INPUT -j VPS-IP-GUARD >/dev/null 2>&1; then
    STATUS_IPGUARD="${GREEN_B}RUN${NONE}"
elif ipset list VPS-IP-GUARD-V4 >/dev/null 2>&1; then
    STATUS_IPGUARD="${YELLOW_B}IDLE${NONE}"
elif check_active_security vps-ip-guard.service; then
    STATUS_IPGUARD="${YELLOW_B}STOPPED${NONE}"
else
    STATUS_IPGUARD="${GRAY}NOT INSTALLED${NONE}"
fi

IPGUARD_COUNT="$(ipset list VPS-IP-GUARD-V4 2>/dev/null | awk '/Number of entries:/ {print $4; exit}')"
IPGUARD_COUNT="${IPGUARD_COUNT:-0}"

IPGUARD_LAST="Никогда"
if [[ -f /etc/vps-ip-guard/state/last_update.txt ]]; then
    IPGUARD_LAST="$(cat /etc/vps-ip-guard/state/last_update.txt 2>/dev/null | awk '{print $1, $2}')"
elif [[ -f /etc/vps-ip-guard/cache/active_v4.list ]]; then
    IPGUARD_LAST="$(date -r /etc/vps-ip-guard/cache/active_v4.list '+%Y-%m-%d %H:%M' 2>/dev/null)"
fi
# === SECURITY STATUS END ===
"""

# Вставляем блок вычисления перед блоком СТАТУС СЛУЖБ
target_marker_line = re.search(r'^[ \t]*.*СТАТУС СЛУЖБ.*$', s, re.M)
if target_marker_line:
    insert_pos = target_marker_line.start()
    s = s[:insert_pos] + block + '\n' + s[insert_pos:]
else:
    s = block + '\n' + s

# Удаляем любые старые строки вывода AntiScanner / IP Guard и Fail2ban из секции статусов
s = re.sub(r'^[ \t]*printf[ \t]+["\'].*?(?:AntiScanner|VPS IP Guard|Blocked IPs|Blocked Networks|Last update|Fail2ban|SSH jail|recidive).*?\n', '', s, flags=re.M)
s = re.sub(r'if \[\[ "\$ANTISCAN_STATUS" != \*"NOT INSTALLED"\* \]\]; then.*?fi\n', '', s, flags=re.S)
s = re.sub(r'if \[\[ "\$STATUS_IPGUARD" != \*"NOT INSTALLED"\* \]\]; then.*?fi\n', '', s, flags=re.S)

# Формируем итоговый блок вывода
addition = r'''printf "    %-22s : %b\n" "VPS IP Guard" "$STATUS_IPGUARD"
if [[ "$STATUS_IPGUARD" != *"NOT INSTALLED"* ]]; then
    printf "      %-20s : %s\n" "Blocked Networks" "$IPGUARD_COUNT"
    printf "      %-20s : %s\n" "Last update" "$IPGUARD_LAST"
fi
printf "    %-22s : %b\n" "Fail2ban" "$STATUS_FAIL2BAN"
printf "      %-20s : %b\n" "SSH jail" "$STATUS_SSH_JAIL"
printf "      %-20s : %b\n" "recidive" "$STATUS_RECIDIVE"
'''

header_match = re.search(r'^[ \t]*.*СТАТУС СЛУЖБ.*$', s, re.M)
if header_match:
    s = s[:header_match.end()] + '\n' + addition + s[header_match.end():]

path.write_text(s)
PY_MOTD

    chmod 755 "$MOTD_FILE"
    ok "VPS IP Guard и Fail2ban успешно интегрированы в СТАТУС СЛУЖБ"

elif [[ "$MOTD_CHOICE" == "2" ]]; then
    cat > "$MOTD_SECURITY_FILE" <<'EOF_MOTD_SECURITY'
#!/usr/bin/env bash
GREEN_B='\033[1;32m'
YELLOW_B='\033[1;33m'
RED_B='\033[1;31m'
GRAY='\033[0;37m'
NONE='\033[0m'

check_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

if iptables -C INPUT -j VPS-IP-GUARD >/dev/null 2>&1; then
    STATUS_IPGUARD="${GREEN_B}RUN${NONE}"
elif ipset list VPS-IP-GUARD-V4 >/dev/null 2>&1; then
    STATUS_IPGUARD="${YELLOW_B}IDLE${NONE}"
elif check_active vps-ip-guard.service; then
    STATUS_IPGUARD="${YELLOW_B}STOPPED${NONE}"
else
    STATUS_IPGUARD="${GRAY}NOT INSTALLED${NONE}"
fi

IPGUARD_COUNT="$(ipset list VPS-IP-GUARD-V4 2>/dev/null | awk '/Number of entries:/ {print $4; exit}')"
IPGUARD_COUNT="${IPGUARD_COUNT:-0}"

IPGUARD_LAST="Никогда"
if [[ -f /etc/vps-ip-guard/state/last_update.txt ]]; then
    IPGUARD_LAST="$(cat /etc/vps-ip-guard/state/last_update.txt 2>/dev/null | awk '{print $1, $2}')"
elif [[ -f /etc/vps-ip-guard/cache/active_v4.list ]]; then
    IPGUARD_LAST="$(date -r /etc/vps-ip-guard/cache/active_v4.list '+%Y-%m-%d %H:%M' 2>/dev/null)"
fi

if check_active fail2ban; then
    STATUS_FAIL2BAN="${GREEN_B}RUNNING${NONE}"
else
    STATUS_FAIL2BAN="${RED_B}STOPPED${NONE}"
fi

if check_active fail2ban && fail2ban-client status sshd >/dev/null 2>&1; then
    F2B_BANNED="$(fail2ban-client status sshd 2>/dev/null | awk -F: '/Currently banned:/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')"
    F2B_BANNED="${F2B_BANNED:-0}"
    STATUS_SSH_JAIL="${GREEN_B}OK | banned: ${F2B_BANNED}${NONE}"
else
    STATUS_SSH_JAIL="${RED_B}FAIL${NONE}"
fi

if check_active fail2ban && fail2ban-client status recidive >/dev/null 2>&1; then
    STATUS_RECIDIVE="${GREEN_B}OK${NONE}"
else
    STATUS_RECIDIVE="${GRAY}N/A${NONE}"
fi

if ss -lnt 2>/dev/null | grep -qE ':40000[[:space:]]'; then
    WARP_STATUS="${GREEN_B}RUNNING (SOCKS5 :40000)${NONE}"
elif check_active warp-svc; then
    WARP_STATUS="${YELLOW_B}CONNECTING (warp-svc)${NONE}"
else
    WARP_STATUS="${RED_B}STOPPED${NONE}"
fi

printf '\n'
echo -e "  \033[0;36m🛡️ СТАТУС СЛУЖБ БЕЗОПАСНОСТИ:${NONE}"
printf "    %-22s : %b\n" "VPS IP Guard" "$STATUS_IPGUARD"
if [[ "$STATUS_IPGUARD" != *"NOT INSTALLED"* ]]; then
    printf "      %-20s : %s\n" "Blocked Networks" "$IPGUARD_COUNT"
    printf "      %-20s : %s\n" "Last update" "$IPGUARD_LAST"
fi
printf "    %-22s : %b\n" "Fail2ban" "$STATUS_FAIL2BAN"
printf "      %-20s : %b\n" "SSH jail" "$STATUS_SSH_JAIL"
printf "      %-20s : %b\n" "recidive" "$STATUS_RECIDIVE"
printf "    %-22s : %b\n" "Cloudflare WARP" "$WARP_STATUS"
EOF_MOTD_SECURITY
    chmod 755 "$MOTD_SECURITY_FILE"
    ok "Создан отдельный $MOTD_SECURITY_FILE"
else
    ok "MOTD не изменён"
fi

###############################################################################
# FINAL CHECK
###############################################################################
log "ФИНАЛЬНАЯ ПРОВЕРКА"

printf 'Fail2ban service       : '; systemctl is-active --quiet fail2ban && echo 'OK' || echo 'FAIL'
printf 'Fail2ban sshd jail     : '; fail2ban-client status sshd >/dev/null 2>&1 && echo 'OK' || echo 'FAIL'
printf 'Fail2ban recidive      : '; fail2ban-client status recidive >/dev/null 2>&1 && echo 'OK' || echo 'WARN'
printf 'SSH port               : %s\n' "$SSH_PORT"
printf 'IP Guard service       : '; systemctl is-active --quiet vps-ip-guard.service && echo 'OK' || echo 'FAIL'
printf 'IP Guard timer         : '; systemctl is-active --quiet vps-ip-guard-update.timer && echo 'OK' || echo 'FAIL'
printf 'IP Guard ipset         : '; ipset list "$IP_GUARD_SET_V4" >/dev/null 2>&1 && echo 'OK' || echo 'FAIL'
printf 'IP Guard DROP          : '; iptables -C INPUT -j "$IP_GUARD_CHAIN" >/dev/null 2>&1 && echo 'OK' || echo 'FAIL'
printf 'Blocked networks       : %s\n' "$(ipset list "$IP_GUARD_SET_V4" 2>/dev/null | awk '/Number of entries:/ {print $4; exit}')"
printf 'WARP service (warp-svc): '; systemctl is-active --quiet warp-svc && echo 'OK' || echo 'FAIL'
printf 'WARP SOCKS5 (:%s)   : ' "$WARP_PORT"; ss -lnt 2>/dev/null | grep -qE ":${WARP_PORT}[[:space:]]" && echo 'OK' || echo 'FAIL'

echo
echo "Проверка Fail2ban:"
fail2ban-client status sshd 2>/dev/null | sed -n '1,12p' || true

echo
echo "Проверка Cloudflare WARP:"
if ss -lnt 2>/dev/null | grep -qE ":${WARP_PORT}[[:space:]]"; then
    warp_trace="$(curl -s --max-time 5 -x "socks5h://127.0.0.1:${WARP_PORT}" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
    if echo "$warp_trace" | grep -q 'warp=on'; then
        ok "WARP SOCKS5 успешно подключен к сети Cloudflare (warp=on)"
        echo "$warp_trace" | grep -E '^(warp|ip|loc)=' | sed 's/^/    /' || true
    elif [[ -n "$warp_trace" ]]; then
        ok "WARP SOCKS5 прокси отвечает на порту ${WARP_PORT}"
    else
        warn "Порт ${WARP_PORT} открыт, но ответ от cdn-cgi/trace пока не получен"
    fi
else
    warn "Порт ${WARP_PORT} не слушается. Проверьте статус: warp-cli status"
fi

echo
echo "======================================================================"
echo " Готово."
echo " VPS IP Guard управление        : ip-guard {status|update|ban|unban|list|reload}"
echo " VPS IP Guard конфиг            : $IP_GUARD_CONF"
echo " VPS IP Guard кэш базы          : $IP_GUARD_CACHE"
echo " Fail2ban конфиг                : $F2B_CONF"
echo " WARP SOCKS5 прокси             : 127.0.0.1:${WARP_PORT}"
echo "======================================================================"
