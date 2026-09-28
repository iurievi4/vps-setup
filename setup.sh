#!/usr/bin/env bash

###############################################################################
# ☁️ VPS BOOTSTRAP / SETUP
# Версия: 3.6.3
#
# Ubuntu / Debian
#
# Назначение:
#   Первичная настройка чистого VPS:
#   - Nginx (:80)
#   - BBR / FQ / TCP Fast Open
#   - SWAP (универсальная проверка)
#   - UFW (порты: 1241, 80, 443, 2053, 2096, 8443, 8784, 54325)
#   - SSH :1241 (drop-in + поддержка Ubuntu 24.04 socket activation)
#   - 3x-ui (non-interactive, SQLite, SSL mode: ip)
#   - Опциональное восстановление эталонной базы (0 - чистая / 1 - LV / 2 - MW / 3 - TR)
#   - Резервные копии (ежедневные + pre-update)
#   - Безопасное автообновление 3x-ui с автоматическим rollback
#   - Healthcheck (x-ui + xray-core + строгая проверка портов 2053 И 8443)
#   - Обновление geo-файлов (v2fly + runetfreedom)
#   - Системное обслуживание в /etc/cron.d/
#
# SSL-АРХИТЕКТУРА:
#
#   Nginx :80
#       ↓
#   stop nginx
#       ↓
#   3x-ui / acme.sh standalone :80
#       ↓
#   Let's Encrypt HTTP-01
#       ↓
#   сертификат
#       ↓
#   start nginx
#
###############################################################################

set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

SCRIPT_VERSION="3.6.3"

LOG_FILE="/var/log/vps-setup.log"

SSH_PORT="1241"

XUI_PORT="8784"

ACME_PORT="80"

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
# 9. SYSCTL / BBR
###############################################################################

echo
echo ">>> Настройка TCP..."

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
# 10. SWAP (УНИВЕРСАЛЬНАЯ ПРОВЕРКА)
###############################################################################

if ! swapon --show | grep -q .; then

    echo
    echo ">>> Создание SWAP 2 GB..."

    if [[ ! -f /swapfile ]]; then

        dd if=/dev/zero \
            of=/swapfile \
            bs=1M \
            count=2048 \
            status=progress

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
# 11. NGINX
###############################################################################

echo
echo ">>> Настройка Nginx..."

mkdir -p /var/www/acme/.well-known/acme-challenge

rm -f /etc/nginx/sites-enabled/default

cat > /etc/nginx/sites-available/cloud-node <<'EOF'
server {

    listen 80 default_server;
    listen [::]:80 default_server;

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

ln -sf \
    /etc/nginx/sites-available/cloud-node \
    /etc/nginx/sites-enabled/cloud-node

nginx -t

systemctl enable nginx

systemctl restart nginx


###############################################################################
# 12. MOTD
###############################################################################

echo
echo ">>> Настройка MOTD..."

cat > /etc/update-motd.d/99-custom-sysinfo <<'EOF'
#!/usr/bin/env bash

echo
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                      ☁️  CLOUD NODE                             ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo

echo "🕒 $(date '+%Y-%m-%d %H:%M:%S')"

echo "⏱ Uptime: $(uptime -p)"

echo

echo "🌐 NETWORK"

ip -4 -brief addr show scope global 2>/dev/null || true

echo

echo "📡 PING"

printf "Yandex: "

ping -c 1 -W 1 77.88.8.8 >/dev/null 2>&1 \
    && echo "OK" \
    || echo "FAIL"

echo

echo "🖥 SYSTEM"

echo "Load: $(cut -d' ' -f1-3 /proc/loadavg)"

if command -v sensors >/dev/null 2>&1; then

    CPU_TEMP="$(
        sensors 2>/dev/null |
        awk '/Package id 0:/ {print $4; exit}'
    )"

    [[ -n "${CPU_TEMP}" ]] && echo "CPU: ${CPU_TEMP}"

fi

if command -v nvme >/dev/null 2>&1; then

    NVME_TEMP="$(
        nvme smart-log /dev/nvme0 2>/dev/null |
        awk -F: '/temperature/ {print $2; exit}' |
        xargs
    )"

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

for service in nginx ssh x-ui docker; do

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
# 13. DIRECTORIES
###############################################################################

mkdir -p /usr/local/x-ui/bin

mkdir -p "$BACKUP_DIR"

mkdir -p "$PRE_UPDATE_DIR"

chmod 700 "$BACKUP_DIR"

chmod 700 "$PRE_UPDATE_DIR"


###############################################################################
# 14. LOCAL MSSQL HEALTH KEY
###############################################################################

if [[ ! -f /root/.mssql_health.key ]]; then

    umask 077

    openssl rand -base64 32 > /root/.mssql_health.key

    chmod 600 /root/.mssql_health.key

