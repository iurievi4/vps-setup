#!/usr/bin/env bash

###############################################################################
# ☁️ VPS BOOTSTRAP / SETUP
# Версия: 3.7.0
#
# Ubuntu / Debian
#
# Назначение:
#   Первичная настройка чистого VPS:
#   - Отключение IPv6 (sysctl + ufw)
#   - Nginx (:80 IPv4 only)
#   - BBR / FQ / TCP Fast Open
#   - SWAP (универсальная проверка)
#   - Cloudflare WARP CLI (SOCKS5 proxy :40000)
#   - UFW (порты: 1241, 80, 443, 2053, 2096, 8443, 8784, 54325)
#   - SSH :1241 (drop-in + поддержка Ubuntu 24.04 socket activation)
#   - 3x-ui (non-interactive, SQLite, SSL mode: ip)
#   - Опциональное восстановление эталонной базы (0 - чистая / 1 - LV / 2 - MW / 3 - TR)
#   - Резервные копии (ежедневные + pre-update)
#   - Безопасное автообновление 3x-ui с автоматическим rollback
#   - Healthcheck (x-ui + xray-core + строгая проверка портов 2053 И 8443)
#   - Обновление geo-файлов (v2fly + runetfreedom)
#   - Системное обслуживание в /etc/cron.d/
###############################################################################

set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

SCRIPT_VERSION="3.7.0"
LOG_FILE="/var/log/vps-setup.log"
SSH_PORT="1241"
XUI_PORT="8784"
ACME_PORT="80"
WARP_PROXY_PORT="40000"

XUI_INSTALL_URL="https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh"
XUI_UPDATE_URL="https://raw.githubusercontent.com/MHSanaei/3x-ui/main/update.sh"

BACKUP_DIR="/root/xui_backups"
PRE_UPDATE_DIR="${BACKUP_DIR}/pre-update"
MAINTENANCE_FILE="/etc/cron.d/vps-maintenance"


###############################################################################
# 1. ЛОГИРОВАНИЕ
###############################################################################

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

echo
echo "======================================================================"
echo " ☁️ VPS SETUP ${SCRIPT_VERSION}"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================================"
echo


###############################################################################
# 2. ОБРАБОТЧИК ОШИБОК
###############################################################################

on_error() {
    local exit_code=$?
    echo
    echo "======================================================================"
    echo " ❌ ОШИБКА УСТАНОВКИ"
    echo " Код: ${exit_code}"
    echo " Строка: ${BASH_LINENO[0]:-unknown}"
    echo " Команда: ${BASH_COMMAND:-unknown}"
    echo " Лог: ${LOG_FILE}"
    echo "======================================================================"
    echo
    exit "$exit_code"
}

trap on_error ERR


###############################################################################
# 3. ROOT
###############################################################################

if [[ "${EUID}" -ne 0 ]]; then
    echo "❌ Скрипт необходимо запускать от root."
    exit 1
fi


###############################################################################
# 4. ОС
###############################################################################

if [[ ! -f /etc/os-release ]]; then
    echo "❌ Не найден /etc/os-release."
    exit 1
fi

source /etc/os-release
echo "OS: ${PRETTY_NAME:-unknown}"

case "${ID:-}" in
    ubuntu|debian)
        ;;
    *)
        echo
        echo "❌ Поддерживаются Ubuntu/Debian."
        echo "Обнаружено: ${ID:-unknown}"
        echo
        exit 1
        ;;
esac


###############################################################################
# 5. АРХИТЕКТУРА
###############################################################################

ARCH="$(dpkg --print-architecture 2>/dev/null || true)"
echo "Архитектура: ${ARCH:-unknown}"


###############################################################################
# 6. APT
###############################################################################

echo
echo ">>> Обновление пакетов..."
apt-get update
apt-get upgrade -y


###############################################################################
# 7. БАЗОВЫЕ ПАКЕТЫ
###############################################################################

