#!/usr/bin/env bash
# ==============================================================================
# LERS DATABASE MANAGER
# Установка • Backup • Restore • Обновление LERS
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Цветовая палитра для терминала
# ------------------------------------------------------------------------------
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
NC=$'\033[0m'

# ------------------------------------------------------------------------------
# Системные каталоги и параметры по умолчанию
# ------------------------------------------------------------------------------
LERS_BASE_DIR="/opt/lers"
COMPOSE_FILE="${LERS_BASE_DIR}/compose.yml"
ENV_FILE="${LERS_BASE_DIR}/.env"

SQLDATA_DIR="${LERS_BASE_DIR}/sqldata"
LERS_DATA_DIR="${LERS_BASE_DIR}/data"
LERS_CONF_DIR="${LERS_BASE_DIR}/config"

# Стандартный каталог бэкапов
BACKUP_DIR="/var/backups/lers"
SQL_BACKUP_DIR="${LERS_BASE_DIR}/backup/sql"
INCOMING_DIR="${BACKUP_DIR}/incoming"

# Каталог конфигурации менеджера (без паролей на диске)
MSSQL_SA_PASSWORD_FILE="/root/.mssql-sa-password"

DEFAULT_LERS_IMAGE="lersamr/full-r:latest"
DEFAULT_MSSQL_IMAGE="mcr.microsoft.com/mssql/server:2025-latest"
DEFAULT_LERS_PORT="10000"
DEFAULT_MSSQL_PORT="1433"
DEFAULT_DB_NAME="LERS"
DEFAULT_MSSQL_PID="Express"

# Активная сессия (в памяти)

# ------------------------------------------------------------------------------
# Вспомогательные функции вывода и безопасности
# ------------------------------------------------------------------------------
info()    { echo -e "${BLUE}[ИНФО]${NC} $1"; }
success() { echo -e "${GREEN}[УСПЕХ]${NC} $1"; }
warn()    { echo -e "${YELLOW}[ВНИМАНИЕ]${NC} $1"; }
error()   { echo -e "${RED}[ОШИБКА]${NC} $1"; }
step()    { echo -e "\\n${BOLD}${CYAN}>>> [$1]${NC} ${BOLD}$2${NC}"; }

print_banner() {
    clear 2>/dev/null || true
    echo -e "${CYAN}======================================================================${NC}"
    echo -e "                   ${BOLD}${CYAN}LERS DATABASE MANAGER${NC}"
    echo -e "         ${YELLOW}Установка • Backup • Restore • Обновление LERS${NC}"
    echo -e "${CYAN}======================================================================${NC}"
}

read_secret_masked() {
    local prompt="$1"
    local __resultvar="$2"
    local secret=""
    local char=""

    if [[ ! -t 0 ]]; then
        read -r secret
        printf -v "$__resultvar" '%s' "$secret"
        return 0
    fi

    echo -ne "$prompt" >&2
    while IFS= read -r -s -n 1 char; do
        if [[ "$char" == $'\0' || "$char" == $'\n' ]]; then
            break
        elif [[ "$char" == $'\177' || "$char" == $'\b' ]]; then
            if [[ ${#secret} -gt 0 ]]; then
                secret="${secret%?}"
                echo -ne "\\b \\b" >&2
            fi
        else
            secret+="$char"
            echo -ne "*" >&2
        fi
    done
    echo >&2
    printf -v "$__resultvar" '%s' "$secret"
}

sql_escape() {
    local val="$1"
    echo "${val//\'/\'\'}"
}

# ------------------------------------------------------------------------------
# Системный слой: APT, каталоги, профили конфигурации
# ------------------------------------------------------------------------------
check_prerequisites() {
    if [[ "${EUID}" -ne 0 ]]; then
        error "Этот скрипт должен запускаться от имени root (или через sudo)."
        exit 1
    fi

    local arch
    arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
    if [[ "$arch" != "amd64" && "$arch" != "x86_64" ]]; then
        error "MS SQL Server и ЛЭРС УЧЁТ в Docker поддерживаются только на архитектуре x86_64 / amd64."
        exit 1
    fi
}

clean_broken_third_party_apt() {
    return 0
}

ensure_dependencies() {
    clean_broken_third_party_apt

    local missing=()
    for tool in curl openssl tar jq gzip unzip file bzip2; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        info "Установка базовых системных утилит: ${missing[*]}..."
        apt-get update -qq >/dev/null 2>&1 || true
        if ! apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1; then
            warn "Некоторые утилиты не удалось установить автоматически: ${missing[*]}"
        fi
    fi
}

# Проверка требований по оперативной памяти для MS SQL Server (минимум 2000 MB)
check_mssql_memory_requirement() {
    local total_kb avail_kb swap_total_kb
    total_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    avail_kb="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    swap_total_kb="$(awk '/SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"

    local total_mb=$(( total_kb / 1024 ))
    local avail_mb=$(( avail_kb / 1024 ))
    local swap_mb=$(( swap_total_kb / 1024 ))

    local total_gb avail_gb swap_gb
    total_gb="$(awk -v v="$total_mb" 'BEGIN {printf "%.2f", v/1024}')"
    avail_gb="$(awk -v v="$avail_mb" 'BEGIN {printf "%.2f", v/1024}')"
    swap_gb="$(awk -v v="$swap_mb" 'BEGIN {printf "%.2f", v/1024}')"

    if (( total_mb < 2000 )); then
        echo
        error "Недостаточно оперативной памяти для MS SQL Server."
        echo
        echo "  SQL Server 2025"
        echo "  Требуемая RAM: минимум 2 GB (2000 MB)"
        echo "  RAM VPS:       ${total_gb} GB (${total_mb} MB)"
        echo "  Доступно:      ${avail_gb} GB (${avail_mb} MB)"
        echo "  Swap:          ${swap_gb} GB (${swap_mb} MB)"
        echo
        echo "  [ОШИБКА] Сервер не подходит для установки MS SQL Server."
        echo "  Swap не заменяет требование к физической RAM."
        echo "  Движок sqlservr при старте проверяет MemTotal в /proc/meminfo"
        echo "  и аварийно завершается, если физическая память меньше 2000 MB."
        echo
        echo "  Для установки LERS + MS SQL увеличьте RAM VPS минимум до 2 GB."
        echo
        return 1
    fi

    success "RAM VPS подходит для MS SQL Server: ${total_mb} MB (${total_gb} GB)."
    return 0
}

ensure_docker() {
    # 1. Проверяем наличие Docker
    if command -v docker >/dev/null 2>&1; then
        local d_ver
        d_ver="$(docker --version 2>/dev/null || echo "установлен")"
        success "Docker уже установлен: ${d_ver}"
    else
        info "Docker не найден. Установка через apt-get..."
        clean_broken_third_party_apt

        info "Выполнение: apt-get update..."
        apt-get update

        info "Выполнение: apt-get install -y docker.io..."
        apt-get install -y docker.io

        systemctl enable --now docker >/dev/null 2>&1 || true
    fi

    # Проверка доступности Docker
    if ! command -v docker >/dev/null 2>&1; then
        echo
        error "КРИТИЧЕСКАЯ ОШИБКА: Docker не установлен."
        echo "  Команда 'docker' отсутствует в системе после выполнения apt-get install -y docker.io."
        echo "  Проверьте вывод ошибок APT выше и состояние репозиториев (/etc/apt/sources.list)."
        return 1
    fi

    # 2. Проверяем наличие Docker Compose
    if docker compose version >/dev/null 2>&1; then
        local c_ver
        c_ver="$(docker compose version 2>/dev/null || echo "готов")"
        success "Docker Compose доступен: ${c_ver}"
    else
        info "Плагин Docker Compose не найден. Установка через APT..."
        apt-get install -y docker-compose-v2 2>/dev/null || apt-get install -y docker-compose-plugin 2>/dev/null || apt-get install -y docker-compose 2>/dev/null || true

        if ! docker compose version >/dev/null 2>&1; then
            echo
            error "КРИТИЧЕСКАЯ ОШИБКА: Docker Compose плагин недоступен."
            echo "  Установите пакет командой: apt-get install -y docker-compose-v2"
            return 1
        fi
        success "Docker Compose успешно установлен: $(docker compose version)"
    fi

    return 0
}

init_directories() {
    mkdir -p         "${LERS_BASE_DIR}"         "${SQLDATA_DIR}"         "${LERS_DATA_DIR}"         "${LERS_CONF_DIR}"         "${BACKUP_DIR}"         "${SQL_BACKUP_DIR}"         "${INCOMING_DIR}"

    chmod 755 "${LERS_BASE_DIR}"
    chmod 755 "${BACKUP_DIR}" "${INCOMING_DIR}"

    # MS SQL Server в контейнере работает от пользователя mssql (UID 10001, GID 0)
    chown -R 10001:0 "${SQLDATA_DIR}" "${SQL_BACKUP_DIR}" 2>/dev/null || true
    chmod -R 775 "${SQLDATA_DIR}" "${SQL_BACKUP_DIR}" 2>/dev/null || chmod -R 777 "${SQLDATA_DIR}" "${SQL_BACKUP_DIR}" 2>/dev/null || true

    # Очистка устаревших сохранённых профилей с сервера (если остались от старых версий)
    rm -rf /var/lib/lers-manager 2>/dev/null || true
}

prepare_mssql_storage() {
    init_directories
    chown -R 10001:0 "${SQLDATA_DIR}" "${SQL_BACKUP_DIR}" 2>/dev/null || true
    chmod -R 775 "${SQLDATA_DIR}" "${SQL_BACKUP_DIR}" 2>/dev/null || chmod -R 777 "${SQLDATA_DIR}" "${SQL_BACKUP_DIR}" 2>/dev/null || true
}



get_or_create_sa_password() {
    if [[ -s "$MSSQL_SA_PASSWORD_FILE" ]]; then
        MSSQL_SA_PASSWORD="$(<"$MSSQL_SA_PASSWORD_FILE")"
    else
        local old_umask
        old_umask="$(umask)"
        umask 077
        local rnd_hex
        rnd_hex="$(openssl rand -hex 16 2>/dev/null || od -vAn -N16 -tx1 /dev/urandom | tr -d ' 
')"
        MSSQL_SA_PASSWORD="Lers_Sql_${rnd_hex}#2026!"
        printf '%s' "$MSSQL_SA_PASSWORD" > "$MSSQL_SA_PASSWORD_FILE"
        chmod 600 "$MSSQL_SA_PASSWORD_FILE"
        umask "$old_umask"
        info "Сгенерирован пароль SA для MS SQL: сохранён в $MSSQL_SA_PASSWORD_FILE"
    fi
}

# ------------------------------------------------------------------------------
# Клиентский движок: go-sqlcmd, native sqlcmd, Docker fallback
# ------------------------------------------------------------------------------
find_sqlcmd_client() {
    local __client_type_var="$1"
    local __client_path_var="$2"
    local __flags_var="$3"

    local candidates=(
        "/opt/mssql-tools18/bin/sqlcmd"
        "/opt/mssql-tools/bin/sqlcmd"
        "/usr/local/bin/sqlcmd"
        "/usr/bin/sqlcmd"
    )

    if command -v sqlcmd >/dev/null 2>&1; then
        local which_sqlcmd
        which_sqlcmd="$(command -v sqlcmd)"
        candidates=("$which_sqlcmd" "${candidates[@]}")
    fi

    for bin in "${candidates[@]}"; do
        if [[ -x "$bin" ]]; then
            local flags=""
            local help_out
            help_out="$("$bin" -? 2>&1 || "$bin" --help 2>&1 || true)"
            if echo "$help_out" | grep -q -- '-C'; then
                flags="-C"
            fi
            printf -v "$__client_type_var" '%s' "NATIVE"
            printf -v "$__client_path_var" '%s' "$bin"
            printf -v "$__flags_var" '%s' "$flags"
            return 0
        fi
    done

    # Проверка контейнера базы данных lers-db
    if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'lers-db'; then
        printf -v "$__client_type_var" '%s' "CONTAINER_LERS_DB"
        printf -v "$__client_path_var" '%s' "lers-db"
        printf -v "$__flags_var" '%s' "-C"
        return 0
    fi

    # Запасной вариант через docker run mssql-tools
    if command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1; then
        printf -v "$__client_type_var" '%s' "DOCKER_RUN"
        printf -v "$__client_path_var" '%s' "mcr.microsoft.com/mssql-tools:latest"
        printf -v "$__flags_var" '%s' ""
        return 0
    fi

    return 1
}

install_go_sqlcmd_archive() {
    local raw_arch
    raw_arch="$(uname -m)"
    local go_arch="amd64"
    if [[ "$raw_arch" == "x86_64" || "$raw_arch" == "amd64" ]]; then
        go_arch="amd64"
    elif [[ "$raw_arch" == "aarch64" || "$raw_arch" == "arm64" ]]; then
        go_arch="arm64"
    else
        echo -e "${RED}НЕПОДДЕРЖИВАЕТСЯ (${raw_arch})${NC}"
        error "Архитектура ${raw_arch} не поддерживается для готовых сборок go-sqlcmd."
        return 1
    fi

    local candidate_urls=(
        "https://github.com/microsoft/go-sqlcmd/releases/latest/download/sqlcmd-linux-${go_arch}.tar.bz2"
        "https://github.com/microsoft/go-sqlcmd/releases/download/v1.8.2/sqlcmd-linux-${go_arch}.tar.bz2"
        "https://github.com/microsoft/go-sqlcmd/releases/download/v1.8.0/sqlcmd-linux-${go_arch}.tar.bz2"
    )

    local tmp_dir
    tmp_dir="$(mktemp -d /tmp/lers-sqlcmd-XXXXXX)"
    chmod 700 "$tmp_dir"
    local tmp_tar="${tmp_dir}/sqlcmd-linux-${go_arch}.tar.bz2"

    local download_ok=0
    for u in "${candidate_urls[@]}"; do
        local http_code
        http_code="$(curl -4 -sL -w "%{http_code}" --retry 2 --connect-timeout 10 -o "$tmp_tar" "$u" 2>/dev/null || echo "000")"
        if [[ "$http_code" == "200" && -s "$tmp_tar" ]]; then
            if bzip2 -t "$tmp_tar" 2>/dev/null; then
                download_ok=1
                break
            fi
        fi
    done

    if [[ $download_ok -eq 0 ]]; then
        rm -rf "$tmp_dir"
        return 1
    fi

    mkdir -p /usr/local/bin
    if ! tar -xjf "$tmp_tar" -C /usr/local/bin/ sqlcmd 2>/dev/null; then
        rm -rf "$tmp_dir"
        return 1
    fi
    chmod +x /usr/local/bin/sqlcmd 2>/dev/null || true
    rm -rf "$tmp_dir"

    [[ -x /usr/local/bin/sqlcmd ]]
}

prepare_sqlcmd() {
    echo
    echo -e "${BOLD}${CYAN}>>> ПОДГОТОВКА SQL-КЛИЕНТА${NC}"
    echo

    if command -v sqlcmd >/dev/null 2>&1; then
        local version
        version="$(sqlcmd --version 2>&1 | head -n1 || sqlcmd -? 2>&1 | head -n1 || echo "готов")"
        success "sqlcmd уже установлен: ${version}"
        return 0
    fi

    echo "  sqlcmd не найден в системе."
    echo "  Устанавливается официальный автономный go-sqlcmd от Microsoft."
    echo

    # [1/3] Системные зависимости (curl, bzip2, tar)
    echo -n "  [1/3] Обновление пакетов и зависимостей (bzip2, tar) .. "
    local missing_pkgs=()
    command -v curl >/dev/null 2>&1 || missing_pkgs+=("curl")
    command -v bzip2 >/dev/null 2>&1 || missing_pkgs+=("bzip2")
    command -v tar >/dev/null 2>&1 || missing_pkgs+=("tar")

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        clean_broken_third_party_apt
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y -qq "${missing_pkgs[@]}" >/dev/null 2>&1 || true
    fi
    echo -e "${GREEN}OK${NC}"

    # [2/3] Загрузка и распаковка go-sqlcmd
    echo -n "  [2/3] Установка автономного go-sqlcmd ................. "
    if ! install_go_sqlcmd_archive; then
        echo -e "${RED}FAILED${NC}"
        echo
        error "Не удалось скачать или распаковать go-sqlcmd."
        warn "Проверьте соединение с GitHub или установите sqlcmd вручную в /usr/local/bin/sqlcmd."
        return 1
    fi
    echo -e "${GREEN}OK${NC}"

    # [3/3] Проверка работоспособности
    echo -n "  [3/3] Проверка sqlcmd ................................. "
    if ! command -v sqlcmd >/dev/null 2>&1 && [[ ! -x /usr/local/bin/sqlcmd ]]; then
        echo -e "${RED}FAILED${NC}"
        error "После установки исполняемый файл sqlcmd не найден."
        return 1
    fi
    echo -e "${GREEN}OK${NC}"

    local v_out
    v_out="$(/usr/local/bin/sqlcmd --version 2>&1 | head -n1 || echo "готов")"
    success "SQL-клиент готов к работе: ${v_out}"
    echo
    return 0
}

check_tcp_port() {
    local host="$1" port="$2" timeout_sec="${3:-5}"
    if timeout "$timeout_sec" bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" 2>/dev/null; then
        return 0
    elif command -v nc >/dev/null 2>&1 && nc -z -w "$timeout_sec" "$host" "$port" 2>/dev/null; then
        return 0
    fi
    return 1
}

sql_auth_check() {
    local host="$1" port="$2" db="$3" user="$4" pass="$5" timeout_sec="${6:-15}"

    local sqlcmd_bin="/usr/local/bin/sqlcmd"
    if [[ ! -x "$sqlcmd_bin" ]]; then
        sqlcmd_bin="$(command -v sqlcmd 2>/dev/null || true)"
    fi

    if [[ -z "$sqlcmd_bin" || ! -x "$sqlcmd_bin" ]]; then
        error "sqlcmd не найден."
        return 1
    fi

    local output=""
    local rc=0

    output="$(
        SQLCMDPASSWORD="$pass" \
        timeout "${timeout_sec}s" \
        "$sqlcmd_bin" \
            -S "${host},${port}" \
            -U "$user" \
            -d "$db" \
            -Q 'SET NOCOUNT ON; SELECT DB_NAME();' \
            -C \
            -l 10 \
            -t 10 \
            -h -1 \
            -W \
            -b \
        2>&1
    )" || rc=$?

    local result
    result="$(printf '%s' "$output" | tr -d '\r' | sed '/^[[:space:]]*$/d' | tail -n 1 | xargs 2>/dev/null || true)"

    if (( rc == 0 )) && [[ "$result" == "$db" ]]; then
        return 0
    fi

    if [[ "$result" == "$db" ]]; then
        return 0
    fi

    return 1
}

remote_sqlcmd() {
    local host="$1" port="$2" user="$3" pass="$4" db="${5:-master}" query="$6" extra_flags="${7:-}" timeout_sec="${8:-20}"
    local client_type="" client_path="" flags=""

    if ! find_sqlcmd_client client_type client_path flags; then
        error "SQL-клиент sqlcmd не найден в системе. Запустите prepare_sqlcmd."
        return 1
    fi

    local login_timeout=5
    (( timeout_sec < login_timeout )) && login_timeout=$timeout_sec

    case "$client_type" in
        NATIVE)
            SQLCMDPASSWORD="$pass" timeout "${timeout_sec}s" "$client_path" \
                -S "${host},${port}" \
                -U "${user}" \
                -d "${db}" \
                -Q "${query}" \
                $flags \
                -l "$login_timeout" \
                $extra_flags -b < /dev/null
            ;;
        CONTAINER_LERS_DB)
            docker exec -i lers-db bash -c '
                            if [ -x /opt/mssql-tools18/bin/sqlcmd ]; then
                CMD=/opt/mssql-tools18/bin/sqlcmd; FLAGS="-C"
            elif [ -x /usr/local/bin/sqlcmd ]; then
                CMD=/usr/local/bin/sqlcmd; FLAGS="-C"
            elif [ -x /opt/mssql-tools/bin/sqlcmd ]; then
                CMD=/opt/mssql-tools/bin/sqlcmd; FLAGS=""
            elif command -v sqlcmd >/dev/null 2>&1; then
                CMD="$(command -v sqlcmd)"; FLAGS="-C"
            else
                echo "sqlcmd не найден в контейнере lers-db" >&2; exit 1
            fi
                SQLCMDPASSWORD="$(cat)" timeout '"${timeout_sec}s"' "$CMD" -S "'"${host},${port}"'" -U "'"${user}"'" -d "'"${db}"'" -Q "'"${query}"'" $FLAGS -l '"$login_timeout"' -t '"$timeout_sec"' '"$extra_flags"' -b
            ' <<< "$pass"
            ;;
        DOCKER_RUN)
            docker run --rm -i -e "SQLCMDPASSWORD=${pass}" "$client_path" \
                /opt/mssql-tools/bin/sqlcmd -S "${host},${port}" -U "${user}" -d "${db}" -Q "${query}" -l "$login_timeout" -t "$timeout_sec" $extra_flags -b
            ;;
    esac
}