fi


###############################################################################
# 15. X-UI HEALTH CHECK (СТРОГИЙ: ОБА ПОРТА 2053 И 8443)
###############################################################################

echo
echo ">>> Создание x-ui healthcheck (x-ui + xray + порты 2053 И 8443)..."

cat > /usr/local/sbin/xui-health.sh <<'EOF'
#!/usr/bin/env bash

set -u

LOG="/var/log/xui-health.log"
SERVICE="x-ui"

# Оба порта являются обязательными
CHECK_PORTS=("2053" "8443")

need_restart=0
reason=""

# 1. Проверка службы systemd
if ! systemctl is-active --quiet "$SERVICE"; then
    need_restart=1
    reason="служба x-ui не активна"

# 2. Проверка процесса Xray
elif ! pgrep -af 'xray' >/dev/null 2>&1; then
    need_restart=1
    reason="процесс xray не найден"

# 3. Проверка прослушивания ВСЕХ рабочих портов
else
    for port in "${CHECK_PORTS[@]}"; do
        if ! ss -lnt 2>/dev/null | grep -qE ":${port}[[:space:]]"; then
            need_restart=1
            reason="порт ${port} не слушается"
            break
        fi
    done
fi

# Выполнение перезапуска и расширенная диагностика
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
# 16. X-UI BACKUP
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

[[ -f /etc/systemd/system/x-ui.service ]] &&
    SOURCE_LIST+=("etc/systemd/system/x-ui.service")

[[ -f /etc/default/x-ui ]] &&
    SOURCE_LIST+=("etc/default/x-ui")

[[ -d /root/cert ]] &&
    SOURCE_LIST+=("root/cert")

[[ -d /root/.acme.sh ]] &&
    SOURCE_LIST+=("root/.acme.sh")

if [[ "${#SOURCE_LIST[@]}" -eq 0 ]]; then

    echo "No x-ui data found."

    exit 0

fi

tar \
    -czf "$TMP_FILE" \
    -C / \
    "${SOURCE_LIST[@]}"

mv "$TMP_FILE" "$BACKUP_FILE"

chmod 600 "$BACKUP_FILE"

find "$BACKUP_DIR" \
    -type f \
    -name 'x-ui_*.tar.gz' \
    -mtime +14 \
    -delete

echo "Backup created: $BACKUP_FILE"
EOF

chmod 700 /usr/local/sbin/xui-backup.sh


###############################################################################
# 17. SAFE X-UI UPDATE / ROLLBACK (С ПОЛНОЙ ПРОВЕРКОЙ XRAY)
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

    echo
    echo "[$(date '+%F %T')] UPDATE SKIPPED: another update is running."

    exit 0

fi

log() {

    echo "[$(date '+%F %T')] $*"

}

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

    [[ -d /etc/x-ui ]] &&
        source_list+=("etc/x-ui")

    [[ -d /usr/local/x-ui ]] &&
        source_list+=("usr/local/x-ui")

    [[ -f /usr/bin/x-ui ]] &&
        source_list+=("usr/bin/x-ui")

    [[ -f /etc/systemd/system/x-ui.service ]] &&
        source_list+=("etc/systemd/system/x-ui.service")

    [[ -f /etc/default/x-ui ]] &&
        source_list+=("etc/default/x-ui")

    [[ -d /root/cert ]] &&
        source_list+=("root/cert")

    if [[ "${#source_list[@]}" -eq 0 ]]; then

        log "ERROR: nothing to backup."

        return 1

    fi

    tar \
        -czf "$archive" \
        -C / \
        "${source_list[@]}"

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

    log "Removing failed x-ui state..."

    rm -rf \
        /etc/x-ui \
        /usr/local/x-ui \
        /root/cert

    rm -f \
        /usr/bin/x-ui \
        /etc/systemd/system/x-ui.service \
        /etc/default/x-ui

    log "Restoring previous x-ui state..."

    tar \
        -xzf "$archive" \
        -C /

    systemctl daemon-reload

    systemctl enable x-ui >/dev/null 2>&1 || true

    systemctl start x-ui

}