echo
echo ">>> Установка базовых пакетов..."

apt-get install -y \
    nginx \
    git \
    curl \
    wget \
    gnupg \
    cron \
    iproute2 \
    iputils-ping \
    lm-sensors \
    nvme-cli \
    iptables \
    ufw \
    socat \
    sqlite3 \
    ca-certificates \
    openssl \
    jq \
    unzip \
    lsof \
    procps \
    net-tools \
    util-linux


###############################################################################
# 8. CRON
###############################################################################

systemctl enable --now cron


###############################################################################
# 9. ОТКЛЮЧЕНИЕ IPV6
###############################################################################

echo
echo ">>> Отключение IPv6..."

cat > /etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
# Полное отключение IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

# Применяем отключение на все текущие интерфейсы
for iface in /proc/sys/net/ipv6/conf/*; do
    if [[ -d "$iface" ]]; then
        iface_name="$(basename "$iface")"
        sysctl -w "net.ipv6.conf.${iface_name}.disable_ipv6=1" >/dev/null 2>&1 || true
    fi
done

# Отключаем IPv6 в UFW
if [[ -f /etc/default/ufw ]]; then
    sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw
fi

echo "✓ IPv6 отключен."


###############################################################################
# 10. SYSCTL / BBR
###############################################################################

echo
echo ">>> Настройка TCP оптимизации..."

cat > /etc/sysctl.d/99-vps-optimization.conf <<'EOF'
# BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP Fast Open
net.ipv4.tcp_fastopen = 3

# TCP SYN cookies
net.ipv4.tcp_syncookies = 1

# IPv4 forwarding
net.ipv4.ip_forward = 1

# VM
vm.swappiness = 10
EOF

sysctl --system


###############################################################################
# 11. SWAP (УНИВЕРСАЛЬНАЯ ПРОВЕРКА)
###############################################################################

if ! swapon --show | grep -q .; then
    echo
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
else
    echo "✓ SWAP уже существует в системе."
fi

if ! swapon --show | grep -q .; then
    echo "❌ SWAP не удалось активировать."
    exit 1
fi
echo "✓ SWAP активен."


###############################################################################
# 12. CLOUDFLARE WARP (WARP-CLI SOCKS5 PROXY)
###############################################################################

echo
echo "======================================================================"
echo " 🌐 Установка и настройка Cloudflare WARP"
echo "======================================================================"

install_cloudflare_warp() {
    local keyring="/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg"
    local list_file="/etc/apt/sources.list.d/cloudflare-client.list"
    local codename="${VERSION_CODENAME:-noble}"

    echo ">>> Импорт GPG ключа Cloudflare..."
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | \
        gpg --yes --dearmor -o "$keyring"

    echo ">>> Подключение репозитория (${codename})..."
    echo "deb [signed-by=${keyring}] https://pkg.cloudflareclient.com/ ${codename} main" > "$list_file"

    apt-get update
    apt-get install -y cloudflare-warp

    echo ">>> Запуск службы warp-svc..."
    systemctl enable --now warp-svc
    sleep 3

    echo ">>> Регистрация и настройка warp-cli..."
    # Проверка существующей регистрации
    if ! warp-cli --accept-tos status 2>/dev/null | grep -qi "Registration missing"; then
        echo "Регистрация уже выполнена или обновляется..."
    fi

    warp-cli --accept-tos registration new 2>/dev/null || true
    warp-cli --accept-tos mode proxy
    warp-cli --accept-tos proxy port "$WARP_PROXY_PORT" 2>/dev/null || true
    warp-cli --accept-tos connect

    echo "Ожидание подключения WARP..."
    sleep 4

    echo ">>> Статус Cloudflare WARP:"
    warp-cli --accept-tos status || true

    echo ">>> Проверка маршрута через WARP SOCKS5 (порт ${WARP_PROXY_PORT}):"
    local trace_output
    if trace_output="$(curl --socks5 "127.0.0.1:${WARP_PROXY_PORT}" -fsSL --connect-timeout 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)"; then
        local warp_status
        warp_status="$(echo "$trace_output" | grep '^warp=' || true)"
        local warp_ip
        warp_ip="$(echo "$trace_output" | grep '^ip=' || true)"
        echo "✓ WARP SOCKS5 активен: ${warp_status}, ${warp_ip}"
    else
        echo "⚠️️ Внимание: WARP SOCKS5 пока не вернул ответ, служба продолжит работу в фоне."
    fi
}

install_cloudflare_warp


###############################################################################
# 13. NGINX (ТОЛЬКО IPV4)
###############################################################################

echo
echo ">>> Настройка Nginx..."

mkdir -p /var/www/acme/.well-known/acme-challenge
rm -f /etc/nginx/sites-enabled/default

# Убран сокет [::]:80 для корректной работы с отключенным IPv6
cat > /etc/nginx/sites-available/cloud-node <<'EOF'
server {
    listen 80 default_server;
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
# 14. MOTD
###############################################################################

echo
echo ">>> Настройка MOTD..."

cat > /etc/update-motd.d/99-custom-sysinfo <<'EOF'
#!/usr/bin/env bash

echo
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                      ☁️  CLOUD NODE                              ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo

echo "🕒 $(date '+%Y-%m-%d %H:%M:%S')"
echo "⏱ Uptime: $(uptime -p)"
echo

echo "🌐 NETWORK"
ip -4 -brief addr show scope global 2>/dev/null || true
echo

echo "🛡️ CLOUDFLARE WARP"
if ss -lnt 2>/dev/null | grep -qE ":40000[[:space:]]"; then
    WARP_IP="$(curl -s --socks5 127.0.0.1:40000 --max-time 1 https://api.ipify.org 2>/dev/null || true)"
    if [[ -n "$WARP_IP" ]]; then
        echo "  ✓ Активен (SOCKS5 127.0.0.1:40000 | IP: ${WARP_IP})"
    else
        echo "  ✓ Активен (SOCKS5 127.0.0.1:40000)"
    fi
elif command -v warp-cli >/dev/null 2>&1 && warp-cli --accept-tos status 2>/dev/null | grep -qi "Connected"; then
    echo "  ✓ Активен (Connected)"
else
    echo "  ✗ Не активен"
fi
echo

echo "📡 PING"
printf "Yandex: "
ping -c 1 -W 1 77.88.8.8 >/dev/null 2>&1 && echo "OK" || echo "FAIL"
echo

echo "🖥 SYSTEM"
echo "Load: $(cut -d' ' -f1-3 /proc/loadavg)"

if command -v sensors >/dev/null 2>&1; then
    CPU_TEMP="$(sensors 2>/dev/null | awk '/Package id 0:/ {print $4; exit}')"
    [[ -n "${CPU_TEMP}" ]] && echo "CPU: ${CPU_TEMP}"
fi

if command -v nvme >/dev/null 2>&1; then
    NVME_TEMP="$(nvme smart-log /dev/nvme0 2>/dev/null | awk -F: '/temperature/ {print $2; exit}' | xargs)"
    [[ -n "${NVME_TEMP}" ]] && echo "NVMe: ${NVME_TEMP}"
fi
echo

echo "💾 MEMORY"
free -h
echo

echo "💽 DISK"
df -h / | tail -n 1
echo

echo "📊 INODES"
df -ih / | tail -n 1
echo

echo "🔌 CONNECTIONS"
echo "TCP: $(ss -tan 2>/dev/null | tail -n +2 | wc -l)"
echo "UDP: $(ss -uan 2>/dev/null | tail -n +2 | wc -l)"
echo

echo "👤 SSH"
who 2>/dev/null || true
echo

echo "⚙️ SERVICES"
for service in nginx ssh x-ui warp-svc docker; do
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo "  ✓ ${service}"
    else
        echo "  ✗ ${service}"
    fi
done
echo

echo "📦 DOCKER"
if command -v docker >/dev/null 2>&1; then
    docker ps --format '  {{.Names}} — {{.Status}}' 2>/dev/null || true
else
    echo "  Docker не установлен"
fi
echo

echo "🔐 FIREWALL"
ufw status 2>/dev/null | head -n 12 || true
echo
echo "=================================================================="
EOF

chmod +x /etc/update-motd.d/99-custom-sysinfo

###############################################################################
# 15. ДИРЕКТОРИИ И КЛЮЧИ
###############################################################################

mkdir -p /usr/local/x-ui/bin
mkdir -p "$BACKUP_DIR"
mkdir -p "$PRE_UPDATE_DIR"

chmod 700 "$BACKUP_DIR"
chmod 700 "$PRE_UPDATE_DIR"

if [[ ! -f /root/.mssql_health.key ]]; then
    umask 077
    openssl rand -base64 32 > /root/.mssql_health.key
    chmod 600 /root/.mssql_health.key
fi


###############################################################################
# 16. X-UI HEALTH CHECK (ПОРТЫ 2053 И 8443)
###############################################################################

echo
echo ">>> Создание x-ui healthcheck..."

cat > /usr/local/sbin/xui-health.sh <<'EOF'
#!/usr/bin/env bash

set -u

LOG="/var/log/xui-health.log"
SERVICE="x-ui"
CHECK_PORTS=("2053" "8443")

need_restart=0
reason=""

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

if [[ "$need_restart" -eq 1 ]]; then
    echo "$(date '+%F %T') [RESTART] Причина: ${reason}" >> "$LOG"
    logger -t xui-health "x-ui restart. Reason: ${reason}"
    systemctl restart "$SERVICE"
    sleep 5
    if systemctl is-active --quiet "$SERVICE"; then
        echo "$(date '+%F %T') [OK] x-ui восстановлен" >> "$LOG"
    else
        echo "$(date '+%F %T') [FAIL] x-ui не восстановлен" >> "$LOG"
        systemctl status "$SERVICE" --no-pager >> "$LOG" 2>&1 || true
    fi
else
    echo "$(date '+%F %T') [OK] x-ui + Xray + ports 2053/8443" >> "$LOG"
fi
EOF

chmod 700 /usr/local/sbin/xui-health.sh
touch /var/log/xui-health.log
chmod 600 /var/log/xui-health.log


###############################################################################
# 17. X-UI BACKUP
###############################################################################

echo
echo ">>> Создание резервного копирования x-ui..."

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

if [[ "${#SOURCE_LIST[@]}" -eq 0 ]]; then
    echo "No x-ui data found."
    exit 0
fi

tar -czf "$TMP_FILE" -C / "${SOURCE_LIST[@]}"
mv "$TMP_FILE" "$BACKUP_FILE"
chmod 600 "$BACKUP_FILE"

find "$BACKUP_DIR" -type f -name 'x-ui_*.tar.gz' -mtime +14 -delete
echo "Backup created: $BACKUP_FILE"
EOF

chmod 700 /usr/local/sbin/xui-backup.sh


###############################################################################
# 18. SAFE X-UI UPDATE / ROLLBACK
###############################################################################

echo
echo ">>> Создание безопасного updater 3x-ui..."

cat > /usr/local/sbin/xui-update-safe.sh <<'EOF'
#!/usr/bin/env bash

set -Eeuo pipefail

LOG="/var/log/xui-auto-update.log"
LOCK_FILE="/run/lock/xui-update-safe.lock"
BACKUP_DIR="/root/xui_backups"
PRE_UPDATE_DIR="${BACKUP_DIR}/pre-update"
UPDATE_URL="https://raw.githubusercontent.com/MHSanaei/3x-ui/main/update.sh"

exec >> "$LOG" 2>&1

mkdir -p "$PRE_UPDATE_DIR"
chmod 700 "$BACKUP_DIR"
chmod 700 "$PRE_UPDATE_DIR"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "[$(date '+%F %T')] UPDATE SKIPPED: another update is running."
    exit 0
fi

log() { echo "[$(date '+%F %T')] $*"; }

notify_error() {
    local message="$1"
    logger -p daemon.err -t xui-update "$message"
    if command -v wall >/dev/null 2>&1; then
        wall "x-ui UPDATE: ${message}" 2>/dev/null || true
    fi
}

create_snapshot() {
    local label="$1"
    local dir="${PRE_UPDATE_DIR}/${label}"
    local archive="${dir}/x-ui-state.tar.gz"
    rm -rf "$dir"
    mkdir -p "$dir"
    chmod 700 "$dir"

    local source_list=()
    [[ -d /etc/x-ui ]] && source_list+=("etc/x-ui")
    [[ -d /usr/local/x-ui ]] && source_list+=("usr/local/x-ui")
    [[ -f /usr/bin/x-ui ]] && source_list+=("usr/bin/x-ui")
    [[ -f /etc/systemd/system/x-ui.service ]] && source_list+=("etc/systemd/system/x-ui.service")
    [[ -f /etc/default/x-ui ]] && source_list+=("etc/default/x-ui")
    [[ -d /root/cert ]] && source_list+=("root/cert")

    if [[ "${#source_list[@]}" -eq 0 ]]; then
        log "ERROR: nothing to backup."
        return 1
    fi

    tar -czf "$archive" -C / "${source_list[@]}"
    chmod 600 "$archive"
    echo "$archive"
}

restore_snapshot() {
    local archive="$1"
    if [[ ! -f "$archive" ]]; then
        log "ERROR: rollback archive not found: $archive"
        return 1
    fi
    log "Stopping x-ui before rollback..."
    systemctl stop x-ui 2>/dev/null || true
    rm -rf /etc/x-ui /usr/local/x-ui /root/cert
    rm -f /usr/bin/x-ui /etc/systemd/system/x-ui.service /etc/default/x-ui
    tar -xzf "$archive" -C /
    systemctl daemon-reload
    systemctl enable x-ui >/dev/null 2>&1 || true
    systemctl start x-ui
}

health_check() {
    log "Waiting 10 seconds for x-ui..."
    sleep 10

    if ! systemctl is-active --quiet x-ui; then
        log "Healthcheck: systemd x-ui is NOT active."
        return 1
    fi

    if ! ss -lnt 2>/dev/null | grep -qE ":8784[[:space:]]"; then
        log "Healthcheck: panel port 8784 is not listening."
        return 1
    fi

    if ! pgrep -af 'xray' >/dev/null 2>&1; then
        log "Healthcheck: xray process is NOT running."
        return 1
    fi

    for port in 2053 8443; do
        if ! ss -lnt 2>/dev/null | grep -qE ":${port}[[:space:]]"; then
            log "Healthcheck: Xray port ${port} is NOT listening."
            return 1
        fi
    done
    return 0
}

main() {
    log "============================================================"
    log "3x-ui SAFE AUTO UPDATE"
    log "============================================================"

    if ! systemctl is-active --quiet x-ui; then
        log "x-ui is not active before update."
        notify_error "x-ui was inactive before scheduled update."
        exit 1
    fi

    local pre_archive
    pre_archive="$(create_snapshot "current")"
    if [[ ! -f "$pre_archive" ]]; then
        log "ERROR: pre-update backup failed."
        notify_error "x-ui update aborted: backup failed."
        exit 1
    fi

    local tmp_update="/tmp/xui-update.sh"
    rm -f "$tmp_update"
    if ! curl -4 -fL --retry 3 --connect-timeout 15 --max-time 300 "$UPDATE_URL" -o "$tmp_update"; then
        log "ERROR: failed to download updater."
        notify_error "3x-ui update aborted: updater download failed."
        rm -f "$tmp_update"
        exit 1
    fi
    chmod 700 "$tmp_update"

    if ! bash "$tmp_update"; then
        log "Official updater returned an error. Starting rollback..."
        rm -f "$tmp_update"
        if restore_snapshot "$pre_archive" && health_check; then
            log "ROLLBACK SUCCESS"
            notify_error "3x-ui update failed; previous version restored successfully."
            exit 0
        fi
        log "CRITICAL: rollback failed."
        notify_error "CRITICAL: 3x-ui update and rollback both failed."
        exit 1
    fi
    rm -f "$tmp_update"

    if health_check; then
        log "UPDATE SUCCESS"
        exit 0
    fi

    log "Update healthcheck FAILED. Starting rollback..."
    create_snapshot "failed-$(date '+%Y%m%d-%H%M%S')" 2>/dev/null || true
    if restore_snapshot "$pre_archive" && health_check; then
        log "ROLLBACK SUCCESS"
        notify_error "3x-ui update failed; automatic rollback succeeded."
        exit 0
    fi

    log "CRITICAL: ROLLBACK FAILED"
    notify_error "CRITICAL: 3x-ui update failed and automatic rollback failed."
    exit 1
}

main "$@"
EOF

chmod 700 /usr/local/sbin/xui-update-safe.sh
touch /var/log/xui-auto-update.log
chmod 600 /var/log/xui-auto-update.log


###############################################################################
# 19. ОБНОВЛЕНИЯ СИСТЕМЫ И ГЕО-БАЗ
###############################################################################

cat > /usr/local/sbin/system-update.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y
apt-get autoremove -y
apt-get autoclean
if [[ -f /var/run/reboot-required ]]; then
    logger -t system-update "System reboot required after update."
fi
EOF
chmod 700 /usr/local/sbin/system-update.sh

cat > /usr/local/sbin/update-geo.sh <<'EOF'
#!/usr/bin/env bash
set -u
LOG="/var/log/xui-geo-update.log"
exec >> "$LOG" 2>&1
TARGET_DIR="/usr/local/x-ui/bin"
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
        echo "$(date '+%F %T') ERROR: failed to update $(basename "$dest")"
    fi
}

update_file "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat" "${TARGET_DIR}/geosite.dat"
update_file "https://github.com/v2fly/geoip/releases/latest/download/geoip.dat" "${TARGET_DIR}/geoip.dat"
update_file "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/geosite.dat" "${TARGET_DIR}/geosite_RU.dat"

if command -v x-ui >/dev/null 2>&1; then
    x-ui update-all-geofiles >/dev/null 2>&1 || true
fi
EOF
chmod 700 /usr/local/sbin/update-geo.sh
touch /var/log/xui-geo-update.log
chmod 600 /var/log/xui-geo-update.log


###############################################################################
# 20. SSL RENEWAL WRAPPER
###############################################################################

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
    if [[ "$NGINX_WAS_ACTIVE" -eq 1 ]]; then
        systemctl start nginx || true
    fi
    exit "$exit_code"
}
trap cleanup EXIT

if [[ ! -x "$ACME" ]]; then
    echo "ERROR: acme.sh not found"
    exit 1
fi

"$ACME" --cron --home "/root/.acme.sh"
EOF
chmod 700 /usr/local/bin/renew-ssl.sh
touch /var/log/acme-renew.log
chmod 600 /var/log/acme-renew.log


###############################################################################
# 21. SSH
###############################################################################

echo
echo ">>> Настройка SSH..."

SSHD_CONFIG="/etc/ssh/sshd_config"
mkdir -p /etc/ssh/sshd_config.d

sed -i -E 's/^[[:space:]]*Port[[:space:]]+/# Disabled by VPS setup: &/' "$SSHD_CONFIG"

shopt -s nullglob
for file in /etc/ssh/sshd_config.d/*.conf; do
    [[ "$(basename "$file")" == "99-custom-port.conf" ]] && continue
    sed -i -E 's/^[[:space:]]*Port[[:space:]]+/# Disabled by VPS setup: &/' "$file"
done
shopt -u nullglob

cat > /etc/ssh/sshd_config.d/99-custom-port.conf <<EOF
# Managed by VPS setup ${SCRIPT_VERSION}
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
    echo "❌ Эффективный SSH порт не равен ${SSH_PORT}."
    exit 1
fi
echo "✓ SSH слушает порт ${SSH_PORT}"


###############################################################################
# 22. UFW & ICMP (IPV4 ONLY)
###############################################################################

echo
echo ">>> Настройка firewall..."

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw allow "${SSH_PORT}/tcp" comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw allow 2053/tcp comment 'x-ui / xray'
ufw allow 2096/tcp comment 'x-ui'
ufw allow 8443/tcp comment 'x-ui / xray'
ufw allow 8784/tcp comment 'x-ui panel'
ufw allow 54325/tcp comment 'Service 54325'

UFW_BEFORE="/etc/ufw/before.rules"
if [[ -f "$UFW_BEFORE" ]]; then
    sed -i 's/-p icmp --icmp-type echo-request -j ACCEPT/-p icmp --icmp-type echo-request -j DROP/' "$UFW_BEFORE" || true
fi

ufw --force enable
ufw reload


###############################################################################
# 23. NGINX STOP & 3X-UI УСТАНОВКА
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

restore_nginx_on_failure() {
    local exit_code=$?
    if [[ "$NGINX_WAS_ACTIVE" -eq 1 ]]; then
        systemctl start nginx || true
    fi
    exit "$exit_code"
}
trap restore_nginx_on_failure EXIT

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
    echo "✓ Штатный cron acme.sh удалён"
fi


###############################################################################
# 24. ЭТАЛОННАЯ БАЗА 3X-UI
###############################################################################

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
    /usr/local/sbin/xui-backup.sh

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
            echo "❌ SQLite integrity_check не пройден."
            rm -f "$tmp_db" "$decrypted_db"
            systemctl start x-ui
            return 1
        fi

        install -o root -g root -m 600 "$decrypted_db" /etc/x-ui/x-ui.db
        sqlite3 /etc/x-ui/x-ui.db "UPDATE client_traffics SET up = 0, down = 0;" 2>/dev/null || true
        sqlite3 /etc/x-ui/x-ui.db "UPDATE inbounds SET up = 0, down = 0;" 2>/dev/null || true
        sqlite3 /etc/x-ui/x-ui.db "DELETE FROM inbound_client_ips;" 2>/dev/null || true
        echo "✓ База ${db_file} успешно установлена."
        rm -f "$tmp_db" "$decrypted_db"
    else
        echo "❌ Ошибка расшифровки базы."
        rm -f "$tmp_db" "$decrypted_db"
        systemctl start x-ui
        return 1
    fi

    systemctl restart x-ui
    sleep 5
    systemctl is-active --quiet x-ui
}

restore_custom_database

# Восстанавливаем Nginx
systemctl enable nginx
nginx -t
systemctl start nginx
trap - EXIT


###############################################################################
# 25. НАСТРОЙКА MAINTENANCE CRON
###############################################################################

echo
echo ">>> Настройка maintenance cron..."

cat > "$MAINTENANCE_FILE" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# === 1. ОБНОВЛЕНИЕ SSL-СЕРТИФИКАТОВ ACME.SH ===
16 10 * * * root /usr/local/bin/renew-ssl.sh

# === 2. ЕЖЕДНЕВНЫЙ БЭКАП БАЗЫ X-UI ===
0 3 * * * root /usr/local/sbin/xui-backup.sh

# === 3. ЕЖЕНЕДЕЛЬНОЕ ОБНОВЛЕНИЕ СИСТЕМЫ И ПАКЕТОВ APT (СРЕДА) ===
20 3 * * 3 root /usr/local/sbin/system-update.sh

# === 4. БЕЗОПАСНОЕ АВТО-ОБНОВЛЕНИЕ ПАНЕЛИ 3X-UI С ROLLBACK (ПЯТНИЦА) ===
30 4 * * 5 root /usr/local/sbin/xui-update-safe.sh

# === 5. ПЛАНОВАЯ ПЕРЕЗАГРУЗКА VPS (ПТ В 05:06, ПН И ЧТ В 06:00) ===
06 5 * * 5 root /usr/bin/systemctl reboot
0 6 * * 1,4 root /usr/bin/systemctl reboot

# === 6. МОНИТОРИНГ (СЛУЖБА X-UI, ЯДРО XRAY, ПОРТЫ 2053 И 8443) ===
*/30 * * * * root /usr/local/sbin/xui-health.sh

