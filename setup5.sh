#!/usr/bin/env bash

###############################################################################
# ☁️ VPS BOOTSTRAP / SETUP
# Версия: 3.9.7 (Production-Ready)
#
# Поддерживаемые ОС: Ubuntu / Debian (amd64, arm64)
#
# Порядок развертывания:
#   1. Проверка окружения (root, маркер запуска, ОС, архитектура)
#   2. Установка базовых системных пакетов
#   3. Настройка sysctl (IPv6, BBR/FQ с проверкой ядра, forwarding)
#   4. Создание и активация SWAP (2 GB)
#   5. Безопасность: UFW (открытие порта SSH 1241) -> Настройка и рестарт SSH
#   6. Cloudflare WARP (SOCKS5 127.0.0.1:40000)
#   7. Веб-сервер Nginx (:80)
#   8. Панель 3x-ui + опциональный накат базы
#   9. Службы обслуживания:
#      - xui-backup.sh (с верификацией tar -tzf)
#      - xui-update-safe.sh (безопасный откат через .bak и maintenance lock)
#      - xui-health.sh (защита от restart-loop: макс. 3 перезапуска в час)
#      - system-update.sh (умный reboot только по /var/run/reboot-required)
#      - update-geo.sh, renew-ssl.sh
#  10. Системный планировщик /etc/cron.d/vps-maintenance
#  11. Быстрый и информативный MOTD (без лишней задержки, пароль MSSQL в файле)
#  12. Финальная проверка работоспособности
#  13. Создание маркера завершения
###############################################################################

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none

SCRIPT_VERSION="3.9.9-standalone-antiscan-ipv6-fix"
BOOTSTRAP_MARKER="/etc/vps-bootstrap-complete"
LOG_FILE="/var/log/vps-setup.log"

# Параметры по умолчанию
SSH_PORT="${SSH_PORT:-1241}"
XUI_PORT="${XUI_PORT:-8784}"
ACME_PORT="${ACME_PORT:-80}"
WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"
DISABLE_IPV6="${DISABLE_IPV6:-1}"
ENABLE_IP_FORWARD="${ENABLE_IP_FORWARD:-0}"
ALLOW_PORT_54325="${ALLOW_PORT_54325:-1}"

# Дополнительные компоненты: ask = спросить, 1 = установить, 0 = пропустить
INSTALL_POSTGRES="${INSTALL_POSTGRES:-ask}"
INSTALL_MSSQL="${INSTALL_MSSQL:-ask}"
INSTALL_TORRSERVER="${INSTALL_TORRSERVER:-ask}"

# Cloudflare WARP
INSTALL_WARP="${INSTALL_WARP:-1}"
WARP_MANDATORY="${WARP_MANDATORY:-1}"

FORCE_BOOTSTRAP="${FORCE_BOOTSTRAP:-0}"

XUI_INSTALL_URL="https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh"
XUI_UPDATE_URL="https://raw.githubusercontent.com/MHSanaei/3x-ui/main/update.sh"

BACKUP_DIR="/root/xui_backups"
PRE_UPDATE_DIR="${BACKUP_DIR}/pre-update"
MAINTENANCE_FILE="/etc/cron.d/vps-maintenance"
MSSQL_SA_PASSWORD_FILE="/root/.mssql-sa-password"


###############################################################################
# 1. ROOT, МАРКЕР, OS & ARCH CHECK
###############################################################################

if [[ "${EUID}" -ne 0 ]]; then
    echo "❌ Скрипт необходимо запускать с правами root."
    exit 1
fi

if [[ -f "$BOOTSTRAP_MARKER" ]] && [[ "$FORCE_BOOTSTRAP" != "1" ]]; then
    echo
    echo "======================================================================"
    echo " ⚠️ ВНИМАНИЕ: Сервер уже настроен этим скриптом!"
    echo " Маркер: ${BOOTSTRAP_MARKER}"
    echo " Для повторного запуска используйте: FORCE_BOOTSTRAP=1 bash setup.sh"
    echo "======================================================================"
    echo
    exit 0
fi

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

echo
echo "======================================================================"
echo " ☁️ VPS BOOTSTRAP ${SCRIPT_VERSION}"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================================"
echo

on_error() {
    local exit_code=$?
    echo
    echo "======================================================================"
    echo " ❌ ОШИБКА РАЗВЕРТЫВАНИЯ: Код ${exit_code} на строке ${BASH_LINENO[0]:-unknown}"
    echo " Команда: ${BASH_COMMAND:-unknown}"
    echo " Лог: ${LOG_FILE}"
    echo "======================================================================"
    echo
    exit "$exit_code"
}
trap on_error ERR

if [[ ! -f /etc/os-release ]]; then
    echo "❌ Не найден /etc/os-release."
    exit 1
fi

source /etc/os-release
OS_ID="${ID:-unknown}"
OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"

echo "OS           : ${PRETTY_NAME:-$OS_ID}"
echo "Codename     : ${OS_CODENAME:-unknown}"
echo "Архитектура  : ${ARCH}"

case "$OS_ID" in
    ubuntu|debian) ;;
    *) echo "❌ Поддерживаются только Ubuntu и Debian."; exit 1 ;;
esac

case "$ARCH" in
    amd64|arm64|x86_64|aarch64) ;;
    *) echo "❌ Архитектура ${ARCH} не поддерживается."; exit 1 ;;
esac

ask_component() {
    local name="$1"
    local var_name="$2"
    local current_value="${!var_name}"

    if [[ "$current_value" == "0" || "$current_value" == "1" ]]; then
        return 0
    fi

    if [[ ! -r /dev/tty ]]; then
        printf -v "$var_name" '0'
        return 0
    fi

    local answer
    while true; do
        read -rp "${name}? [y/N]: " answer </dev/tty || answer=""
        case "${answer,,}" in
            y|yes) printf -v "$var_name" '1'; return 0 ;;
            n|no|"") printf -v "$var_name" '0'; return 0 ;;
            *) echo "Введите y или n." ;;
        esac
    done
}

echo
echo "======================================================================"
echo " ДОПОЛНИТЕЛЬНЫЕ КОМПОНЕНТЫ"
echo "======================================================================"
echo
ask_component "Установить PostgreSQL" INSTALL_POSTGRES
ask_component "Установить MS SQL Server" INSTALL_MSSQL
ask_component "Установить TorrServer" INSTALL_TORRSERVER
echo
echo "Выбрано:"
echo "  PostgreSQL    : $([[ "$INSTALL_POSTGRES" == "1" ]] && echo "ДА" || echo "НЕТ")"
echo "  MS SQL Server : $([[ "$INSTALL_MSSQL" == "1" ]] && echo "ДА" || echo "НЕТ")"
echo "  TorrServer    : $([[ "$INSTALL_TORRSERVER" == "1" ]] && echo "ДА" || echo "НЕТ")"
echo


###############################################################################
# 2. УСТАНОВКА ПАКЕТОВ
###############################################################################

echo
echo ">>> Обновление пакетов и установка системных утилит..."
apt-get update </dev/null
apt-get upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" </dev/null

apt-get install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    nginx git curl wget gnupg cron iproute2 iputils-ping \
    iptables ipset ufw socat sqlite3 ca-certificates openssl jq \
    unzip lsof procps net-tools util-linux fail2ban </dev/null

systemctl enable --now cron


###############################################################################
# 2.1. ДОПОЛНИТЕЛЬНЫЕ КОМПОНЕНТЫ
###############################################################################

install_additional_components() {
    if [[ "$INSTALL_POSTGRES" == "1" ]]; then
        echo ">>> Установка PostgreSQL..."
        apt-get install -y postgresql postgresql-contrib
        systemctl enable --now postgresql
        systemctl is-active --quiet postgresql || { echo "❌ PostgreSQL не запустился."; return 1; }
        echo "✓ PostgreSQL установлен."
    else
        echo "⏭ PostgreSQL: пропущен."
    fi

    if [[ "$INSTALL_MSSQL" == "1" ]]; then
        if [[ "$ARCH" != "amd64" && "$ARCH" != "x86_64" ]]; then
            echo "❌ MS SQL Server выбран, но этот компонент в данном bootstrap поддерживается только на amd64/x86_64."
            return 1
        fi

        echo ">>> Установка MS SQL Server..."
        apt-get install -y docker.io
        systemctl enable --now docker

        if [[ ! -s "$MSSQL_SA_PASSWORD_FILE" ]]; then
            umask 077
            { echo 'Aa1!'; openssl rand -hex 24; } | tr -d '\n' > "$MSSQL_SA_PASSWORD_FILE"
            chmod 600 "$MSSQL_SA_PASSWORD_FILE"
        fi
        MSSQL_SA_PASSWORD="$(<"$MSSQL_SA_PASSWORD_FILE")"

        if docker ps -a --format '{{.Names}}' | grep -qx 'mssql_server'; then
            docker start mssql_server >/dev/null 2>&1 || true
        else
            docker pull mcr.microsoft.com/mssql/server:2022-latest
            docker run -d \
                --name mssql_server \
                --restart always \
                -e 'ACCEPT_EULA=Y' \
                -e "MSSQL_SA_PASSWORD=${MSSQL_SA_PASSWORD}" \
                -e 'MSSQL_PID=Express' \
                -p 1433:1433 \
                mcr.microsoft.com/mssql/server:2022-latest >/dev/null
        fi
        echo "✓ MS SQL Server установлен."
    else
        echo "⏭ MS SQL Server: пропущен."
    fi

    if [[ "$INSTALL_TORRSERVER" == "1" ]]; then
        echo ">>> Установка TorrServer..."
        local ts_arch
        case "$ARCH" in
            amd64|x86_64) ts_arch="amd64" ;;
            arm64|aarch64) ts_arch="arm64" ;;
            *) echo "❌ Архитектура ${ARCH} не поддерживается TorrServer."; return 1 ;;
        esac

        local ts_dir="/opt/torrserver"
        local ts_bin="${ts_dir}/TorrServer-linux-${ts_arch}"
        mkdir -p "$ts_dir"
        curl -4 -fL --retry 3 --connect-timeout 15 --max-time 600 \
            "https://github.com/YouROK/TorrServer/releases/latest/download/TorrServer-linux-${ts_arch}" \
            -o "$ts_bin"
        chmod 755 "$ts_bin"

        cat > /etc/systemd/system/torrserver.service <<EOF_TS
[Unit]
Description=TorrServer
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${ts_bin} --port 8090
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_TS

        systemctl daemon-reload
        systemctl enable --now torrserver
        systemctl is-active --quiet torrserver || { echo "❌ TorrServer не запустился."; return 1; }
        echo "✓ TorrServer установлен на порту 8090."
    else
        echo "⏭ TorrServer: пропущен."
    fi
}

install_additional_components


