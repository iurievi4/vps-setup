#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# VPS SETUP INSTALLER & MANAGER
#
# Режимы работы:
#   ОСНОВНАЯ НАСТРОЙКА VPS:
#     1) Полная автоматическая установка (setup.sh в тихом режиме)
#     2) Ручная / повторная настройка VPS (интерактивный режим setup.sh)
#   БЕЗОПАСНОСТЬ И ДОСТУП:
#     3) Безопасность VPS (vps-security-installer.sh)
#     4) Управление SSH-ключами (ssh-key-manager.sh)
#   СЕРВИСЫ И СЕТЬ:
#     5) Шаблоны сайтов и безопасность Nginx (nginx-templates.sh)
#     6) 3x-ui: установка, шифрование и проверка баз (export-xui-db.sh)
#     7) Установка NaïveProxy + Caddy (naiveproxy-install.sh)
#     8) Управление NaïveProxy (naiveproxy-manager.sh)
#   ОБСЛУЖИВАНИЕ VPS:
#     9) Обслуживание и диагностика (комплекс обновления, аудита и контроля)
#   УПРАВЛЕНИЕ ФУНКЦИЯМИ VPS:
#     10) Управление функциями VPS (WARP, VPS IP Guard, Fail2ban, UFW, Docker, сервисы)
#   МЕДИА И СТРИМИНГ:
#     11) TorrServer Manager (torrserver-manager.sh)
#   ЛЭРС УЧЁТ:
#     12) Система диспетчеризации ЛЭРС УЧЁТ (lers-manager.sh)
#   0) Выход
###############################################################################

REPO_RAW="https://raw.githubusercontent.com/iurievi4/vps-setup/main"
BOOTSTRAP_MARKER="/etc/vps-bootstrap-complete"
XUI_DB_FILE="/etc/x-ui/x-ui.db"

TMP_DIR="$(mktemp -d /tmp/vps-installer.XXXXXX)"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Цветовая палитра для терминала
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_CYAN='\033[0;36m'
C_BCYAN='\033[1;36m'
C_GREEN='\033[0;32m'
C_BGREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_PURPLE='\033[0;35m'
C_GRAY='\033[0;90m'

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo >&2
    echo -e "${C_RED}❌ Скрипт необходимо запускать с правами root (sudo).${C_RESET}" >&2
    echo >&2
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo ">>> Установка curl и ca-certificates..." >&2
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates >/dev/null 2>&1

    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${C_RED}❌ Не удалось установить curl. Проверьте сеть и репозитории apt.${C_RESET}" >&2
        exit 1
    fi
fi

backup_existing_db() {
    if [[ -f "$XUI_DB_FILE" ]]; then
        mkdir -p /root/xui_backups
        local backup_path="/root/xui_backups/x-ui-before-setup-$(date +%Y%m%d-%H%M%S).db"
        cp -a "$XUI_DB_FILE" "$backup_path"
        echo -e "  ${C_CYAN}[i]${C_RESET} Создана страховочная копия базы: ${C_YELLOW}$backup_path${C_RESET}" >&2
        echo -e "  ${C_CYAN}[i]${C_RESET} Существующая база 3x-ui и ваши клиенты будут сохранены." >&2
    fi
}

download_script() {
    local script_name="$1"
    local target="${TMP_DIR}/${script_name}"

    echo -e "${C_GRAY}>>> Загрузка ${script_name}...${C_RESET}" >&2

    curl -4 -fL \
        --retry 3 \
        --connect-timeout 15 \
        --max-time 300 \
        -H "Cache-Control: no-cache" \
        -H "Pragma: no-cache" \
        "${REPO_RAW}/${script_name}" \
        -o "$target"

    if [[ ! -s "$target" ]]; then
        echo -e "${C_RED}❌ Файл ${script_name} пустой или не был загружен.${C_RESET}" >&2
        exit 1
    fi

    if ! head -n 1 "$target" | grep -qE '^#!.*bash'; then
        echo -e "${C_RED}❌ ${script_name}: файл не является корректным Bash-скриптом.${C_RESET}" >&2
        exit 1
    fi

    chmod 700 "$target"
    printf '%s\n' "$target"
}

get_progress_bar() {
    local pct="${1:-0}"
    local total=10
    local filled=$(( pct * total / 100 ))
    local empty=$(( total - filled ))
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="■"; done
    for ((i=0; i<empty; i++)); do bar+="□"; done
    printf "%s" "$bar"
}

# Чтение выбора пользователя с поддержкой цветов и терминала
read_choice() {
    local prompt="$1"
    local var_name="$2"
    local default_val="${3:-0}"
    local val=""

    echo -ne "$prompt"

    if [[ -t 0 ]]; then
        read -r val || val="$default_val"
    elif { exec 3</dev/tty; } 2>/dev/null; then
        read -r val <&3 || val="$default_val"
        exec 3<&-
    else
        read -r val || val="$default_val"
    fi

    if [[ -z "$val" ]]; then
        val="$default_val"
    fi
    printf -v "$var_name" "%s" "$val"
}

pause_prompt() {
    echo
    echo -ne "${C_GRAY}Нажмите Enter для продолжения...${C_RESET}"
    if [[ -t 0 ]]; then
        read -r _ || true
    elif { exec 3</dev/tty; } 2>/dev/null; then
        read -r _ <&3 || true
        exec 3<&-
    else
        read -r _ || true
    fi
    echo
}

show_dashboard() {
    clear 2>/dev/null || true

    # Сбор данных о системе
    local os_name kernel uptime_str hostname_str cpu_load ext_ip
    os_name=$(grep -oP '(?<=^PRETTY_NAME=).+' /etc/os-release 2>/dev/null | tr -d '"' || uname -s)
    kernel=$(uname -r)
    uptime_str=$(uptime -p 2>/dev/null | sed 's/^up //' || uptime | awk '{print $3}')
    hostname_str=$(hostname -s 2>/dev/null || echo "vps")
    cpu_load=$(awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null || echo "N/A")
    ext_ip=$(curl -4 -s --connect-timeout 1 --max-time 1 https://api.ipify.org 2>/dev/null || ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' || echo "N/A")

    # Память
    local mem_total mem_used mem_pct=0 mem_bar
    mem_total=$(free -m 2>/dev/null | awk '/Mem:/ {print $2}' || echo 0)
    mem_used=$(free -m 2>/dev/null | awk '/Mem:/ {print $3}' || echo 0)
    [[ $mem_total -gt 0 ]] && mem_pct=$(( mem_used * 100 / mem_total ))
    mem_bar=$(get_progress_bar "$mem_pct")

    # Диск
    local disk_total disk_used disk_pct_str disk_pct=0 disk_bar
    disk_total=$(df -h / 2>/dev/null | awk 'NR==2 {print $2}')
    disk_used=$(df -h / 2>/dev/null | awk 'NR==2 {print $3}')
    disk_pct_str=$(df -h / 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
    disk_pct=${disk_pct_str:-0}
    disk_bar=$(get_progress_bar "$disk_pct")

    # Статусы служб
    local status_xui_svc status_xui_db
    if [[ -f "$XUI_DB_FILE" ]]; then
        status_xui_db="${C_GREEN}● Обнаружена${C_RESET} ${C_GRAY}(${XUI_DB_FILE})${C_RESET}"
    else
        status_xui_db="${C_GRAY}○ Не найдена${C_RESET}"
    fi

    if systemctl is-active --quiet x-ui 2>/dev/null; then
        status_xui_svc="${C_GREEN}● Активна${C_RESET} ${C_GRAY}(x-ui.service)${C_RESET}"
    elif command -v x-ui >/dev/null 2>&1 || [[ -f "$XUI_DB_FILE" ]]; then
        status_xui_svc="${C_YELLOW}○ Остановлена${C_RESET}"
    else
        status_xui_svc="${C_GRAY}○ Не установлена${C_RESET}"
    fi

    local status_nginx
    if systemctl is-active --quiet nginx 2>/dev/null; then
        status_nginx="${C_GREEN}● Запущен${C_RESET}"
    elif command -v nginx >/dev/null 2>&1; then
        status_nginx="${C_YELLOW}○ Остановлен${C_RESET}"
    else
        status_nginx="${C_GRAY}○ Не установлен${C_RESET}"
    fi

    local status_naive
    if systemctl is-active --quiet caddy 2>/dev/null; then
        status_naive="${C_GREEN}● Активен${C_RESET} ${C_GRAY}(caddy.service)${C_RESET}"
    elif systemctl is-active --quiet naive 2>/dev/null || systemctl is-active --quiet naiveproxy 2>/dev/null; then
        status_naive="${C_GREEN}● Активен${C_RESET}"
    elif command -v caddy >/dev/null 2>&1 || [[ -f "/etc/caddy/Caddyfile" ]]; then
        status_naive="${C_YELLOW}○ Остановлен${C_RESET}"
    else
        status_naive="${C_GRAY}○ Не установлен${C_RESET}"
    fi

    local status_warp
    if command -v warp-cli >/dev/null 2>&1; then
        if ss -lnt 2>/dev/null | grep -qE '127\.0\.0\.1:40000|:40000 '; then
            status_warp="${C_GREEN}● RUNNING${C_RESET} ${C_GRAY}(SOCKS5 :40000)${C_RESET}"
        elif warp-cli status 2>/dev/null | grep -qiE 'Connected|Status.*Connected'; then
            status_warp="${C_GREEN}● Подключен${C_RESET}"
        else
            status_warp="${C_YELLOW}○ Установлен (отключен)${C_RESET}"
        fi
    else
        status_warp="${C_GRAY}○ Не установлен${C_RESET}"
    fi

    local status_docker
    if command -v docker >/dev/null 2>&1; then
        if systemctl is-active --quiet docker 2>/dev/null; then
            local d_cnt d_names
            d_cnt=$(timeout 1 docker ps -q 2>/dev/null | wc -l | tr -d ' ' || echo "0")
            if [[ "$d_cnt" -gt 0 ]]; then
                d_names=$(timeout 1 docker ps --format '{{.Names}}' 2>/dev/null | tr '\n' ', ' | sed 's/, $//' || echo "")
                if [[ ${#d_names} -gt 35 ]]; then
                    d_names="${d_names:0:32}..."
                fi
                status_docker="${C_GREEN}● Активен${C_RESET} ${C_GRAY}(контейнеры: ${C_CYAN}${d_names}${C_GRAY})${C_RESET}"
            else
                status_docker="${C_GREEN}● Активен${C_RESET} ${C_GRAY}(0 контейнеров)${C_RESET}"
            fi
        else
            status_docker="${C_YELLOW}○ Остановлен${C_RESET}"
        fi
    else
        status_docker="${C_GRAY}○ Не установлен${C_RESET}"
    fi

    local status_postgres
    if systemctl is-active --quiet postgresql 2>/dev/null; then
        status_postgres="${C_GREEN}● Запущен${C_RESET} ${C_GRAY}(postgresql.service)${C_RESET}"
    elif command -v psql >/dev/null 2>&1; then
        status_postgres="${C_YELLOW}○ Остановлен${C_RESET}"
    else
        status_postgres="${C_GRAY}○ Не установлен${C_RESET}"
    fi

    local status_mssql
    if systemctl is-active --quiet mssql-server 2>/dev/null; then
        status_mssql="${C_GREEN}● Запущен${C_RESET} ${C_GRAY}(mssql-server.service)${C_RESET}"
    elif [[ -d "/opt/mssql" ]] || \
         systemctl list-unit-files 2>/dev/null | grep -q '^mssql-server\.service'; then
        status_mssql="${C_YELLOW}○ Остановлен${C_RESET} ${C_GRAY}(сервер установлен)${C_RESET}"
    else
        status_mssql="${C_GRAY}○ Не установлен${C_RESET}"
    fi

    local status_torr
    if systemctl is-active --quiet torrserver 2>/dev/null; then
        status_torr="${C_GREEN}● Запущен${C_RESET} ${C_GRAY}(torrserver.service)${C_RESET}"
    elif command -v torrserver >/dev/null 2>&1 || [[ -f "/usr/bin/torrserver" ]]; then
        status_torr="${C_YELLOW}○ Остановлен${C_RESET}"
    else
        status_torr="${C_GRAY}○ Не установлен${C_RESET}"
    fi

    local status_lers
    if systemctl is-active --quiet lers-server 2>/dev/null; then
        status_lers="${C_GREEN}● Сервер активен${C_RESET} ${C_GRAY}(lers-server.service)${C_RESET}"
    elif command -v lers >/dev/null 2>&1 || [[ -d "/var/lib/lers" ]] || [[ -f "/etc/systemd/system/lers-server.service" ]]; then
        status_lers="${C_YELLOW}○ Остановлен${C_RESET}"
    else
        status_lers="${C_GRAY}○ Не установлен${C_RESET}"
    fi

    local status_fail2ban
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        local jails
        jails=$(fail2ban-client status 2>/dev/null | awk -F':' '/Jail list/ {print $2}' | xargs || true)
        if [[ -n "$jails" ]]; then
            status_fail2ban="${C_GREEN}● Активен${C_RESET} ${C_GRAY}(jails: ${jails})${C_RESET}"
        else
            status_fail2ban="${C_GREEN}● Активен${C_RESET}"
        fi
    elif command -v fail2ban-client >/dev/null 2>&1; then
        status_fail2ban="${C_YELLOW}○ Остановлен${C_RESET}"
    else
        status_fail2ban="${C_GRAY}○ Не установлен${C_RESET}"
    fi

    local status_ipguard
    if iptables -C INPUT -j VPS-IP-GUARD >/dev/null 2>&1 || systemctl is-active --quiet vps-ip-guard.service 2>/dev/null; then
        status_ipguard="${C_GREEN}● Активен${C_RESET}"
    elif systemctl is-active --quiet vps-ip-guard-update.timer 2>/dev/null; then
        status_ipguard="${C_YELLOW}○ Таймер активен${C_RESET}"
    elif ipset list VPS-IP-GUARD-V4 >/dev/null 2>&1; then
        status_ipguard="${C_YELLOW}○ Набор ipset загружен${C_RESET}"
    elif [[ -f "/usr/local/sbin/ip-guard" ]]; then
        status_ipguard="${C_YELLOW}○ Установлен (остановлен)${C_RESET}"
    else
        status_ipguard="${C_GRAY}○ Не установлен${C_RESET}"
    fi

    echo
    echo -e "${C_BCYAN}════════════════════════════════════════════════════════════════════════${C_RESET}"
    echo -e "                  ${C_BOLD}${C_GREEN}⚡ VPS SETUP INSTALLER & MANAGER ⚡${C_RESET}"
    echo -e "         ${C_GRAY}Автоматический комплекс настройки, защиты и сервисов${C_RESET}"
    echo -e "${C_BCYAN}════════════════════════════════════════════════════════════════════════${C_RESET}"
    echo
    echo -e "${C_BOLD}${C_YELLOW}📊 СИСТЕМНЫЙ ИНФОРМАТОР:${C_RESET}"
    echo -e "  ${C_GRAY}├─${C_RESET} ОС & Ядро   : ${C_CYAN}${os_name}${C_RESET} (${kernel})"
    echo -e "  ${C_GRAY}├─${C_RESET} Хост & IP   : ${C_BOLD}${hostname_str}${C_RESET} | Внешний IP: ${C_YELLOW}${ext_ip}${C_RESET}"
    echo -e "  ${C_GRAY}├─${C_RESET} Аптайм & LA : ${C_RESET}${uptime_str}${C_RESET} | Load Average: ${C_CYAN}${cpu_load}${C_RESET}"
    echo -e "  ${C_GRAY}├─${C_RESET} Память RAM  : ${C_RESET}${mem_used} MB / ${mem_total} MB [${C_GREEN}${mem_bar}${C_RESET}] ${mem_pct}%"
    echo -e "  ${C_GRAY}└─${C_RESET} Диск (root) : ${C_RESET}${disk_used} / ${disk_total} [${C_PURPLE}${disk_bar}${C_RESET}] ${disk_pct}%"
    echo
    echo -e "${C_BOLD}${C_YELLOW}🛡  СТАТУС КОМПОНЕНТОВ:${C_RESET}"
    if [[ -f "$BOOTSTRAP_MARKER" ]]; then
        echo -e "  ${C_GRAY}├─${C_RESET} Инициализация VPS : ${C_GREEN}● Сервер настроен${C_RESET} ${C_GRAY}(/etc/vps-bootstrap-complete)${C_RESET}"
    else
        echo -e "  ${C_GRAY}├─${C_RESET} Инициализация VPS : ${C_CYAN}○ Первичная установка${C_RESET}"
    fi
    echo -e "  ${C_GRAY}├─${C_RESET} База данных 3x-ui : ${status_xui_db}"
    echo -e "  ${C_GRAY}├─${C_RESET} Служба 3x-ui      : ${status_xui_svc}"
    echo -e "  ${C_GRAY}├─${C_RESET} Веб-сервер Nginx  : ${status_nginx}"
    echo -e "  ${C_GRAY}├─${C_RESET} NaïveProxy + Caddy: ${status_naive}"
    echo -e "  ${C_GRAY}├─${C_RESET} Cloudflare WARP   : ${status_warp}"
    echo -e "  ${C_GRAY}├─${C_RESET} Docker & Контейнеры: ${status_docker}"
    echo -e "  ${C_GRAY}├─${C_RESET} СУБД PostgreSQL   : ${status_postgres}"
    echo -e "  ${C_GRAY}├─${C_RESET} СУБД MS SQL Server: ${status_mssql}"
    echo -e "  ${C_GRAY}├─${C_RESET} Медиа TorrServer  : ${status_torr}"
    echo -e "  ${C_GRAY}├─${C_RESET} ЛЭРС УЧЁТ         : ${status_lers}"
    echo -e "  ${C_GRAY}├─${C_RESET} Защита Fail2ban   : ${status_fail2ban}"
    echo -e "  ${C_GRAY}└─${C_RESET} Защита IP Guard   : ${status_ipguard}"
    echo
    echo -e "${C_BOLD}${C_CYAN}  ОСНОВНАЯ НАСТРОЙКА VPS${C_RESET}"
    echo -e "  ${C_BGREEN}[1]${C_RESET}  🚀 Полная установка VPS ${C_GRAY}(тихий режим setup.sh)${C_RESET}"
    echo -e "  ${C_BGREEN}[2]${C_RESET}  ⚙️  Ручная / повторная настройка VPS ${C_GRAY}(интерактивные вопросы)${C_RESET}"
    echo
    echo -e "${C_BOLD}${C_CYAN}  БЕЗОПАСНОСТЬ И ДОСТУП${C_RESET}"
    echo -e "  ${C_BGREEN}[3]${C_RESET}  🛡️  Безопасность VPS ${C_GRAY}(vps-security-installer.sh: Fail2ban, WARP)${C_RESET}"
    echo -e "  ${C_BGREEN}[4]${C_RESET}  🔑 Управление SSH-ключами ${C_GRAY}(ssh-key-manager.sh: Ed25519, защита)${C_RESET}"
    echo
    echo -e "${C_BOLD}${C_CYAN}  СЕРВИСЫ И СЕТЬ${C_RESET}"
    echo -e "  ${C_BGREEN}[5]${C_RESET}  🌐 Nginx / сайты / Reverse Proxy ${C_GRAY}(nginx-templates.sh)${C_RESET}"
    echo -e "  ${C_BGREEN}[6]${C_RESET}  🎛️  3x-ui ${C_GRAY}(установка, базы, шифрование, проверка)${C_RESET}"
    echo -e "  ${C_BGREEN}[7]${C_RESET}  🚀 Установка NaïveProxy + Caddy ${C_GRAY}(naiveproxy-install.sh)${C_RESET}"
    echo -e "  ${C_BGREEN}[8]${C_RESET}  🎚️  Управление NaïveProxy ${C_GRAY}(naiveproxy-manager.sh)${C_RESET}"
    echo
    echo -e "${C_BOLD}${C_CYAN}  ОБСЛУЖИВАНИЕ VPS${C_RESET}"
    echo -e "  ${C_BGREEN}[9]${C_RESET}  🔧 Обслуживание и диагностика ${C_GRAY}(обновление, очистка, аудит)${C_RESET}"
    echo
    echo -e "${C_BOLD}${C_CYAN}  УПРАВЛЕНИЕ ФУНКЦИЯМИ VPS${C_RESET}"
    echo -e "  ${C_BGREEN}[10]${C_RESET} ⚙️  Управление функциями VPS ${C_GRAY}(WARP, VPS IP Guard, Fail2ban, UFW, Docker, сервисы)${C_RESET}"
    echo
    echo -e "${C_GRAY}  ──────────────────────────────────────────────────────────────────────${C_RESET}"
    echo
    echo -e "${C_BOLD}${C_YELLOW}  МЕДИА И СТРИМИНГ${C_RESET}"
    echo -e "  ${C_BGREEN}[11]${C_RESET} 📺 TorrServer Manager ${C_GRAY}(torrserver-manager.sh)${C_RESET}"
    echo
    echo -e "${C_BOLD}${C_YELLOW}  СИСТЕМА ДИСПЕТЧЕРИЗАЦИИ ЛЭРС УЧЁТ${C_RESET}"
    echo -e "  ${C_BGREEN}[12]${C_RESET} 📊 Управление ЛЭРС УЧЁТ ${C_GRAY}(lers-manager.sh)${C_RESET}"
    echo
    echo -e "  ${C_RED}[0]${C_RESET}  🚪 Выход"
    echo
}

###############################################################################
# МЕНЮ 3X-UI (ПУНКТ 6)
###############################################################################

xui_menu() {
    while true; do
        clear 2>/dev/null || true
        echo
        echo -e "${C_BOLD}${C_CYAN}======================================================================${C_RESET}"
        echo -e "  🎛️  ${C_BOLD}3X-UI: УСТАНОВКА, ШИФРОВАНИЕ И ПРОВЕРКА${C_RESET}"
        echo -e "${C_BOLD}${C_CYAN}======================================================================${C_RESET}"
        echo
        echo -e "  ${C_BGREEN}[1]${C_RESET} Установка чистая 3x-ui с официального репозитория"
        echo -e "  ${C_BGREEN}[2]${C_RESET} Создание зашифрованной базы"
        echo -e "  ${C_BGREEN}[3]${C_RESET} Как проверить, что зашифрованный файл подходит к setup.sh"
        echo
        echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад в главное меню"
        echo
        local xui_choice="0"
        read_choice "${C_BOLD}Выберите вариант [0-3]: ${C_RESET}" xui_choice "0"
        echo

        case "$xui_choice" in
            1)
                echo ">>> Запуск официального скрипта установки 3x-ui (mhsanaei)..."
                echo
                bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
                pause_prompt
                ;;
            2)
                local xui_script
                xui_script="$(download_script "export-xui-db.sh")"
                bash "$xui_script" create
                pause_prompt
                ;;
            3)
                local xui_script
                xui_script="$(download_script "export-xui-db.sh")"
                bash "$xui_script" verify
                pause_prompt
                ;;
            0|q|exit|back|назад)
                return 0
                ;;
            *)
                echo -e "${C_RED}❌ Некорректный выбор: ${xui_choice}${C_RESET}" >&2
                sleep 1
                ;;
        esac
    done
}

