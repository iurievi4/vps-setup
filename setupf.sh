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

SCRIPT_VERSION="3.9.8"
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

EFFECTIVE_SSH_PORT="$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}')"
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

# AntiScanner используется как отдельный слой фильтрации известных сетей
# сканеров. Код внешнего установщика не выполняем: скачиваем только список
# подсетей и применяем его через ipset + один DROP в INPUT.
ANTISCAN_URL="https://gist.githubusercontent.com/sngvy/07cee7ac810c9d222fbebddff8c1d1b8/raw/974d3d87f190468e134e9b56f1e0a93c7caa0fcd/blacklist.txt"
ANTISCAN_SET="SCANNERS-BLOCK-V4"
ANTISCAN_SCRIPT="/usr/local/sbin/antiscan-update.sh"
ANTISCAN_LOG="/var/log/antiscan-update.log"

echo ">>> Настройка AntiScanner..."

cat > /etc/default/antiscan <<EOF_ANTISCAN_CONF
ANTISCAN_URL="${ANTISCAN_URL}"
ANTISCAN_SET="${ANTISCAN_SET}"
ANTISCAN_LOG="${ANTISCAN_LOG}"
EOF_ANTISCAN_CONF
chmod 600 /etc/default/antiscan

cat > "$ANTISCAN_SCRIPT" <<'EOF_ANTISCAN'
#!/usr/bin/env bash
set -Eeuo pipefail

source /etc/default/antiscan
URL="$ANTISCAN_URL"
SET_NAME="$ANTISCAN_SET"
TMP_FILE="/run/antiscan-blacklist.txt"
LOG="$ANTISCAN_LOG"

mkdir -p "$(dirname "$LOG")"
exec >> "$LOG" 2>&1

log() { echo "[$(date '+%F %T')] $*"; }

command -v ipset >/dev/null 2>&1 || { log "ERROR: ipset not found"; exit 1; }
command -v curl >/dev/null 2>&1 || { log "ERROR: curl not found"; exit 1; }
command -v iptables >/dev/null 2>&1 || { log "ERROR: iptables not found"; exit 1; }

mkdir -p /run

if ! curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 -o "${TMP_FILE}.new" "$URL"; then
    rm -f "${TMP_FILE}.new"
    log "ERROR: failed to download blacklist"
    exit 1
fi

# Минимальная защита от подмены/битого ответа: нужен хотя бы один CIDR.
if ! grep -Eq '^[[:space:]]*[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?[[:space:]]*$' "${TMP_FILE}.new"; then
    rm -f "${TMP_FILE}.new"
    log "ERROR: downloaded blacklist contains no valid IPv4 networks"
    exit 1
fi

mv -f "${TMP_FILE}.new" "$TMP_FILE"

# Атомарно обновляем отдельный ipset через временный набор.
TMP_SET="${SET_NAME}-TMP"
ipset destroy "$TMP_SET" 2>/dev/null || true
ipset create "$TMP_SET" hash:net family inet hashsize 4096 maxelem 65536