###############################################################################
# 3. SYSCTL (IPV6, BBR/FQ С ПРОВЕРКОЙ ЯДРА, IP FORWARD)
###############################################################################

echo ">>> Настройка сетевого стека ядра..."

# 3.1. IPv6
if [[ "$DISABLE_IPV6" == "1" ]]; then
    # Без heredoc: этот критичный блок не должен зависеть от shell-окружения.
    printf '%s\n' \
        'net.ipv6.conf.all.disable_ipv6=1' \
        'net.ipv6.conf.default.disable_ipv6=1' \
        'net.ipv6.conf.lo.disable_ipv6=1' \
        > /etc/sysctl.d/99-disable-ipv6.conf

    for iface in /proc/sys/net/ipv6/conf/*; do
        [[ -d "$iface" ]] || continue
        iface_name="$(basename "$iface")"
        sysctl -w "net.ipv6.conf.${iface_name}.disable_ipv6=1" >/dev/null 2>&1 || true
    done

    [[ -f /etc/default/ufw ]] && sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw
else
    rm -f /etc/sysctl.d/99-disable-ipv6.conf
    [[ -f /etc/default/ufw ]] && sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
fi

# 3.2. Проверка BBR в ядре
modprobe tcp_bbr 2>/dev/null || true
BBR_CONFIG="# BBR unavailable in kernel"
if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    BBR_CONFIG="net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr"
    echo "✓ BBR поддерживается ядром и активирован."
else
    echo "ℹ️ BBR не обнаружен в доступных алгоритмах ядра, оставлен системный по умолчанию."
fi

cat > /etc/sysctl.d/99-vps-optimization.conf <<EOF
${BBR_CONFIG}
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_syncookies=1
net.ipv4.ip_forward=${ENABLE_IP_FORWARD}
vm.swappiness=10
EOF

sysctl --system

if [[ "$DISABLE_IPV6" == "1" ]]; then
    if [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" == "1" ]]; then
        echo "✓ IPv6 успешно отключен."
    fi
fi


###############################################################################
# 4. SWAP (2 GB)
###############################################################################

if ! swapon --show | grep -q .; then
    echo ">>> Создание SWAP 2 GB..."
    if [[ ! -f /swapfile ]]; then
        dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress
        chmod 600 /swapfile
        mkswap /swapfile
    fi
    swapon /swapfile
    if ! grep -qE '^/swapfile\s' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    echo "✓ SWAP активирован."
else
    echo "✓ SWAP уже присутствует в системе."
fi


###############################################################################
# 5. БЕЗОПАСНОСТЬ: UFW -> ПРОВЕРКА -> SSH (ПОРТ 1241)
###############################################################################

echo ">>> Настройка сетевого экрана (UFW)..."

if [[ ! -f "$BOOTSTRAP_MARKER" ]] || [[ "$FORCE_BOOTSTRAP" == "1" ]]; then
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing

    # Сначала открываем новый порт SSH в фаерволе!
    ufw allow "${SSH_PORT}/tcp" comment 'SSH'
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    ufw allow 2053/tcp comment 'x-ui / xray'
    ufw allow 2096/tcp comment 'x-ui'
    ufw allow 8443/tcp comment 'x-ui / xray'
    ufw allow "${XUI_PORT}/tcp" comment 'x-ui panel'
    [[ "$ALLOW_PORT_54325" == "1" ]] && ufw allow 54325/tcp comment 'Service 54325'
    [[ "$INSTALL_MSSQL" == "1" ]] && ufw allow 1433/tcp comment 'MS SQL Server'
    [[ "$INSTALL_TORRSERVER" == "1" ]] && ufw allow 8090/tcp comment 'TorrServer'

    ufw --force enable
    ufw reload
fi

echo ">>> Настройка и проверка службы SSH на порт ${SSH_PORT}..."

# sshd требует этот runtime-каталог даже в минимальных образах.
mkdir -p /run/sshd
chmod 755 /run/sshd

SSHD_CONFIG="/etc/ssh/sshd_config"
mkdir -p /etc/ssh/sshd_config.d

sed -i -E 's/^[[:space:]]*Port[[:space:]]+/# Disabled: &/' "$SSHD_CONFIG"
shopt -s nullglob
for file in /etc/ssh/sshd_config.d/*.conf; do
    [[ "$(basename "$file")" == "99-custom-port.conf" ]] && continue
    sed -i -E 's/^[[:space:]]*Port[[:space:]]+/# Disabled: &/' "$file"
done
shopt -u nullglob

cat > /etc/ssh/sshd_config.d/99-custom-port.conf <<EOF
Port ${SSH_PORT}
EOF
chmod 644 /etc/ssh/sshd_config.d/99-custom-port.conf

systemctl disable --now ssh.socket 2>/dev/null || true
systemctl enable ssh.service
sshd -t
systemctl restart ssh
sleep 2

SSH_PORTS="$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}')"
EFFECTIVE_SSH_PORT="${SSH_PORTS%%$'\n'*}"
if [[ "$EFFECTIVE_SSH_PORT" != "$SSH_PORT" ]]; then
    echo "❌ SSH не применил порт ${SSH_PORT}. Фактический: ${EFFECTIVE_SSH_PORT}"
    exit 1
fi
echo "✓ SSH успешно работает на порту ${SSH_PORT} (UFW предварительно открыт)."


###############################################################################
# 5.1. FAIL2BAN
###############################################################################

echo ">>> Настройка Fail2ban..."

cat > /etc/fail2ban/jail.local <<EOF_F2B
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
backend = systemd
maxretry = 3
findtime = 10m
bantime = 24h

[recidive]
enabled = true
logpath = /var/log/fail2ban.log
banaction = %(banaction_allports)s
bantime = 1w
findtime = 1d
maxretry = 3
EOF_F2B

chmod 644 /etc/fail2ban/jail.local
systemctl enable --now fail2ban
systemctl restart fail2ban
sleep 2

if ! fail2ban-client status sshd >/dev/null 2>&1; then
    echo "❌ Fail2ban jail sshd не запустился."
    fail2ban-client status || true
    exit 1
fi

echo "✓ Fail2ban активирован: SSH :${SSH_PORT}, recidive."


###############################################################################
# 5.2. ANTISCANNER
###############################################################################

ANTISCAN_DIR="/etc/antiscan"
ANTISCAN_URL="https://gist.githubusercontent.com/sngvy/07cee7ac810c9d222fbebddff8c1d1b8/raw/974d3d87f190468e134e9b56f1e0a93c7caa0fcd/blacklist.txt"
ANTISCAN_SET="SCANNERS-BLOCK-V4"
ANTISCAN_SCRIPT="/usr/local/bin/update-antiscan.sh"
ANTISCAN_LOG="/var/log/antiscan-update.log"

echo ">>> Настройка AntiScanner..."

mkdir -p "$ANTISCAN_DIR" "$(dirname "$ANTISCAN_LOG")"

cat > /etc/default/antiscan <<EOF_ANTISCAN_CONF
ANTISCAN_URL="${ANTISCAN_URL}"
ANTISCAN_SET="${ANTISCAN_SET}"
ANTISCAN_LOG="${ANTISCAN_LOG}"
ANTISCAN_DIR="${ANTISCAN_DIR}"
EOF_ANTISCAN_CONF
chmod 600 /etc/default/antiscan

cat > "$ANTISCAN_SCRIPT" <<'EOF_ANTISCAN'
#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="/etc/default/antiscan"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

ANTISCAN_DIR="${ANTISCAN_DIR:-/etc/antiscan}"
ANTISCAN_FILE="${ANTISCAN_DIR}/blacklist.txt"
ANTISCAN_LAST_UPDATE="${ANTISCAN_DIR}/last_update"
ANTISCAN_COUNT_FILE="${ANTISCAN_DIR}/blocked_count"
URL="${ANTISCAN_URL:-https://gist.githubusercontent.com/sngvy/07cee7ac810c9d222fbebddff8c1d1b8/raw/974d3d87f190468e134e9b56f1e0a93c7caa0fcd/blacklist.txt}"
SET_NAME="${ANTISCAN_SET:-SCANNERS-BLOCK-V4}"
LOG="${ANTISCAN_LOG:-/var/log/antiscan-update.log}"
LOCK_FILE="/run/lock/antiscan-update.lock"
TMP_DIR="/run/antiscan"
TMP_FILE="${TMP_DIR}/blacklist.download"

mkdir -p "$ANTISCAN_DIR" "$(dirname "$LOG")" "$(dirname "$LOCK_FILE")" "$TMP_DIR"
exec >> "$LOG" 2>&1

log() { echo "[$(date '+%F %T')] $*"; }

command -v ipset >/dev/null 2>&1 || { log "ERROR: ipset not found"; exit 1; }
command -v curl >/dev/null 2>&1 || { log "ERROR: curl not found"; exit 1; }
command -v iptables >/dev/null 2>&1 || { log "ERROR: iptables not found"; exit 1; }

exec 9>"$LOCK_FILE"
flock -n 9 || { log "INFO: update already running"; exit 0; }

TMP_SET="${SET_NAME}-TMP-$$"
cleanup() {
    rm -rf "$TMP_DIR"
    ipset destroy "$TMP_SET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "=== AntiScanner update started ==="

DOWNLOAD_OK=0
if curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 -o "$TMP_FILE" "$URL"; then
    if [[ -s "$TMP_FILE" ]] && awk '
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*#/ { next }
        /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?[[:space:]]*$/ { ipv4++; next }
        /^[0-9A-Fa-f:]+(\/[0-9]+)?[[:space:]]*$/ { ipv6++; next }
        { invalid++ }
        END { exit !(ipv4 > 0 && invalid == 0) }
    ' "$TMP_FILE"; then
        DOWNLOAD_OK=1
        cp -f "$TMP_FILE" "$ANTISCAN_FILE"
        chmod 644 "$ANTISCAN_FILE"
        log "Downloaded fresh blacklist from ${URL}"
    else
        log "WARNING: downloaded file is invalid or empty, checking cache"
    fi
else
    log "WARNING: download failed from ${URL}, checking cache"
fi

SOURCE_FILE=""
if [[ "$DOWNLOAD_OK" -eq 1 ]]; then
    SOURCE_FILE="$ANTISCAN_FILE"
elif [[ -s "$ANTISCAN_FILE" ]]; then
    log "Using existing local cache: ${ANTISCAN_FILE}"
    SOURCE_FILE="$ANTISCAN_FILE"
else
    log "ERROR: no valid blacklist source available"
    exit 1
fi

ipset destroy "$TMP_SET" >/dev/null 2>&1 || true
ipset create "$TMP_SET" hash:net family inet hashsize 4096 maxelem 131072

valid=0
while IFS= read -r subnet; do
    subnet="${subnet%%$'
'}"
    subnet="${subnet//$'ï»¿'/}"
    [[ -z "$subnet" || "$subnet" =~ ^[[:space:]]*# ]] && continue
    subnet="$(printf '%s' "$subnet" | awk '{$1=$1; print}')"
    [[ -z "$subnet" ]] && continue

    if [[ "$subnet" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
        if ipset add "$TMP_SET" "$subnet" -exist 2>/dev/null; then
            valid=$((valid + 1))
        fi
    fi
done < "$SOURCE_FILE"

if [[ "$valid" -eq 0 ]]; then
    log "ERROR: no valid IPv4 networks loaded from ${SOURCE_FILE}"
    exit 1
fi

if ipset list "$SET_NAME" >/dev/null 2>&1; then
    ipset swap "$TMP_SET" "$SET_NAME"
    ipset destroy "$TMP_SET" >/dev/null 2>&1 || true
else
    ipset rename "$TMP_SET" "$SET_NAME"
fi

if ! iptables -C INPUT -m set --match-set "$SET_NAME" src -j DROP >/dev/null 2>&1; then
    iptables -I INPUT 1 -m set --match-set "$SET_NAME" src -j DROP
    log "Added iptables DROP rule for ${SET_NAME}"
fi

if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || true
elif command -v iptables-save >/dev/null 2>&1; then
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi

date '+%Y-%m-%d %H:%M' > "$ANTISCAN_LAST_UPDATE"
echo "$valid" > "$ANTISCAN_COUNT_FILE"

count="$(ipset list "$SET_NAME" 2>/dev/null | awk '/Number of entries:/ {print $4; exit}')"
count="${count:-$valid}"
log "OK: loaded ${valid} IPv4 networks; ipset entries=${count}"
exit 0
EOF_ANTISCAN

chmod 755 "$ANTISCAN_SCRIPT"
mkdir -p /usr/local/sbin
ln -sf "$ANTISCAN_SCRIPT" /usr/local/sbin/antiscan-update.sh

cat > /etc/systemd/system/antiscan.service <<EOF_ANTISCAN_SERVICE
[Unit]
Description=AntiScanner IP blacklist
After=network-online.target ufw.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${ANTISCAN_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_ANTISCAN_SERVICE

systemctl daemon-reload
systemctl enable --now antiscan.service

if ! ipset list "$ANTISCAN_SET" >/dev/null 2>&1; then
    echo "❌ AntiScanner ipset не создан."
    exit 1
fi
if ! iptables -C INPUT -m set --match-set "$ANTISCAN_SET" src -j DROP >/dev/null 2>&1; then
    echo "❌ AntiScanner правило DROP не установлено."
    exit 1
fi

echo "✓ AntiScanner активирован: ipset ${ANTISCAN_SET}."


###############################################################################
# 6. CLOUDFLARE WARP (SOCKS5 127.0.0.1:40000)
###############################################################################

echo ">>> Установка и настройка Cloudflare WARP..."

install_cloudflare_warp() {
    local keyring="/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg"
    local list_file="/etc/apt/sources.list.d/cloudflare-client.list"
    local repo_codename=""

    case "$OS_ID" in
        ubuntu)
            case "$OS_CODENAME" in
                noble|jammy|focal) repo_codename="$OS_CODENAME" ;;
                *) repo_codename="noble" ;;
            esac
            ;;
        debian)
            case "$OS_CODENAME" in
                bookworm|bullseye) repo_codename="$OS_CODENAME" ;;
                *) repo_codename="bookworm" ;;
            esac
            ;;
    esac

    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o "$keyring"
    echo "deb [signed-by=${keyring}] https://pkg.cloudflareclient.com/ ${repo_codename} main" > "$list_file"

    apt-get update
    if apt-get install -y cloudflare-warp; then
        systemctl enable --now warp-svc
        sleep 3
        warp-cli --accept-tos registration new 2>/dev/null || true
        warp-cli --accept-tos mode proxy
        warp-cli --accept-tos proxy port "$WARP_PROXY_PORT" 2>/dev/null || true
        warp-cli --accept-tos connect
        sleep 3
        echo "✓ Cloudflare WARP настроен в режиме SOCKS5 (127.0.0.1:${WARP_PROXY_PORT})."
    else
        echo "❌ Установка пакета cloudflare-warp завершилась с ошибкой."
        [[ "$WARP_MANDATORY" == "1" ]] && return 1
    fi
}

if [[ "$INSTALL_WARP" == "1" ]]; then
    install_cloudflare_warp
else
    echo "⏭ Cloudflare WARP: отключён параметром INSTALL_WARP=0."
fi


###############################################################################
# 7. NGINX
###############################################################################

echo ">>> Настройка Nginx..."

mkdir -p /var/www/acme/.well-known/acme-challenge
rm -f /etc/nginx/sites-enabled/default

cat > /etc/nginx/sites-available/cloud-node <<EOF
server {
    listen 80 default_server;
$( [[ "$DISABLE_IPV6" != "1" ]] && echo "    listen [::]:80 default_server;" )
    server_name _;

    root /var/www/acme;

    location /.well-known/acme-challenge/ {
        allow all;
    }

    location / {
        default_type text/plain;
        return 200 "Cloud Node Active\n";
    }
}
EOF

ln -sf /etc/nginx/sites-available/cloud-node /etc/nginx/sites-enabled/cloud-node

nginx -t
systemctl enable nginx
systemctl restart nginx


###############################################################################
# 8. УСТАНОВКА 3X-UI И ЭТАЛОННАЯ БАЗА
###############################################################################

echo
echo "======================================================================"
echo " 📦 Установка 3x-ui"
echo "======================================================================"

NGINX_WAS_ACTIVE=0
if systemctl is-active --quiet nginx; then
    NGINX_WAS_ACTIVE=1
    systemctl stop nginx
fi

restore_nginx_emergency() {
    local exit_code=$?
    [[ "$NGINX_WAS_ACTIVE" -eq 1 ]] && systemctl start nginx || true
    exit "$exit_code"
}
trap restore_nginx_emergency EXIT

TMP_XUI_INSTALL="/tmp/3x-ui-install.sh"
rm -f "$TMP_XUI_INSTALL"
curl -4 -fL --retry 3 --connect-timeout 15 --max-time 300 "$XUI_INSTALL_URL" -o "$TMP_XUI_INSTALL"
chmod 700 "$TMP_XUI_INSTALL"

export XUI_NONINTERACTIVE=1
export XUI_DB_TYPE="sqlite"
export XUI_SSL_MODE="ip"
export XUI_PANEL_PORT="$XUI_PORT"
export XUI_ACME_HTTP_PORT="$ACME_PORT"

bash "$TMP_XUI_INSTALL"
rm -f "$TMP_XUI_INSTALL"

ACME="/root/.acme.sh/acme.sh"
if [[ -x "$ACME" ]]; then
    "$ACME" --uninstall-cronjob >/dev/null 2>&1 || true
fi

# Функция восстановления базы данных
restore_custom_database() {
    local reg_choice="${REG_CHOICE:-}"
    local token="${GH_TOKEN:-}"
    local db_pass="${DB_PASS:-}"
    local repo="iurievi4/my-private-backups"
    local db_file=""
    local tmp_dir=""
    local downloaded=""
    local decrypted_archive=""
    local candidate_db=""
    local http_code=""
    local attempt

    read_secret_masked() {
        local prompt="$1"
        local __resultvar="$2"
        local ch value=""
        printf '%s' "$prompt" >/dev/tty

        while IFS= read -r -s -n 1 ch </dev/tty; do
            if [[ -z "$ch" ]]; then
                printf '\n' >/dev/tty
                break
            elif [[ "$ch" == $'\177' || "$ch" == $'\b' ]]; then
                if [[ -n "$value" ]]; then
                    value="${value%?}"
                    printf '\b \b' >/dev/tty
                fi
            else
                value+="$ch"
                printf '*' >/dev/tty
            fi
        done

        printf -v "$__resultvar" '%s' "$value"
    }

    cleanup_restore_tmp() {
        [[ -n "$tmp_dir" && -d "$tmp_dir" ]] && rm -rf "$tmp_dir"
    }

    if [[ -z "$reg_choice" ]] && [[ -r /dev/tty ]]; then
        echo
        echo "Выберите конфигурацию 3x-ui:"
        echo "  0) Чистая установка [по умолчанию]"
        echo "  1) Латвия  (lv-x-ui.db)"
        echo "  2) Москва  (mw-x-ui.db)"
        echo "  3) Турция  (tr-x-ui.db)"
        echo
        read -rp "Выбор [0-3]: " reg_choice </dev/tty || true
    fi

    reg_choice="${reg_choice:-0}"

    case "$reg_choice" in
        0)
            echo "  [i] Выбрана чистая установка."
            return 0
            ;;
        1)
            db_file="lv-x-ui.db"
            ;;
        2)
            db_file="mw-x-ui.db"
            ;;
        3)
            db_file="tr-x-ui.db"
            ;;
        *)
            echo "❌ Некорректный выбор: '${reg_choice}'"
            return 0
            ;;
    esac

    if [[ -z "$token" ]] && [[ -r /dev/tty ]]; then
        read_secret_masked "Введите GitHub Token: " token
    fi

    if [[ -z "$token" ]]; then
        echo "❌ GitHub Token не указан."
        echo "   Восстановление пропущено; установка продолжается."
        return 0
    fi

    tmp_dir="$(mktemp -d /tmp/xui-restore.XXXXXX)"
    downloaded="${tmp_dir}/${db_file}"
    decrypted_archive="${tmp_dir}/backup.tar.gz"
    mkdir -p "${tmp_dir}/extract"

    echo
    echo ">>> Скачивание резервной базы ${db_file}..."

    http_code="$(
        curl -4 -sS -w '%{http_code}' \
            -H "Authorization: Bearer ${token}" \
            -H 'Accept: application/vnd.github.raw+json' \
            --connect-timeout 15 \
            --max-time 300 \
            -o "$downloaded" \
            "https://api.github.com/repos/${repo}/contents/${db_file}" \
            || true
    )"

    if [[ "$http_code" != "200" ]] || [[ ! -s "$downloaded" ]]; then
        echo "❌ Ошибка скачивания базы (HTTP: ${http_code:-unknown})."
        cleanup_restore_tmp
        return 0
    fi

    echo "✓ Резервная база скачана."
    echo "  Размер: $(du -h "$downloaded" | awk '{print $1}')"

    if head -c 16 "$downloaded" 2>/dev/null | grep -q '^SQLite format 3'; then
        echo
        echo "❌ Файл ${db_file} является обычной SQLite-базой."
        echo "   Ожидалась AES-256-CBC резервная копия."
        echo "   Рабочая база сервера НЕ изменена."
        cleanup_restore_tmp
        return 0
    fi

    echo
    echo "Введите мастер-пароль базы. Допустимо до 3 попыток."

    for attempt in 1 2 3; do
        db_pass=""
        if [[ -n "${DB_PASS:-}" && "$attempt" -eq 1 ]]; then
            db_pass="$DB_PASS"
        elif [[ -r /dev/tty ]]; then
            read_secret_masked "Мастер-пароль: " db_pass
        else
            break
        fi

        if [[ -z "$db_pass" ]]; then
            echo "❌ Пароль не введён."
            continue
        fi

        rm -f "$decrypted_archive"
        rm -rf "${tmp_dir}/extract"
        mkdir -p "${tmp_dir}/extract"

        if ! openssl enc -d -aes-256-cbc -pbkdf2 \
            -in "$downloaded" \
            -out "$decrypted_archive" \
            -pass pass:"$db_pass" \
            2>/dev/null; then
            if (( attempt < 3 )); then
                echo "❌ Неверный пароль. Осталось попыток: $((3 - attempt))."
            fi
            continue
        fi

        if [[ ! -s "$decrypted_archive" ]] || ! tar -tzf "$decrypted_archive" >/dev/null 2>&1; then
            if (( attempt < 3 )); then
                echo "❌ Неверный пароль или повреждённый архив. Осталось попыток: $((3 - attempt))."
            fi
            continue
        fi

        echo "✓ AES-256-CBC + PBKDF2 → tar.gz успешно расшифровано."
        echo ">>> Распаковка резервной БД во временный каталог..."

        if ! tar -xzf "$decrypted_archive" -C "${tmp_dir}/extract"; then
            echo "❌ Не удалось распаковать tar.gz."
            continue
        fi

        local db_candidates=()
        mapfile -t db_candidates < <(
            find "${tmp_dir}/extract" \
                -type f \
                -name '*.db' \
                -size +0c \
                -print
        )

        if [[ "${#db_candidates[@]}" -ne 1 ]]; then
            echo "❌ В архиве найдено DB-файлов: ${#db_candidates[@]}. Ожидался ровно один *.db."
            continue
        fi

        candidate_db="${db_candidates[0]}"
        echo "✓ Найдена БД: $candidate_db"

        if ! sqlite3 "$candidate_db" 'PRAGMA integrity_check;' 2>/dev/null | grep -qx 'ok'; then
            echo "❌ SQLite integrity_check не пройден."
            continue
        fi
        echo "✓ SQLite integrity_check: OK"

        if ! sqlite3 "$candidate_db" "SELECT name FROM sqlite_master WHERE type='table' AND name='inbounds';" 2>/dev/null | grep -qx 'inbounds'; then
            echo "❌ В БД отсутствует таблица inbounds."
            continue
        fi

        if ! sqlite3 "$candidate_db" "SELECT name FROM sqlite_master WHERE type='table' AND name='users';" 2>/dev/null | grep -qx 'users'; then
            echo "❌ В БД отсутствует таблица users."
            continue
        fi

        if ! sqlite3 "$candidate_db" "SELECT name FROM sqlite_master WHERE type='table' AND name='settings';" 2>/dev/null | grep -qx 'settings'; then
            echo "❌ В БД отсутствует таблица settings."
            continue
        fi

        local backup_inbounds=0
        local backup_users=0
        local backup_settings=0

        backup_inbounds="$(sqlite3 "$candidate_db" "SELECT COUNT(*) FROM inbounds;" 2>/dev/null || echo 0)"
        backup_users="$(sqlite3 "$candidate_db" "SELECT COUNT(*) FROM users;" 2>/dev/null || echo 0)"
        backup_settings="$(sqlite3 "$candidate_db" "SELECT COUNT(*) FROM settings;" 2>/dev/null || echo 0)"

        echo ">>> Проверка содержимого резервной БД:"
        echo "    Размер БД      : $(du -h "$candidate_db" | awk '{print $1}')"
        echo "    Inbounds       : ${backup_inbounds}"
        echo "    Users          : ${backup_users}"
        echo "    Settings       : ${backup_settings}"

        if (( backup_inbounds < 1 )); then
            echo "❌ Резервная БД не содержит inbounds."
            cleanup_restore_tmp
            return 0
        fi

        if (( backup_users < 1 )); then
            echo "❌ Резервная БД не содержит users."
            cleanup_restore_tmp
            return 0
        fi

        echo "✓ Резервная БД содержит рабочую конфигурацию."

        local XUI_DB="/etc/x-ui/x-ui.db"
        local old_db_backup=""

        echo ">>> Остановка панели 3x-ui..."
        systemctl stop x-ui 2>/dev/null || true
        local wait_sec=0
        while pgrep -f "x-ui" >/dev/null 2>&1 && [[ "$wait_sec" -lt 10 ]]; do
            sleep 0.5
            wait_sec=$((wait_sec + 1))
        done
        pkill -9 -f "x-ui" 2>/dev/null || true
        sleep 1
        echo "✓ x-ui полностью остановлен."

        if [[ -f "$XUI_DB" ]]; then
            mkdir -p /root/xui_backups
            old_db_backup="/root/xui_backups/x-ui-before-restore-$(date +%Y%m%d-%H%M%S).db"
            cp -a "$XUI_DB" "$old_db_backup"
            echo "✓ Предыдущая БД сохранена: $old_db_backup"
        fi

        # Сброс WAL режима в восстанавливаемой базе перед заменой
        sqlite3 "$candidate_db" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true
        sqlite3 "$candidate_db" "PRAGMA journal_mode = DELETE;" >/dev/null 2>&1 || true

        # КРИТИЧЕСКИ ВАЖНО: Удаляем старую БД вместе со старыми журналами WAL и SHM!
        # Если оставить x-ui.db-wal от чистой установки, SQLite автоматически накатит
        # пустой журнал поверх новой базы данных при следующем открытии!
        echo ">>> Очистка старой базы данных и WAL/SHM журналов..."
        rm -f "$XUI_DB" "${XUI_DB}-wal" "${XUI_DB}-shm"

        echo ">>> Замена рабочей БД..."
        cp -f "$candidate_db" "$XUI_DB"
        chown root:root "$XUI_DB"
        chmod 644 "$XUI_DB"
        rm -f "${XUI_DB}-wal" "${XUI_DB}-shm"
        echo "✓ /etc/x-ui/x-ui.db заменена."

        echo ">>> Обнуление счетчиков трафика..."
        sqlite3 "$XUI_DB" "UPDATE client_traffics SET up = 0, down = 0;" 2>/dev/null || true
        sqlite3 "$XUI_DB" "UPDATE inbounds SET up = 0, down = 0;" 2>/dev/null || true
        sqlite3 "$XUI_DB" "DELETE FROM inbound_client_ips;" 2>/dev/null || true
        echo "✓ Счетчики трафика обнулены."

        # Включаем WAL режим с чистым состоянием
        sqlite3 "$XUI_DB" "PRAGMA journal_mode = WAL;" >/dev/null 2>&1 || true
        sqlite3 "$XUI_DB" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true

        # Проверка и линковка SSL путей
        local cert_path key_path
        cert_path="$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key = 'webCertFile';" 2>/dev/null || true)"
        key_path="$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key = 'webKeyFile';" 2>/dev/null || true)"

        if [[ -n "$cert_path" && -n "$key_path" ]]; then
            mkdir -p "$(dirname "$cert_path")" "$(dirname "$key_path")"
            if [[ ! -f "$cert_path" ]]; then
                [[ -f "/root/cert/ip/fullchain.pem" ]] && ln -sf "/root/cert/ip/fullchain.pem" "$cert_path" || \
                [[ -f "/root/cert/fullchain.pem" ]] && ln -sf "/root/cert/fullchain.pem" "$cert_path" || \
                [[ -f "/root/cert/xui.crt" ]] && ln -sf "/root/cert/xui.crt" "$cert_path"
            fi
            if [[ ! -f "$key_path" ]]; then
                [[ -f "/root/cert/ip/privkey.pem" ]] && ln -sf "/root/cert/ip/privkey.pem" "$key_path" || \
                [[ -f "/root/cert/privkey.pem" ]] && ln -sf "/root/cert/privkey.pem" "$key_path" || \
                [[ -f "/root/cert/xui.key" ]] && ln -sf "/root/cert/xui.key" "$key_path"
            fi
            if [[ ! -f "$cert_path" || ! -f "$key_path" ]]; then
                openssl req -x509 -newkey rsa:2048 -nodes -sha256 -keyout "$key_path" -out "$cert_path" -days 3650 -subj "/CN=vps" >/dev/null 2>&1 || true
                chmod 600 "$key_path" "$cert_path" 2>/dev/null || true
            fi
        fi

        # Открытие портов восстановленных inbounds в UFW
        if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
            while IFS= read -r in_port; do
                if [[ -n "$in_port" ]] && [[ "$in_port" =~ ^[0-9]+$ ]]; then
                    ufw allow "${in_port}/tcp" comment "Xray Inbound :${in_port}" >/dev/null 2>&1 || true
                fi
            done < <(sqlite3 "$XUI_DB" "SELECT port FROM inbounds WHERE enable = 1;" 2>/dev/null || true)
            ufw reload >/dev/null 2>&1 || true
        fi

        echo ">>> Запуск панели 3x-ui..."
        systemctl start x-ui 2>/dev/null || true
        sleep 4

        if ! systemctl is-active --quiet x-ui; then
            echo "❌ x-ui не запустился после восстановления."
            if [[ -n "$old_db_backup" && -f "$old_db_backup" ]]; then
                systemctl stop x-ui 2>/dev/null || true
                rm -f "$XUI_DB" "${XUI_DB}-wal" "${XUI_DB}-shm"
                cp -f "$old_db_backup" "$XUI_DB"
                systemctl start x-ui 2>/dev/null || true
                echo "✓ Предыдущая БД восстановлена."
            fi
            cleanup_restore_tmp
            return 0
        fi

        # Проверка базы ПОСЛЕ запуска x-ui
        local check_inbounds check_users check_settings restored_base_path restored_username
        check_inbounds="$(sqlite3 "$XUI_DB" "SELECT count(*) FROM inbounds;" 2>/dev/null || echo 0)"
        check_users="$(sqlite3 "$XUI_DB" "SELECT count(*) FROM users;" 2>/dev/null || echo 0)"
        check_settings="$(sqlite3 "$XUI_DB" "SELECT count(*) FROM settings;" 2>/dev/null || echo 0)"
        restored_base_path="$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key = 'webBasePath';" 2>/dev/null || echo '')"
        restored_username="$(sqlite3 "$XUI_DB" "SELECT username FROM users LIMIT 1;" 2>/dev/null || echo '')"

        echo ">>> Проверка содержимого БД после запуска x-ui:"
        echo "    Inbounds : ${check_inbounds}"
        echo "    Users    : ${check_users}"
        echo "    Settings : ${check_settings}"

        if [[ "$check_inbounds" -lt 1 ]]; then
            echo "❌ ОШИБКА: База оказалась пустой после старта x-ui! Откат..."
            systemctl stop x-ui 2>/dev/null || true
            rm -f "$XUI_DB" "${XUI_DB}-wal" "${XUI_DB}-shm"
            [[ -n "$old_db_backup" && -f "$old_db_backup" ]] && cp -f "$old_db_backup" "$XUI_DB"
            systemctl start x-ui 2>/dev/null || true
            cleanup_restore_tmp
            return 0
        fi

        echo "✓ 3x-ui успешно запущен с восстановленной базой."
        echo
        echo "======================================================================"
        echo " 🔑 ДАННЫЕ ДЛЯ ВХОДА В ПАНЕЛЬ (ИЗ ВОССТАНОВЛЕННОЙ БАЗЫ):"
        echo "======================================================================"
        local srv_ip
        srv_ip="$(curl -4 -s --connect-timeout 2 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
        echo "  URL панели : https://${srv_ip}:${XUI_PORT}${restored_base_path}"
        echo "  Логин      : ${restored_username}"
        echo "  Пароль     : (ваш прежний пароль пользователя ${restored_username} из бэкапа)"
        echo "  Inbounds   : ${check_inbounds} шт."
        echo "======================================================================"
        echo

        cleanup_restore_tmp
        return 0
    done

    echo "❌ Восстановление базы не выполнено после 3 попыток."
    cleanup_restore_tmp
    return 0
}

###############################################################################
# 9.1. BACKUP СКРИПТ С ПРОВЕРКОЙ TAR -TZF
###############################################################################

cat > /usr/local/sbin/xui-backup.sh <<'EOF'
#!/usr/bin/env bash

set -Eeuo pipefail
BACKUP_DIR="/root/xui_backups"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

DATE="$(date '+%Y-%m-%d_%H-%M-%S')"
BACKUP_FILE="${BACKUP_DIR}/x-ui_${DATE}.tar.gz"
TMP_FILE="${BACKUP_FILE}.tmp"

SOURCE_LIST=()
[[ -d /etc/x-ui ]] && SOURCE_LIST+=("etc/x-ui")
[[ -d /usr/local/x-ui ]] && SOURCE_LIST+=("usr/local/x-ui")
[[ -f /usr/bin/x-ui ]] && SOURCE_LIST+=("usr/bin/x-ui")
[[ -f /etc/systemd/system/x-ui.service ]] && SOURCE_LIST+=("etc/systemd/system/x-ui.service")
[[ -f /etc/default/x-ui ]] && SOURCE_LIST+=("etc/default/x-ui")
[[ -d /root/cert ]] && SOURCE_LIST+=("root/cert")
[[ -d /root/.acme.sh ]] && SOURCE_LIST+=("root/.acme.sh")

[[ "${#SOURCE_LIST[@]}" -eq 0 ]] && exit 0

tar -czf "$TMP_FILE" -C / "${SOURCE_LIST[@]}"

if ! tar -tzf "$TMP_FILE" >/dev/null 2>&1; then
    echo "ERROR: Backup archive verification failed!"
    rm -f "$TMP_FILE"
    exit 1
fi

mv "$TMP_FILE" "$BACKUP_FILE"
chmod 600 "$BACKUP_FILE"
find "$BACKUP_DIR" -type f -name 'x-ui_*.tar.gz' -mtime +14 -delete
echo "Backup created and verified: $BACKUP_FILE"
EOF
chmod 700 /usr/local/sbin/xui-backup.sh


###############################################################################
# 9.2. HEALTHCHECK С ЗАЩИТОЙ ОТ RESTART-LOOP (МАКС. 3 В ЧАС)
###############################################################################

cat > /usr/local/sbin/xui-health.sh <<'EOF'
#!/usr/bin/env bash

set -u
LOG="/var/log/xui-health.log"
SERVICE="x-ui"
CHECK_PORTS=()
RESTART_TRACK_FILE="/run/xui-restarts.log"
MAX_RESTARTS_PER_HOUR=3

need_restart=0
reason=""

if [[ -f /etc/x-ui/x-ui.db ]] && command -v sqlite3 >/dev/null 2>&1; then
    while IFS= read -r port; do
        [[ -n "$port" ]] && CHECK_PORTS+=("$port")
    done < <(sqlite3 /etc/x-ui/x-ui.db "SELECT port FROM inbounds WHERE enable = 1;" 2>/dev/null || true)
fi

if ! systemctl is-active --quiet "$SERVICE"; then
    need_restart=1
    reason="служба x-ui не активна"
elif ! pgrep -af 'xray' >/dev/null 2>&1; then
    need_restart=1
    reason="процесс xray не найден"
else
    for port in "${CHECK_PORTS[@]}"; do
        if ! ss -lnt 2>/dev/null | grep -qE ":${port}[[:space:]]"; then
            need_restart=1
            reason="порт ${port} не слушается"
            break
        fi
    done
fi

check_restart_limit() {
    local now
    now="$(date +%s)"
    local one_hour_ago=$((now - 3600))
    local recent_restarts=0
    local filtered_lines=()

    if [[ -f "$RESTART_TRACK_FILE" ]]; then
        while read -r ts; do
            if [[ "$ts" =~ ^[0-9]+$ ]] && [[ "$ts" -ge "$one_hour_ago" ]]; then
                recent_restarts=$((recent_restarts + 1))
                filtered_lines+=("$ts")
            fi
        done < "$RESTART_TRACK_FILE"
    fi

    if [[ "$recent_restarts" -ge "$MAX_RESTARTS_PER_HOUR" ]]; then
        return 1
    fi

    filtered_lines+=("$now")
    printf "%s\n" "${filtered_lines[@]}" > "$RESTART_TRACK_FILE"
    return 0
}

if [[ "$need_restart" -eq 1 ]]; then
    if ! check_restart_limit; then
        echo "$(date '+%F %T') [RESTART-LOOP BLOCKED] Превышен лимит (${MAX_RESTARTS_PER_HOUR}/час). Перезапуск пропущен. Требуется ручная проверка!" >> "$LOG"
        logger -t xui-health "Restart loop detected. Skipping automatic restart."
        exit 0
    fi

    echo "$(date '+%F %T') [RESTART] Причина: ${reason}" >> "$LOG"
    logger -t xui-health "x-ui restart. Reason: ${reason}"
    systemctl restart "$SERVICE"
    sleep 5
    if systemctl is-active --quiet "$SERVICE"; then
        echo "$(date '+%F %T') [OK] x-ui восстановлен" >> "$LOG"
    else
        echo "$(date '+%F %T') [FAIL] x-ui не восстановился" >> "$LOG"
    fi
else
    echo "$(date '+%F %T') [OK] x-ui + Xray + ports ${CHECK_PORTS[*]}" >> "$LOG"
fi
EOF
chmod 700 /usr/local/sbin/xui-health.sh
touch /var/log/xui-health.log && chmod 600 /var/log/xui-health.log


###############################################################################
# 9.3. БЕЗОПАСНЫЙ UPDATER 3X-UI С БЕКАПОМ ЧЕРЕЗ .BAK
###############################################################################

cat > /usr/local/sbin/xui-update-safe.sh <<'EOF'
#!/usr/bin/env bash

set -Eeuo pipefail
LOG="/var/log/xui-auto-update.log"
MAINTENANCE_LOCK="/run/lock/vps-maintenance.lock"
BACKUP_DIR="/root/xui_backups"
PRE_UPDATE_DIR="${BACKUP_DIR}/pre-update"
UPDATE_URL="https://raw.githubusercontent.com/MHSanaei/3x-ui/main/update.sh"
[[ -r /etc/default/vps-bootstrap ]] && source /etc/default/vps-bootstrap

exec >> "$LOG" 2>&1
mkdir -p "$PRE_UPDATE_DIR"

exec 9>"$MAINTENANCE_LOCK"
if ! flock -n 9; then
    echo "[$(date '+%F %T')] Update skipped: maintenance lock active."
    exit 0
fi

log() { echo "[$(date '+%F %T')] $*"; }

create_snapshot() {
    local label="$1"
    local dir="${PRE_UPDATE_DIR}/${label}"
    local archive="${dir}/x-ui-state.tar.gz"
    local tmp_archive="${archive}.tmp"

    mkdir -p "$dir"
    local source_list=()
    [[ -d /etc/x-ui ]] && source_list+=("etc/x-ui")
    [[ -d /usr/local/x-ui ]] && source_list+=("usr/local/x-ui")
    [[ -f /usr/bin/x-ui ]] && source_list+=("usr/bin/x-ui")
    [[ -f /etc/systemd/system/x-ui.service ]] && source_list+=("etc/systemd/system/x-ui.service")
    [[ -f /etc/default/x-ui ]] && source_list+=("etc/default/x-ui")
    [[ -d /root/cert ]] && source_list+=("root/cert")

    [[ "${#source_list[@]}" -eq 0 ]] && return 1

    tar -czf "$tmp_archive" -C / "${source_list[@]}"
    if ! tar -tzf "$tmp_archive" >/dev/null 2>&1; then
        rm -f "$tmp_archive"
        return 1
    fi
    mv "$tmp_archive" "$archive"
    chmod 600 "$archive"
    echo "$archive"
}

restore_snapshot() {
    local archive="$1"
    [[ ! -f "$archive" ]] && return 1

    if ! tar -tzf "$archive" >/dev/null 2>&1; then
        log "CRITICAL: Corrupted rollback archive. Aborting."
        return 1
    fi

    log "Stopping x-ui..."
    systemctl stop x-ui 2>/dev/null || true

    local bak_suffix="rollback-bak-$(date +%s)"
    [[ -d /etc/x-ui ]] && mv /etc/x-ui "/etc/x-ui.${bak_suffix}"
    [[ -d /usr/local/x-ui ]] && mv /usr/local/x-ui "/usr/local/x-ui.${bak_suffix}"
    [[ -d /root/cert ]] && mv /root/cert "/root/cert.${bak_suffix}"

    if tar -xzf "$archive" -C /; then
        systemctl daemon-reload
        systemctl enable x-ui >/dev/null 2>&1 || true
        systemctl start x-ui

        if health_check; then
            log "Rollback verified. Removing temp backup..."
            rm -rf "/etc/x-ui.${bak_suffix}" "/usr/local/x-ui.${bak_suffix}" "/root/cert.${bak_suffix}"
            return 0
        fi
    fi

    log "Reverting from temp backup..."
    systemctl stop x-ui 2>/dev/null || true
    rm -rf /etc/x-ui /usr/local/x-ui /root/cert
    [[ -d "/etc/x-ui.${bak_suffix}" ]] && mv "/etc/x-ui.${bak_suffix}" /etc/x-ui
    [[ -d "/usr/local/x-ui.${bak_suffix}" ]] && mv "/usr/local/x-ui.${bak_suffix}" /usr/local/x-ui
    [[ -d "/root/cert.${bak_suffix}" ]] && mv "/root/cert.${bak_suffix}" /root/cert
    systemctl daemon-reload
    systemctl start x-ui 2>/dev/null || true
    return 1
}

health_check() {
    sleep 10
    systemctl is-active --quiet x-ui || return 1
    ss -lnt 2>/dev/null | grep -qE ":${XUI_PORT}[[:space:]]" || return 1
    pgrep -af 'xray' >/dev/null 2>&1 || return 1
    local port
    if [[ -f /etc/x-ui/x-ui.db ]] && command -v sqlite3 >/dev/null 2>&1; then
        while IFS= read -r port; do
            [[ -n "$port" ]] || continue
            ss -lnt 2>/dev/null | grep -qE ":${port}[[:space:]]" || return 1
        done < <(sqlite3 /etc/x-ui/x-ui.db "SELECT port FROM inbounds WHERE enable = 1;" 2>/dev/null || true)
    fi
    return 0
}

main() {
    systemctl is-active --quiet x-ui || exit 1
    local pre_archive
    pre_archive="$(create_snapshot "current")"
    [[ ! -f "$pre_archive" ]] && exit 1

    local tmp_update="/tmp/xui-update.sh"
    rm -f "$tmp_update"
    if ! curl -4 -fL --retry 3 --connect-timeout 15 --max-time 300 "$UPDATE_URL" -o "$tmp_update"; then
        rm -f "$tmp_update"
        exit 1
    fi

    if ! grep -qi "3x-ui" "$tmp_update"; then
        log "ERROR: downloaded script failed sanity check."
        rm -f "$tmp_update"
        exit 1
    fi
    chmod 700 "$tmp_update"

    if ! bash "$tmp_update"; then
        rm -f "$tmp_update"
        restore_snapshot "$pre_archive" && exit 0
        exit 1
    fi
    rm -f "$tmp_update"

    health_check && exit 0

    log "Healthcheck failed. Initiating rollback..."
    create_snapshot "failed-$(date '+%Y%m%d-%H%M%S')" 2>/dev/null || true
    restore_snapshot "$pre_archive" && exit 0
    exit 1
}

main "$@"
EOF
chmod 700 /usr/local/sbin/xui-update-safe.sh
touch /var/log/xui-auto-update.log && chmod 600 /var/log/xui-auto-update.log


###############################################################################
# 9.4. ОБНОВЛЕНИЕ APT С УМНЫМ REBOOT
###############################################################################

cat > /usr/local/sbin/system-update.sh <<'EOF'
#!/usr/bin/env bash

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
LOG="/var/log/vps-system-update.log"
MAINTENANCE_LOCK="/run/lock/vps-maintenance.lock"

exec >> "$LOG" 2>&1

exec 9>"$MAINTENANCE_LOCK"
if ! flock -n 9; then
    echo "[$(date '+%F %T')] System update skipped: maintenance lock active."
    exit 0
fi

echo "[$(date '+%F %T')] Starting scheduled system update..."
apt-get update
apt-get upgrade -y
apt-get autoremove -y
apt-get autoclean

if [[ -f /var/run/reboot-required ]]; then
    echo "[$(date '+%F %T')] Reboot required! Scheduling graceful reboot in 2 minutes..."
    logger -t system-update "Reboot required after updates. Rebooting..."
    /sbin/shutdown -r +2 "Scheduled maintenance reboot after package updates"
else
    echo "[$(date '+%F %T')] Update complete. Reboot not required."
fi
EOF
chmod 700 /usr/local/sbin/system-update.sh


###############################################################################
# 9.5. ГЕО-БАЗЫ И SSL RENEWAL
###############################################################################

cat > /usr/local/sbin/update-geo.sh <<'EOF'
#!/usr/bin/env bash

set -u
LOG="/var/log/xui-geo-update.log"
MAINTENANCE_LOCK="/run/lock/vps-maintenance.lock"
TARGET_DIR="/usr/local/x-ui/bin"

exec >> "$LOG" 2>&1
exec 9>"$MAINTENANCE_LOCK"
if ! flock -n 9; then
    exit 0
fi

mkdir -p "$TARGET_DIR"

update_file() {
    local url="$1"
    local dest="$2"
    local tmp="${dest}.tmp"
    if curl -fsSL --retry 3 --connect-timeout 15 -o "$tmp" "$url" && [[ -s "$tmp" ]]; then
        mv -f "$tmp" "$dest"
        echo "$(date '+%F %T') OK: $(basename "$dest")"
    else
        rm -f "$tmp"
        echo "$(date '+%F %T') ERROR: $(basename "$dest")"
    fi
}

update_file "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat" "${TARGET_DIR}/geosite.dat"
update_file "https://github.com/v2fly/geoip/releases/latest/download/geoip.dat" "${TARGET_DIR}/geoip.dat"
update_file "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/geosite.dat" "${TARGET_DIR}/geosite_RU.dat"

command -v x-ui >/dev/null 2>&1 && x-ui update-all-geofiles >/dev/null 2>&1 || true
EOF
chmod 700 /usr/local/sbin/update-geo.sh

echo ">>> Загрузка актуальных гео-баз (dlc.dat, geoip.dat, geosite_RU.dat)..."
/usr/local/sbin/update-geo.sh || true

cat > /usr/local/bin/renew-ssl.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
LOG="/var/log/acme-renew.log"
ACME="/root/.acme.sh/acme.sh"
NGINX_WAS_ACTIVE=0
exec >> "$LOG" 2>&1

if systemctl is-active --quiet nginx; then
    NGINX_WAS_ACTIVE=1
    systemctl stop nginx
fi

cleanup() {
    local exit_code=$?
    [[ "$NGINX_WAS_ACTIVE" -eq 1 ]] && systemctl start nginx || true
    exit "$exit_code"
}
trap cleanup EXIT

if [[ -x "$ACME" ]]; then
    "$ACME" --cron --home "/root/.acme.sh"
fi
EOF
chmod 700 /usr/local/bin/renew-ssl.sh

if ! restore_custom_database; then
    echo "⚠️ Восстановление базы завершилось с ошибкой. Продолжаю установку без замены рабочей БД."
fi

# Восстанавливаем Nginx
systemctl enable nginx
nginx -t
systemctl start nginx
trap - EXIT


###############################################################################
# 10. CRON ПЛАНИРОВЩИК (/etc/cron.d/vps-maintenance)
###############################################################################

echo ">>> Настройка расписания обслуживания..."

cat > "$MAINTENANCE_FILE" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 1. SSL ACME (ежедневно)
16 10 * * * root /usr/local/bin/renew-ssl.sh

# 2. Бэкап x-ui (ежедневно)
0 3 * * * root /usr/local/sbin/xui-backup.sh

# 3. Обновление APT с умным ребутом (среда 03:30)
30 3 * * 3 root /usr/local/sbin/system-update.sh

# 4. Обновление 3x-ui с rollback (пятница 04:30)
30 4 * * 5 root /usr/local/sbin/xui-update-safe.sh

# 5. Гео-базы v2fly / runetfreedom (понедельник 05:00)
0 5 * * 1 root /usr/local/sbin/update-geo.sh

# 5.1. Обновление AntiScanner (понедельник 04:15)
15 4 * * 1 root /usr/local/bin/update-antiscan.sh >> /var/log/antiscan-update.log 2>&1

# 6. Мониторинг healthcheck с анти-лупом (каждые 30 мин)
*/30 * * * * root /usr/local/sbin/xui-health.sh

