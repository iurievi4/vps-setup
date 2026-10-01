#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none

SCRIPT_VERSION="1.0"
FAIL2BAN_JAIL="/etc/fail2ban/jail.d/99-security-installer.local"
ANTISCAN_URL="https://gist.githubusercontent.com/sngvy/07cee7ac810c9d222fbebddff8c1d1b8/raw/974d3d87f190468e134e9b56f1e0a93c7caa0fcd/blacklist.txt"
ANTISCAN_SET="SCANNERS-BLOCK-V4"
ANTISCAN_SCRIPT="/usr/local/sbin/antiscan-update.sh"
ANTISCAN_SERVICE="/etc/systemd/system/antiscan.service"
ANTISCAN_TIMER="/etc/systemd/system/antiscan.timer"
ANTISCAN_LOG="/var/log/antiscan-update.log"
MOTD_MAIN="/etc/update-motd.d/99-custom-sysinfo"
MOTD_SECURITY="/etc/update-motd.d/98-security-status"

GREEN="\033[1;32m"; RED="\033[1;31m"; YELLOW="\033[1;33m"; CYAN="\033[0;36m"; NONE="\033[0m"
log(){ printf "  ${CYAN}▶${NONE} %s\n" "$*"; }
ok(){ printf "  ${GREEN}✓${NONE} %s\n" "$*"; }
warn(){ printf "  ${YELLOW}!${NONE} %s\n" "$*"; }
fail(){ printf "  ${RED}✗${NONE} %s\n" "$*" >&2; }
die(){ fail "$*"; exit 1; }
trap 'printf "\n"; fail "Ошибка на строке ${LINENO}: ${BASH_COMMAND}"; exit 1' ERR

printf "\n======================================================================\n"
printf "  🛡️ SECURITY INSTALLER v%s\n  Fail2ban + AntiScanner\n======================================================================\n" "$SCRIPT_VERSION"

apt_install_packages(){
    apt-get update </dev/null
    apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
        fail2ban ipset iptables curl ca-certificates </dev/null
}

printf "\n${CYAN}[ 1 / 4 ] FAIL2BAN${NONE}\n\n"
if dpkg-query -W -f='${Status}' fail2ban 2>/dev/null | grep -q "install ok installed"; then
    ok "Fail2ban уже установлен — переустановка не требуется."
else
    log "Fail2ban не установлен — устанавливаем."
    apt_install_packages
    ok "Fail2ban установлен."
fi

command -v fail2ban-client >/dev/null 2>&1 || die "fail2ban-client не найден."

SSH_PORT=""
if command -v sshd >/dev/null 2>&1; then
    SSH_PORT="$(sshd -T 2>/dev/null | awk '$1=="port" {print $2; exit}' || true)"
fi
if [[ -z "$SSH_PORT" ]] && [[ -f /etc/ssh/sshd_config ]]; then
    SSH_PORT="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)"
fi
SSH_PORT="${SSH_PORT:-22}"
log "SSH порт: ${SSH_PORT}"

mkdir -p /etc/fail2ban/jail.d
cat > "$FAIL2BAN_JAIL" <<EOF2
# Managed by security-install.sh
# Existing jail.local and other jail.d files are preserved.