# ------------------------------------------------------------------------------
# Локальное выполнение SQL внутри Docker-контейнера lers-db
# ------------------------------------------------------------------------------
sql_local_exec() {
    local query="$1" db_context="${2:-master}"
    shift 2 2>/dev/null || true
    get_or_create_sa_password

    docker exec -i \
        -e "SQLCMDPASSWORD=${MSSQL_SA_PASSWORD}" \
        lers-db \
        bash -c '
            if [ -x /opt/mssql-tools18/bin/sqlcmd ]; then
                CMD=/opt/mssql-tools18/bin/sqlcmd; FLAGS="-C"
            elif [ -x /opt/mssql-tools/bin/sqlcmd ]; then
                CMD=/opt/mssql-tools/bin/sqlcmd; FLAGS=""
            else
                echo "sqlcmd не найден в контейнере lers-db" >&2; exit 1
            fi
            "$CMD" -S localhost -U sa -d "'"$db_context"'" -Q "'"$query"'" $FLAGS "$@" -b
        ' bash "$@"
}

wait_for_local_mssql() {
    local count=0
    local max_retries=40
    info "Ожидание инициализации и готовности MS SQL Server..."
    until sql_local_exec "SELECT 1" "master" >/dev/null 2>&1; do
        sleep 2
        count=$((count + 1))
        if (( count >= max_retries )); then
            echo
            error "Таймаут ожидания старта MS SQL Server ($(( max_retries * 2 )) сек)."
            info "Диагностика контейнера lers-db (последние 40 строк журнала):"
            docker logs --tail 40 lers-db 2>&1 || true
            return 1
        fi
    done
    success "MS SQL Server готов к работе."
    return 0
}