# 7. Ротация журналов journalctl (суббота 04:15)
15 4 * * 6 root /usr/bin/journalctl --vacuum-time=7d --vacuum-size=200M > /dev/null 2>&1
EOF

chmod 644 "$MAINTENANCE_FILE"
systemctl restart cron


###############################################################################
# 11. ЛЁГКИЙ, БЫСТРЫЙ И БЕЗОПАСНЫЙ MOTD
###############################################################################

echo ">>> Установка эксплуатационного MOTD..."

MOTD_DIR="/etc/update-motd.d"
MOTD_FILE="${MOTD_DIR}/99-custom-sysinfo"

mkdir -p "$MOTD_DIR"

find "$MOTD_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true

systemctl disable --now motd-news.service motd-news.timer 2>/dev/null || true
rm -f /var/lib/ubuntu-release-upgrader/release-upgrade-motd 2>/dev/null || true

cat > /etc/default/vps-bootstrap <<EOF_BOOTSTRAP
INSTALL_POSTGRES=${INSTALL_POSTGRES}
INSTALL_MSSQL=${INSTALL_MSSQL}
INSTALL_TORRSERVER=${INSTALL_TORRSERVER}
INSTALL_WARP=${INSTALL_WARP}
WARP_PROXY_PORT=${WARP_PROXY_PORT}
XUI_PORT=${XUI_PORT}
EOF_BOOTSTRAP