health_check() {

    log "Waiting 10 seconds for x-ui..."

    sleep 10

    # 1. Служба x-ui
    if ! systemctl is-active --quiet x-ui; then

        log "Healthcheck: systemd x-ui is NOT active."

        systemctl status x-ui --no-pager || true

        return 1

    fi

    log "Healthcheck: x-ui service is active."

    # 2. Порт панели 8784
    if ! ss -lnt 2>/dev/null |
        grep -qE ":8784[[:space:]]"; then

        log "Healthcheck: panel port 8784 is not listening."

        return 1

    fi

    log "Healthcheck: panel port 8784 is listening."

    # 3. Процесс ядра Xray
    if ! pgrep -af 'xray' >/dev/null 2>&1; then

        log "Healthcheck: xray process is NOT running."

        return 1

    fi

    log "Healthcheck: xray process is running."

    # 4. Рабочие порты 2053 и 8443
    for port in 2053 8443; do

        if ! ss -lnt 2>/dev/null |
            grep -qE ":${port}[[:space:]]"; then

            log "Healthcheck: Xray port ${port} is NOT listening."

            return 1

        fi

        log "Healthcheck: Xray port ${port} is listening."

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

    # PRE-UPDATE BACKUP
    log "Creating pre-update snapshot..."

    local pre_archive

    pre_archive="$(create_snapshot "current")"

    if [[ ! -f "$pre_archive" ]]; then

        log "ERROR: pre-update backup failed."

        notify_error "x-ui update aborted: backup failed."

        exit 1

    fi

    log "Pre-update snapshot: $pre_archive"

    # DOWNLOAD UPDATE SCRIPT
    local tmp_update="/tmp/xui-update.sh"

    rm -f "$tmp_update"

    log "Downloading official 3x-ui updater..."

    if ! curl \
        -4 \
        -fL \
        --retry 3 \
        --connect-timeout 15 \
        --max-time 300 \
        "$UPDATE_URL" \
        -o "$tmp_update"; then

        log "ERROR: failed to download updater."

        notify_error "3x-ui update aborted: updater download failed."

        rm -f "$tmp_update"

        exit 1

    fi

    chmod 700 "$tmp_update"

    # UPDATE
    log "Starting official 3x-ui update..."

    if ! bash "$tmp_update"; then

        log "Official updater returned an error."

        rm -f "$tmp_update"

        log "Starting rollback..."

        if restore_snapshot "$pre_archive"; then

            if health_check; then

                log "ROLLBACK SUCCESS"

                notify_error "3x-ui update failed; previous version restored successfully."

                exit 0

            fi

        fi

        log "CRITICAL: rollback failed."

        systemctl status x-ui --no-pager || true

        journalctl \
            -u x-ui \
            -n 100 \
            --no-pager \
            || true

        notify_error "CRITICAL: 3x-ui update and rollback both failed."

        exit 1

    fi

    rm -f "$tmp_update"

    # POST-UPDATE HEALTHCHECK
    log "Update command completed."

    if health_check; then

        log "============================================================"
        log "UPDATE SUCCESS"
        log "============================================================"

        logger -t xui-update "3x-ui update completed successfully."

        exit 0

    fi

    # FAILED UPDATE -> SAVE FAILED STATE & ROLLBACK
    log "Update healthcheck FAILED."

    local failed_archive=""

    if failed_archive="$(create_snapshot "failed-$(date '+%Y%m%d-%H%M%S')" 2>/dev/null)"; then

        log "Failed state saved: $failed_archive"

    else

        log "WARNING: failed state snapshot could not be created."

    fi

    log "============================================================"
    log "STARTING ROLLBACK"
    log "============================================================"

    if restore_snapshot "$pre_archive"; then

        log "Rollback files restored."

        if health_check; then

            log "============================================================"
            log "ROLLBACK SUCCESS"
            log "============================================================"

            notify_error "3x-ui update failed; automatic rollback succeeded."

            exit 0

        fi

    fi

    log "============================================================"
    log "CRITICAL: ROLLBACK FAILED"
    log "============================================================"

    systemctl status x-ui --no-pager || true

    journalctl \
        -u x-ui \
        -n 150 \
        --no-pager \
        || true

    notify_error "CRITICAL: 3x-ui update failed and automatic rollback failed."

    exit 1

}

main "$@"
EOF

chmod 700 /usr/local/sbin/xui-update-safe.sh

touch /var/log/xui-auto-update.log

chmod 600 /var/log/xui-auto-update.log


###############################################################################
# 18. SYSTEM UPDATE
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

    logger -t system-update \
        "System reboot required after update."

fi
EOF

chmod 700 /usr/local/sbin/system-update.sh


###############################################################################
# 19. GEO DATABASE UPDATE (V2FLY + RUNETFREEDOM)
###############################################################################

cat > /usr/local/sbin/update-geo.sh <<'EOF'
#!/usr/bin/env bash

set -u

LOG="/var/log/xui-geo-update.log"

exec >> "$LOG" 2>&1

echo
echo "============================================================"
echo "$(date '+%F %T') GEO UPDATE"
echo "============================================================"

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

update_file \
    "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat" \
    "${TARGET_DIR}/geosite.dat"

update_file \
    "https://github.com/v2fly/geoip/releases/latest/download/geoip.dat" \
    "${TARGET_DIR}/geoip.dat"

update_file \
    "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/geosite.dat" \
    "${TARGET_DIR}/geosite_RU.dat"

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

