#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# VPS MANAGEMENT · MODULE
# TorrServer Manager — Автономный модуль управления torrent stream сервером
# Репозиторий: vps-setup
#
# Пункты меню:
#   [1]  Статус TorrServer (PID, аптайм, порт, сеть, память, авторизация)
#   [2]  Запустить
#   [3]  Остановить
#   [4]  Перезапустить
#   [5]  Настройки доступа (логин / пароль, безопасный accs.db)
#   [6]  Сменить порт
#   [7]  Настроить автозапуск
#   [8]  Просмотр логов
#   [9]  Проверка доступности и диагностика
#   [10] Обновить TorrServer
#   [11] Резервная копия / восстановление
#   [12] Удалить TorrServer
#   [0]  Выход
###############################################################################

# Константы по умолчанию
DEFAULT_INSTALL_DIR="/opt/torrserver"
DEFAULT_SERVICE_NAME="torrserver.service"
DEFAULT_SERVICE_PATH="/etc/systemd/system/${DEFAULT_SERVICE_NAME}"
DEFAULT_PORT="8090"
DEFAULT_BIND_IP="0.0.0.0"
GITHUB_REPO="YouROK/TorrServer"
BACKUP_DIR="${DEFAULT_INSTALL_DIR}/backups"

# Цветовая палитра для терминала
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_CYAN='\033[0;36m'
C_BCYAN='\033[1;36m'
C_GREEN='\033[0;32m'
C_BGREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_BRED='\033[1;31m'
C_GRAY='\033[0;90m'

# Проверка прав суперпользователя (root)
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo >&2
    echo -e "${C_RED}❌ Скрипт необходимо запускать с правами root (sudo).${C_RESET}" >&2
    echo >&2
    exit 1
fi

# Универсальное чтение пользовательского ввода с поддержкой /dev/tty
read_choice() {
    local prompt="$1"
    local var_name="$2"
    local default_val="${3:-}"
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

# Безопасное чтение пароля без эхо-вывода
read_password_secret() {
    local prompt="$1"
    local var_name="$2"
    local val=""

    echo -ne "$prompt"

    if [[ -t 0 ]]; then
        read -rs val || val=""
    elif { exec 3</dev/tty; } 2>/dev/null; then
        read -rs val <&3 || val=""
        exec 3<&-
    else
        read -rs val || val=""
    fi
    echo
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

# Определение архитектуры сервера
detect_arch() {
    local arch
    arch="$(uname -m 2>/dev/null || echo "x86_64")"
    case "$arch" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armhf|armv7) echo "arm7" ;;
        armv5*|armv6*) echo "arm5" ;;
        i386|i686) echo "386" ;;
        *) echo "unknown" ;;
    esac
}

# Внешний IP-адрес для вывода информационных ссылок
get_server_ip() {
    local ip_str=""
    ip_str=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7}' | head -n 1 || true)
    if [[ -z "$ip_str" ]]; then
        ip_str=$(ip -br addr show scope global 2>/dev/null | awk '{print $3}' | awk -F'/' '{print $1}' | head -n 1 || true)
    fi
    if [[ -z "$ip_str" ]]; then
        ip_str="127.0.0.1"
    fi
    echo "$ip_str"
}

# Автономное обнаружение существующей установки TorrServer
# Заполняет глобальные переменные:
# TS_INSTALLED (0 или 1)
# TS_SERVICE_PATH (путь к unit-файлу)
# TS_BIN (путь к бинарнику)
# TS_DIR (рабочая папка/каталог базы данных)
# TS_PORT (порт)
# TS_BIND_IP (IP привязки)
# TS_AUTH_ENABLED (0 или 1)
# TS_ACCS_FILE (путь к файлу accs.db)
# TS_INSECURE_ARGS_DETECTED (0 или 1, если пароль передан в ExecStart)
detect_torrserver() {
    TS_INSTALLED=0
    TS_SERVICE_PATH=""
    TS_BIN=""
    TS_DIR="$DEFAULT_INSTALL_DIR"
    TS_PORT="$DEFAULT_PORT"
    TS_BIND_IP="$DEFAULT_BIND_IP"
    TS_AUTH_ENABLED=0
    TS_ACCS_FILE=""
    TS_INSECURE_ARGS_DETECTED=0

    # 1. Поиск unit-файла systemd
    local svc_file=""
    if [[ -f "${DEFAULT_SERVICE_PATH:-}" ]]; then svc_file="${DEFAULT_SERVICE_PATH}"; elif [[ -f "/etc/systemd/system/torrserver.service" ]]; then
        svc_file="/etc/systemd/system/torrserver.service"
    elif [[ -f "/lib/systemd/system/torrserver.service" ]]; then
        svc_file="/lib/systemd/system/torrserver.service"
    elif [[ -f "/usr/lib/systemd/system/torrserver.service" ]]; then
        svc_file="/usr/lib/systemd/system/torrserver.service"
    elif systemctl list-unit-files 2>/dev/null | grep -q '^torrserver\.service'; then
        svc_file="$(systemctl show -p FragmentPath torrserver.service 2>/dev/null | awk -F'=' '{print $2}' || true)"
    fi

    if [[ -n "$svc_file" && -f "$svc_file" ]]; then
        TS_SERVICE_PATH="$svc_file"
        TS_INSTALLED=1

        # Анализ строки ExecStart
        local exec_line=""
        exec_line="$(grep -E '^\s*ExecStart=' "$svc_file" | head -n 1 | sed 's/^\s*ExecStart=//' || true)"

        if [[ -n "$exec_line" ]]; then
            # Извлекаем путь к исполняемому файлу
            local raw_bin
            raw_bin="$(echo "$exec_line" | awk '{print $1}')"
            if [[ -f "$raw_bin" ]]; then
                TS_BIN="$raw_bin"
                TS_DIR="$(dirname "$raw_bin")"
            fi

            # Извлекаем порт (-p или --port)
            if echo "$exec_line" | grep -qE -- '(--port|-p)[ =]'; then
                local parsed_port
                parsed_port="$(echo "$exec_line" | sed -nE 's/.*(--port|-p)[ =]+([0-9]+).*/\2/p')"
                [[ -n "$parsed_port" ]] && TS_PORT="$parsed_port"
            fi

            # Извлекаем IP привязки (--ip)
            if echo "$exec_line" | grep -qE -- '(--ip)[ =]'; then
                local parsed_ip
                parsed_ip="$(echo "$exec_line" | sed -nE 's/.*--ip[ =]+([0-9a-zA-Z\.:]+).*/\1/p')"
                [[ -n "$parsed_ip" ]] && TS_BIND_IP="$parsed_ip"
            fi

            # Извлекаем каталог данных и базы (-d или --path)
            if echo "$exec_line" | grep -qE -- '(-d|--path)[ =]'; then
                local parsed_dir
                parsed_dir="$(echo "$exec_line" | sed -nE 's/.*(-d|--path)[ =]+([^ ]+).*/\2/p')"
                [[ -n "$parsed_dir" ]] && TS_DIR="$parsed_dir"
            fi

            # Проверка флага HTTP Basic Auth (-a или --httpauth)
            if echo "$exec_line" | grep -qE -- '(--httpauth|-a)\b'; then
                TS_AUTH_ENABLED=1
            fi

            # Проверка, не передавался ли пароль небезопасно прямо в аргументах
            if echo "$exec_line" | grep -qiE -- '(--password|--pass|--pwd|-pass)\b'; then
                TS_INSECURE_ARGS_DETECTED=1
            fi
        fi

        # Проверка директивы WorkingDirectory
        local work_dir=""
        work_dir="$(grep -E '^\s*WorkingDirectory=' "$svc_file" | head -n 1 | sed 's/^\s*WorkingDirectory=//' || true)"
        if [[ -n "$work_dir" && -d "$work_dir" && "$TS_DIR" == "$DEFAULT_INSTALL_DIR" ]]; then
            TS_DIR="$work_dir"
        fi
    fi

    # 2. Если бинарник не обнаружен через службу, проверяем файловую систему
    if [[ -z "$TS_BIN" ]]; then
        local candidate=""
        local arch
        arch="$(detect_arch)"
        for candidate in \
            "${DEFAULT_INSTALL_DIR}/TorrServer-linux-${arch}" \
            "${DEFAULT_INSTALL_DIR}/TorrServer" \
            "${DEFAULT_INSTALL_DIR}/torrserver" \
            "/usr/local/bin/TorrServer" \
            "/usr/local/bin/torrserver" \
            "/usr/bin/torrserver"; do
            if [[ -f "$candidate" && -x "$candidate" ]]; then
                TS_BIN="$candidate"
                TS_DIR="$(dirname "$candidate")"
                TS_INSTALLED=1
                break
            fi
        done

        if [[ -z "$TS_BIN" ]] && command -v torrserver >/dev/null 2>&1; then
            TS_BIN="$(command -v torrserver)"
            TS_DIR="$(dirname "$TS_BIN")"
            TS_INSTALLED=1
        fi
    fi

    # 3. Определение расположения файла accs.db
    if [[ -f "${TS_DIR}/accs.db" ]]; then
        TS_ACCS_FILE="${TS_DIR}/accs.db"
    elif [[ -f "${DEFAULT_INSTALL_DIR}/accs.db" ]]; then
        TS_ACCS_FILE="${DEFAULT_INSTALL_DIR}/accs.db"
    else
        TS_ACCS_FILE="${TS_DIR}/accs.db"
    fi
}

