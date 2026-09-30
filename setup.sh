#!/usr/bin/env bash

###############################################################################
# вЃпёЏ VPS BOOTSTRAP / SETUP
# Р’РµСЂСЃРёСЏ: 3.2
#
# Ubuntu / Debian
#
# РќР°Р·РЅР°С‡РµРЅРёРµ:
#   РџРµСЂРІРёС‡РЅР°СЏ РЅР°СЃС‚СЂРѕР№РєР° VPS:
#   - Nginx
#   - BBR / FQ / TCP Fast Open
#   - SWAP
#   - UFW
#   - SSH
#   - 3x-ui
#   - Let's Encrypt / ACME
#   - СЂРµР·РµСЂРІРЅС‹Рµ РєРѕРїРёРё
#   - healthcheck
#   - geo-С„Р°Р№Р»С‹
#   - СЃРёСЃС‚РµРјРЅРѕРµ РѕР±СЃР»СѓР¶РёРІР°РЅРёРµ
#
# РљР›Р®Р§Р•Р’РђРЇ SSL-РђР РҐРРўР•РљРўРЈР Рђ:
#
#   Nginx :80
#       в†“
#   stop nginx
#       в†“
#   acme.sh standalone :80
#       в†“
#   Let's Encrypt HTTP-01
#       в†“
#   СЃРµСЂС‚РёС„РёРєР°С‚
#       в†“
#   start nginx
#
###############################################################################

set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

SCRIPT_VERSION="3.2"

LOG_FILE="/var/log/vps-setup.log"

SSH_PORT="1241"

XUI_PORT="8784"

ACME_PORT="80"

XUI_INSTALL_URL="https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh"

BACKUP_DIR="/root/xui_backups"

MAINTENANCE_FILE="/etc/cron.d/vps-maintenance"


###############################################################################
# 1. Р›РћР“РР РћР’РђРќРР•
###############################################################################

mkdir -p "$(dirname "$LOG_FILE")"

touch "$LOG_FILE"

chmod 600 "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

echo
echo "======================================================================"
echo " вЃпёЏ VPS SETUP ${SCRIPT_VERSION}"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================================"
echo


###############################################################################
# 2. РћР‘Р РђР‘РћРўР§РРљ РћРЁРР‘РћРљ
###############################################################################

on_error() {

    local exit_code=$?

    echo
    echo "======================================================================"
    echo " вќЊ РћРЁРР‘РљРђ РЈРЎРўРђРќРћР’РљР"
    echo " РљРѕРґ: ${exit_code}"
    echo " РЎС‚СЂРѕРєР°: ${BASH_LINENO[0]:-unknown}"
    echo " Р›РѕРі: ${LOG_FILE}"
    echo "======================================================================"
    echo

    exit "$exit_code"
}

trap on_error ERR


###############################################################################
# 3. ROOT
###############################################################################

if [[ "${EUID}" -ne 0 ]]; then

    echo "вќЊ РЎРєСЂРёРїС‚ РЅРµРѕР±С…РѕРґРёРјРѕ Р·Р°РїСѓСЃРєР°С‚СЊ РѕС‚ root."

    exit 1

fi


###############################################################################
# 4. РћРЎ
###############################################################################

if [[ ! -f /etc/os-release ]]; then

    echo "вќЊ РќРµ РЅР°Р№РґРµРЅ /etc/os-release."

    exit 1

fi

source /etc/os-release

echo "OS: ${PRETTY_NAME:-unknown}"

case "${ID:-}" in

    ubuntu|debian)
        ;;

    *)
        echo
        echo "вќЊ РџРѕРґРґРµСЂР¶РёРІР°СЋС‚СЃСЏ Ubuntu/Debian."
        echo "РћР±РЅР°СЂСѓР¶РµРЅРѕ: ${ID:-unknown}"
        echo
        exit 1
        ;;

esac


