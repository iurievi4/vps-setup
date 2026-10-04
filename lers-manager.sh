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
CONFIG_DIR="/var/lib/lers-manager"
CONFIG_FILE="${CONFIG_DIR}/config"
MSSQL_SA_PASSWORD_FILE="/root/.mssql-sa-password"
RCLONE_CONFIG_FILE="/root/.config/rclone/rclone.conf"

CANONICAL_BACKUP_NAME="LERS_BACKUP.enc"
GDRIVE_REMOTE="${GDRIVE_REMOTE:-gdrive}"
GDRIVE_PATH="${GDRIVE_PATH:-LERS_BACKUP.enc}"

DEFAULT_LERS_IMAGE="lersamr/full-r:latest"
DEFAULT_MSSQL_IMAGE="mcr.microsoft.com/mssql/server:2025-latest"
DEFAULT_LERS_PORT="10000"
DEFAULT_MSSQL_PORT="1433"
DEFAULT_DB_NAME="LERS"
DEFAULT_MSSQL_PID="Express"

# Активная сессия (в памяти)
SESSION_HOST=""
SESSION_PORT="1433"
SESSION_DB="LERS"
SESSION_USER="sa"
SESSION_PASS=""
SESSION_TRANSPORT="SCP"

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
    for tool in curl openssl tar jq gzip unzip sshpass smbclient file bzip2; do
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
    total_gb="$(awk "BEGIN {printf "%.2f", ${total_mb}/1024}")"
    avail_gb="$(awk "BEGIN {printf "%.2f", ${avail_mb}/1024}")"
    swap_gb="$(awk "BEGIN {printf "%.2f", ${swap_mb}/1024}")"

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
    mkdir -p \
        "${LERS_BASE_DIR}" \
        "${SQLDATA_DIR}" \
        "${LERS_DATA_DIR}" \
        "${LERS_CONF_DIR}" \
        "${BACKUP_DIR}" \
        "${SQL_BACKUP_DIR}" \
        "${INCOMING_DIR}" \
        "${CONFIG_DIR}"

    chmod 755 "${LERS_BASE_DIR}"

    chmod 700 \
        "${BACKUP_DIR}" \
        "${SQL_BACKUP_DIR}" \
        "${INCOMING_DIR}" \
        "${CONFIG_DIR}"

    chgrp -R 0 "${SQLDATA_DIR}" "${SQL_BACKUP_DIR}" 2>/dev/null || true
    chmod -R g=u "${SQLDATA_DIR}" "${SQL_BACKUP_DIR}" 2>/dev/null || true

    load_saved_config
}

load_saved_config() {
    mkdir -p "$CONFIG_DIR"
    if [[ -f "$CONFIG_FILE" ]]; then
        # Читаем параметры (без паролей)
        local h p d u t
        h="$(grep -E '^SQL_HOST=' "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '\r\n' || true)"
        p="$(grep -E '^SQL_PORT=' "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '\r\n' || true)"
        d="$(grep -E '^SQL_DB=' "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '\r\n' || true)"
        u="$(grep -E '^SQL_USER=' "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '\r\n' || true)"
        t="$(grep -E '^SQL_TRANSPORT=' "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '\r\n' || true)"
        [[ -n "$h" && -z "$SESSION_HOST" ]] && SESSION_HOST="$h"
        [[ -n "$p" ]] && SESSION_PORT="$p"
        [[ -n "$d" ]] && SESSION_DB="$d"
        [[ -n "$u" ]] && SESSION_USER="$u"
        [[ -n "$t" ]] && SESSION_TRANSPORT="$t"
    fi
}

save_config_profile() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
# LERS Manager Saved Connection Settings
SQL_HOST="${SESSION_HOST:-}"
SQL_PORT="${SESSION_PORT:-1433}"
SQL_DB="${SESSION_DB:-LERS}"
SQL_USER="${SESSION_USER:-sa}"
SQL_TRANSPORT="${SESSION_TRANSPORT:-SCP}"
EOF
    chmod 600 "$CONFIG_FILE"
}

get_or_create_sa_password() {
    if [[ -s "$MSSQL_SA_PASSWORD_FILE" ]]; then
        MSSQL_SA_PASSWORD="$(<"$MSSQL_SA_PASSWORD_FILE")"
    else
        umask 077
        local rnd_hex
        rnd_hex="$(openssl rand -hex 16 2>/dev/null || od -vAn -N16 -tx1 /dev/urandom | tr -d ' \\n')"
        MSSQL_SA_PASSWORD="Lers_Sql_${rnd_hex}#2026!"
        printf '%s' "$MSSQL_SA_PASSWORD" > "$MSSQL_SA_PASSWORD_FILE"
        chmod 600 "$MSSQL_SA_PASSWORD_FILE"
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
            if echo "$help_out" | grep -q -- '-N'; then
                flags="$flags -N"
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
        printf -v "$__flags_var" '%s' "-C -N"
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
                -t "$timeout_sec" \
                $extra_flags -b
            ;;
        CONTAINER_LERS_DB)
            docker exec -i lers-db bash -c '
                if [ -x /opt/mssql-tools18/bin/sqlcmd ]; then
                    CMD=/opt/mssql-tools18/bin/sqlcmd; FLAGS="-C -N"
                elif [ -x /usr/local/bin/sqlcmd ]; then
                    CMD=/usr/local/bin/sqlcmd; FLAGS="-C -N"
                else
                    CMD=/opt/mssql-tools/bin/sqlcmd; FLAGS=""
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