valid=0
while IFS= read -r subnet; do
    subnet="${subnet%%$'\r'}"
    [[ -z "$subnet" || "$subnet" =~ ^[[:space:]]*# ]] && continue
    if ipset add "$TMP_SET" "$subnet" -exist 2>/dev/null; then
        valid=$((valid + 1))
    fi
done < "$TMP_FILE"

if [[ "$valid" -eq 0 ]]; then
    ipset destroy "$TMP_SET" 2>/dev/null || true
    log "ERROR: no valid IPv4 networks loaded"
    exit 1
fi

# Атомарно подменяем рабочий набор. Важно: рабочий set уже используется
# правилом iptables, поэтому его нельзя просто destroy/создать заново.
if ipset list "$SET_NAME" >/dev/null 2>&1; then
    ipset swap "$TMP_SET" "$SET_NAME"
    ipset destroy "$TMP_SET" 2>/dev/null || true
else
    ipset rename "$TMP_SET" "$SET_NAME"
fi

# Ставим правило в начало INPUT, чтобы AntiScanner срабатывал до UFW allow.
if ! iptables -C INPUT -m set --match-set "$SET_NAME" src -j DROP 2>/dev/null; then
    iptables -I INPUT 1 -m set --match-set "$SET_NAME" src -j DROP
fi

# Набор и правило восстанавливаются при загрузке через antiscan.service.
count="$(ipset list "$SET_NAME" -o save 2>/dev/null | grep -c '^add ' || true)"
log "OK: loaded ${valid} networks; ipset entries=${count}"
EOF_ANTISCAN

chmod 700 "$ANTISCAN_SCRIPT"

# Отдельный systemd unit: восстанавливает AntiScanner после загрузки/UFW.
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
        0) echo "  [i] Выбрана чистая установка."; return 0 ;;
        1) db_file="lv-x-ui.db" ;;
        2) db_file="mw-x-ui.db" ;;
        3) db_file="tr-x-ui.db" ;;
        *) echo "❌ Некорректный выбор: '${reg_choice}'"; return 1 ;;
    esac

    if [[ -z "$token" ]] && [[ -r /dev/tty ]]; then
        read -rsp "Введите GitHub Token: " token </dev/tty || true
        echo
    fi
    [[ -z "$token" ]] && { echo "❌ GitHub Token не указан."; return 1; }

    if [[ -z "$db_pass" ]] && [[ -r /dev/tty ]]; then
        read -rsp "Введите мастер-пароль базы: " db_pass </dev/tty || true
        echo
    fi
    [[ -z "$db_pass" ]] && { echo "❌ Пароль базы не указан."; return 1; }

    systemctl stop x-ui 2>/dev/null || true
    /usr/local/sbin/xui-backup.sh 2>/dev/null || true

    local tmp_db="/tmp/${db_file}"
    rm -f "$tmp_db"

    local http_code
    http_code="$(curl -4 -sS -w "%{http_code}" -H "Authorization: Bearer ${token}" -H "Accept: application/vnd.github.raw+json" --connect-timeout 15 --max-time 300 -o "$tmp_db" "https://api.github.com/repos/${repo}/contents/${db_file}")"

    if [[ "$http_code" != "200" ]] || [[ ! -s "$tmp_db" ]]; then
        echo "❌ Ошибка скачивания базы (HTTP: ${http_code})."
        rm -f "$tmp_db"
        systemctl start x-ui
        return 1
    fi

    local decrypted_db="/tmp/x-ui-restored.db"
    rm -f "$decrypted_db"

    if openssl enc -d -aes-256-cbc -pbkdf2 -in "$tmp_db" -pass pass:"$db_pass" 2>/dev/null | tar -xzf - -O > "$decrypted_db" 2>/dev/null; then
        if [[ ! -s "$decrypted_db" ]] || ! sqlite3 "$decrypted_db" "PRAGMA integrity_check;" 2>/dev/null | grep -qx "ok"; then
            echo "❌ Ошибка integrity_check SQLite."
            rm -f "$tmp_db" "$decrypted_db"
            systemctl start x-ui
            return 1
        fi

        install -o root -g root -m 600 "$decrypted_db" /etc/x-ui/x-ui.db
        sqlite3 /etc/x-ui/x-ui.db "UPDATE client_traffics SET up = 0, down = 0;" 2>/dev/null || true
        sqlite3 /etc/x-ui/x-ui.db "UPDATE inbounds SET up = 0, down = 0;" 2>/dev/null || true
        sqlite3 /etc/x-ui/x-ui.db "DELETE FROM inbound_client_ips;" 2>/dev/null || true
        echo "✓ База ${db_file} установлена, счетчики трафика обнулены."
        rm -f "$tmp_db" "$decrypted_db"
    else
        echo "❌ Ошибка расшифровки (неверный пароль)."
        rm -f "$tmp_db" "$decrypted_db"
        systemctl start x-ui
        return 1
    fi

    systemctl restart x-ui
    sleep 5
    systemctl is-active --quiet x-ui
}

# 9. СКРИПТЫ ОБСЛУЖИВАНИЯ (BACKUP, HEALTH, UPDATE)
mkdir -p /usr/local/x-ui/bin "$BACKUP_DIR" "$PRE_UPDATE_DIR"
chmod 700 "$BACKUP_DIR" "$PRE_UPDATE_DIR"


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

# Строгая проверка читаемости архива
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

    # Базовая валидация скачанного скрипта
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

# Запуск восстановления эталонной базы
restore_custom_database

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

# 5.1. Обновление AntiScanner (ежедневно 05:30)
30 5 * * * root /usr/local/sbin/antiscan-update.sh

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

echo ">>> Установка быстрого эксплуатационного MOTD..."