# --- Подменю Сеть и Скорость ---
network_speed_menu() {
    while true; do
        clear 2>/dev/null || true
        echo
        echo -e "${C_BCYAN}════════════════════════════════════════════════════════════════════════${C_RESET}"
        echo -e "                   ${C_BOLD}${C_GREEN}🌐 СЕТЬ И СКОРОСТЬ СОЕДИНЕНИЯ${C_RESET}"
        echo -e "        ${C_GRAY}Тестирование пропускной способности, пинга и сетевых служб${C_RESET}"
        echo -e "${C_BCYAN}════════════════════════════════════════════════════════════════════════${C_RESET}"
        echo
        echo -e "  ${C_BGREEN}[1]${C_RESET} ⚡ Быстрая диагностика сети ${C_GRAY}(Ping, DNS, Gateway, Packet Loss)${C_RESET}"
        echo -e "  ${C_BGREEN}[2]${C_RESET} 🚀 Speedtest ${C_GRAY}(Классический Ookla Speedtest)${C_RESET}"
        echo -e "  ${C_BGREEN}[3]${C_RESET} 🇷🇺 Тест скорости РФ / Яндекс ${C_GRAY}(RU CDN, Yandex, Selectel)${C_RESET}"
        echo -e "  ${C_BGREEN}[4]${C_RESET} 📊 2IP.ru ${C_GRAY}(Проверка IP, провайдера, Ping и скорости)${C_RESET}"
        echo -e "  ${C_BGREEN}[5]${C_RESET} 📡 iPerf3 ${C_GRAY}(VPS ↔ VPS измерение пропускной способности)${C_RESET}"
        echo -e "  ${C_BGREEN}[6]${C_RESET} 🌐 Сетевые интерфейсы ${C_GRAY}(IP, маршруты, DNS, MTU)${C_RESET}"
        echo -e "  ${C_BGREEN}[7]${C_RESET} 🔌 Открытые порты ${C_GRAY}(Listening TCP/UDP порты)${C_RESET}"
        echo
        echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
        echo

        local net_choice="0"
        read_choice "${C_BOLD}Выберите действие [0-7]: ${C_RESET}" net_choice "0"
        echo

        case "$net_choice" in
            1)
                echo -e "${C_BOLD}${C_CYAN}=== 1. Проверка шлюза по умолчанию ===${C_RESET}"
                local gw
                gw=$(ip route 2>/dev/null | awk '/default/ {print $3}' | head -n 1)
                if [[ -n "$gw" ]]; then
                    echo "Шлюз: $gw"
                    ping -c 3 -W 2 "$gw" 2>/dev/null || echo "Шлюз не отвечает на ICMP ping"
                else
                    echo "Шлюз по умолчанию не найден."
                fi
                echo
                echo -e "${C_BOLD}${C_CYAN}=== 2. Пинг до DNS Cloudflare (1.1.1.1) ===${C_RESET}"
                ping -c 3 -W 2 1.1.1.1 2>/dev/null || echo "1.1.1.1 недоступен"
                echo
                echo -e "${C_BOLD}${C_CYAN}=== 3. Пинг до DNS Yandex (77.88.8.8) ===${C_RESET}"
                ping -c 3 -W 2 77.88.8.8 2>/dev/null || echo "77.88.8.8 недоступен"
                echo
                echo -e "${C_BOLD}${C_CYAN}=== 4. Проверка разрешения доменных имён (DNS) ===${C_RESET}"
                if getent ahosts yandex.ru >/dev/null 2>&1; then
                    echo -e "${C_GREEN}✓ yandex.ru разрешается успешно:${C_RESET} $(getent ahosts yandex.ru | awk '{print $1}' | head -n 1)"
                else
                    echo -e "${C_RED}❌ Ошибка разрешения yandex.ru${C_RESET}"
                fi
                if getent ahosts google.com >/dev/null 2>&1; then
                    echo -e "${C_GREEN}✓ google.com разрешается успешно:${C_RESET} $(getent ahosts google.com | awk '{print $1}' | head -n 1)"
                else
                    echo -e "${C_RED}❌ Ошибка разрешения google.com${C_RESET}"
                fi
                pause_prompt
                ;;

            2)
                echo -e "${C_BOLD}${C_CYAN}=== Запуск Ookla Speedtest ===${C_RESET}"
                if ! command -v speedtest-cli >/dev/null 2>&1 && ! command -v speedtest >/dev/null 2>&1; then
                    echo ">>> Установка утилиты speedtest-cli..."
                    apt-get update -qq && apt-get install -y -qq speedtest-cli >/dev/null 2>&1 || true
                fi

                if command -v speedtest >/dev/null 2>&1; then
                    speedtest --accept-license --accept-gdpr || speedtest
                elif command -v speedtest-cli >/dev/null 2>&1; then
                    speedtest-cli --secure || speedtest-cli
                else
                    echo -e "${C_YELLOW}speedtest-cli недоступен в репозитории.${C_RESET}"
                    echo "Используйте тест скорости к российским серверам (пункт [3] или [4])."
                fi
                pause_prompt
                ;;

            3)
                echo -e "${C_BOLD}${C_CYAN}=== Тестирование скорости к российским CDN и серверам ===${C_RESET}"
                echo "Замер реальной пропускной способности при скачивании тестовых пакетов..."
                echo

                # 1. Yandex CDN test
                echo -e "${C_BOLD}1. Yandex CDN (mirror.yandex.ru):${C_RESET}"
                local speed_yandex
                speed_yandex=$(curl -4 -s -w "%{speed_download}" -o /dev/null --max-time 10 "https://mirror.yandex.ru/debian/ls-lR.gz" 2>/dev/null || echo 0)
                if [[ -n "$speed_yandex" && "$speed_yandex" != "0" ]]; then
                    local mbps_ya
                    mbps_ya=$(awk -v s="$speed_yandex" 'BEGIN { printf "%.2f", (s * 8) / 1000000 }')
                    local mbs_ya
                    mbs_ya=$(awk -v s="$speed_yandex" 'BEGIN { printf "%.2f", s / 1048576 }')
                    echo -e "   Скорость: ${C_GREEN}${mbps_ya} Мбит/с${C_RESET} (${mbs_ya} МБ/с)"
                else
                    echo -e "   ${C_RED}❌ Не удалось подключиться к mirror.yandex.ru${C_RESET}"
                fi
                echo

                # 2. Selectel CDN test
                echo -e "${C_BOLD}2. Selectel CDN (mirror.selectel.ru):${C_RESET}"
                local speed_sel
                speed_sel=$(curl -4 -s -w "%{speed_download}" -o /dev/null --max-time 10 "https://mirror.selectel.ru/debian/ls-lR.gz" 2>/dev/null || echo 0)
                if [[ -n "$speed_sel" && "$speed_sel" != "0" ]]; then
                    local mbps_sel
                    mbps_sel=$(awk -v s="$speed_sel" 'BEGIN { printf "%.2f", (s * 8) / 1000000 }')
                    local mbs_sel
                    mbs_sel=$(awk -v s="$speed_sel" 'BEGIN { printf "%.2f", s / 1048576 }')
                    echo -e "   Скорость: ${C_GREEN}${mbps_sel} Мбит/с${C_RESET} (${mbs_sel} МБ/с)"
                else
                    echo -e "   ${C_RED}❌ Не удалось подключиться к mirror.selectel.ru${C_RESET}"
                fi
                echo

                # 3. Speedtest-cli to RU server if speedtest-cli is installed
                if command -v speedtest-cli >/dev/null 2>&1; then
                    echo -e "${C_BOLD}3. Поиск российских серверов в базе Speedtest...${C_RESET}"
                    local ru_srv
                    ru_srv=$(speedtest-cli --list 2>/dev/null | grep -iE 'russia|moscow|saint petersburg' | head -n 1 | awk '{print $1}' | tr -d ')' || true)
                    if [[ -n "$ru_srv" ]]; then
                        echo "Тест через сервер #$ru_srv..."
                        speedtest-cli --server "$ru_srv" --secure 2>/dev/null || speedtest-cli --server "$ru_srv" 2>/dev/null || true
                    fi
                fi
                pause_prompt
                ;;

            4)
                echo -e "${C_BOLD}${C_CYAN}=== 2IP: Проверка сетевых параметров и геолокации ===${C_RESET}"
                echo "Определение сетевой информации через 2ip / IP-сервисы..."
                echo
                local pub_ip=""
                pub_ip=$(curl -s --max-time 3 https://2ip.ru 2>/dev/null | grep -oP '\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}' | head -n 1 || curl -s --max-time 3 https://api.ipify.org 2>/dev/null || echo "N/A")
                echo -e "Внешний IPv4 : ${C_GREEN}${pub_ip}${C_RESET}"
                echo
                echo "Пинг до 2ip.ru:"
                ping -c 3 -W 2 2ip.ru 2>/dev/null || echo "2ip.ru не отвечает на ping"
                echo
                echo "Провайдер и ASN (через ipinfo.io):"
                curl -s --max-time 5 "https://ipinfo.io/${pub_ip}/json" 2>/dev/null | grep -E '"ip"|"city"|"region"|"country"|"org"' || echo "Информация недоступна"
                pause_prompt
                ;;

            5)
                echo -e "${C_BOLD}${C_CYAN}=== Тест iPerf3 ===${C_RESET}"
                if ! command -v iperf3 >/dev/null 2>&1; then
                    echo "Установка утилиты iperf3..."
                    apt-get update -qq && apt-get install -y -qq iperf3 >/dev/null 2>&1 || true
                fi

                if ! command -v iperf3 >/dev/null 2>&1; then
                    echo -e "${C_RED}❌ Не удалось установить iperf3.${C_RESET}"
                    pause_prompt
                    continue
                fi

                echo "1) Тест к публичному серверу iPerf3"
                echo "2) Тест к собственному серверу (указать IP:Port)"
                echo "3) Запустить VPS в режиме iPerf3-сервера (ожидать замер)"
                echo "0) Назад"
                echo
                local ipf_mode="0"
                read_choice "${C_BOLD}Выберите режим [0-3]: ${C_RESET}" ipf_mode "0"
                case "$ipf_mode" in
                    1)
                        echo ">>> Тестирование через публичный iPerf3..."
                        iperf3 -c speedtest.serverius.net -p 5002 -t 5 -P 2 2>/dev/null || \
                        iperf3 -c ping.online.net -p 5201 -t 5 2>/dev/null || \
                        echo "Публичные серверы iperf3 сейчас заняты или недоступны. Рекомендуется использовать собственный узел."
                        ;;
                    2)
                        local target_ip="" target_port="5201"
                        read_choice "${C_BOLD}Введите IP целевого iPerf3-сервера: ${C_RESET}" target_ip ""
                        read_choice "${C_BOLD}Введите порт (по умолчанию 5201): ${C_RESET}" target_port "5201"
                        if [[ -n "$target_ip" ]]; then
                            echo ">>> Запуск: iperf3 -c $target_ip -p $target_port -t 10..."
                            iperf3 -c "$target_ip" -p "$target_port" -t 10
                        fi
                        ;;
                    3)
                        echo ">>> Запуск iPerf3 в режиме сервера (порт 5201, 1 замер)..."
                        echo "    Нажмите Ctrl+C для прерывания."
                        iperf3 -s -1
                        ;;
                esac
                pause_prompt
                ;;

            6)
                echo -e "${C_BOLD}${C_CYAN}=== Сетевые интерфейсы и MTU ===${C_RESET}"
                ip -d link 2>/dev/null || ip link
                echo
                echo -e "${C_BOLD}${C_CYAN}=== IP адреса ===${C_RESET}"
                ip -br addr 2>/dev/null || ip a
                echo
                echo -e "${C_BOLD}${C_CYAN}=== Таблица маршрутизации ===${C_RESET}"
                ip route
                echo
                echo -e "${C_BOLD}${C_CYAN}=== DNS резолверы (/etc/resolv.conf) ===${C_RESET}"
                cat /etc/resolv.conf 2>/dev/null || true
                pause_prompt
                ;;

            7)
                echo -e "${C_BOLD}${C_CYAN}=== Открытые порты (LISTEN TCP/UDP) ===${C_RESET}"
                ss -tulpn 2>/dev/null | grep -E 'Netid|LISTEN' || netstat -tulpn 2>/dev/null || echo "Команда ss недоступна"
                pause_prompt
                ;;

            0|q|exit|back|назад)
                return 0
                ;;
            *)
                echo -e "${C_RED}❌ Некорректный выбор: ${net_choice}${C_RESET}" >&2
                sleep 1
                ;;
        esac
    done
}