# Получение установленной версии TorrServer
get_torrserver_version() {
    detect_torrserver
    if [[ -z "$TS_BIN" || ! -f "$TS_BIN" ]]; then
        echo "Не установлен"
        return
    fi

    local ver_out=""
    ver_out="$("$TS_BIN" -v 2>&1 || true)"
    if [[ -z "$ver_out" ]]; then
        ver_out="$("$TS_BIN" --version 2>&1 || true)"
    fi

    local parsed_ver=""
    parsed_ver="$(echo "$ver_out" | grep -iE '(TorrServer|MatriX|[0-9]+\.[0-9]+)' | head -n 1 | tr -d '\r' || true)"

    if [[ -z "$parsed_ver" ]]; then
        if systemctl is-active --quiet torrserver 2>/dev/null; then
            local api_out=""
            api_out="$(curl -fsS --max-time 2 "http://127.0.0.1:${TS_PORT}/echo" 2>/dev/null || true)"
            if [[ -n "$api_out" ]]; then
                parsed_ver="TorrServer ${api_out}"
            fi
        fi
    fi

    if [[ -n "$parsed_ver" ]]; then
        echo "$parsed_ver"
    else
        echo "Установлен"
    fi
}

# Проверка статуса порта в UFW
check_ufw_port_status() {
    local port="$1"
    if ! command -v ufw >/dev/null 2>&1; then
        echo "ufw_not_installed"
        return
    fi

    if ! ufw status 2>/dev/null | grep -qw "Status: active"; then
        echo "ufw_inactive"
        return
    fi

    if ufw status 2>/dev/null | grep -qE "^${port}(/tcp)?[[:space:]]+ALLOW"; then
        echo "allowed"
    else
        echo "blocked"
    fi
}

# Проверка доступности порта в системе
check_port_free() {
    local port="$1"
    local check_cmd=""

    if command -v ss >/dev/null 2>&1; then
        check_cmd="$(ss -tulpn 2>/dev/null | grep -E ":${port}\b" || true)"
    elif command -v netstat >/dev/null 2>&1; then
        check_cmd="$(netstat -tulpn 2>/dev/null | grep -E ":${port}\b" || true)"
    elif command -v lsof >/dev/null 2>&1; then
        check_cmd="$(lsof -i ":${port}" 2>/dev/null || true)"
    fi

    if [[ -n "$check_cmd" ]]; then
        return 1 # Порт занят
    else
        return 0 # Порт свободен
    fi
}

# Отображение шапки интерфейса модуля
show_header() {
    clear 2>/dev/null || true
    echo -e "${C_GRAY}======================================================================${C_RESET}"
    echo -e "                   ${C_BOLD}${C_BCYAN}VPS MANAGEMENT · MODULE${C_RESET}"
    echo -e "                     ${C_BOLD}${C_BGREEN}TorrServer Manager${C_RESET}"
    echo -e "${C_GRAY}======================================================================${C_RESET}"
    echo
}

# [1] Статус TorrServer
view_status() {
    show_header
    detect_torrserver

    echo -e "${C_BOLD}${C_YELLOW}📊 ТЕКУЩИЙ СТАТУС TORRSERVER${C_RESET}"
    echo

    if [[ "$TS_INSTALLED" -eq 0 || -z "$TS_BIN" ]]; then
        echo -e "  ${C_GRAY}├─${C_RESET} Установка    : ${C_RED}❌ Не обнаружен в системе${C_RESET}"
        echo -e "  ${C_GRAY}└─${C_RESET} Рекомендация : Выберите пункт [10] для первичной установки."
        pause_prompt
        return
    fi

    local s_active s_enabled pid_val uptime_val mem_val
    s_active="${C_RED}⏹️  Остановлен (inactive)${C_RESET}"
    if systemctl is-active --quiet torrserver 2>/dev/null; then
        s_active="${C_GREEN}● Запущен (active/running)${C_RESET}"
    elif systemctl is-failed --quiet torrserver 2>/dev/null; then
        s_active="${C_BRED}❌ Сбой (failed)${C_RESET}"
    fi

    s_enabled="${C_RED}Отключен (disabled)${C_RESET}"
    if systemctl is-enabled --quiet torrserver 2>/dev/null; then
        s_enabled="${C_GREEN}Включен (enabled)${C_RESET}"
    fi

    pid_val="N/A"
    uptime_val="N/A"
    mem_val="N/A"
    if systemctl is-active --quiet torrserver 2>/dev/null; then
        pid_val="$(systemctl show -p MainPID torrserver 2>/dev/null | awk -F'=' '{print $2}' || true)"
        if [[ "$pid_val" == "0" || -z "$pid_val" ]]; then
            pid_val="$(pgrep -f "$(basename "$TS_BIN")" 2>/dev/null | head -n 1 || echo "N/A")"
        fi

        local active_enter
        active_enter="$(systemctl show -p ActiveEnterTimestamp torrserver 2>/dev/null | awk -F'=' '{print $2}' || true)"
        if [[ -n "$active_enter" ]]; then
            uptime_val="$active_enter"
        fi

        if [[ "$pid_val" != "N/A" && -d "/proc/$pid_val" ]]; then
            local rss_kb
            rss_kb="$(awk '/VmRSS/{print $2}' "/proc/$pid_val/status" 2>/dev/null || true)"
            if [[ -n "$rss_kb" ]]; then
                mem_val="$(( rss_kb / 1024 )) MB"
            fi
        fi
    fi

    local ver_str
    ver_str="$(get_torrserver_version)"

    local server_ip
    server_ip="$(get_server_ip)"

    local auth_status="${C_YELLOW}Выключена${C_RESET}"
    local user_list=""
    if [[ "$TS_AUTH_ENABLED" -eq 1 ]]; then
        if [[ -f "$TS_ACCS_FILE" ]]; then
            if command -v jq >/dev/null 2>&1; then
                user_list="$(jq -r 'keys | join(", ")' "$TS_ACCS_FILE" 2>/dev/null || true)"
            else
                user_list="$(grep -oE '"[^"]+"[[:space:]]*:' "$TS_ACCS_FILE" | tr -d '": ' | tr '\n' ',' | sed 's/,$//' || true)"
            fi
        fi
        if [[ -n "$user_list" ]]; then
            auth_status="${C_GREEN}Включена${C_RESET} ${C_GRAY}(пользователи: ${user_list})${C_RESET}"
        else
            auth_status="${C_GREEN}Включена${C_RESET} ${C_GRAY}(accs.db пуст или не настроен)${C_RESET}"
        fi
    fi

    local ufw_status_str
    case "$(check_ufw_port_status "$TS_PORT")" in
        "allowed") ufw_status_str="${C_GREEN}✓ Разрешен${C_RESET}" ;;
        "blocked") ufw_status_str="${C_RED}⚠️ Заблокирован (порт закрыт)${C_RESET}" ;;
        "ufw_inactive") ufw_status_str="${C_GRAY}UFW выключен${C_RESET}" ;;
        *) ufw_status_str="${C_GRAY}UFW не установлен${C_RESET}" ;;
    esac

    echo -e "  ${C_GRAY}├─${C_RESET} Версия        : ${C_BCYAN}${ver_str}${C_RESET}"
    echo -e "  ${C_GRAY}├─${C_RESET} Бинарный файл : ${C_BOLD}${TS_BIN}${C_RESET}"
    echo -e "  ${C_GRAY}├─${C_RESET} Служба        : ${C_BOLD}${TS_SERVICE_PATH:-/etc/systemd/system/torrserver.service}${C_RESET}"
    echo -e "  ${C_GRAY}├─${C_RESET} Состояние     : ${s_active}"
    echo -e "  ${C_GRAY}├─${C_RESET} Автозапуск    : ${s_enabled}"
    echo -e "  ${C_GRAY}├─${C_RESET} PID процесса  : ${C_BOLD}${pid_val}${C_RESET}"
    echo -e "  ${C_GRAY}├─${C_RESET} Время запуска : ${uptime_val}"
    echo -e "  ${C_GRAY}├─${C_RESET} Память (RSS)  : ${mem_val}"
    echo -e "  ${C_GRAY}├─${C_RESET} Сетевой порт  : ${C_BGREEN}${TS_PORT}${C_RESET} (привязка: ${TS_BIND_IP})"
    echo -e "  ${C_GRAY}├─${C_RESET} Авторизация   : ${auth_status}"
    echo -e "  ${C_GRAY}├─${C_RESET} Статус в UFW  : ${ufw_status_str}"
    echo -e "  ${C_GRAY}├─${C_RESET} Внешний адрес : ${C_CYAN}http://${server_ip}:${TS_PORT}/${C_RESET}"
    echo -e "  ${C_GRAY}└─${C_RESET} Локальный URL : ${C_GRAY}http://127.0.0.1:${TS_PORT}/${C_RESET}"

    if [[ "$TS_INSECURE_ARGS_DETECTED" -eq 1 ]]; then
        echo
        echo -e "  ${C_BRED}⚠️  ВНИМАНИЕ ПО БЕЗОПАСНОСТИ:${C_RESET} В ExecStart обнаружена передача пароля через аргументы процесса!"
        echo -e "     Локальные пользователи могут прочесть его через 'ps aux'. Рекомендуется настроить доступ через пункт [5]."
    fi
    echo

    pause_prompt
}