chmod 600 /etc/default/vps-bootstrap

if [[ "$INSTALL_MSSQL" == "1" && ! -f "$MSSQL_SA_PASSWORD_FILE" ]]; then
    umask 077
    { echo 'Aa1!'; openssl rand -hex 24; } \
        | tr -d '\n' > "$MSSQL_SA_PASSWORD_FILE"
    chmod 600 "$MSSQL_SA_PASSWORD_FILE"
fi

cat > "$MOTD_FILE" <<'EOF_MOTD'
#!/usr/bin/env bash

set +e

NONE='\033[0m'
GREEN_B='\033[1;32m'
RED_B='\033[1;31m'
YELLOW_B='\033[1;33m'
CYAN_B='\033[1;36m'
PURPLE='\033[1;35m'
WHITE_B='\033[1;37m'
GRAY='\033[0;37m'

LINE="────────────────────────────────────────────────────────────────────────"

status_running() {
    local service="$1"
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        printf "%b" "${GREEN_B}RUNNING${NONE}"
    else
        printf "%b" "${RED_B}STOPPED${NONE}"
    fi
}

status_enabled() {
    local service="$1"
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        printf "%b" "${GREEN_B}OK${NONE}"
    else
        printf "%b" "${RED_B}STOPPED${NONE}"
    fi
}