get_restore_file_moves() {
    local container_backup_path="$1" target_db_name="${2:-LERS}"
    local raw_filelist
    raw_filelist="$(sql_local_exec "RESTORE FILELISTONLY FROM DISK = N'$(sql_escape "$container_backup_path")';" "master" -s "|" -W -h -1 2>/dev/null || true)"

    [[ -z "$raw_filelist" ]] && { error "Не удалось прочитать список файлов бэкапа."; return 1; }

    local data_idx=0 log_idx=0 move_clauses=()
    while IFS='|' read -r col_logical col_phys col_type col_rest; do
        col_logical="$(echo "${col_logical:-}" | tr -d '\r\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        col_type="$(echo "${col_type:-}" | tr -d '\r\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | tr '[:lower:]' '[:upper:]')"
        [[ -z "$col_logical" || -z "$col_type" || "$col_logical" =~ ^-+ ]] && continue

        local escaped_logical
        escaped_logical="$(sql_escape "$col_logical")"

        if [[ "$col_type" == "D" ]]; then
            data_idx=$((data_idx + 1))
            if (( data_idx == 1 )); then
                move_clauses+=("MOVE N'${escaped_logical}' TO N'/var/opt/mssql/data/${target_db_name}.mdf'")
            else
                move_clauses+=("MOVE N'${escaped_logical}' TO N'/var/opt/mssql/data/${target_db_name}_${data_idx}.ndf'")
            fi
        elif [[ "$col_type" == "L" ]]; then
            log_idx=$((log_idx + 1))
            if (( log_idx == 1 )); then
                move_clauses+=("MOVE N'${escaped_logical}' TO N'/var/opt/mssql/data/${target_db_name}_log.ldf'")
            else
                move_clauses+=("MOVE N'${escaped_logical}' TO N'/var/opt/mssql/data/${target_db_name}_log_${log_idx}.ldf'")
            fi
        fi
    done <<< "$raw_filelist"

    if (( ${#move_clauses[@]} == 0 )); then
        error "Не удалось сформировать предложения MOVE для восстановления."
        return 1
    fi

    local IFS=","
    echo "${move_clauses[*]}"
}

cleanup_orphaned_ndf_files() {
    local target_db_name="${1:-LERS}"
    local active_files
    active_files="$(sql_local_exec "SELECT physical_name FROM sys.master_files WHERE database_id = DB_ID('$(sql_escape "$target_db_name")')" "master" -h -1 -W 2>/dev/null || true)"
    [[ -z "$active_files" ]] && return 0

    for f in "${SQLDATA_DIR}/${target_db_name}_"*.ndf; do
        [[ ! -f "$f" ]] && continue
        local fname
        fname="$(basename "$f")"
        if ! grep -q "$fname" <<< "$active_files"; then
            warn "Удаление устаревшего файла вторичных данных: $f"
            rm -f "$f"
        fi
    done
}

verify_sql_backup() {
    local bak_path="$1"
    step "ПРОВЕРКА БЭКАПА" "Валидация файла бэкапа средствами MS SQL Server..."

    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'lers-db'; then
        error "Контейнер lers-db должен быть запущен для проверки бэкапа."
        return 1
    fi

    local tmp_bak_name="__verify_$(date +%s).bak"
    local host_sql_bak="${SQL_BACKUP_DIR}/${tmp_bak_name}"
    cp -f "$bak_path" "$host_sql_bak"
    chmod 664 "$host_sql_bak"
    chown 10001:0 "$host_sql_bak" 2>/dev/null || true

    local container_path="/var/opt/mssql/backup/${tmp_bak_name}"

    info "Запуск RESTORE VERIFYONLY..."
    local verify_res
    if ! verify_res="$(sql_local_exec "RESTORE VERIFYONLY FROM DISK = N'$(sql_escape "${container_path}")';" "master" 2>&1)"; then
        error "Файл повреждён или не является валидным бэкапом SQL Server!"
        echo "$verify_res"
        rm -f "$host_sql_bak"
        return 1
    fi
    rm -f "$host_sql_bak"
    success "RESTORE VERIFYONLY: Резервная копия целостна и валидна."
    return 0
}

prepare_sql_bak_from_source() {
    local input_path="$1" __res_bak_var="$2"
    [[ ! -s "$input_path" ]] && { error "Файл не найден: $input_path"; return 1; }

    local determined_bak=""
    local file_type
    file_type="$(file -b "$input_path" 2>/dev/null || true)"

    if [[ "$input_path" == *.tar.gz || "$input_path" == *.tgz ]] || echo "$file_type" | grep -qi "gzip compressed"; then
        info "Распаковка архива tar.gz..."
        local out_tar_dir="${INCOMING_DIR}/extracted_$(date +%s)"
        mkdir -p "$out_tar_dir"
        tar -xzf "$input_path" -C "$out_tar_dir"
        local candidates=()
        mapfile -t candidates < <(find "$out_tar_dir" -maxdepth 2 -type f \( -iname "*.bak" -o -iname "*.db" \) -size +0c)
        [[ ${#candidates[@]} -gt 0 ]] && determined_bak="${candidates[0]}"
    elif [[ "$input_path" == *.zip ]] || echo "$file_type" | grep -qi "zip archive"; then
        info "Распаковка архива zip..."
        local out_zip_dir="${INCOMING_DIR}/extracted_$(date +%s)"
        mkdir -p "$out_zip_dir"
        unzip -q "$input_path" -d "$out_zip_dir"
        local candidates=()
        mapfile -t candidates < <(find "$out_zip_dir" -maxdepth 2 -type f \( -iname "*.bak" -o -iname "*.db" \) -size +0c)
        [[ ${#candidates[@]} -gt 0 ]] && determined_bak="${candidates[0]}"
    else
        determined_bak="$input_path"
    fi

    [[ -z "$determined_bak" || ! -s "$determined_bak" ]] && { error "Файл .bak не обнаружен."; return 1; }
    printf -v "$__res_bak_var" '%s' "$determined_bak"
    return 0
}

perform_database_restore() {
    local target_bak="$1"
    step "ВОССТАНОВЛЕНИЕ" "Восстановление базы данных LERS..."

    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'lers-db'; then
        check_mssql_memory_requirement || return 1
        info "Запуск контейнера MS SQL lers-db..."
        docker compose -f "$COMPOSE_FILE" up -d db
        wait_for_local_mssql
    fi

    verify_sql_backup "$target_bak" || return 1

    # Аварийная копия текущей базы перед восстановлением
    info "Создание аварийного бэкапа текущей базы (safety-backup)..."
    local safety_name="LERS_safety_before_restore_$(date +%Y%m%d_%H%M%S).bak"
    local safety_container_path="/var/opt/mssql/backup/${safety_name}"
    sql_local_exec "
        IF DB_ID('${DEFAULT_DB_NAME}') IS NOT NULL
        BEGIN
            BACKUP DATABASE [${DEFAULT_DB_NAME}]
            TO DISK = N'${safety_container_path}'
            WITH COPY_ONLY, COMPRESSION, FORMAT, INIT;
        END
    " "master" 2>/dev/null || true
    if [[ -f "${SQL_BACKUP_DIR}/${safety_name}" ]]; then
        mv -f "${SQL_BACKUP_DIR}/${safety_name}" "${BACKUP_DIR}/${safety_name}" 2>/dev/null || true
        info "Аварийный бэкап сохранён в: ${BACKUP_DIR}/${safety_name}"
    fi

    # Остановка LERS
    info "Остановка службы ЛЭРС перед перезаписью базы..."
    docker compose -f "$COMPOSE_FILE" stop lers >/dev/null 2>&1 || true

    # Копирование файла в том SQL
    local r_bak_name="restore_active_$(date +%s).bak"
    local r_host_p="${SQL_BACKUP_DIR}/${r_bak_name}"
    cp -f "$target_bak" "$r_host_p"
    chmod 664 "$r_host_p"
    chown 10001:0 "$r_host_p" 2>/dev/null || true

    local moves
    moves="$(get_restore_file_moves "/var/opt/mssql/backup/${r_bak_name}" "${DEFAULT_DB_NAME}")"

    info "Выполнение RESTORE DATABASE [${DEFAULT_DB_NAME}]..."
    sql_local_exec "
        USE master;
        IF DB_ID('${DEFAULT_DB_NAME}') IS NOT NULL ALTER DATABASE [${DEFAULT_DB_NAME}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
        RESTORE DATABASE [${DEFAULT_DB_NAME}] FROM DISK = N'/var/opt/mssql/backup/${r_bak_name}' WITH REPLACE, ${moves};
        ALTER DATABASE [${DEFAULT_DB_NAME}] SET MULTI_USER;
    " "master"

    rm -f "$r_host_p"
    cleanup_orphaned_ndf_files "${DEFAULT_DB_NAME}"

    info "Запуск службы ЛЭРС УЧЁТ..."
    docker compose -f "$COMPOSE_FILE" up -d lers

    verify_lers_health
    success "База данных LERS успешно восстановлена и подключена!"
}

# ------------------------------------------------------------------------------
# Генерация Compose и проверка здоровья
# ------------------------------------------------------------------------------
generate_compose_files() {
    cat > "$ENV_FILE" <<EOF
MSSQL_SA_PASSWORD=${MSSQL_SA_PASSWORD}
LERS_PORT=${LERS_PORT:-$DEFAULT_LERS_PORT}
LERS_IMAGE=${LERS_IMAGE:-$DEFAULT_LERS_IMAGE}
MSSQL_IMAGE=${MSSQL_IMAGE:-$DEFAULT_MSSQL_IMAGE}
MSSQL_PID=${MSSQL_PID:-$DEFAULT_MSSQL_PID}
EOF
    chmod 600 "$ENV_FILE"

    cat > "$COMPOSE_FILE" <<EOF
services:
  db:
    image: ${MSSQL_IMAGE:-$DEFAULT_MSSQL_IMAGE}
    container_name: lers-db
    restart: always
    environment:
      ACCEPT_EULA: "Y"
      MSSQL_SA_PASSWORD: "\${MSSQL_SA_PASSWORD}"
      SQLCMDPASSWORD: "\${MSSQL_SA_PASSWORD}"
      MSSQL_PID: "${MSSQL_PID:-Express}"
    volumes:
      - "${SQLDATA_DIR}:/var/opt/mssql/data"
      - "${SQL_BACKUP_DIR}:/var/opt/mssql/backup"
    ports:
      - "127.0.0.1:1433:1433"
    healthcheck:
      test: ["CMD-SHELL", "/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -Q 'SELECT 1' || /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -Q 'SELECT 1' || /usr/local/bin/sqlcmd -S localhost -U sa -C -Q 'SELECT 1' || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 30
      start_period: 30s

  lers:
    image: ${LERS_IMAGE:-$DEFAULT_LERS_IMAGE}
    container_name: lers-server
    restart: always
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "${LERS_PORT:-$DEFAULT_LERS_PORT}:10000"
    volumes:
      - "${LERS_DATA_DIR}:/var/LERS"
      - "${LERS_CONF_DIR}:/etc/LERS"
    environment:
      LERS_SERVER_DATABASE__ConnectionString: "Data Source=db,1433; Initial Catalog=${DEFAULT_DB_NAME}; User ID=sa; Password=\${MSSQL_SA_PASSWORD}; Integrated Security=false; Encrypt=true; TrustServerCertificate=true"
EOF
    chmod 644 "$COMPOSE_FILE"
}

verify_lers_health() {
    local port="${LERS_PORT:-$DEFAULT_LERS_PORT}"
    local waited=0
    info "Проверка доступности веб-интерфейса ЛЭРС УЧЁТ..."
    while (( waited < 30 )); do
        sleep 2
        waited=$((waited + 2))
        local code
        code="$(curl -4 -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://127.0.0.1:${port}/" 2>/dev/null || true)"
        if [[ "$code" =~ ^(200|301|302|401|403)$ ]]; then
            success "Веб-интерфейс ЛЭРС доступен (HTTP $code на порту $port)!"
            return 0
        fi
    done
    warn "Веб-интерфейс ещё инициализируется. Журнал: docker compose logs lers"
    return 0
}


# ==============================================================================
# СЦЕНАРИИ МЕНЕДЖЕРА (7 ОСНОВНЫХ ОПЕРАЦИЙ)
# ==============================================================================

# [1] Чистая установка LERS + MS SQL Express
menu_clean_install() {
    print_banner
    echo -e "${BOLD}${CYAN}>>> [1] ЧИСТАЯ УСТАНОВКА LERS + MS SQL EXPRESS${NC}"
    echo "────────────────────────────────────────────────────────────"
    check_mssql_memory_requirement || return 1
    if ! ensure_docker; then
        error "Установка остановлена: Docker недоступен."
        return 1
    fi
    init_directories

    read -rp "Порт веб-интерфейса ЛЭРС [${DEFAULT_LERS_PORT}]: " in_port
    LERS_PORT="${in_port:-$DEFAULT_LERS_PORT}"

    get_or_create_sa_password
    generate_compose_files

    # Очистка незавершённых контейнеров от предыдущей попытки
    docker compose -f "$COMPOSE_FILE" down 2>/dev/null || true
    prepare_mssql_storage

    info "Загрузка Docker-образов..."
    docker compose -f "$COMPOSE_FILE" pull

    info "[1/2] Запуск службы базы данных (MS SQL Express)..."
    docker compose -f "$COMPOSE_FILE" up -d db

    info "[2/2] Ожидание готовности MS SQL Server..."
    wait_for_local_mssql || return 1

    info "Запуск службы сервера ЛЭРС УЧЁТ..."
    docker compose -f "$COMPOSE_FILE" up -d lers

    sleep 10
    local lers_logs
    lers_logs="$(docker compose -f "$COMPOSE_FILE" logs --tail 40 lers 2>&1 || true)"
    if echo "$lers_logs" | grep -qiE "install.sh|waiting for configuration|initial setup"; then
        info "Выполнение первичного конфигуратора /install.sh..."
        docker compose -f "$COMPOSE_FILE" exec -T lers /install.sh || true
    fi

    verify_lers_health

    local server_ip
    server_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    server_ip="${server_ip:-127.0.0.1}"
    echo
    echo -e "${GREEN}======================================================================${NC}"
    echo -e "${BOLD}${GREEN}  ✓ СЕРВЕР ЛЭРС УЧЁТ УСПЕШНО РАЗВЁРНУТ!${NC}"
    echo -e "  Веб-интерфейс : ${BOLD}http://${server_ip}:${LERS_PORT}${NC}"
    echo -e "  MS SQL Server : 127.0.0.1:${DEFAULT_MSSQL_PORT} (${DEFAULT_MSSQL_PID})"
    echo -e "  Пароль SA     : Сохранён в ${MSSQL_SA_PASSWORD_FILE}"
    echo -e "${GREEN}======================================================================${NC}"
}

# [2] Установка LERS + восстановление существующей БД
menu_install_with_restore() {
    print_banner
    echo -e "${BOLD}${CYAN}>>> [2] УСТАНОВКА LERS + ВОССТАНОВЛЕНИЕ СУЩЕСТВУЮЩЕЙ БД${NC}"
    echo "────────────────────────────────────────────────────────────"
    check_mssql_memory_requirement || return 1
    if ! ensure_docker; then
        error "Установка остановлена: Docker недоступен."
        return 1
    fi
    init_directories

    # 1. Поиск локального файла бэкапа
    local found_baks=()
    mapfile -t found_baks < <(find "${BACKUP_DIR}" "${INCOMING_DIR}" "/root/lers-backup" "${SQL_BACKUP_DIR}" -maxdepth 2 -type f \( -iname "*.bak" -o -iname "*.tar.gz" -o -iname "*.zip" \) 2>/dev/null | sort)
    local raw_input_file=""

    if [[ ${#found_baks[@]} -gt 0 ]]; then
        echo "Найдены файлы резервных копий на VPS:"
        local f_idx=1
        for bf in "${found_baks[@]}"; do
            echo "  [$f_idx] $(basename "$bf") ($(du -h "$bf" | awk '{print $1}')) [$(dirname "$bf")]"
            f_idx=$((f_idx + 1))
        done
        echo "  [0] Указать другой полный путь к файлу"
        read -rp "Выбор [1-${#found_baks[@]} или 0]: " sel_bf
        if [[ "$sel_bf" =~ ^[1-9][0-9]*$ ]] && (( sel_bf <= ${#found_baks[@]} )); then
            raw_input_file="${found_baks[$((sel_bf-1))]}"
        fi
    fi

    if [[ -z "$raw_input_file" ]]; then
        read -rp "Введите полный путь к файлу бэкапа (.bak, .tar.gz, .zip): " raw_input_file
    fi

    [[ ! -s "$raw_input_file" ]] && { error "Файл бэкапа не найден: $raw_input_file"; return 1; }

    read -rp "Порт веб-интерфейса ЛЭРС [${DEFAULT_LERS_PORT}]: " in_port
    LERS_PORT="${in_port:-$DEFAULT_LERS_PORT}"

    get_or_create_sa_password
    generate_compose_files

    docker compose -f "$COMPOSE_FILE" down 2>/dev/null || true
    prepare_mssql_storage

    info "Загрузка Docker-образов..."
    docker compose -f "$COMPOSE_FILE" pull

    # 2. Запуск ТОЛЬКО базы данных
    info "[1/4] Запуск службы базы данных (MS SQL Express)..."
    docker compose -f "$COMPOSE_FILE" up -d db

    info "[2/4] Ожидание готовности MS SQL Server..."
    wait_for_local_mssql || return 1

    # 3. Подготовка и проверка
    local ready_bak=""
    info "[3/4] Подготовка и валидация файла бэкапа..."
    prepare_sql_bak_from_source "$raw_input_file" ready_bak || return 1
    verify_sql_backup "$ready_bak" || return 1

    # 4. Восстановление БД
    info "[4/4] Восстановление базы данных [${DEFAULT_DB_NAME}]..."
    local r_bak_name="restore_init_$(date +%s).bak"
    local r_host_p="${SQL_BACKUP_DIR}/${r_bak_name}"
    cp -f "$ready_bak" "$r_host_p"
    chmod 664 "$r_host_p"
    chown 10001:0 "$r_host_p" 2>/dev/null || true

    local moves
    moves="$(get_restore_file_moves "/var/opt/mssql/backup/${r_bak_name}" "${DEFAULT_DB_NAME}")"
    sql_local_exec "
        USE master;
        IF DB_ID('${DEFAULT_DB_NAME}') IS NOT NULL ALTER DATABASE [${DEFAULT_DB_NAME}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
        RESTORE DATABASE [${DEFAULT_DB_NAME}] FROM DISK = N'/var/opt/mssql/backup/${r_bak_name}' WITH REPLACE, ${moves};
        ALTER DATABASE [${DEFAULT_DB_NAME}] SET MULTI_USER;
    " "master"
    rm -f "$r_host_p"
    cleanup_orphaned_ndf_files "${DEFAULT_DB_NAME}"

    # 5. Запуск службы LERS поверх готовой БД
    info "Запуск службы ЛЭРС УЧЁТ поверх восстановленной базы..."
    docker compose -f "$COMPOSE_FILE" up -d lers

    sleep 10
    local lers_logs
    lers_logs="$(docker compose -f "$COMPOSE_FILE" logs --tail 40 lers 2>&1 || true)"
    if echo "$lers_logs" | grep -qiE "install.sh|waiting for configuration|initial setup"; then
        docker compose -f "$COMPOSE_FILE" exec -T lers /install.sh || true
    fi

    verify_lers_health

    local server_ip
    server_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    server_ip="${server_ip:-127.0.0.1}"
    echo
    echo -e "${GREEN}======================================================================${NC}"
    echo -e "${BOLD}${GREEN}  ✓ ЛЭРС УЧЁТ УСПЕШНО РАЗВЁРНУТ С СУЩЕСТВУЮЩЕЙ БАЗОЙ!${NC}"
    echo -e "  Веб-интерфейс : ${BOLD}http://${server_ip}:${LERS_PORT}${NC}"
    echo -e "  База данных   : [${DEFAULT_DB_NAME}] восстановлена и подключена"
    echo -e "  MS SQL Server : 127.0.0.1:${DEFAULT_MSSQL_PORT} (${DEFAULT_MSSQL_PID})"
    echo -e "${GREEN}======================================================================${NC}"
}

# Вспомогательное подключение к удаленному SQL Server
get_remote_sql_conn() {
    local __out_host="$1" __out_port="$2" __out_db="$3" __out_user="$4" __out_pass="$5" __out_stype="$6"

    echo "Источник MS SQL:"
    echo "  [1] Windows"
    echo "  [2] Linux"
    echo "  [3] Linux Docker"
    local _r_stype=""
    read -rp "Выбор [1-3, по умолчанию 1]: " _r_stype
    _r_stype="${_r_stype:-1}"

    if ! prepare_sqlcmd; then
        return 1
    fi

    local _r_host="" _r_port="1433" _r_db="LERS" _r_user="sa" _r_pass=""

    read -rp "  IP / Host: " _r_host
    while [[ -z "$_r_host" ]]; do
        warn "Адрес сервера не может быть пустым."
        read -rp "  IP / Host: " _r_host
    done

    local in_p=""
    read -rp "  Порт [1433]: " in_p
    _r_port="${in_p:-1433}"

    local in_db=""
    read -rp "  База данных [LERS]: " in_db
    _r_db="${in_db:-LERS}"
    [[ -n "$_r_db" ]] || _r_db="LERS"

    local in_u=""
    read -rp "  Пользователь [sa]: " in_u
    _r_user="${in_u:-sa}"

    local in_pw=""
    read_secret_masked "  Пароль SQL: " in_pw
    echo
    _r_pass="$in_pw"
    while [[ -z "$_r_pass" ]]; do
        warn "Пароль не может быть пустым."
        read_secret_masked "  Пароль SQL: " in_pw
        echo
        _r_pass="$in_pw"
    done

    # Проверка подключения
    echo
    step "ПОДКЛЮЧЕНИЕ" "Проверка подключения к SQL Server (${_r_host}:${_r_port})..."

    echo -n "  [1/2] Проверка сетевого порта TCP (${_r_port}) .... "
    if ! check_tcp_port "$_r_host" "$_r_port" 5; then
        echo -e "${YELLOW}TIMEOUT / НЕ ОТВЕЧАЕТ${NC}"
        warn "Порт ${_r_host}:${_r_port} не ответил по TCP за 5 сек."
        warn "Возможно, соединение блокируется брандмауэром или указан неверный порт."
    else
        echo -e "${GREEN}OK${NC}"
    fi

    echo -n "  [2/2] Аутентификация SQL Server (${_r_user}, БД: ${_r_db}) ... "

    local auth_output=""
    local auth_code=0
    local sqlcmd_bin="/usr/local/bin/sqlcmd"
    if [[ ! -x "$sqlcmd_bin" ]]; then
        sqlcmd_bin="$(command -v sqlcmd 2>/dev/null || true)"
    fi

    auth_output="$(
        SQLCMDPASSWORD="$_r_pass" \
        timeout 15s \
        "$sqlcmd_bin" \
            -S "${_r_host},${_r_port}" \
            -U "$_r_user" \
            -d "$_r_db" \
            -Q 'SET NOCOUNT ON; SELECT DB_NAME();' \
            -C \
            -l 10 \
            -t 10 \
            -h -1 \
            -W \
            -b \
        2>&1
    )" || auth_code=$?

    local clean_result
    clean_result="$(printf '%s' "$auth_output" | tr -d '\r' | sed '/^[[:space:]]*$/d' | tail -n 1 | xargs 2>/dev/null || true)"

    if [[ "$clean_result" == "$_r_db" ]] || (( auth_code == 0 && ${#clean_result} > 0 )); then
        echo -e "${GREEN}OK${NC}"
        echo
        success "SQL Server доступен."
        success "Аутентификация пользователя ${_r_user} успешна (база данных ${_r_db} подтверждена)."
    else
        echo -e "${RED}FAILED${NC}"
        echo
        error "Не удалось выполнить аутентификацию на SQL Server или открыть базу ${_r_db}."
        echo
        echo "Код завершения sqlcmd: ${auth_code}"
        if [[ -n "$auth_output" ]]; then
            echo
            echo "Ответ SQL Server:"
            echo "$auth_output" | sed 's/^/    /'
        fi
        return 1
    fi

    printf -v "$__out_host" '%s' "$_r_host"
    printf -v "$__out_port" '%s' "$_r_port"
    printf -v "$__out_db" '%s' "$_r_db"
    printf -v "$__out_user" '%s' "$_r_user"
    printf -v "$__out_pass" '%s' "$_r_pass"
    printf -v "$__out_stype" '%s' "$_r_stype"
    return 0
}

# [3] Создать BACKUP БД на удалённом MS SQL
menu_remote_backup() {
    print_banner
    echo -e "${BOLD}${CYAN}>>> [3] СОЗДАТЬ BACKUP БД НА УДАЛЁННОМ MS SQL${NC}"
    echo "────────────────────────────────────────────────────────────"

    local host="" port="" db="" user="" pass="" s_type=""
    if ! get_remote_sql_conn host port db user pass s_type; then
        return 1
    fi

    # Защита от пустой БД
    [[ -n "$db" ]] || db="LERS"

    echo
    step "ПРОВЕРКА БД" "Проверка существования базы данных [${db}] на сервере..."
    local check_db_query="SET NOCOUNT ON; SELECT name FROM sys.databases WHERE name = N'$(sql_escape "$db")';"
    local db_exists=""
    db_exists="$(remote_sqlcmd "$host" "$port" "$user" "$pass" "$db" "$check_db_query" "" 15 2>/dev/null | grep -vE '^-+|^[[:space:]]*$' | tail -n 1 | tr -d '\r\n' | xargs || true)"

    if [[ "$db_exists" == "$db" ]]; then
        success "База данных [${db}] найдена и подтверждена на сервере."
    else
        local db_id_val=""
        db_id_val="$(remote_sqlcmd "$host" "$port" "$user" "$pass" "$db" "SET NOCOUNT ON; SELECT DB_ID(N'$(sql_escape "$db")');" "" 15 2>/dev/null | grep -vE '^-+|^[[:space:]]*$' | tail -n 1 | tr -d '\r\n' | xargs || true)"
        if [[ -n "$db_id_val" && "$db_id_val" =~ ^[0-9]+$ && "$db_id_val" -gt 0 ]]; then
            success "База данных [${db}] найдена (ID: ${db_id_val})."
        else
            error "База данных [${db}] не найдена на SQL Server (${host}:${port})."
            echo "  Доступные базы данных на сервере:"
            remote_sqlcmd "$host" "$port" "$user" "$pass" "$db" "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE database_id > 4;" "" 15 2>/dev/null | sed 's/^/    /'
            return 1
        fi
    fi

    step "КАТАЛОГ" "Определение пути и имени для файла BACKUP..."

    # Определение версии SQL Server для имени бэкапа
    local mssql_ver_query="SET NOCOUNT ON; SELECT CASE WHEN CHARINDEX('2025', @@VERSION) > 0 THEN 'SQL2025' WHEN CHARINDEX('2022', @@VERSION) > 0 THEN 'SQL2022' WHEN CHARINDEX('2019', @@VERSION) > 0 THEN 'SQL2019' WHEN CHARINDEX('2017', @@VERSION) > 0 THEN 'SQL2017' ELSE 'SQL' + CAST(ISNULL(SERVERPROPERTY('ProductMajorVersion'), 'Server') AS varchar(10)) END;"
    local mssql_tag=""
    mssql_tag="$(remote_sqlcmd "$host" "$port" "$user" "$pass" "$db" "$mssql_ver_query" "" 10 2>/dev/null | grep -vE '^-+|^[[:space:]]*$' | tail -n 1 | tr -d '\r\n' | xargs || true)"
    [[ -z "$mssql_tag" ]] && mssql_tag="SQL2025"

    # Опрос версии базы данных ЛЭРС УЧЁТ
    local lers_ver_query="SET NOCOUNT ON; DECLARE @v varchar(50) = ''; IF OBJECT_ID(N'dbo.Version') IS NOT NULL SELECT TOP 1 @v = CAST([Version] AS varchar(50)) FROM dbo.[Version]; ELSE IF OBJECT_ID(N'dbo.SystemSettings') IS NOT NULL SELECT TOP 1 @v = CAST([Value] AS varchar(50)) FROM dbo.SystemSettings WHERE [Name] LIKE '%Version%'; ELSE IF OBJECT_ID(N'dbo.GlobalSettings') IS NOT NULL SELECT TOP 1 @v = CAST([Value] AS varchar(50)) FROM dbo.GlobalSettings WHERE [Name] LIKE '%Version%'; SELECT ISNULL(@v, '');"
    local lers_ver=""
    lers_ver="$(remote_sqlcmd "$host" "$port" "$user" "$pass" "$db" "$lers_ver_query" "" 10 2>/dev/null | grep -vE '^-+|^[[:space:]]*$' | tail -n 1 | tr -d '\r\n' | xargs || true)"

    local lers_tag=""
    local in_lver=""
    if [[ -n "$lers_ver" ]]; then
        lers_tag="LERS-${lers_ver// /_}"
        info "Версия ЛЭРС УЧЁТ: ${lers_ver}"
    else
        read -rp "  Версия сервера ЛЭРС УЧЁТ [например 3.59, по умолчанию пропустить]: " in_lver
        if [[ -n "$in_lver" ]]; then
            lers_tag="LERS-${in_lver// /_}"
        fi
    fi

    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    local b_filename=""
    if [[ -n "$lers_tag" ]]; then
        b_filename="${db}_${lers_tag}_${mssql_tag}_${ts}.bak"
    else
        b_filename="${db}_${mssql_tag}_${ts}.bak"
    fi

    local rem_bak_path=""
    case "$s_type" in
        1)
            # Windows
            local def_path_query="SET NOCOUNT ON; SELECT CAST(ISNULL(SERVERPROPERTY('InstanceDefaultBackupPath'), '') AS varchar(500));"
            local detected_dir=""
            detected_dir="$(remote_sqlcmd "$host" "$port" "$user" "$pass" "$db" "$def_path_query" "" 15 2>/dev/null | grep -vE '^-+|^[[:space:]]*$' | tail -n 1 | tr -d '\r\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true)"
            detected_dir="${detected_dir%[\/\\]}"

            echo "Каталог для BACKUP на Windows-сервере"
            echo "Введите полный путь, например:"
            echo "  C:\LERS\Backup"
            echo "  D:\SQLBackup"
            echo "  E:\SQL\SQL LERS"
            [[ -n "$detected_dir" ]] && echo "  (каталог экземпляра по умолчанию: ${detected_dir})"
            echo
            read -rp "Путь Windows для BACKUP: " in_wdir
            if [[ -z "$in_wdir" ]]; then
                if [[ -n "$detected_dir" ]]; then
                    in_wdir="$detected_dir"
                    info "Используется каталог по умолчанию: ${in_wdir}"
                else
                    in_wdir="C:\LERS\Backup"
                    info "Используется путь: ${in_wdir}"
                fi
            fi
            local win_dir="$in_wdir"
            win_dir="${win_dir%[\/\\]}"
            rem_bak_path="${win_dir}"'\'"${b_filename}"
            ;;
        2|3)
            # Linux / Linux Docker
            echo "Каталог для BACKUP на Linux-сервере"
            echo "Введите полный путь (например /var/opt/mssql/backup или /backups):"
            read -rp "Путь [/var/opt/mssql/backup]: " in_ldir
            local linux_dir="${in_ldir:-/var/opt/mssql/backup}"
            linux_dir="${linux_dir%[\/]}"
            rem_bak_path="${linux_dir}/${b_filename}"
            ;;
    esac

    echo
    step "BACKUP" "Создание резервной копии базы [${db}]..."
    info "Целевой файл: ${rem_bak_path}"
    local b_query="BACKUP DATABASE [$(sql_escape "$db")] TO DISK = N'$(sql_escape "$rem_bak_path")' WITH COPY_ONLY, INIT, COMPRESSION, STATS = 10;"

    info "Выполнение: BACKUP DATABASE [${db}] WITH COPY_ONLY, COMPRESSION..."
    echo -e "${CYAN}------------------------------------------------------------${NC}"
    local backup_log
    backup_log="$(mktemp /tmp/lers-bk-log.XXXXXX)"
    chmod 600 "$backup_log"
    trap 'rm -f "$backup_log"' RETURN

    local backup_code=0
    remote_sqlcmd "$host" "$port" "$user" "$pass" "$db" "$b_query" "" 900 2>&1 | tee "$backup_log"
    backup_code="${PIPESTATUS[0]}"
    echo -e "${CYAN}------------------------------------------------------------${NC}"

    local backup_err
    backup_err="$(<"$backup_log")"
    rm -f "$backup_log"
    if [[ $backup_code -ne 0 ]]; then
        if grep -qi "panic\|runtime error\|segmentation fault" <<< "$backup_err"; then
            error "КЛИЕНТ SQLCMD ЗАВЕРШИЛСЯ АВАРИЙНО (panic / runtime error):"
            echo "$backup_err" | sed 's/^/    /'
        elif grep -qi "Login failed\|Cannot open database\|network-related" <<< "$backup_err"; then
            error "ОШИБКА ПОДКЛЮЧЕНИЯ ИЛИ АВТОРИЗАЦИИ SQL SERVER:"
            echo "$backup_err" | sed 's/^/    /'
        else
            error "SQL Server отклонил команду BACKUP или вернул ошибку:"
            echo
            echo "Целевой путь:"
            echo "  ${rem_bak_path}"
            echo
            echo "Возможные причины:"
            echo "  • указанный каталог не существует на диске сервера;"
            echo "  • диск недоступен или переполнен;"
            echo "  • у службы SQL Server нет прав на запись в эту папку (NTFS permissions);"
            echo "  • опечатка в пути."
            echo
            echo "Ответ SQL Server:"
            echo "$backup_err" | sed 's/^/    /'
        fi
        return 1
    fi
    success "Резервная копия успешно создана на сервере: ${rem_bak_path}"

    echo
    step "ПРОВЕРКА" "Проверка резервной копии (RESTORE VERIFYONLY)..."
    local v_query="RESTORE VERIFYONLY FROM DISK = N'$(sql_escape "$rem_bak_path")';"
    info "Выполнение RESTORE VERIFYONLY на сервере..."
    echo -e "${CYAN}------------------------------------------------------------${NC}"

    local verify_log
    verify_log="$(mktemp /tmp/lers-vfy-log.XXXXXX)"
    chmod 600 "$verify_log"
    trap 'rm -f "$verify_log"' RETURN

    local verify_code=0
    remote_sqlcmd "$host" "$port" "$user" "$pass" "$db" "$v_query" "" 300 2>&1 | tee "$verify_log"
    verify_code="${PIPESTATUS[0]}"
    echo -e "${CYAN}------------------------------------------------------------${NC}"

    local verify_res
    verify_res="$(<"$verify_log")"
    rm -f "$verify_log"
    if [[ $verify_code -ne 0 ]]; then
        error "Резервная копия не прошла проверку RESTORE VERIFYONLY на сервере:"
        echo "$verify_res" | sed 's/^/    /'
        return 1
    fi
    success "Резервная копия проверена и валидна (RESTORE VERIFYONLY успешно)."

    # Запрос размера созданного бэкапа из msdb
    local size_query="SET NOCOUNT ON; SELECT TOP 1 CAST(ROUND(compressed_backup_size / 1048576.0, 1) AS varchar(20)) + '|' + CAST(ROUND(backup_size / 1048576.0, 1) AS varchar(20)) FROM msdb.dbo.backupset WITH (NOLOCK) WHERE database_name = N'$(sql_escape "$db")' AND type = 'D' ORDER BY backup_finish_date DESC;"
    local b_info=""
    b_info="$(remote_sqlcmd "$host" "$port" "$user" "$pass" "$db" "$size_query" "" 15 2>/dev/null | grep -vE '^-+|^[[:space:]]*$' | tail -n 1 | tr -d '\r\n' | xargs || true)"

    local b_comp_mb="Н/Д" b_raw_mb="Н/Д"
    if [[ "$b_info" == *"|"* ]]; then
        b_comp_mb="${b_info%%|*} MB"
        b_raw_mb="${b_info##*|} MB"
    fi

    local display_lver="${lers_ver:-${in_lver:-Н/Д}}"

    echo
    echo -e "${GREEN}======================================================================${NC}"
    echo -e "${BOLD}${GREEN}        BACKUP УСПЕШНО СОЗДАН И ПРОВЕРЕН НА MS SQL${NC}"
    echo -e "${GREEN}======================================================================${NC}"
    echo -e "  Сервер        : ${BOLD}${host}:${port}${NC}"
    echo -e "  База данных   : ${BOLD}${db}${NC}"
    echo -e "  Версия SQL    : ${BOLD}${mssql_tag}${NC}"
    echo -e "  Версия ЛЭРС   : ${BOLD}${display_lver}${NC}"
    echo -e "  Файл бэкапа   : ${BOLD}${rem_bak_path}${NC}"
    echo -e "  Сжатый размер : ${BOLD}${b_comp_mb}${NC}"
    echo -e "  Исходный      : ${b_raw_mb}"
    echo -e "  Тип           : FULL / COPY_ONLY (сжатие включено)"
    echo -e "  Статус        : ${BOLD}${GREEN}OK (RESTORE VERIFYONLY успешно пройден)${NC}"
    echo
    echo -e "  ${YELLOW}Файл сохранён на удалённом сервере.${NC}"
    echo -e "${GREEN}======================================================================${NC}"
    return 0
}

# [4] Проверить удалённый MS SQL (Диагностика)
menu_remote_diagnostics() {
    print_banner
    echo -e "${BOLD}${CYAN}>>> [4] 🔎 ПРОВЕРКА УДАЛЁННОГО MS SQL${NC}"
    echo "────────────────────────────────────────────────────────────"

    local host="" port="" db="" user="" pass="" s_type=""
    if ! get_remote_sql_conn host port db user pass s_type; then
        return 1
    fi

    while true; do
        echo
        echo -e "${BOLD}  ДИАГНОСТИКА MS SQL (${host}:${port}, БД: ${db})${NC}"
        echo "  ────────────────────────────────────────────────────────────"
        echo "  [1] 🔌 Проверить подключение"
        echo "  [2] ℹ️  Информация о SQL Server"
        echo "  [3] 📊 Состояние базы ${db}"
        echo "  [4] 🛡️  Проверка целостности базы (DBCC CHECKDB)"
        echo "  [5] 💾 Последние резервные копии (BACKUP history)"
        echo "  [6] ♻️  Последние операции восстановления (RESTORE history)"
        echo "  [7] ⚠️  Журнал ошибок SQL Server (ErrorLog)"
        echo "  [8] 💽 Свободное место на дисках сервера"
        echo "  [9] 📋 ПОЛНАЯ ДИАГНОСТИКА (сводная таблица)"
        echo "  [0] ↩️  Назад в главное меню"
        echo "  ────────────────────────────────────────────────────────────"
        local d_choice=""
        read -rp "Выберите пункт [0-9]: " d_choice

        case "$d_choice" in
            1)
                echo
                step "ТЕСТ" "Проверка соединения..."
                check_tcp_port "$host" "$port" 5 && echo -e "  TCP порт (${port}) ................... ${GREEN}OK${NC}" || echo -e "  TCP порт (${port}) ................... ${RED}FAILED${NC}"
                sql_auth_check "$host" "$port" "$db" "$user" "$pass" && echo -e "  SQL авторизация (${user}, ${db}) .... ${GREEN}OK${NC}" || echo -e "  SQL авторизация (${user}, ${db}) .... ${RED}FAILED${NC}"
                ;;
            2)
                echo
                step "ИНФО" "Информация о SQL Server..."
                remote_sqlcmd "$host" "$port" "$user" "$pass" "$db" "
                    SET NOCOUNT ON;
                    SELECT
                      CAST(SERVERPROPERTY('MachineName') AS varchar(30)) AS [Machine],
                      CAST(SERVERPROPERTY('ServerName') AS varchar(30)) AS [Instance],
                      CAST(SERVERPROPERTY('ProductVersion') AS varchar(20)) AS [Version],
                      CAST(SERVERPROPERTY('ProductLevel') AS varchar(15)) AS [Level],
                      CAST(SERVERPROPERTY('Edition') AS varchar(35)) AS [Edition];
                "
                ;;
            3)
                echo
                step "БАЗА ДАННЫХ" "Состояние базы данных ${db}..."
                remote_sqlcmd "$host" "$port" "$user" "$pass" "master" "
                    SET NOCOUNT ON;
                    SELECT
                      name AS [Database],
                      state_desc AS [State],
                      recovery_model_desc AS [Recovery_Model],
                      compatibility_level AS [Compat_Level],
                      collation_name AS [Collation]
                    FROM sys.databases
                    WHERE name = N'$(sql_escape "$db")';
                "
                ;;
            4)
                echo
                step "DBCC" "Запуск проверки целостности DBCC CHECKDB [${db}]..."
                info "Выполняется DBCC CHECKDB WITH NO_INFOMSGS, PHYSICAL_ONLY..."
                local dbcc_out="" dbcc_rc=0
                dbcc_out="$(remote_sqlcmd "$host" "$port" "$user" "$pass" "$db" "DBCC CHECKDB (N'$(sql_escape "$db")') WITH NO_INFOMSGS, PHYSICAL_ONLY;" "" 600 2>&1)" || dbcc_rc=$?
                if [[ $dbcc_rc -eq 0 && -z "$dbcc_out" ]]; then
                    success "DBCC CHECKDB: Ошибок целостности не обнаружено (OK)."
                elif [[ $dbcc_rc -eq 0 ]] && echo "$dbcc_out" | grep -qiE "0 errors|no errors"; then
                    success "DBCC CHECKDB: Ошибок целостности не обнаружено (OK)."
                else
                    error "DBCC CHECKDB: Обнаружены ошибки целостности базы (код $dbcc_rc):"
                    echo "$dbcc_out" | sed 's/^/    /'
                fi
                ;;
            5)
                echo
                step "BACKUP ИСТОРИЯ" "Последние 5 резервных копий базы ${db}..."
                remote_sqlcmd "$host" "$port" "$user" "$pass" "msdb" "
                    SET NOCOUNT ON;
                    SELECT TOP 5
                      type AS [Type],
                      CONVERT(varchar(19), backup_start_date, 120) AS [Start_Time],
                      CONVERT(varchar(19), backup_finish_date, 120) AS [Finish_Time],
                      CAST(ROUND(backup_size / 1048576.0, 1) AS varchar(15)) + ' MB' AS [Raw_Size],
                      CAST(ROUND(compressed_backup_size / 1048576.0, 1) AS varchar(15)) + ' MB' AS [Compressed]
                    FROM msdb.dbo.backupset
                    WHERE database_name = N'$(sql_escape "$db")'
                    ORDER BY backup_finish_date DESC;
                "
                ;;
            6)
                echo
                step "RESTORE ИСТОРИЯ" "Последние операции восстановления базы ${db}..."
                remote_sqlcmd "$host" "$port" "$user" "$pass" "msdb" "
                    SET NOCOUNT ON;
                    SELECT TOP 5
                      destination_database_name AS [Target_DB],
                      CONVERT(varchar(19), restore_date, 120) AS [Restore_Date],
                      restore_type AS [Type],
                      user_name AS [Restored_By]
                    FROM msdb.dbo.restorehistory
                    WHERE destination_database_name = N'$(sql_escape "$db")'
                    ORDER BY restore_date DESC;
                "
                ;;
            7)
                echo
                step "ОШИБКИ" "Последние ошибки из журнала SQL Server ErrorLog..."
                remote_sqlcmd "$host" "$port" "$user" "$pass" "master" "
                    SET NOCOUNT ON;
                    EXEC xp_readerrorlog 0, 1, N'error', NULL, NULL, NULL, N'desc';
                " "" 30 || warn "Не удалось прочитать xp_readerrorlog."
                ;;
            8)
                echo
                step "ДИСКИ" "Свободное место на дисках сервера..."
                remote_sqlcmd "$host" "$port" "$user" "$pass" "master" "
                    SET NOCOUNT ON;
                    SELECT DISTINCT
                      volume_mount_point AS [Drive],
                      CAST(ROUND(available_bytes / 1073741824.0, 1) AS varchar(15)) + ' GB' AS [Free_GB],
                      CAST(ROUND(total_bytes / 1073741824.0, 1) AS varchar(15)) + ' GB' AS [Total_GB],
                      CAST(ROUND((available_bytes * 100.0) / total_bytes, 1) AS varchar(10)) + '%' AS [Free_Pct]
                    FROM sys.master_files AS f
                    CROSS APPLY sys.dm_os_volume_stats(f.database_id, f.file_id);
                "
                ;;
            9)
                echo
                step "СВОДКА" "Выполнение комплексной диагностики SQL Server..."

                # 1. Проверка версии
                local srv_ver
                srv_ver="$(remote_sqlcmd "$host" "$port" "$user" "$pass" "master" "SET NOCOUNT ON; SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(20)) + ' ' + CAST(SERVERPROPERTY('Edition') AS varchar(30));" "" 15 2>/dev/null | grep -vE '^-+|^[[:space:]]*$' | tail -n 1 | tr -d '\r\n' | xargs || echo "SQL Server")"

                # 2. Состояние базы
                local db_state db_rec
                db_state="$(remote_sqlcmd "$host" "$port" "$user" "$pass" "master" "SET NOCOUNT ON; SELECT state_desc FROM sys.databases WHERE name = N'$(sql_escape "$db")';" "" 15 2>/dev/null | grep -vE '^-+|^[[:space:]]*$' | tail -n 1 | tr -d '\r\n' | xargs || echo "UNKNOWN")"
                db_rec="$(remote_sqlcmd "$host" "$port" "$user" "$pass" "master" "SET NOCOUNT ON; SELECT recovery_model_desc FROM sys.databases WHERE name = N'$(sql_escape "$db")';" "" 15 2>/dev/null | grep -vE '^-+|^[[:space:]]*$' | tail -n 1 | tr -d '\r\n' | xargs || echo "UNKNOWN")"

                # 3. DBCC CHECKDB
                local dbcc_status="OK"
                local dbcc_res="" dbcc_code=0
                dbcc_res="$(remote_sqlcmd "$host" "$port" "$user" "$pass" "$db" "DBCC CHECKDB (N'$(sql_escape "$db")') WITH NO_INFOMSGS, PHYSICAL_ONLY;" "" 600 2>&1)" || dbcc_code=$?
                if [[ $dbcc_code -ne 0 ]]; then
                    dbcc_status="СБОЙ"
                elif [[ -n "$dbcc_res" ]] && ! echo "$dbcc_res" | grep -qiE "0 errors|no errors"; then
                    dbcc_status="ОШИБКИ"
                fi

                # 4. Последний FULL и LOG BACKUP
                local last_full_bk last_log_bk
                last_full_bk="$(remote_sqlcmd "$host" "$port" "$user" "$pass" "msdb" "SET NOCOUNT ON; SELECT TOP 1 CONVERT(varchar(16), backup_finish_date, 120) FROM msdb.dbo.backupset WHERE database_name = N'$(sql_escape "$db")' AND type = 'D' ORDER BY backup_finish_date DESC;" "" 15 2>/dev/null | grep -vE '^-+|^[[:space:]]*$' | tail -n 1 | tr -d '\r\n' | xargs || true)"
                last_log_bk="$(remote_sqlcmd "$host" "$port" "$user" "$pass" "msdb" "SET NOCOUNT ON; SELECT TOP 1 CONVERT(varchar(16), backup_finish_date, 120) FROM msdb.dbo.backupset WHERE database_name = N'$(sql_escape "$db")' AND type = 'L' ORDER BY backup_finish_date DESC;" "" 15 2>/dev/null | grep -vE '^-+|^[[:space:]]*$' | tail -n 1 | tr -d '\r\n' | xargs || true)"
                [[ -z "$last_full_bk" ]] && last_full_bk="Нет данных"
                [[ -z "$last_log_bk" ]] && last_log_bk="Нет данных"

                # 5. Свободное место на диске базы данных
                local free_space_str="Н/Д"
                local free_space_q="SET NOCOUNT ON; SELECT TOP 1 CAST(ROUND(available_bytes / 1073741824.0, 1) AS varchar(15)) + ' GB' FROM sys.master_files AS f CROSS APPLY sys.dm_os_volume_stats(f.database_id, f.file_id) WHERE f.database_id = DB_ID(N'$(sql_escape "$db")');"
                free_space_str="$(remote_sqlcmd "$host" "$port" "$user" "$pass" "master" "$free_space_q" "" 15 2>/dev/null | grep -vE '^-+|^[[:space:]]*$' | tail -n 1 | tr -d '\r\n' | xargs || echo "Н/Д")"
                [[ -z "$free_space_str" ]] && free_space_str="Н/Д"

                echo
                echo -e "${CYAN}======================================================================${NC}"
                echo -e "${BOLD}${CYAN}             MS SQL SERVER — ДИАГНОСТИКА${NC}"
                echo -e "${CYAN}======================================================================${NC}"
                echo -e "  Сервер       : ${BOLD}${host}:${port}${NC}"
                echo -e "  SQL Server   : ${srv_ver}"
                echo -e "  База данных  : ${BOLD}${db}${NC}"
                echo
                echo -e "  [1] Подключение ....................... ${GREEN}OK${NC}"
                echo -e "  [2] Авторизация ....................... ${GREEN}OK${NC}"
                if [[ "$db_state" == "ONLINE" ]]; then
                    echo -e "  [3] База ONLINE ....................... ${GREEN}OK${NC}"
                else
                    echo -e "  [3] База ONLINE ....................... ${RED}${db_state}${NC}"
                fi
                echo -e "  [4] Recovery model .................... ${BOLD}${db_rec}${NC}"
                if [[ "$dbcc_status" == "OK" ]]; then
                    echo -e "  [5] DBCC CHECKDB ...................... ${GREEN}OK${NC}"
                else
                    echo -e "  [5] DBCC CHECKDB ...................... ${RED}${dbcc_status}${NC}"
                fi
                echo -e "  [6] Последний FULL BACKUP ............. ${last_full_bk}"
                echo -e "  [7] Последний LOG BACKUP .............. ${last_log_bk}"
                echo -e "  [8] Журнал ошибок ..................... доступен (см. пункт 7)"
                echo -e "  [9] Свободное место тома БД ........... ${BOLD}${free_space_str}${NC}"
                echo
                if [[ "$db_state" == "ONLINE" && "$dbcc_status" == "OK" ]]; then
                    echo -e "${BOLD}${GREEN}ИТОГ: SQL SERVER В НОРМЕ${NC}"
                else
                    echo -e "${BOLD}${YELLOW}ИТОГ: ТРЕБУЕТСЯ ВНИМАНИЕ АДМИНИСТРАТОРА${NC}"
                fi
                echo -e "${CYAN}======================================================================${NC}"
                ;;
            0)
                break
                ;;
            *)
                error "Неверный выбор."
                ;;
        esac
        echo
        read -rp "Нажмите Enter для продолжения..." _dummy || true
    done
}

# [5] Зашифровать локальный BACKUP
# ==============================================================================
# УПРАВЛЕНИЕ ЛОКАЛЬНЫМ MS SQL SERVER И БАЗОЙ LERS
# ==============================================================================

action_mssql_status() {
    print_banner
    echo -e "${BOLD}${CYAN}>>> СТАТУС MS SQL SERVER И БАЗЫ ДАННЫХ LERS${NC}"
    echo "────────────────────────────────────────────────────────────"
    if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'lers-db'; then
        warn "Контейнер lers-db не создан. Выполните установку (пункт [1] или [2])."
        return 0
    fi

    local c_status c_health c_image c_ports
    c_status="$(docker inspect -f '{{.State.Status}}' lers-db 2>/dev/null || echo "неизвестно")"
    c_health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}без healthcheck{{end}}' lers-db 2>/dev/null || echo "неизвестно")"
    c_image="$(docker inspect -f '{{.Config.Image}}' lers-db 2>/dev/null || echo "неизвестно")"
    c_ports="$(docker port lers-db 2>/dev/null | tr '
' ' ' || echo "127.0.0.1:1433")"

    echo -e "${BOLD}MS SQL Server:${NC}"
    echo "  Контейнер : lers-db"
    echo "  Образ     : $c_image"
    if [[ "$c_status" == "running" ]]; then
        echo -e "  Статус    : ${GREEN}${c_status^^}${NC}"
    else
        echo -e "  Статус    : ${RED}${c_status^^}${NC}"
    fi
    if [[ "$c_health" == "healthy" ]]; then
        echo -e "  Здоровье  : ${GREEN}${c_health^^}${NC}"
    elif [[ "$c_health" == "unhealthy" ]]; then
        echo -e "  Здоровье  : ${RED}${c_health^^}${NC}"
    else
        echo -e "  Здоровье  : ${YELLOW}${c_health}${NC}"
    fi
    echo "  Порты     : ${c_ports:-127.0.0.1:1433}"

    if [[ "$c_status" == "running" ]]; then
        echo
        echo -e "${BOLD}Информация о движке SQL Server:${NC}"
        local sql_ver
        sql_ver="$(sql_local_exec "SELECT @@VERSION" "master" -h -1 -W 2>/dev/null | head -n 1 | tr -d '
' || true)"
        if [[ -n "$sql_ver" ]]; then
            echo "  Версия    : $sql_ver"
        else
            echo "  Версия    : Ожидание инициализации или ошибка авторизации SA"
        fi

        echo
        echo -e "${BOLD}База данных [${DEFAULT_DB_NAME}]:${NC}"
        local db_info
        db_info="$(sql_local_exec "
            IF DB_ID('${DEFAULT_DB_NAME}') IS NOT NULL
            BEGIN
                SELECT state_desc + '|' + collation_name + '|' + CAST(compatibility_level AS VARCHAR)
                FROM sys.databases WHERE name = '${DEFAULT_DB_NAME}';
            END
            ELSE
                SELECT 'NOT_FOUND||';
        " "master" -h -1 -s "|" -W 2>/dev/null | tr -d '
' | grep -v '^$' | head -n 1 || true)"

        if [[ -n "$db_info" && "$db_info" != "NOT_FOUND||" ]]; then
            IFS='|' read -r db_state db_collation db_compat <<< "$db_info"
            if [[ "$db_state" == "ONLINE" ]]; then
                echo -e "  Состояние : ${GREEN}${db_state}${NC}"
            else
                echo -e "  Состояние : ${YELLOW}${db_state}${NC}"
            fi
            echo "  Collation : ${db_collation}"
            echo "  Совместим.: Уровень ${db_compat}"

            local db_size_mb
            db_size_mb="$(sql_local_exec "
                SELECT CAST(SUM(size) * 8.0 / 1024 AS DECIMAL(10,2))
                FROM sys.master_files
                WHERE database_id = DB_ID('${DEFAULT_DB_NAME}');
            " "master" -h -1 -W 2>/dev/null | tr -d '
' | grep -v '^$' | head -n 1 || true)"
            if [[ -n "$db_size_mb" ]]; then
                echo "  Размер    : ${db_size_mb} MB"
            fi
        else
            echo -e "  Состояние : ${YELLOW}База данных [${DEFAULT_DB_NAME}] ещё не создана${NC}"
        fi
    fi
}

action_mssql_start() {
    print_banner
    echo -e "${BOLD}${CYAN}>>> ЗАПУСК СЛУЖБЫ MS SQL SERVER${NC}"
    echo "────────────────────────────────────────────────────────────"
    prepare_mssql_storage
    info "Запуск контейнера lers-db..."
    docker compose -f "$COMPOSE_FILE" up -d db
    wait_for_local_mssql
}

action_mssql_stop() {
    print_banner
    echo -e "${BOLD}${CYAN}>>> ОСТАНОВКА СЛУЖБЫ MS SQL SERVER${NC}"
    echo "────────────────────────────────────────────────────────────"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'lers-server'; then
        warn "Сервер ЛЭРС УЧЁТ работает с этой базой данных."
        read -rp "Остановить также сервер ЛЭРС? [Y/n]: " stop_lers_ans
        if [[ "${stop_lers_ans:-Y}" =~ ^[YyДд]$ ]]; then
            docker compose -f "$COMPOSE_FILE" stop lers >/dev/null 2>&1 || true
            info "Контейнер lers-server остановлен."
        fi
    fi
    info "Остановка контейнера lers-db..."
    docker compose -f "$COMPOSE_FILE" stop db
    success "MS SQL Server остановлен."
}

action_mssql_restart() {
    print_banner
    echo -e "${BOLD}${CYAN}>>> ПЕРЕЗАПУСК СЛУЖБЫ MS SQL SERVER${NC}"
    echo "────────────────────────────────────────────────────────────"
    prepare_mssql_storage
    info "Перезапуск контейнера lers-db..."
    docker compose -f "$COMPOSE_FILE" restart db
    wait_for_local_mssql
}

action_mssql_logs() {
    print_banner
    echo -e "${BOLD}${CYAN}>>> ПОСЛЕДНИЕ 100 СТРОК ЖУРНАЛА lers-db${NC}"
    echo "────────────────────────────────────────────────────────────"
    docker compose -f "$COMPOSE_FILE" logs --tail 100 db || true
}

action_mssql_check_db() {
    print_banner
    echo -e "${BOLD}${CYAN}>>> ПРОВЕРКА СОСТОЯНИЯ БАЗЫ ДАННЫХ [${DEFAULT_DB_NAME}]${NC}"
    echo "────────────────────────────────────────────────────────────"
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'lers-db'; then
        error "MS SQL Server (lers-db) не запущен."
        return 1
    fi

    local db_id
    db_id="$(sql_local_exec "SELECT DB_ID('${DEFAULT_DB_NAME}')" "master" -h -1 -W 2>/dev/null | tr -d '
' | grep -v '^$' | head -n 1 || true)"
    if [[ -z "$db_id" || "$db_id" == "NULL" ]]; then
        error "База данных [${DEFAULT_DB_NAME}] не существует в SQL Server."
        return 1
    fi

    echo "Параметры базы данных [${DEFAULT_DB_NAME}]:"
    sql_local_exec "
        SELECT 
            name AS [Имя БД],
            state_desc AS [Статус],
            recovery_model_desc AS [Модель восстановления],
            collation_name AS [Кодировка],
            compatibility_level AS [Уровень совместимости],
            user_access_desc AS [Режим доступа]
        FROM sys.databases
        WHERE name = '${DEFAULT_DB_NAME}';
    " "master"

    echo
    echo "Файлы базы данных:"
    sql_local_exec "
        SELECT 
            name AS [Логическое имя],
            type_desc AS [Тип],
            physical_name AS [Путь к файлу],
            CAST(size * 8.0 / 1024 AS DECIMAL(10,2)) AS [Размер (MB)]
        FROM sys.master_files
        WHERE database_id = DB_ID('${DEFAULT_DB_NAME}');
    " "master"

    local table_count
    table_count="$(sql_local_exec "USE [${DEFAULT_DB_NAME}]; SELECT COUNT(*) FROM sys.tables;" "${DEFAULT_DB_NAME}" -h -1 -W 2>/dev/null | tr -d '
' | grep -v '^$' | head -n 1 || echo 0)"
    echo
    echo "Количество пользовательских таблиц в БД: ${table_count}"
    if (( table_count > 0 )); then
        success "База данных [${DEFAULT_DB_NAME}] заполнена и активна."
    else
        warn "База данных [${DEFAULT_DB_NAME}] существует, но не содержит таблиц."
    fi
}

action_mssql_dbcc() {
    print_banner
    echo -e "${BOLD}${CYAN}>>> ПРОВЕРКА ЦЕЛОСТНОСТИ БАЗЫ ДАННЫХ (DBCC CHECKDB)${NC}"
    echo "────────────────────────────────────────────────────────────"
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'lers-db'; then
        error "MS SQL Server (lers-db) не запущен."
        return 1
    fi

    local db_id
    db_id="$(sql_local_exec "SELECT DB_ID('${DEFAULT_DB_NAME}')" "master" -h -1 -W 2>/dev/null | tr -d '
' | grep -v '^$' | head -n 1 || true)"
    if [[ -z "$db_id" || "$db_id" == "NULL" ]]; then
        error "База данных [${DEFAULT_DB_NAME}] не найдена."
        return 1
    fi

    info "Запуск DBCC CHECKDB([${DEFAULT_DB_NAME}])... Это может занять некоторое время..."
    local dbcc_out dbcc_code=0
    dbcc_out="$(sql_local_exec "DBCC CHECKDB([${DEFAULT_DB_NAME}]) WITH NO_INFOMSGS, ALL_ERRORMSGS;" "master" 2>&1)" || dbcc_code=$?

    if [[ $dbcc_code -eq 0 && -z "$(echo "$dbcc_out" | grep -v '^[[:space:]]*$' || true)" ]]; then
        echo
        success "DBCC CHECKDB завершён: ошибок согласованности не обнаружено. База данных полностью исправна!"
    else
        echo
        if echo "$dbcc_out" | grep -qiE "0 allocation errors and 0 consistency errors"; then
            success "DBCC CHECKDB завершён: 0 allocation errors and 0 consistency errors."
        else
            error "Обнаружены ошибки при проверке DBCC CHECKDB:"
            echo "$dbcc_out"
        fi
    fi
}

action_mssql_size() {
    print_banner
    echo -e "${BOLD}${CYAN}>>> ДЕТАЛЬНЫЙ РАЗМЕР БАЗЫ ДАННЫХ [${DEFAULT_DB_NAME}]${NC}"
    echo "────────────────────────────────────────────────────────────"
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'lers-db'; then
        error "MS SQL Server (lers-db) не запущен."
        return 1
    fi

    local db_id
    db_id="$(sql_local_exec "SELECT DB_ID('${DEFAULT_DB_NAME}')" "master" -h -1 -W 2>/dev/null | tr -d '
' | grep -v '^$' | head -n 1 || true)"
    if [[ -z "$db_id" || "$db_id" == "NULL" ]]; then
        error "База данных [${DEFAULT_DB_NAME}] не найдена."
        return 1
    fi

    echo "Статистика дискового пространства (sp_spaceused):"
    sql_local_exec "USE [${DEFAULT_DB_NAME}]; EXEC sp_spaceused;" "${DEFAULT_DB_NAME}"
    echo
    echo "Файлы базы данных на диске:"
    sql_local_exec "
        SELECT 
            name AS [Логическое имя],
            type_desc AS [Тип],
            CAST(size * 8.0 / 1024 AS DECIMAL(10,2)) AS [Выделено (MB)],
            CAST(FILEPROPERTY(name, 'SpaceUsed') * 8.0 / 1024 AS DECIMAL(10,2)) AS [Занято (MB)],
            physical_name AS [Путь в контейнере]
        FROM [${DEFAULT_DB_NAME}].sys.database_files;
    " "${DEFAULT_DB_NAME}"
}

action_mssql_restore_bak() {
    print_banner
    echo -e "${BOLD}${CYAN}>>> ВОССТАНОВИТЬ БАЗУ ДАННЫХ LERS ИЗ .BAK ФАЙЛА${NC}"
    echo "────────────────────────────────────────────────────────────"
    warn "ВНИМАНИЕ: Восстановление перезапишет существующую базу данных [${DEFAULT_DB_NAME}]."
    warn "Перед перезаписью будет автоматически создан safety-бэкап текущей базы."
    read -rp "Продолжить? [y/N]: " confirm_r
    if [[ ! "$confirm_r" =~ ^[YyДд]$ ]]; then
        info "Операция отменена пользователем."
        return 0
    fi

    local found_files=()
    mapfile -t found_files < <(find "${BACKUP_DIR}" "${INCOMING_DIR}" "/root/lers-backup" "${SQL_BACKUP_DIR}" -maxdepth 2 -type f \( -iname "*.bak" -o -iname "*.tar.gz" -o -iname "*.zip" \) 2>/dev/null | sort)

    local target_file=""
    if [[ ${#found_files[@]} -gt 0 ]]; then
        echo "Найдены резервные копии на VPS:"
        local idx=1
        for f in "${found_files[@]}"; do
            echo "  [$idx] $(basename "$f") ($(du -h "$f" | awk '{print $1}')) [$(dirname "$f")]"
            idx=$((idx + 1))
        done
        echo "  [0] Ввести другой путь вручную"
        read -rp "Выберите файл [1-${#found_files[@]} или 0]: " sel_f
        if [[ "$sel_f" =~ ^[1-9][0-9]*$ ]] && (( sel_f <= ${#found_files[@]} )); then
            target_file="${found_files[$((sel_f-1))]}"
        fi
    fi

    if [[ -z "$target_file" ]]; then
        read -rp "Введите полный путь к файлу (.bak, .tar.gz, .zip): " target_file
    fi

    [[ ! -s "$target_file" ]] && { error "Файл не найден: $target_file"; return 1; }

    prepare_mssql_storage
    local ready_bak=""
    prepare_sql_bak_from_source "$target_file" ready_bak || return 1
    perform_database_restore "$ready_bak"
}

# [5] Подменю управления MS SQL и БД LERS
menu_manage_mssql() {
    while true; do
        print_banner
        echo
        echo -e "${BOLD}${CYAN}======================================================================${NC}"
        echo -e "${BOLD}${CYAN}                    MS SQL / LERS DATABASE${NC}"
        echo -e "${BOLD}${CYAN}======================================================================${NC}"
        echo
        echo -e "${BOLD}  MS SQL SERVER${NC}"
        echo "  ────────────────────────────────────────────────────────────"
        echo "  [1] 📊 Статус MS SQL"
        echo "  [2] ▶️  Запустить MS SQL"
        echo "  [3] ⏹️  Остановить MS SQL"
        echo "  [4] 🔄 Перезапустить MS SQL"
        echo "  [5] 📜 Логи MS SQL"
        echo
        echo -e "${BOLD}  БАЗА LERS${NC}"
        echo "  ────────────────────────────────────────────────────────────"
        echo "  [6] 🔎 Проверить БД LERS"
        echo "  [7] 🩺 DBCC CHECKDB"
        echo "  [8] 📦 Показать размер БД"
        echo "  [9] ♻️  Восстановить БД из .bak"
        echo
        echo "  [0] Назад"
        echo "  ────────────────────────────────────────────────────────────"
        local s_choice=""
        read -rp "Выберите пункт [0-9]: " s_choice

        case "$s_choice" in
            1) action_mssql_status ;;
            2) action_mssql_start ;;
            3) action_mssql_stop ;;
            4) action_mssql_restart ;;
            5) action_mssql_logs ;;
            6) action_mssql_check_db ;;
            7) action_mssql_dbcc ;;
            8) action_mssql_size ;;
            9) action_mssql_restore_bak ;;
            0) return 0 ;;
            *) error "Неверный выбор." ;;
        esac
        echo
        read -rp "Нажмите Enter для продолжения..." _dummy || true
    done
}

