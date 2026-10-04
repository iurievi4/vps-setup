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
#   ЛЭРС УЧЁТ:
#     8) Система диспетчеризации ЛЭРС УЧЁТ (lers-manager.sh)
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

pause_prompt() {
    echo
    read -r -p "Нажмите Enter для возврата в меню обслуживания..." </dev/tty || true
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
    if command -v warp-cli >/dev/null 2>&1 && warp-cli status 2>/dev/null | grep -qi 'Connected'; then
        status_warp="${C_GREEN}● Подключен${C_RESET}"
    elif command -v warp-cli >/dev/null 2>&1; then
        status_warp="${C_YELLOW}○ Установлен (отключен)${C_RESET}"
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
    elif [[ -d "/opt/mssql" ]] || command -v sqlcmd >/dev/null 2>&1; then
        status_mssql="${C_YELLOW}○ Остановлен${C_RESET}"
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
    if systemctl is-active --quiet antiscanner 2>/dev/null || pgrep -f antiscanner >/dev/null 2>&1; then
        status_antiscanner="${C_GREEN}● Активен${C_RESET}"
    elif [[ -f "/etc/systemd/system/antiscanner.service" ]]; then
        status_antiscanner="${C_YELLOW}○ Остановлен${C_RESET}"
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
    echo -e "  ${C_BGREEN}[1]${C_RESET}  🚀 Полная автоматическая установка ${C_GRAY}(setup.sh в тихом режиме)${C_RESET}"
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
    echo -e "${C_GRAY}  ──────────────────────────────────────────────────────────────────────${C_RESET}"
    echo
    echo -e "${C_BOLD}${C_YELLOW}  СИСТЕМА ДИСПЕТЧЕРИЗАЦИИ ЛЭРС УЧЁТ${C_RESET}"
    echo -e "  ${C_BGREEN}[8]${C_RESET}  📊 Управление ЛЭРС УЧЁТ ${C_GRAY}(lers-manager.sh)${C_RESET}"
    echo
    echo -e "  ${C_RED}[0]${C_RESET}  🚪 Выход"
    echo
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

        local m_choice
        read -r -p "Выберите действие [0-14]: " m_choice </dev/tty || m_choice="0"
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
                read -rp "Продолжить полное обновление? [y/N]: " confirm_full
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
                read -rp "Продолжить сброс маркера? [y/N]: " confirm_marker
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
                read -rp "Вы действительно хотите ПЕРЕЗАГРУЗИТЬ сервер прямо сейчас? [y/N]: " confirm_reboot
                if [[ "$confirm_reboot" =~ ^[YyДд]$ ]]; then
                    echo ">>> Перезагрузка сервера..."
                    reboot
                else
                    echo "Перезагрузка отменена."
                    pause_prompt
                fi
                ;;

            14)
                read -rp "Вы действительно хотите ВЫКЛЮЧИТЬ сервер прямо сейчас? [y/N]: " confirm_power
                if [[ "$confirm_power" =~ ^[YyДд]$ ]]; then
                    echo ">>> Выключение сервера..."
                    poweroff
                else
                    echo "Выключение отменено."
                    pause_prompt
                fi
                ;;

            0)
                break
                ;;

            *)
                echo -e "${C_RED}❌ Некорректный выбор: ${m_choice}${C_RESET}" >&2
                sleep 1
                ;;
        esac
    done
}

CHOICE="${1:-}"

if [[ -z "$CHOICE" ]]; then
    if [[ ! -r /dev/tty ]]; then
        echo -e "${C_RED}❌ Не найден интерактивный терминал /dev/tty.${C_RESET}" >&2
        echo "    Для автоматического запуска передайте номер аргументом: bash $0 [1|2|3|4|5|6|7|8]" >&2
        exit 1
    fi
    show_dashboard
    read -r -p "Выберите вариант [0-8]: " CHOICE </dev/tty || CHOICE="0"
fi

echo