###############################################################################
# МЕНЮ ОБСЛУЖИВАНИЯ И ДИАГНОСТИКИ (ПУНКТ 7)
###############################################################################

maintenance_menu() {
    while true; do
        clear 2>/dev/null || true
        echo
        echo -e "${C_BCYAN}════════════════════════════════════════════════════════════════════════${C_RESET}"
        echo -e "               ${C_BOLD}${C_GREEN}🔧 ОБСЛУЖИВАНИЕ И ДИАГНОСТИКА VPS${C_RESET}"
        echo -e "       ${C_GRAY}Комплексное обновление, очистка, аудит и контроль системы${C_RESET}"
        echo -e "${C_BCYAN}════════════════════════════════════════════════════════════════════════${C_RESET}"
        echo
        echo -e "${C_BOLD}${C_CYAN}  СИСТЕМА${C_RESET}"
        echo -e "  ${C_BGREEN}[1]${C_RESET}  🔄 Обновление системы ${C_GRAY}(apt update + upgrade)${C_RESET}"
        echo -e "  ${C_BGREEN}[2]${C_RESET}  🧹 Очистка системы ${C_GRAY}(autoremove + autoclean + clean + journal)${C_RESET}"
        echo -e "  ${C_BGREEN}[3]${C_RESET}  📦 Исправление пакетов и зависимостей ${C_GRAY}(dpkg audit, broken install)${C_RESET}"
        echo -e "  ${C_BGREEN}[4]${C_RESET}  🔧 Полное обслуживание VPS ${C_GRAY}(update + cleanup + audit)${C_RESET}"
        echo
        echo -e "${C_BOLD}${C_CYAN}  ДИАГНОСТИКА${C_RESET}"
        echo -e "  ${C_BGREEN}[5]${C_RESET}  📊 Состояние VPS ${C_GRAY}(CPU, RAM, Диск, Swap, Uptime, LA)${C_RESET}"
        echo -e "  ${C_BGREEN}[6]${C_RESET}  🔍 Полная диагностика ${C_GRAY}(комплексный отчет ресурсов и процессов)${C_RESET}"
        echo -e "  ${C_BGREEN}[7]${C_RESET}  📋 Аудит системы ${C_GRAY}(безопасность, пакеты, открытые порты)${C_RESET}"
        echo -e "  ${C_BGREEN}[8]${C_RESET}  🌐 Проверка сети и скорости ${C_GRAY}(Speedtest, Яндекс, 2IP, iPerf3)${C_RESET}"
        echo
        echo -e "${C_BOLD}${C_CYAN}  ЛОГИ${C_RESET}"
        echo -e "  ${C_BGREEN}[9]${C_RESET}  📜 Журнал системы ${C_GRAY}(journalctl -n 100)${C_RESET}"
        echo -e "  ${C_BGREEN}[10]${C_RESET} 🔐 Журнал SSH / Fail2ban ${C_GRAY}(last, auth.log, fail2ban.log)${C_RESET}"
        echo -e "  ${C_BGREEN}[11]${C_RESET} ⚠️  Ошибки systemd ${C_GRAY}(failed units, journalctl -p 3)${C_RESET}"
        echo
        echo -e "${C_BOLD}${C_CYAN}  СИСТЕМНЫЕ ОПЕРАЦИИ${C_RESET}"
        echo -e "  ${C_BGREEN}[12]${C_RESET} 🔄 Перезапуск проблемных сервисов ${C_GRAY}(systemctl reset-failed)${C_RESET}"
        echo -e "  ${C_BGREEN}[13]${C_RESET} 🕐 Cron / Systemd Timers ${C_GRAY}(планировщики задач)${C_RESET}"
        echo -e "  ${C_BGREEN}[14]${C_RESET} ⚠️  Сбросить маркер настройки ${C_GRAY}(/etc/vps-bootstrap-complete)${C_RESET}"
        echo -e "  ${C_BGREEN}[15]${C_RESET} ♻️  Перезагрузка VPS ${C_GRAY}(reboot)${C_RESET}"
        echo -e "  ${C_BGREEN}[16]${C_RESET} ⏻  Выключение VPS ${C_GRAY}(poweroff)${C_RESET}"
        echo
        echo -e "  ${C_RED}[0]${C_RESET}  ◀️  Назад в главное меню"
        echo

        local m_choice="0"
        read_choice "${C_BOLD}Выберите действие [0-16]: ${C_RESET}" m_choice "0"
        echo

        case "$m_choice" in
            1)
                echo -e "${C_BOLD}${C_GREEN}>>> [1/2] Обновление списков пакетов (apt update)...${C_RESET}"
                apt-get update
                echo
                echo -e "${C_BOLD}${C_GREEN}>>> [2/2] Установка обновлений (apt upgrade)...${C_RESET}"
                DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
                echo
                echo -e "${C_GREEN}✓ Обновление пакетов завершено.${C_RESET}"
                pause_prompt
                ;;

            2)
                echo ">>> [1/4] Удаление неиспользуемых пакетов (autoremove)..."
                apt-get autoremove -y
                echo ">>> [2/4] Очистка архивов APT (autoclean)..."
                apt-get autoclean
                echo ">>> [3/4] Очистка кэша APT (clean)..."
                apt-get clean
                echo ">>> [4/4] Очистка старых логов journald (>3 дней)..."
                journalctl --vacuum-time=3d 2>/dev/null || true
                echo -e "${C_GREEN}✓ Очистка системы завершена.${C_RESET}"
                pause_prompt
                ;;

            3)
                echo ">>> [1/3] Исправление прерванных установок dpkg..."
                dpkg --configure -a
                echo ">>> [2/3] Исправление сломанных зависимостей APT..."
                apt-get --fix-broken install -y
                echo ">>> [3/3] Проверка целостности базы пакетов..."
                apt-get check
                echo -e "${C_GREEN}✓ Зависимости и пакеты проверены и исправлены.${C_RESET}"
                pause_prompt
                ;;

            4)
                echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
                echo -e "  🚀 ${C_BOLD}ПОЛНОЕ ОБСЛУЖИВАНИЕ VPS${C_RESET}"
                echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
                echo
                echo ">>> [1/5] apt update..."
                apt-get update
                echo
                echo ">>> [2/5] apt upgrade..."
                DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
                echo
                echo ">>> [3/5] autoremove + clean..."
                apt-get autoremove -y && apt-get autoclean && apt-get clean
                echo
                echo ">>> [4/5] journalctl vacuum..."
                journalctl --vacuum-time=3d 2>/dev/null || true
                echo
                echo ">>> [5/5] Аудит упавших служб..."
                local failed_u
                failed_u=$(systemctl --failed --no-legend 2>/dev/null || true)
                if [[ -n "$failed_u" ]]; then
                    echo -e "${C_RED}⚠️ Обнаружены службы с ошибками:${C_RESET}"
                    echo "$failed_u"
                else
                    echo -e "${C_GREEN}✓ Все службы работают штатно (0 failed units).${C_RESET}"
                fi
                echo
                echo -e "${C_GREEN}✓ Полное обслуживание успешно завершено.${C_RESET}"
                pause_prompt
                ;;

            5)
                echo -e "${C_BOLD}${C_CYAN}=== 1. Время работы и средняя загрузка ===${C_RESET}"
                uptime
                echo
                echo -e "${C_BOLD}${C_CYAN}=== 2. Процессор (CPU) ===${C_RESET}"
                echo "Логических ядер: $(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)"
                echo "Load average   : $(awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null || echo 'N/A')"
                echo
                echo -e "${C_BOLD}${C_CYAN}=== 3. Оперативная память и Swap ===${C_RESET}"
                free -h 2>/dev/null || free -m
                echo
                echo -e "${C_BOLD}${C_CYAN}=== 4. Дисковые накопители ===${C_RESET}"
                df -h -x tmpfs -x devtmpfs -x squashfs 2>/dev/null || df -h
                pause_prompt
                ;;

            6)
                echo -e "${C_BOLD}${C_CYAN}======================================================================${C_RESET}"
                echo -e "  🔍 ${C_BOLD}ПОЛНАЯ ДИАГНОСТИКА СИСТЕМЫ${C_RESET}"
                echo -e "${C_BOLD}${C_CYAN}======================================================================${C_RESET}"
                echo
                echo -e "${C_BOLD}1. Ресурсы:${C_RESET}"
                uptime
                free -h 2>/dev/null || free -m
                echo
                echo -e "${C_BOLD}2. Диски и inode:${C_RESET}"
                df -h -x tmpfs -x devtmpfs 2>/dev/null || df -h
                echo
                df -i / 2>/dev/null || true
                echo
                echo -e "${C_BOLD}3. Топ-5 процессов по памяти:${C_RESET}"
                ps aux --sort=-%mem 2>/dev/null | head -n 6 || true
                echo
                echo -e "${C_BOLD}4. Топ-5 процессов по CPU:${C_RESET}"
                ps aux --sort=-%cpu 2>/dev/null | head -n 6 || true
                echo
                echo -e "${C_BOLD}5. Состояние служб (failed):${C_RESET}"
                systemctl --failed --no-legend 2>/dev/null || echo "Ошибок служб нет"
                pause_prompt
                ;;

            7)
                echo -e "${C_BOLD}${C_CYAN}======================================================================${C_RESET}"
                echo -e "  📋 ${C_BOLD}АУДИТ СИСТЕМЫ И БЕЗОПАСНОСТИ${C_RESET}"
                echo -e "${C_BOLD}${C_CYAN}======================================================================${C_RESET}"
                echo
                echo -e "${C_BOLD}1. Статус файрвола UFW:${C_RESET}"
                if command -v ufw >/dev/null 2>&1; then
                    ufw status verbose
                else
                    echo "UFW не установлен."
                fi
                echo
                echo -e "${C_BOLD}2. Статус Fail2ban:${C_RESET}"
                if command -v fail2ban-client >/dev/null 2>&1; then
                    fail2ban-client status 2>/dev/null || echo "Fail2ban не запущен"
                else
                    echo "Fail2ban не установлен."
                fi
                echo
                echo -e "${C_BOLD}3. Открытые порты (LISTEN):${C_RESET}"
                ss -tulpn 2>/dev/null | grep -E 'Netid|LISTEN' || netstat -tulpn 2>/dev/null || echo "ss недоступен"
                echo
                echo -e "${C_BOLD}4. Последние успешные входы по SSH:${C_RESET}"
                last -n 5 2>/dev/null || true
                pause_prompt
                ;;

            8)
                network_speed_menu
                ;;

            9)
                echo -e "${C_BOLD}${C_CYAN}=== Последние 100 записей системного журнала ===${C_RESET}"
                journalctl -n 100 --no-pager 2>/dev/null || echo "journalctl недоступен"
                pause_prompt
                ;;

            10)
                echo -e "${C_BOLD}${C_CYAN}=== Журнал SSH и авторизации ===${C_RESET}"
                if [[ -f "/var/log/auth.log" ]]; then
                    tail -n 50 /var/log/auth.log
                else
                    journalctl -u ssh -u sshd -n 50 --no-pager 2>/dev/null || echo "Логи SSH не найдены"
                fi
                echo
                echo -e "${C_BOLD}${C_CYAN}=== Журнал Fail2ban ===${C_RESET}"
                if [[ -f "/var/log/fail2ban.log" ]]; then
                    tail -n 30 /var/log/fail2ban.log
                else
                    echo "Лог /var/log/fail2ban.log не найден"
                fi
                pause_prompt
                ;;

            11)
                echo -e "${C_BOLD}${C_CYAN}=== Службы с ошибками (failed units) ===${C_RESET}"
                local f_units
                f_units=$(systemctl --failed --no-legend 2>/dev/null || true)
                if [[ -z "$f_units" ]]; then
                    echo -e "${C_GREEN}✓ Служб в состоянии ошибки нет.${C_RESET}"
                else
                    systemctl --failed
                fi
                echo
                echo -e "${C_BOLD}${C_CYAN}=== Системные ошибки (priority err/crit) ===${C_RESET}"
                journalctl -p 3 -xb -n 30 --no-pager 2>/dev/null || true
                pause_prompt
                ;;

            12)
                echo ">>> Сброс счетчиков сбоев служб (systemctl reset-failed)..."
                systemctl reset-failed 2>/dev/null || true
                echo ">>> Повторная проверка статуса служб..."
                local rem_f
                rem_f=$(systemctl --failed --no-legend 2>/dev/null || true)
                if [[ -z "$rem_f" ]]; then
                    echo -e "${C_GREEN}✓ Все службы сброшены, ошибок нет.${C_RESET}"
                else
                    echo -e "${C_YELLOW}Службы, оставшиеся в ошибке:${C_RESET}"
                    echo "$rem_f"
                fi
                pause_prompt
                ;;

            13)
                echo -e "${C_BOLD}${C_CYAN}=== Системные таймеры (systemd timers) ===${C_RESET}"
                systemctl list-timers --no-pager 2>/dev/null || true
                echo
                echo -e "${C_BOLD}${C_CYAN}=== Пользовательские cron-задачи (root) ===${C_RESET}"
                crontab -l 2>/dev/null || echo "Cron-задачи для root не настроены"
                pause_prompt
                ;;

            14)
                echo -e "${C_YELLOW}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
                echo -e "${C_YELLOW}║ ⚠️  ВНИМАНИЕ                                                  ║${C_RESET}"
                echo -e "${C_YELLOW}║ Удаление маркера позволит повторно запустить                  ║${C_RESET}"
                echo -e "${C_YELLOW}║ первоначальную настройку VPS через setup.sh.                  ║${C_RESET}"
                echo -e "${C_YELLOW}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
                local confirm_marker="N"
                read_choice "${C_BOLD}Продолжить сброс маркера? [y/N]: ${C_RESET}" confirm_marker "N"
                if [[ "$confirm_marker" =~ ^[YyДд]$ ]]; then
                    if [[ -f "$BOOTSTRAP_MARKER" ]]; then
                        rm -f "$BOOTSTRAP_MARKER"
                        echo -e "${C_GREEN}✓ Маркер $BOOTSTRAP_MARKER успешно удалён.${C_RESET}"
                    else
                        echo "Маркер и так отсутствует (сервер считается чистым)."
                    fi
                else
                    echo "Отменено."
                fi
                pause_prompt
                ;;

            15)
                local confirm_reboot="N"
                read_choice "${C_BOLD}Вы действительно хотите ПЕРЕЗАГРУЗИТЬ сервер? [y/N]: ${C_RESET}" confirm_reboot "N"
                if [[ "$confirm_reboot" =~ ^[YyДд]$ ]]; then
                    echo ">>> Перезагрузка сервера..."
                    reboot
                else
                    echo "Перезагрузка отменена."
                    pause_prompt
                fi
                ;;

            16)
                local confirm_power="N"
                read_choice "${C_BOLD}Вы действительно хотите ВЫКЛЮЧИТЬ сервер? [y/N]: ${C_RESET}" confirm_power "N"
                if [[ "$confirm_power" =~ ^[YyДд]$ ]]; then
                    echo ">>> Выключение сервера..."
                    poweroff
                else
                    echo "Выключение отменено."
                    pause_prompt
                fi
                ;;

            0|q|exit|back|назад)
                return 0
                ;;

            *)
                echo -e "${C_RED}❌ Некорректный выбор: ${m_choice}${C_RESET}" >&2
                sleep 1
                ;;
        esac
    done
}