echo
echo ">>> Создание SSL renewal wrapper..."

cat > /usr/local/bin/renew-ssl.sh <<'EOF'
#!/usr/bin/env bash

set -Eeuo pipefail

LOG="/var/log/acme-renew.log"

ACME="/root/.acme.sh/acme.sh"

NGINX_WAS_ACTIVE=0

exec >> "$LOG" 2>&1

echo
echo "======================================================================"
echo " 🔐 SSL RENEW"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================================"

if systemctl is-active --quiet nginx; then

    NGINX_WAS_ACTIVE=1

    echo "$(date '+%F %T') stopping nginx for standalone ACME"

    systemctl stop nginx

fi

cleanup() {

    local exit_code=$?

    if [[ "$NGINX_WAS_ACTIVE" -eq 1 ]]; then

        echo "$(date '+%F %T') restoring nginx"

        systemctl start nginx || true

        if systemctl is-active --quiet nginx; then

            echo "$(date '+%F %T') nginx restored successfully"

        else

            echo "$(date '+%F %T') ERROR: nginx failed to start"

        fi

    fi

    echo "$(date '+%F %T') ACME exit code: ${exit_code}"

    exit "$exit_code"
}

trap cleanup EXIT

if [[ ! -x "$ACME" ]]; then

    echo "$(date '+%F %T') ERROR: acme.sh not found"

    exit 1

fi

echo "$(date '+%F %T') running acme.sh renewal"

"$ACME" \
    --cron \
    --home "/root/.acme.sh"

echo "$(date '+%F %T') acme renewal completed"

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

sed -i \
    -E 's/^[[:space:]]*Port[[:space:]]+/# Disabled by VPS setup: &/' \
    "$SSHD_CONFIG"

shopt -s nullglob