# [2] Запустить службу
start_service() {
    show_header
    detect_torrserver
    echo -e "${C_BOLD}${C_YELLOW}▶️  ЗАПУСК СЛУЖБЫ TORRSERVER${C_RESET}"
    echo

    if [[ "$TS_INSTALLED" -eq 0 || -z "$TS_SERVICE_PATH" ]]; then
        echo -e "${C_RED}❌ Служба torrserver.service не найдена.${C_RESET}"
        echo "Для установки выберите пункт [10]."
        pause_prompt
        return
    fi

    if systemctl is-active --quiet torrserver 2>/dev/null; then
        echo -e "${C_GREEN}✓ Служба уже запущена.${C_RESET}"
        pause_prompt
        return
    fi

    echo ">>> Выполняется: systemctl start torrserver..."
    systemctl start torrserver 2>/dev/null || true

    sleep 1.5

    if systemctl is-active --quiet torrserver 2>/dev/null; then
        echo -e "${C_GREEN}✓ TorrServer успешно запущен!${C_RESET}"
        local s_ip
        s_ip="$(get_server_ip)"
        echo -e "  Веб-интерфейс доступен: ${C_CYAN}http://${s_ip}:${TS_PORT}/${C_RESET}"
    else
        echo -e "${C_RED}❌ Не удалось запустить TorrServer.${C_RESET}"
        echo -e "${C_YELLOW}Журнал сбоя:${C_RESET}"
        journalctl -u torrserver -n 15 --no-pager 2>/dev/null || true
    fi

    pause_prompt
}

# [3] Остановить службу
stop_service() {
    show_header
    detect_torrserver
    echo -e "${C_BOLD}${C_YELLOW}⏹️  ОСТАНОВКА СЛУЖБЫ TORRSERVER${C_RESET}"
    echo

    if [[ "$TS_INSTALLED" -eq 0 || -z "$TS_SERVICE_PATH" ]]; then
        echo -e "${C_RED}❌ Служба torrserver.service не найдена.${C_RESET}"
        pause_prompt
        return
    fi

    if ! systemctl is-active --quiet torrserver 2>/dev/null; then
        echo -e "${C_YELLOW}Служба уже остановлена.${C_RESET}"
        pause_prompt
        return
    fi

    echo ">>> Выполняется: systemctl stop torrserver..."
    systemctl stop torrserver 2>/dev/null || true

    sleep 1

    if ! systemctl is-active --quiet torrserver 2>/dev/null; then
        echo -e "${C_GREEN}✓ TorrServer успешно остановлен.${C_RESET}"
    else
        echo -e "${C_RED}❌ Служба не остановилась.${C_RESET}"
    fi

    pause_prompt
}

# [4] Перезапустить службу
restart_service() {
    show_header
    detect_torrserver
    echo -e "${C_BOLD}${C_YELLOW}🔄 ПЕРЕЗАПУСК СЛУЖБЫ TORRSERVER${C_RESET}"
    echo

    if [[ "$TS_INSTALLED" -eq 0 || -z "$TS_SERVICE_PATH" ]]; then
        echo -e "${C_RED}❌ Служба torrserver.service не найдена.${C_RESET}"
        pause_prompt
        return
    fi

    echo ">>> Выполняется: systemctl restart torrserver..."
    systemctl restart torrserver 2>/dev/null || true

    sleep 1.5

    if systemctl is-active --quiet torrserver 2>/dev/null; then
        echo -e "${C_GREEN}✓ TorrServer успешно перезапущен и работает!${C_RESET}"
    else
        echo -e "${C_RED}❌ Ошибка при перезапуске TorrServer.${C_RESET}"
        echo -e "${C_YELLOW}Журнал сбоя:${C_RESET}"
        journalctl -u torrserver -n 15 --no-pager 2>/dev/null || true
    fi

    pause_prompt
}

# [7] Настроить автозапуск
toggle_autostart() {
    show_header
    detect_torrserver
    echo -e "${C_BOLD}${C_YELLOW}⚙️  НАСТРОЙКА АВТОЗАПУСКА TORRSERVER${C_RESET}"
    echo

    if [[ "$TS_INSTALLED" -eq 0 || -z "$TS_SERVICE_PATH" ]]; then
        echo -e "${C_RED}❌ Служба torrserver.service не найдена.${C_RESET}"
        pause_prompt
        return
    fi

    if systemctl is-enabled --quiet torrserver 2>/dev/null; then
        echo -e "Текущее состояние: ${C_GREEN}ВКЛЮЧЕН (enabled)${C_RESET}"
        echo
        local choice="n"
        read_choice "Отключить автозапуск службы при загрузке VPS? [y/N]: " choice "n"
        if [[ "$choice" =~ ^[YyДд]$ ]]; then
            systemctl disable torrserver 2>/dev/null || true
            echo -e "${C_GREEN}✓ Автозапуск отключен (disabled).${C_RESET}"
        else
            echo "Изменения отменены."
        fi
    else
        echo -e "Текущее состояние: ${C_RED}ОТКЛЮЧЕН (disabled)${C_RESET}"
        echo
        local choice="y"
        read_choice "Включить автозапуск службы при загрузке VPS? [Y/n]: " choice "y"
        if [[ "$choice" =~ ^[YyДд]$ || -z "$choice" ]]; then
            systemctl enable torrserver 2>/dev/null || true
            echo -e "${C_GREEN}✓ Автозапуск включен (enabled).${C_RESET}"
        else
            echo "Изменения отменены."
        fi
    fi

    pause_prompt
}

# Безопасное обновление unit-файла systemd с резервным копированием
update_systemd_unit() {
    local bin_path="$1"
    local port="$2"
    local bind_ip="$3"
    local data_dir="$4"
    local enable_auth="$5"

    local target_unit="${TS_SERVICE_PATH:-$DEFAULT_SERVICE_PATH}"
    mkdir -p "$(dirname "$target_unit")"
    mkdir -p "$BACKUP_DIR"

    # Резервная копия существующего unit-файла перед изменением
    if [[ -f "$target_unit" ]]; then
        local ts_stamp
        ts_stamp="$(date +%Y%m%d_%H%M%S)"
        cp -a "$target_unit" "${BACKUP_DIR}/torrserver.service.bak_${ts_stamp}"
        cp -a "$target_unit" "${target_unit}.bak"
    fi

    # Формирование аргументов запуска
    # Пароли НЕ передаются через аргументы процесса (защита от ps aux / proc inspection)
    # TorrServer читает учетные данные из файла accs.db в директории данных (-d)
    local cmd_args="--port ${port}"
    if [[ "$bind_ip" != "0.0.0.0" && -n "$bind_ip" ]]; then
        cmd_args="${cmd_args} --ip ${bind_ip}"
    fi
    if [[ "$enable_auth" -eq 1 ]]; then
        cmd_args="${cmd_args} --httpauth"
    fi
    cmd_args="${cmd_args} -d ${data_dir}"

    cat > "$target_unit" <<EOF_UNIT
[Unit]
Description=TorrServer - Torrent Stream Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=${data_dir}
ExecStart=${bin_path} ${cmd_args}
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF_UNIT

    chmod 644 "$target_unit"
    systemctl daemon-reload 2>/dev/null || true
    TS_SERVICE_PATH="$target_unit"
}

