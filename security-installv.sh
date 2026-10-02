#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# VPS SECURITY INSTALLER
#
# Назначение:
#   Отдельная установка/настройка Fail2ban + AntiScanner + Cloudflare WARP
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

ANTISCAN_URL="https://gist.githubusercontent.com/sngvy/07cee7ac810c9d222fbebddff8c1d1b8/raw/974d3d87f190468e134e9b56f1e0a93c7caa0fcd/blacklist.txt"
ANTISCAN_SET="SCANNERS-BLOCK-V4"
ANTISCAN_SCRIPT="/usr/local/sbin/antiscan-update.sh"
ANTISCAN_LOG="/var/log/antiscan-update.log"
ANTISCAN_ENV="/etc/default/antiscan"

log(){ printf '\n\033[1;32m>>> %s\033[0m\n' "$*"; }
ok(){ printf '  \033[1;32m[OK]\033[0m %s\n' "$*"; }
warn(){ printf '  \033[1;33m[WARN]\033[0m %s\n' "$*"; }
die(){ printf '  \033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

log "Проверка базовых зависимостей"
apt-get update -qq
apt-get install -y -qq curl ipset iptables gnupg ca-certificates lsb-release >/dev/null 2>&1 \
    || apt-get install -y -qq curl ipset iptables gnupg ca-certificates >/dev/null
ok "curl / ipset / iptables / gnupg / ca-certificates установлены"

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
# Managed by /usr/local/sbin/security-install.sh
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
# ANTISCANNER
###############################################################################
log "AntiScanner: установка и загрузка blacklist"

cat > "$ANTISCAN_ENV" <<EOF_ENV
ANTISCAN_URL="$ANTISCAN_URL"
ANTISCAN_SET="$ANTISCAN_SET"
ANTISCAN_LOG="$ANTISCAN_LOG"
EOF_ENV
chmod 600 "$ANTISCAN_ENV"

cat > "$ANTISCAN_SCRIPT" <<'EOF_ANTISCAN'
set -Eeuo pipefail

source /etc/default/antiscan
URL="$ANTISCAN_URL"
SET_NAME="$ANTISCAN_SET"
TMP_FILE="/run/antiscan-blacklist.txt"
LOG="$ANTISCAN_LOG"
LOCK_FILE="/run/antiscan-update.lock"

mkdir -p "$(dirname "$LOG")"
exec >> "$LOG" 2>&1

log() { echo "[$(date '+%F %T')] $*"; }

command -v ipset >/dev/null 2>&1 || { log "ERROR: ipset not found"; exit 1; }
command -v curl >/dev/null 2>&1 || { log "ERROR: curl not found"; exit 1; }
command -v iptables >/dev/null 2>&1 || { log "ERROR: iptables not found"; exit 1; }

exec 9>"$LOCK_FILE"
flock -n 9 || { log "INFO: update already running"; exit 0; }

TMP_SET="${SET_NAME}-TMP-$$"
cleanup() {
    rm -f "${TMP_FILE}.new"
    ipset destroy "$TMP_SET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p /run

###############################################################################
# DOWNLOAD
###############################################################################

if ! curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 \
    -o "${TMP_FILE}.new" "$URL"; then
    rm -f "${TMP_FILE}.new"
    log "ERROR: failed to download blacklist"
    exit 1
fi

###############################################################################
# VALIDATE
#
# Source may contain IPv4 and IPv6 networks. AntiScanner is intentionally
# IPv4-only (ipset family inet), so IPv6 is accepted in the source and ignored.
# Any other non-empty/non-comment text is treated as invalid.
###############################################################################

if ! awk '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }

    # IPv4 / CIDR
    /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?[[:space:]]*$/ {
        ipv4++
        next
    }

    # IPv6 / CIDR: accepted in source, but not loaded into IPv4 ipset.
    /^[0-9A-Fa-f:]+(\/[0-9]+)?[[:space:]]*$/ {
        ipv6++
        next
    }

    { invalid++ }

    END {
        exit !(ipv4 > 0 && invalid == 0)
    }
' "${TMP_FILE}.new"; then
    rm -f "${TMP_FILE}.new"
    log "ERROR: invalid blacklist format"
    exit 1
fi

mv -f "${TMP_FILE}.new" "$TMP_FILE"

###############################################################################
# BUILD TEMP IPV4 IPSET
###############################################################################

ipset destroy "$TMP_SET" >/dev/null 2>&1 || true
ipset create "$TMP_SET" hash:net family inet hashsize 4096 maxelem 65536

valid=0
while IFS= read -r subnet; do
    subnet="${subnet%%$'\r'}"
    subnet="${subnet//$'\xef\xbb\xbf'/}"
    [[ -z "$subnet" || "$subnet" =~ ^[[:space:]]*# ]] && continue

    subnet="$(printf '%s' "$subnet" | awk '{$1=$1; print}')"
    [[ -z "$subnet" ]] && continue

    # Only IPv4 is loaded into family inet.
    if [[ "$subnet" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
        if ipset add "$TMP_SET" "$subnet" -exist 2>/dev/null; then
            valid=$((valid + 1))
        fi
    fi
done < "$TMP_FILE"

if [[ "$valid" -eq 0 ]]; then
    ipset destroy "$TMP_SET" >/dev/null 2>&1 || true
    log "ERROR: no valid IPv4 networks loaded"
    exit 1
fi

###############################################################################
# ATOMIC SWITCH
###############################################################################

if ipset list "$SET_NAME" >/dev/null 2>&1; then
    ipset swap "$TMP_SET" "$SET_NAME"
    ipset destroy "$TMP_SET" >/dev/null 2>&1 || true
else
    ipset rename "$TMP_SET" "$SET_NAME"
fi

###############################################################################
# IPTABLES RULE
###############################################################################

if ! iptables -C INPUT -m set --match-set "$SET_NAME" src -j DROP >/dev/null 2>&1; then
    iptables -I INPUT 1 -m set --match-set "$SET_NAME" src -j DROP
fi

###############################################################################
# SAVE FIREWALL RULES WHEN AVAILABLE
###############################################################################

if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || true
elif command -v iptables-save >/dev/null 2>&1; then
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi

count="$(ipset list "$SET_NAME" 2>/dev/null | awk '/Number of entries:/ {print $4; exit}')"
log "OK: loaded ${valid} IPv4 networks; ipset entries=${count:-0}"
exit 0
EOF_ANTISCAN

chmod 755 "$ANTISCAN_SCRIPT"

cat > /etc/systemd/system/antiscan.service <<'EOF_SERVICE'
[Unit]
Description=AntiScanner IP blacklist
After=network-online.target ufw.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/antiscan-update.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_SERVICE

systemctl daemon-reload
systemctl enable --now antiscan.service
sleep 1

ipset list "$ANTISCAN_SET" >/dev/null 2>&1 || die "AntiScanner ipset не создан."
iptables -C INPUT -m set --match-set "$ANTISCAN_SET" src -j DROP >/dev/null 2>&1 \
    || die "AntiScanner DROP rule не создан."
ok "AntiScanner активен"

###############################################################################
# DAILY UPDATE
###############################################################################
log "AntiScanner: ежедневное обновление"

mkdir -p /etc/cron.d
CRON_FILE=/etc/cron.d/vps-security
CRON_LINE='30 5 * * * root /usr/local/sbin/antiscan-update.sh >/dev/null 2>&1'

# Удаляем только нашу старую строку и добавляем актуальную.
tmpcron="$(mktemp)"
if [[ -f "$CRON_FILE" ]]; then
    grep -vF '/usr/local/sbin/antiscan-update.sh' "$CRON_FILE" > "$tmpcron" || true
fi
printf '%s\n' "$CRON_LINE" >> "$tmpcron"
install -m 644 "$tmpcron" "$CRON_FILE"
rm -f "$tmpcron"

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

# Ожидание готовности сокета демона warp-svc
for _ in {1..10}; do
    if run_warp_cli status >/dev/null 2>&1 || run_warp_cli registration show >/dev/null 2>&1 || run_warp_cli account >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

# Регистрация устройства (если не было зарегистрировано)
if ! run_warp_cli registration show >/dev/null 2>&1 && ! run_warp_cli account >/dev/null 2>&1; then
    run_warp_cli registration new >/dev/null 2>&1 || run_warp_cli register >/dev/null 2>&1 || true
    ok "Клиент Cloudflare WARP зарегистрирован"
else
    ok "Регистрация Cloudflare WARP уже существует"
fi

# Настройка режима SOCKS5-прокси (чтобы не нарушать SSH и маршрутизацию VPS)
run_warp_cli mode proxy >/dev/null 2>&1 || run_warp_cli set-mode proxy >/dev/null 2>&1 || true
run_warp_cli proxy port "$WARP_PORT" >/dev/null 2>&1 || run_warp_cli set-proxy-port "$WARP_PORT" >/dev/null 2>&1 || true
run_warp_cli connect >/dev/null 2>&1 || true

# Ожидание открытия порта
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
    read -r -p "Выбор [1-3]: " MOTD_CHOICE
else
    echo
    echo "$MOTD_FILE не найден."
    echo
    echo "1) Создать $MOTD_SECURITY_FILE"
    echo "2) Ничего не менять"
    echo
    read -r -p "Выбор [1-2]: " MOTD_CHOICE
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

# Удаляем только нашу управляемую секцию, чтобы повторный запуск не дублировал код.
s = re.sub(r'\n?# === SECURITY STATUS BEGIN ===\n.*?\n# === SECURITY STATUS END ===\n?', '\n', s, flags=re.S)

marker = 'echo -e "  ${PURPLE}СТАТУС СЛУЖБ:${NONE}"'
if marker not in s:
    raise SystemExit('Не найден блок "СТАТУС СЛУЖБ" в 99-custom-sysinfo')

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

if check_active_security antiscan.service && ipset list SCANNERS-BLOCK-V4 >/dev/null 2>&1 && iptables -C INPUT -m set --match-set SCANNERS-BLOCK-V4 src -j DROP >/dev/null 2>&1; then
    SCANNER_COUNT="$(ipset list SCANNERS-BLOCK-V4 2>/dev/null | awk '/Number of entries:/ {print $4; exit}')"
    SCANNER_COUNT="${SCANNER_COUNT:-0}"
    STATUS_ANTISCAN="${GREEN_B}RUNNING | networks: ${SCANNER_COUNT}${NONE}"
else
    STATUS_ANTISCAN="${RED_B}STOPPED${NONE}"
fi
# === SECURITY STATUS END ===
"""

s = s.replace(marker, block + '\n' + marker, 1)

# Удаляем старые строки статусов безопасности, если они уже присутствуют.
s = re.sub(r'^printf "    %-22s : %b\\n" "(?:  )?(?:Fail2ban|SSH jail|AntiScanner)".*\n', '', s, flags=re.M)

# Вставляем статусы сразу после Cloudflare WARP (или после СТАТУС СЛУЖБ, если строка отсутствует).
pat = re.compile(r'^[ \t]*.*"Cloudflare WARP".*$', re.M)
m = pat.search(s)
addition = 'printf "    %-22s : %b\\n" "Fail2ban" "$STATUS_FAIL2BAN"\nprintf "    %-22s : %b\\n" "  SSH jail" "$STATUS_SSH_JAIL"\nprintf "    %-22s : %b\\n" "AntiScanner" "$STATUS_ANTISCAN"'
if m:
    s = s[:m.end()] + '\n' + addition + s[m.end():]
else:
    s = s.replace(marker, marker + '\n' + addition)

path.write_text(s)
PY_MOTD

    chmod 755 "$MOTD_FILE"
    ok "Fail2ban / SSH jail / AntiScanner интегрированы в СТАТУС СЛУЖБ"

elif [[ "$MOTD_CHOICE" == "2" ]]; then
    cat > "$MOTD_SECURITY_FILE" <<'EOF_MOTD_SECURITY'
#!/usr/bin/env bash
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NONE='\033[0m'
check_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
if check_active fail2ban; then F2B_STATUS="${GREEN}OK${NONE}"; else F2B_STATUS="${RED}FAIL${NONE}"; fi
if check_active fail2ban && fail2ban-client status sshd >/dev/null 2>&1; then
    F2B_BANNED="$(fail2ban-client status sshd 2>/dev/null | awk -F: '/Currently banned:/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')"
    F2B_BANNED="${F2B_BANNED:-0}"
    F2B_JAIL="${GREEN}OK | banned: ${F2B_BANNED}${NONE}"
else
    F2B_JAIL="${RED}FAIL${NONE}"
fi
if check_active antiscan.service && ipset list SCANNERS-BLOCK-V4 >/dev/null 2>&1 && iptables -C INPUT -m set --match-set SCANNERS-BLOCK-V4 src -j DROP >/dev/null 2>&1; then
    SCANNER_COUNT="$(ipset list SCANNERS-BLOCK-V4 2>/dev/null | awk '/Number of entries:/ {print $4; exit}')"
    SCANNER_COUNT="${SCANNER_COUNT:-0}"
    ANTISCAN_STATUS="${GREEN}OK | networks: ${SCANNER_COUNT}${NONE}"
else
    ANTISCAN_STATUS="${RED}FAIL${NONE}"
fi
if ss -lnt 2>/dev/null | grep -qE ':40000[[:space:]]'; then
    WARP_STATUS="${GREEN}RUNNING (SOCKS5 :40000)${NONE}"
elif check_active warp-svc; then
    WARP_STATUS="${YELLOW}CONNECTING (warp-svc)${NONE}"
else
    WARP_STATUS="${RED}STOPPED${NONE}"
fi
printf '\n'
echo -e "  \033[0;36m🛡️ SECURITY${NONE}"
printf "    %-22s : %b\n" "Fail2ban" "$F2B_STATUS"
printf "    %-22s : %b\n" "SSH jail" "$F2B_JAIL"
printf "    %-22s : %b\n" "AntiScanner" "$ANTISCAN_STATUS"
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
printf 'Fail2ban sshd jail    : '; fail2ban-client status sshd >/dev/null 2>&1 && echo 'OK' || echo 'FAIL'
printf 'Fail2ban recidive     : '; fail2ban-client status recidive >/dev/null 2>&1 && echo 'OK' || echo 'WARN'
printf 'SSH port              : %s\n' "$SSH_PORT"
printf 'AntiScanner service   : '; systemctl is-active --quiet antiscan.service && echo 'OK' || echo 'FAIL'
printf 'AntiScanner ipset     : '; ipset list "$ANTISCAN_SET" >/dev/null 2>&1 && echo 'OK' || echo 'FAIL'
printf 'AntiScanner DROP      : '; iptables -C INPUT -m set --match-set "$ANTISCAN_SET" src -j DROP >/dev/null 2>&1 && echo 'OK' || echo 'FAIL'
printf 'Scanner networks      : %s\n' "$(ipset list "$ANTISCAN_SET" 2>/dev/null | awk '/Number of entries:/ {print $4; exit}')"
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
echo "Готово."
echo "AntiScanner ручное обновление: $ANTISCAN_SCRIPT"
echo "AntiScanner лог:              $ANTISCAN_LOG"
echo "Fail2ban конфиг:              $F2B_CONF"
echo "WARP SOCKS5 прокси:           127.0.0.1:${WARP_PORT}"