encrypt_archive() {
    local input_bak="$1" output_enc="$2" master_pass="$3"
    [[ ! -s "$input_bak" ]] && { error "Файл бэкапа не найден: $input_bak"; return 1; }

    local work_dir
    work_dir="$(mktemp -d /tmp/lers-enc.XXXXXX)"
    chmod 700 "$work_dir"
    trap 'rm -rf "$work_dir"' RETURN

    local pass_file="${work_dir}/pass.tmp"
    printf '%s' "$master_pass" > "$pass_file"
    chmod 600 "$pass_file"

    local bak_filename
    bak_filename="$(basename "$input_bak")"
    local archive_tar="${work_dir}/backup.tar.gz"
    local tmp_enc="${work_dir}/encrypted.tmp"

    info "Упаковка $bak_filename в tar.gz..."
    tar -czf "$archive_tar" -C "$(dirname "$input_bak")" "$bak_filename"
    tar -tzf "$archive_tar" >/dev/null 2>&1 || { error "Ошибка создания архива."; return 1; }

    info "Шифрование через OpenSSL (AES-256-CBC + PBKDF2)..."
    openssl enc -aes-256-cbc -pbkdf2 -in "$archive_tar" -out "$tmp_enc" -pass file:"$pass_file"

    info "Контрольная расшифровка и проверка..."
    local test_tar="${work_dir}/test_verify.tar.gz"
    openssl enc -d -aes-256-cbc -pbkdf2 -in "$tmp_enc" -out "$test_tar" -pass file:"$pass_file" 2>/dev/null
    tar -tzf "$test_tar" >/dev/null 2>&1 || { error "Тестовый архив повреждён при расшифровке."; return 1; }

    mkdir -p "$(dirname "$output_enc")"
    mv -f "$tmp_enc" "$output_enc"
    chmod 600 "$output_enc"
    success "Файл зашифрован и верифицирован: $output_enc ($(du -h "$output_enc" | awk '{print $1}'))"
    return 0
}