# --- Подменю Cloudflare WARP ---
manage_warp() {
    while true; do
        clear 2>/dev/null || true
        echo
        echo -e "${C_BCYAN}════════════════════════════════════════════════════════════════════════${C_RESET}"
        echo -e "                 ${C_BOLD}${C_GREEN}🌐 УПРАВЛЕНИЕ CLOUDFLARE WARP${C_RESET}"
        echo -e "${C_BCYAN}════════════════════════════════════════════════════════════════════════${C_RESET}"
        echo

        local warp_cur
        if ! command -v warp-cli >/dev/null 2>&1; then
            warp_cur="${C_GRAY}○ Не установлен${C_RESET}"
        elif ss -lnt 2>/dev/null | grep -qE '127\.0\.0\.1:40000|:40000 '; then
            warp_cur="${C_GREEN}● RUNNING (SOCKS5 :40000)${C_RESET}"
        elif warp-cli status 2>/dev/null | grep -qiE 'Connected|Status.*Connected'; then
            warp_cur="${C_GREEN}● Подключен${C_RESET}"
        else
            warp_cur="${C_YELLOW}○ Установлен (отключен)${C_RESET}"
        fi

        echo -e "  Текущее состояние: ${warp_cur}"
        echo
        if ! command -v warp-cli >/dev/null 2>&1; then
            echo -e "  ${C_YELLOW}⚠️  WARP не установлен в системе.${C_RESET}"
            echo -e "     Для установки перейдите в Главное меню -> [3] Безопасность VPS."
            echo
            echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
            echo
            local no_warp_act="0"
            read_choice "${C_BOLD}Выберите действие [0]: ${C_RESET}" no_warp_act "0"
            return 0
        fi

        echo -e "  ${C_BGREEN}[1]${C_RESET} ▶️  Подключить WARP ${C_GRAY}(warp-cli connect)${C_RESET}"
        echo -e "  ${C_BGREEN}[2]${C_RESET} ⏹️  Отключить WARP ${C_GRAY}(warp-cli disconnect)${C_RESET}"
        echo -e "  ${C_BGREEN}[3]${C_RESET} 🔄 Перезапустить соединение ${C_GRAY}(reconnect)${C_RESET}"
        echo -e "  ${C_BGREEN}[4]${C_RESET} 🔍 Проверить статус службы ${C_GRAY}(warp-cli status)${C_RESET}"
        echo
        echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
        echo

        local w_act="0"
        read_choice "${C_BOLD}Выберите действие [0-4]: ${C_RESET}" w_act "0"
        echo

        case "$w_act" in
            1)
                echo ">>> Подключение Cloudflare WARP..."
                warp-cli connect 2>/dev/null || true
                sleep 1
                echo -e "${C_GREEN}✓ Запрос на подключение отправлен.${C_RESET}"
                pause_prompt
                ;;
            2)
                echo ">>> Отключение Cloudflare WARP..."
                warp-cli disconnect 2>/dev/null || true
                sleep 1
                echo -e "${C_YELLOW}✓ WARP отключен.${C_RESET}"
                pause_prompt
                ;;
            3)
                echo ">>> Перезапуск соединения WARP..."
                warp-cli disconnect 2>/dev/null || true
                sleep 1
                warp-cli connect 2>/dev/null || true
                sleep 1
                echo -e "${C_GREEN}✓ WARP перезапущен.${C_RESET}"
                pause_prompt
                ;;
            4)
                echo -e "${C_BOLD}${C_CYAN}=== Статус Cloudflare WARP ===${C_RESET}"
                warp-cli status 2>/dev/null || echo "Не удалось получить статус warp-cli"
                echo
                echo -e "${C_BOLD}${C_CYAN}=== Порты SOCKS5 (40000) ===${C_RESET}"
                ss -tulpn 2>/dev/null | grep -E ':40000' || echo "Порт 40000 не слушается"
                pause_prompt
                ;;
            0|q|exit|back|назад)
                return 0
                ;;
            *)
                echo -e "${C_RED}❌ Некорректный выбор: ${w_act}${C_RESET}" >&2
                sleep 1
                ;;
        esac
    done
}

# --- Подменю VPS IP Guard ---
manage_ipguard() {
    while true; do
        clear 2>/dev/null || true
        echo
        echo -e "${C_BCYAN}════════════════════════════════════════════════════════════════════════${C_RESET}"
        echo -e "                  ${C_BOLD}${C_GREEN}🛡️  УПРАВЛЕНИЕ VPS IP GUARD${C_RESET}"
        echo -e "${C_BCYAN}════════════════════════════════════════════════════════════════════════${C_RESET}"
        echo

        local ipg_cur
        if iptables -C INPUT -j VPS-IP-GUARD >/dev/null 2>&1 || systemctl is-active --quiet vps-ip-guard.service 2>/dev/null; then
            ipg_cur="${C_GREEN}● RUNNING (Фильтрация активна)${C_RESET}"
        elif systemctl is-active --quiet vps-ip-guard-update.timer 2>/dev/null; then
            ipg_cur="${C_YELLOW}○ Установлен (таймер активен)${C_RESET}"
        elif ipset list VPS-IP-GUARD-V4 >/dev/null 2>&1; then
            ipg_cur="${C_YELLOW}○ Набор ipset активен${C_RESET}"
        else
            ipg_cur="${C_GRAY}○ Не установлен${C_RESET}"
        fi

        local ipg_last_up="неизвестно"
        if [[ -f "/etc/vps-ip-guard/state/last_update.txt" ]]; then
            ipg_last_up=$(cat "/etc/vps-ip-guard/state/last_update.txt" 2>/dev/null || echo "неизвестно")
        elif [[ -f "/etc/vps-ip-guard/cache/active_v4.list" ]]; then
            ipg_last_up=$(date -r "/etc/vps-ip-guard/cache/active_v4.list" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)
        fi

        local ipg_nets_cnt=0
        if ipset list VPS-IP-GUARD-V4 >/dev/null 2>&1; then
            ipg_nets_cnt=$(ipset list VPS-IP-GUARD-V4 2>/dev/null | grep -c '^[0-9]' || echo 0)
        elif [[ -f "/etc/vps-ip-guard/cache/active_v4.list" ]]; then
            ipg_nets_cnt=$(wc -l < "/etc/vps-ip-guard/cache/active_v4.list" 2>/dev/null || echo 0)
        fi

        echo -e "  Текущее состояние     : ${ipg_cur}"
        echo -e "  Заблокировано сетей   : ${C_YELLOW}${ipg_nets_cnt}${C_RESET}"
        echo -e "  Последнее обновление  : ${C_CYAN}${ipg_last_up}${C_RESET}"
        echo

        local is_ipg_installed=0
        if [[ -x "/usr/local/sbin/ip-guard" ]] || ipset list VPS-IP-GUARD-V4 >/dev/null 2>&1; then
            is_ipg_installed=1
        fi

        if [[ "$is_ipg_installed" -eq 0 ]]; then
            echo -e "  ${C_YELLOW}⚠️  VPS IP Guard не установлен в системе.${C_RESET}"
            echo -e "     Для установки перейдите в Главное меню -> [3] Безопасность VPS."
            echo
            echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
            echo
            local no_ipg="0"
            read_choice "${C_BOLD}Выберите действие [0]: ${C_RESET}" no_ipg "0"
            return 0
        fi

        echo -e "  ${C_BGREEN}[1]${C_RESET} ▶️  Восстановить правила из кэша ${C_GRAY}(ip-guard reload)${C_RESET}"
        echo -e "  ${C_BGREEN}[2]${C_RESET} 🔄 Обновить списки сейчас ${C_GRAY}(ip-guard update)${C_RESET}"
        echo -e "  ${C_BGREEN}[3]${C_RESET} 📊 Подробный статус ${C_GRAY}(ip-guard status)${C_RESET}"
        echo -e "  ${C_BGREEN}[4]${C_RESET} 📋 Показать ручной blacklist ${C_GRAY}(ip-guard list)${C_RESET}"
        echo -e "  ${C_BGREEN}[5]${C_RESET} 🚫 Заблокировать IP/подсеть ${C_GRAY}(ip-guard ban)${C_RESET}"
        echo -e "  ${C_BGREEN}[6]${C_RESET} ✅ Разблокировать IP/подсеть ${C_GRAY}(ip-guard unban)${C_RESET}"
        echo -e "  ${C_BGREEN}[7]${C_RESET} ⏰ Перезапустить таймер автообновления ${C_GRAY}(systemctl restart timer)${C_RESET}"
        echo -e "  ${C_BGREEN}[8]${C_RESET} 🔍 Проверить статус службы и таймера ${C_GRAY}(systemctl status)${C_RESET}"
        echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
        echo

        local ipg_act="0"
        read_choice "${C_BOLD}Выберите действие [0-8]: ${C_RESET}" ipg_act "0"
        echo

        case "$ipg_act" in
            1)
                echo ">>> Восстановление правил IP Guard..."
                /usr/local/sbin/ip-guard reload
                pause_prompt
                ;;
            2)
                echo ">>> Обновление списков IP Guard из сети..."
                /usr/local/sbin/ip-guard update
                pause_prompt
                ;;
            3)
                echo -e "${C_BOLD}${C_CYAN}=== Статус VPS IP Guard ===${C_RESET}"
                /usr/local/sbin/ip-guard status
                pause_prompt
                ;;
            4)
                echo -e "${C_BOLD}${C_CYAN}=== Ручной чёрный список ===${C_RESET}"
                /usr/local/sbin/ip-guard list
                pause_prompt
                ;;
            5)
                echo -ne "Введите IP или подсеть для блокировки: "
                local b_ip=""
                read -r b_ip || true
                if [[ -n "$b_ip" ]]; then
                    /usr/local/sbin/ip-guard ban "$b_ip"
                fi
                pause_prompt
                ;;
            6)
                echo -ne "Введите IP или подсеть для разблокировки: "
                local u_ip=""
                read -r u_ip || true
                if [[ -n "$u_ip" ]]; then
                    /usr/local/sbin/ip-guard unban "$u_ip"
                fi
                pause_prompt
                ;;
            7)
                echo ">>> Перезапуск таймера автообновления..."
                systemctl restart vps-ip-guard-update.timer 2>/dev/null || true
                systemctl status vps-ip-guard-update.timer --no-pager 2>/dev/null || true
                pause_prompt
                ;;
            8)
                echo -e "${C_BOLD}${C_CYAN}=== Статус службы и таймера ===${C_RESET}"
                systemctl status vps-ip-guard.service --no-pager 2>/dev/null || true
                systemctl status vps-ip-guard-update.timer --no-pager 2>/dev/null || true
                pause_prompt
                ;;
            0|q|exit)
                return 0
                ;;
            *)
                echo -e "${C_RED}❌ Некорректный выбор: ${ipg_act}${C_RESET}" >&2
                sleep 1
                ;;
        esac
    done
}