# ==============================================================================
# УПРАВЛЕНИЕ СЕРВЕРОМ ЛЭРС УЧЁТ
# ==============================================================================

action_lers_status() {
    print_banner
    echo -e "${BOLD}${CYAN}>>> СТАТУС СЕРВЕРА ЛЭРС УЧЁТ${NC}"
    echo "────────────────────────────────────────────────────────────"
    if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'lers-server'; then
        warn "Контейнер lers-server не создан. Сначала выполните установку (пункт [1] или [2])."
        return 0
    fi

    local c_status c_image c_ports
    c_status="$(docker inspect -f '{{.State.Status}}' lers-server 2>/dev/null || echo "неизвестно")"
    c_image="$(docker inspect -f '{{.Config.Image}}' lers-server 2>/dev/null || echo "неизвестно")"
    c_ports="$(docker port lers-server 2>/dev/null | tr '
' ' ' || echo "${LERS_PORT:-$DEFAULT_LERS_PORT}:10000")"

    echo "  Контейнер : lers-server"
    echo "  Образ     : $c_image"
    if [[ "$c_status" == "running" ]]; then
        echo -e "  Статус    : ${GREEN}${c_status^^}${NC}"
    else
        echo -e "  Статус    : ${RED}${c_status^^}${NC}"
    fi
    echo "  Порты     : ${c_ports}"

    local server_ip
    server_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    server_ip="${server_ip:-127.0.0.1}"
    echo "  URL       : http://${server_ip}:${LERS_PORT:-$DEFAULT_LERS_PORT}"

    if [[ "$c_status" == "running" ]]; then
        echo
        local code
        code="$(curl -4 -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://127.0.0.1:${LERS_PORT:-$DEFAULT_LERS_PORT}/" 2>/dev/null || true)"
        if [[ "$code" =~ ^(200|301|302|401|403)$ ]]; then
            success "Веб-интерфейс отвечает (HTTP $code)!"
        else
            warn "Веб-интерфейс ещё инициализируется или порт недоступен (код: ${code:-нет ответа})."
        fi
    fi
}

