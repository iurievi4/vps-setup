#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# VPS SETUP INSTALLER & MANAGER
#
# Режимы работы:
#   1) Полная автоматическая установка (тихий режим, сохранение текущей БД)
#   2) Ручной запуск setup.sh (интерактивный режим, FORCE_BOOTSTRAP=1)
#   3) Установка безопасности (vps-security-installer.sh)
#   4) Управление SSH-ключами (ssh-key-manager.sh)
#   5) Шаблоны сайтов и безопасность Nginx (nginx-templates.sh)
#   6) Сброс маркера завершения (/etc/vps-bootstrap-complete)
#   7) 3x-ui: установка, шифрование и проверка баз
#   8) CSQTT Server Installer & Manager (csqtt-install.sh)
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
    local status_xui_svc status_nginx status_warp
    if systemctl is-active --quiet x-ui 2>/dev/null; then
        status_xui_svc="${C_GREEN}● Активна (x-ui.service)${C_RESET}"
    elif command -v x-ui >/dev/null 2>&1 || [[ -f "$XUI_DB_FILE" ]]; then
        status_xui_svc="${C_YELLOW}○ Остановлена${C_RESET}"
    else
        status_xui_svc="${C_GRAY}○ Не установлена${C_RESET}"
    fi

    if systemctl is-active --quiet nginx 2>/dev/null; then
        status_nginx="${C_GREEN}● Запущен${C_RESET}"
    elif command -v nginx >/dev/null 2>&1; then
        status_nginx="${C_YELLOW}○ Остановлен${C_RESET}"
    else
        status_nginx="${C_GRAY}○ Не установлен${C_RESET}"
    fi

    if command -v warp-cli >/dev/null 2>&1 && warp-cli status 2>/dev/null | grep -qi 'Connected'; then
        status_warp="${C_GREEN}● Подключен${C_RESET}"
    elif command -v warp-cli >/dev/null 2>&1; then
        status_warp="${C_YELLOW}○ Установлен (отключен)${C_RESET}"
    else
        status_warp="${C_GRAY}○ Не установлен${C_RESET}"
    fi

    echo
    echo -e "${C_BCYAN}╔════════════════════════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BCYAN}║${C_RESET}                  ${C_BOLD}${C_GREEN}★ VPS SETUP INSTALLER & MANAGER ★${C_RESET}                   ${C_BCYAN}║${C_RESET}"
    echo -e "${C_BCYAN}║${C_RESET}          ${C_GRAY}Автоматический комплекс настройки, защиты и сервисов${C_RESET}          ${C_BCYAN}║${C_RESET}"
    echo -e "${C_BCYAN}╚════════════════════════════════════════════════════════════════════════╝${C_RESET}"
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

    if [[ -f "$XUI_DB_FILE" ]]; then
        echo -e "  ${C_GRAY}├─${C_RESET} База данных 3x-ui : ${C_GREEN}● Обнаружена${C_RESET} ${C_GRAY}(${XUI_DB_FILE})${C_RESET}"
    else
        echo -e "  ${C_GRAY}├─${C_RESET} База данных 3x-ui : ${C_GRAY}○ Не найдена${C_RESET}"
    fi
    echo -e "  ${C_GRAY}├─${C_RESET} Служба 3x-ui      : ${status_xui_svc}"
    echo -e "  ${C_GRAY}├─${C_RESET} Веб-сервер Nginx  : ${status_nginx}"
    echo -e "  ${C_GRAY}└─${C_RESET} Cloudflare WARP   : ${status_warp}"
    echo
    echo -e "${C_BOLD}${C_CYAN}📋 МЕНЮ УСТАНОВКИ И УПРАВЛЕНИЯ:${C_RESET}"
    echo -e "  ${C_BGREEN}[1]${C_RESET}  🚀 Полная автоматическая установка ${C_GRAY}(setup.sh в тихом режиме)${C_RESET}"
    echo -e "  ${C_BGREEN}[2]${C_RESET}  ⚙️  Ручной запуск setup.sh ${C_GRAY}(интерактивные вопросы, FORCE_BOOTSTRAP=1)${C_RESET}"
    echo -e "  ${C_BGREEN}[3]${C_RESET}  🛡️  Установка безопасности ${C_GRAY}(vps-security-installer.sh: Fail2ban, WARP)${C_RESET}"
    echo -e "  ${C_BGREEN}[4]${C_RESET}  🔑 Управление SSH-ключами ${C_GRAY}(ssh-key-manager.sh: Ed25519, защита)${C_RESET}"
    echo -e "  ${C_BGREEN}[5]${C_RESET}  🌐 Шаблоны сайтов и прокси ${C_GRAY}(nginx-templates.sh: маскировка, Reverse Proxy)${C_RESET}"
    if [[ -f "$BOOTSTRAP_MARKER" ]]; then
        echo -e "  ${C_BGREEN}[6]${C_RESET}  🔄 Сбросить маркер настройки ${C_GRAY}(удалить /etc/vps-bootstrap-complete)${C_RESET}"
    fi
    echo -e "  ${C_BGREEN}[7]${C_RESET}  🎛️  3x-ui: установка, шифрование и проверка баз"
    echo -e "  ${C_BGREEN}[8]${C_RESET}  🎮 CSQTT Server Installer & Manager ${C_GRAY}(Version-Agnostic)${C_RESET}"
    echo -e "  ${C_RED}[0]${C_RESET}  🚪 Выход"
    echo
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
        echo -e "  ⚙️  ${C_BOLD}РУЧНОЙ ЗАПУСК SETUP.SH${C_RESET}"
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

    6|reset)
        echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
        echo -e "  🔄 ${C_BOLD}СБРОС МАРКЕРА УСТАНОВКИ${C_RESET}"
        echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
        echo

        if [[ -f "$BOOTSTRAP_MARKER" ]]; then
            rm -f "$BOOTSTRAP_MARKER"
            echo -e "${C_GREEN}✓ Маркер $BOOTSTRAP_MARKER успешно удалён.${C_RESET}"
            echo "  Теперь любая версия setup.sh запустится без блокировки."
        else
            echo "ℹ️ Маркер $BOOTSTRAP_MARKER отсутствует (сервер и так считается чистым)."
        fi
        echo
        ;;

    7|xui|xui-manager)
        echo -e "${C_BOLD}${C_CYAN}======================================================================${C_RESET}"
        echo -e "  🎛️  ${C_BOLD}3X-UI: УСТАНОВКА, ШИФРОВАНИЕ И ПРОВЕРКА${C_RESET}"
        echo -e "${C_BOLD}${C_CYAN}======================================================================${C_RESET}"
        echo
        echo -e "  ${C_BGREEN}[1]${C_RESET} Установка чистая 3x-ui с официального репозитория"
        echo -e "  ${C_BGREEN}[2]${C_RESET} Создание зашифрованной базы"
        echo -e "  ${C_BGREEN}[3]${C_RESET} Как проверить, что зашифрованный файл на 100% подходит к setup.sh"
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

    8|csqtt|csqtt-server)
        echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
        echo -e "  🎮 ${C_BOLD}CSQTT SERVER INSTALLER & MANAGER (VERSION-AGNOSTIC)${C_RESET}"
        echo -e "${C_BOLD}${C_GREEN}======================================================================${C_RESET}"
        echo

        CSQTT_SCRIPT="$(download_script "csqtt-install.sh")"
        cp -f "$CSQTT_SCRIPT" /root/csqtt-install.sh
        chmod +x /root/csqtt-install.sh

        echo ">>> Запуск /root/csqtt-install.sh..."
        echo
        bash /root/csqtt-install.sh

        echo
        echo -e "${C_GREEN}✓ CSQTT SERVER ЗАВЕРШЁН${C_RESET}"
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