UPTIME_TEXT="$(uptime -p 2>/dev/null | sed 's/^up //')"
UPTIME_TEXT="${UPTIME_TEXT:-unknown}"

LOCAL_IPV4="$(
    hostname -I 2>/dev/null \
        | tr ' ' '\n' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        | head -n1
)"
LOCAL_IPV4="${LOCAL_IPV4:-N/A}"

PUB_IP_CACHE="/tmp/pub_ip_cache"
PUB_IP=""

if [[ -r "$PUB_IP_CACHE" ]]; then
    CACHE_AGE=$(( $(date +%s) - $(stat -c %Y "$PUB_IP_CACHE" 2>/dev/null || echo 0) ))
    if (( CACHE_AGE < 3600 )); then
        PUB_IP="$(cat "$PUB_IP_CACHE" 2>/dev/null || true)"
    fi
fi

if [[ -z "$PUB_IP" ]]; then
    PUB_IP="$(curl -4 -fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)"
    if [[ "$PUB_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf '%s\n' "$PUB_IP" > "$PUB_IP_CACHE"
    else
        PUB_IP="N/A"
    fi
fi

read -r MEM_TOTAL_KB MEM_USED_KB MEM_AVAIL_KB < <(
    awk '
        /MemTotal:/     { total=$2 }
        /MemAvailable:/ { avail=$2 }
        END {
            used=total-avail
            printf "%s %s %s\n", total, used, avail
        }
    ' /proc/meminfo
)

MEM_TOTAL_MB=$(( MEM_TOTAL_KB / 1024 ))
MEM_USED_MB=$(( MEM_USED_KB / 1024 ))

if (( MEM_TOTAL_MB > 0 )); then
    MEM_PERCENT=$(( MEM_USED_MB * 100 / MEM_TOTAL_MB ))
else
    MEM_PERCENT=0
fi

SWAP_TOTAL_KB="$(awk '/SwapTotal:/ {print $2}' /proc/meminfo)"
SWAP_FREE_KB="$(awk '/SwapFree:/ {print $2}' /proc/meminfo)"

SWAP_TOTAL_MB=$(( SWAP_TOTAL_KB / 1024 ))
SWAP_USED_MB=$(( (SWAP_TOTAL_KB - SWAP_FREE_KB) / 1024 ))

if (( SWAP_TOTAL_MB > 0 )); then
    SWAP_PERCENT=$(( SWAP_USED_MB * 100 / SWAP_TOTAL_MB ))
else
    SWAP_PERCENT=0
fi

read -r DISK_TOTAL DISK_USED DISK_PERCENT < <(
    df -h / 2>/dev/null \
        | awk 'NR==2 {
            gsub("%","",$5)
            print $2,$3,$5
        }'
)

DISK_TOTAL="${DISK_TOTAL:-N/A}"
DISK_USED="${DISK_USED:-N/A}"
DISK_PERCENT="${DISK_PERCENT:-0}"

PROCESS_COUNT="$(ps -e --no-headers 2>/dev/null | wc -l | tr -d ' ')"
PROCESS_COUNT="${PROCESS_COUNT:-0}"

ACTIVE_CONNECTIONS="$(
    ss -H -tun 2>/dev/null \
        | awk '$1 ~ /^(tcp|udp)$/ && $2 != "0" {count++}
               END {print count+0}'
)"
TOTAL_CONNECTIONS="$(ss -H -tun 2>/dev/null | wc -l | tr -d ' ')"
ACTIVE_CONNECTIONS="${ACTIVE_CONNECTIONS:-0}"
TOTAL_CONNECTIONS="${TOTAL_CONNECTIONS:-0}"

