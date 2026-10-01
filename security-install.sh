#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# 🛡️ VPS SECURITY INSTALLER
#
# Fail2ban + AntiScanner + MOTD
#
# Назначение:
#   Установка/настройка защиты на уже установленном VPS.
#
# ВАЖНО:
#   - существующий /etc/fail2ban/jail.local НЕ изменяется
#   - существующие jail.d/*.local НЕ перезаписываются
#   - наша конфигурация: /etc/fail2ban/jail.d/vps-setup.local
#   - SSH-порт определяется автоматически
#   - MOTD:
#       1) полный 99-custom-sysinfo
#       2) отдельный 98-security-status
#
###############################################################################

set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none

SCRIPT_VERSION="2.0"

###############################################################################
# НАСТРОЙКИ
###############################################################################

FAIL2BAN_JAIL="/etc/fail2ban/jail.d/vps-setup.local"

ANTISCAN_URL="https://gist.githubusercontent.com/sngvy/07cee7ac810c9d222fbebddff8c1d1b8/raw/974d3d87f190468e134e9b56f1e0a93c7caa0fcd/blacklist.txt"
ANTISCAN_SET="SCANNERS-BLOCK-V4"
ANTISCAN_SCRIPT="/usr/local/sbin/antiscan-update.sh"
ANTISCAN_SERVICE="/etc/systemd/system/antiscan.service"
ANTISCAN_TIMER="/etc/systemd/system/antiscan.timer"
ANTISCAN_LOG="/var/log/antiscan-update.log"

MOTD_DIR="/etc/update-motd.d"
MOTD_MAIN="${MOTD_DIR}/99-custom-sysinfo"
MOTD_SECURITY="${MOTD_DIR}/98-security-status"

###############################################################################
# ЦВЕТА
###############################################################################

NONE='\033[0m'
GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'

###############################################################################
# СЛУЖЕБНЫЕ ФУНКЦИИ
###############################################################################

log() {
    printf "  ${CYAN}▶${NONE} %s\n" "$*"
}

ok() {
    printf "  ${GREEN}✓${NONE} %s\n" "$*"
}

warn() {
    printf "  ${YELLOW}!${NONE} %s\n" "$*"
}

fail() {
    printf "  ${RED}✗${NONE} %s\n" "$*" >&2
}

die() {
    fail "$*"
    exit 1
}

safe_read() {
    local prompt="$1"
    local varname="$2"
    local default_val="${3:-}"
    local val=""

    printf "%s" "$prompt"
    if [ -t 0 ]; then
        read -r val || true
    elif { exec 3</dev/tty; } 2>/dev/null; then
        read -r val <&3 || true
        exec 3<&-
    else
        read -r val || true
    fi
    val="${val:-$default_val}"
    printf -v "$varname" "%s" "$val"
}

trap 'printf "\n"; fail "Ошибка на строке ${LINENO}: ${BASH_COMMAND}"; exit 1' ERR

###############################################################################
# ЗАГОЛОВОК
###############################################################################

printf "\n"
printf "======================================================================\n"
printf "  🛡️ SECURITY INSTALLER v%s\n" "$SCRIPT_VERSION"
printf "  Fail2ban + AntiScanner + MOTD\n"
printf "======================================================================\n"

###############################################################################
# ПРОВЕРКА БАЗОВЫХ ЗАВИСИМОСТЕЙ
###############################################################################

printf "\n${CYAN}>>> Проверка базовых зависимостей${NONE}\n"

apt_install_packages() {
    apt-get update </dev/null

    apt-get install -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        fail2ban \
        ipset \
        iptables \
        curl \
        ca-certificates </dev/null
}

MISSING=()

for package in fail2ban ipset iptables curl ca-certificates; do
    if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null \
        | grep -q "install ok installed"; then
        MISSING+=("$package")
    fi
done