# [5] Настройки доступа (логин / пароль HTTP Basic Auth)
manage_auth() {
    while true; do
        show_header
        detect_torrserver

        echo -e "${C_BOLD}${C_YELLOW}🔐 НАСТРОЙКИ АВТОРИЗАЦИИ (HTTP BASIC AUTH)${C_RESET}"
        echo

        if [[ "$TS_INSTALLED" -eq 0 || -z "$TS_BIN" ]]; then
            echo -e "${C_RED}❌ TorrServer не установлен.${C_RESET}"
            pause_prompt
            return
        fi

        mkdir -p "$TS_DIR"
        chmod 700 "$TS_DIR" 2>/dev/null || true

        local auth_mode="${C_RED}Выключена${C_RESET}"
        [[ "$TS_AUTH_ENABLED" -eq 1 ]] && auth_mode="${C_GREEN}Включена (--httpauth)${C_RESET}"

        echo -e "  ${C_GRAY}├─${C_RESET} Режим HTTP Auth     : ${auth_mode}"
        echo -e "  ${C_GRAY}├─${C_RESET} Файл учетных записей: ${TS_ACCS_FILE}"

        local accounts_display="отсутствуют"
        if [[ -f "$TS_ACCS_FILE" ]]; then
            if command -v jq >/dev/null 2>&1; then
                accounts_display="$(jq -r 'keys | join(", ")' "$TS_ACCS_FILE" 2>/dev/null || echo "ошибка чтения")"
            else
                accounts_display="$(grep -oE '"[^"]+"[[:space:]]*:' "$TS_ACCS_FILE" | tr -d '": ' | tr '\n' ', ' || echo "N/A")"
            fi
            [[ -z "$accounts_display" ]] && accounts_display="файл пуст"
        fi
        echo -e "  ${C_GRAY}└─${C_RESET} Пользователи в базе : ${C_BOLD}${accounts_display}${C_RESET}"
        echo
        echo -e "  ${C_BGREEN}[1]${C_RESET} 👤 Настроить пользователя (создать / сменить пароль)"
        echo -e "  ${C_BGREEN}[2]${C_RESET} ➕ Добавить дополнительного пользователя"
        echo -e "  ${C_BGREEN}[3]${C_RESET} 🗑️  Удалить пользователя из accs.db"
        echo -e "  ${C_BGREEN}[4]${C_RESET} 🔓 Полностью отключить авторизацию"
        echo -e "  ${C_BGREEN}[5]${C_RESET} 🛡️  Проверить и исправить права доступа (chmod 600)"
        echo -e "  ${C_RED}[0]${C_RESET} ↩️  Назад в главное меню"
        echo

        local a_choice="0"
        read_choice "${C_BOLD}Выберите действие [0-5]: ${C_RESET}" a_choice "0"
        echo

        case "$a_choice" in
            1)
                echo -e "${C_BOLD}${C_CYAN}--- Настройка учетных данных ---${C_RESET}"
                local username=""
                read_choice "Введите имя пользователя [admin]: " username "admin"
                if [[ -z "$username" ]]; then username="admin"; fi

                local pass1="" pass2=""
                read_password_secret "Введите пароль (ввод скрыт): " pass1
                if [[ -z "$pass1" ]]; then
                    echo -e "${C_RED}❌ Пароль не может быть пустым.${C_RESET}"
                    pause_prompt
                    continue
                fi

                read_password_secret "Повторите пароль: " pass2
                if [[ "$pass1" != "$pass2" ]]; then
                    echo -e "${C_RED}❌ Введенные пароли не совпадают!${C_RESET}"
                    pause_prompt
                    continue
                fi

                # Атомарная и безопасная запись с маской 077
                local tmp_accs="${TS_DIR}/accs.db.tmp.$$"
                (
                    umask 077
                    if command -v jq >/dev/null 2>&1; then
                        jq -n --arg u "$username" --arg p "$pass1" '{($u): $p}' > "$tmp_accs"
                    else
                        python3 -c "import json, sys; json.dump({sys.argv[1]: sys.argv[2]}, open(sys.argv[3], 'w'), indent=2)" "$username" "$pass1" "$tmp_accs"
                    fi
                )

                mv -f "$tmp_accs" "$TS_ACCS_FILE"
                chmod 600 "$TS_ACCS_FILE"
                chown root:root "$TS_ACCS_FILE" 2>/dev/null || true

                # Обновление службы с флагом --httpauth
                update_systemd_unit "$TS_BIN" "$TS_PORT" "$TS_BIND_IP" "$TS_DIR" 1

                echo -e "${C_GREEN}✓ Учетные данные пользователя '${username}' сохранены в accs.db (права 600).${C_RESET}"
                echo ">>> Перезапуск службы TorrServer для применения настроек..."
                systemctl restart torrserver 2>/dev/null || true

                if systemctl is-active --quiet torrserver 2>/dev/null; then
                    echo -e "${C_GREEN}✓ TorrServer успешно защищен HTTP Basic Auth!${C_RESET}"
                else
                    echo -e "${C_RED}⚠️ Служба не запустилась с новыми настройками.${C_RESET}"
                fi
                pause_prompt
                ;;
            2)
                echo -e "${C_BOLD}${C_CYAN}--- Добавление пользователя ---${C_RESET}"
                local new_user=""
                read_choice "Введите имя нового пользователя: " new_user ""
                if [[ -z "$new_user" ]]; then
                    echo -e "${C_RED}❌ Имя пользователя обязательно.${C_RESET}"
                    pause_prompt
                    continue
                fi

                local new_pass1="" new_pass2=""
                read_password_secret "Введите пароль (ввод скрыт): " new_pass1
                if [[ -z "$new_pass1" ]]; then
                    echo -e "${C_RED}❌ Пароль не может быть пустым.${C_RESET}"
                    pause_prompt
                    continue
                fi

                read_password_secret "Повторите пароль: " new_pass2
                if [[ "$new_pass1" != "$new_pass2" ]]; then
                    echo -e "${C_RED}❌ Пароли не совпадают!${C_RESET}"
                    pause_prompt
                    continue
                fi

                local tmp_accs="${TS_DIR}/accs.db.tmp.$$"
                (
                    umask 077
                    if [[ ! -f "$TS_ACCS_FILE" ]]; then
                        echo "{}" > "$TS_ACCS_FILE"
                    fi
                    if command -v jq >/dev/null 2>&1; then
                        jq --arg u "$new_user" --arg p "$new_pass1" '.[$u] = $p' "$TS_ACCS_FILE" > "$tmp_accs"
                    else
                        python3 -c "import json, sys; d = json.load(open(sys.argv[3])) if open(sys.argv[3]).read().strip() else {}; d[sys.argv[1]] = sys.argv[2]; json.dump(d, open(sys.argv[4], 'w'), indent=2)" "$new_user" "$new_pass1" "$TS_ACCS_FILE" "$tmp_accs"
                    fi
                )

                mv -f "$tmp_accs" "$TS_ACCS_FILE"
                chmod 600 "$TS_ACCS_FILE"
                chown root:root "$TS_ACCS_FILE" 2>/dev/null || true

                if [[ "$TS_AUTH_ENABLED" -eq 0 ]]; then
                    update_systemd_unit "$TS_BIN" "$TS_PORT" "$TS_BIND_IP" "$TS_DIR" 1
                fi

                echo -e "${C_GREEN}✓ Пользователь '${new_user}' добавлен в accs.db.${C_RESET}"
                echo ">>> Перезапуск службы TorrServer..."
                systemctl restart torrserver 2>/dev/null || true
                pause_prompt
                ;;
            3)
                echo -e "${C_BOLD}${C_CYAN}--- Удаление пользователя ---${C_RESET}"
                if [[ ! -f "$TS_ACCS_FILE" ]]; then
                    echo -e "${C_YELLOW}Файл accs.db отсутствует.${C_RESET}"
                    pause_prompt
                    continue
                fi

                local del_user=""
                read_choice "Введите имя пользователя для удаления: " del_user ""
                if [[ -z "$del_user" ]]; then
                    echo "Отмена."
                    pause_prompt
                    continue
                fi

                local tmp_accs="${TS_DIR}/accs.db.tmp.$$"
                (
                    umask 077
                    if command -v jq >/dev/null 2>&1; then
                        jq --arg u "$del_user" 'del(.[$u])' "$TS_ACCS_FILE" > "$tmp_accs"
                    else
                        python3 -c "import json, sys; d = json.load(open(sys.argv[2])); d.pop(sys.argv[1], None); json.dump(d, open(sys.argv[3], 'w'), indent=2)" "$del_user" "$TS_ACCS_FILE" "$tmp_accs"
                    fi
                )

                mv -f "$tmp_accs" "$TS_ACCS_FILE"
                chmod 600 "$TS_ACCS_FILE"
                chown root:root "$TS_ACCS_FILE" 2>/dev/null || true

                echo -e "${C_GREEN}✓ Пользователь '${del_user}' удален.${C_RESET}"
                systemctl restart torrserver 2>/dev/null || true
                pause_prompt
                ;;
            4)
                echo -e "${C_BOLD}${C_CYAN}--- Отключение авторизации ---${C_RESET}"
                local conf_disable="n"
                read_choice "Вы уверены, что хотите отключить авторизацию? Веб-интерфейс станет общедоступным! [y/N]: " conf_disable "n"
                if [[ "$conf_disable" =~ ^[YyДд]$ ]]; then
                    if [[ -f "$TS_ACCS_FILE" ]]; then
                        cp -a "$TS_ACCS_FILE" "${TS_ACCS_FILE}.disabled_bak"
                    fi
                    update_systemd_unit "$TS_BIN" "$TS_PORT" "$TS_BIND_IP" "$TS_DIR" 0
                    echo ">>> Перезапуск TorrServer без авторизации..."
                    systemctl restart torrserver 2>/dev/null || true
                    echo -e "${C_GREEN}✓ Авторизация отключена.${C_RESET}"
                else
                    echo "Отмена."
                fi
                pause_prompt
                ;;
            5)
                echo -e "${C_BOLD}${C_CYAN}--- Защита прав доступа конфигурации ---${C_RESET}"
                mkdir -p "$TS_DIR"
                chmod 700 "$TS_DIR"
                if [[ -f "$TS_ACCS_FILE" ]]; then
                    chmod 600 "$TS_ACCS_FILE"
                    chown root:root "$TS_ACCS_FILE"
                    echo -e "  ${C_GREEN}✓ accs.db защищен: права 600 (-rw-------), владелец root:root.${C_RESET}"
                else
                    echo -e "  ${C_GRAY}Файл accs.db не существует.${C_RESET}"
                fi
                echo -e "  ${C_GREEN}✓ Каталог данных ${TS_DIR} защищен: права 700 (drwx------).${C_RESET}"
                pause_prompt
                ;;
            0)
                break
                ;;
            *)
                echo -e "${C_RED}Некорректный выбор.${C_RESET}"
                sleep 1
                ;;
        esac
    done
}