# === 7. ОБНОВЛЕНИЕ ГЕО-БАЗ V2FLY И RUNETFREEDOM (ПОНЕДЕЛЬНИК 05:00) ===
0 5 * * 1 root /usr/local/sbin/update-geo.sh

# === 8. ОЧИСТКА СИСТЕМНЫХ ЖУРНАЛОВ JOURNALCTL (СУББОТА) ===
15 4 * * 6 root /usr/bin/journalctl --vacuum-time=7d --vacuum-size=200M > /dev/null 2>&1
EOF

chmod 644 "$MAINTENANCE_FILE"
systemctl restart cron


###############################################################################
# 26. ФИНАЛЬНАЯ ПРОВЕРКА СТАТУСОВ
###############################################################################

echo
echo "======================================================================"
echo " ✅ ФИНАЛЬНАЯ ПРОВЕРКА"
echo "======================================================================"

check_service() {
    local name="$1"
    local svc="$2"
    printf "%-22s : " "$name"
    systemctl is-active --quiet "$svc" && echo "OK" || echo "FAIL"
}

check_service "Nginx" "nginx"
check_service "SSH" "ssh"
check_service "Cron" "cron"
check_service "Cloudflare WARP" "warp-svc"
check_service "x-ui service" "x-ui"

printf "%-22s : " "Xray core"
pgrep -af 'xray' >/dev/null 2>&1 && echo "OK" || echo "FAIL"