###############################################################################
# 5. РђР РҐРРўР•РљРўРЈР Рђ
###############################################################################

ARCH="$(dpkg --print-architecture 2>/dev/null || true)"

echo "РђСЂС…РёС‚РµРєС‚СѓСЂР°: ${ARCH:-unknown}"


###############################################################################
# 6. APT
###############################################################################

echo
echo ">>> РћР±РЅРѕРІР»РµРЅРёРµ РїР°РєРµС‚РѕРІ..."

apt-get update

apt-get upgrade -y


###############################################################################
# 7. Р‘РђР—РћР’Р«Р• РџРђРљР•РўР«
###############################################################################

echo
echo ">>> РЈСЃС‚Р°РЅРѕРІРєР° Р±Р°Р·РѕРІС‹С… РїР°РєРµС‚РѕРІ..."

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
    iptables-persistent \
    ufw \
    socat \
    sqlite3 \
    ca-certificates \
    openssl \
    jq \
    unzip \
    lsof \
    procps \
    net-tools


###############################################################################
# 8. CRON
###############################################################################

systemctl enable --now cron


###############################################################################
# 9. SYSCTL / BBR
###############################################################################

echo
echo ">>> РќР°СЃС‚СЂРѕР№РєР° TCP..."

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
# 10. SWAP
###############################################################################

if ! swapon --show | grep -q .; then

    echo
    echo ">>> РЎРѕР·РґР°РЅРёРµ SWAP 2 GB..."

    if [[ ! -f /swapfile ]]; then

        fallocate -l 2G /swapfile

        chmod 600 /swapfile

        mkswap /swapfile

    fi

    swapon /swapfile

    if ! grep -qE '^/swapfile\s' /etc/fstab; then

        echo '/swapfile none swap sw 0 0' >> /etc/fstab

    fi

else

    echo "вњ“ SWAP СѓР¶Рµ СЃСѓС‰РµСЃС‚РІСѓРµС‚."

fi


###############################################################################
# 11. NGINX
###############################################################################

echo
echo ">>> РќР°СЃС‚СЂРѕР№РєР° Nginx..."

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

ln -sf /etc/nginx/sites-available/cloud-node \
    /etc/nginx/sites-enabled/cloud-node

nginx -t

systemctl enable nginx

systemctl restart nginx


###############################################################################
# 12. MOTD
###############################################################################

echo
echo ">>> РќР°СЃС‚СЂРѕР№РєР° MOTD..."

cat > /etc/update-motd.d/99-custom-sysinfo <<'EOF'
#!/usr/bin/env bash

echo
echo "в•”в•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•—"
echo "в•‘                     вЃпёЏ  CLOUD NODE                              в•‘"
echo "в•љв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ќ"
echo

echo "рџ•’ $(date '+%Y-%m-%d %H:%M:%S')"

echo "вЏ± Uptime: $(uptime -p)"

echo

echo "рџЊђ NETWORK"

ip -4 -brief addr show scope global 2>/dev/null || true

echo

echo "рџ“Ў PING"

printf "Yandex: "

ping -c 1 -W 1 77.88.8.8 >/dev/null 2>&1 \
    && echo "OK" \
    || echo "FAIL"

echo

echo "рџ–Ґ SYSTEM"

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

echo "рџ’ѕ MEMORY"

free -h

echo

echo "рџ’Ѕ DISK"

df -h / | tail -n 1

echo

echo "рџ“Љ INODES"

df -ih / | tail -n 1

echo

echo "рџ”Њ CONNECTIONS"

echo "TCP: $(ss -tan 2>/dev/null | tail -n +2 | wc -l)"

echo "UDP: $(ss -uan 2>/dev/null | tail -n +2 | wc -l)"

echo

echo "рџ‘¤ SSH"

who 2>/dev/null || true

echo

echo "вљ™пёЏ SERVICES"

