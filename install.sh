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
#   ОБСЛУЖИВАНИЕ VPS:
#     7) Обслуживание и диагностика (комплекс обновления, аудита и контроля)
#   УПРАВЛЕНИЕ ФУНКЦИЯМИ VPS:
#     8) Управление функциями VPS (WARP, AntiScanner, СУБД, Docker, сервисы)
#   ЛЭРС УЧЁТ:
#     9) Система диспетчеризации ЛЭРС УЧЁТ (lers-manager.sh)
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

    local status_antiscanner
    if systemctl is-active --quiet antiscan.service 2>/dev/null; then
        status_antiscanner="${C_GREEN}● Активен${C_RESET}"
    elif systemctl is-enabled --quiet antiscan.timer 2>/dev/null; then
        status_antiscanner="${C_YELLOW}○ Установлен (служба остановлена)${C_RESET}"
    elif [[ -f "/etc/systemd/system/antiscan.service" ]] || \
         [[ -f "/etc/systemd/system/antiscan.timer" ]] || \
         [[ -x "/usr/local/sbin/antiscan-update.sh" ]]; then
        status_antiscanner="${C_YELLOW}○ Установлен${C_RESET}"
    else
        status_antiscanner="${C_GRAY}○ Не установлен${C_RESET}"
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
    echo -e "  ${C_GRAY}├─${C_RESET} Cloudflare WARP   : ${status_warp}"
    echo -e "  ${C_GRAY}├─${C_RESET} Docker & Контейнеры: ${status_docker}"
    echo -e "  ${C_GRAY}├─${C_RESET} СУБД PostgreSQL   : ${status_postgres}"
    echo -e "  ${C_GRAY}├─${C_RESET} СУБД MS SQL Server: ${status_mssql}"
    echo -e "  ${C_GRAY}├─${C_RESET} Медиа TorrServer  : ${status_torr}"
    echo -e "  ${C_GRAY}├─${C_RESET} ЛЭРС УЧЁТ         : ${status_lers}"
    echo -e "  ${C_GRAY}├─${C_RESET} Защита Fail2ban   : ${status_fail2ban}"
    echo -e "  ${C_GRAY}└─${C_RESET} Защита AntiScanner: ${status_antiscanner}"
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
    echo
    echo -e "${C_BOLD}${C_CYAN}  ОБСЛУЖИВАНИЕ VPS${C_RESET}"
    echo -e "  ${C_BGREEN}[7]${C_RESET}  🔧 Обслуживание и диагностика ${C_GRAY}(обновление, очистка, аудит)${C_RESET}"
    echo
    echo -e "${C_BOLD}${C_CYAN}  УПРАВЛЕНИЕ ФУНКЦИЯМИ VPS${C_RESET}"
    echo -e "  ${C_BGREEN}[8]${C_RESET}  ⚙️  Управление функциями VPS ${C_GRAY}(WARP, AntiScanner, СУБД, Docker, сервисы)${C_RESET}"
    echo
    echo -e "${C_GRAY}  ──────────────────────────────────────────────────────────────────────${C_RESET}"
    echo
    echo -e "${C_BOLD}${C_YELLOW}  СИСТЕМА ДИСПЕТЧЕРИЗАЦИИ ЛЭРС УЧЁТ${C_RESET}"
    echo -e "  ${C_BGREEN}[9]${C_RESET}  📊 Управление ЛЭРС УЧЁТ ${C_GRAY}(lers-manager.sh)${C_RESET}"
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
        echo -e "${C_BOLD}${C_CYAN}  КОМПЛЕКСНОЕ ОБСЛУЖИВАНИЕ${C_RESET}"
        echo -e "  ${C_BGREEN}[1]${C_RESET}  ⚡ Быстрое обслуживание"
        echo -e "       ${C_GRAY}└─ update + upgrade + autoremove + autoclean + аудит служб${C_RESET}"
        echo
        echo -e "${C_BOLD}${C_CYAN}  ОБНОВЛЕНИЕ И ОЧИСТКА СИСТЕМЫ${C_RESET}"
        echo -e "  ${C_BGREEN}[2]${C_RESET}  🔄 Обновить списки пакетов ${C_GRAY}(apt update)${C_RESET}"
        echo -e "  ${C_BGREEN}[3]${C_RESET}  ⬆️  Безопасное обновление пакетов ${C_GRAY}(apt upgrade)${C_RESET}"
        echo -e "  ${C_BGREEN}[4]${C_RESET}  🚀 Полное обновление дистрибутива ${C_GRAY}(apt full-upgrade)${C_RESET}"
        echo -e "  ${C_BGREEN}[5]${C_RESET}  🧹 Очистить систему ${C_GRAY}(autoremove + autoclean + clean)${C_RESET}"
        echo
        echo -e "${C_BOLD}${C_CYAN}  ДИАГНОСТИКА И АУДИТ${C_RESET}"
        echo -e "  ${C_BGREEN}[6]${C_RESET}  ❤️  Проверка ресурсов VPS ${C_GRAY}(CPU, RAM, Диск, Swap, Uptime)${C_RESET}"
        echo -e "  ${C_BGREEN}[7]${C_RESET}  📦 Проверка базы пакетов ${C_GRAY}(dpkg audit, broken dependencies)${C_RESET}"
        echo -e "  ${C_BGREEN}[8]${C_RESET}  🔥 Проверка упавших сервисов ${C_GRAY}(systemctl --failed)${C_RESET}"
        echo -e "  ${C_BGREEN}[9]${C_RESET}  🌐 Проверка сети ${C_GRAY}(IP, DNS, открытые порты, маршруты)${C_RESET}"
        echo -e "  ${C_BGREEN}[10]${C_RESET} 🛡️  Проверка безопасности ${C_GRAY}(UFW статус, Fail2ban, SSH логи)${C_RESET}"
        echo
        echo -e "${C_BOLD}${C_CYAN}  СИСТЕМНЫЕ ОПЕРАЦИИ${C_RESET}"
        echo -e "  ${C_BGREEN}[11]${C_RESET} 📜 Очистить системные журналы ${C_GRAY}(journalctl --vacuum-time=3d)${C_RESET}"
        echo -e "  ${C_BGREEN}[12]${C_RESET} ⚠️  Сбросить маркер настройки ${C_GRAY}(/etc/vps-bootstrap-complete)${C_RESET}"
        echo -e "  ${C_BGREEN}[13]${C_RESET} 🔁 Перезагрузка VPS ${C_GRAY}(reboot)${C_RESET}"
        echo -e "  ${C_BGREEN}[14]${C_RESET} ⏻  Выключение VPS ${C_GRAY}(poweroff)${C_RESET}"
        echo
        echo -e "  ${C_RED}[0]${C_RESET}  ◀️  Назад в главное меню"
        echo

        local m_choice="0"
        read_choice "${C_BOLD}Выберите действие [0-14]: ${C_RESET}" m_choice "0"
        echo

        case "$m_choice" in
            1)
                echo -e "${C_BOLD}${C_GREEN}>>> [1/5] Обновление списков пакетов (apt update)...${C_RESET}"
                apt-get update
                echo
                echo -e "${C_BOLD}${C_GREEN}>>> [2/5] Установка безопасных обновлений (apt upgrade)...${C_RESET}"
                DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
                echo
                echo -e "${C_BOLD}${C_GREEN}>>> [3/5] Удаление неиспользуемых пакетов (autoremove)...${C_RESET}"
                apt-get autoremove -y
                echo
                echo -e "${C_BOLD}${C_GREEN}>>> [4/5] Очистка архивов кэша пакетов (autoclean + clean)...${C_RESET}"
                apt-get autoclean && apt-get clean
                echo
                echo -e "${C_BOLD}${C_GREEN}>>> [5/5] Проверка упавших служб...${C_RESET}"
                local failed_units
                failed_units=$(systemctl --failed --no-legend 2>/dev/null || true)
                if [[ -n "$failed_units" ]]; then
                    echo -e "${C_RED}⚠️ Обнаружены службы с ошибками:${C_RESET}"
                    echo "$failed_units"
                else
                    echo -e "${C_GREEN}✓ Все системные службы работают штатно (0 failed units).${C_RESET}"
                fi
                echo
                echo -e "${C_GREEN}======================================================================${C_RESET}"
                echo -e "  ✓ БЫСТРОЕ ОБСЛУЖИВАНИЕ УСПЕШНО ЗАВЕРШЕНО"
                echo -e "${C_GREEN}======================================================================${C_RESET}"
                pause_prompt
                ;;

            2)
                echo ">>> Обновление списков пакетов..."
                apt-get update
                pause_prompt
                ;;

            3)
                echo ">>> Установка обновлений пакетов..."
                DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
                pause_prompt
                ;;

            4)
                echo -e "${C_YELLOW}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
                echo -e "${C_YELLOW}║ ⚠️  ВНИМАНИЕ                                                  ║${C_RESET}"
                echo -e "${C_YELLOW}║ full-upgrade может удалить или заменить системные пакеты     ║${C_RESET}"
                echo -e "${C_YELLOW}║ для разрешения сложных зависимостей.                         ║${C_RESET}"
                echo -e "${C_YELLOW}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
                read -r -p "Продолжить полное обновление? [y/N]: " confirm_full </dev/tty 2>/dev/null || read -r -p "Продолжить полное обновление? [y/N]: " confirm_full 2>/dev/null || confirm_full="N"
                if [[ "$confirm_full" =~ ^[YyДд]$ ]]; then
                    DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y
                else
                    echo "Отменено пользователем."
                fi
                pause_prompt
                ;;

            5)
                echo ">>> Очистка пакетов и кэша..."
                apt-get autoremove -y
                apt-get autoclean
                apt-get clean
                echo -e "${C_GREEN}✓ Очистка завершена.${C_RESET}"
                pause_prompt
                ;;

            6)
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

            7)
                echo ">>> Проверка базы пакетов dpkg..."
                dpkg --audit
                echo ">>> Проверка дерева зависимостей APT..."
                apt-get check
                echo -e "${C_GREEN}✓ Ошибок зависимостей не обнаружено.${C_RESET}"
                pause_prompt
                ;;

            8)
                echo ">>> Список служб с ошибками (failed units):"
                local failed_out
                failed_out=$(systemctl --failed --no-legend 2>/dev/null || true)
                if [[ -z "$failed_out" ]]; then
                    echo -e "${C_GREEN}✓ Упавших служб нет (0 failed units).${C_RESET}"
                else
                    systemctl --failed
                fi
                pause_prompt
                ;;

            9)
                echo -e "${C_BOLD}${C_CYAN}=== Сетевые интерфейсы и IP ===${C_RESET}"
                ip -br addr 2>/dev/null || ifconfig 2>/dev/null || ip a
                echo
                echo -e "${C_BOLD}${C_CYAN}=== Маршруты по умолчанию ===${C_RESET}"
                ip route 2>/dev/null || route -n
                echo
                echo -e "${C_BOLD}${C_CYAN}=== Серверы DNS ===${C_RESET}"
                grep '^nameserver' /etc/resolv.conf 2>/dev/null || echo "Не удалось прочесть /etc/resolv.conf"
                echo
                echo -e "${C_BOLD}${C_CYAN}=== Открытые прослушиваемые порты (LISTEN) ===${C_RESET}"
                ss -tulpn 2>/dev/null | grep -E 'Netid|LISTEN' || netstat -tulpn 2>/dev/null || echo "Команда ss недоступна"
                pause_prompt
                ;;

            10)
                echo -e "${C_BOLD}${C_CYAN}=== Статус файрвола UFW ===${C_RESET}"
                if command -v ufw >/dev/null 2>&1; then
                    ufw status verbose
                else
                    echo "UFW не установлен в системе."
                fi
                echo
                echo -e "${C_BOLD}${C_CYAN}=== Статус Fail2ban ===${C_RESET}"
                if command -v fail2ban-client >/dev/null 2>&1 && systemctl is-active --quiet fail2ban 2>/dev/null; then
                    fail2ban-client status
                else
                    echo "Fail2ban не запущен или не установлен."
                fi
                echo
                echo -e "${C_BOLD}${C_CYAN}=== Последние входы по SSH ===${C_RESET}"
                last -n 5 2>/dev/null || true
                pause_prompt
                ;;

            11)
                echo ">>> Очистка логов journald старше 3 дней..."
                journalctl --vacuum-time=3d
                echo -e "${C_GREEN}✓ Журналы очищены.${C_RESET}"
                pause_prompt
                ;;

            12)
                echo -e "${C_YELLOW}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
                echo -e "${C_YELLOW}║ ⚠️  ВНИМАНИЕ                                                  ║${C_RESET}"
                echo -e "${C_YELLOW}║ Удаление маркера позволит повторно запустить                  ║${C_RESET}"
                echo -e "${C_YELLOW}║ первоначальную настройку VPS через setup.sh.                  ║${C_RESET}"
                echo -e "${C_YELLOW}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
                read -r -p "Продолжить сброс маркера? [y/N]: " confirm_marker </dev/tty 2>/dev/null || read -r -p "Продолжить сброс маркера? [y/N]: " confirm_marker 2>/dev/null || confirm_marker="N"
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

            13)
                read -r -p "Вы действительно хотите ПЕРЕЗАГРУЗИТЬ сервер прямо сейчас? [y/N]: " confirm_reboot </dev/tty 2>/dev/null || read -r -p "Вы действительно хотите ПЕРЕЗАГРУЗИТЬ сервер прямо сейчас? [y/N]: " confirm_reboot 2>/dev/null || confirm_reboot="N"
                if [[ "$confirm_reboot" =~ ^[YyДд]$ ]]; then
                    echo ">>> Перезагрузка сервера..."
                    reboot
                else
                    echo "Перезагрузка отменена."
                    pause_prompt
                fi
                ;;

            14)
                read -r -p "Вы действительно хотите ВЫКЛЮЧИТЬ сервер прямо сейчас? [y/N]: " confirm_power </dev/tty 2>/dev/null || read -r -p "Вы действительно хотите ВЫКЛЮЧИТЬ сервер прямо сейчас? [y/N]: " confirm_power 2>/dev/null || confirm_power="N"
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