decrypt_archive() {
    local input_enc="$1" output_dir="$2" master_pass="$3" __result_bak_var="$4"
    [[ ! -s "$input_enc" ]] && { error "Файл не найден: $input_enc"; return 1; }

    local work_dir
    work_dir="$(mktemp -d /tmp/lers-dec.XXXXXX)"
    chmod 700 "$work_dir"
    trap 'rm -rf "$work_dir"' RETURN

    local pass_file="${work_dir}/pass.tmp"
    printf '%s' "$master_pass" > "$pass_file"
    chmod 600 "$pass_file"

    local decrypted_tar="${work_dir}/decrypted.tar.gz"

    info "Расшифровка OpenSSL (AES-256-CBC + PBKDF2)..."
    if ! openssl enc -d -aes-256-cbc -pbkdf2 -in "$input_enc" -out "$decrypted_tar" -pass file:"$pass_file" 2>/dev/null; then
        error "Неверный пароль или повреждённый файл."
        return 1
    fi

    mkdir -p "$output_dir"
    chmod 700 "$output_dir"
    local extracted_bak=""

    if tar -tzf "$decrypted_tar" >/dev/null 2>&1; then
        tar -xzf "$decrypted_tar" -C "$output_dir"
        local candidates=()
        mapfile -t candidates < <(find "$output_dir" -maxdepth 2 -type f \( -iname "*.bak" -o -iname "*.db" \) -size +0c)
        [[ ${#candidates[@]} -gt 0 ]] && extracted_bak="${candidates[0]}"
    else
        if head -c 1024 "$decrypted_tar" 2>/dev/null | grep -qa "TAPE"; then
            local fallback_name
            fallback_name="$(basename "$input_enc" .enc)"
            [[ "$fallback_name" != *.bak ]] && fallback_name="${fallback_name}.bak"
            extracted_bak="${output_dir}/${fallback_name}"
            mv -f "$decrypted_tar" "$extracted_bak"
        fi
    fi

    [[ -z "$extracted_bak" || ! -s "$extracted_bak" ]] && { error "В архиве не найдено файла базы (*.bak)."; return 1; }
    chmod 600 "$extracted_bak"
    success "База успешно расшифрована: $extracted_bak"
    printf -v "$__result_bak_var" '%s' "$extracted_bak"
    return 0
}

# ------------------------------------------------------------------------------
# Движок локального MS SQL и Dynamic RESTORE
# ------------------------------------------------------------------------------
sql_local_exec() {
    local query="$1" db_context="${2:-master}" extra_flags="${3:-}"
    get_or_create_sa_password
    docker exec -i lers-db bash -c "
        if [ -x /opt/mssql-tools18/bin/sqlcmd ]; then
            CMD=/opt/mssql-tools18/bin/sqlcmd; FLAGS=\\"-C\\"
        elif [ -x /opt/mssql-tools/bin/sqlcmd ]; then
            CMD=/opt/mssql-tools/bin/sqlcmd; FLAGS=\\"\\"
        else
            echo 'sqlcmd не найден в контейнере' >&2; exit 1
        fi
        SQLCMDPASSWORD=\\"\\$MSSQL_SA_PASSWORD\\" \\"\\$CMD\\" -S localhost -U sa -d \\"$db_context\\" -Q \\"$query\\" \\$FLAGS $extra_flags -b
    "
}

wait_for_local_mssql() {
    local count=0
    until sql_local_exec "SELECT 1" "master" >/dev/null 2>&1; do
        sleep 2
        count=$((count + 1))
        (( count >= 35 )) && { error "Таймаут старта MS SQL Server."; return 1; }
    done
    success "MS SQL Server готов к работе."
}

get_restore_file_moves() {
    local container_backup_path="$1" target_db_name="${2:-LERS}"
    local raw_filelist
    raw_filelist="$(sql_local_exec "RESTORE FILELISTONLY FROM DISK = N'$(sql_escape "$container_backup_path")';" "master" "-s | -W -h -1" 2>/dev/null || true)"

    [[ -z "$raw_filelist" ]] && { error "Не удалось прочитать список файлов бэкапа."; return 1; }

    local data_idx=0 log_idx=0 move_clauses=()
    while IFS='|' read -r col_logical col_phys col_type col_rest; do
        col_logical="$(echo "${col_logical:-}" | tr -d '\\r\\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        col_type="$(echo "${col_type:-}" | tr -d '\\r\\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | tr '[:lower:]' '[:upper:]')"
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

    if (( data_idx == 0 || log_idx == 0 )); then
        error "В бэкапе не найдено обязательных файлов данных (D) или логов (L)!"
        return 1
    fi
    local IFS=","
    echo "${move_clauses[*]}"
    return 0
}

cleanup_orphaned_ndf_files() {
    local target_db_name="${1:-LERS}"
    local active_files
    active_files="$(sql_local_exec "SELECT physical_name FROM sys.master_files WHERE database_id = DB_ID('$(sql_escape "$target_db_name")')" "master" "-h -1 -W" 2>/dev/null || true)"
    [[ -z "$active_files" ]] && return 0

    for f in "${SQLDATA_DIR}/${target_db_name}_"*.ndf; do
        [[ ! -f "$f" ]] && continue
        local fname
        fname="$(basename "$f")"
        if ! echo "$active_files" | grep -q "$fname"; then
            warn "Удаление устаревшего вторичного файла NDF: $f"
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
    chmod 600 "$host_sql_bak"
    chgrp 0 "$host_sql_bak" 2>/dev/null || true

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

    if [[ "$input_path" == *.enc ]] || echo "$file_type" | grep -qi "openssl enc"; then
        echo -e "${YELLOW}Файл зашифрован. Введите пароль для расшифровки:${NC}"
        local d_pass=""
        read_secret_masked "Пароль: " d_pass
        echo
        local out_dec_dir="${INCOMING_DIR}/decrypted_$(date +%s)"
        decrypt_archive "$input_path" "$out_dec_dir" "$d_pass" determined_bak || return 1
    elif [[ "$input_path" == *.tar.gz || "$input_path" == *.tgz ]] || echo "$file_type" | grep -qi "gzip compressed"; then
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
    chmod 600 "$r_host_p"
    chgrp 0 "$r_host_p" 2>/dev/null || true

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
      MSSQL_PID: "${MSSQL_PID:-Express}"
    volumes:
      - "${SQLDATA_DIR}:/var/opt/mssql/data"
      - "${SQL_BACKUP_DIR}:/var/opt/mssql/backup"
    ports:
      - "127.0.0.1:1433:1433"
    healthcheck:
      test: ["CMD-SHELL", "/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P '\$\$MSSQL_SA_PASSWORD' -C -Q 'SELECT 1' || /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P '\$\$MSSQL_SA_PASSWORD' -Q 'SELECT 1'"]
      interval: 10s
      timeout: 5s
      retries: 25
      start_period: 15s

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

# ------------------------------------------------------------------------------
# Загрузка по ссылке (Google Drive / прямой URL)
# ------------------------------------------------------------------------------
download_public_url() {
    local raw_url="$1" dest_file="$2"
    ensure_dependencies
    mkdir -p "$(dirname "$dest_file")"

    local file_id=""
    if [[ "$raw_url" =~ /d/([a-zA-Z0-9_-]+) ]]; then
        file_id="${BASH_REMATCH[1]}"
    elif [[ "$raw_url" =~ id=([a-zA-Z0-9_-]+) ]]; then
        file_id="${BASH_REMATCH[1]}"
    fi

    if [[ -n "$file_id" ]]; then
        info "Обнаружена ссылка Google Drive (ID: ${file_id}). Загрузка..."
        local cookie_jar
        cookie_jar="$(mktemp /tmp/gdrive_cookie.XXXXXX)"
        chmod 600 "$cookie_jar"
        trap 'rm -f "$cookie_jar"' RETURN

        local confirm_code
        confirm_code="$(curl -4 -sSL -c "$cookie_jar" "https://drive.google.com/uc?export=download&id=${file_id}" 2>/dev/null | grep -o 'confirm=[^&"]*' | head -n1 || true)"
        if [[ -n "$confirm_code" ]]; then
            curl -4 -fL -b "$cookie_jar" "https://drive.google.com/uc?export=download&${confirm_code}&id=${file_id}" -o "$dest_file"
        else
            curl -4 -fL -b "$cookie_jar" "https://drive.google.com/uc?export=download&id=${file_id}" -o "$dest_file"
        fi
        rm -f "$cookie_jar"
    else
        info "Загрузка файла по прямому URL..."
        curl -4 -fL --connect-timeout 20 --max-time 3600 -o "$dest_file" "$raw_url"
    fi

    [[ ! -s "$dest_file" ]] && { error "Скачанный файл пуст или отсутствует."; return 1; }

    if head -c 512 "$dest_file" 2>/dev/null | grep -qiE "<!doctype|<html|<head|accounts.google.com"; then
        error "Скачанный файл является HTML-страницей (нет публичного доступа на Google Drive)."
        rm -f "$dest_file"
        return 1
    fi

    chmod 600 "$dest_file"
    success "Файл успешно загружен: $dest_file ($(du -h "$dest_file" | awk '{print $1}'))"
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

    chgrp -R 0 "${SQLDATA_DIR}" "${SQL_BACKUP_DIR}" 2>/dev/null || true
    chmod -R g=u "${SQLDATA_DIR}" "${SQL_BACKUP_DIR}" 2>/dev/null || true

    info "Загрузка Docker-образов..."
    docker compose -f "$COMPOSE_FILE" pull

    info "Запуск контейнеров LERS + MS SQL..."
    docker compose -f "$COMPOSE_FILE" up -d

    info "Ожидание готовности MS SQL Server..."
    wait_for_local_mssql

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

    read -rp "Порт веб-интерфейса ЛЭРС [${DEFAULT_LERS_PORT}]: " in_port
    LERS_PORT="${in_port:-$DEFAULT_LERS_PORT}"

    get_or_create_sa_password
    generate_compose_files

    chgrp -R 0 "${SQLDATA_DIR}" "${SQL_BACKUP_DIR}" 2>/dev/null || true
    chmod -R g=u "${SQLDATA_DIR}" "${SQL_BACKUP_DIR}" 2>/dev/null || true

    # 1. Запускаем ТОЛЬКО базу данных
    info "[1/5] Запуск службы базы данных (MS SQL Express)..."
    docker compose -f "$COMPOSE_FILE" up -d db

    info "[2/5] Ожидание готовности MS SQL Server..."
    wait_for_local_mssql

    # 2. Получение файла бэкапа
    echo
    echo "Выберите источник файла резервной копии:"
    echo "  [1] Ссылка Google Drive / прямой URL"
    echo "  [2] Локальный файл на VPS (из ${BACKUP_DIR} или указать путь)"
    read -rp "Выбор [1-2, по умолчанию 1]: " src_c
    src_c="${src_c:-1}"

    local raw_input_file=""
    if [[ "$src_c" == "1" ]]; then
        read -rp "Введите URL или ссылку Google Drive: " g_url
        [[ -z "$g_url" ]] && { error "URL не указан."; return 1; }
        local tmp_dl="${INCOMING_DIR}/LERS_downloaded_$(date +%s).tmp"
        download_public_url "$g_url" "$tmp_dl" || return 1
        raw_input_file="$tmp_dl"
    else
        local found_baks=()
        mapfile -t found_baks < <(find "${BACKUP_DIR}" "${INCOMING_DIR}" -maxdepth 2 -type f \( -iname "*.bak" -o -iname "*.enc" \) 2>/dev/null | sort)
        if [[ ${#found_baks[@]} -gt 0 ]]; then
            echo "Найдены файлы на сервере:"
            local f_idx=1
            for bf in "${found_baks[@]}"; do
                echo "  [$f_idx] $(basename "$bf") ($(du -h "$bf" | awk '{print $1}'))"
                f_idx=$((f_idx + 1))
            done
            echo "  [0] Указать другой полный путь к файлу"
            read -rp "Выбор [1-${#found_baks[@]} или 0]: " sel_bf
            if [[ "$sel_bf" =~ ^[1-9][0-9]*$ ]] && (( sel_bf <= ${#found_baks[@]} )); then
                raw_input_file="${found_baks[$((sel_bf-1))]}"
            fi
        fi
        if [[ -z "$raw_input_file" ]]; then
            read -rp "Введите полный путь к файлу бэкапа (.bak или .enc): " raw_input_file
        fi
    fi

    [[ ! -s "$raw_input_file" ]] && { error "Файл бэкапа не найден: $raw_input_file"; return 1; }

    # 3. Подготовка и проверка
    local ready_bak=""
    info "[3/5] Подготовка и валидация файла бэкапа..."
    prepare_sql_bak_from_source "$raw_input_file" ready_bak || return 1
    verify_sql_backup "$ready_bak" || return 1

    # 4. Восстановление БД
    info "[4/5] Восстановление базы данных LERS..."
    local r_bak_name="restore_init_$(date +%s).bak"
    local r_host_p="${SQL_BACKUP_DIR}/${r_bak_name}"
    cp -f "$ready_bak" "$r_host_p"
    chmod 600 "$r_host_p"
    chgrp 0 "$r_host_p" 2>/dev/null || true

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
    info "[5/5] Запуск службы ЛЭРС УЧЁТ..."
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
    echo -e "${GREEN}======================================================================${NC}"
}

# Общий конвейер скачивания бэкапа с MS SQL Server на VPS
execute_download_backup() {
    local do_encrypt="$1"
    init_directories

    echo "Источник MS SQL:"
    echo "  [1] Windows"
    echo "  [2] Linux"
    echo "  [3] Linux Docker"
    read -rp "Выбор [1-3, по умолчанию 1]: " s_type
    s_type="${s_type:-1}"

    # Подготовка SQL-клиента ДО ввода параметров подключения
    if ! prepare_sqlcmd; then
        return 1
    fi

    local p_host_prompt="IP / Host"
    [[ -n "$SESSION_HOST" ]] && p_host_prompt="IP / Host [${SESSION_HOST}]"
    read -rp "  ${p_host_prompt}: " in_host
    SESSION_HOST="${in_host:-$SESSION_HOST}"
    while [[ -z "$SESSION_HOST" ]]; do
        warn "Адрес сервера не может быть пустым."
        read -rp "  IP / Host: " in_host
        SESSION_HOST="$in_host"
    done

    read -rp "  Порт [${SESSION_PORT:-1433}]: " in_p
    SESSION_PORT="${in_p:-${SESSION_PORT:-1433}}"

    read -rp "  База данных [${SESSION_DB:-LERS}]: " in_db
    SESSION_DB="${in_db:-${SESSION_DB:-LERS}}"

    read -rp "  Пользователь [${SESSION_USER:-sa}]: " in_u
    SESSION_USER="${in_u:-${SESSION_USER:-sa}}"

    read_secret_masked "  Пароль SQL: " in_pw
    echo
    SESSION_PASS="$in_pw"
    while [[ -z "$SESSION_PASS" ]]; do
        warn "Пароль не может быть пустым."
        read_secret_masked "  Пароль SQL: " in_pw
        echo
        SESSION_PASS="$in_pw"
    done

    local transport="SCP"
    if [[ "$s_type" == "1" ]]; then
        echo "Способ передачи backup на VPS:"
        echo "  [1] SCP / SFTP (SSH)"
        echo "  [2] SMB / Windows Network Share (smbclient)"
        read -rp "Выбор [1-2, по умолчанию 1]: " in_t
        [[ "${in_t:-1}" == "2" ]] && transport="SMB"
    fi
    SESSION_TRANSPORT="$transport"
    save_config_profile

    # Шаг 1/5: Проверка подключения к SQL Server
    echo
    step "1/5" "Проверка подключения к SQL Server (${SESSION_HOST}:${SESSION_PORT})..."

    echo -n "  [1/2] Проверка сетевого порта TCP (${SESSION_PORT}) .... "
    if ! check_tcp_port "$SESSION_HOST" "$SESSION_PORT" 5; then
        echo -e "${YELLOW}TIMEOUT / НЕ ОТВЕЧАЕТ${NC}"
        warn "Порт ${SESSION_HOST}:${SESSION_PORT} не ответил по TCP за 5 сек."
        warn "Возможно, соединение блокируется брандмауэром или указан неверный порт."
    else
        echo -e "${GREEN}OK${NC}"
    fi

    echo -n "  [2/2] Аутентификация SQL Server (${SESSION_USER}) ....... "
    local check_res exit_code=0
    check_res="$(remote_sqlcmd "$SESSION_HOST" "$SESSION_PORT" "$SESSION_USER" "$SESSION_PASS" "master" "SELECT 1;" "-h -1 -W" 15 2>&1)" || exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo -e "${RED}FAILED${NC}"
        echo
        error "Не удалось подключиться к SQL Server:"
        echo "$check_res" | sed 's/^/    /'
        return 1
    fi
    echo -e "${GREEN}OK${NC}"
    success "Подключение к SQL Server успешно подтверждено."

    # Шаг 2/5: Определение каталога для BACKUP на удалённом сервере
    step "2/5" "Проверка каталога BACKUP на сервере..."
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    local b_filename="LERS_${ts}.bak"
    local rem_bak_path=""

    if [[ "$s_type" == "1" ]]; then
        # Опрос пути по умолчанию инстанса SQL Server для справки
        local def_path_query="SET NOCOUNT ON; SELECT CAST(ISNULL(SERVERPROPERTY('InstanceDefaultBackupPath'), '') AS varchar(500));"
        local detected_dir=""
        detected_dir="$(remote_sqlcmd "$SESSION_HOST" "$SESSION_PORT" "$SESSION_USER" "$SESSION_PASS" "master" "$def_path_query" "-h -1 -W" 15 2>/dev/null | tr -d '\r\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true)"
        detected_dir="${detected_dir%[\/\\]}"

        echo "Каталог для BACKUP на Windows-сервере"
        echo "Введите полный путь, например:"
        echo "  C:\LERS\Backup"
        echo "  D:\SQLBackup"
        echo "  E:\Backup"
        [[ -n "$detected_dir" ]] && echo "  (каталог экземпляра по умолчанию: ${detected_dir})"
        echo
        read -rp "Путь [C:\LERS\Backup]: " in_wdir
        local win_dir="${in_wdir:-C:\LERS\Backup}"
        win_dir="${win_dir%[\/\\]}"
        rem_bak_path="${win_dir}\\${b_filename}"
    else
        echo "Каталог для BACKUP на Linux-сервере"
        echo "Введите полный путь (например /var/opt/mssql/backup или /backups):"
        read -rp "Путь [/var/opt/mssql/backup]: " in_ldir
        local linux_dir="${in_ldir:-/var/opt/mssql/backup}"
        linux_dir="${linux_dir%[\/]}"
        rem_bak_path="${linux_dir}/${b_filename}"
    fi
    info "Целевой файл бэкапа: ${rem_bak_path}"

    # Шаг 3/5: Создание BACKUP на удалённой стороне
    step "3/5" "Создание BACKUP на удалённом сервере..."
    local b_query="BACKUP DATABASE [$(sql_escape "$SESSION_DB")] TO DISK = N'$(sql_escape "$rem_bak_path")' WITH COPY_ONLY, COMPRESSION, STATS = 20, FORMAT, INIT;"
    info "Выполнение BACKUP DATABASE [${SESSION_DB}]..."
    local backup_err="" backup_code=0
    backup_err="$(remote_sqlcmd "$SESSION_HOST" "$SESSION_PORT" "$SESSION_USER" "$SESSION_PASS" "master" "$b_query" "" 600 2>&1)" || backup_code=$?
    if [[ $backup_code -ne 0 ]]; then
        error "SQL Server не смог записать BACKUP."
        echo
        echo "Путь:"
        echo "  ${rem_bak_path}"
        echo
        echo "Возможные причины:"
        echo "  • каталог не существует;"
        echo "  • диск недоступен;"
        echo "  • у службы SQL Server нет права записи;"
        echo "  • указан неправильный путь."
        echo
        echo "Проверьте каталог и права службы SQL Server."
        if [[ -n "$backup_err" ]]; then
            echo
            echo "Ответ SQL Server:"
            echo "$backup_err" | sed 's/^/    /'
        fi
        return 1
    fi
    success "Резервная копия успешно создана на сервере: ${rem_bak_path}"

    # Шаг 4/5: Проверка BACKUP (RESTORE VERIFYONLY на удалённом сервере)
    step "4/5" "Проверка резервной копии (RESTORE VERIFYONLY на сервере)..."
    local v_query="RESTORE VERIFYONLY FROM DISK = N'$(sql_escape "$rem_bak_path")';"
    info "Выполнение проверки целостности на SQL Server..."
    local verify_res exit_code=0
    verify_res="$(remote_sqlcmd "$SESSION_HOST" "$SESSION_PORT" "$SESSION_USER" "$SESSION_PASS" "master" "$v_query" "" 180 2>&1)" || exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        error "Резервная копия не прошла проверку RESTORE VERIFYONLY на сервере:"
        echo "$verify_res" | sed 's/^/    /'
        return 1
    fi
    success "Резервная копия проверена и валидна (RESTORE VERIFYONLY успешно)."

    # Шаг 5/5: Передача файла на VPS
    step "5/5" "Передача файла на VPS..."
    local local_dest="${BACKUP_DIR}/${b_filename}"

    if [[ "$transport" == "SMB" ]]; then
        ensure_dependencies
        # Определение сетевого ресурса по умолчанию (C$, D$) и пути внутри ресурса
        local def_share="C$"
        local smb_file_rel="${b_filename}"
        if [[ "$rem_bak_path" =~ ^([A-Za-z]):[/\\]*(.*)$ ]]; then
            local drive_letter="${BASH_REMATCH[1]}"
            def_share="${drive_letter}\$"
            local raw_rel="${BASH_REMATCH[2]}"
            smb_file_rel="${raw_rel//\\//}"
        fi

        read -rp "  Сетевой ресурс SMB [${def_share}]: " in_share
        local smb_share="${in_share:-$def_share}"

        local smb_inner_path=""
        if [[ "$smb_share" =~ ^[A-Za-z]\$ ]]; then
            smb_inner_path="$smb_file_rel"
        else
            smb_inner_path="${b_filename}"
        fi
        read -rp "  Путь к файлу внутри SMB-ресурса [${smb_inner_path}]: " in_smb_path
        smb_inner_path="${in_smb_path:-$smb_inner_path}"

        read -rp "  Пользователь Windows [Administrator]: " smb_user
        smb_user="${smb_user:-Administrator}"
        local smb_pass=""
        read_secret_masked "  Пароль Windows (${smb_user}): " smb_pass
        echo

        local auth_f
        auth_f="$(mktemp /tmp/smb_auth.XXXXXX)"
        chmod 600 "$auth_f"
        cat > "$auth_f" <<EOF
username = ${smb_user}
password = ${smb_pass}
EOF
        info "Скачивание //${SESSION_HOST}/${smb_share}/${smb_inner_path} -> ${local_dest}..."
        if ! smbclient "//${SESSION_HOST}/${smb_share}" -A "$auth_f" -c "get \"${smb_inner_path}\" \"${local_dest}\"" 2>&1; then
            rm -f "$auth_f"
            error "Сбой передачи по SMB. Проверьте права доступа и правильность ресурса."
            return 1
        fi
        rm -f "$auth_f"
    else
        read -rp "  SSH порт [22]: " ssh_p
        ssh_p="${ssh_p:-22}"
        read -rp "  SSH пользователь [root или Administrator]: " ssh_u
        ssh_u="${ssh_u:-root}"
        local scp_remote_path="$rem_bak_path"
        if [[ "$s_type" == "1" ]]; then
            scp_remote_path="${rem_bak_path//\\//}"
        fi

        info "Скачивание через SCP (${SESSION_HOST}:${ssh_p})..."
        if ! scp -P "$ssh_p" "${ssh_u}@${SESSION_HOST}:${scp_remote_path}" "$local_dest"; then
            error "Сбой передачи по SCP."
            return 1
        fi
    fi

    if [[ ! -s "$local_dest" ]]; then
        error "Полученный файл пуст или повреждён!"
        return 1
    fi
    chmod 600 "$local_dest"
    local f_size
    f_size="$(du -h "$local_dest" | awk '{print $1}')"
    success "Файл получен на VPS: ${local_dest} (${f_size})"

    local sha256_hash=""
    if command -v sha256sum >/dev/null 2>&1; then
        sha256_hash="$(sha256sum "$local_dest" | awk '{print $1}')"
        info "Контрольная сумма SHA-256 (VPS): ${sha256_hash}"
    fi

    # Если запрошено шифрование
    if [[ "$do_encrypt" == "1" ]]; then
        echo
        echo -e "${YELLOW}Шифрование резервной копии (AES-256-CBC + PBKDF2):${NC}"
        local p1 p2
        read_secret_masked "  Введите пароль шифрования : " p1
        read_secret_masked "  Повторите пароль          : " p2
        if [[ -z "$p1" || "$p1" != "$p2" ]]; then
            error "Пароли не совпадают или пусты."
            return 1
        fi

        local enc_out="${BACKUP_DIR}/LERS_backup_${ts}.bak.enc"
        local canonical_out="${BACKUP_DIR}/${CANONICAL_BACKUP_NAME}"
        encrypt_archive "$local_dest" "$enc_out" "$p1" || return 1
        cp -f "$enc_out" "$canonical_out"
        chmod 600 "$canonical_out"

        echo
        echo "Действие с исходным файлом .bak:"
        echo "  [1] Удалить .bak (оставить только зашифрованный архив)"
        echo "  [2] Оставить оба файла (.bak и .enc)"
        read -rp "Выбор [1/2, по умолчанию 1]: " del_c
        [[ "${del_c:-1}" == "1" ]] && rm -f "$local_dest"

        echo
        echo -e "${GREEN}======================================================================${NC}"
        echo -e "${BOLD}${GREEN}  Готово! Резервная копия зашифрована:${NC}"
        echo -e "  Файл : ${BOLD}${enc_out}${NC}"
        echo -e "  Копия: ${BOLD}${canonical_out}${NC}"
        [[ -n "$sha256_hash" ]] && echo -e "  SHA256 (.bak): ${sha256_hash}"
        echo -e "${GREEN}======================================================================${NC}"
    else
        echo
        echo -e "${GREEN}======================================================================${NC}"
        echo -e "${BOLD}${GREEN}  Готово! Файл сохранён на VPS:${NC}"
        echo -e "  Файл : ${BOLD}${local_dest}${NC}"
        [[ -n "$sha256_hash" ]] && echo -e "  SHA256: ${sha256_hash}"
        echo -e "${GREEN}======================================================================${NC}"
    fi
    return 0
}

menu_download_raw() {
    print_banner
    echo -e "${BOLD}${CYAN}>>> [3] СКАЧАТЬ БД С MS SQL НА VPS${NC}"
    echo "────────────────────────────────────────────────────────────"
    execute_download_backup 0
}

# [4] Скачать БД → зашифровать
menu_download_encrypt() {
    print_banner
    echo -e "${BOLD}${CYAN}>>> [4] СКАЧАТЬ БД → ЗАШИФРОВАТЬ${NC}"
    echo "────────────────────────────────────────────────────────────"
    execute_download_backup 1
}

# [5] Восстановить БД из Google Drive
menu_restore_gdrive() {
    print_banner
    echo -e "${BOLD}${CYAN}>>> [5] ВОССТАНОВИТЬ БД ИЗ GOOGLE DRIVE${NC}"
    echo "────────────────────────────────────────────────────────────"
    if ! ensure_docker; then return 1; fi
    init_directories

    echo "Укажите ссылку на файл в Google Drive (или прямую ссылку):"
    read -rp "URL: " gd_url
    [[ -z "$gd_url" ]] && { error "Ссылка не указана."; return 1; }

    local tmp_file="${INCOMING_DIR}/LERS_gdrive_$(date +%s).tmp"
    download_public_url "$gd_url" "$tmp_file" || return 1

    local extracted_bak=""
    prepare_sql_bak_from_source "$tmp_file" extracted_bak || return 1

    perform_database_restore "$extracted_bak"
}

# [6] Восстановить БД из файла на VPS
menu_restore_local_file() {
    print_banner
    echo -e "${BOLD}${CYAN}>>> [6] ВОССТАНОВИТЬ БД ИЗ ФАЙЛА НА VPS${NC}"
    echo "────────────────────────────────────────────────────────────"
    if ! ensure_docker; then return 1; fi
    init_directories

    local found_files=()
    mapfile -t found_files < <(find "${BACKUP_DIR}" "${INCOMING_DIR}" -maxdepth 2 -type f \( -iname "*.bak" -o -iname "*.enc" \) 2>/dev/null | sort)

    local target_file=""
    if [[ ${#found_files[@]} -gt 0 ]]; then
        echo "Найдены файлы в ${BACKUP_DIR}:"
        local idx=1
        for f in "${found_files[@]}"; do
            echo "  [$idx] $(basename "$f") ($(du -h "$f" | awk '{print $1}'))"
            idx=$((idx + 1))
        done
        echo "  [0] Ввести другой путь вручную"
        read -rp "Выберите файл [1-${#found_files[@]} или 0]: " sel_f
        if [[ "$sel_f" =~ ^[1-9][0-9]*$ ]] && (( sel_f <= ${#found_files[@]} )); then
            target_file="${found_files[$((sel_f-1))]}"
        fi
    fi

    if [[ -z "$target_file" ]]; then
        read -rp "Введите полный путь к файлу: " target_file
    fi

    [[ ! -s "$target_file" ]] && { error "Файл не найден: $target_file"; return 1; }

    local extracted_bak=""
    prepare_sql_bak_from_source "$target_file" extracted_bak || return 1

    perform_database_restore "$extracted_bak"
}

# [7] Обновить LERS
menu_update_lers() {
    print_banner
    echo -e "${BOLD}${CYAN}>>> [7] ОБНОВИТЬ СЛУЖБУ ЛЭРС УЧЁТ${NC}"
    echo "────────────────────────────────────────────────────────────"
    if ! ensure_docker; then return 1; fi
    [[ ! -f "$COMPOSE_FILE" ]] && { error "Файл compose.yml не найден. Сначала выполните установку."; return 1; }

    info "Обновление Docker-образа lers..."
    docker compose -f "$COMPOSE_FILE" pull lers

    info "Перезапуск контейнера lers с новым образом..."
    docker compose -f "$COMPOSE_FILE" up -d lers

    verify_lers_health
    success "Обновление контейнера LERS успешно завершено!"
}

# ==============================================================================
# ГЛАВНОЕ МЕНЮ (7 ПУНКТОВ)
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
        echo -e "${BOLD}  MS SQL — BACKUP / RESTORE${NC}"
        echo "  ────────────────────────────────────────────────────────────"
        echo "  [3] 💾 Скачать БД с MS SQL на VPS"
        echo "  [4] 🔐 Скачать БД → зашифровать"
        echo "  [5] ♻️ Восстановить БД из Google Drive"
        echo "  [6] ♻️ Восстановить БД из файла на VPS"
        echo
        echo -e "${BOLD}  LERS${NC}"
        echo "  ────────────────────────────────────────────────────────────"
        echo "  [7] 🔄 Обновить LERS"
        echo
        echo "  [0] Выход"
        echo "  ────────────────────────────────────────────────────────────"
        read -rp "Выберите пункт меню [0-7]: " m_choice

        case "$m_choice" in
            1) menu_clean_install ;;
            2) menu_install_with_restore ;;
            3) menu_download_raw ;;
            4) menu_download_encrypt ;;
            5) menu_restore_gdrive ;;
            6) menu_restore_local_file ;;
            7) menu_update_lers ;;
            0) echo "Выход."; exit 0 ;;
            *) error "Неверный выбор." ;;
        esac
        echo
        read -rp "Нажмите Enter для продолжения..." _dummy || true
    done
}

# CLI аргументы
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
        download)
            menu_download_raw
            ;;
        download-enc)
            menu_download_encrypt
            ;;
        restore-gdrive)
            menu_restore_gdrive
            ;;
        restore)
            if [[ -n "${2:-}" ]]; then
                extracted_bak=""
                if prepare_sql_bak_from_source "$2" extracted_bak; then
                    perform_database_restore "$extracted_bak"
                fi
            else
                menu_restore_local_file
            fi
            ;;
        update)
            menu_update_lers
            ;;
        *)
            echo "Использование: $0 [install|install-restore|download|download-enc|restore-gdrive|restore <file>|update]"
            exit 1
            ;;
    esac
else
    main_menu
fi