# --- Подменю Fail2ban ---
manage_fail2ban() {
    while true; do
        clear 2>/dev/null || true
        echo
        echo -e "${C_BCYAN}════════════════════════════════════════════════════════════════════════${C_RESET}"
        echo -e "                     ${C_BOLD}${C_GREEN}🔒 УПРАВЛЕНИЕ FAIL2BAN${C_RESET}"
        echo -e "${C_BCYAN}════════════════════════════════════════════════════════════════════════${C_RESET}"
        echo

        local f2b_cur
        if systemctl is-active --quiet fail2ban 2>/dev/null; then
            local active_jails
            active_jails=$(fail2ban-client status 2>/dev/null | awk -F':' '/Jail list/ {print $2}' | xargs || echo "нет")
            f2b_cur="${C_GREEN}● RUNNING (jails: ${active_jails})${C_RESET}"
        elif command -v fail2ban-client >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -q '^fail2ban\.service'; then
            f2b_cur="${C_YELLOW}○ Установлен (остановлен)${C_RESET}"
        else
            f2b_cur="${C_GRAY}○ Не установлен${C_RESET}"
        fi

        echo -e "  Текущее состояние: ${f2b_cur}"
        echo

        if ! command -v fail2ban-client >/dev/null 2>&1 && ! systemctl list-unit-files 2>/dev/null | grep -q '^fail2ban\.service'; then
            echo -e "  ${C_YELLOW}⚠️  Fail2ban не установлен в системе.${C_RESET}"
            echo -e "     Для установки перейдите в Главное меню -> [3] Безопасность VPS."
            echo
            echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
            echo
            local no_f2b="0"
            read_choice "${C_BOLD}Выберите действие [0]: ${C_RESET}" no_f2b "0"
            return 0
        fi

        echo -e "  ${C_BGREEN}[1]${C_RESET} ▶️  Запустить службу ${C_GRAY}(systemctl start fail2ban)${C_RESET}"
        echo -e "  ${C_BGREEN}[2]${C_RESET} ⏹️  Остановить службу ${C_GRAY}(systemctl stop fail2ban)${C_RESET}"
        echo -e "  ${C_BGREEN}[3]${C_RESET} 🔄 Перезапустить службу ${C_GRAY}(systemctl restart fail2ban)${C_RESET}"
        echo -e "  ${C_BGREEN}[4]${C_RESET} 🔍 Общий статус и активные jails ${C_GRAY}(fail2ban-client status)${C_RESET}"
        echo -e "  ${C_BGREEN}[5]${C_RESET} 📋 Список заблокированных IP по всем jails ${C_GRAY}(banned IP list)${C_RESET}"
        echo -e "  ${C_BGREEN}[6]${C_RESET} 🔓 Разблокировать IP-адрес ${C_GRAY}(fail2ban-client unban)${C_RESET}"
        echo -e "  ${C_BGREEN}[7]${C_RESET} 🚫 Заблокировать IP-адрес вручную ${C_GRAY}(fail2ban-client banip)${C_RESET}"
        echo -e "  ${C_BGREEN}[8]${C_RESET} 📜 Журнал событий ${C_GRAY}(/var/log/fail2ban.log)${C_RESET}"
        echo -e "  ${C_BGREEN}[9]${C_RESET} ⚙️  Включить / отключить автозапуск ${C_GRAY}(systemctl enable/disable)${C_RESET}"
        echo
        echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
        echo

        local fb_act="0"
        read_choice "${C_BOLD}Выберите действие [0-9]: ${C_RESET}" fb_act "0"
        echo

        case "$fb_act" in
            1)
                echo ">>> Запуск Fail2ban..."
                systemctl start fail2ban 2>/dev/null || true
                echo -e "${C_GREEN}✓ Служба запущена.${C_RESET}"
                pause_prompt
                ;;
            2)
                echo ">>> Остановка Fail2ban..."
                systemctl stop fail2ban 2>/dev/null || true
                echo -e "${C_YELLOW}✓ Служба остановлена.${C_RESET}"
                pause_prompt
                ;;
            3)
                echo ">>> Перезапуск Fail2ban..."
                systemctl restart fail2ban 2>/dev/null || true
                echo -e "${C_GREEN}✓ Служба перезапущена.${C_RESET}"
                pause_prompt
                ;;
            4)
                echo -e "${C_BOLD}${C_CYAN}=== Общий статус Fail2ban ===${C_RESET}"
                fail2ban-client status 2>/dev/null || echo "Не удалось получить статус fail2ban-client"
                pause_prompt
                ;;
            5)
                echo -e "${C_BOLD}${C_CYAN}=== Список заблокированных IP по jails ===${C_RESET}"
                local j_list
                j_list=$(fail2ban-client status 2>/dev/null | awk -F':' '/Jail list/ {print $2}' | tr ',' ' ')
                if [[ -z "$j_list" ]]; then
                    echo "Активные jails не найдены или служба не запущена."
                else
                    for j in $j_list; do
                        echo -e "${C_BOLD}>>> Jail: ${C_GREEN}${j}${C_RESET}"
                        local j_stat
                        j_stat=$(fail2ban-client status "$j" 2>/dev/null || true)
                        local cur_banned
                        cur_banned=$(echo "$j_stat" | grep -i 'Currently banned' | awk -F':' '{print $2}' | xargs || echo "0")
                        local ip_list
                        ip_list=$(echo "$j_stat" | grep -i 'Banned IP list' | awk -F':' '{print $2}' | xargs || echo "нет")
                        echo -e "    Активно заблокировано IP : ${C_YELLOW}${cur_banned}${C_RESET}"
                        echo -e "    Список IP               : ${C_CYAN}${ip_list}${C_RESET}"
                        echo
                    done
                fi
                pause_prompt
                ;;
            6)
                echo -e "${C_BOLD}${C_CYAN}=== Разблокировка IP-адреса ===${C_RESET}"
                local unban_ip=""
                read_choice "${C_BOLD}Введите IP-адрес для разблокировки: ${C_RESET}" unban_ip ""
                if [[ -z "$unban_ip" ]]; then
                    echo "Разблокировка отменена (IP не указан)."
                else
                    echo ">>> Попытка разблокировки $unban_ip во всех активных jails..."
                    if fail2ban-client unban "$unban_ip" 2>/dev/null; then
                        echo -e "${C_GREEN}✓ IP $unban_ip успешно разблокирован.${C_RESET}"
                    else
                        local unbanned_any=0
                        local j_list
                        j_list=$(fail2ban-client status 2>/dev/null | awk -F':' '/Jail list/ {print $2}' | tr ',' ' ')
                        for j in $j_list; do
                            if fail2ban-client set "$j" unbanip "$unban_ip" 2>/dev/null; then
                                echo -e "${C_GREEN}✓ Разблокирован в jail: $j${C_RESET}"
                                unbanned_any=1
                            fi
                        done
                        if [[ "$unbanned_any" -eq 0 ]]; then
                            echo -e "${C_YELLOW}IP $unban_ip не найден в списках блокировок или уже разблокирован.${C_RESET}"
                        fi
                    fi
                fi
                pause_prompt
                ;;
            7)
                echo -e "${C_BOLD}${C_CYAN}=== Ручная блокировка IP-адреса ===${C_RESET}"
                local ban_ip=""
                read_choice "${C_BOLD}Введите IP-адрес для блокировки: ${C_RESET}" ban_ip ""
                if [[ -z "$ban_ip" ]]; then
                    echo "Блокировка отменена (IP не указан)."
                else
                    local j_list
                    j_list=$(fail2ban-client status 2>/dev/null | awk -F':' '/Jail list/ {print $2}' | tr ',' ' ')
                    local first_jail
                    first_jail=$(echo "$j_list" | awk '{print $1}')
                    if [[ -z "$first_jail" ]]; then
                        first_jail="sshd"
                    fi
                    local target_jail=""
                    read_choice "${C_BOLD}Введите jail (по умолчанию: ${first_jail}): ${C_RESET}" target_jail "$first_jail"
                    echo ">>> Блокировка $ban_ip в jail $target_jail..."
                    if fail2ban-client set "$target_jail" banip "$ban_ip" 2>/dev/null; then
                        echo -e "${C_GREEN}✓ IP $ban_ip заблокирован в $target_jail.${C_RESET}"
                    else
                        echo -e "${C_RED}❌ Не удалось заблокировать IP. Проверьте имя jail и статус службы.${C_RESET}"
                    fi
                fi
                pause_prompt
                ;;
            8)
                echo -e "${C_BOLD}${C_CYAN}=== Последние 50 записей лога Fail2ban ===${C_RESET}"
                if [[ -f "/var/log/fail2ban.log" ]]; then
                    tail -n 50 /var/log/fail2ban.log
                else
                    echo "Файл лога /var/log/fail2ban.log не найден."
                fi
                pause_prompt
                ;;
            9)
                if systemctl is-enabled --quiet fail2ban 2>/dev/null; then
                    echo ">>> Отключение автозапуска Fail2ban..."
                    systemctl disable fail2ban 2>/dev/null || true
                    echo -e "${C_YELLOW}✓ Автозапуск отключен.${C_RESET}"
                else
                    echo ">>> Включение автозапуска Fail2ban..."
                    systemctl enable fail2ban 2>/dev/null || true
                    echo -e "${C_GREEN}✓ Автозапуск включен.${C_RESET}"
                fi
                pause_prompt
                ;;
            0|q|exit|back|назад)
                return 0
                ;;
            *)
                echo -e "${C_RED}❌ Некорректный выбор: ${fb_act}${C_RESET}" >&2
                sleep 1
                ;;
        esac
    done
}

# --- Подменю PostgreSQL ---
manage_postgres() {
    while true; do
        clear 2>/dev/null || true
        echo
        echo -e "${C_BCYAN}════════════════════════════════════════════════════════════════════════${C_RESET}"
        echo -e "                    ${C_BOLD}${C_GREEN}🐘 УПРАВЛЕНИЕ POSTGRESQL${C_RESET}"
        echo -e "${C_BCYAN}════════════════════════════════════════════════════════════════════════${C_RESET}"
        echo

        local pg_cur
        if systemctl is-active --quiet postgresql 2>/dev/null; then
            pg_cur="${C_GREEN}● RUNNING (Служба активна)${C_RESET}"
        elif command -v psql >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -q '^postgresql\.service'; then
            pg_cur="${C_YELLOW}○ Установлен (остановлен)${C_RESET}"
        else
            pg_cur="${C_GRAY}○ Не установлен${C_RESET}"
        fi

        echo -e "  Текущее состояние: ${pg_cur}"
        echo

        if ! systemctl list-unit-files 2>/dev/null | grep -q '^postgresql\.service' && ! command -v psql >/dev/null 2>&1; then
            echo -e "  ${C_YELLOW}⚠️  PostgreSQL не установлен в системе.${C_RESET}"
            echo -e "     Установка выполняется через Главное меню -> [2] Ручная настройка setup.sh."
            echo
            echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
            echo
            local no_pg="0"
            read_choice "${C_BOLD}Выберите действие [0]: ${C_RESET}" no_pg "0"
            return 0
        fi

        echo -e "  ${C_BGREEN}[1]${C_RESET} ▶️  Запустить службу ${C_GRAY}(systemctl start postgresql)${C_RESET}"
        echo -e "  ${C_BGREEN}[2]${C_RESET} ⏹️  Остановить службу ${C_GRAY}(systemctl stop postgresql)${C_RESET}"
        echo -e "  ${C_BGREEN}[3]${C_RESET} 🔄 Перезапустить службу ${C_GRAY}(systemctl restart postgresql)${C_RESET}"
        echo -e "  ${C_BGREEN}[4]${C_RESET} ⚙️  Включить автозапуск ${C_GRAY}(systemctl enable postgresql)${C_RESET}"
        echo -e "  ${C_BGREEN}[5]${C_RESET} ⛔ Отключить автозапуск ${C_GRAY}(systemctl disable postgresql)${C_RESET}"
        echo -e "  ${C_BGREEN}[6]${C_RESET} 🔍 Проверить статус службы ${C_GRAY}(systemctl status postgresql)${C_RESET}"
        echo
        echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
        echo

        local p_act="0"
        read_choice "${C_BOLD}Выберите действие [0-6]: ${C_RESET}" p_act "0"
        echo

        case "$p_act" in
            1)
                echo ">>> Запуск PostgreSQL..."
                systemctl start postgresql 2>/dev/null || true
                echo -e "${C_GREEN}✓ Служба запущена.${C_RESET}"
                pause_prompt
                ;;
            2)
                echo ">>> Остановка PostgreSQL..."
                systemctl stop postgresql 2>/dev/null || true
                echo -e "${C_YELLOW}✓ Служба остановлена.${C_RESET}"
                pause_prompt
                ;;
            3)
                echo ">>> Перезапуск PostgreSQL..."
                systemctl restart postgresql 2>/dev/null || true
                echo -e "${C_GREEN}✓ Служба перезапущена.${C_RESET}"
                pause_prompt
                ;;
            4)
                echo ">>> Включение автозапуска PostgreSQL..."
                systemctl enable postgresql 2>/dev/null || true
                echo -e "${C_GREEN}✓ Автозапуск включен.${C_RESET}"
                pause_prompt
                ;;
            5)
                echo ">>> Отключение автозапуска PostgreSQL..."
                systemctl disable postgresql 2>/dev/null || true
                echo -e "${C_YELLOW}✓ Автозапуск отключен.${C_RESET}"
                pause_prompt
                ;;
            6)
                echo -e "${C_BOLD}${C_CYAN}=== Статус PostgreSQL ===${C_RESET}"
                systemctl status postgresql --no-pager 2>/dev/null || true
                pause_prompt
                ;;
            0|q|exit|back|назад)
                return 0
                ;;
            *)
                echo -e "${C_RED}❌ Некорректный выбор: ${p_act}${C_RESET}" >&2
                sleep 1
                ;;
        esac
    done
}