[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
bantime = 1h
findtime = 10m
maxretry = 5
EOF2
ok "SSH jail настроен: ${FAIL2BAN_JAIL}"

systemctl enable fail2ban >/dev/null 2>&1 || true
systemctl restart fail2ban
sleep 1
systemctl is-active --quiet fail2ban || { fail2ban-client -t || true; die "Fail2ban не запустился."; }
ok "Fail2ban service: RUNNING"

if fail2ban-client status sshd >/dev/null 2>&1; then
    F2B_BANNED="$(fail2ban-client status sshd 2>/dev/null | awk -F: '/Currently banned:/ {gsub(/^[[:space:]]+/,"",$2); print $2; exit}')"
    ok "SSH jail: OK | banned: ${F2B_BANNED:-0}"
else
    fail2ban-client status || true
    die "SSH jail не активен."
fi

printf "\n${CYAN}[ 2 / 4 ] ANTISCANNER${NONE}\n\n"
for package in ipset iptables curl ca-certificates; do
    if ! command -v "$package" >/dev/null 2>&1; then
        log "Устанавливаем отсутствующий пакет: $package"
        apt-get update </dev/null
        apt-get install -y "$package" </dev/null
    fi
done

cat > "$ANTISCAN_SCRIPT" <<'EOF2'
#!/usr/bin/env bash
set -Eeuo pipefail
ANTISCAN_URL="https://gist.githubusercontent.com/sngvy/07cee7ac810c9d222fbebddff8c1d1b8/raw/974d3d87f190468e134e9b56f1e0a93c7caa0fcd/blacklist.txt"
ANTISCAN_SET="SCANNERS-BLOCK-V4"
ANTISCAN_LOG="/var/log/antiscan-update.log"
TMP_FILE="$(mktemp)"
TMP_SET="${ANTISCAN_SET}-NEW-$$"
cleanup(){ rm -f "$TMP_FILE"; ipset destroy "$TMP_SET" >/dev/null 2>&1 || true; }
trap cleanup EXIT
touch "$ANTISCAN_LOG"

if ! curl -fsSL --connect-timeout 15 --max-time 60 "$ANTISCAN_URL" -o "$TMP_FILE"; then
    echo "$(date '+%F %T') ERROR: blacklist download failed" >> "$ANTISCAN_LOG"; exit 1
fi

if ! awk '/^[[:space:]]*#/ {next} /^[[:space:]]*$/ {next} /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?[[:space:]]*$/ {valid++; next} {invalid++} END {exit !(valid>0 && invalid==0)}' "$TMP_FILE"; then
    echo "$(date '+%F %T') ERROR: invalid blacklist format" >> "$ANTISCAN_LOG"; exit 1
fi

ipset destroy "$TMP_SET" >/dev/null 2>&1 || true
ipset create "$TMP_SET" hash:net family inet maxelem 65536
while IFS= read -r network; do
    [[ -z "$network" ]] && continue
    [[ "$network" =~ ^[[:space:]]*# ]] && continue
    network="$(printf '%s' "$network" | awk '{$1=$1; print}')"
    [[ -z "$network" ]] && continue
    [[ "$network" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]] && ipset add "$TMP_SET" "$network" -exist
done < "$TMP_FILE"

if ipset list "$ANTISCAN_SET" >/dev/null 2>&1; then
    ipset swap "$TMP_SET" "$ANTISCAN_SET"
    ipset destroy "$TMP_SET" >/dev/null 2>&1 || true
else
    ipset rename "$TMP_SET" "$ANTISCAN_SET"
fi

if ! iptables -C INPUT -m set --match-set "$ANTISCAN_SET" src -j DROP >/dev/null 2>&1; then
    iptables -I INPUT -m set --match-set "$ANTISCAN_SET" src -j DROP
fi

COUNT="$(ipset list "$ANTISCAN_SET" 2>/dev/null | awk '/Number of entries:/ {print $4; exit}')"
echo "$(date '+%F %T') OK: ${COUNT:-0} networks loaded" >> "$ANTISCAN_LOG"
EOF2
chmod 0755 "$ANTISCAN_SCRIPT"

cat > "$ANTISCAN_SERVICE" <<EOF2
[Unit]
Description=AntiScanner IPv4 blacklist update
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=${ANTISCAN_SCRIPT}
StandardOutput=journal
StandardError=journal
EOF2

cat > "$ANTISCAN_TIMER" <<'EOF2'
[Unit]
Description=AntiScanner periodic blacklist update

[Timer]
OnBootSec=2min
OnUnitActiveSec=6h
Persistent=true
Unit=antiscan.service

[Install]
WantedBy=timers.target
EOF2

systemctl daemon-reload
systemctl enable antiscan.timer >/dev/null 2>&1
log "Первоначальное обновление blacklist..."
systemctl start antiscan.service
systemctl restart antiscan.timer
systemctl is-active --quiet antiscan.timer || die "AntiScanner timer не запустился."
ok "AntiScanner timer: RUNNING"

if ipset list "$ANTISCAN_SET" >/dev/null 2>&1; then
    SCANNER_COUNT="$(ipset list "$ANTISCAN_SET" 2>/dev/null | awk '/Number of entries:/ {print $4; exit}')"
    ok "AntiScanner ipset: ${SCANNER_COUNT:-0} networks"
else
    die "AntiScanner ipset не создан."
fi

if iptables -C INPUT -m set --match-set "$ANTISCAN_SET" src -j DROP >/dev/null 2>&1; then
    ok "AntiScanner iptables rule: OK"
else
    die "AntiScanner iptables DROP rule отсутствует."
fi

if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || true
elif [[ -d /etc/iptables ]] && command -v iptables-save >/dev/null 2>&1; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi

printf "\n${CYAN}[ 3 / 4 ] ФИНАЛЬНАЯ ПРОВЕРКА${NONE}\n\n"
F2B_STATUS="FAIL"; SSH_JAIL_STATUS="FAIL"; ANTISCAN_STATUS="FAIL"; IPSET_STATUS="FAIL"; RULE_STATUS="FAIL"
systemctl is-active --quiet fail2ban && F2B_STATUS="OK"
fail2ban-client status sshd >/dev/null 2>&1 && SSH_JAIL_STATUS="OK"
systemctl is-active --quiet antiscan.timer && ANTISCAN_STATUS="OK"
ipset list "$ANTISCAN_SET" >/dev/null 2>&1 && IPSET_STATUS="OK"
iptables -C INPUT -m set --match-set "$ANTISCAN_SET" src -j DROP >/dev/null 2>&1 && RULE_STATUS="OK"
printf "    %-24s : %s\n" "Fail2ban" "$F2B_STATUS"
printf "    %-24s : %s\n" "SSH jail" "$SSH_JAIL_STATUS"
printf "    %-24s : %s\n" "AntiScanner timer" "$ANTISCAN_STATUS"
printf "    %-24s : %s\n" "AntiScanner ipset" "$IPSET_STATUS"
printf "    %-24s : %s\n" "iptables DROP rule" "$RULE_STATUS"
[[ "$F2B_STATUS" == OK && "$SSH_JAIL_STATUS" == OK && "$ANTISCAN_STATUS" == OK && "$IPSET_STATUS" == OK && "$RULE_STATUS" == OK ]] || die "Финальная проверка безопасности не пройдена."

create_security_motd(){
cat > "$MOTD_SECURITY" <<'EOF2'
#!/usr/bin/env bash
GREEN='\033[1;32m'; RED='\033[1;31m'; NONE='\033[0m'
if systemctl is-active --quiet fail2ban 2>/dev/null; then F2B_STATUS="${GREEN}RUNNING${NONE}"; else F2B_STATUS="${RED}STOPPED${NONE}"; fi
if systemctl is-active --quiet fail2ban 2>/dev/null && fail2ban-client status sshd >/dev/null 2>&1; then
    F2B_BANNED="$(fail2ban-client status sshd 2>/dev/null | awk -F: '/Currently banned:/ {gsub(/^[[:space:]]+/,"",$2); print $2; exit}')"
    F2B_JAIL="${GREEN}OK | banned: ${F2B_BANNED:-0}${NONE}"
else F2B_JAIL="${RED}FAIL${NONE}"; fi
if systemctl is-active --quiet antiscan.timer 2>/dev/null && ipset list SCANNERS-BLOCK-V4 >/dev/null 2>&1 && iptables -C INPUT -m set --match-set SCANNERS-BLOCK-V4 src -j DROP >/dev/null 2>&1; then
    SCANNER_COUNT="$(ipset list SCANNERS-BLOCK-V4 2>/dev/null | awk '/Number of entries:/ {print $4; exit}')"
    ANTISCAN_STATUS="${GREEN}RUNNING | networks: ${SCANNER_COUNT:-0}${NONE}"
else ANTISCAN_STATUS="${RED}STOPPED${NONE}"; fi
printf '\n'; echo -e "  \033[0;36m🛡️ SECURITY${NONE}"
printf "    %-22s : %b\n" "Fail2ban" "$F2B_STATUS"
printf "    %-22s : %b\n" "SSH jail" "$F2B_JAIL"
printf "    %-22s : %b\n" "AntiScanner" "$ANTISCAN_STATUS"
EOF2
chmod 0755 "$MOTD_SECURITY"
ok "Создан $MOTD_SECURITY"
}

integrate_main_motd(){
    [[ -f "$MOTD_MAIN" ]] || { warn "$MOTD_MAIN не найден."; return 1; }
    rm -f "$MOTD_SECURITY"
    sed -i '/# === SECURITY-INSTALLER BEGIN ===/,/# === SECURITY-INSTALLER END ===/d' "$MOTD_MAIN"
    grep -q 'STATUS_NGINX=.*check_service nginx' "$MOTD_MAIN" || { warn "Не найден блок STATUS_NGINX."; return 1; }
    local tmp
    tmp="$(mktemp)"
    awk '
    { print
      if ($0 ~ /^STATUS_NGINX=.*check_service nginx/) {
        print ""
        print "# === SECURITY-INSTALLER BEGIN ==="
        print "if systemctl is-active --quiet fail2ban 2>/dev/null; then"
        print "    STATUS_FAIL2BAN=\"${GREEN_B}RUNNING${NONE}\""
        print "else"
        print "    STATUS_FAIL2BAN=\"${RED_B}STOPPED${NONE}\""
        print "fi"
        print "if systemctl is-active --quiet fail2ban 2>/dev/null && fail2ban-client status sshd >/dev/null 2>&1; then"
        print "    F2B_BANNED=\"$(fail2ban-client status sshd 2>/dev/null | awk -F: '\''/Currently banned:/ {gsub(/^[[:space:]]+/,\"\",$2); print $2; exit}'\'')\""
        print "    STATUS_SSH_JAIL=\"${GREEN_B}OK | banned: ${F2B_BANNED:-0}${NONE}\""
        print "else"
        print "    STATUS_SSH_JAIL=\"${RED_B}FAIL${NONE}\""
        print "fi"
        print "if systemctl is-active --quiet antiscan.timer 2>/dev/null && ipset list SCANNERS-BLOCK-V4 >/dev/null 2>&1 && iptables -C INPUT -m set --match-set SCANNERS-BLOCK-V4 src -j DROP >/dev/null 2>&1; then"
        print "    SCANNER_COUNT=\"$(ipset list SCANNERS-BLOCK-V4 2>/dev/null | awk '\''/Number of entries:/ {print $4; exit}'\'')\""
        print "    STATUS_ANTISCAN=\"${GREEN_B}RUNNING | networks: ${SCANNER_COUNT:-0}${NONE}\""
        print "else"
        print "    STATUS_ANTISCAN=\"${RED_B}STOPPED${NONE}\""
        print "fi"
        print "# === SECURITY-INSTALLER END ==="
      }
    }' "$MOTD_MAIN" > "$tmp"
    mv "$tmp" "$MOTD_MAIN"

    tmp="$(mktemp)"
    awk '{ print; if ($0 ~ /"Cloudflare WARP"/) { print "printf \"    %-22s : %b\\n\" \"Fail2ban\" \"$STATUS_FAIL2BAN\""; print "printf \"    %-22s : %b\\n\" \"SSH jail\" \"$STATUS_SSH_JAIL\""; print "printf \"    %-22s : %b\\n\" \"AntiScanner\" \"$STATUS_ANTISCAN\"" } }' "$MOTD_MAIN" > "$tmp"
    mv "$tmp" "$MOTD_MAIN"
    chmod 0755 "$MOTD_MAIN"
    ok "Security добавлен в $MOTD_MAIN → СТАТУС СЛУЖБ."
}

printf "\n${CYAN}[ 4 / 4 ] MOTD${NONE}\n\n"
printf "  Куда добавить статус безопасности?\n\n"
printf "    1) В основной 99-custom-sysinfo → СТАТУС СЛУЖБ\n"
printf "    2) Создать отдельный 98-security-status\n"
printf "    3) Не добавлять в MOTD\n\n"
read -r -p "  Выбор [1]: " MOTD_CHOICE </dev/tty || MOTD_CHOICE=""
MOTD_CHOICE="${MOTD_CHOICE:-1}"

case "$MOTD_CHOICE" in
    1)
        if ! integrate_main_motd; then
            warn "Не удалось интегрировать $MOTD_MAIN."
            printf "  Создать отдельный 98-security-status? [Y/n]: "
            read -r FALLBACK </dev/tty || FALLBACK="n"
            FALLBACK="${FALLBACK:-y}"
            [[ "$FALLBACK" =~ ^[YyДд]$ ]] && create_security_motd || warn "Security MOTD не создан."
        fi
        ;;
    2) create_security_motd ;;
    3) rm -f "$MOTD_SECURITY"; ok "MOTD не изменён." ;;
    *)
        warn "Неверный выбор — используется вариант 1."
        integrate_main_motd || create_security_motd
        ;;