# Отключаем стандартный шум Ubuntu/Debian MOTD.
shopt -s nullglob
for motd_file in /etc/update-motd.d/*; do
    [[ "$(basename "$motd_file")" == "99-custom-sysinfo" ]] && continue
    chmod -x "$motd_file" 2>/dev/null || true
done
shopt -u nullglob
systemctl disable --now motd-news.service motd-news.timer 2>/dev/null || true
rm -f /var/lib/ubuntu-release-upgrader/release-upgrade-motd 2>/dev/null || true

# Сохраняем параметры bootstrap для MOTD и последующей диагностики.
cat > /etc/default/vps-bootstrap <<EOF_BOOTSTRAP
INSTALL_POSTGRES=${INSTALL_POSTGRES}
INSTALL_MSSQL=${INSTALL_MSSQL}
INSTALL_TORRSERVER=${INSTALL_TORRSERVER}
INSTALL_WARP=${INSTALL_WARP}
WARP_PROXY_PORT=${WARP_PROXY_PORT}
XUI_PORT=${XUI_PORT}
EOF_BOOTSTRAP
chmod 600 /etc/default/vps-bootstrap

# Создаем файл с паролем MSSQL, если он действительно нужен.
if [[ "$INSTALL_MSSQL" == "1" && ! -f "$MSSQL_SA_PASSWORD_FILE" ]]; then
    umask 077
    { echo 'Aa1!'; openssl rand -hex 24; } | tr -d '\n' > "$MSSQL_SA_PASSWORD_FILE"
    chmod 600 "$MSSQL_SA_PASSWORD_FILE"
fi



cat > /etc/update-motd.d/99-custom-sysinfo <<'EOF'
#!/bin/bash

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

# --- Сетевые соединения (чистый вывод чисел) ---
CONN_ESTAB=$(ss -tun -a 2>/dev/null | awk '/ESTAB/ {c++} END {print c+0}')
CONN_TOTAL=$(ss -tun -a 2>/dev/null | awk 'NR>1 {c++} END {print c+0}')

# --- Память ---
MEM_TOTAL=$(free -m 2>/dev/null | awk '/Mem:/ {print $2}')
MEM_USED=$(free -m 2>/dev/null | awk '/Mem:/ {print $3}')
[ -n "$MEM_TOTAL" ] && [ "$MEM_TOTAL" -gt 0 ] && MEM_PCT=$((MEM_USED * 100 / MEM_TOTAL)) || MEM_PCT=0

# --- Swap ---
SWAP_TOTAL=$(free -m 2>/dev/null | awk '/Swap:/ {print $2}')
SWAP_USED=$(free -m 2>/dev/null | awk '/Swap:/ {print $3}')
[ -n "$SWAP_TOTAL" ] && [ "$SWAP_TOTAL" -gt 0 ] && SWAP_PCT=$((SWAP_USED * 100 / SWAP_TOTAL)) || SWAP_PCT=0

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

# Fail2ban
if systemctl is-active --quiet fail2ban 2>/dev/null; then
    STATUS_FAIL2BAN="${GREEN_B}RUNNING${NONE}"
else
    STATUS_FAIL2BAN="${RED_B}STOPPED${NONE}"
fi

# Fail2ban SSH jail
if systemctl is-active --quiet fail2ban 2>/dev/null && \
   fail2ban-client status sshd >/dev/null 2>&1; then
    F2B_BANNED="$(fail2ban-client status sshd 2>/dev/null | \
        awk -F: '/Currently banned:/ {
            gsub(/^[[:space:]]+/, "", $2)
            print $2
            exit
        }')"
    F2B_BANNED="${F2B_BANNED:-0}"
    STATUS_SSH_JAIL="${GREEN_B}OK | banned: ${F2B_BANNED}${NONE}"
else
    STATUS_SSH_JAIL="${RED_B}FAIL${NONE}"
fi

# AntiScanner
if systemctl is-active --quiet antiscan.service 2>/dev/null && \
   ipset list SCANNERS-BLOCK-V4 >/dev/null 2>&1 && \
   iptables -C INPUT -m set --match-set SCANNERS-BLOCK-V4 src -j DROP >/dev/null 2>&1; then

    SCANNER_COUNT="$(ipset list SCANNERS-BLOCK-V4 2>/dev/null | \
        awk '/Number of entries:/ {print $4; exit}')"

    SCANNER_COUNT="${SCANNER_COUNT:-0}"
    STATUS_ANTISCAN="${GREEN_B}RUNNING | networks: ${SCANNER_COUNT}${NONE}"
else
    STATUS_ANTISCAN="${RED_B}STOPPED${NONE}"
fi

# WARP (только локальная проверка)
if ss -lnt 2>/dev/null | grep -qE ":${WARP_PROXY_PORT}[[:space:]]"; then
    STATUS_WARP="${GREEN_B}RUNNING (SOCKS5 :${WARP_PROXY_PORT})${NONE}"
elif systemctl is-active --quiet warp-svc 2>/dev/null; then
    STATUS_WARP="${YELLOW}CONNECTING (warp-svc)${NONE}"
else
    STATUS_WARP="${RED_B}STOPPED${NONE}"
fi

if [[ "$INSTALL_POSTGRES" == "1" ]]; then
    STATUS_POSTGRES=$(pg_isready >/dev/null 2>&1 && echo -e "${GREEN_B}RUNNING${NONE}" || echo -e "${RED_B}STOPPED${NONE}")
else
    STATUS_POSTGRES="${YELLOW}NOT INSTALLED${NONE}"
fi

if [[ "$INSTALL_TORRSERVER" == "1" ]]; then
    STATUS_TORRSERVER=$(check_service torrserver)
else
    STATUS_TORRSERVER="${YELLOW}NOT INSTALLED${NONE}"
fi

# Проверка MS SQL через безопасный файл пароля
MSSQL_SA_PASSWORD_FILE="/root/.mssql-sa-password"
if [[ "$INSTALL_MSSQL" != "1" ]]; then
    STATUS_MSSQL="${YELLOW}NOT INSTALLED${NONE}"
elif docker ps --format '{{.Names}}' 2>/dev/null | grep -Eq "^mssql_server$"; then
    if [[ -r "$MSSQL_SA_PASSWORD_FILE" ]]; then
        MSSQL_SA_PASSWORD="$(<"$MSSQL_SA_PASSWORD_FILE")"
        if docker exec mssql_server /opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P "$MSSQL_SA_PASSWORD" -C -Q "SELECT 1" >/dev/null 2>&1; then
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

# Проверка Amnezia VPN в Docker
if docker ps --format '{{.Names}}' 2>/dev/null | grep -Eq "^amnezia-"; then
    STATUS_AMNEZIA="${GREEN_B}RUNNING (Docker)${NONE}"
else
    STATUS_AMNEZIA="${RED_B}STOPPED${NONE}"
fi

# --- Вывод ---
echo -e "${CYAN}┌────────────────────────────────────────────────────────────────────────┐${NONE}"
echo -e "  ${GREEN_B}СЕРВЕР ПОДКЛЮЧЕН СТАБИЛЬНО${NONE}"
echo -e "  Uptime: $UPTIME"
echo -e "${CYAN}├────────────────────────────────────────────────────────────────────────┤${NONE}"

echo -e "  ${PURPLE}МЕТРИКИ СИСТЕМЫ:${NONE}"
printf "    %-22s : %s (Pub: %s)\n" "IPv4 адреса" "$IP_LOCAL" "$IP_PUB"
printf "    %-22s : %sMB / %sMB (%s%%)\n" "Оперативная память" "$MEM_USED" "$MEM_TOTAL" "$MEM_PCT"
printf "    %-22s : %sMB / %sMB (%s%%)\n" "Swap" "$SWAP_USED" "$SWAP_TOTAL" "$SWAP_PCT"
printf "    %-22s : %s / %s (%s%%)\n" "Диск (/)" "$DISK_USED" "$DISK_TOTAL" "$DISK_PCT"
printf "    %-22s : %s\n" "Всего процессов" "$PROCESSES"
printf "    %-22s : %s (Всего: %s)\n" "Активные соединения" "$CONN_ESTAB" "$CONN_TOTAL"
printf "    %-22s : %s\n" "SSH-сессии" "$SSH_CONN"
printf "    %-22s : %s\n" "Cron задачи" "$CRON_COUNT"
printf "    %-22s : %s\n" "Обновления APT" "$UPDATES"

echo -e "${CYAN}├────────────────────────────────────────────────────────────────────────┤${NONE}"
echo -e "  ${PURPLE}СТАТУС СЛУЖБ:${NONE}"
printf "    %-22s : %b\n" "AntiScanner" "$STATUS_ANTISCAN"
printf "    %-22s : %b\n" "Fail2ban" "$STATUS_FAIL2BAN"
printf "    %-22s : %b\n" "3x-ui / Xray" "$STATUS_XUI"
printf "    %-22s : %b\n" "Nginx" "$STATUS_NGINX"
printf "    %-22s : %b\n" "Cloudflare WARP" "$STATUS_WARP"
printf "    %-22s : %b\n" "PostgreSQL" "$STATUS_POSTGRES"
printf "    %-22s : %b\n" "MS SQL Server" "$STATUS_MSSQL"
printf "    %-22s : %b\n" "TorrServer" "$STATUS_TORRSERVER"
printf "    %-22s : %b\n" "Amnezia VPN" "$STATUS_AMNEZIA"

echo -e "${CYAN}├────────────────────────────────────────────────────────────────────────┤${NONE}"
echo -e "  ${PURPLE}DOCKER:${NONE}"
printf "    %-22s : %s\n" "Активные контейнеры" "$DOCKER_COUNT"
if [[ -n "$DOCKER_LIST" ]]; then
    echo "$DOCKER_LIST"
else
    echo -e "    ${YELLOW}Нет активных контейнеров${NONE}"
fi

echo -e "${CYAN}└────────────────────────────────────────────────────────────────────────┘${NONE}"
echo
EOF

chmod +x /etc/update-motd.d/99-custom-sysinfo


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
        return 0
    else
        echo "FAIL"
        FINAL_FAILURES=$((FINAL_FAILURES + 1))
        return 1
    fi
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
        check_item "Xray Port ${port}" "ss -lnt | grep -qE ':${port}[[:space:]]'"
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

# Установка маркера успешного bootstrap
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