for service in nginx ssh x-ui docker; do

    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo "  вњ“ ${service}"
    else
        echo "  вњ— ${service}"
    fi

done

echo

echo "рџ“¦ DOCKER"

if command -v docker >/dev/null 2>&1; then

    docker ps --format '  {{.Names}} вЂ” {{.Status}}' 2>/dev/null || true
else
    echo "  Docker РЅРµ СѓСЃС‚Р°РЅРѕРІР»РµРЅ"
fi

echo

echo "рџ”ђ FIREWALL"

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

chmod 700 "$BACKUP_DIR"


###############################################################################
# 14. LOCAL MSSQL HEALTH KEY
###############################################################################

if [[ ! -f /root/.mssql_health.key ]]; then

    umask 077

    openssl rand -base64 32 > /root/.mssql_health.key

    chmod 600 /root/.mssql_health.key

fi


###############################################################################
# 15. X-UI HEALTH CHECK
###############################################################################

echo
echo ">>> РЎРѕР·РґР°РЅРёРµ x-ui healthcheck..."

cat > /usr/local/sbin/xui-health.sh <<'EOF'
#!/usr/bin/env bash

set -u

SERVICE="x-ui"

if systemctl is-active --quiet "$SERVICE"; then
    exit 0
fi

logger -t xui-health "x-ui is not running; attempting restart"

systemctl restart "$SERVICE"

sleep 5

if systemctl is-active --quiet "$SERVICE"; then

    logger -t xui-health "x-ui successfully restarted"

    exit 0

fi

logger -t xui-health "ERROR: x-ui failed to restart"

exit 1
EOF

chmod 700 /usr/local/sbin/xui-health.sh


###############################################################################
# 16. X-UI BACKUP
###############################################################################

echo
echo ">>> РЎРѕР·РґР°РЅРёРµ СЂРµР·РµСЂРІРЅРѕРіРѕ РєРѕРїРёСЂРѕРІР°РЅРёСЏ x-ui..."

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

[[ -d /etc/x-ui ]] && SOURCE_LIST+=("/etc/x-ui")

[[ -d /usr/local/x-ui ]] && SOURCE_LIST+=("/usr/local/x-ui")

[[ -d /root/.acme.sh ]] && SOURCE_LIST+=("/root/.acme.sh")

if [[ "${#SOURCE_LIST[@]}" -eq 0 ]]; then

    echo "No x-ui data found."

    exit 0

fi

tar -czf "$TMP_FILE" \
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
# 17. SYSTEM UPDATE
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
# 18. GEO DATABASE UPDATE
#
# РСЃРїРѕР»СЊР·СѓРµРј С€С‚Р°С‚РЅСѓСЋ CLI-РєРѕРјР°РЅРґСѓ x-ui.
# РќРµ РѕР±СЂР°С‰Р°РµРјСЃСЏ Рє /usr/local/x-ui/bin/x-ui.
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

if command -v x-ui >/dev/null 2>&1; then

    x-ui update-all-geofiles

else

    echo "$(date '+%F %T') ERROR: x-ui command not found"

    exit 1

fi
EOF

chmod 700 /usr/local/sbin/update-geo.sh

touch /var/log/xui-geo-update.log

chmod 600 /var/log/xui-geo-update.log


###############################################################################
# 19. SSL RENEWAL WRAPPER
#
# Р’РђР–РќРћ:
# acme.sh СЃР°Рј СѓСЃС‚Р°РЅР°РІР»РёРІР°РµС‚ РµР¶РµРґРЅРµРІРЅС‹Р№ cron.
# РџРѕСЃР»Рµ СѓСЃС‚Р°РЅРѕРІРєРё 3x-ui РјС‹ РµРіРѕ СѓРґР°Р»СЏРµРј Рё РёСЃРїРѕР»СЊР·СѓРµРј РўРћР›Р¬РљРћ СЌС‚РѕС‚ wrapper.
#
# РџСЂРёС‡РёРЅР°:
# standalone ACME РґРѕР»Р¶РµРЅ РїРѕР»СѓС‡РёС‚СЊ СЃРІРѕР±РѕРґРЅС‹Р№ TCP/80.
###############################################################################