for file in /etc/ssh/sshd_config.d/*.conf; do

    if [[ "$(basename "$file")" == "99-custom-port.conf" ]]; then
        continue
    fi

    sed -i \
        -E 's/^[[:space:]]*Port[[:space:]]+/# Disabled by VPS setup: &/' \
        "$file"

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

EFFECTIVE_SSH_PORT="$(
    sshd -T 2>/dev/null |
    awk '$1 == "port" {print $2; exit}'
)"

if [[ "$EFFECTIVE_SSH_PORT" != "$SSH_PORT" ]]; then

    echo
    echo "❌ Эффективный SSH порт не равен ${SSH_PORT}."
    echo "Получено: ${EFFECTIVE_SSH_PORT:-unknown}"
    echo

    sshd -T 2>/dev/null |
        grep -E '^port ' ||
        true

    exit 1

fi

if ! ss -lnt | grep -qE ":${SSH_PORT}[[:space:]]"; then

    echo "❌ SSH НЕ слушает порт ${SSH_PORT}."

    ss -lntp |
        grep -E ':(22|1241)\b' ||
        true

    exit 1

fi

echo "✓ SSH слушает порт ${SSH_PORT}"


###############################################################################
# 22. UFW
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


###############################################################################
# 23. ICMP
###############################################################################

echo
echo ">>> Настройка ICMP..."

UFW_BEFORE="/etc/ufw/before.rules"

if [[ -f "$UFW_BEFORE" ]]; then

    if grep -qE -- \
        "-p icmp --icmp-type echo-request -j ACCEPT" \
        "$UFW_BEFORE"; then

        sed -i \
            's/-p icmp --icmp-type echo-request -j ACCEPT/-p icmp --icmp-type echo-request -j DROP/' \
            "$UFW_BEFORE"

        echo "✓ IPv4 ICMP echo-request заблокирован"

    elif grep -qE -- \
        "-p icmp --icmp-type echo-request -j DROP" \
        "$UFW_BEFORE"; then

        echo "✓ IPv4 ICMP echo-request уже заблокирован"

    else

        echo "⚠️ IPv4 правило ICMP echo-request не найдено."

    fi

fi

UFW_BEFORE6="/etc/ufw/before6.rules"

if [[ -f "$UFW_BEFORE6" ]]; then

    if grep -qE -- \
        "-p ipv6-icmp --icmpv6-type echo-request -j ACCEPT" \
        "$UFW_BEFORE6"; then

        sed -i \
            's/-p ipv6-icmp --icmpv6-type echo-request -j ACCEPT/-p ipv6-icmp --icmpv6-type echo-request -j DROP/' \
            "$UFW_BEFORE6"

        echo "✓ IPv6 ICMP echo-request заблокирован"

    elif grep -qE -- \
        "-p ipv6-icmp --icmpv6-type echo-request -j DROP" \
        "$UFW_BEFORE6"; then

        echo "✓ IPv6 ICMP echo-request уже заблокирован"

    else

        echo "⚠️ IPv6 правило ICMP echo-request не найдено."

    fi

fi


###############################################################################
# 24. ВКЛЮЧАЕМ UFW
###############################################################################

ufw --force enable

ufw reload

ufw status verbose


###############################################################################
# 25. NGINX STOP ДЛЯ 3X-UI / ACME
###############################################################################

echo
echo "======================================================================"
echo " 🔐 ПОДГОТОВКА ACME"
echo "======================================================================"

NGINX_WAS_ACTIVE=0

if systemctl is-active --quiet nginx; then

    NGINX_WAS_ACTIVE=1

    echo "Останавливаем Nginx перед установкой 3x-ui..."

    systemctl stop nginx

fi

restore_nginx_on_failure() {

    local exit_code=$?

    if [[ "$NGINX_WAS_ACTIVE" -eq 1 ]]; then

        echo
        echo "⚠️ Аварийное завершение установки 3x-ui."
        echo "Восстанавливаем Nginx..."

        systemctl start nginx || true

    fi

    exit "$exit_code"
}

trap restore_nginx_on_failure EXIT


###############################################################################
# 26. СКАЧИВАЕМ 3X-UI INSTALLER
###############################################################################

echo
echo "======================================================================"
echo " 📦 Установка 3x-ui"
echo "======================================================================"

TMP_XUI_INSTALL="/tmp/3x-ui-install.sh"

rm -f "$TMP_XUI_INSTALL"

curl \
    -4 \
    -fL \
    --retry 3 \
    --connect-timeout 15 \
    --max-time 300 \
    "$XUI_INSTALL_URL" \
    -o "$TMP_XUI_INSTALL"

chmod 700 "$TMP_XUI_INSTALL"


###############################################################################
# 27. UNATTENDED 3X-UI (С ЯВНЫМ SQLITE)
###############################################################################

export XUI_NONINTERACTIVE=1

export XUI_DB_TYPE="sqlite"

export XUI_SSL_MODE="ip"

export XUI_PANEL_PORT="$XUI_PORT"

export XUI_ACME_HTTP_PORT="$ACME_PORT"

echo
echo "Параметры 3x-ui:"
echo "  Panel port : ${XUI_PANEL_PORT}"
echo "  DB type    : ${XUI_DB_TYPE}"
echo "  SSL mode   : ${XUI_SSL_MODE}"
echo "  ACME port  : ${XUI_ACME_HTTP_PORT}"
echo


###############################################################################
# 28. ЗАПУСК 3X-UI INSTALLER
###############################################################################

bash "$TMP_XUI_INSTALL"

rm -f "$TMP_XUI_INSTALL"


###############################################################################
# 29. УДАЛЯЕМ ШТАТНЫЙ ACME CRON
###############################################################################

echo
echo ">>> Настройка ACME cron..."

ACME="/root/.acme.sh/acme.sh"

if [[ -x "$ACME" ]]; then

    "$ACME" \
        --uninstall-cronjob \
        >/dev/null 2>&1 \
        || true

    echo "✓ Штатный cron acme.sh удалён"

else

    echo "⚠️ acme.sh не найден после установки 3x-ui."

fi


###############################################################################
# 30. ВОССТАНОВЛЕНИЕ ЭТАЛОННОЙ БАЗЫ (0 - ЧИСТАЯ ПО УМОЛЧАНИЮ)
###############################################################################

restore_custom_database() {

    echo
    echo "======================================================================"
    echo " 💾 НАСТРОЙКА ЭТАЛОННОЙ БАЗЫ 3X-UI"
    echo "======================================================================"

    local reg_choice="${REG_CHOICE:-}"
    local token="${GH_TOKEN:-}"
    local db_pass="${DB_PASS:-}"
    local repo="iurievi4/my-private-backups"
    local db_file=""

    ###########################################################################
    # 1. Выбор конфигурации
    ###########################################################################

    if [[ -z "$reg_choice" ]] && [[ -r /dev/tty ]]; then

        echo
        echo "Выберите конфигурацию 3x-ui:"
        echo
        echo "  0) Чистая установка [по умолчанию]"
        echo "  1) Латвия  (lv-x-ui.db)"
        echo "  2) Москва  (mw-x-ui.db)"
        echo "  3) Турция  (tr-x-ui.db)"
        echo

        read \
            -rp \
            "Выбор [0-3]: " \
            reg_choice \
            </dev/tty ||
            true

    fi

    # Нажатие Enter или пустой ввод трактуется как 0 (по умолчанию)
    reg_choice="${reg_choice:-0}"

    case "$reg_choice" in

        0)
            echo
            echo "  [i] Выбрана чистая установка."
            echo "  [i] Развертывание эталонной базы пропущено."
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
            echo
            echo "❌ Некорректный выбор: '${reg_choice}'. Допустимо только [0-3]."
            return 1
            ;;

    esac

    ###########################################################################
    # 2. GitHub Token (запрашивается ТОЛЬКО если выбрано 1-3)
    ###########################################################################

    if [[ -z "$token" ]] && [[ -r /dev/tty ]]; then

        read \
            -rsp \
            "Введите GitHub Token: " \
            token \
            </dev/tty ||
            true

        echo

    fi

    if [[ -z "$token" ]]; then

        echo "❌ GitHub Token не указан. Восстановление базы невозможно."

        return 1

    fi

    ###########################################################################
    # 3. Мастер-пароль базы (запрашивается ТОЛЬКО если выбрано 1-3)
    ###########################################################################

    if [[ -z "$db_pass" ]] && [[ -r /dev/tty ]]; then

        read \
            -rsp \
            "Введите мастер-пароль базы: " \
            db_pass \
            </dev/tty ||
            true

        echo

    fi

    if [[ -z "$db_pass" ]]; then

        echo "❌ Пароль базы не указан. Восстановление базы невозможно."

        return 1

    fi

    ###########################################################################
    # 4. Сначала останавливаем x-ui, затем делаем backup
    ###########################################################################

    if systemctl is-active --quiet x-ui; then

        echo ">>> Остановка службы 3x-ui перед заменой базы..."

        systemctl stop x-ui

    fi

    echo ">>> Создание backup текущего состояния..."

    /usr/local/sbin/xui-backup.sh

    ###########################################################################
    # 5. Скачивание
    ###########################################################################

    echo ">>> Загрузка ${db_file} из ${repo}..."

    local tmp_db="/tmp/${db_file}"

    rm -f "$tmp_db"

    local http_code

    http_code="$(
        curl \
            -4 \
            -sS \
            -w "%{http_code}" \
            -H "Authorization: Bearer ${token}" \
            -H "Accept: application/vnd.github.raw+json" \
            --connect-timeout 15 \
            --max-time 300 \
            -o "$tmp_db" \
            "https://api.github.com/repos/${repo}/contents/${db_file}"
    )"

    if [[ "$http_code" != "200" ]]; then

        echo "❌ Ошибка скачивания базы."
        echo "HTTP: ${http_code}"

        rm -f "$tmp_db"

        systemctl start x-ui

        return 1

    fi

    if [[ ! -s "$tmp_db" ]]; then

        echo "❌ Скачанный файл базы пуст."

        rm -f "$tmp_db"

        systemctl start x-ui

        return 1

    fi

    ###########################################################################
    # 6. Расшифровка
    ###########################################################################

    echo ">>> Расшифровка архива и применение базы..."

    local decrypted_db="/tmp/x-ui-restored.db"

    rm -f "$decrypted_db"

    if openssl enc \
        -d \
        -aes-256-cbc \
        -pbkdf2 \
        -in "$tmp_db" \
        -pass pass:"$db_pass" \
        2>/dev/null |
        tar -xzf - -O \
        > "$decrypted_db" \
        2>/dev/null; then

        if [[ ! -s "$decrypted_db" ]]; then

            echo "❌ Расшифровка дала пустой файл."

            rm -f "$tmp_db" "$decrypted_db"

            systemctl start x-ui

            return 1

        fi

        if ! sqlite3 "$decrypted_db" \
            "PRAGMA integrity_check;" \
            2>/dev/null |
            grep -qx "ok"; then

            echo "❌ SQLite integrity_check не пройден."

            rm -f "$tmp_db" "$decrypted_db"

            systemctl start x-ui

            return 1

        fi

        install \
            -o root \
            -g root \
            -m 600 \
            "$decrypted_db" \
            /etc/x-ui/x-ui.db

        sqlite3 /etc/x-ui/x-ui.db \
            "UPDATE client_traffics SET up = 0, down = 0;" \
            2>/dev/null ||
            true

        sqlite3 /etc/x-ui/x-ui.db \
            "UPDATE inbounds SET up = 0, down = 0;" \
            2>/dev/null ||
            true

        sqlite3 /etc/x-ui/x-ui.db \
            "DELETE FROM inbound_client_ips;" \
            2>/dev/null ||
            true

        echo "✓ База ${db_file} успешно установлена."
        echo "✓ Трафик и IP-сессии обнулены."

        rm -f "$tmp_db" "$decrypted_db"

    else

        echo "❌ Ошибка расшифровки."
        echo "❌ Проверьте DB_PASS."

        rm -f "$tmp_db" "$decrypted_db"

        systemctl start x-ui

        return 1

    fi

    ###########################################################################
    # 7. Запуск x-ui и финальная проверка
    ###########################################################################

    echo ">>> Перезапуск службы 3x-ui..."

    systemctl restart x-ui

    sleep 5

    if ! systemctl is-active --quiet x-ui; then

        echo "❌ x-ui не запустился после восстановления базы."

        systemctl status x-ui --no-pager || true

        journalctl \
            -u x-ui \
            -n 80 \
            --no-pager \
            || true

        return 1

    fi

    echo "✓ x-ui работает после восстановления базы."

    return 0
}

restore_custom_database


###############################################################################
# 31. ВОССТАНОВЛЕНИЕ NGINX
###############################################################################

echo
echo ">>> Восстановление Nginx..."

systemctl enable nginx

nginx -t

systemctl start nginx

if ! systemctl is-active --quiet nginx; then

    echo "❌ Nginx не запустился."

    systemctl status nginx --no-pager || true

    exit 1

fi

echo "✓ Nginx работает"


###############################################################################
# 32. Снимаем аварийный trap Nginx.
###############################################################################

trap - EXIT


###############################################################################
# 33. SSH FINAL CHECK
###############################################################################

echo
echo ">>> Финальная проверка SSH..."

sshd -t

EFFECTIVE_SSH_PORT="$(
    sshd -T 2>/dev/null |
    awk '$1 == "port" {print $2; exit}'
)"

if [[ "$EFFECTIVE_SSH_PORT" != "$SSH_PORT" ]]; then

    echo "❌ SSH effective port: ${EFFECTIVE_SSH_PORT:-unknown}"

    exit 1

fi

if ! ss -lnt | grep -qE ":${SSH_PORT}[[:space:]]"; then

    echo "❌ SSH порт ${SSH_PORT} не слушается."

    exit 1

fi

echo "✓ SSH ${SSH_PORT}"


###############################################################################
# 34. X-UI CHECK
###############################################################################

echo
echo ">>> Проверка x-ui..."

if systemctl is-enabled x-ui >/dev/null 2>&1; then

    echo "✓ x-ui enabled"

else

    echo "⚠️ x-ui не enabled"

fi

if systemctl is-active --quiet x-ui; then

    echo "✓ x-ui работает"

else

    echo "⚠️ x-ui не запущен"

    systemctl status x-ui --no-pager || true

    exit 1

fi

if ss -lnt | grep -qE ":${XUI_PORT}[[:space:]]"; then

    echo "✓ x-ui слушает порт ${XUI_PORT}"

else

    echo "⚠️ x-ui порт ${XUI_PORT} не найден"

fi


###############################################################################
# 35. НАСТРОЙКА СИСТЕМНОГО CRON
###############################################################################

echo
echo ">>> Настройка maintenance cron (/etc/cron.d/vps-maintenance)..."

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

if crontab -l >/dev/null 2>&1; then
    echo "ℹ️ Существующий пользовательский root crontab сохранён."
fi

systemctl restart cron


###############################################################################
# 36. ПРОВЕРКА СИСТЕМНОГО CRON
###############################################################################

echo
echo ">>> Проверка cron..."

if [[ -f "$MAINTENANCE_FILE" ]] && grep -q 'xui-update-safe.sh' "$MAINTENANCE_FILE"; then

    echo "✓ Maintenance cron успешно активен: ${MAINTENANCE_FILE}"

else

    echo "❌ Ошибка: ${MAINTENANCE_FILE} не найден или повреждён."

    exit 1

fi


###############################################################################
# 37. ПРОВЕРКА ПОРТОВ
###############################################################################

echo
echo "======================================================================"
echo " 🔎 ПРОВЕРКА ПОРТОВ"
echo "======================================================================"

ss -lntp |
    grep -E \
        ":(80|443|${SSH_PORT}|${XUI_PORT}|2053|2096|8443|54325)\b" ||
    true


###############################################################################
# 38. FIREWALL
###############################################################################

echo
echo "======================================================================"
echo " 🔥 FIREWALL"
echo "======================================================================"

ufw status numbered


###############################################################################
# 39. X-UI INSTALL RESULT
###############################################################################

echo
echo "======================================================================"
echo " 🔐 РЕЗУЛЬТАТ УСТАНОВКИ 3X-UI"
echo "======================================================================"

if [[ -f /etc/x-ui/install-result.env ]]; then

    echo
    echo "Файл результата:"
    echo "  /etc/x-ui/install-result.env"
    echo

    sed \
        -E \
        's/^(XUI_PASSWORD=).*/\1********/' \
        /etc/x-ui/install-result.env ||
        true

