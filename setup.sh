#!/usr/bin/env bash

###############################################################################
# ☁️ VPS BOOTSTRAP / SETUP
# Версия: 4.0.0 (Production-Ready with VPS IP Guard)
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

SCRIPT_VERSION="4.0.0-vps-ip-guard"
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
for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE_BOOTSTRAP=1 ;;
    esac
done

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
    echo " ⚠️ ВНИМАНИЕ: Сервер уже был настроен ранее!"
    echo " Маркер: ${BOOTSTRAP_MARKER}"
    echo "======================================================================"
    echo
    if [[ -r /dev/tty ]]; then
        read -rp "Выполнить повторную принудительную настройку сервера? [y/N]: " force_confirm </dev/tty || force_confirm=""
        case "${force_confirm,,}" in
            y|yes)
                echo ">>> Повторный запуск подтверждён (FORCE_BOOTSTRAP=1)."
                FORCE_BOOTSTRAP=1
                ;;
            *)
                echo "Отмена. Конфигурация сервера не изменялась."
                exit 0
                ;;
        esac
    else
        echo "Для повторного запуска используйте: FORCE_BOOTSTRAP=1 bash $0 (или флаг --force)"
        exit 0
    fi
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
# 5.2. VPS IP GUARD
###############################################################################

echo ">>> Настройка VPS IP Guard..."

IP_GUARD_DIR="/etc/vps-ip-guard"
IP_GUARD_CONF="${IP_GUARD_DIR}/ip-guard.conf"
IP_GUARD_MANUAL="${IP_GUARD_DIR}/manual.list"
IP_GUARD_CACHE="${IP_GUARD_DIR}/cache"
IP_GUARD_STATE="${IP_GUARD_DIR}/state"
IP_GUARD_BIN="/usr/local/sbin/ip-guard"

mkdir -p "$IP_GUARD_DIR" "$IP_GUARD_CACHE" "$IP_GUARD_STATE" /usr/local/sbin
[[ ! -f "$IP_GUARD_MANUAL" ]] && touch "$IP_GUARD_MANUAL"

if [[ ! -f "$IP_GUARD_CONF" ]]; then
    cat > "$IP_GUARD_CONF" <<'EOF_IPGUARD_CONF'
# ==============================================================================
# /etc/vps-ip-guard/ip-guard.conf
# Конфигурационный файл для VPS IP Guard
# ==============================================================================

# Поддержка протоколов: true, false или "auto"
ENABLE_IPV4=true
ENABLE_IPV6="auto"

# Имена ipset наборов и цепочки iptables
SET_V4="VPS-IP-GUARD-V4"
SET_V6="VPS-IP-GUARD-V6"
CHAIN_NAME="VPS-IP-GUARD"

# Параметры ipset
IPSET_HASHSIZE=16384
IPSET_MAXELEM=262144

# Источники списков блокировок (shadow-netlab/traffic-guard-lists)
SOURCE_GOVERNMENT_URL="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/government_networks.list"
SOURCE_SCANNER_URL="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list"
SOURCE_SKIPA_URL="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/skipa.list"

# Таймауты скачивания (в секундах)
CURL_CONNECT_TIMEOUT=10
CURL_MAX_TIME=60

# Минимально допустимый суммарный порог сетей для успешного swap
MIN_TOTAL_NETWORKS=50
EOF_IPGUARD_CONF
    chmod 644 "$IP_GUARD_CONF"
fi

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

# Запуск первичной установки и инициализации
"$IP_GUARD_BIN" install

systemctl daemon-reload
systemctl enable vps-ip-guard.service
systemctl start vps-ip-guard.service
systemctl enable --now vps-ip-guard-update.timer

if ! ipset list VPS-IP-GUARD-V4 >/dev/null 2>&1; then
    echo "❌ VPS IP Guard ipset не создан."
    exit 1
fi
if ! iptables -C INPUT -j VPS-IP-GUARD >/dev/null 2>&1; then
    echo "❌ VPS IP Guard правило DROP не установлено."
    exit 1
fi

echo "✓ VPS IP Guard активирован: ipset VPS-IP-GUARD-V4, цепочка VPS-IP-GUARD."

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
    local db_dir="databases"
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
        echo "  4) Ввести другое имя файла из databases/"
        echo
        read -rp "Выбор [0-4]: " reg_choice </dev/tty || true
    fi

    reg_choice="${reg_choice:-0}"

    case "$reg_choice" in
        0)
            echo "  [i] Выбрана чистая установка."
            return 0
            ;;
        1)
            db_file="databases/lv-x-ui.db"
            ;;
        2)
            db_file="databases/mw-x-ui.db"
            ;;
        3)
            db_file="databases/tr-x-ui.db"
            ;;
        4)
            local custom_name=""
            read -rp "Введите имя файла базы (например, de-x-ui.db): " custom_name </dev/tty || custom_name=""
            custom_name="$(echo "$custom_name" | tr -d '[:space:]')"
            if [[ -z "$custom_name" ]]; then
                echo "❌ Имя файла не указано."
                return 0
            fi
            custom_name="${custom_name#databases/}"
            [[ "$custom_name" != *.db ]] && custom_name="${custom_name}.db"
            db_file="databases/${custom_name}"
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

mkdir -p "$(dirname "$downloaded")"
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

# 5.1. Обновление VPS IP Guard (ежедневно 04:15)
15 4 * * * root /usr/local/sbin/ip-guard update >> /var/log/vps-ip-guard.log 2>&1

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

if iptables -C INPUT -j VPS-IP-GUARD >/dev/null 2>&1; then
    STATUS_IPGUARD="${GREEN_B}RUN${NONE}"
elif ipset list VPS-IP-GUARD-V4 >/dev/null 2>&1; then
    STATUS_IPGUARD="${YELLOW_B}IDLE${NONE}"
elif systemctl is-active --quiet vps-ip-guard.service 2>/dev/null; then
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

printf "    %-22s : %b\n" "VPS IP Guard" "$STATUS_IPGUARD"
if [[ "$STATUS_IPGUARD" != *"NOT INSTALLED"* ]]; then
    printf "      %-20s : %s\n" "Blocked Networks" "$IPGUARD_COUNT"
    printf "      %-20s : %s\n" "Last update" "$IPGUARD_LAST"
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
check_item "IP Guard service" "systemctl is-active --quiet vps-ip-guard.service"
check_item "IP Guard timer" "systemctl is-active --quiet vps-ip-guard-update.timer"
check_item "IP Guard ipset" "ipset list VPS-IP-GUARD-V4 >/dev/null 2>&1"
check_item "IP Guard rule" "iptables -C INPUT -j VPS-IP-GUARD >/dev/null 2>&1"
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
echo "VPS IP Guard     : ip-guard {status|update|ban|unban|list|reload}"
echo "Xray Inbounds    : ${ACTIVE_XRAY_PORTS[*]:-нет активных}"
echo "======================================================================"
echo " ✅ Завершено: $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================================"
echo