# [6] Сменить порт и сетевой адрес
change_port_and_ip() {
    show_header
    detect_torrserver
    echo -e "${C_BOLD}${C_YELLOW}🌐 СЕТЕВЫЕ НАСТРОЙКИ (ПОРТ И ПРИВЯЗКА ИНТЕРФЕЙСА)${C_RESET}"
    echo

    if [[ "$TS_INSTALLED" -eq 0 || -z "$TS_BIN" ]]; then
        echo -e "${C_RED}❌ TorrServer не установлен.${C_RESET}"
        pause_prompt
        return
    fi

    echo -e "  Текущий порт : ${C_BGREEN}${TS_PORT}${C_RESET}"
    echo -e "  Текущий IP   : ${C_BOLD}${TS_BIND_IP}${C_RESET} (0.0.0.0 = все интерфейсы, 127.0.0.1 = только localhost)"
    echo

    local new_port=""
    read_choice "Введите новый порт [нажмите Enter для сохранения ${TS_PORT}]: " new_port "$TS_PORT"

    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [[ "$new_port" -lt 1 || "$new_port" -gt 65535 ]]; then
        echo -e "${C_RED}❌ Некорректный номер порта: ${new_port}. Допустимый диапазон: 1-65535.${C_RESET}"
        pause_prompt
        return
    fi

    # Проверка, свободен ли новый порт
    if [[ "$new_port" != "$TS_PORT" ]]; then
        if ! check_port_free "$new_port"; then
            echo -e "${C_RED}❌ Порт ${new_port} уже занят другим процессом!${C_RESET}"
            if command -v ss >/dev/null 2>&1; then
                ss -tulpn | grep -E ":${new_port}\b" || true
            fi
            echo "Пожалуйста, освободите порт или выберите другой."
            pause_prompt
            return
        fi
    fi

    echo
    echo "Выберите адрес прослушивания (Bind IP):"
    echo "  [1] 0.0.0.0   - Все сетевые интерфейсы (прямой доступ из интернета)"
    echo "  [2] 127.0.0.1 - Только локальный доступ (рекомендуется при работе через Nginx)"
    local ip_choice="1"
    read_choice "Выберите вариант [1-2] (Enter = ${TS_BIND_IP}): " ip_choice ""

    local new_bind_ip="$TS_BIND_IP"
    if [[ "$ip_choice" == "1" ]]; then
        new_bind_ip="0.0.0.0"
    elif [[ "$ip_choice" == "2" ]]; then
        new_bind_ip="127.0.0.1"
    fi

    local old_port="$TS_PORT"

    echo
    echo ">>> Сохранение резервной копии конфигурации и обновление unit-файла..."
    update_systemd_unit "$TS_BIN" "$new_port" "$new_bind_ip" "$TS_DIR" "$TS_AUTH_ENABLED"

    echo ">>> Перезапуск службы TorrServer на порту ${new_port}..."
    systemctl restart torrserver 2>/dev/null || true
    sleep 2

    # Проверка жизнеспособности после смены настроек
    if ! systemctl is-active --quiet torrserver 2>/dev/null; then
        echo -e "${C_RED}❌ Ошибка: служба не запустилась на новом порту! Выполняется откат...${C_RESET}"
        if [[ -f "${TS_SERVICE_PATH}.bak" ]]; then
            cp -a "${TS_SERVICE_PATH}.bak" "$TS_SERVICE_PATH"
            systemctl daemon-reload 2>/dev/null || true
            systemctl restart torrserver 2>/dev/null || true
            echo -e "${C_YELLOW}Конфигурация возвращена на исходный порт ${old_port}.${C_RESET}"
        fi
        pause_prompt
        return
    fi

    echo -e "${C_GREEN}✓ TorrServer успешно переведен на порт ${new_port} (${new_bind_ip})!${C_RESET}"

    # Проверка и взаимодействие с UFW (без автоматических скрытых изменений)
    if [[ "$new_bind_ip" != "127.0.0.1" && "$new_port" != "$old_port" ]]; then
        echo
        echo -e "${C_BOLD}${C_YELLOW}🛡️  Проверка фаервола UFW:${C_RESET}"
        local ufw_status
        ufw_status="$(check_ufw_port_status "$new_port")"

        if [[ "$ufw_status" == "blocked" ]]; then
            echo -e "${C_YELLOW}⚠️  ВНИМАНИЕ: Порт ${new_port}/tcp не открыт в UFW!${C_RESET}"
            echo -e "   Внешний доступ к серверу будет заблокирован фаерволом."
            echo -e "   Команда для ручного открытия: ${C_CYAN}ufw allow ${new_port}/tcp comment 'TorrServer'${C_RESET}"
            echo
            local ufw_ask="y"
            read_choice "Открыть порт ${new_port}/tcp в UFW сейчас? [Y/n]: " ufw_ask "y"
            if [[ "$ufw_ask" =~ ^[YyДд]$ || -z "$ufw_ask" ]]; then
                ufw allow "${new_port}/tcp" comment 'TorrServer' >/dev/null 2>&1 || true
                echo -e "${C_GREEN}✓ Порт ${new_port}/tcp успешно открыт в UFW.${C_RESET}"

                # Проверка старого правила
                if [[ "$(check_ufw_port_status "$old_port")" == "allowed" ]]; then
                    local del_old="n"
                    read_choice "Удалить старое правило UFW для порта ${old_port}/tcp? [y/N]: " del_old "n"
                    if [[ "$del_old" =~ ^[YyДд]$ ]]; then
                        ufw delete allow "${old_port}/tcp" >/dev/null 2>&1 || true
                        echo -e "${C_GREEN}✓ Старое правило для порта ${old_port}/tcp удалено.${C_RESET}"
                    fi
                fi
            else
                echo -e "${C_GRAY}Правила UFW не изменены.${C_RESET}"
            fi
        elif [[ "$ufw_status" == "allowed" ]]; then
            echo -e "${C_GREEN}✓ Порт ${new_port}/tcp уже открыт в UFW.${C_RESET}"
        fi
    fi

    pause_prompt
}