echo
echo ">>> РЎРѕР·РґР°РЅРёРµ SSL renewal wrapper..."

cat > /usr/local/bin/renew-ssl.sh <<'EOF'
#!/usr/bin/env bash

set -Eeuo pipefail

LOG="/var/log/acme-renew.log"

ACME="/root/.acme.sh/acme.sh"

NGINX_WAS_ACTIVE=0

exec >> "$LOG" 2>&1

echo
echo "======================================================================"
echo " рџ”ђ SSL RENEW"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================================"


###############################################################################
# РЎРѕС…СЂР°РЅСЏРµРј СЃРѕСЃС‚РѕСЏРЅРёРµ Nginx
###############################################################################

if systemctl is-active --quiet nginx; then

    NGINX_WAS_ACTIVE=1

    echo "$(date '+%F %T') stopping nginx for standalone ACME"

    systemctl stop nginx

fi


###############################################################################
# Р’РЎР•Р“Р”Рђ РІРѕР·РІСЂР°С‰Р°РµРј Nginx
###############################################################################

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


###############################################################################
# РџСЂРѕРІРµСЂРєР° acme.sh
###############################################################################

if [[ ! -x "$ACME" ]]; then

    echo "$(date '+%F %T') ERROR: acme.sh not found"

    exit 1

fi


###############################################################################
# Renewal
###############################################################################

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
# 20. SSH
#
# Ubuntu 22.10+ / 24.04:
# ssh.socket РјРѕР¶РµС‚ РёСЃРїРѕР»СЊР·РѕРІР°С‚СЊ socket activation.
###############################################################################

echo
echo ">>> РќР°СЃС‚СЂРѕР№РєР° SSH..."

SSHD_CONFIG="/etc/ssh/sshd_config"

if grep -qE '^[#[:space:]]*Port[[:space:]]+' "$SSHD_CONFIG"; then

    sed -i \
        -E "s/^[#[:space:]]*Port[[:space:]]+.*/Port ${SSH_PORT}/" \
        "$SSHD_CONFIG"

else

    echo "Port ${SSH_PORT}" >> "$SSHD_CONFIG"

fi


###############################################################################
# РћС‚РєР»СЋС‡Р°РµРј socket activation, РµСЃР»Рё РёСЃРїРѕР»СЊР·СѓРµС‚СЃСЏ
###############################################################################

systemctl disable --now ssh.socket 2>/dev/null || true


###############################################################################
# РџСЂРѕРІРµСЂСЏРµРј РєРѕРЅС„РёРіСѓСЂР°С†РёСЋ Р”Рћ РїРµСЂРµР·Р°РїСѓСЃРєР°
###############################################################################

sshd -t


###############################################################################
# РџРµСЂРµР·Р°РїСѓСЃРєР°РµРј SSH
###############################################################################

systemctl restart ssh

sleep 2


###############################################################################
# РџСЂРѕРІРµСЂСЏРµРј РЅРѕРІС‹Р№ РїРѕСЂС‚
###############################################################################

if ! ss -lnt | grep -qE ":${SSH_PORT}[[:space:]]"; then

    echo
    echo "вќЊ SSH РќР• СЃР»СѓС€Р°РµС‚ РїРѕСЂС‚ ${SSH_PORT}."
    echo

    echo "РўРµРєСѓС‰РёРµ SSH-РїРѕСЂС‚С‹:"

    ss -lntp | grep -E ':(22|1241)\b' || true

    exit 1

fi

echo "вњ“ SSH СЃР»СѓС€Р°РµС‚ РїРѕСЂС‚ ${SSH_PORT}"


###############################################################################
# 21. UFW
###############################################################################