else

    echo "⚠️ /etc/x-ui/install-result.env не найден."

fi


###############################################################################
# 40. ACME & IP SSL CERTIFICATES
###############################################################################

echo
echo "======================================================================"
echo " 🔐 ACME & IP SSL"
echo "======================================================================"

if [[ -x /root/.acme.sh/acme.sh ]]; then

    echo "✓ acme.sh установлен"

    /root/.acme.sh/acme.sh \
        --list \
        2>/dev/null ||
        true

else

    echo "⚠️ acme.sh не найден."

fi

if [[ -f /root/cert/ip/fullchain.pem ]] && [[ -f /root/cert/ip/privkey.pem ]]; then

    echo "✓ IP SSL-сертификаты 3x-ui обнаружены: /root/cert/ip/"

elif [[ -d /root/cert ]] && [[ -n "$(ls -A /root/cert 2>/dev/null)" ]]; then

    echo "✓ SSL-сертификаты обнаружены в /root/cert/"

else

    echo "ℹ️ Сертификаты в /root/cert/ip/ не найдены (будут обновлены по расписанию)."

fi


###############################################################################
# 41. SAFE UPDATE TEST
###############################################################################

echo
echo "======================================================================"
echo " 🛡️ SAFE UPDATE"
echo "======================================================================"