SSH_SESSIONS="$(who 2>/dev/null | awk '$1 != "" {count++} END {print count+0}')"
SSH_SESSIONS="${SSH_SESSIONS:-0}"

CRON_TASKS=0
if [[ -f /etc/crontab ]]; then
    CRON_TASKS=$(grep -Ev '^[[:space:]]*($|#)' /etc/crontab 2>/dev/null | wc -l | tr -d ' ')
fi
if [[ -d /etc/cron.d ]]; then
    CRON_TASKS=$(( CRON_TASKS + $(find /etc/cron.d -maxdepth 1 -type f -print0 2>/dev/null | xargs -0r grep -hEv '^[[:space:]]*($|#)' 2>/dev/null | wc -l) ))
fi
if command -v crontab >/dev/null 2>&1; then
    ROOT_CRON="$(crontab -l 2>/dev/null | grep -Ev '^[[:space:]]*($|#)' | wc -l | tr -d ' ')"
    CRON_TASKS=$(( CRON_TASKS + ROOT_CRON ))
fi
CRON_TASKS="${CRON_TASKS:-0}"

APT_UPDATES=0
if command -v apt >/dev/null 2>&1; then
    APT_UPDATES="$(apt list --upgradable 2>/dev/null | tail -n +2 | grep -c '/' 2>/dev/null)"
    APT_UPDATES="${APT_UPDATES:-0}"