esac

printf "\n======================================================================\n"
printf "  🛡️ ФИНАЛЬНАЯ ПРОВЕРКА SECURITY\n======================================================================\n"
if systemctl is-active --quiet fail2ban; then printf "  Fail2ban              : ${GREEN}OK${NONE}\n"; else printf "  Fail2ban              : ${RED}FAIL${NONE}\n"; fi
if fail2ban-client status sshd >/dev/null 2>&1; then
    BANNED_NOW="$(fail2ban-client status sshd 2>/dev/null | awk -F: '/Currently banned:/ {gsub(/^[[:space:]]+/,"",$2); print $2; exit}')"
    printf "  SSH jail              : ${GREEN}OK | banned: %s${NONE}\n" "${BANNED_NOW:-0}"
else printf "  SSH jail              : ${RED}FAIL${NONE}\n"; fi
if systemctl is-active --quiet antiscan.timer && ipset list "$ANTISCAN_SET" >/dev/null 2>&1 && iptables -C INPUT -m set --match-set "$ANTISCAN_SET" src -j DROP >/dev/null 2>&1; then
    SCANNER_COUNT="$(ipset list "$ANTISCAN_SET" 2>/dev/null | awk '/Number of entries:/ {print $4; exit}')"
    printf "  AntiScanner           : ${GREEN}OK | networks: %s${NONE}\n" "${SCANNER_COUNT:-0}"
else printf "  AntiScanner           : ${RED}FAIL${NONE}\n"; fi
printf "\n  Готово. Скрипт можно запускать повторно.\n======================================================================\n\n"