echo "Updater:"
echo "  /usr/local/sbin/xui-update-safe.sh"

echo "Backup:"
echo "  ${BACKUP_DIR}"

echo "Pre-update:"
echo "  ${PRE_UPDATE_DIR}"

echo "Log:"
echo "  /var/log/xui-auto-update.log"

echo
echo "✓ Backup + healthcheck + rollback включены"


###############################################################################
# 42. ФИНАЛЬНАЯ ПРОВЕРКА (ВКЛЮЧАЯ XRAY И ПОРТЫ 2053 / 8443)
###############################################################################

echo
echo "======================================================================"
echo " ✅ ФИНАЛЬНАЯ ПРОВЕРКА"
echo "======================================================================"

printf "%-20s : " "Nginx"

systemctl is-active --quiet nginx \
    && echo "OK" \
    || echo "FAIL"


printf "%-20s : " "SSH"

systemctl is-active --quiet ssh \
    && echo "OK" \
    || echo "FAIL"


printf "%-20s : " "Cron"

systemctl is-active --quiet cron \
    && echo "OK" \
    || echo "FAIL"


printf "%-20s : " "x-ui service"

systemctl is-active --quiet x-ui \
    && echo "OK" \
    || echo "FAIL"


printf "%-20s : " "Xray core"

pgrep -af 'xray' >/dev/null 2>&1 \
    && echo "OK" \
    || echo "FAIL"