action_lers_start() {
    print_banner
    echo -e "${BOLD}${CYAN}>>> ЗАПУСК СЛУЖБЫ ЛЭРС УЧЁТ${NC}"
    echo "────────────────────────────────────────────────────────────"
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'lers-db'; then
        info "MS SQL Server (lers-db) не запущен. Сначала запускаем базу данных..."
        prepare_mssql_storage
        docker compose -f "$COMPOSE_FILE" up -d db
        wait_for_local_mssql || return 1
    fi
    info "Запуск контейнера lers-server..."
    docker compose -f "$COMPOSE_FILE" up -d lers
    verify_lers_health
}

action_lers_stop() {
    print_banner
    echo -e "${BOLD}${CYAN}>>> ОСТАНОВКА СЛУЖБЫ ЛЭРС УЧЁТ${NC}"
    echo "────────────────────────────────────────────────────────────"
    info "Остановка контейнера lers-server..."
    docker compose -f "$COMPOSE_FILE" stop lers
    success "Сервер ЛЭРС УЧЁТ остановлен."
}

action_lers_restart() {
    print_banner
    echo -e "${BOLD}${CYAN}>>> ПЕРЕЗАПУСК СЛУЖБЫ ЛЭРС УЧЁТ${NC}"
    echo "────────────────────────────────────────────────────────────"
    info "Перезапуск контейнера lers-server..."
    docker compose -f "$COMPOSE_FILE" restart lers
    verify_lers_health
}