# [8] Просмотр логов службы
view_logs() {
    show_header
    echo -e "${C_BOLD}${C_YELLOW}📜 ЖУРНАЛ СЛУЖБЫ TORRSERVER (JOURNALCTL)${C_RESET}"
    echo
    echo "  [1] Последние 50 строк"
    echo "  [2] Последние 150 строк"
    echo "  [3] Непрерывный мониторинг в реальном времени (Ctrl+C для выхода)"
    echo "  [0] Назад"
    echo

    local l_choice="1"
    read_choice "Выберите режим [0-3]: " l_choice "1"
    echo

    case "$l_choice" in
        1)
            journalctl -u torrserver -n 50 --no-pager 2>/dev/null || echo "Логи отсутствуют."
            pause_prompt
            ;;
        2)
            journalctl -u torrserver -n 150 --no-pager 2>/dev/null || echo "Логи отсутствуют."
            pause_prompt
            ;;
        3)
            echo -e "${C_GRAY}Для выхода нажмите Ctrl+C...${C_RESET}"
            sleep 1
            journalctl -u torrserver -f 2>/dev/null || true
            ;;
        0)
            return
            ;;
        *)
            echo "Некорректный выбор."
            sleep 1
            ;;
    esac
}

# [9] Проверка доступности и диагностика
diagnose_server() {
    show_header
    detect_torrserver

    echo -e "${C_BOLD}${C_YELLOW}🔍 ДИАГНОСТИКА И ПРОВЕРКА ДОСТУПНОСТИ TORRSERVER${C_RESET}"
    echo

    # 1. Бинарный файл
    echo -ne "  [1] Исполняемый файл     : "
    if [[ -n "$TS_BIN" && -f "$TS_BIN" ]]; then
        if [[ -x "$TS_BIN" ]]; then
            echo -e "${C_GREEN}✓ Обнаружен (${TS_BIN})${C_RESET}"
        else
            echo -e "${C_YELLOW}⚠️ Найден, но нет прав на запуск (+x). Исправляю...${C_RESET}"
            chmod +x "$TS_BIN" 2>/dev/null || true
        fi
    else
        echo -e "${C_RED}❌ Не найден${C_RESET}"
    fi

    # 2. Unit-файл службы
    echo -ne "  [2] Unit-файл systemd    : "
    if [[ -n "$TS_SERVICE_PATH" && -f "$TS_SERVICE_PATH" ]]; then
        echo -e "${C_GREEN}✓ ${TS_SERVICE_PATH}${C_RESET}"
    else
        echo -e "${C_RED}❌ Отсутствует${C_RESET}"
    fi

    # 3. Состояние процесса
    echo -ne "  [3] Статус процесса      : "
    if systemctl is-active --quiet torrserver 2>/dev/null; then
        local pid_val
        pid_val="$(systemctl show -p MainPID torrserver 2>/dev/null | awk -F'=' '{print $2}' || true)"
        echo -e "${C_GREEN}✓ Запущен (PID: ${pid_val})${C_RESET}"
    else
        echo -e "${C_RED}⏹️  Не активен${C_RESET}"
    fi

    # 4. Прослушивание порта
    echo -ne "  [4] Сокет порта ${TS_PORT}        : "
    local sock_check=""
    if command -v ss >/dev/null 2>&1; then
        sock_check="$(ss -tulpn 2>/dev/null | grep -E ":${TS_PORT}\b" || true)"
    fi
    if [[ -n "$sock_check" ]]; then
        echo -e "${C_GREEN}✓ Слушается (${TS_BIND_IP}:${TS_PORT})${C_RESET}"
    else
        echo -e "${C_RED}❌ Порт не слушается${C_RESET}"
    fi

    # 5. Локальный HTTP запрос
    echo -ne "  [5] HTTP-интерфейс       : "
    local http_code=""
    http_code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:${TS_PORT}/echo" 2>/dev/null || echo "000")"
    if [[ "$http_code" == "200" ]]; then
        echo -e "${C_GREEN}✓ Доступен (HTTP 200 OK)${C_RESET}"
    elif [[ "$http_code" == "401" ]]; then
        echo -e "${C_GREEN}✓ Доступен и защищен (HTTP 401 — Basic Auth активен)${C_RESET}"
    elif [[ "$http_code" == "000" ]]; then
        http_code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:${TS_PORT}/" 2>/dev/null || echo "000")"
        if [[ "$http_code" == "200" || "$http_code" == "302" ]]; then
            echo -e "${C_GREEN}✓ Доступен (HTTP ${http_code})${C_RESET}"
        elif [[ "$http_code" == "401" ]]; then
            echo -e "${C_GREEN}✓ Доступен и защищен (HTTP 401)${C_RESET}"
        else
            echo -e "${C_RED}❌ Нет ответа HTTP (Код: ${http_code})${C_RESET}"
        fi
    else
        echo -e "${C_YELLOW}Ответ сервера: HTTP ${http_code}${C_RESET}"
    fi

    # 6. Права доступа к конфигурации
    echo -ne "  [6] Защита конфигурации  : "
    if [[ -f "$TS_ACCS_FILE" ]]; then
        local perms
        perms="$(stat -c "%a" "$TS_ACCS_FILE" 2>/dev/null || stat -f "%Lp" "$TS_ACCS_FILE" 2>/dev/null || echo "???")"
        if [[ "$perms" == "600" || "$perms" == "400" ]]; then
            echo -e "${C_GREEN}✓ Безопасно (accs.db права: ${perms})${C_RESET}"
        else
            echo -e "${C_YELLOW}⚠️ Права ${perms}. Исправлено на 600.${C_RESET}"
            chmod 600 "$TS_ACCS_FILE" 2>/dev/null || true
        fi
    else
        echo -e "${C_GRAY}Файл accs.db отсутствует (авторизация не включена)${C_RESET}"
    fi

    # 7. UFW фаервол
    echo -ne "  [7] Фаервол UFW          : "
    case "$(check_ufw_port_status "$TS_PORT")" in
        "allowed") echo -e "${C_GREEN}✓ Порт ${TS_PORT}/tcp разрешен${C_RESET}" ;;
        "blocked") echo -e "${C_RED}⚠️ Порт ${TS_PORT}/tcp закрыт в UFW! Внешний доступ ограничен${C_RESET}" ;;
        "ufw_inactive") echo -e "${C_GRAY}UFW выключен${C_RESET}" ;;
        *) echo -e "${C_GRAY}UFW не используется${C_RESET}" ;;
    esac

    # 8. Свободное место на диске
    echo -ne "  [8] Дисковое пространство: "
    local disk_avail
    disk_avail="$(df -h "$TS_DIR" 2>/dev/null | awk 'NR==2{print $4}' || echo "N/A")"
    echo -e "${C_BOLD}${disk_avail} свободно${C_RESET}"

    echo
    pause_prompt
}

