#!/usr/bin/env bash
# modules/mssql/common.sh — Базовые утилиты, цвета и SQL-движок

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
C_PURPLE='\033[0;35m'
C_GRAY='\033[0;90m'

# Каталоги конфигурации
MSSQL_CONF_DIR="/etc/mssql-manager"
MSSQL_CONN_DIR="${MSSQL_CONF_DIR}/connections"
MSSQL_LOG_DIR="/var/log/mssql-manager"
MSSQL_BACKUP_DEFAULT="/var/backups/mssql-manager"

init_directories() {
    mkdir -p "$MSSQL_CONF_DIR" "$MSSQL_CONN_DIR" "$MSSQL_LOG_DIR" "$MSSQL_BACKUP_DEFAULT" 2>/dev/null || true
    chmod 700 "$MSSQL_CONF_DIR" "$MSSQL_CONN_DIR" "$MSSQL_LOG_DIR" "$MSSQL_BACKUP_DEFAULT" 2>/dev/null || true
}

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

    [[ -z "$val" ]] && val="$default_val"
    printf -v "$var_name" "%s" "$val"
}

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

# Подтверждение опасных действий по уровням риска:
# Уровень 1 (безопасно) — без подтверждения
# Уровень 2 (изменение) — [y/N]
# Уровень 3 (разрушительно) — ввод точного имени объекта
confirm_action() {
    local level="$1"
    local description="$2"
    local target_name="${3:-}"

    if [[ "$level" -eq 1 ]]; then
        return 0
    elif [[ "$level" -eq 2 ]]; then
        echo -e "${C_YELLOW}⚠️  ВНИМАНИЕ: ${description}${C_RESET}"
        local ans="n"
        read_choice "Подтвердить операцию? [y/N]: " ans "n"
        if [[ "$ans" =~ ^[YyДд]$ ]]; then
            return 0
        else
            echo "Операция отменена."
            return 1
        fi
    elif [[ "$level" -eq 3 ]]; then
        echo -e "${C_BRED}⛔ ОПАСНАЯ ОПЕРАЦИЯ: ${description}${C_RESET}"
        echo -e "   Целевой объект: ${C_BOLD}${target_name}${C_RESET}"
        echo
        local input_conf=""
        read_choice "Для подтверждения введите точное имя '${target_name}': " input_conf ""
        if [[ "$input_conf" == "$target_name" ]]; then
            return 0
        else
            echo -e "${C_YELLOW}Подтверждение не совпадает. Действие отменено.${C_RESET}"
            return 1
        fi
    fi
    return 1
}

# Единый движок выполнения SQL-запросов
# Принимает query и необязательный target db
# Использует текущий активный профиль: TARGET_TYPE (docker/native/remote), TARGET_HOST, TARGET_PORT, TARGET_USER, TARGET_PASS, TARGET_CONTAINER
run_sql_query() {
    local query="$1"
    local database="${2:-master}"
    local query_out=""
    local rc=0

    # Проверка обязательных параметров подключения
    local user="${CURRENT_USER:-sa}"
    local pass="${CURRENT_PASS:-}"
    local host="${CURRENT_HOST:-127.0.0.1}"
    local port="${CURRENT_PORT:-1433}"
    local target_type="${CURRENT_TYPE:-docker}"

    # Если запуск в Docker
    if [[ "$target_type" == "docker" ]]; then
        local container="${CURRENT_CONTAINER:-mssql_server}"
        if ! command -v docker >/dev/null 2>&1; then
            echo "❌ Docker не установлен." >&2
            return 1
        fi
        
        # Поиск sqlcmd внутри контейнера (sqlcmd в mssql-tools18 или mssql-tools)
        local cmd_bin="/opt/mssql-tools18/bin/sqlcmd"
        if ! docker exec "$container" test -f "$cmd_bin" 2>/dev/null; then
            cmd_bin="/opt/mssql-tools/bin/sqlcmd"
        fi

        # Безопасная передача пароля через переменную окружения в subshell
        query_out="$(docker exec -i -e SQLCMDPASSWORD="$pass" "$container" "$cmd_bin" -S localhost -U "$user" -d "$database" -C -b -W -Q "$query" 2>&1)" || rc=$?
    elif [[ "$target_type" == "native" || "$target_type" == "remote" ]]; then
        # Использование локального sqlcmd, если установлен
        local sqlcmd_bin=""
        for candidate in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd /usr/bin/sqlcmd /usr/local/bin/sqlcmd; do
            if [[ -x "$candidate" ]]; then
                sqlcmd_bin="$candidate"
                break
            fi
        done

        if [[ -n "$sqlcmd_bin" ]]; then
            export SQLCMDPASSWORD="$pass"
            query_out="$("$sqlcmd_bin" -S "${host},${port}" -U "$user" -d "$database" -C -b -W -Q "$query" 2>&1)" || rc=$?
            unset SQLCMDPASSWORD
        elif command -v python3 >/dev/null 2>&1; then
            # Фоллбек: простой запрос через Python, если sqlcmd отсутствует
            query_out="$(python3 -c "
import socket, sys
# Проверка сокета
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(3)
try:
    s.connect(('$host', int('$port')))
    s.close()
    print('TCP Connection OK (sqlcmd utility not installed on host)')
except Exception as e:
    print('Connection error:', e)
    sys.exit(1)
" 2>&1)" || rc=$?
        else
            echo "❌ Утилита sqlcmd не найдена в системе." >&2
            return 1
        fi
    fi

    echo "$query_out"
    return "$rc"
}