action_lers_logs() {
    print_banner
    echo -e "${BOLD}${CYAN}>>> ПОСЛЕДНИЕ 100 СТРОК ЖУРНАЛА lers-server${NC}"
    echo "────────────────────────────────────────────────────────────"
    docker compose -f "$COMPOSE_FILE" logs --tail 100 lers || true
}

action_lers_check_http() {
    print_banner
    local port="${LERS_PORT:-$DEFAULT_LERS_PORT}"
    local server_ip
    server_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    server_ip="${server_ip:-127.0.0.1}"

    echo -e "${BOLD}${CYAN}>>> ПРОВЕРКА ВЕБ-ИНТЕРФЕЙСА ЛЭРС УЧЁТ${NC}"
    echo "────────────────────────────────────────────────────────────"
    echo "URL: http://${server_ip}:${port}/"

    local http_code
    http_code="$(curl -4 -s -o /dev/null -w "%{http_code}" --connect-timeout 4 "http://127.0.0.1:${port}/" 2>/dev/null || echo "000")"
    if [[ "$http_code" =~ ^(200|301|302|401|403)$ ]]; then
        success "Веб-интерфейс доступен и отвечает с кодом HTTP $http_code!"
    else
        warn "Веб-интерфейс вернул код $http_code (или соединение отклонено)."
        info "Если сервер только что запущен, подождите 10-30 секунд до завершения инициализации .NET ядра."
        info "Журнал сервера: docker compose -f $COMPOSE_FILE logs --tail 30 lers"
    fi
}