# [10] Обновить TorrServer
update_torrserver() {
    show_header
    detect_torrserver

    echo -e "${C_BOLD}${C_YELLOW}🚀 ОБНОВЛЕНИЕ / УСТАНОВКА БИНАРНОГО ФАЙЛА TORRSERVER${C_RESET}"
    echo

    local arch
    arch="$(detect_arch)"
    if [[ "$arch" == "unknown" ]]; then
        echo -e "${C_RED}❌ Не удалось определить архитектуру процессора ($(uname -m)).${C_RESET}"
        pause_prompt
        return
    fi

    local current_ver
    current_ver="$(get_torrserver_version)"
    echo -e "  Текущая версия    : ${C_BCYAN}${current_ver}${C_RESET}"
    echo -e "  Архитектура       : ${C_BOLD}${arch}${C_RESET}"
    echo

    local target_bin="${TS_BIN:-${DEFAULT_INSTALL_DIR}/TorrServer-linux-${arch}}"
    local target_dir="${TS_DIR:-$DEFAULT_INSTALL_DIR}"
    mkdir -p "$target_dir"
    mkdir -p "$BACKUP_DIR"

    local dl_url="https://github.com/${GITHUB_REPO}/releases/latest/download/TorrServer-linux-${arch}"
    echo -e "  Источник загрузки : ${C_GRAY}${dl_url}${C_RESET}"
    echo

    local conf_up="y"
    read_choice "Загрузить и применить обновление? [Y/n]: " conf_up "y"
    if ! [[ "$conf_up" =~ ^[YyДд]$ || -z "$conf_up" ]]; then
        echo "Отмена."
        pause_prompt
        return
    fi

    local tmp_file="/tmp/TorrServer-new.$$"
    rm -f "$tmp_file"

    echo ">>> Скачивание бинарного файла с GitHub..."
    if ! curl -4 -fL --retry 3 --connect-timeout 15 --max-time 300 "$dl_url" -o "$tmp_file"; then
        echo -e "${C_RED}❌ Ошибка загрузки с GitHub.${C_RESET}"
        rm -f "$tmp_file"
        pause_prompt
        return
    fi

    # Проверка скачанного файла на непустоту
    if [[ ! -s "$tmp_file" ]]; then
        echo -e "${C_RED}❌ Загруженный файл пуст.${C_RESET}"
        rm -f "$tmp_file"
        pause_prompt
        return
    fi

    # Проверка ELF заголовка исполняемого файла
    local file_magic
    file_magic="$(head -c 4 "$tmp_file" 2>/dev/null || true)"
    if [[ "$file_magic" != $'\x7fELF' ]]; then
        echo -e "${C_RED}❌ Загруженный файл не является исполняемым бинарником Linux ELF!${C_RESET}"
        rm -f "$tmp_file"
        pause_prompt
        return
    fi

    chmod +x "$tmp_file"

    # Тестовый запуск во временной директории перед подменой
    local test_run=""
    test_run="$("$tmp_file" -v 2>&1 || true)"
    if [[ -z "$test_run" ]]; then
        test_run="$("$tmp_file" -h 2>&1 || true)"
    fi

    if [[ -z "$test_run" ]] && ! "$tmp_file" -v >/dev/null 2>&1; then
        echo -e "${C_RED}❌ Тестовый запуск нового бинарника завершился с ошибкой.${C_RESET}"
        rm -f "$tmp_file"
        pause_prompt
        return
    fi

    # Резервная копия текущего рабочего бинарника
    local ts_stamp
    ts_stamp="$(date +%Y%m%d_%H%M%S)"
    local old_backup=""
    if [[ -f "$target_bin" ]]; then
        old_backup="${BACKUP_DIR}/$(basename "$target_bin").bak_${ts_stamp}"
        echo ">>> Создание резервной копии старого бинарника: ${old_backup}"
        cp -a "$target_bin" "$old_backup"
    fi

    echo ">>> Остановка службы перед заменой..."
    systemctl stop torrserver 2>/dev/null || true

    echo ">>> Атомарная замена бинарного файла..."
    mv -f "$tmp_file" "$target_bin"
    chmod 755 "$target_bin"
    chown root:root "$target_bin" 2>/dev/null || true

    # Если unit-файла не было, создаем
    if [[ "$TS_INSTALLED" -eq 0 || -z "$TS_SERVICE_PATH" || ! -f "$TS_SERVICE_PATH" ]]; then
        echo ">>> Развертывание службы torrserver.service..."
        update_systemd_unit "$target_bin" "$DEFAULT_PORT" "$DEFAULT_BIND_IP" "$target_dir" 0
        systemctl enable torrserver 2>/dev/null || true
    fi

    echo ">>> Запуск службы..."
    systemctl restart torrserver 2>/dev/null || true
    sleep 2

    # Проверка запуска с автоматическим откатом при сбое
    if systemctl is-active --quiet torrserver 2>/dev/null; then
        local new_ver
        new_ver="$(get_torrserver_version)"
        echo -e "${C_GREEN}✓ TorrServer успешно обновлен до: ${new_ver}!${C_RESET}"
    else
        echo -e "${C_BRED}❌ ВНИМАНИЕ: Служба TorrServer не запустилась после обновления!${C_RESET}"
        if [[ -n "$old_backup" && -f "$old_backup" ]]; then
            echo -e "${C_YELLOW}>>> Выполняется автоматический откат к предыдущей рабочей версии...${C_RESET}"
            cp -a "$old_backup" "$target_bin"
            chmod 755 "$target_bin"
            systemctl restart torrserver 2>/dev/null || true
            sleep 1.5
            if systemctl is-active --quiet torrserver 2>/dev/null; then
                echo -e "${C_GREEN}✓ Предыдущая рабочая версия успешно восстановлена.${C_RESET}"
            else
                echo -e "${C_RED}❌ Ошибка автоотката. Проверьте журналы логов.${C_RESET}"
            fi
        fi
        echo -e "${C_YELLOW}Журнал сбоя:${C_RESET}"
        journalctl -u torrserver -n 15 --no-pager 2>/dev/null || true
    fi

    pause_prompt
}