for port in 2053 8443; do

    printf "%-20s : " "Xray :${port}"

    ss -lnt 2>/dev/null |
        grep -qE ":${port}[[:space:]]" \
        && echo "OK" \
        || echo "FAIL"

done


printf "%-20s : " "UFW"

ufw status |
    grep -q "Status: active" \
    && echo "OK" \
    || echo "FAIL"


###############################################################################
# 43. SERVER INFO
###############################################################################

SERVER_IP="$(
    ip -4 route get 1.1.1.1 2>/dev/null |
    awk '{print $7; exit}'
)"

echo
echo "======================================================================"
echo " ☁️ VPS ГОТОВ"
echo "======================================================================"

echo
echo "IP VPS       : ${SERVER_IP:-unknown}"
echo "SSH          : ${SSH_PORT}"
echo "X-UI         : ${XUI_PORT}"
echo "HTTP         : 80"
echo "HTTPS        : 443"
echo "Xray Inbounds: 2053, 8443"

echo
echo "3x-ui result : /etc/x-ui/install-result.env"
echo "Setup log    : ${LOG_FILE}"
echo "X-UI update  : /var/log/xui-auto-update.log"
echo "X-UI health  : /var/log/xui-health.log"
echo "ACME log     : /var/log/acme-renew.log"
echo "Geo log      : /var/log/xui-geo-update.log"
echo "Backups      : ${BACKUP_DIR}"

echo
echo "SSL схема:"
echo "  Nginx → stop → ACME standalone :80 → start Nginx"

echo
echo "Maintenance (/etc/cron.d/vps-maintenance):"
echo "  SSL          : ежедневно 10:16"
echo "  Backup       : ежедневно 03:00"
echo "  Updates      : среда 03:20"
echo "  x-ui safe    : пятница 04:30 (проверка панели + xray + 2053/8443)"
echo "  Reboot       : пт 05:06, пн/чт 06:00"
echo "  Health       : каждые 30 минут (xray + порты 2053, 8443)"
echo "  Geo          : понедельник 05:00"
echo "  Journal      : суббота 04:15"

echo
echo "X-UI safe update:"
echo "  backup → update → wait 10s → full healthcheck"
echo "  failure → rollback → full healthcheck"

echo
echo "Firewall:"
echo "  SSH   : ${SSH_PORT}"
echo "  HTTP  : 80"
echo "  HTTPS : 443"
echo "  X-UI  : ${XUI_PORT}"
echo "  Xray  : 2053, 2096, 8443, 54325"

echo
echo "======================================================================"
echo " ✅ Установка завершена"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================================"
echo