for port in 2053 8443; do
    printf "%-22s : " "Xray :${port}"
    ss -lnt 2>/dev/null | grep -qE ":${port}[[:space:]]" && echo "OK" || echo "FAIL"
done

printf "%-22s : " "WARP SOCKS5 :${WARP_PROXY_PORT}"
ss -lnt 2>/dev/null | grep -qE ":${WARP_PROXY_PORT}[[:space:]]" && echo "OK" || echo "FAIL"

printf "%-22s : " "UFW Firewall"
ufw status | grep -q "Status: active" && echo "OK" || echo "FAIL"

printf "%-22s : " "IPv6 Disabled"
[[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" == "1" ]] && echo "OK" || echo "FAIL"


###############################################################################
# 27. ИТОГОВАЯ ИНФОРМАЦИЯ
###############################################################################

SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"

echo
echo "======================================================================"
echo " ☁️ VPS ГОТОВ"
echo "======================================================================"
echo "IP VPS           : ${SERVER_IP:-unknown}"
echo "SSH              : ${SSH_PORT}"
echo "X-UI             : ${XUI_PORT}"
echo "Cloudflare WARP  : SOCKS5 127.0.0.1:${WARP_PROXY_PORT}"
echo "IPv6             : Отключен"
echo "Xray Inbounds    : 2053, 8443"
echo "======================================================================"
echo " ✅ Установка завершена"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================================"
echo