echo
echo ">>> РќР°СЃС‚СЂРѕР№РєР° firewall..."

ufw --force reset

ufw default deny incoming

ufw default allow outgoing


###############################################################################
# SSH
###############################################################################

ufw allow "${SSH_PORT}/tcp" comment 'SSH'


###############################################################################
# HTTP / HTTPS
###############################################################################

ufw allow 80/tcp comment 'HTTP'

ufw allow 443/tcp comment 'HTTPS'


###############################################################################
# DNS
###############################################################################

ufw allow 53/tcp comment 'DNS TCP'

ufw allow 53/udp comment 'DNS UDP'


###############################################################################
# X-UI / SERVICES
###############################################################################

ufw allow 2053/tcp comment 'x-ui'

ufw allow 2096/tcp comment 'x-ui'

ufw allow 8443/tcp comment 'Service 8443'

ufw allow 8784/tcp comment 'x-ui panel'

ufw allow 54325/tcp comment 'Service 54325'


###############################################################################
# 22. ICMP
#
# Р‘Р»РѕРєРёСЂСѓРµРј РІС…РѕРґСЏС‰РёР№ ping.
# Р­С‚Рѕ РєР°СЃР°РµС‚СЃСЏ РёРјРµРЅРЅРѕ echo-request.
###############################################################################

echo
echo ">>> РќР°СЃС‚СЂРѕР№РєР° ICMP..."

UFW_BEFORE="/etc/ufw/before.rules"

if grep -qE -- "-p icmp --icmp-type echo-request -j ACCEPT" "$UFW_BEFORE"; then

    sed -i \
        's/-p icmp --icmp-type echo-request -j ACCEPT/-p icmp --icmp-type echo-request -j DROP/' \
        "$UFW_BEFORE"

    echo "вњ“ IPv4 ICMP echo-request Р·Р°Р±Р»РѕРєРёСЂРѕРІР°РЅ"

else

    echo "вљ пёЏ IPv4 РїСЂР°РІРёР»Рѕ ICMP echo-request РЅРµ РЅР°Р№РґРµРЅРѕ."

fi


###############################################################################
# IPv6 ICMP
###############################################################################

UFW_BEFORE6="/etc/ufw/before6.rules"

if [[ -f "$UFW_BEFORE6" ]]; then

    if grep -qE -- "-p ipv6-icmp --icmpv6-type echo-request -j ACCEPT" "$UFW_BEFORE6"; then

        sed -i \
            's/-p ipv6-icmp --icmpv6-type echo-request -j ACCEPT/-p ipv6-icmp --icmpv6-type echo-request -j DROP/' \
            "$UFW_BEFORE6"

        echo "вњ“ IPv6 ICMP echo-request Р·Р°Р±Р»РѕРєРёСЂРѕРІР°РЅ"

    else

        echo "вљ пёЏ IPv6 РїСЂР°РІРёР»Рѕ ICMP echo-request РЅРµ РЅР°Р№РґРµРЅРѕ."

    fi

fi


###############################################################################
# 23. Р’РљР›Р®Р§РђР•Рњ UFW
###############################################################################

ufw --force enable

ufw reload

ufw status verbose


###############################################################################
# 24. NGINX STOP Р”Р›РЇ 3X-UI
#
# РќРђРњР•Р Р•РќРќРћ.
#
# 3x-ui РёСЃРїРѕР»СЊР·СѓРµС‚ ACME standalone.
# Nginx Р·Р°РЅРёРјР°РµС‚ TCP/80.
#
# РџРѕСЌС‚РѕРјСѓ РѕСЃРІРѕР±РѕР¶РґР°РµРј РїРѕСЂС‚ РґРѕ СѓСЃС‚Р°РЅРѕРІРєРё СЃРµСЂС‚РёС„РёРєР°С‚Р°.
###############################################################################