menu_update_lers() {
    print_banner
    echo -e "${BOLD}${CYAN}>>> ОБНОВИТЬ СЛУЖБУ ЛЭРС УЧЁТ${NC}"
    echo "────────────────────────────────────────────────────────────"
    if ! ensure_docker; then return 1; fi
    [[ ! -f "$COMPOSE_FILE" ]] && { error "Файл compose.yml не найден. Сначала выполните установку."; return 1; }

    info "Обновление Docker-образа lers (${DEFAULT_LERS_IMAGE})..."
    docker compose -f "$COMPOSE_FILE" pull lers

    info "Перезапуск контейнера lers с новым образом..."
    docker compose -f "$COMPOSE_FILE" up -d lers

    verify_lers_health
    success "Обновление контейнера LERS успешно завершено!"
}

# [6] Подменю управления LERS
# [8] Удаление ЛЭРС УЧЁТ
menu_uninstall_lers() {
    print_banner
    echo -e "${BOLD}${RED}======================================================================${NC}"
    echo -e "${BOLD}${RED}                       УДАЛЕНИЕ ЛЭРС УЧЁТ${NC}"
    echo -e "${BOLD}${RED}======================================================================${NC}"
    echo
    echo "Выберите режим удаления:"
    echo "  [1] ⚠️  Удалить только сервер ЛЭРС (контейнер lers-server)"
    echo "      База данных MS SQL Server и файлы ${SQLDATA_DIR} сохранятся."
    echo
    echo "  [2] 💣 ПОЛНОЕ УДАЛЕНИЕ комплекса (LERS + MS SQL + базы данных)"
    echo "      Остановка и удаление всех контейнеров, томов данных,"
    echo "      каталогов ${LERS_BASE_DIR} и сохранённого пароля SA."
    echo
    echo "  [0] Отмена"
    echo "  ────────────────────────────────────────────────────────────"
    local u_choice=""
    read -rp "Выберите вариант [0-2]: " u_choice

    case "$u_choice" in
        1)
            echo
            warn "Будет остановлен и удалён контейнер сервера ЛЭРС (lers-server)."
            read -rp "Подтверждаете удаление контейнера LERS? [y/N]: " conf1
            if [[ "$conf1" =~ ^[YyДд]$ ]]; then
                info "Остановка и удаление lers-server..."
                docker compose -f "$COMPOSE_FILE" stop lers >/dev/null 2>&1 || true
                docker compose -f "$COMPOSE_FILE" rm -f lers >/dev/null 2>&1 || true
                docker rm -f lers-server >/dev/null 2>&1 || true
                success "Контейнер lers-server успешно удалён. База данных MS SQL сохранена."
            else
                info "Удаление отменено."
            fi
            ;;
        2)
            echo
            error "ВНИМАНИЕ: БУДУТ БЕЗВОЗВРАТНО УДАЛЕНЫ ВСЕ ДАННЫЕ ЛЭРС И MS SQL SERVER!"
            echo "  Будут удалены:"
            echo "    - Контейнеры lers-server и lers-db"
            echo "    - Все файлы базы данных в ${SQLDATA_DIR}"
            echo "    - Все настройки и конфигурации в ${LERS_BASE_DIR}"
            echo "    - Сохранённый пароль SA (${MSSQL_SA_PASSWORD_FILE})"
            echo
            read -rp "Вы абсолютно уверены? Введите 'DELETE' для подтверждения: " conf2
            if [[ "$conf2" == "DELETE" ]]; then
                info "Остановка всех контейнеров LERS..."
                docker compose -f "$COMPOSE_FILE" down -v --remove-orphans >/dev/null 2>&1 || true
                docker rm -f lers-server lers-db >/dev/null 2>&1 || true

                info "Очистка системных каталогов ${LERS_BASE_DIR}..."
                rm -rf "${SQLDATA_DIR}" "${LERS_DATA_DIR}" "${LERS_CONF_DIR}" "${COMPOSE_FILE}" "${ENV_FILE}" 2>/dev/null || true
                rm -f "${MSSQL_SA_PASSWORD_FILE}" 2>/dev/null || true

                echo
                success "Комплекс ЛЭРС УЧЁТ и база данных MS SQL полностью удалены с сервера."
                info "Каталог резервных копий ${BACKUP_DIR} сохранён."
            else
                info "Подтверждение 'DELETE' не получено. Удаление отменено."
            fi
            ;;
        *)
            info "Операция отменена."
            return 0
            ;;
    esac
}