# [11] Резервная копия / восстановление
backup_restore_menu() {
    while true; do
        show_header
        detect_torrserver

        echo -e "${C_BOLD}${C_YELLOW}💾 РЕЗЕРВНОЕ КОПИРОВАНИЕ И ВОССТАНОВЛЕНИЕ${C_RESET}"
        echo
        echo "  [1] 📦 Создать полную резервную копию сейчас"
        echo "  [2] 📋 Список существующих резервных копий"
        echo "  [3] ⏪ Восстановить из резервной копии"
        echo "  [4] 🧹 Удалить старые резервные копии"
        echo "  [0] ↩️  Назад в главное меню"
        echo

        local b_choice="0"
        read_choice "Выберите действие [0-4]: " b_choice "0"
        echo

        mkdir -p "$BACKUP_DIR"

        case "$b_choice" in
            1)
                local b_stamp
                b_stamp="$(date +%Y%m%d_%H%M%S)"
                local arc_name="${BACKUP_DIR}/torrserver_full_backup_${b_stamp}.tar.gz"

                echo ">>> Формирование полного архива конфигурации..."
                local items_to_backup=()
                [[ -n "$TS_BIN" && -f "$TS_BIN" ]] && items_to_backup+=("$TS_BIN")
                [[ -f "${TS_SERVICE_PATH:-}" ]] && items_to_backup+=("${TS_SERVICE_PATH}")
                [[ -f "${TS_DIR}/accs.db" ]] && items_to_backup+=("${TS_DIR}/accs.db")
                [[ -f "${TS_DIR}/torrents.db" ]] && items_to_backup+=("${TS_DIR}/torrents.db")
                [[ -f "${TS_DIR}/settings.json" ]] && items_to_backup+=("${TS_DIR}/settings.json")

                if [[ ${#items_to_backup[@]} -eq 0 ]]; then
                    echo -e "${C_YELLOW}Не найдены файлы для создания резервной копии.${C_RESET}"
                else
                    tar -czf "$arc_name" "${items_to_backup[@]}" 2>/dev/null || true
                    chmod 600 "$arc_name"
                    local b_size
                    b_size="$(du -h "$arc_name" | awk '{print $1}')"
                    echo -e "${C_GREEN}✓ Резервная копия создана: ${arc_name} (${b_size})${C_RESET}"
                fi
                pause_prompt
                ;;
            2)
                echo -e "${C_BOLD}${C_CYAN}Список резервных копий в ${BACKUP_DIR}:${C_RESET}"
                echo
                local files
                files="$(find "$BACKUP_DIR" -maxdepth 1 -type f 2>/dev/null | sort -r || true)"
                if [[ -z "$files" ]]; then
                    echo "  Резервные копии отсутствуют."
                else
                    local f
                    for f in $files; do
                        local f_sz
                        f_sz="$(du -h "$f" | awk '{print $1}')"
                        local f_date
                        f_date="$(date -r "$f" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "N/A")"
                        echo -e "  • ${C_BOLD}$(basename "$f")${C_RESET} [${f_sz}, ${f_date}]"
                    done
                fi
                pause_prompt
                ;;
            3)
                echo -e "${C_BOLD}${C_CYAN}Восстановление из архива:${C_RESET}"
                local tar_files=()
                while IFS= read -r line; do
                    [[ -n "$line" ]] && tar_files+=("$line")
                done < <(find "$BACKUP_DIR" -maxdepth 1 -name "*.tar.gz" -type f 2>/dev/null | sort -r)

                if [[ ${#tar_files[@]} -eq 0 ]]; then
                    echo -e "${C_YELLOW}Нет полных архивов *.tar.gz для восстановления.${C_RESET}"
                    pause_prompt
                    continue
                fi

                local idx=1
                for tf in "${tar_files[@]}"; do
                    echo "  [$idx] $(basename "$tf") ($(du -h "$tf" | awk '{print $1}'))"
                    ((idx++))
                done
                echo "  [0] Отмена"
                echo

                local pick="0"
                read_choice "Выберите номер архива [1-${#tar_files[@]}]: " pick "0"
                if ! [[ "$pick" =~ ^[0-9]+$ ]] || [[ "$pick" -lt 1 || "$pick" -gt ${#tar_files[@]} ]]; then
                    echo "Отмена."
                    pause_prompt
                    continue
                fi

                local selected_archive="${tar_files[$((pick - 1))]}"
                echo ">>> Восстановление из $(basename "$selected_archive")..."
                systemctl stop torrserver 2>/dev/null || true

                tar -xzf "$selected_archive" -C / 2>/dev/null || true

                systemctl daemon-reload 2>/dev/null || true
                systemctl restart torrserver 2>/dev/null || true
                sleep 1.5

                if systemctl is-active --quiet torrserver 2>/dev/null; then
                    echo -e "${C_GREEN}✓ Успешно восстановлено! TorrServer активен.${C_RESET}"
                else
                    echo -e "${C_YELLOW}Файлы восстановлены, но служба не запустилась. Проверьте логи.${C_RESET}"
                fi
                pause_prompt
                ;;
            4)
                echo ">>> Очистка старых резервных копий (оставляем 3 самые свежие)..."
                local all_baks=()
                while IFS= read -r line; do
                    [[ -n "$line" ]] && all_baks+=("$line")
                done < <(find "$BACKUP_DIR" -maxdepth 1 -type f 2>/dev/null | sort -r)

                if [[ ${#all_baks[@]} -le 3 ]]; then
                    echo "Резервных копий 3 или меньше. Очистка не требуется."
                else
                    for ((i=3; i<${#all_baks[@]}; i++)); do
                        rm -f "${all_baks[$i]}"
                        echo "  Удален старый файл: $(basename "${all_baks[$i]}")"
                    done
                    echo -e "${C_GREEN}✓ Очистка завершена.${C_RESET}"
                fi
                pause_prompt
                ;;
            0)
                break
                ;;
            *)
                echo "Некорректный выбор."
                sleep 1
                ;;
        esac
    done
}

# [12] Удалить TorrServer
uninstall_torrserver() {
    show_header
    detect_torrserver

    echo -e "${C_BOLD}${C_BRED}⚠️  ПОЛНОЕ УДАЛЕНИЕ TORRSERVER${C_RESET}"
    echo
    echo "Это действие остановит службу, удалит torrserver.service и очистит файлы программы."
    echo

    local confirm=""
    read_choice "Для подтверждения введите 'DELETE' или 'УДАЛИТЬ': " confirm ""

    if [[ "$confirm" != "DELETE" && "$confirm" != "УДАЛИТЬ" ]]; then
        echo -e "${C_YELLOW}Удаление отменено.${C_RESET}"
        pause_prompt
        return
    fi

    echo
    echo ">>> Остановка и отключение службы..."
    systemctl stop torrserver 2>/dev/null || true
    systemctl disable torrserver 2>/dev/null || true

    # Создание страховочного архива перед удалением
    local safe_tar="/root/torrserver_pre_uninstall_$(date +%Y%m%d_%H%M%S).tar.gz"
    echo ">>> Сохранение аварийного архива в ${safe_tar}..."
    tar -czf "$safe_tar" "$TS_DIR" "${TS_SERVICE_PATH:-}" 2>/dev/null || true
    chmod 600 "$safe_tar" 2>/dev/null || true

    if [[ -n "$TS_SERVICE_PATH" && -f "$TS_SERVICE_PATH" ]]; then
        echo ">>> Удаление unit-файла службы ${TS_SERVICE_PATH}..."
        rm -f "$TS_SERVICE_PATH"
        systemctl daemon-reload 2>/dev/null || true
    fi

    local del_data="n"
    read_choice "Удалить каталог данных и базу торрентов (${TS_DIR})? [y/N]: " del_data "n"
    if [[ "$del_data" =~ ^[YyДд]$ ]]; then
        rm -rf "$TS_DIR"
        echo -e "${C_GREEN}✓ Каталог ${TS_DIR} удален.${C_RESET}"
    else
        echo -e "${C_GRAY}Каталог ${TS_DIR} сохранен.${C_RESET}"
    fi

    # Проверка UFW
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw "Status: active"; then
        if ufw status | grep -qE "^${TS_PORT}(/tcp)?[[:space:]]+ALLOW"; then
            local del_ufw="n"
            read_choice "Удалить правило UFW для порта ${TS_PORT}/tcp? [y/N]: " del_ufw "n"
            if [[ "$del_ufw" =~ ^[YyДд]$ ]]; then
                ufw delete allow "${TS_PORT}/tcp" >/dev/null 2>&1 || true
                echo -e "${C_GREEN}✓ Правило UFW для порта ${TS_PORT}/tcp удалено.${C_RESET}"
            fi
        fi
    fi

    echo
    echo -e "${C_GREEN}✓ TorrServer успешно удален из системы.${C_RESET}"
    echo -e "  Аварийная копия конфигурации сохранена: ${safe_tar}"
    pause_prompt
}

# Главное меню скрипта
main_menu() {
    while true; do
        show_header
        detect_torrserver

        local short_status="${C_RED}● Остановлен${C_RESET}"
        if [[ "$TS_INSTALLED" -eq 0 ]]; then
            short_status="${C_YELLOW}⚠️ Не установлен${C_RESET}"
        elif systemctl is-active --quiet torrserver 2>/dev/null; then
            short_status="${C_GREEN}● Работает${C_RESET} ${C_GRAY}(порт ${TS_PORT})${C_RESET}"
        fi

        echo -e "  Статус: ${short_status}"
        echo -e "${C_GRAY}──────────────────────────────────────────────────────────────────────${C_RESET}"
        echo -e "  ${C_BGREEN}[1]${C_RESET}  📊 Статус TorrServer"
        echo -e "  ${C_BGREEN}[2]${C_RESET}  ▶️  Запустить"
        echo -e "  ${C_BGREEN}[3]${C_RESET}  ⏹️  Остановить"
        echo -e "  ${C_BGREEN}[4]${C_RESET}  🔄 Перезапустить"
        echo -e "  ${C_BGREEN}[5]${C_RESET}  🔐 Настройки доступа (логин / пароль)"
        echo -e "  ${C_BGREEN}[6]${C_RESET}  🌐 Сменить порт"
        echo -e "  ${C_BGREEN}[7]${C_RESET}  ⚙️  Настроить автозапуск"
        echo -e "  ${C_BGREEN}[8]${C_RESET}  📜 Просмотр логов"
        echo -e "  ${C_BGREEN}[9]${C_RESET}  🔍 Проверка доступности и диагностика"
        echo -e "  ${C_BGREEN}[10]${C_RESET} 🚀 Обновить TorrServer"
        echo -e "  ${C_BGREEN}[11]${C_RESET} 💾 Резервная копия / восстановление"
        echo -e "  ${C_BRED}[12]${C_RESET} 🗑️  Удалить TorrServer"
        echo -e "  ${C_RED}[0]${C_RESET}  🚪 Выход"
        echo -e "${C_GRAY}──────────────────────────────────────────────────────────────────────${C_RESET}"

        local main_choice="0"
        read_choice "${C_BOLD}Выберите пункт [0-12]: ${C_RESET}" main_choice "0"
        echo

        case "$main_choice" in
            1)  view_status ;;
            2)  start_service ;;
            3)  stop_service ;;
            4)  restart_service ;;
            5)  manage_auth ;;
            6)  change_port_and_ip ;;
            7)  toggle_autostart ;;
            8)  view_logs ;;
            9)  diagnose_server ;;
            10) update_torrserver ;;
            11) backup_restore_menu ;;
            12) uninstall_torrserver ;;
            0|q|exit|quit)
                echo "Выход из TorrServer Manager."
                exit 0
                ;;
            *)
                echo -e "${C_RED}❌ Некорректный выбор: ${main_choice}${C_RESET}" >&2
                sleep 1
                ;;
        esac
    done
}

# Поддержка CLI-вызовов
handle_cli() {
    local cmd="${1:-}"
    case "$cmd" in
        status)
            detect_torrserver
            systemctl status torrserver --no-pager 2>/dev/null || true
            ;;
        start)
            systemctl start torrserver
            ;;
        stop)
            systemctl stop torrserver
            ;;
        restart)
            systemctl restart torrserver
            ;;
        *)
            main_menu
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    handle_cli "${1:-}"
fi
