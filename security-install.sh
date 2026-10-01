#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# VPS SECURITY INSTALLER
#
# Назначение:
#   Отдельная установка/настройка Fail2ban + AntiScanner
#   на уже работающем Debian/Ubuntu VPS.
#
# Повторный запуск безопасен: существующие конфиги не затираются без backup.
###############################################################################

SSH_PORT="$(sshd -T 2>/dev/null | awk '$1=="port" {print $2; exit}' || true)"
SSH_PORT="${SSH_PORT:-22}"

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

[[ $EUID -eq 0 ]] || die "Запускать только от root."
command -v apt-get >/dev/null 2>&1 || die "Поддерживается Debian/Ubuntu (apt-get не найден)."

log "Проверка базовых зависимостей"
apt-get update -qq
apt-get install -y -qq curl ipset iptables >/dev/null
ok "curl / ipset / iptables установлены"

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
#!/usr/bin/env bash
set -Eeuo pipefail

source /etc/default/antiscan

exec 9>/run/antiscan-update.lock
flock -n 9 || exit 0

mkdir -p "$(dirname "$ANTISCAN_LOG")"
exec >>"$ANTISCAN_LOG" 2>&1
printf '\n[%s] AntiScanner update started\n' "$(date -Is)"

TMP_FILE="/run/antiscan-blacklist.txt.new"
TMP_SET="${ANTISCAN_SET}-TMP"
trap 'rm -f "$TMP_FILE"; ipset destroy "$TMP_SET" 2>/dev/null || true' EXIT

curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 \
  "$ANTISCAN_URL" -o "$TMP_FILE"

# Принимаем только IPv4 CIDR/IPv4 addresses. Пустой/битый список
# не должен заменять действующий blacklist.
VALID_LINES="$(grep -Evc '^([[:space:]]*#|[[:space:]]*$)' "$TMP_FILE" || true)"
(( VALID_LINES > 0 )) || { echo "Blacklist is empty"; exit 1; }

ipset destroy "$TMP_SET" 2>/dev/null || true
ipset create "$TMP_SET" hash:net family inet hashsize 4096 maxelem 65536

COUNT=0
while IFS= read -r NET; do
    NET="${NET%%#*}"
    NET="$(printf '%s' "$NET" | xargs)"
    [[ -z "$NET" ]] && continue

    if [[ "$NET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
        if ipset add "$TMP_SET" "$NET" -exist 2>/dev/null; then
            ((COUNT+=1)) || true
        fi
    fi
done < "$TMP_FILE"

(( COUNT > 0 )) || { echo "No valid IPv4 networks in blacklist"; exit 1; }

# Не уничтожаем live-set, который уже используется iptables.
# ipset swap заменяет содержимое атомарно для потребителя.
if ipset list "$ANTISCAN_SET" >/dev/null 2>&1; then
    ipset swap "$TMP_SET" "$ANTISCAN_SET"
    ipset destroy "$TMP_SET" 2>/dev/null || true
else
    ipset rename "$TMP_SET" "$ANTISCAN_SET"
fi

# Ставим DROP первым правилом INPUT, чтобы listed scanners не обходили
# блокировку через последующие ACCEPT-правила UFW.
if ! iptables -C INPUT -m set --match-set "$ANTISCAN_SET" src -j DROP 2>/dev/null; then
    iptables -I INPUT 1 -m set --match-set "$ANTISCAN_SET" src -j DROP
fi

# Сохраняем iptables/ipset для восстановления при перезапуске системы.
if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save || true
elif command -v iptables-save >/dev/null 2>&1; then
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 || true
fi

printf '[%s] AntiScanner loaded: %s networks\n' "$(date -Is)" "$COUNT"
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

echo
echo "Проверка Fail2ban:"
fail2ban-client status sshd 2>/dev/null | sed -n '1,12p' || true

echo
echo "Готово."
echo "AntiScanner ручное обновление: $ANTISCAN_SCRIPT"
echo "AntiScanner лог:              $ANTISCAN_LOG"
echo "Fail2ban конфиг:              $F2B_CONF"