###############################################################################
# УПРАВЛЕНИЕ ФУНКЦИЯМИ VPS (ПУНКТ 8)
###############################################################################

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

# --- Подменю AntiScanner ---
manage_antiscanner() {
    while true; do
        clear 2>/dev/null || true
        echo
        echo -e "${C_BCYAN}════════════════════════════════════════════════════════════════════════${C_RESET}"
        echo -e "                  ${C_BOLD}${C_GREEN}🛡️  УПРАВЛЕНИЕ ANTISCANNER${C_RESET}"
        echo -e "${C_BCYAN}════════════════════════════════════════════════════════════════════════${C_RESET}"
        echo

        local anti_cur
        if systemctl is-active --quiet antiscan.service 2>/dev/null; then
            anti_cur="${C_GREEN}● RUNNING (Служба активна)${C_RESET}"
        elif systemctl is-enabled --quiet antiscan.timer 2>/dev/null; then
            anti_cur="${C_YELLOW}○ Установлен (таймер активен)${C_RESET}"
        elif [[ -f "/etc/systemd/system/antiscan.service" ]] || [[ -f "/etc/systemd/system/antiscan.timer" ]] || [[ -x "/usr/local/sbin/antiscan-update.sh" ]]; then
            anti_cur="${C_YELLOW}○ Установлен (служба остановлена)${C_RESET}"
        else
            anti_cur="${C_GRAY}○ Не установлен${C_RESET}"
        fi

        echo -e "  Текущее состояние: ${anti_cur}"
        echo

        local is_anti_installed=0
        if systemctl is-active --quiet antiscan.service 2>/dev/null ||            systemctl list-unit-files 2>/dev/null | grep -qE '^antiscan\.(service|timer)' ||            [[ -f "/etc/systemd/system/antiscan.service" ]] ||            [[ -f "/etc/systemd/system/antiscan.timer" ]] ||            [[ -f "/lib/systemd/system/antiscan.service" ]] ||            [[ -x "/usr/local/sbin/antiscan-update.sh" ]]; then
            is_anti_installed=1
        fi

        if [[ "$is_anti_installed" -eq 0 ]]; then
            echo -e "  ${C_YELLOW}⚠️  AntiScanner не установлен в системе.${C_RESET}"
            echo -e "     Для установки перейдите в Главное меню -> [3] Безопасность VPS."
            echo
            echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
            echo
            local no_anti="0"
            read_choice "${C_BOLD}Выберите действие [0]: ${C_RESET}" no_anti "0"
            return 0
        fi

        echo -e "  ${C_BGREEN}[1]${C_RESET} ▶️  Запустить службу ${C_GRAY}(systemctl start antiscan.service)${C_RESET}"
        echo -e "  ${C_BGREEN}[2]${C_RESET} ⏹️  Остановить службу ${C_GRAY}(systemctl stop antiscan.service)${C_RESET}"
        echo -e "  ${C_BGREEN}[3]${C_RESET} 🔄 Перезапустить службу ${C_GRAY}(systemctl restart antiscan.service)${C_RESET}"
        echo -e "  ${C_BGREEN}[4]${C_RESET} 📥 Принудительно обновить базу ${C_GRAY}(antiscan-update.sh)${C_RESET}"
        echo -e "  ${C_BGREEN}[5]${C_RESET} ⏰ Включить автоматический таймер ${C_GRAY}(enable antiscan.timer)${C_RESET}"
        echo -e "  ${C_BGREEN}[6]${C_RESET} ⛔ Отключить автоматический таймер ${C_GRAY}(disable antiscan.timer)${C_RESET}"
        echo -e "  ${C_BGREEN}[7]${C_RESET} 🔍 Проверить статус службы и таймера ${C_GRAY}(status)${C_RESET}"
        echo
        echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
        echo

        local a_act="0"
        read_choice "${C_BOLD}Выберите действие [0-7]: ${C_RESET}" a_act "0"
        echo

        case "$a_act" in
            1)
                echo ">>> Запуск службы AntiScanner..."
                systemctl start antiscan.service 2>/dev/null || true
                echo -e "${C_GREEN}✓ Команда запуска выполнена.${C_RESET}"
                pause_prompt
                ;;
            2)
                echo ">>> Остановка службы AntiScanner..."
                systemctl stop antiscan.service 2>/dev/null || true
                echo -e "${C_YELLOW}✓ Служба остановлена.${C_RESET}"
                pause_prompt
                ;;
            3)
                echo ">>> Перезапуск службы AntiScanner..."
                systemctl restart antiscan.service 2>/dev/null || true
                echo -e "${C_GREEN}✓ Служба перезапущена.${C_RESET}"
                pause_prompt
                ;;
            4)
                echo ">>> Запуск принудительного обновления базы AntiScanner..."
                if [[ -x "/usr/local/sbin/antiscan-update.sh" ]]; then
                    /usr/local/sbin/antiscan-update.sh
                elif [[ -f "/usr/local/sbin/antiscan-update.sh" ]]; then
                    bash /usr/local/sbin/antiscan-update.sh
                else
                    echo -e "${C_RED}❌ Скрипт /usr/local/sbin/antiscan-update.sh не найден.${C_RESET}"
                fi
                pause_prompt
                ;;
            5)
                echo ">>> Включение таймера AntiScanner..."
                systemctl enable --now antiscan.timer 2>/dev/null || true
                echo -e "${C_GREEN}✓ Таймер активирован и добавлен в автозапуск.${C_RESET}"
                pause_prompt
                ;;
            6)
                echo ">>> Отключение таймера AntiScanner..."
                systemctl disable --now antiscan.timer 2>/dev/null || true
                echo -e "${C_YELLOW}✓ Таймер отключен.${C_RESET}"
                pause_prompt
                ;;
            7)
                echo -e "${C_BOLD}${C_CYAN}=== Статус antiscan.service ===${C_RESET}"
                systemctl status antiscan.service --no-pager 2>/dev/null || true
                echo
                echo -e "${C_BOLD}${C_CYAN}=== Статус antiscan.timer ===${C_RESET}"
                systemctl status antiscan.timer --no-pager 2>/dev/null || true
                pause_prompt
                ;;
            0|q|exit|back|назад)
                return 0
                ;;
            *)
                echo -e "${C_RED}❌ Некорректный выбор: ${a_act}${C_RESET}" >&2
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

        echo -e "  ${C_BGREEN}[1]${C_RESET} ▶️  Запустить службу Docker ${C_GRAY}(systemctl start docker)${C_RESET}"
        echo -e "  ${C_BGREEN}[2]${C_RESET} ⏹️  Остановить службу Docker ${C_GRAY}(systemctl stop docker)${C_RESET}"
        echo -e "  ${C_BGREEN}[3]${C_RESET} 🔄 Перезапустить службу Docker ${C_GRAY}(systemctl restart docker)${C_RESET}"
        echo -e "  ${C_BGREEN}[4]${C_RESET} 📋 Показать все контейнеры ${C_GRAY}(docker ps -a)${C_RESET}"
        echo -e "  ${C_BGREEN}[5]${C_RESET} 📊 Потребление ресурсов ${C_GRAY}(docker stats --no-stream)${C_RESET}"
        echo -e "  ${C_BGREEN}[6]${C_RESET} ⚙️  Включить автозапуск ${C_GRAY}(systemctl enable docker)${C_RESET}"
        echo -e "  ${C_BGREEN}[7]${C_RESET} ⛔ Отключить автозапуск ${C_GRAY}(systemctl disable docker)${C_RESET}"
        echo
        echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
        echo

        local d_act="0"
        read_choice "${C_BOLD}Выберите действие [0-7]: ${C_RESET}" d_act "0"
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
                echo -e "${C_BOLD}${C_CYAN}=== Список контейнеров Docker (docker ps -a) ===${C_RESET}"
                docker ps -a
                pause_prompt
                ;;
            5)
                echo -e "${C_BOLD}${C_CYAN}=== Статистика ресурсов контейнеров ===${C_RESET}"
                docker stats --no-stream 2>/dev/null || echo "Нет работающих контейнеров"
                pause_prompt
                ;;
            6)
                echo ">>> Включение автозапуска Docker..."
                systemctl enable docker 2>/dev/null || true
                echo -e "${C_GREEN}✓ Автозапуск включен.${C_RESET}"
                pause_prompt
                ;;
            7)
                echo ">>> Отключение автозапуска Docker..."
                systemctl disable docker 2>/dev/null || true
                echo -e "${C_YELLOW}✓ Автозапуск отключен.${C_RESET}"
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
        echo
        echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
        echo

        local t_act="0"
        read_choice "${C_BOLD}Выберите действие [0-6]: ${C_RESET}" t_act "0"
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
            echo -e "     Для установки перейдите в Главное меню -> [9] Управление ЛЭРС УЧЁТ."
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
        local warp_state antiscan_state postgres_state mssql_state docker_state torr_state lers_state

        if ! command -v warp-cli >/dev/null 2>&1; then
            warp_state="${C_GRAY}○ Не установлен${C_RESET}"
        elif ss -lnt 2>/dev/null | grep -qE '127\.0\.0\.1:40000|:40000 '; then
            warp_state="${C_GREEN}● RUNNING :40000${C_RESET}"
        elif warp-cli status 2>/dev/null | grep -qiE 'Connected|Status.*Connected'; then
            warp_state="${C_GREEN}● RUNNING${C_RESET}"
        else
            warp_state="${C_YELLOW}○ Установлен (отключен)${C_RESET}"
        fi

        if systemctl is-active --quiet antiscan.service 2>/dev/null; then
            antiscan_state="${C_GREEN}● RUNNING${C_RESET}"
        elif systemctl is-enabled --quiet antiscan.timer 2>/dev/null; then
            antiscan_state="${C_YELLOW}○ Таймер активен${C_RESET}"
        elif [[ -f "/etc/systemd/system/antiscan.service" ]] || [[ -f "/etc/systemd/system/antiscan.timer" ]] || [[ -x "/usr/local/sbin/antiscan-update.sh" ]]; then
            antiscan_state="${C_YELLOW}○ Установлен (остановлен)${C_RESET}"
        else
            antiscan_state="${C_GRAY}○ Не установлен${C_RESET}"
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
        echo -e "  ${C_GRAY}├─${C_RESET} AntiScanner        : ${antiscan_state}"
        echo -e "  ${C_GRAY}├─${C_RESET} Docker & Конт.     : ${docker_state}"
        echo -e "  ${C_GRAY}├─${C_RESET} PostgreSQL         : ${postgres_state}"
        echo -e "  ${C_GRAY}├─${C_RESET} MS SQL Server      : ${mssql_state}"
        echo -e "  ${C_GRAY}├─${C_RESET} TorrServer         : ${torr_state}"
        echo -e "  ${C_GRAY}└─${C_RESET} ЛЭРС УЧЁТ          : ${lers_state}"
        echo
        echo -e "${C_BOLD}${C_CYAN}  УПРАВЛЕНИЕ КОМПОНЕНТАМИ${C_RESET}"
        echo
        echo -e "  ${C_BGREEN}[1]${C_RESET} 🌐 Cloudflare WARP ${C_GRAY}(подключение, отключение, socks5)${C_RESET}"
        echo -e "  ${C_BGREEN}[2]${C_RESET} 🛡️  AntiScanner ${C_GRAY}(служба, таймер, обновление blacklist)${C_RESET}"
        echo -e "  ${C_BGREEN}[3]${C_RESET} 🐘 PostgreSQL ${C_GRAY}(запуск, остановка, автозапуск)${C_RESET}"
        echo -e "  ${C_BGREEN}[4]${C_RESET} 🗄️  MS SQL Server ${C_GRAY}(запуск, остановка, автозапуск)${C_RESET}"
        echo -e "  ${C_BGREEN}[5]${C_RESET} 🐳 Docker & Контейнеры ${C_GRAY}(служба, статус, список ps)${C_RESET}"
        echo -e "  ${C_BGREEN}[6]${C_RESET} 📺 TorrServer ${C_GRAY}(запуск, остановка, автозапуск)${C_RESET}"
        echo -e "  ${C_BGREEN}[7]${C_RESET} 🏢 ЛЭРС УЧЁТ ${C_GRAY}(служба, автозапуск, менеджер)${C_RESET}"
        echo
        echo -e "${C_BOLD}${C_CYAN}  ДОПОЛНИТЕЛЬНО${C_RESET}"
        echo
        echo -e "  ${C_BGREEN}[8]${C_RESET} 🔄 Обновить статус"
        echo -e "  ${C_BGREEN}[9]${C_RESET} 🔧 Запустить vps-security-installer.sh"
        echo
        echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад в главное меню"
        echo

        local f_choice="0"
        read_choice "${C_BOLD}Выберите функцию [0-9]: ${C_RESET}" f_choice "0"
        echo

        case "$f_choice" in
            1) manage_warp ;;
            2) manage_antiscanner ;;
            3) manage_postgres ;;
            4) manage_mssql ;;
            5) manage_docker ;;
            6) manage_torrserver ;;
            7) manage_lers ;;
            8) continue ;;
            9)
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

        7|tools|maintenance)
            maintenance_menu
            ;;

        8|functions|features)
            functions_menu
            ;;

        9|lers|lers-manager)
            echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
            echo -e "  🏢 ${C_BOLD}СИСТЕМА ДИСПЕТЧЕРИЗАЦИИ ЛЭРС УЧЁТ${C_RESET}"
            echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
            echo

            local lers_script
            lers_script="$(download_script "lers-manager.sh")"
            cp -f "$lers_script" /root/lers-manager.sh
            chmod +x /root/lers-manager.sh

            echo ">>> Запуск /root/lers-manager.sh..."
            echo
            bash /root/lers-manager.sh

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
        echo "    Для автоматического запуска передайте номер аргументом: bash $0 [1|2|3|4|5|6|7|8|9]" >&2
        exit 1
    fi

    # Бесконечный интерактивный цикл главного меню
    while true; do
        show_dashboard
        local choice="0"
        read_choice "${C_BOLD}Выберите вариант [0-9]: ${C_RESET}" choice "0"
        echo

        case "$choice" in
            1|2|3|4|5|6|7|8|9)
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