# --- Подменю MS SQL Server ---
manage_mssql() {
    while true; do
        clear 2>/dev/null || true
        echo
        echo -e "${C_BCYAN}════════════════════════════════════════════════════════════════════════${C_RESET}"
        echo -e "                   ${C_BOLD}${C_GREEN}🗄️  УПРАВЛЕНИЕ MS SQL SERVER${C_RESET}"
        echo -e "${C_BCYAN}════════════════════════════════════════════════════════════════════════${C_RESET}"
        echo

        local ms_cur
        if systemctl is-active --quiet mssql-server 2>/dev/null; then
            ms_cur="${C_GREEN}● RUNNING (Служба активна)${C_RESET}"
        elif [[ -d "/opt/mssql" ]] || systemctl list-unit-files 2>/dev/null | grep -q '^mssql-server\.service'; then
            ms_cur="${C_YELLOW}○ Установлен (остановлен)${C_RESET}"
        else
            ms_cur="${C_GRAY}○ Не установлен${C_RESET}"
        fi

        echo -e "  Текущее состояние: ${ms_cur}"
        echo

        if ! systemctl list-unit-files 2>/dev/null | grep -q '^mssql-server\.service' && [[ ! -d "/opt/mssql" ]]; then
            echo -e "  ${C_YELLOW}⚠️  MS SQL Server не установлен в системе.${C_RESET}"
            echo -e "     Наличие утилиты sqlcmd является лишь клиентом, а не сервером."
            echo -e "     Установка сервера выполняется через Главное меню -> [2] setup.sh."
            echo
            echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
            echo
            local no_ms="0"
            read_choice "${C_BOLD}Выберите действие [0]: ${C_RESET}" no_ms "0"
            return 0
        fi

        echo -e "  ${C_BGREEN}[1]${C_RESET} ▶️  Запустить службу ${C_GRAY}(systemctl start mssql-server)${C_RESET}"
        echo -e "  ${C_BGREEN}[2]${C_RESET} ⏹️  Остановить службу ${C_GRAY}(systemctl stop mssql-server)${C_RESET}"
        echo -e "  ${C_BGREEN}[3]${C_RESET} 🔄 Перезапустить службу ${C_GRAY}(systemctl restart mssql-server)${C_RESET}"
        echo -e "  ${C_BGREEN}[4]${C_RESET} ⚙️  Включить автозапуск ${C_GRAY}(systemctl enable mssql-server)${C_RESET}"
        echo -e "  ${C_BGREEN}[5]${C_RESET} ⛔ Отключить автозапуск ${C_GRAY}(systemctl disable mssql-server)${C_RESET}"
        echo -e "  ${C_BGREEN}[6]${C_RESET} 🔍 Проверить статус службы ${C_GRAY}(systemctl status mssql-server)${C_RESET}"
        echo
        echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
        echo

        local m_act="0"
        read_choice "${C_BOLD}Выберите действие [0-6]: ${C_RESET}" m_act "0"
        echo

        case "$m_act" in
            1)
                echo ">>> Запуск MS SQL Server..."
                systemctl start mssql-server 2>/dev/null || true
                echo -e "${C_GREEN}✓ Служба запущена.${C_RESET}"
                pause_prompt
                ;;
            2)
                echo ">>> Остановка MS SQL Server..."
                systemctl stop mssql-server 2>/dev/null || true
                echo -e "${C_YELLOW}✓ Служба остановлена.${C_RESET}"
                pause_prompt
                ;;
            3)
                echo ">>> Перезапуск MS SQL Server..."
                systemctl restart mssql-server 2>/dev/null || true
                echo -e "${C_GREEN}✓ Служба перезапущена.${C_RESET}"
                pause_prompt
                ;;
            4)
                echo ">>> Включение автозапуска MS SQL Server..."
                systemctl enable mssql-server 2>/dev/null || true
                echo -e "${C_GREEN}✓ Автозапуск включен.${C_RESET}"
                pause_prompt
                ;;
            5)
                echo ">>> Отключение автозапуска MS SQL Server..."
                systemctl disable mssql-server 2>/dev/null || true
                echo -e "${C_YELLOW}✓ Автозапуск отключен.${C_RESET}"
                pause_prompt
                ;;
            6)
                echo -e "${C_BOLD}${C_CYAN}=== Статус MS SQL Server ===${C_RESET}"
                systemctl status mssql-server --no-pager 2>/dev/null || true
                pause_prompt
                ;;
            0|q|exit|back|назад)
                return 0
                ;;
            *)
                echo -e "${C_RED}❌ Некорректный выбор: ${m_act}${C_RESET}" >&2
                sleep 1
                ;;
        esac
    done
}

# --- Подменю UFW (Файрвол) ---
manage_ufw() {
    while true; do
        clear 2>/dev/null || true
        echo
        echo -e "${C_BCYAN}════════════════════════════════════════════════════════════════════════${C_RESET}"
        echo -e "                     ${C_BOLD}${C_GREEN}🧱 УПРАВЛЕНИЕ ФАЙРВОЛОМ UFW${C_RESET}"
        echo -e "${C_BCYAN}════════════════════════════════════════════════════════════════════════${C_RESET}"
        echo

        local u_cur
        if ! command -v ufw >/dev/null 2>&1; then
            u_cur="${C_GRAY}○ Не установлен${C_RESET}"
        elif ufw status 2>/dev/null | grep -qi 'active'; then
            local r_cnt
            r_cnt=$(ufw status numbered 2>/dev/null | grep -c '^\[' || echo 0)
            u_cur="${C_GREEN}● Активен (правил: ${r_cnt})${C_RESET}"
        else
            u_cur="${C_YELLOW}○ Отключен (inactive)${C_RESET}"
        fi

        echo -e "  Текущее состояние: ${u_cur}"
        echo

        if ! command -v ufw >/dev/null 2>&1; then
            echo -e "  ${C_YELLOW}⚠️  UFW не установлен в системе.${C_RESET}"
            echo -e "     Для установки выполните: apt-get install -y ufw"
            echo
            echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
            echo
            local no_ufw="0"
            read_choice "${C_BOLD}Выберите действие [0]: ${C_RESET}" no_ufw "0"
            return 0
        fi

        echo -e "  ${C_BGREEN}[1]${C_RESET}  🔍 Показать правила с номерами ${C_GRAY}(ufw status numbered)${C_RESET}"
        echo -e "  ${C_BGREEN}[2]${C_RESET}  ➕ Открыть (разрешить) порт ${C_GRAY}(ufw allow <порт>[/tcp|/udp])${C_RESET}"
        echo -e "  ${C_BGREEN}[3]${C_RESET}  ➖ Удалить правило по номеру ${C_GRAY}(ufw delete <номер>)${C_RESET}"
        echo -e "  ${C_BGREEN}[4]${C_RESET}  ❌ Удалить разрешение порта ${C_GRAY}(ufw delete allow <порт>)${C_RESET}"
        echo -e "  ${C_BGREEN}[5]${C_RESET}  🚫 Заблокировать порт ${C_GRAY}(ufw deny <порт>)${C_RESET}"
        echo -e "  ${C_BGREEN}[6]${C_RESET}  ▶️  Включить UFW ${C_GRAY}(ufw enable)${C_RESET}"
        echo -e "  ${C_BGREEN}[7]${C_RESET}  ⏹️  Отключить UFW ${C_GRAY}(ufw disable)${C_RESET}"
        echo -e "  ${C_BGREEN}[8]${C_RESET}  🔄 Перезагрузить правила ${C_GRAY}(ufw reload)${C_RESET}"
        echo -e "  ${C_BGREEN}[9]${C_RESET}  📜 Подробный статус ${C_GRAY}(ufw status verbose)${C_RESET}"
        echo
        echo -e "  ${C_RED}[0]${C_RESET}  ◀️  Назад"
        echo

        local u_act="0"
        read_choice "${C_BOLD}Выберите действие [0-9]: ${C_RESET}" u_act "0"
        echo

        case "$u_act" in
            1)
                echo -e "${C_BOLD}${C_CYAN}=== Правила UFW с номерами ===${C_RESET}"
                ufw status numbered
                pause_prompt
                ;;
            2)
                echo -e "${C_BOLD}${C_CYAN}=== Добавление разрешающего правила (allow) ===${C_RESET}"
                local allow_port=""
                read_choice "${C_BOLD}Введите порт или порт/протокол (например: 8080 или 8080/tcp): ${C_RESET}" allow_port ""
                if [[ -z "$allow_port" ]]; then
                    echo "Отменено."
                else
                    echo ">>> Выполнение: ufw allow $allow_port..."
                    ufw allow "$allow_port"
                    echo -e "${C_GREEN}✓ Правило добавлено.${C_RESET}"
                fi
                pause_prompt
                ;;
            3)
                echo -e "${C_BOLD}${C_CYAN}=== Удаление правила по номеру ===${C_RESET}"
                ufw status numbered
                echo
                local del_num=""
                read_choice "${C_BOLD}Введите номер правила для удаления: ${C_RESET}" del_num ""
                if [[ -z "$del_num" || ! "$del_num" =~ ^[0-9]+$ ]]; then
                    echo "Некорректный номер или отменено."
                else
                    echo ">>> Выполнение: ufw --force delete $del_num..."
                    ufw --force delete "$del_num"
                    echo -e "${C_GREEN}✓ Правило #$del_num удалено.${C_RESET}"
                fi
                pause_prompt
                ;;
            4)
                echo -e "${C_BOLD}${C_CYAN}=== Удаление разрешения порта ===${C_RESET}"
                local del_port=""
                read_choice "${C_BOLD}Введите порт для удаления из allow: ${C_RESET}" del_port ""
                if [[ -z "$del_port" ]]; then
                    echo "Отменено."
                else
                    echo ">>> Выполнение: ufw delete allow $del_port..."
                    ufw delete allow "$del_port"
                    echo -e "${C_GREEN}✓ Разрешение порта $del_port удалено.${C_RESET}"
                fi
                pause_prompt
                ;;
            5)
                echo -e "${C_BOLD}${C_CYAN}=== Блокировка порта (deny) ===${C_RESET}"
                local deny_port=""
                read_choice "${C_BOLD}Введите порт для блокировки: ${C_RESET}" deny_port ""
                if [[ -z "$deny_port" ]]; then
                    echo "Отменено."
                else
                    echo ">>> Выполнение: ufw deny $deny_port..."
                    ufw deny "$deny_port"
                    echo -e "${C_GREEN}✓ Правило блокировки добавлено.${C_RESET}"
                fi
                pause_prompt
                ;;
            6)
                echo ">>> Включение файрвола UFW..."
                ufw --force enable
                echo -e "${C_GREEN}✓ UFW включен.${C_RESET}"
                pause_prompt
                ;;
            7)
                echo ">>> Отключение файрвола UFW..."
                ufw disable
                echo -e "${C_YELLOW}✓ UFW отключен.${C_RESET}"
                pause_prompt
                ;;
            8)
                echo ">>> Перезагрузка правил UFW..."
                ufw reload
                echo -e "${C_GREEN}✓ Правила перезагружены.${C_RESET}"
                pause_prompt
                ;;
            9)
                echo -e "${C_BOLD}${C_CYAN}=== Подробный статус UFW ===${C_RESET}"
                ufw status verbose
                pause_prompt
                ;;
            0|q|exit|back|назад)
                return 0
                ;;
            *)
                echo -e "${C_RED}❌ Некорректный выбор: ${u_act}${C_RESET}" >&2
                sleep 1
                ;;
        esac
    done
}

# --- Подменю Docker ---
manage_docker() {
    while true; do
        clear 2>/dev/null || true
        echo
        echo -e "${C_BCYAN}════════════════════════════════════════════════════════════════════════${C_RESET}"
        echo -e "                ${C_BOLD}${C_GREEN}🐳 УПРАВЛЕНИЕ DOCKER И КОНТЕЙНЕРАМИ${C_RESET}"
        echo -e "${C_BCYAN}════════════════════════════════════════════════════════════════════════${C_RESET}"
        echo

        local doc_cur
        if ! command -v docker >/dev/null 2>&1; then
            doc_cur="${C_GRAY}○ Не установлен${C_RESET}"
        elif systemctl is-active --quiet docker 2>/dev/null; then
            local cnt
            cnt=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ' || echo "0")
            doc_cur="${C_GREEN}● RUNNING (активно контейнеров: ${cnt})${C_RESET}"
        else
            doc_cur="${C_YELLOW}○ Установлен (служба остановлена)${C_RESET}"
        fi

        echo -e "  Текущее состояние: ${doc_cur}"
        echo

        if ! command -v docker >/dev/null 2>&1; then
            echo -e "  ${C_YELLOW}⚠️  Docker не установлен в системе.${C_RESET}"
            echo
            echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
            echo
            local no_doc="0"
            read_choice "${C_BOLD}Выберите действие [0]: ${C_RESET}" no_doc "0"
            return 0
        fi

        echo -e "  ${C_BOLD}${C_CYAN}СЛУЖБА DOCKER${C_RESET}"
        echo -e "  ${C_BGREEN}[1]${C_RESET}  ▶️  Запустить службу Docker ${C_GRAY}(systemctl start docker)${C_RESET}"
        echo -e "  ${C_BGREEN}[2]${C_RESET}  ⏹️  Остановить службу Docker ${C_GRAY}(systemctl stop docker)${C_RESET}"
        echo -e "  ${C_BGREEN}[3]${C_RESET}  🔄 Перезапустить службу Docker ${C_GRAY}(systemctl restart docker)${C_RESET}"
        echo -e "  ${C_BGREEN}[4]${C_RESET}  ⚙️  Включить / отключить автозапуск ${C_GRAY}(enable/disable)${C_RESET}"
        echo
        echo -e "  ${C_BOLD}${C_CYAN}УПРАВЛЕНИЕ КОНТЕЙНЕРАМИ${C_RESET}"
        echo -e "  ${C_BGREEN}[5]${C_RESET}  📋 Список всех контейнеров ${C_GRAY}(docker ps -a)${C_RESET}"
        echo -e "  ${C_BGREEN}[6]${C_RESET}  📊 Статистика ресурсов ${C_GRAY}(docker stats --no-stream)${C_RESET}"
        echo -e "  ${C_BGREEN}[7]${C_RESET}  🗑️  Удалить контейнер ${C_GRAY}(остановка и docker rm)${C_RESET}"
        echo -e "  ${C_BGREEN}[8]${C_RESET}  🧹 Очистить остановленные контейнеры ${C_GRAY}(container prune)${C_RESET}"
        echo
        echo -e "  ${C_BOLD}${C_CYAN}УПРАВЛЕНИЕ ОБРАЗАМИ${C_RESET}"
        echo -e "  ${C_BGREEN}[9]${C_RESET}  🖼️  Список образов ${C_GRAY}(docker images)${C_RESET}"
        echo -e "  ${C_BGREEN}[10]${C_RESET} ❌ Удалить выбранный образ ${C_GRAY}(docker rmi)${C_RESET}"
        echo -e "  ${C_BGREEN}[11]${C_RESET} 🧽 Полная очистка неиспользуемых образов ${C_GRAY}(image prune -a)${C_RESET}"
        echo
        echo -e "  ${C_RED}[0]${C_RESET}  ◀️  Назад"
        echo

        local d_act="0"
        read_choice "${C_BOLD}Выберите действие [0-11]: ${C_RESET}" d_act "0"
        echo

        case "$d_act" in
            1)
                echo ">>> Запуск Docker..."
                systemctl start docker 2>/dev/null || true
                echo -e "${C_GREEN}✓ Служба Docker запущена.${C_RESET}"
                pause_prompt
                ;;
            2)
                echo ">>> Остановка Docker..."
                systemctl stop docker 2>/dev/null || true
                echo -e "${C_YELLOW}✓ Служба Docker остановлена.${C_RESET}"
                pause_prompt
                ;;
            3)
                echo ">>> Перезапуск Docker..."
                systemctl restart docker 2>/dev/null || true
                echo -e "${C_GREEN}✓ Служба Docker перезапущена.${C_RESET}"
                pause_prompt
                ;;
            4)
                if systemctl is-enabled --quiet docker 2>/dev/null; then
                    echo ">>> Отключение автозапуска Docker..."
                    systemctl disable docker 2>/dev/null || true
                    echo -e "${C_YELLOW}✓ Автозапуск отключен.${C_RESET}"
                else
                    echo ">>> Включение автозапуска Docker..."
                    systemctl enable docker 2>/dev/null || true
                    echo -e "${C_GREEN}✓ Автозапуск включен.${C_RESET}"
                fi
                pause_prompt
                ;;
            5)
                echo -e "${C_BOLD}${C_CYAN}=== Список контейнеров Docker (docker ps -a) ===${C_RESET}"
                docker ps -a
                pause_prompt
                ;;
            6)
                echo -e "${C_BOLD}${C_CYAN}=== Статистика ресурсов контейнеров ===${C_RESET}"
                docker stats --no-stream 2>/dev/null || echo "Нет работающих контейнеров"
                pause_prompt
                ;;
            7)
                echo -e "${C_BOLD}${C_CYAN}=== Удаление контейнера Docker ===${C_RESET}"
                docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Image}}"
                echo
                local c_target=""
                read_choice "${C_BOLD}Введите имя или ID контейнера для удаления: ${C_RESET}" c_target ""
                if [[ -z "$c_target" ]]; then
                    echo "Удаление отменено."
                else
                    echo ">>> Остановка и принудительное удаление контейнера $c_target..."
                    docker rm -f "$c_target" 2>/dev/null || echo -e "${C_RED}❌ Ошибка удаления контейнера $c_target.${C_RESET}"
                    echo -e "${C_GREEN}✓ Контейнер $c_target удалён.${C_RESET}"
                fi
                pause_prompt
                ;;
            8)
                echo -e "${C_BOLD}${C_CYAN}=== Очистка всех остановленных контейнеров ===${C_RESET}"
                local conf_c=""
                read_choice "${C_BOLD}Удалить все остановленные контейнеры? [y/N]: ${C_RESET}" conf_c "N"
                if [[ "$conf_c" =~ ^[YyДд]$ ]]; then
                    docker container prune -f
                    echo -e "${C_GREEN}✓ Остановленные контейнеры очищены.${C_RESET}"
                else
                    echo "Отменено."
                fi
                pause_prompt
                ;;
            9)
                echo -e "${C_BOLD}${C_CYAN}=== Список образов Docker (docker images) ===${C_RESET}"
                docker images
                pause_prompt
                ;;
            10)
                echo -e "${C_BOLD}${C_CYAN}=== Удаление образа Docker ===${C_RESET}"
                docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}"
                echo
                local img_target=""
                read_choice "${C_BOLD}Введите Repository:Tag или Image ID для удаления: ${C_RESET}" img_target ""
                if [[ -z "$img_target" ]]; then
                    echo "Удаление отменено."
                else
                    echo ">>> Удаление образа $img_target..."
                    docker rmi -f "$img_target" 2>/dev/null || echo -e "${C_RED}❌ Ошибка удаления образа $img_target.${C_RESET}"
                    echo -e "${C_GREEN}✓ Образ $img_target удалён.${C_RESET}"
                fi
                pause_prompt
                ;;
            11)
                echo -e "${C_BOLD}${C_CYAN}=== Полная очистка неиспользуемых образов ===${C_RESET}"
                echo -e "${C_YELLOW}Внимание: будут удалены все образы, не связанные с запущенными контейнерами.${C_RESET}"
                local conf_img=""
                read_choice "${C_BOLD}Продолжить очистку образов? [y/N]: ${C_RESET}" conf_img "N"
                if [[ "$conf_img" =~ ^[YyДд]$ ]]; then
                    docker image prune -a -f
                    echo -e "${C_GREEN}✓ Неиспользуемые образы очищены.${C_RESET}"
                else
                    echo "Отменено."
                fi
                pause_prompt
                ;;
            0|q|exit|back|назад)
                return 0
                ;;
            *)
                echo -e "${C_RED}❌ Некорректный выбор: ${d_act}${C_RESET}" >&2
                sleep 1
                ;;
        esac
    done
}