fi

if systemctl is-active --quiet fail2ban 2>/dev/null; then
    STATUS_FAIL2BAN="${GREEN_B}RUNNING${NONE}"
else
    STATUS_FAIL2BAN="${RED_B}STOPPED${NONE}"
fi

SSH_JAIL_EXISTS=0
SSH_BANNED=0

if command -v fail2ban-client >/dev/null 2>&1 && systemctl is-active --quiet fail2ban 2>/dev/null; then
    if fail2ban-client status sshd >/dev/null 2>&1; then
        SSH_JAIL_EXISTS=1
        SSH_BANNED="$(fail2ban-client status sshd 2>/dev/null | awk -F': ' '/Currently banned/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
        SSH_BANNED="${SSH_BANNED:-0}"
    fi
fi

if (( SSH_JAIL_EXISTS == 1 )); then
    STATUS_SSH_JAIL="${GREEN_B}OK${NONE} | banned: ${SSH_BANNED}"
else
    STATUS_SSH_JAIL="${RED_B}STOPPED${NONE}"
fi

if command -v fail2ban-client >/dev/null 2>&1 && systemctl is-active --quiet fail2ban 2>/dev/null && fail2ban-client status recidive >/dev/null 2>&1; then
    STATUS_RECIDIVE="${GREEN_B}OK${NONE}"
else
    STATUS_RECIDIVE="${GRAY}N/A${NONE}"
fi

if iptables -C INPUT -m set --match-set SCANNERS-BLOCK-V4 src -j DROP >/dev/null 2>&1; then
    ANTISCAN_STATUS="${GREEN_B}RUN${NONE}"
elif ipset list SCANNERS-BLOCK-V4 >/dev/null 2>&1; then
    ANTISCAN_STATUS="${YELLOW_B}IDLE${NONE}"
elif systemctl is-enabled --quiet antiscan.service 2>/dev/null; then
    ANTISCAN_STATUS="${YELLOW_B}STOPPED${NONE}"
else
    ANTISCAN_STATUS="${GRAY}NOT INSTALLED${NONE}"
fi

ANTISCAN_COUNT=0
if command -v ipset >/dev/null 2>&1 && ipset list SCANNERS-BLOCK-V4 >/dev/null 2>&1; then
    ANTISCAN_COUNT="$(ipset list SCANNERS-BLOCK-V4 2>/dev/null | awk '/Number of entries:/ {print $4; exit}')"
    if [[ -z "$ANTISCAN_COUNT" || "$ANTISCAN_COUNT" -eq 0 ]]; then
        ANTISCAN_COUNT="$(ipset list SCANNERS-BLOCK-V4 2>/dev/null | awk '/^[0-9]+\./ {count++} END {print count+0}')"
    fi
fi
if [[ -z "$ANTISCAN_COUNT" || "$ANTISCAN_COUNT" -eq 0 ]] && [[ -f /etc/antiscan/blocked_count ]]; then
    ANTISCAN_COUNT="$(cat /etc/antiscan/blocked_count 2>/dev/null)"
fi
ANTISCAN_COUNT="${ANTISCAN_COUNT:-0}"

ANTISCAN_LAST="N/A"
if [[ -f /etc/antiscan/last_update ]]; then
    ANTISCAN_LAST="$(cat /etc/antiscan/last_update 2>/dev/null)"
elif [[ -f /etc/antiscan/blacklist.txt ]]; then
    ANTISCAN_LAST="$(date -r /etc/antiscan/blacklist.txt '+%Y-%m-%d %H:%M' 2>/dev/null)"
fi

if systemctl is-active --quiet x-ui 2>/dev/null; then
    STATUS_XUI="${GREEN_B}RUNNING${NONE}"
elif systemctl is-active --quiet 3x-ui 2>/dev/null; then
    STATUS_XUI="${GREEN_B}RUNNING${NONE}"
else
    STATUS_XUI="${RED_B}STOPPED${NONE}"
fi

if systemctl is-active --quiet nginx 2>/dev/null; then
    STATUS_NGINX="${GREEN_B}RUNNING${NONE}"
else
    STATUS_NGINX="${RED_B}STOPPED${NONE}"
fi

WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"

if systemctl is-active --quiet warp-svc 2>/dev/null; then
    if ss -lnt 2>/dev/null | grep -q ":${WARP_PROXY_PORT}[[:space:]]"; then
        STATUS_WARP="${GREEN_B}RUNNING${NONE} (SOCKS5 :${WARP_PROXY_PORT})"
    else
        STATUS_WARP="${GREEN_B}RUNNING${NONE}"
    fi
elif command -v warp-cli >/dev/null 2>&1; then
    WARP_STATE="$(warp-cli status 2>/dev/null | tr '\n' ' ')"
    if echo "$WARP_STATE" | grep -qi "Connected"; then
        STATUS_WARP="${GREEN_B}RUNNING${NONE}"
    else
        STATUS_WARP="${RED_B}STOPPED${NONE}"
    fi
else
    STATUS_WARP="${GRAY}NOT INSTALLED${NONE}"
fi

if [[ "${INSTALL_POSTGRES:-0}" == "1" ]]; then
    if systemctl list-unit-files 2>/dev/null | grep -q '^postgresql\.service'; then
        if systemctl is-active --quiet postgresql 2>/dev/null; then
            STATUS_POSTGRES="${GREEN_B}RUNNING${NONE}"
        else
            STATUS_POSTGRES="${RED_B}STOPPED${NONE}"
        fi
    else
        STATUS_POSTGRES="${RED_B}STOPPED${NONE}"
    fi
else
    STATUS_POSTGRES="${GRAY}NOT INSTALLED${NONE}"
fi

if [[ "${INSTALL_MSSQL:-0}" == "1" ]]; then
    if systemctl list-unit-files 2>/dev/null | grep -q '^mssql-server\.service'; then
        if systemctl is-active --quiet mssql-server 2>/dev/null; then
            STATUS_MSSQL="${GREEN_B}RUNNING${NONE}"
        else
            STATUS_MSSQL="${RED_B}STOPPED${NONE}"
        fi
    else
        STATUS_MSSQL="${RED_B}STOPPED${NONE}"
    fi
else
    STATUS_MSSQL="${GRAY}NOT INSTALLED${NONE}"
fi