menu_manage_lers() {
    while true; do
        print_banner
        echo
        echo -e "${BOLD}${CYAN}======================================================================${NC}"
        echo -e "${BOLD}${CYAN}                         LERS SERVER${NC}"
        echo -e "${BOLD}${CYAN}======================================================================${NC}"
        echo
        echo "  [1] 📊 Статус LERS"
        echo "  [2] ▶️  Запустить LERS"
        echo "  [3] ⏹️  Остановить LERS"
        echo "  [4] 🔄 Перезапустить LERS"
        echo "  [5] 📜 Логи LERS"
        echo "  [6] 🔍 Проверить HTTP :10000"
        echo "  [7] ⬆️  Обновить LERS"
        echo "  [8] 🗑️  Удалить ЛЭРС"
        echo
        echo "  [0] Назад"
        echo "  ────────────────────────────────────────────────────────────"
        local l_choice=""
        read -rp "Выберите пункт [0-8]: " l_choice

        case "$l_choice" in
            1) action_lers_status ;;
            2) action_lers_start ;;
            3) action_lers_stop ;;
            4) action_lers_restart ;;
            5) action_lers_logs ;;
            6) action_lers_check_http ;;
            7) menu_update_lers ;;
            8) menu_uninstall_lers ;;
            0) return 0 ;;
            *) error "Неверный выбор." ;;
        esac
        echo
        read -rp "Нажмите Enter для продолжения..." _dummy || true
    done
}

# ==============================================================================
# ГЛАВНОЕ МЕНЮ (LERS + MS SQL MANAGER)
# ==============================================================================
main_menu() {
    check_prerequisites
    init_directories

    while true; do
        print_banner
        echo
        echo -e "${BOLD}  УСТАНОВКА LERS${NC}"
        echo "  ────────────────────────────────────────────────────────────"
        echo "  [1] 🚀 Чистая установка LERS + MS SQL Express (Docker)"
        echo "  [2] 🔄 Установка LERS + восстановление существующей БД"
        echo
        echo -e "${BOLD}  УДАЛЁННЫЙ MS SQL${NC}"
        echo "  ────────────────────────────────────────────────────────────"
        echo "  [3] 💾 Создать BACKUP БД на удалённом MS SQL"
        echo "  [4] 🔎 Проверить удалённый MS SQL"
        echo
        echo -e "${BOLD}  ЛОКАЛЬНЫЙ MS SQL / БД LERS${NC}"
        echo "  ────────────────────────────────────────────────────────────"
        echo "  [5] 🗄️  Управление MS SQL и БД LERS"
        echo
        echo -e "${BOLD}  LERS${NC}"
        echo "  ────────────────────────────────────────────────────────────"
        echo "  [6] ⚙️  Управление LERS"
        echo "  [7] 🔄 Обновить LERS"
        echo "  [8] 🗑️  Удалить ЛЭРС"
        echo
        echo "  [0] Выход"
        echo "  ────────────────────────────────────────────────────────────"
        local m_choice=""
        read -rp "Выберите пункт меню [0-8]: " m_choice

        case "$m_choice" in
            1) menu_clean_install ;;
            2) menu_install_with_restore ;;
            3) menu_remote_backup ;;
            4) menu_remote_diagnostics ;;
            5) menu_manage_mssql ;;
            6) menu_manage_lers ;;
            7) menu_update_lers ;;
            8) menu_uninstall_lers ;;
            0) echo "Выход."; exit 0 ;;
            *) error "Неверный выбор." ;;
        esac
        echo
        read -rp "Нажмите Enter для продолжения..." _dummy || true
    done
}

# ------------------------------------------------------------------------------
# Точка входа / CLI диспетчер
# ------------------------------------------------------------------------------
if [[ $# -gt 0 ]]; then
    check_prerequisites
    init_directories
    case "$1" in
        install)
            menu_clean_install
            ;;
        install-restore)
            menu_install_with_restore
            ;;
        backup-remote)
            menu_remote_backup
            ;;
        diag)
            menu_remote_diagnostics
            ;;
        mssql)
            menu_manage_mssql
            ;;
        lers)
            menu_manage_lers
            ;;
        update)
            menu_update_lers
            ;;
        uninstall)
            menu_uninstall_lers
            ;;
        *)
            echo "Использование: $0 [install|install-restore|backup-remote|diag|mssql|lers|update|uninstall]"
            exit 1
            ;;
    esac
else
    check_prerequisites
    main_menu
fi