# --- Подменю TorrServer ---
manage_torrserver() {
    while true; do
        clear 2>/dev/null || true
        echo
        echo -e "${C_BCYAN}════════════════════════════════════════════════════════════════════════${C_RESET}"
        echo -e "                   ${C_BOLD}${C_GREEN}📺 УПРАВЛЕНИЕ TORRSERVER${C_RESET}"
        echo -e "${C_BCYAN}════════════════════════════════════════════════════════════════════════${C_RESET}"
        echo

        local torr_cur
        if systemctl is-active --quiet torrserver 2>/dev/null; then
            torr_cur="${C_GREEN}● RUNNING (Служба активна)${C_RESET}"
        elif systemctl list-unit-files 2>/dev/null | grep -q '^torrserver\.service' || [[ -f "/usr/bin/torrserver" ]]; then
            torr_cur="${C_YELLOW}○ Установлен (остановлен)${C_RESET}"
        else
            torr_cur="${C_GRAY}○ Не установлен${C_RESET}"
        fi

        echo -e "  Текущее состояние: ${torr_cur}"
        echo

        if ! systemctl list-unit-files 2>/dev/null | grep -q '^torrserver\.service' && [[ ! -f "/usr/bin/torrserver" ]]; then
            echo -e "  ${C_YELLOW}⚠️  TorrServer не установлен в системе.${C_RESET}"
            echo
            echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
            echo
            local no_torr="0"
            read_choice "${C_BOLD}Выберите действие [0]: ${C_RESET}" no_torr "0"
            return 0
        fi

        echo -e "  ${C_BGREEN}[1]${C_RESET} ▶️  Запустить службу ${C_GRAY}(systemctl start torrserver)${C_RESET}"
        echo -e "  ${C_BGREEN}[2]${C_RESET} ⏹️  Остановить службу ${C_GRAY}(systemctl stop torrserver)${C_RESET}"
        echo -e "  ${C_BGREEN}[3]${C_RESET} 🔄 Перезапустить службу ${C_GRAY}(systemctl restart torrserver)${C_RESET}"
        echo -e "  ${C_BGREEN}[4]${C_RESET} ⚙️  Включить автозапуск ${C_GRAY}(systemctl enable torrserver)${C_RESET}"
        echo -e "  ${C_BGREEN}[5]${C_RESET} ⛔ Отключить автозапуск ${C_GRAY}(systemctl disable torrserver)${C_RESET}"
        echo -e "  ${C_BGREEN}[6]${C_RESET} 🔍 Проверить статус службы ${C_GRAY}(systemctl status torrserver)${C_RESET}"
        echo -e "  ${C_BGREEN}[7]${C_RESET} 🎛️  Открыть полный менеджер TorrServer ${C_GRAY}(torrserver-manager.sh)${C_RESET}"
        echo
        echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
        echo

        local t_act="0"
        read_choice "${C_BOLD}Выберите действие [0-7]: ${C_RESET}" t_act "0"
        echo

        case "$t_act" in
            1)
                echo ">>> Запуск TorrServer..."
                systemctl start torrserver 2>/dev/null || true
                echo -e "${C_GREEN}✓ Служба запущена.${C_RESET}"
                pause_prompt
                ;;
            2)
                echo ">>> Остановка TorrServer..."
                systemctl stop torrserver 2>/dev/null || true
                echo -e "${C_YELLOW}✓ Служба остановлена.${C_RESET}"
                pause_prompt
                ;;
            3)
                echo ">>> Перезапуск TorrServer..."
                systemctl restart torrserver 2>/dev/null || true
                echo -e "${C_GREEN}✓ Служба перезапущена.${C_RESET}"
                pause_prompt
                ;;
            4)
                echo ">>> Включение автозапуска TorrServer..."
                systemctl enable torrserver 2>/dev/null || true
                echo -e "${C_GREEN}✓ Автозапуск включен.${C_RESET}"
                pause_prompt
                ;;
            5)
                echo ">>> Отключение автозапуска TorrServer..."
                systemctl disable torrserver 2>/dev/null || true
                echo -e "${C_YELLOW}✓ Автозапуск отключен.${C_RESET}"
                pause_prompt
                ;;
            6)
                echo -e "${C_BOLD}${C_CYAN}=== Статус TorrServer ===${C_RESET}"
                systemctl status torrserver --no-pager 2>/dev/null || true
                pause_prompt
                ;;
            7)
                local torr_mgr_script=""
                if [[ -f "/root/torrserver-manager.sh" ]]; then
                    torr_mgr_script="/root/torrserver-manager.sh"
                elif [[ -f "$(dirname "$0")/torrserver-manager.sh" ]]; then
                    torr_mgr_script="$(dirname "$0")/torrserver-manager.sh"
                elif [[ -f "./torrserver-manager.sh" ]]; then
                    torr_mgr_script="./torrserver-manager.sh"
                else
                    torr_mgr_script="$(download_script "torrserver-manager.sh")"
                    cp -f "$torr_mgr_script" /root/torrserver-manager.sh 2>/dev/null || true
                    chmod +x /root/torrserver-manager.sh 2>/dev/null || true
                fi
                bash "$torr_mgr_script"
                ;;
            0|q|exit|back|назад)
                return 0
                ;;
            *)
                echo -e "${C_RED}❌ Некорректный выбор: ${t_act}${C_RESET}" >&2
                sleep 1
                ;;
        esac
    done
}

# --- Подменю ЛЭРС УЧЁТ ---
manage_lers() {
    while true; do
        clear 2>/dev/null || true
        echo
        echo -e "${C_BCYAN}════════════════════════════════════════════════════════════════════════${C_RESET}"
        echo -e "                  ${C_BOLD}${C_GREEN}🏢 УПРАВЛЕНИЕ ЛЭРС УЧЁТ${C_RESET}"
        echo -e "${C_BCYAN}════════════════════════════════════════════════════════════════════════${C_RESET}"
        echo

        local lers_cur
        if systemctl is-active --quiet lers-server 2>/dev/null; then
            lers_cur="${C_GREEN}● RUNNING (Служба активна)${C_RESET}"
        elif systemctl list-unit-files 2>/dev/null | grep -q '^lers-server\.service' || [[ -d "/var/lib/lers" ]]; then
            lers_cur="${C_YELLOW}○ Установлен (остановлен)${C_RESET}"
        else
            lers_cur="${C_GRAY}○ Не установлен${C_RESET}"
        fi

        echo -e "  Текущее состояние: ${lers_cur}"
        echo

        if ! systemctl list-unit-files 2>/dev/null | grep -q '^lers-server\.service' && [[ ! -d "/var/lib/lers" ]]; then
            echo -e "  ${C_YELLOW}⚠️  ЛЭРС УЧЁТ не установлен в системе.${C_RESET}"
            echo -e "     Для установки перейдите в Главное меню -> [12] Управление ЛЭРС УЧЁТ."
            echo
            echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
            echo
            local no_lers="0"
            read_choice "${C_BOLD}Выберите действие [0]: ${C_RESET}" no_lers "0"
            return 0
        fi

        echo -e "  ${C_BGREEN}[1]${C_RESET} ▶️  Запустить службу ${C_GRAY}(systemctl start lers-server)${C_RESET}"
        echo -e "  ${C_BGREEN}[2]${C_RESET} ⏹️  Остановить службу ${C_GRAY}(systemctl stop lers-server)${C_RESET}"
        echo -e "  ${C_BGREEN}[3]${C_RESET} 🔄 Перезапустить службу ${C_GRAY}(systemctl restart lers-server)${C_RESET}"
        echo -e "  ${C_BGREEN}[4]${C_RESET} ⚙️  Включить автозапуск ${C_GRAY}(systemctl enable lers-server)${C_RESET}"
        echo -e "  ${C_BGREEN}[5]${C_RESET} ⛔ Отключить автозапуск ${C_GRAY}(systemctl disable lers-server)${C_RESET}"
        echo -e "  ${C_BGREEN}[6]${C_RESET} 📊 Открыть полный менеджер ЛЭРС ${C_GRAY}(lers-manager.sh)${C_RESET}"
        echo
        echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
        echo

        local l_act="0"
        read_choice "${C_BOLD}Выберите действие [0-6]: ${C_RESET}" l_act "0"
        echo

        case "$l_act" in
            1)
                echo ">>> Запуск службы ЛЭРС УЧЁТ..."
                systemctl start lers-server 2>/dev/null || true
                echo -e "${C_GREEN}✓ Служба запущена.${C_RESET}"
                pause_prompt
                ;;
            2)
                echo ">>> Остановка службы ЛЭРС УЧЁТ..."
                systemctl stop lers-server 2>/dev/null || true
                echo -e "${C_YELLOW}✓ Служба остановлена.${C_RESET}"
                pause_prompt
                ;;
            3)
                echo ">>> Перезапуск службы ЛЭРС УЧЁТ..."
                systemctl restart lers-server 2>/dev/null || true
                echo -e "${C_GREEN}✓ Служба перезапущена.${C_RESET}"
                pause_prompt
                ;;
            4)
                echo ">>> Включение автозапуска ЛЭРС УЧЁТ..."
                systemctl enable lers-server 2>/dev/null || true
                echo -e "${C_GREEN}✓ Автозапуск включен.${C_RESET}"
                pause_prompt
                ;;
            5)
                echo ">>> Отключение автозапуска ЛЭРС УЧЁТ..."
                systemctl disable lers-server 2>/dev/null || true
                echo -e "${C_YELLOW}✓ Автозапуск отключен.${C_RESET}"
                pause_prompt
                ;;
            6)
                local lers_script
                lers_script="$(download_script "lers-manager.sh")"
                cp -f "$lers_script" /root/lers-manager.sh 2>/dev/null || true
                chmod +x /root/lers-manager.sh 2>/dev/null || true
                bash /root/lers-manager.sh
                pause_prompt
                ;;
            0|q|exit|back|назад)
                return 0
                ;;
            *)
                echo -e "${C_RED}❌ Некорректный выбор: ${l_act}${C_RESET}" >&2
                sleep 1
                ;;
        esac
    done
}