if [[ "${INSTALL_TORRSERVER:-0}" == "1" ]]; then
    if systemctl is-active --quiet torrserver 2>/dev/null; then
        STATUS_TORRSERVER="${GREEN_B}RUNNING${NONE}"
    elif systemctl list-unit-files 2>/dev/null | grep -q '^torrserver\.service'; then
        STATUS_TORRSERVER="${RED_B}STOPPED${NONE}"
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -qi '^torrserver$'; then
        STATUS_TORRSERVER="${GREEN_B}RUNNING (Docker)${NONE}"
    else
        STATUS_TORRSERVER="${RED_B}STOPPED${NONE}"
    fi
else
    STATUS_TORRSERVER="${GRAY}NOT INSTALLED${NONE}"
fi

AMNEZIA_CONTAINER="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^amnezia-' | head -n1)"
if [[ -n "$AMNEZIA_CONTAINER" ]]; then
    STATUS_AMNEZIA="${GREEN_B}RUNNING (Docker)${NONE}"
else
    AMNEZIA_EXISTS="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^amnezia-' | head -n1)"
    if [[ -n "$AMNEZIA_EXISTS" ]]; then
        STATUS_AMNEZIA="${RED_B}STOPPED (Docker)${NONE}"
    else
        STATUS_AMNEZIA="${GRAY}NOT INSTALLED${NONE}"
    fi
fi

DOCKER_COUNT=0
if command -v docker >/dev/null 2>&1; then
    DOCKER_COUNT="$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')"
    DOCKER_COUNT="${DOCKER_COUNT:-0}"
fi

echo
printf "┌%s┐\n" "$LINE"
printf "  %bСЕРВЕР ПОДКЛЮЧЕН СТАБИЛЬНО%b\n" "$GREEN_B" "$NONE"
printf "  Uptime: %s\n" "$UPTIME_TEXT"
printf "├%s┤\n" "$LINE"
printf "  %bМЕТРИКИ СИСТЕМЫ:%b\n" "$CYAN_B" "$NONE"
printf "    %-22s : %s (Pub: %s)\n" "IPv4 адреса" "$LOCAL_IPV4" "$PUB_IP"
printf "    %-22s : %sMB / %sMB (%s%%)\n" "Оперативная память" "$MEM_USED_MB" "$MEM_TOTAL_MB" "$MEM_PERCENT"
printf "    %-22s : %sMB / %sMB (%s%%)\n" "Swap" "$SWAP_USED_MB" "$SWAP_TOTAL_MB" "$SWAP_PERCENT"
printf "    %-22s : %s / %s (%s%%)\n" "Диск (/)" "$DISK_USED" "$DISK_TOTAL" "$DISK_PERCENT"
printf "    %-22s : %s\n" "Всего процессов" "$PROCESS_COUNT"
printf "    %-22s : %s (Всего: %s)\n" "Активные соединения" "$ACTIVE_CONNECTIONS" "$TOTAL_CONNECTIONS"
printf "    %-22s : %s\n" "SSH-сессии" "$SSH_SESSIONS"
printf "    %-22s : %s\n" "Cron задачи" "$CRON_TASKS"
printf "    %-22s : %s\n" "Обновления APT" "$APT_UPDATES"
printf "├%s┤\n" "$LINE"
printf "  %bСТАТУС СЛУЖБ:%b\n" "$PURPLE" "$NONE"

printf "    %-22s : %b\n" "AntiScanner" "$ANTISCAN_STATUS"
if [[ "$ANTISCAN_STATUS" != *"NOT INSTALLED"* ]]; then
    printf "      %-20s : %s\n" "Blocked IPs" "$ANTISCAN_COUNT"
    printf "      %-20s : %s\n" "Last update" "$ANTISCAN_LAST"
fi

printf "    %-22s : %b\n" "Fail2ban" "$STATUS_FAIL2BAN"
printf "      %-20s : %b\n" "SSH jail" "$STATUS_SSH_JAIL"
printf "      %-20s : %b\n" "recidive" "$STATUS_RECIDIVE"
printf "    %-22s : %b\n" "3x-ui / Xray" "$STATUS_XUI"
printf "    %-22s : %b\n" "Amnezia VPN" "$STATUS_AMNEZIA"
printf "    %-22s : %b\n" "Nginx" "$STATUS_NGINX"
printf "    %-22s : %b\n" "Cloudflare WARP" "$STATUS_WARP"
printf "    %-22s : %b\n" "PostgreSQL" "$STATUS_POSTGRES"
printf "    %-22s : %b\n" "MS SQL Server" "$STATUS_MSSQL"
printf "    %-22s : %b\n" "TorrServer" "$STATUS_TORRSERVER"
printf "├%s┤\n" "$LINE"
printf "  %bDOCKER:%b\n" "$CYAN_B" "$NONE"
printf "    %-22s : %s\n" "Активные контейнеры" "$DOCKER_COUNT"

if (( DOCKER_COUNT > 0 )); then
    printf "%s\n" "$(docker ps --format 'NAMES          STATUS       PORTS\n{{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | sed 's/\t/   /g')"
fi

printf "└%s┘\n" "$LINE"
echo

exit 0
EOF_MOTD

chmod +x /etc/update-motd.d/99-custom-sysinfo

if [[ ! -x "$MOTD_FILE" ]]; then
    echo "⚠️ Ошибка: $MOTD_FILE не создан или не исполняемый."
else
    echo "✓ Создан единый MOTD: $MOTD_FILE"
fi

if bash -n "$MOTD_FILE"; then
    echo "✓ Синтаксис MOTD: OK"
else
    echo "❌ Ошибка синтаксиса MOTD: $MOTD_FILE"
fi

MOTD_FILES="$(find "$MOTD_DIR" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort)"
if [[ "$MOTD_FILES" == "99-custom-sysinfo" ]]; then
    echo "✓ Каталог $MOTD_DIR очищен."
    echo "✓ Единственный MOTD: 99-custom-sysinfo"
else
    echo "⚠️ В $MOTD_DIR остались файлы:"
    printf '%s\n' "$MOTD_FILES"
fi

echo "✓ MOTD установлен."

###############################################################################
# 12. ФИНАЛЬНАЯ ПРОВЕРКА И МАРКЕР ЗАВЕРШЕНИЯ
###############################################################################

echo
echo "======================================================================"
echo " ✅ ФИНАЛЬНАЯ ПРОВЕРКА"
echo "======================================================================"

check_item() {
    local label="$1"
    local condition="$2"
    printf "%-24s : " "$label"
    if eval "$condition"; then
        echo "OK"
    else
        echo "FAIL"
        FINAL_FAILURES=$((FINAL_FAILURES + 1))
    fi
    return 0
}

FINAL_FAILURES=0

check_item "Nginx" "systemctl is-active --quiet nginx"
check_item "SSH (:${SSH_PORT})" "ss -lnt | grep -qE ':${SSH_PORT}[[:space:]]'"
check_item "Cron" "systemctl is-active --quiet cron"
check_item "Fail2ban" "systemctl is-active --quiet fail2ban"
check_item "Fail2ban SSH jail" "fail2ban-client status sshd >/dev/null 2>&1"
check_item "AntiScanner service" "systemctl is-active --quiet antiscan.service"
check_item "AntiScanner ipset" "ipset list SCANNERS-BLOCK-V4 >/dev/null 2>&1"
check_item "AntiScanner rule" "iptables -C INPUT -m set --match-set SCANNERS-BLOCK-V4 src -j DROP >/dev/null 2>&1"
check_item "3x-ui service" "systemctl is-active --quiet x-ui"
check_item "Xray core process" "pgrep -af 'xray' >/dev/null 2>&1"

get_active_xray_ports() {
    [[ -f /etc/x-ui/x-ui.db ]] || return 0
    command -v sqlite3 >/dev/null 2>&1 || return 0
    sqlite3 /etc/x-ui/x-ui.db \
        "SELECT port FROM inbounds WHERE enable = 1 ORDER BY port;" \
        2>/dev/null | awk '/^[0-9]+$/ {print}'
}

ACTIVE_XRAY_PORTS=()
while IFS= read -r port; do
    [[ -n "$port" ]] && ACTIVE_XRAY_PORTS+=("$port")
done < <(get_active_xray_ports)

if [[ "${#ACTIVE_XRAY_PORTS[@]}" -eq 0 ]]; then
    echo "Xray Inbounds            : NONE (чистая база 3x-ui)"
else
    for port in "${ACTIVE_XRAY_PORTS[@]}"; do
        local_wait=0
        while ! ss -lnt 2>/dev/null | grep -qE ":${port}[[:space:]]" && [[ "$local_wait" -lt 25 ]]; do
            sleep 1
            local_wait=$((local_wait + 1))
        done
        check_item "Xray Port ${port}" "ss -lnt | grep -qE ':${port}[[:space:]]'"
        if ! ss -lnt 2>/dev/null | grep -qE ":${port}[[:space:]]"; then
            echo "    ⚠️ Лог ошибки ядра x-ui:"
            journalctl -u x-ui -n 15 --no-pager 2>/dev/null | sed "s/^/      /" || true
        fi
    done
fi

if [[ "$INSTALL_WARP" == "1" ]]; then
    check_item "WARP SOCKS5 (:${WARP_PROXY_PORT})" "ss -lnt | grep -qE ':${WARP_PROXY_PORT}[[:space:]]'"
elif [[ "$WARP_MANDATORY" == "1" ]]; then
    echo "WARP SOCKS5              : FAIL (отключён при обязательном режиме)"
    FINAL_FAILURES=$((FINAL_FAILURES + 1))
else
    echo "WARP SOCKS5              : DISABLED"
fi

check_item "UFW Firewall" "ufw status | grep -q 'Status: active'"

if [[ "$DISABLE_IPV6" == "1" ]]; then
    check_item "IPv6 Disabled" "[[ \"$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)\" == \"1\" ]]"
fi

if [[ "$FINAL_FAILURES" -ne 0 ]]; then
    echo
    echo "❌ РАЗВЕРТЫВАНИЕ НЕ ЗАВЕРШЕНО: Ошибок обязательных служб: ${FINAL_FAILURES}"
    echo "   Маркер ${BOOTSTRAP_MARKER} НЕ создаётся."
    exit 1
fi

touch "$BOOTSTRAP_MARKER"
SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"

echo
echo "======================================================================"
echo " ☁️ VPS УСПЕШНО НАСТРОЕН"
echo "======================================================================"
echo "IP VPS           : ${SERVER_IP:-unknown}"
echo "SSH Порт         : ${SSH_PORT}"
echo "Панель 3x-ui     : ${XUI_PORT}"
echo "WARP SOCKS5      : 127.0.0.1:${WARP_PROXY_PORT}"
echo "IPv6             : $( [[ "$DISABLE_IPV6" == "1" ]] && echo "Отключен" || echo "Включен" )"
echo "BBR              : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "default")"
echo "Xray Inbounds    : ${ACTIVE_XRAY_PORTS[*]:-нет активных}"
echo "======================================================================"
echo " ✅ Завершено: $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================================"
echo