echo
echo "======================================================================"
echo " рџ”ђ РџРћР”Р“РћРўРћР’РљРђ ACME"
echo "======================================================================"

if systemctl is-active --quiet nginx; then

    echo "РћСЃС‚Р°РЅР°РІР»РёРІР°РµРј Nginx РїРµСЂРµРґ СѓСЃС‚Р°РЅРѕРІРєРѕР№ 3x-ui..."

    systemctl stop nginx

fi


###############################################################################
# 25. РЎРљРђР§РР’РђР•Рњ 3X-UI INSTALLER
###############################################################################

echo
echo "======================================================================"
echo " рџ“¦ РЈСЃС‚Р°РЅРѕРІРєР° 3x-ui"
echo "======================================================================"

TMP_XUI_INSTALL="/tmp/3x-ui-install.sh"

rm -f "$TMP_XUI_INSTALL"

curl \
    -4 \
    -fL \
    --retry 3 \
    --connect-timeout 15 \
    "$XUI_INSTALL_URL" \
    -o "$TMP_XUI_INSTALL"

chmod 700 "$TMP_XUI_INSTALL"


###############################################################################
# 26. UNATTENDED 3X-UI
#
# РђРєС‚СѓР°Р»СЊРЅС‹Рµ РїР°СЂР°РјРµС‚СЂС‹ upstream:
#
# XUI_NONINTERACTIVE=1
# XUI_SSL_MODE=ip
# XUI_PANEL_PORT=8784
# XUI_ACME_HTTP_PORT=80
###############################################################################

export XUI_NONINTERACTIVE=1

export XUI_SSL_MODE="ip"

export XUI_PANEL_PORT="$XUI_PORT"

export XUI_ACME_HTTP_PORT="$ACME_PORT"


echo
echo "РџР°СЂР°РјРµС‚СЂС‹ 3x-ui:"
echo "  Panel port : ${XUI_PANEL_PORT}"
echo "  SSL mode   : ${XUI_SSL_MODE}"
echo "  ACME port  : ${XUI_ACME_HTTP_PORT}"
echo


###############################################################################
# 27. Р—РђРџРЈРЎРљ 3X-UI INSTALLER
###############################################################################

bash "$TMP_XUI_INSTALL"


###############################################################################
# 28. РЈР”РђР›РЇР•Рњ РЁРўРђРўРќР«Р™ ACME CRON
#
# 3x-ui / acme.sh СЃРѕР·РґР°С‘С‚ СЃРѕР±СЃС‚РІРµРЅРЅС‹Р№ cron.
# РќР°Рј РЅСѓР¶РµРЅ РѕРґРёРЅ-РµРґРёРЅСЃС‚РІРµРЅРЅС‹Р№ renewal:
#
#   РЅР°С€ wrapper
#       в†“
#   stop nginx
#       в†“
#   acme.sh --cron
#       в†“
#   start nginx
#
###############################################################################

echo
echo ">>> РќР°СЃС‚СЂРѕР№РєР° ACME cron..."

ACME="/root/.acme.sh/acme.sh"

if [[ -x "$ACME" ]]; then

    "$ACME" \
        --uninstall-cronjob \
        >/dev/null 2>&1 \
        || true

    echo "вњ“ РЁС‚Р°С‚РЅС‹Р№ cron acme.sh СѓРґР°Р»С‘РЅ"

else

    echo "вљ пёЏ acme.sh РЅРµ РЅР°Р№РґРµРЅ РїРѕСЃР»Рµ СѓСЃС‚Р°РЅРѕРІРєРё 3x-ui."

fi


###############################################################################
# 29. Р’РћРЎРЎРўРђРќРђР’Р›РР’РђР•Рњ NGINX
###############################################################################

echo
echo ">>> Р’РѕСЃСЃС‚Р°РЅРѕРІР»РµРЅРёРµ Nginx..."

systemctl enable nginx

nginx -t

systemctl start nginx