if (( ${#MISSING[@]} > 0 )); then
    log "Устанавливаем отсутствующие пакеты: ${MISSING[*]}"
    apt_install_packages
    ok "Базовые зависимости установлены"
else
    ok "curl / ipset / iptables установлены"
fi

###############################################################################
# FAIL2BAN
###############################################################################

printf "\n${CYAN}>>> Fail2ban: проверка и установка${NONE}\n"

if dpkg-query -W -f='${Status}' fail2ban 2>/dev/null \
    | grep -q "install ok installed"; then

    F2B_VERSION="$(fail2ban-client -V 2>/dev/null | awk '{print $2}' || true)"
    F2B_VERSION="${F2B_VERSION:-unknown}"

    ok "Fail2ban уже установлен: ${F2B_VERSION}"
else
    apt_install_packages
    ok "Fail2ban установлен"
fi

command -v fail2ban-client >/dev/null 2>&1 \
    || die "fail2ban-client не найден."

###############################################################################
# ОПРЕДЕЛЕНИЕ SSH-ПОРТА
###############################################################################

SSH_PORT=""

if command -v sshd >/dev/null 2>&1; then
    SSH_PORT="$(
        sshd -T 2>/dev/null \
        | awk '$1=="port" {print $2; exit}' \
        || true
    )"
fi

if [[ -z "$SSH_PORT" ]] && [[ -f /etc/ssh/sshd_config ]]; then
    SSH_PORT="$(
        awk '
            /^[[:space:]]*Port[[:space:]]+[0-9]+/ {
                print $2
                exit
            }
        ' /etc/ssh/sshd_config 2>/dev/null || true
    )"
fi

SSH_PORT="${SSH_PORT:-22}"

log "SSH порт: ${SSH_PORT}"

###############################################################################
# FAIL2BAN CONFIG
#
# ВАЖНО:
#   jail.local НЕ трогаем.
#   Используем отдельный файл vps-setup.local.
###############################################################################

mkdir -p /etc/fail2ban/jail.d

F2B_BACKUP=""

if [[ -f "$FAIL2BAN_JAIL" ]]; then
    F2B_BACKUP="${FAIL2BAN_JAIL}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$FAIL2BAN_JAIL" "$F2B_BACKUP"
    ok "Предыдущий vps-setup.local сохранён: ${F2B_BACKUP}"
fi

cat > "$FAIL2BAN_JAIL" <<EOF
# =====================================================================
# Managed by security-install.sh
#
# Existing /etc/fail2ban/jail.local is preserved.
# Existing jail.d configuration is preserved.
# =====================================================================

[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
bantime = 1h
findtime = 10m
maxretry = 5

EOF

# recidive добавляем только если отдельная конфигурация уже не определяет его.
if ! grep -RqsE '^[[:space:]]*\[recidive\][[:space:]]*$' \
    /etc/fail2ban/jail.local \
    /etc/fail2ban/jail.d/*.conf \
    /etc/fail2ban/jail.d/*.local 2>/dev/null; then

    cat >> "$FAIL2BAN_JAIL" <<'EOF'

[recidive]
enabled = true
bantime = 1w
findtime = 1d
maxretry = 5
banaction = iptables-multiport
logpath = /var/log/fail2ban.log

EOF

    log "Jail recidive добавлен"
else
    log "Jail recidive уже существует — существующая конфигурация сохранена"
fi

ok "Конфигурация Fail2ban записана: ${FAIL2BAN_JAIL}"

###############################################################################
# ПРОВЕРКА КОНФИГУРАЦИИ ДО RESTART
###############################################################################

log "Проверка конфигурации Fail2ban..."

if ! fail2ban-client -t >/dev/null 2>&1; then
    fail2ban-client -t || true
    die "Конфигурация Fail2ban содержит ошибку."
fi

ok "Конфигурация Fail2ban корректна"

###############################################################################
# FAIL2BAN SERVICE
###############################################################################

systemctl enable fail2ban >/dev/null 2>&1 || true
systemctl restart fail2ban

sleep 2

if ! systemctl is-active --quiet fail2ban; then
    systemctl status fail2ban --no-pager -l || true
    die "Fail2ban не запустился."
fi

ok "Fail2ban запущен"

###############################################################################
# SSH JAIL
###############################################################################

if fail2ban-client status sshd >/dev/null 2>&1; then

    F2B_BANNED="$(
        fail2ban-client status sshd 2>/dev/null \
        | awk -F': ' '/Currently banned/ {print $2}' \
        | tr -d '[:space:]'
    )"

    F2B_BANNED="${F2B_BANNED:-0}"

    ok "Jail sshd активен, порт: ${SSH_PORT}, banned: ${F2B_BANNED}"

else

    fail2ban-client status || true
    die "Jail sshd не активен."

fi

###############################################################################
# RECIDIVE
###############################################################################

if fail2ban-client status recidive >/dev/null 2>&1; then
    ok "Jail recidive активен"
else
    warn "Jail recidive не активен"
fi

###############################################################################
# ANTISCANNER
###############################################################################

printf "\n${CYAN}>>> AntiScanner: установка и загрузка blacklist${NONE}\n"

###############################################################################
# Скрипт обновления blacklist
###############################################################################

cat > "$ANTISCAN_SCRIPT" <<'EOF'
#!/usr/bin/env bash

set -Eeuo pipefail

ANTISCAN_URL="https://gist.githubusercontent.com/sngvy/07cee7ac810c9d222fbebddff8c1d1b8/raw/974d3d87f190468e134e9b56f1e0a93c7caa0fcd/blacklist.txt"
ANTISCAN_SET="SCANNERS-BLOCK-V4"
ANTISCAN_LOG="/var/log/antiscan-update.log"

TMP_FILE="$(mktemp)"
TMP_SET="${ANTISCAN_SET}-NEW-$$"

cleanup() {
    rm -f "$TMP_FILE"
    ipset destroy "$TMP_SET" >/dev/null 2>&1 || true
}

trap cleanup EXIT

touch "$ANTISCAN_LOG"

###############################################################################
# DOWNLOAD
###############################################################################

if ! curl -fsSL \
    --connect-timeout 15 \
    --max-time 60 \
    "$ANTISCAN_URL" \
    -o "$TMP_FILE"; then

    echo "$(date '+%F %T') ERROR: blacklist download failed" \
        >> "$ANTISCAN_LOG"

    exit 1
fi

###############################################################################
# VALIDATE
###############################################################################

if ! awk '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*$/ {next}
    /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?[[:space:]]*$/ {
        valid++
        next
    }
    {
        invalid++
    }
    END {
        exit !(valid > 0 && invalid == 0)
    }
' "$TMP_FILE"; then

    echo "$(date '+%F %T') ERROR: invalid blacklist format" \
        >> "$ANTISCAN_LOG"

    exit 1
fi

###############################################################################
# BUILD TEMP IPSET
###############################################################################

ipset destroy "$TMP_SET" >/dev/null 2>&1 || true

ipset create "$TMP_SET" \
    hash:net \
    family inet \
    maxelem 65536

while IFS= read -r network; do

    [[ -z "$network" ]] && continue
    [[ "$network" =~ ^[[:space:]]*# ]] && continue

    network="$(printf '%s' "$network" | awk '{$1=$1; print}')"

    [[ -z "$network" ]] && continue

    if [[ "$network" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
        ipset add "$TMP_SET" "$network" -exist
    fi

done < "$TMP_FILE"

###############################################################################
# ATOMIC SWITCH
###############################################################################

if ipset list "$ANTISCAN_SET" >/dev/null 2>&1; then

    ipset swap "$TMP_SET" "$ANTISCAN_SET"

    ipset destroy "$TMP_SET" >/dev/null 2>&1 || true

else

    ipset rename "$TMP_SET" "$ANTISCAN_SET"

fi

###############################################################################
# IPTABLES RULE
###############################################################################

if ! iptables -C INPUT \
    -m set \
    --match-set "$ANTISCAN_SET" src \
    -j DROP >/dev/null 2>&1; then

    iptables -I INPUT \
        -m set \
        --match-set "$ANTISCAN_SET" src \
        -j DROP
fi

###############################################################################
# LOG
###############################################################################

COUNT="$(
    ipset list "$ANTISCAN_SET" 2>/dev/null \
    | awk '/Number of entries:/ {print $4; exit}'
)"

echo "$(date '+%F %T') OK: ${COUNT:-0} networks loaded" \
    >> "$ANTISCAN_LOG"

EOF

chmod 0755 "$ANTISCAN_SCRIPT"

###############################################################################
# SYSTEMD SERVICE
###############################################################################

cat > "$ANTISCAN_SERVICE" <<EOF
[Unit]
Description=AntiScanner IPv4 blacklist update
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=${ANTISCAN_SCRIPT}
StandardOutput=journal
StandardError=journal
EOF

###############################################################################
# SYSTEMD TIMER
###############################################################################

cat > "$ANTISCAN_TIMER" <<'EOF'
[Unit]
Description=AntiScanner periodic blacklist update

[Timer]
OnBootSec=2min
OnUnitActiveSec=6h
Persistent=true
Unit=antiscan.service

[Install]
WantedBy=timers.target
EOF

###############################################################################
# START ANTISCANNER
###############################################################################

systemctl daemon-reload

systemctl enable antiscan.timer >/dev/null 2>&1

log "Первоначальное обновление blacklist..."

if ! systemctl start antiscan.service; then
    journalctl -u antiscan.service -n 30 --no-pager || true
    die "AntiScanner не смог загрузить blacklist."
fi

systemctl restart antiscan.timer

if ! systemctl is-active --quiet antiscan.timer; then
    die "AntiScanner timer не запустился."
fi

ok "AntiScanner активен"

###############################################################################
# CHECK IPSET
###############################################################################

if ipset list "$ANTISCAN_SET" >/dev/null 2>&1; then

    SCANNER_COUNT="$(
        ipset list "$ANTISCAN_SET" 2>/dev/null \
        | awk '/Number of entries:/ {print $4; exit}'
    )"

    ok "Blacklist загружен: ${SCANNER_COUNT:-0} сетей"

else

    die "AntiScanner ipset не создан."

fi

###############################################################################
# CHECK IPTABLES
###############################################################################

if iptables -C INPUT \
    -m set \
    --match-set "$ANTISCAN_SET" src \
    -j DROP >/dev/null 2>&1; then

    ok "AntiScanner iptables DROP rule: OK"

else

    die "AntiScanner iptables DROP rule отсутствует."

fi

###############################################################################
# СОХРАНЕНИЕ IPTABLES
###############################################################################

if command -v netfilter-persistent >/dev/null 2>&1; then

    netfilter-persistent save >/dev/null 2>&1 || true

elif [[ -d /etc/iptables ]] \
    && command -v iptables-save >/dev/null 2>&1; then

    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

fi

###############################################################################
# ФИНАЛЬНАЯ ПРОВЕРКА SECURITY
###############################################################################

printf "\n${CYAN}>>> Финальная проверка защиты${NONE}\n"

F2B_STATUS="FAIL"
SSH_JAIL_STATUS="FAIL"
RECIDIVE_STATUS="FAIL"
ANTISCAN_STATUS="FAIL"
IPSET_STATUS="FAIL"
RULE_STATUS="FAIL"

systemctl is-active --quiet fail2ban \
    && F2B_STATUS="OK"

fail2ban-client status sshd >/dev/null 2>&1 \
    && SSH_JAIL_STATUS="OK"

fail2ban-client status recidive >/dev/null 2>&1 \
    && RECIDIVE_STATUS="OK"

systemctl is-active --quiet antiscan.timer \
    && ANTISCAN_STATUS="OK"

ipset list "$ANTISCAN_SET" >/dev/null 2>&1 \
    && IPSET_STATUS="OK"

iptables -C INPUT \
    -m set \
    --match-set "$ANTISCAN_SET" src \
    -j DROP >/dev/null 2>&1 \
    && RULE_STATUS="OK"

printf "    %-24s : %s\n" "Fail2ban" "$F2B_STATUS"
printf "    %-24s : %s\n" "SSH jail" "$SSH_JAIL_STATUS"
printf "    %-24s : %s\n" "recidive" "$RECIDIVE_STATUS"
printf "    %-24s : %s\n" "AntiScanner timer" "$ANTISCAN_STATUS"
printf "    %-24s : %s\n" "AntiScanner ipset" "$IPSET_STATUS"
printf "    %-24s : %s\n" "iptables DROP rule" "$RULE_STATUS"

if [[ "$F2B_STATUS" != "OK" \
   || "$SSH_JAIL_STATUS" != "OK" \
   || "$ANTISCAN_STATUS" != "OK" \
   || "$IPSET_STATUS" != "OK" \
   || "$RULE_STATUS" != "OK" ]]; then

    die "Финальная проверка безопасности не пройдена."

fi

###############################################################################
# MOTD — ОТДЕЛЬНЫЙ SECURITY STATUS
###############################################################################

create_security_motd() {

    # Удаляем старую версию нашего security MOTD.
    rm -f "$MOTD_SECURITY"

    cat > "$MOTD_SECURITY" <<'EOF'
#!/usr/bin/env bash

NONE='\033[0m'
GREEN_B='\033[1;32m'
RED_B='\033[1;31m'
CYAN='\033[0;36m'

# Fail2ban
if systemctl is-active --quiet fail2ban 2>/dev/null; then

    F2B_BANNED="$(
        fail2ban-client status sshd 2>/dev/null \
        | awk -F': ' '/Currently banned/ {print $2}' \
        | tr -d '[:space:]'
    )"

    F2B_BANNED="${F2B_BANNED:-0}"

    STATUS_FAIL2BAN="${GREEN_B}RUNNING | banned: ${F2B_BANNED}${NONE}"

else

    STATUS_FAIL2BAN="${RED_B}STOPPED${NONE}"

fi

# SSH jail
if systemctl is-active --quiet fail2ban 2>/dev/null \
    && fail2ban-client status sshd >/dev/null 2>&1; then

    F2B_BANNED="$(
        fail2ban-client status sshd 2>/dev/null \
        | awk -F: '/Currently banned:/ {
            gsub(/^[[:space:]]+/, "", $2)
            print $2
            exit
        }'
    )"

    F2B_BANNED="${F2B_BANNED:-0}"

    STATUS_SSH_JAIL="${GREEN_B}OK | banned: ${F2B_BANNED}${NONE}"

else

    STATUS_SSH_JAIL="${RED_B}FAIL${NONE}"

fi

# recidive
if systemctl is-active --quiet fail2ban 2>/dev/null \
    && fail2ban-client status recidive >/dev/null 2>&1; then

    STATUS_RECIDIVE="${GREEN_B}OK${NONE}"

else

    STATUS_RECIDIVE="${RED_B}FAIL${NONE}"

fi

# AntiScanner
if systemctl is-active --quiet antiscan.timer 2>/dev/null \
    && ipset list SCANNERS-BLOCK-V4 >/dev/null 2>&1 \
    && iptables -C INPUT \
        -m set \
        --match-set SCANNERS-BLOCK-V4 src \
        -j DROP >/dev/null 2>&1; then

    SCANNER_COUNT="$(
        ipset list SCANNERS-BLOCK-V4 2>/dev/null \
        | awk '/Number of entries:/ {print $4; exit}'
    )"

    SCANNER_COUNT="${SCANNER_COUNT:-0}"

    STATUS_ANTISCAN="${GREEN_B}RUNNING | networks: ${SCANNER_COUNT}${NONE}"

else

    STATUS_ANTISCAN="${RED_B}STOPPED${NONE}"

fi

printf '\n'
echo -e "  ${CYAN}🛡️ SECURITY${NONE}"

printf "    %-22s : %b\n" "Fail2ban" "$STATUS_FAIL2BAN"
printf "    %-22s : %b\n" "SSH jail" "$STATUS_SSH_JAIL"
printf "    %-22s : %b\n" "recidive" "$STATUS_RECIDIVE"
printf "    %-22s : %b\n" "AntiScanner" "$STATUS_ANTISCAN"

EOF

    chmod 0755 "$MOTD_SECURITY"

    ok "Создан ${MOTD_SECURITY}"
}

###############################################################################
# MOTD — ПОЛНЫЙ 99-CUSTOM-SYSINFO
###############################################################################

create_full_motd() {

    # Резервная копия существующей папки MOTD
    if [[ -d "$MOTD_DIR" ]]; then

        local motd_backup

        motd_backup="${MOTD_DIR}.bak.$(date +%Y%m%d-%H%M%S)"

        cp -a "$MOTD_DIR" "$motd_backup"

        ok "Резервная копия папки MOTD сохранена: ${motd_backup}"

    fi

    # При полном варианте отдельный security MOTD больше не нужен.
    rm -f "$MOTD_SECURITY"

    cat > "$MOTD_MAIN" <<'EOF'
#!/usr/bin/env bash

[[ -r /etc/default/vps-bootstrap ]] && source /etc/default/vps-bootstrap

INSTALL_POSTGRES="${INSTALL_POSTGRES:-0}"
INSTALL_MSSQL="${INSTALL_MSSQL:-0}"
INSTALL_TORRSERVER="${INSTALL_TORRSERVER:-0}"
WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"

# --- Цветовая палитра ---
NONE='\033[0m'
GREEN_B='\033[1;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED_B='\033[1;31m'
PURPLE='\033[0;35m'

# --- Uptime ---
UPTIME=$(uptime -p 2>/dev/null | sed 's/up //' || uptime)

# --- Процессы ---
PROCESSES=$(ps ax 2>/dev/null | wc -l | tr -d ' ')

# --- Сетевые соединения ---
CONN_ESTAB=$(ss -tun -a 2>/dev/null | awk '/ESTAB/ {c++} END {print c+0}')
CONN_TOTAL=$(ss -tun -a 2>/dev/null | awk 'NR>1 {c++} END {print c+0}')

# --- Память ---
MEM_TOTAL=$(free -m 2>/dev/null | awk '/Mem:/ {print $2}')
MEM_USED=$(free -m 2>/dev/null | awk '/Mem:/ {print $3}')
[ -n "$MEM_TOTAL" ] && [ "$MEM_TOTAL" -gt 0 ] \
    && MEM_PCT=$((MEM_USED * 100 / MEM_TOTAL)) \
    || MEM_PCT=0

# --- Swap ---
SWAP_TOTAL=$(free -m 2>/dev/null | awk '/Swap:/ {print $2}')
SWAP_USED=$(free -m 2>/dev/null | awk '/Swap:/ {print $3}')
[ -n "$SWAP_TOTAL" ] && [ "$SWAP_TOTAL" -gt 0 ] \
    && SWAP_PCT=$((SWAP_USED * 100 / SWAP_TOTAL)) \
    || SWAP_PCT=0

# --- Диск ---
DISK_TOTAL=$(df -h / 2>/dev/null | awk 'NR==2 {print $2}')
DISK_USED=$(df -h / 2>/dev/null | awk 'NR==2 {print $3}')
DISK_PCT=$(df -h / 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')

# --- IP с быстрым кэшированием ---
IP_LOCAL=$(hostname -I 2>/dev/null | awk '{print $1}')
IP_CACHE="/tmp/pub_ip_cache"

update_pub_ip() {
    local temp_ip

    temp_ip=$(curl -s --connect-timeout 2 https://api.ipify.org 2>/dev/null)

    if [[ "$temp_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$temp_ip" > "$IP_CACHE"
    fi
}

if [ ! -s "$IP_CACHE" ]; then
    update_pub_ip
elif find "$IP_CACHE" -mmin +60 -print -quit 2>/dev/null | grep -q .; then
    update_pub_ip &
fi

IP_PUB=$(cat "$IP_CACHE" 2>/dev/null || echo "Ожидание...")
[[ "$IP_PUB" == *"<html"* ]] && IP_PUB="N/A"

# --- SSH-сессии, Cron, APT ---
SSH_CONN=$(ss -t 2>/dev/null | awk '/ssh/ {c++} END {print c+0}')
CRON_COUNT=$(crontab -l 2>/dev/null | wc -l || echo 0)
UPDATES=$(apt-get -s upgrade 2>/dev/null | awk '/^Inst / {c++} END {print c+0}')

# --- Docker ---
DOCKER_COUNT=$(docker ps -q 2>/dev/null | wc -l || echo 0)
DOCKER_LIST=$(docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true)

# --- Статусы служб ---
check_service() {
    if systemctl is-active --quiet "$1" 2>/dev/null; then
        echo -e "${GREEN_B}RUNNING${NONE}"
    else
        echo -e "${RED_B}STOPPED${NONE}"
    fi
}

STATUS_XUI=$(check_service x-ui)
STATUS_NGINX=$(check_service nginx)

# --- Fail2ban ---
if systemctl is-active --quiet fail2ban 2>/dev/null; then

    F2B_BANNED=$(
        fail2ban-client status sshd 2>/dev/null \
        | awk -F': ' '/Currently banned/ {print $2}' \
        | tr -d '[:space:]'
    )

    F2B_BANNED="${F2B_BANNED:-0}"

    STATUS_FAIL2BAN="${GREEN_B}RUNNING | banned: ${F2B_BANNED}${NONE}"

else

    STATUS_FAIL2BAN="${RED_B}STOPPED${NONE}"

fi

# --- Fail2ban SSH jail ---
if systemctl is-active --quiet fail2ban 2>/dev/null \
    && fail2ban-client status sshd >/dev/null 2>&1; then

    F2B_BANNED="$(
        fail2ban-client status sshd 2>/dev/null \
        | awk -F: '/Currently banned:/ {
            gsub(/^[[:space:]]+/, "", $2)
            print $2
            exit
        }'
    )"

    F2B_BANNED="${F2B_BANNED:-0}"

    STATUS_SSH_JAIL="${GREEN_B}OK | banned: ${F2B_BANNED}${NONE}"

else

    STATUS_SSH_JAIL="${RED_B}FAIL${NONE}"

fi

# --- recidive ---
if systemctl is-active --quiet fail2ban 2>/dev/null \
    && fail2ban-client status recidive >/dev/null 2>&1; then

    STATUS_RECIDIVE="${GREEN_B}OK${NONE}"

else

    STATUS_RECIDIVE="${RED_B}FAIL${NONE}"

fi

# --- AntiScanner ---
if systemctl is-active --quiet antiscan.timer 2>/dev/null \
    && ipset list SCANNERS-BLOCK-V4 >/dev/null 2>&1 \
    && iptables -C INPUT \
        -m set \
        --match-set SCANNERS-BLOCK-V4 src \
        -j DROP >/dev/null 2>&1; then

    SCANNER_COUNT="$(
        ipset list SCANNERS-BLOCK-V4 2>/dev/null \
        | awk '/Number of entries:/ {print $4; exit}'
    )"

    SCANNER_COUNT="${SCANNER_COUNT:-0}"

    STATUS_ANTISCAN="${GREEN_B}RUNNING | networks: ${SCANNER_COUNT}${NONE}"

else

    STATUS_ANTISCAN="${RED_B}STOPPED${NONE}"

fi

# --- WARP ---
if ss -lnt 2>/dev/null | grep -qE ":${WARP_PROXY_PORT}[[:space:]]"; then

    STATUS_WARP="${GREEN_B}RUNNING (SOCKS5 :${WARP_PROXY_PORT})${NONE}"

elif systemctl is-active --quiet warp-svc 2>/dev/null; then

    STATUS_WARP="${YELLOW}CONNECTING (warp-svc)${NONE}"

else

    STATUS_WARP="${RED_B}STOPPED${NONE}"

fi

# --- PostgreSQL ---
if [[ "$INSTALL_POSTGRES" == "1" ]]; then

    STATUS_POSTGRES=$(
        pg_isready >/dev/null 2>&1 \
        && echo -e "${GREEN_B}RUNNING${NONE}" \
        || echo -e "${RED_B}STOPPED${NONE}"
    )

else

    STATUS_POSTGRES="${YELLOW}NOT INSTALLED${NONE}"

fi

# --- TorrServer ---
if [[ "$INSTALL_TORRSERVER" == "1" ]]; then

    STATUS_TORRSERVER=$(check_service torrserver)

else

    STATUS_TORRSERVER="${YELLOW}NOT INSTALLED${NONE}"

fi

# --- MS SQL ---
MSSQL_SA_PASSWORD_FILE="/root/.mssql-sa-password"

if [[ "$INSTALL_MSSQL" != "1" ]]; then

    STATUS_MSSQL="${YELLOW}NOT INSTALLED${NONE}"

elif docker ps --format '{{.Names}}' 2>/dev/null \
    | grep -Eq "^mssql_server$"; then

    if [[ -r "$MSSQL_SA_PASSWORD_FILE" ]]; then

        MSSQL_SA_PASSWORD="$(<"$MSSQL_SA_PASSWORD_FILE")"

        if docker exec mssql_server \
            /opt/mssql-tools18/bin/sqlcmd \
            -S localhost \
            -U SA \
            -P "$MSSQL_SA_PASSWORD" \
            -C \
            -Q "SELECT 1" >/dev/null 2>&1; then

            STATUS_MSSQL="${GREEN_B}RUNNING${NONE}"

        else

            STATUS_MSSQL="${YELLOW}STARTING/ERROR${NONE}"

        fi

    else

        STATUS_MSSQL="${YELLOW}PASSWORD FILE MISSING${NONE}"

    fi

else

    STATUS_MSSQL="${RED_B}STOPPED${NONE}"

fi

# --- Amnezia VPN ---
if docker ps --format '{{.Names}}' 2>/dev/null \
    | grep -Eq "^amnezia-"; then

    STATUS_AMNEZIA="${GREEN_B}RUNNING (Docker)${NONE}"

else

    STATUS_AMNEZIA="${RED_B}STOPPED${NONE}"

fi

# ============================================================================
# ВЫВОД
# ============================================================================

echo -e "${CYAN}┌────────────────────────────────────────────────────────────────────────┐${NONE}"
echo -e "  ${GREEN_B}СЕРВЕР ПОДКЛЮЧЕН СТАБИЛЬНО${NONE}"
echo -e "  Uptime: $UPTIME"
echo -e "${CYAN}├────────────────────────────────────────────────────────────────────────┤${NONE}"

echo -e "  ${PURPLE}МЕТРИКИ СИСТЕМЫ:${NONE}"

printf "    %-22s : %s (Pub: %s)\n" \
    "IPv4 адреса" "$IP_LOCAL" "$IP_PUB"

printf "    %-22s : %sMB / %sMB (%s%%)\n" \
    "Оперативная память" "$MEM_USED" "$MEM_TOTAL" "$MEM_PCT"

printf "    %-22s : %sMB / %sMB (%s%%)\n" \
    "Swap" "$SWAP_USED" "$SWAP_TOTAL" "$SWAP_PCT"

printf "    %-22s : %s / %s (%s%%)\n" \
    "Диск (/)" "$DISK_USED" "$DISK_TOTAL" "$DISK_PCT"

printf "    %-22s : %s\n" \
    "Всего процессов" "$PROCESSES"

printf "    %-22s : %s (Всего: %s)\n" \
    "Активные соединения" "$CONN_ESTAB" "$CONN_TOTAL"

printf "    %-22s : %s\n" \
    "SSH-сессии" "$SSH_CONN"

printf "    %-22s : %s\n" \
    "Cron задачи" "$CRON_COUNT"

printf "    %-22s : %s\n" \
    "Обновления APT" "$UPDATES"

echo -e "${CYAN}├────────────────────────────────────────────────────────────────────────┤${NONE}"

echo -e "  ${PURPLE}СТАТУС СЛУЖБ:${NONE}"

printf "    %-22s : %b\n" \
    "AntiScanner" "$STATUS_ANTISCAN"

printf "    %-22s : %b\n" \
    "SSH jail" "$STATUS_SSH_JAIL"

printf "    %-22s : %b\n" \
    "Fail2ban" "$STATUS_FAIL2BAN"

printf "    %-22s : %b\n" \
    "recidive" "$STATUS_RECIDIVE"

printf "    %-22s : %b\n" \
    "3x-ui / Xray" "$STATUS_XUI"

printf "    %-22s : %b\n" \
    "Amnezia VPN" "$STATUS_AMNEZIA"

printf "    %-22s : %b\n" \
    "Nginx" "$STATUS_NGINX"

printf "    %-22s : %b\n" \
    "Cloudflare WARP" "$STATUS_WARP"

printf "    %-22s : %b\n" \
    "PostgreSQL" "$STATUS_POSTGRES"

printf "    %-22s : %b\n" \
    "MS SQL Server" "$STATUS_MSSQL"

printf "    %-22s : %b\n" \
    "TorrServer" "$STATUS_TORRSERVER"

echo -e "${CYAN}├────────────────────────────────────────────────────────────────────────┤${NONE}"

echo -e "  ${PURPLE}DOCKER:${NONE}"

printf "    %-22s : %s\n" \
    "Активные контейнеры" "$DOCKER_COUNT"

if [[ -n "$DOCKER_LIST" ]]; then

    echo "$DOCKER_LIST"

else

    echo -e "    ${YELLOW}Нет активных контейнеров${NONE}"

fi

echo -e "${CYAN}└────────────────────────────────────────────────────────────────────────┘${NONE}"
echo

EOF

    chmod 0755 "$MOTD_MAIN"

    ok "99-custom-sysinfo записан: ${MOTD_MAIN}"

    rm -f "$MOTD_SECURITY"
}

###############################################################################
# ОЧИСТКА НАШИХ MOTD-ФАЙЛОВ
###############################################################################

cleanup_security_motd() {

    # Ничего системного здесь не удаляем.
    #
    # Удаляются только файлы, которыми управляет security-install.sh.

    if [[ -f "$MOTD_SECURITY" ]]; then
        rm -f "$MOTD_SECURITY"
        ok "Старый 98-security-status удалён"
    fi

}

###############################################################################
# ЗАПРОС И ОЧИСТКА СТОРОННИХ ФАЙЛОВ В UPDATE-MOTD.D
###############################################################################

ask_and_clean_motd_dir() {
    local keep1="$1"
    local keep2="${2:-}"

    printf "\n${CYAN}>>> Проверка сторонних файлов в ${MOTD_DIR}${NONE}\n\n"

    if [[ ! -d "$MOTD_DIR" ]]; then
        return 0
    fi

    local other_files=()
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local bname
        bname="$(basename "$f")"
        if [[ "$bname" != "$keep1" ]] && [[ -z "$keep2" || "$bname" != "$keep2" ]]; then
            other_files+=("$f")
        fi
    done < <(find "$MOTD_DIR" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | sort)

    if (( ${#other_files[@]} == 0 )); then
        ok "В ${MOTD_DIR} нет сторонних файлов"
        return 0
    fi

    warn "В папке ${MOTD_DIR} обнаружены сторонние/системные файлы (${#other_files[@]} шт.):"
    for f in "${other_files[@]}"; do
        printf "     - %s\n" "$(basename "$f")"
    done
    printf "\n"

    local DO_DELETE=""
    safe_read "Удалить все остальные файлы из ${MOTD_DIR}? [Y/n]: " DO_DELETE "Y"
    printf "\n"

    if [[ "$DO_DELETE" =~ ^[YyДд]$ || -z "$DO_DELETE" ]]; then
        local motd_backup="${MOTD_DIR}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a "$MOTD_DIR" "$motd_backup"
        ok "Резервная копия папки MOTD сохранена: ${motd_backup}"

        local count=0
        for f in "${other_files[@]}"; do
            if rm -f "$f"; then
                log "Удалён файл: $(basename "$f")"
                count=$((count + 1))
            fi
        done
        ok "Очистка завершена: удалено ${count} файлов из ${MOTD_DIR}"
    else
        log "Очистка отменена: файлы сохранены"
    fi
}


###############################################################################
# MOTD МЕНЮ
###############################################################################

printf "\n${CYAN}>>> MOTD: настройка статуса защиты${NONE}\n\n"

if [[ -f "$MOTD_MAIN" ]]; then

    printf "Найден существующий ${MOTD_MAIN}\n\n"

    printf "1) Заменить 99-custom-sysinfo полностью\n"
    printf "   (будет записан полный MOTD из security-install.sh)\n\n"

    printf "2) Оставить 99-custom-sysinfo без изменений\n"
    printf "   (создать отдельный 98-security-status)\n\n"

    safe_read "Выбор [1-2]: " MOTD_CHOICE "1"

else

    printf "99-custom-sysinfo не найден.\n\n"
    printf "1) Создать полный 99-custom-sysinfo\n"
    printf "2) Создать отдельный 98-security-status\n\n"

    safe_read "Выбор [1-2]: " MOTD_CHOICE "1"

fi

MOTD_CHOICE="${MOTD_CHOICE:-1}"

case "$MOTD_CHOICE" in

    1)

        printf "\n"

        cleanup_security_motd
        create_full_motd
        ask_and_clean_motd_dir "$(basename "$MOTD_MAIN")"

        ;;

    2)

        printf "\n"

        create_security_motd
        ask_and_clean_motd_dir "$(basename "$MOTD_SECURITY")" "$(basename "$MOTD_MAIN")"

        ;;

    *)

        warn "Неверный выбор."

        printf "\n"
        printf "1) Полностью заменить 99-custom-sysinfo\n"
        printf "2) Создать 98-security-status\n\n"

        safe_read "Выбор [1-2]: " MOTD_CHOICE "1"

        case "$MOTD_CHOICE" in

            1)
                cleanup_security_motd
                create_full_motd
                ask_and_clean_motd_dir "$(basename "$MOTD_MAIN")"
                ;;

            2)
                create_security_motd
                ask_and_clean_motd_dir "$(basename "$MOTD_SECURITY")" "$(basename "$MOTD_MAIN")"
                ;;

            *)
                die "MOTD не настроен: неверный выбор."
                ;;

        esac

        ;;

esac

###############################################################################
# ФИНАЛЬНАЯ ПРОВЕРКА
###############################################################################

printf "\n"
printf "======================================================================\n"
printf "  🛡️ ФИНАЛЬНАЯ ПРОВЕРКА SECURITY\n"
printf "======================================================================\n"

if systemctl is-active --quiet fail2ban; then
    printf "  Fail2ban              : ${GREEN}OK${NONE}\n"
else
    printf "  Fail2ban              : ${RED}FAIL${NONE}\n"
fi

if fail2ban-client status sshd >/dev/null 2>&1; then

    BANNED_NOW="$(
        fail2ban-client status sshd 2>/dev/null \
        | awk -F': ' '/Currently banned/ {print $2}' \
        | tr -d '[:space:]'
    )"

    printf "  SSH jail              : ${GREEN}OK | banned: %s${NONE}\n" \
        "${BANNED_NOW:-0}"

else

    printf "  SSH jail              : ${RED}FAIL${NONE}\n"

fi

if fail2ban-client status recidive >/dev/null 2>&1; then
    printf "  recidive              : ${GREEN}OK${NONE}\n"
else
    printf "  recidive              : ${YELLOW}NOT ACTIVE${NONE}\n"
fi

if systemctl is-active --quiet antiscan.timer \
    && ipset list "$ANTISCAN_SET" >/dev/null 2>&1 \
    && iptables -C INPUT \
        -m set \
        --match-set "$ANTISCAN_SET" src \
        -j DROP >/dev/null 2>&1; then

    SCANNER_COUNT="$(
        ipset list "$ANTISCAN_SET" 2>/dev/null \
        | awk '/Number of entries:/ {print $4; exit}'
    )"

    printf "  AntiScanner           : ${GREEN}OK | networks: %s${NONE}\n" \
        "${SCANNER_COUNT:-0}"

else

    printf "  AntiScanner           : ${RED}FAIL${NONE}\n"

fi

printf "\n"
printf "  MOTD                  : ${GREEN}OK${NONE}\n"
printf "  SSH port              : ${GREEN}%s${NONE}\n" "$SSH_PORT"
printf "  Fail2ban config       : ${GREEN}%s${NONE}\n" "$FAIL2BAN_JAIL"

printf "\n"
printf "  Готово. Скрипт можно запускать повторно.\n"
printf "======================================================================\n\n"