case "$CHOICE" in
    1)
        echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
        echo -e "  🚀 ${C_BOLD}ПОЛНАЯ АВТОМАТИЧЕСКАЯ УСТАНОВКА${C_RESET}"
        echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
        echo

        SETUP_SCRIPT="$(download_script "setup.sh")"

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
        bash "$SETUP_SCRIPT"

        echo
        echo -e "${C_GREEN}✓ SETUP.SH ЗАВЕРШЁН${C_RESET}"
        ;;

    2)
        echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
        echo -e "  ⚙️  ${C_BOLD}РУЧНАЯ / ПОВТОРНАЯ НАСТРОЙКА SETUP.SH${C_RESET}"
        echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
        echo

        SETUP_SCRIPT="$(download_script "setup.sh")"

        if [[ -f "$BOOTSTRAP_MARKER" ]]; then
            echo -e "ℹ️ Обнаружен существующий маркер: ${C_YELLOW}$BOOTSTRAP_MARKER${C_RESET}"
            echo "ℹ️ Активирован режим повторного запуска (FORCE_BOOTSTRAP=1)."
        fi

        backup_existing_db
        echo

        export FORCE_BOOTSTRAP=1

        echo ">>> Запуск setup.sh в интерактивном режиме..."
        echo
        bash "$SETUP_SCRIPT"

        echo
        echo -e "${C_GREEN}✓ SETUP.SH ЗАВЕРШЁН${C_RESET}"
        ;;

    3)
        echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
        echo -e "  🛡️  ${C_BOLD}VPS SECURITY INSTALLER${C_RESET}"
        echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
        echo

        SECURITY_SCRIPT="$(download_script "vps-security-installer.sh")"

        echo ">>> Запуск vps-security-installer.sh..."
        echo
        bash "$SECURITY_SCRIPT"

        echo
        echo -e "${C_GREEN}✓ SECURITY INSTALLER ЗАВЕРШЁН${C_RESET}"
        ;;

    4|ssh|ssh-manager)
        echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
        echo -e "  🔑 ${C_BOLD}SSH KEY & SECURITY MANAGER${C_RESET}"
        echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
        echo

        SSH_SCRIPT="$(download_script "ssh-key-manager.sh")"

        echo ">>> Запуск ssh-key-manager.sh..."
        echo
        bash "$SSH_SCRIPT"

        echo
        echo -e "${C_GREEN}✓ SSH KEY MANAGER ЗАВЕРШЁН${C_RESET}"
        ;;

    5|nginx|templates)
        echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
        echo -e "  🌐 ${C_BOLD}NGINX TEMPLATE & SECURITY MANAGER${C_RESET}"
        echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
        echo

        NGINX_SCRIPT="$(download_script "nginx-templates.sh")"

        echo ">>> Запуск nginx-templates.sh..."
        echo
        bash "$NGINX_SCRIPT"

        echo
        echo -e "${C_GREEN}✓ NGINX TEMPLATE MANAGER ЗАВЕРШЁН${C_RESET}"
        ;;

    6|xui|3x-ui)
        echo -e "${C_BOLD}${C_CYAN}======================================================================${C_RESET}"
        echo -e "  🎛️  ${C_BOLD}3X-UI: УСТАНОВКА, ШИФРОВАНИЕ И ПРОВЕРКА${C_RESET}"
        echo -e "${C_BOLD}${C_CYAN}======================================================================${C_RESET}"
        echo
        echo -e "  ${C_BGREEN}[1]${C_RESET} Установка чистая 3x-ui с официального репозитория"
        echo -e "  ${C_BGREEN}[2]${C_RESET} Создание зашифрованной базы"
        echo -e "  ${C_BGREEN}[3]${C_RESET} Как проверить, что зашифрованный файл подходит к setup.sh"
        echo -e "  ${C_RED}[0]${C_RESET} Назад в главное меню"
        echo
        read -r -p "Выберите вариант [0-3]: " XUI_CHOICE </dev/tty || XUI_CHOICE="0"

        case "$XUI_CHOICE" in
            1)
                echo
                echo ">>> Запуск официального скрипта установки 3x-ui (mhsanaei)..."
                echo
                bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
                ;;
            2)
                XUI_SCRIPT="$(download_script "export-xui-db.sh")"
                bash "$XUI_SCRIPT" create
                ;;
            3)
                XUI_SCRIPT="$(download_script "export-xui-db.sh")"
                bash "$XUI_SCRIPT" verify
                ;;
            0)
                ;;
            *)
                echo -e "${C_RED}❌ Некорректный выбор: ${XUI_CHOICE}${C_RESET}" >&2
                ;;
        esac
        ;;

    7|tools|maintenance)
        maintenance_menu
        ;;

    8|lers|lers-manager)
        echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
        echo -e "  🏢 ${C_BOLD}СИСТЕМА ДИСПЕТЧЕРИЗАЦИИ ЛЭРС УЧЁТ${C_RESET}"
        echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
        echo

        LERS_SCRIPT="$(download_script "lers-manager.sh")"
        cp -f "$LERS_SCRIPT" /root/lers-manager.sh
        chmod +x /root/lers-manager.sh

        echo ">>> Запуск /root/lers-manager.sh..."
        echo
        bash /root/lers-manager.sh

        echo
        echo -e "${C_GREEN}✓ ЛЭРС УЧЁТ ЗАВЕРШЁН${C_RESET}"
        ;;

    0)
        echo "Выход."
        exit 0
        ;;

    *)
        echo -e "${C_RED}❌ Некорректный выбор: ${CHOICE}${C_RESET}" >&2
        exit 1
        ;;
esac