# --- Главное меню функций VPS ---
functions_menu() {
    while true; do
        clear 2>/dev/null || true
        echo
        echo -e "${C_BCYAN}════════════════════════════════════════════════════════════════════════${C_RESET}"
        echo -e "              ${C_BOLD}${C_GREEN}⚙️  УПРАВЛЕНИЕ ФУНКЦИЯМИ VPS${C_RESET}"
        echo -e "       ${C_GRAY}Включение, отключение, запуск и контроль компонентов${C_RESET}"
        echo -e "${C_BCYAN}════════════════════════════════════════════════════════════════════════${C_RESET}"
        echo

        # ------------------------------------------------------------------
        # Сбор состояний
        # ------------------------------------------------------------------
        local warp_state ipguard_state f2b_state ufw_state postgres_state mssql_state docker_state torr_state lers_state

        if ! command -v warp-cli >/dev/null 2>&1; then
            warp_state="${C_GRAY}○ Не установлен${C_RESET}"
        elif ss -lnt 2>/dev/null | grep -qE '127\.0\.0\.1:40000|:40000 '; then
            warp_state="${C_GREEN}● RUNNING :40000${C_RESET}"
        elif warp-cli status 2>/dev/null | grep -qiE 'Connected|Status.*Connected'; then
            warp_state="${C_GREEN}● RUNNING${C_RESET}"
        else
            warp_state="${C_YELLOW}○ Установлен (отключен)${C_RESET}"
        fi

        local ipguard_state
        if iptables -C INPUT -j VPS-IP-GUARD >/dev/null 2>&1 || systemctl is-active --quiet vps-ip-guard.service 2>/dev/null; then
            ipguard_state="${C_GREEN}● RUNNING${C_RESET}"
        elif systemctl is-active --quiet vps-ip-guard-update.timer 2>/dev/null; then
            ipguard_state="${C_YELLOW}○ Таймер активен${C_RESET}"
        elif ipset list VPS-IP-GUARD-V4 >/dev/null 2>&1; then
            ipguard_state="${C_YELLOW}○ Набор ipset активен${C_RESET}"
        else
            ipguard_state="${C_GRAY}○ Не установлен${C_RESET}"
        fi

        if systemctl is-active --quiet fail2ban 2>/dev/null; then
            local f2b_j
            f2b_j=$(fail2ban-client status 2>/dev/null | awk -F':' '/Jail list/ {print $2}' | xargs || true)
            if [[ -n "$f2b_j" ]]; then
                f2b_state="${C_GREEN}● RUNNING${C_RESET} ${C_GRAY}(jails: ${f2b_j})${C_RESET}"
            else
                f2b_state="${C_GREEN}● RUNNING${C_RESET}"
            fi
        elif command -v fail2ban-client >/dev/null 2>&1; then
            f2b_state="${C_YELLOW}○ Остановлен${C_RESET}"
        else
            f2b_state="${C_GRAY}○ Не установлен${C_RESET}"
        fi

        if ! command -v ufw >/dev/null 2>&1; then
            ufw_state="${C_GRAY}○ Не установлен${C_RESET}"
        elif ufw status 2>/dev/null | grep -qi 'active'; then
            local u_rcnt
            u_rcnt=$(ufw status numbered 2>/dev/null | grep -c '^\[' || echo 0)
            ufw_state="${C_GREEN}● RUNNING${C_RESET} ${C_GRAY}(правил: ${u_rcnt})${C_RESET}"
        else
            ufw_state="${C_YELLOW}○ Отключен${C_RESET}"
        fi

        if systemctl is-active --quiet postgresql 2>/dev/null; then
            postgres_state="${C_GREEN}● RUNNING${C_RESET}"
        elif command -v psql >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -q '^postgresql\.service'; then
            postgres_state="${C_YELLOW}○ Остановлен${C_RESET}"
        else
            postgres_state="${C_GRAY}○ Не установлен${C_RESET}"
        fi

        if systemctl is-active --quiet mssql-server 2>/dev/null; then
            mssql_state="${C_GREEN}● RUNNING${C_RESET}"
        elif [[ -d "/opt/mssql" ]] || systemctl list-unit-files 2>/dev/null | grep -q '^mssql-server\.service'; then
            mssql_state="${C_YELLOW}○ Остановлен${C_RESET}"
        else
            mssql_state="${C_GRAY}○ Не установлен${C_RESET}"
        fi

        if systemctl is-active --quiet docker 2>/dev/null; then
            local d_c
            d_c=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ' || echo "0")
            docker_state="${C_GREEN}● RUNNING${C_RESET} ${C_GRAY}(${d_c} конт.)${C_RESET}"
        elif command -v docker >/dev/null 2>&1; then
            docker_state="${C_YELLOW}○ Остановлен${C_RESET}"
        else
            docker_state="${C_GRAY}○ Не установлен${C_RESET}"
        fi

        if systemctl is-active --quiet torrserver 2>/dev/null; then
            torr_state="${C_GREEN}● RUNNING${C_RESET}"
        elif systemctl list-unit-files 2>/dev/null | grep -q '^torrserver\.service' || [[ -f "/usr/bin/torrserver" ]]; then
            torr_state="${C_YELLOW}○ Остановлен${C_RESET}"
        else
            torr_state="${C_GRAY}○ Не установлен${C_RESET}"
        fi

        if systemctl is-active --quiet lers-server 2>/dev/null; then
            lers_state="${C_GREEN}● RUNNING${C_RESET}"
        elif systemctl list-unit-files 2>/dev/null | grep -q '^lers-server\.service' || [[ -d "/var/lib/lers" ]]; then
            lers_state="${C_YELLOW}○ Остановлен${C_RESET}"
        else
            lers_state="${C_GRAY}○ Не установлен${C_RESET}"
        fi

        echo -e "${C_BOLD}${C_CYAN}  ТЕКУЩЕЕ СОСТОЯНИЕ${C_RESET}"
        echo
        echo -e "  ${C_GRAY}├─${C_RESET} Cloudflare WARP   : ${warp_state}"
        echo -e "  ${C_GRAY}├─${C_RESET} VPS IP Guard       : ${ipguard_state}"
        echo -e "  ${C_GRAY}├─${C_RESET} Fail2ban           : ${f2b_state}"
        echo -e "  ${C_GRAY}├─${C_RESET} Файрвол UFW        : ${ufw_state}"
        echo -e "  ${C_GRAY}├─${C_RESET} Docker & Конт.     : ${docker_state}"
        echo -e "  ${C_GRAY}├─${C_RESET} PostgreSQL         : ${postgres_state}"
        echo -e "  ${C_GRAY}├─${C_RESET} MS SQL Server      : ${mssql_state}"
        echo -e "  ${C_GRAY}├─${C_RESET} TorrServer         : ${torr_state}"
        echo -e "  ${C_GRAY}└─${C_RESET} ЛЭРС УЧЁТ          : ${lers_state}"
        echo
        echo -e "${C_BOLD}${C_CYAN}  УПРАВЛЕНИЕ КОМПОНЕНТАМИ${C_RESET}"
        echo
        echo -e "  ${C_BGREEN}[1]${C_RESET}  🌐 Cloudflare WARP ${C_GRAY}(подключение, отключение, socks5)${C_RESET}"
        echo -e "  ${C_BGREEN}[2]${C_RESET}  🛡️  VPS IP Guard ${C_GRAY}(служба, таймер, списки, ручной бан)${C_RESET}"
        echo -e "  ${C_BGREEN}[3]${C_RESET}  🔒 Fail2ban ${C_GRAY}(служба, jails, заблокированные IP, unban)${C_RESET}"
        echo -e "  ${C_BGREEN}[4]${C_RESET}  🧱 Файрвол UFW ${C_GRAY}(открытие/удаление портов, статус, правила)${C_RESET}"
        echo -e "  ${C_BGREEN}[5]${C_RESET}  🐳 Docker ${C_GRAY}(контейнеры, образы, удаление, prune)${C_RESET}"
        echo -e "  ${C_BGREEN}[6]${C_RESET}  🐘 PostgreSQL ${C_GRAY}(запуск, остановка, автозапуск)${C_RESET}"
        echo -e "  ${C_BGREEN}[7]${C_RESET}  🗄️  MS SQL Server ${C_GRAY}(запуск, остановка, автозапуск)${C_RESET}"
        echo -e "  ${C_BGREEN}[8]${C_RESET}  📺 TorrServer ${C_GRAY}(запуск, остановка, автозапуск)${C_RESET}"
        echo -e "  ${C_BGREEN}[9]${C_RESET}  🏢 ЛЭРС УЧЁТ ${C_GRAY}(служба, автозапуск, менеджер)${C_RESET}"
        echo
        echo -e "${C_BOLD}${C_CYAN}  ДОПОЛНИТЕЛЬНО${C_RESET}"
        echo
        echo -e "  ${C_BGREEN}[10]${C_RESET} 🔄 Обновить статус"
        echo -e "  ${C_BGREEN}[11]${C_RESET} 🔧 Запустить vps-security-installer.sh"
        echo
        echo -e "  ${C_RED}[0]${C_RESET}  ◀️  Назад в главное меню"
        echo

        local f_choice="0"
        read_choice "${C_BOLD}Выберите функцию [0-11]: ${C_RESET}" f_choice "0"
        echo

        case "$f_choice" in
            1) manage_warp ;;
            2) manage_ipguard ;;
            3) manage_fail2ban ;;
            4) manage_ufw ;;
            5) manage_docker ;;
            6) manage_postgres ;;
            7) manage_mssql ;;
            8) manage_torrserver ;;
            9) manage_lers ;;
            10) continue ;;
            11)
                local sec_script
                sec_script="$(download_script "vps-security-installer.sh")"
                bash "$sec_script"
                pause_prompt
                ;;
            0|q|exit|back|назад)
                return 0
                ;;
            *)
                echo -e "${C_RED}❌ Некорректный выбор: ${f_choice}${C_RESET}" >&2
                sleep 1
                ;;
        esac
    done
}

run_action() {
    local choice="$1"

    case "$choice" in
        1)
            echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
            echo -e "  🚀 ${C_BOLD}ПОЛНАЯ АВТОМАТИЧЕСКАЯ УСТАНОВКА${C_RESET}"
            echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
            echo

            local setup_script
            setup_script="$(download_script "setup.sh")"

            echo "Параметры автоматической установки:"
            echo "  PostgreSQL        : НЕТ"
            echo "  MS SQL Server     : НЕТ"
            echo "  TorrServer        : НЕТ"
            echo "  Cloudflare WARP   : ДА"
            echo "  3x-ui             : ДА"

            backup_existing_db
            echo

            export DEBIAN_FRONTEND=noninteractive
            export XUI_NONINTERACTIVE=1
            export INSTALL_POSTGRES=0
            export INSTALL_MSSQL=0
            export INSTALL_TORRSERVER=0
            export INSTALL_WARP=1
            export WARP_MANDATORY=1
            export FORCE_BOOTSTRAP=1
            export REG_CHOICE=0

            echo ">>> Запуск setup.sh в автоматическом режиме..."
            echo
            bash "$setup_script"

            echo
            echo -e "${C_GREEN}✓ SETUP.SH ЗАВЕРШЁН${C_RESET}"
            pause_prompt
            ;;

        2)
            echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
            echo -e "  ⚙️  ${C_BOLD}РУЧНАЯ / ПОВТОРНАЯ НАСТРОЙКА SETUP.SH${C_RESET}"
            echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
            echo

            local setup_script
            setup_script="$(download_script "setup.sh")"

            if [[ -f "$BOOTSTRAP_MARKER" ]]; then
                echo -e "ℹ️ Обнаружен существующий маркер: ${C_YELLOW}$BOOTSTRAP_MARKER${C_RESET}"
                echo "ℹ️ Активирован режим повторного запуска (FORCE_BOOTSTRAP=1)."
            fi

            backup_existing_db
            echo

            export FORCE_BOOTSTRAP=1

            echo ">>> Запуск setup.sh в интерактивном режиме..."
            echo
            bash "$setup_script"

            echo
            echo -e "${C_GREEN}✓ SETUP.SH ЗАВЕРШЁН${C_RESET}"
            pause_prompt
            ;;

        3)
            echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
            echo -e "  🛡️  ${C_BOLD}VPS SECURITY INSTALLER${C_RESET}"
            echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
            echo

            local security_script
            security_script="$(download_script "vps-security-installer.sh")"

            echo ">>> Запуск vps-security-installer.sh..."
            echo
            bash "$security_script"

            echo
            echo -e "${C_GREEN}✓ SECURITY INSTALLER ЗАВЕРШЁН${C_RESET}"
            pause_prompt
            ;;

        4|ssh|ssh-manager)
            echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
            echo -e "  🔑 ${C_BOLD}SSH KEY & SECURITY MANAGER${C_RESET}"
            echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
            echo

            local ssh_script
            ssh_script="$(download_script "ssh-key-manager.sh")"

            echo ">>> Запуск ssh-key-manager.sh..."
            echo
            bash "$ssh_script"

            echo
            echo -e "${C_GREEN}✓ SSH KEY MANAGER ЗАВЕРШЁН${C_RESET}"
            pause_prompt
            ;;

        5|nginx|templates)
            echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
            echo -e "  🌐 ${C_BOLD}NGINX TEMPLATE & SECURITY MANAGER${C_RESET}"
            echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
            echo

            local nginx_script
            nginx_script="$(download_script "nginx-templates.sh")"

            echo ">>> Запуск nginx-templates.sh..."
            echo
            bash "$nginx_script"

            echo
            echo -e "${C_GREEN}✓ NGINX TEMPLATE MANAGER ЗАВЕРШЁН${C_RESET}"
            pause_prompt
            ;;

        6|xui|3x-ui)
            xui_menu
            ;;

        7|naive-install)
            echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
            echo -e "  🚀 ${C_BOLD}NAÏVEPROXY + CADDY INSTALLER${C_RESET}"
            echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
            echo

            local naive_script
            naive_script="$(download_script "naiveproxy-install.sh")"

            echo ">>> Запуск naiveproxy-install.sh..."
            echo
            bash "$naive_script"

            echo
            echo -e "${C_GREEN}✓ УСТАНОВКА NAÏVEPROXY ЗАВЕРШЕНА${C_RESET}"
            pause_prompt
            ;;

        8|naive-manager|naive|naiveproxy)
            echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
            echo -e "  🎚️  ${C_BOLD}NAÏVEPROXY MANAGER${C_RESET}"
            echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
            echo

            local naive_mgr_script
            naive_mgr_script="$(download_script "naiveproxy-manager.sh")"

            echo ">>> Запуск naiveproxy-manager.sh..."
            echo
            bash "$naive_mgr_script"

            echo
            echo -e "${C_GREEN}✓ МЕНЕДЖЕР NAÏVEPROXY ЗАВЕРШЁН${C_RESET}"
            pause_prompt
            ;;

        9|tools|maintenance)
            maintenance_menu
            ;;

        10|functions|features)
            functions_menu
            ;;

        11|torr|torrserver|torrserver-manager)
            echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
            echo -e "  📺 ${C_BOLD}TORRSERVER MANAGER${C_RESET}"
            echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
            echo

            local torr_script=""
            if [[ -f "/root/torrserver-manager.sh" ]]; then
                torr_script="/root/torrserver-manager.sh"
            elif [[ -f "$(dirname "$0")/torrserver-manager.sh" ]]; then
                torr_script="$(dirname "$0")/torrserver-manager.sh"
            elif [[ -f "./torrserver-manager.sh" ]]; then
                torr_script="./torrserver-manager.sh"
            else
                torr_script="$(download_script "torrserver-manager.sh")"
                cp -f "$torr_script" /root/torrserver-manager.sh 2>/dev/null || true
                chmod +x /root/torrserver-manager.sh 2>/dev/null || true
            fi

            echo ">>> Запуск TorrServer Manager..."
            echo
            bash "$torr_script"

            echo
            echo -e "${C_GREEN}✓ TORRSERVER MANAGER ЗАВЕРШЁН${C_RESET}"
            pause_prompt
            ;;

        12|lers|lers-manager)
            echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
            echo -e "  🏢 ${C_BOLD}СИСТЕМА ДИСПЕТЧЕРИЗАЦИИ ЛЭРС УЧЁТ${C_RESET}"
            echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
            echo

            local lers_script=""
            if [[ -f "/root/lers-manager.sh" ]]; then
                lers_script="/root/lers-manager.sh"
            elif [[ -f "$(dirname "$0")/lers-manager.sh" ]]; then
                lers_script="$(dirname "$0")/lers-manager.sh"
            elif [[ -f "./lers-manager.sh" ]]; then
                lers_script="./lers-manager.sh"
            else
                lers_script="$(download_script "lers-manager.sh")"
                cp -f "$lers_script" /root/lers-manager.sh 2>/dev/null || true
                chmod +x /root/lers-manager.sh 2>/dev/null || true
            fi

            echo ">>> Запуск /root/lers-manager.sh..."
            echo
            bash "$lers_script"

            echo
            echo -e "${C_GREEN}✓ ЛЭРС УЧЁТ ЗАВЕРШЁН${C_RESET}"
            pause_prompt
            ;;

        0|q|exit)
            echo "Выход."
            exit 0
            ;;

        *)
            echo -e "${C_RED}❌ Некорректный выбор: ${choice}${C_RESET}" >&2
            sleep 1
            ;;
    esac
}

###############################################################################
# MAIN LOOP
###############################################################################

main() {
    local cli_arg="${1:-}"

    # Если передан аргумент (например: bash install.sh 1), выполняем и выходим
    if [[ -n "$cli_arg" ]]; then
        run_action "$cli_arg"
        return 0
    fi

    if [[ ! -r /dev/tty ]]; then
        echo -e "${C_RED}❌ Не найден интерактивный терминал /dev/tty.${C_RESET}" >&2
        echo "    Для автоматического запуска передайте номер аргументом: bash $0 [1|2|3|4|5|6|7|8|9|10|11|12]" >&2
        exit 1
    fi

    # Бесконечный интерактивный цикл главного меню
    while true; do
        show_dashboard
        local choice="0"
        read_choice "${C_BOLD}Выберите вариант [0-12]: ${C_RESET}" choice "0"
        echo

        case "$choice" in
            1|2|3|4|5|6|7|8|9|10|11|12)
                run_action "$choice"
                ;;
            0|q|exit)
                echo "Выход."
                exit 0
                ;;
            *)
                echo -e "${C_RED}❌ Некорректный выбор: ${choice}${C_RESET}" >&2
                sleep 1
                ;;
        esac
    done
}

main "${1:-}"