if ! systemctl is-active --quiet nginx; then

    echo "вќЊ Nginx РЅРµ Р·Р°РїСѓСЃС‚РёР»СЃСЏ."

    systemctl status nginx --no-pager || true

    exit 1

fi

echo "вњ“ Nginx СЂР°Р±РѕС‚Р°РµС‚"


###############################################################################
# 30. SSH FINAL CHECK
###############################################################################

echo
echo ">>> Р¤РёРЅР°Р»СЊРЅР°СЏ РїСЂРѕРІРµСЂРєР° SSH..."

sshd -t

if ! ss -lnt | grep -qE ":${SSH_PORT}[[:space:]]"; then

    echo "вќЊ SSH РїРѕСЂС‚ ${SSH_PORT} РЅРµ СЃР»СѓС€Р°РµС‚СЃСЏ."

    exit 1

fi

echo "вњ“ SSH ${SSH_PORT}"


###############################################################################
# 31. X-UI CHECK
###############################################################################

echo
echo ">>> РџСЂРѕРІРµСЂРєР° x-ui..."

if systemctl is-enabled x-ui >/dev/null 2>&1; then

    echo "вњ“ x-ui enabled"

else

    echo "вљ пёЏ x-ui РЅРµ enabled"

fi

if systemctl is-active --quiet x-ui; then

    echo "вњ“ x-ui СЂР°Р±РѕС‚Р°РµС‚"

else

    echo "вљ пёЏ x-ui РЅРµ Р·Р°РїСѓС‰РµРЅ"

    systemctl status x-ui --no-pager || true

fi


###############################################################################
# 32. CRON
###############################################################################

echo
echo ">>> РќР°СЃС‚СЂРѕР№РєР° maintenance cron..."

cat > "$MAINTENANCE_FILE" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# SSL / ACME
16 10 * * * root /usr/local/bin/renew-ssl.sh

# X-UI backup
0 3 * * * root /usr/local/sbin/xui-backup.sh

# System updates
20 3 * * 3 root /usr/local/sbin/system-update.sh

# X-UI update
30 4 * * 5 root /usr/local/bin/x-ui update >> /var/log/xui-update.log 2>&1

# X-UI health check
*/30 * * * * root /usr/local/sbin/xui-health.sh

# Geo database update
0 5 * * 1 root /usr/local/sbin/update-geo.sh

# Journal cleanup
15 4 * * 6 root /usr/bin/journalctl --vacuum-time=14d >/dev/null 2>&1
EOF

chmod 644 "$MAINTENANCE_FILE"

systemctl restart cron


###############################################################################
# 33. РџР РћР’Р•Р РљРђ ACME CRON
###############################################################################

echo
echo ">>> РџСЂРѕРІРµСЂРєР° cron..."

if crontab -l 2>/dev/null | grep -q 'acme.sh.*--cron'; then

    echo "вљ пёЏ Р’ root crontab РІСЃС‘ РµС‰С‘ РЅР°Р№РґРµРЅ acme.sh cron."

    crontab -l 2>/dev/null | grep 'acme.sh.*--cron' || true

else

    echo "вњ“ Р”СѓР±Р»РёСЂСѓСЋС‰РёР№ acme.sh cron РѕС‚СЃСѓС‚СЃС‚РІСѓРµС‚"

fi


###############################################################################
# 34. РџР РћР’Р•Р РљРђ РџРћР РўРћР’
###############################################################################

echo
echo "======================================================================"
echo " рџ”Ћ РџР РћР’Р•Р РљРђ РџРћР РўРћР’"
echo "======================================================================"

ss -lntp | grep -E \
    ":(80|443|${SSH_PORT}|${XUI_PORT}|2053|2096|8443|54325)\b" \
    || true


###############################################################################
# 35. FIREWALL
###############################################################################

echo
echo "======================================================================"
echo " рџ”Ґ FIREWALL"
echo "======================================================================"

ufw status numbered


###############################################################################
# 36. X-UI INSTALL RESULT
###############################################################################

echo
echo "======================================================================"
echo " рџ”ђ Р Р•Р—РЈР›Р¬РўРђРў РЈРЎРўРђРќРћР’РљР 3X-UI"
echo "======================================================================"

if [[ -f /etc/x-ui/install-result.env ]]; then

    echo
    echo "Р¤Р°Р№Р» СЂРµР·СѓР»СЊС‚Р°С‚Р°:"
    echo "  /etc/x-ui/install-result.env"
    echo

    sed \
        -E 's/^(XUI_PASSWORD=).*/\1********/' \
        /etc/x-ui/install-result.env \
        || true

else

    echo "вљ пёЏ /etc/x-ui/install-result.env РЅРµ РЅР°Р№РґРµРЅ."

fi


###############################################################################
# 37. ACME CERTIFICATES
###############################################################################

echo
echo "======================================================================"
echo " рџ”ђ ACME"
echo "======================================================================"

if [[ -x /root/.acme.sh/acme.sh ]]; then

    echo "вњ“ acme.sh СѓСЃС‚Р°РЅРѕРІР»РµРЅ"

    /root/.acme.sh/acme.sh \
        --list \
        2>/dev/null \
        || true

else

    echo "вљ пёЏ acme.sh РЅРµ РЅР°Р№РґРµРЅ."

fi


###############################################################################
# 38. Р¤РРќРђР›Р¬РќРђРЇ РџР РћР’Р•Р РљРђ
###############################################################################

echo
echo "======================================================================"
echo " вњ… Р¤РРќРђР›Р¬РќРђРЇ РџР РћР’Р•Р РљРђ"
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


printf "%-20s : " "x-ui"

systemctl is-active --quiet x-ui \
    && echo "OK" \
    || echo "FAIL"


printf "%-20s : " "UFW"

ufw status | grep -q "Status: active" \
    && echo "OK" \
    || echo "FAIL"


###############################################################################
# 39. SERVER INFO
###############################################################################

SERVER_IP="$(
    ip -4 route get 1.1.1.1 2>/dev/null |
    awk '{print $7; exit}'
)"

echo
echo "======================================================================"
echo " вЃпёЏ VPS Р“РћРўРћР’"
echo "======================================================================"

echo
echo "IP VPS       : ${SERVER_IP:-unknown}"
echo "SSH          : ${SSH_PORT}"
echo "X-UI         : ${XUI_PORT}"
echo "HTTP         : 80"
echo "HTTPS        : 443"
echo
echo "3x-ui result : /etc/x-ui/install-result.env"
echo "Setup log    : ${LOG_FILE}"
echo "ACME log     : /var/log/acme-renew.log"
echo "Geo log      : /var/log/xui-geo-update.log"
echo "Backups      : ${BACKUP_DIR}"
echo
echo "SSL СЃС…РµРјР°:"
echo "  Nginx в†’ stop в†’ ACME standalone :80 в†’ start Nginx"
echo
echo "Maintenance:"
echo "  SSL       : РµР¶РµРґРЅРµРІРЅРѕ 10:16"
echo "  Backup    : РµР¶РµРґРЅРµРІРЅРѕ 03:00"
echo "  Updates   : СЃСЂРµРґР° 03:20"
echo "  x-ui      : РїСЏС‚РЅРёС†Р° 04:30"
echo "  Health    : РєР°Р¶РґС‹Рµ 30 РјРёРЅСѓС‚"
echo "  Geo       : РїРѕРЅРµРґРµР»СЊРЅРёРє 05:00"
echo "  Journal   : СЃСѓР±Р±РѕС‚Р° 04:15"
echo
echo "======================================================================"
echo " вњ… РЈСЃС‚Р°РЅРѕРІРєР° Р·Р°РІРµСЂС€РµРЅР°"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================================"
echo
