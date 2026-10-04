#!/usr/bin/env bash
# ==============================================================================
#  ЛЭРС УЧЁТ (LERS AMR) — МЕНЕДЖЕР РАЗВЁРТЫВАНИЯ, ОБСЛУЖИВАНИЯ И БЭКАПОВ
#  Версия: 3.0 (Production-Ready Architecture)
#
#  Архитектура:
#  1. INSTALLATION:   Развёртывание LERS (Docker Compose / Linux / Подключение к внешним SQL)
#  2. SQL CONNECTORS: Windows SQL (SMB/SFTP) • Linux SQL (SSH/SCP) • Docker SQL • Local LERS
#  3. BACKUP ENGINE:  Dynamic multi-file RESTORE, COPY_ONLY, Orphaned NDF cleanup
#  4. CRYPTO ENGINE:  AES-256-CBC + PBKDF2 (100% совместимо со стандартом setup.sh)
#  5. CLOUD / INGRESS: Публичные URL (Google Drive / HTTP) + rclone Google Drive
#  6. PROFILES:       Сохранение и повторное использование профилей серверов
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Цветовая палитра для терминала
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# ------------------------------------------------------------------------------
# Системные каталоги и параметры по умолчанию
# ------------------------------------------------------------------------------
LERS_BASE_DIR="/opt/lers"
COMPOSE_FILE="${LERS_BASE_DIR}/compose.yml"
ENV_FILE="${LERS_BASE_DIR}/.env"

SQLDATA_DIR="${LERS_BASE_DIR}/sqldata"
LERS_DATA_DIR="${LERS_BASE_DIR}/data"
LERS_CONF_DIR="${LERS_BASE_DIR}/config"
BACKUP_DIR="${LERS_BASE_DIR}/backup"
SQL_BACKUP_DIR="${BACKUP_DIR}/sql"
INCOMING_DIR="${BACKUP_DIR}/incoming"
LOCAL_BACKUP_DIR="${BACKUP_DIR}/local"
ENCRYPTED_BACKUP_DIR="${BACKUP_DIR}/encrypted"

PROFILES_FILE="${LERS_CONF_DIR}/profiles.conf"
MSSQL_SA_PASSWORD_FILE="/root/.mssql-sa-password"
RCLONE_CONFIG_FILE="/root/.config/rclone/rclone.conf"

CANONICAL_BACKUP_NAME="LERS_BACKUP.enc"
GDRIVE_REMOTE="${GDRIVE_REMOTE:-gdrive}"
GDRIVE_PATH="${GDRIVE_PATH:-LERS_BACKUP.enc}"
LERS_BACKUP_URL="${LERS_BACKUP_URL:-}"

DEFAULT_LERS_IMAGE="lersamr/full-r:latest"
DEFAULT_MSSQL_IMAGE="mcr.microsoft.com/mssql/server:2022-latest"
DEFAULT_LERS_PORT="10000"
DEFAULT_MSSQL_PORT="1433"
DEFAULT_DB_NAME="LERS"
DEFAULT_MSSQL_PID="Express"

# Активный рабочий профиль SQL в текущей сессии (без жесткой привязки к конкретному адресу)
ACTIVE_SQL_TYPE="WINDOWS"
ACTIVE_HOST=""
ACTIVE_PORT="1433"
ACTIVE_DB="LERS"
ACTIVE_USER="sa"
ACTIVE_PASS=""

# ------------------------------------------------------------------------------
# Вспомогательные функции вывода и безопасности
# ------------------------------------------------------------------------------
info()    { echo -e "${BLUE}[ИНФО]${NC} $1"; }
success() { echo -e "${GREEN}[УСПЕХ]${NC} $1"; }
warn()    { echo -e "${YELLOW}[ВНИМАНИЕ]${NC} $1"; }
error()   { echo -e "${RED}[ОШИБКА]${NC} $1"; }
step()    { echo -e "\n${BOLD}${CYAN}>>> [$1]${NC} ${BOLD}$2${NC}"; }

print_banner() {
    clear 2>/dev/null || true
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}   ${BOLD}${CYAN}LERS DATABASE MANAGER (v3.0 Production-Ready)${NC}                      ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${YELLOW}Установка • Windows SQL • Linux SQL • Docker • Бэкапы • Облако${NC}     ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════╝${NC}"
}

sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

read_secret_masked() {
    local prompt="$1"
    local __resultvar="$2"
    local ch value=""
    printf '%b' "$prompt" >/dev/tty

    while IFS= read -r -s -n 1 ch </dev/tty; do
        if [[ -z "$ch" ]]; then
            printf '\n' >/dev/tty
            break
        elif [[ "$ch" == $'\177' || "$ch" == $'\b' ]]; then
            if [[ -n "$value" ]]; then
                value="${value%?}"
                printf '\b \b' >/dev/tty
            fi
        else
            value+="$ch"
            printf '*' >/dev/tty
        fi
    done

    printf -v "$__resultvar" '%s' "$value"
}

# ------------------------------------------------------------------------------
# 1. СИСТЕМНЫЙ СЛОЙ И ПРОФИЛИ ПОДКЛЮЧЕНИЙ
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
        error "Текущая архитектура: $arch"
        exit 1
    fi
}

clean_broken_third_party_apt() {
    if [[ -f /etc/apt/sources.list.d/msprod.list ]]; then
        warn "Обнаружен сторонний репозиторий /etc/apt/sources.list.d/msprod.list (вызывает ошибку GPG / NO_PUBKEY)."
        mv -f /etc/apt/sources.list.d/msprod.list /etc/apt/sources.list.d/msprod.list.disabled 2>/dev/null || true
        info "Репозиторий отключен (/etc/apt/sources.list.d/msprod.list.disabled) для восстановления нормальной работы APT."
    fi
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

ensure_docker() {
    # 1. Проверяем наличие Docker
    if command -v docker >/dev/null 2>&1; then
        local d_ver
        d_ver="$(docker --version 2>/dev/null || echo "установлен")"
        success "Docker обнаружен: ${d_ver}"
    else
        info "Docker не найден в системе. Подготовка к установке..."
        clean_broken_third_party_apt

        info "Обновление индексов пакетов (apt-get update)..."
        local apt_err=""
        if ! apt_err="$(apt-get update 2>&1)"; then
            warn "Предупреждение при обновлении репозиториев APT:"
            echo "$apt_err" | grep -iE "error|err|fail|no_pubkey" | head -n 5 | sed 's/^/    /' || true
        fi

        info "Установка пакета docker.io..."
        if ! apt-get install -y docker.io; then
            warn "Установка docker.io через стандартный APT завершилась ошибкой."
            info "Попытка установки через официальный скрипт get.docker.com..."
            if curl -fsSL https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null; then
                sh /tmp/get-docker.sh || true
                rm -f /tmp/get-docker.sh
            fi
        fi

        systemctl enable --now docker >/dev/null 2>&1 || true
    fi

    # Жёсткая проверка: если docker не найден после попытки установки — аварийный останов
    if ! command -v docker >/dev/null 2>&1; then
        echo
        error "КРИТИЧЕСКАЯ ОШИБКА: Docker не установлен."
        echo "  Команда 'docker' отсутствует в системе после попытки установки."
        echo "  Причина: сбой в пакетном менеджере APT или отсутствие доступа к репозиториям."
        echo "  Установите Docker вручную:"
        echo "    curl -fsSL https://get.docker.com | sh"
        echo "  Затем повторите запуск мастера."
        return 1
    fi

    # 2. Проверяем наличие Docker Compose (плагин v2)
    if docker compose version >/dev/null 2>&1; then
        local c_ver
        c_ver="$(docker compose version 2>/dev/null || echo "готов")"
        success "Docker Compose обнаружен: ${c_ver}"
    else
        info "Плагин Docker Compose не найден. Установка..."
        # На Ubuntu 24.04 пакет называется docker-compose-v2, на более старых docker-compose-plugin
        apt-get install -y docker-compose-v2 >/dev/null 2>&1 || \
        apt-get install -y docker-compose-plugin >/dev/null 2>&1 || \
        apt-get install -y docker-compose >/dev/null 2>&1 || true

        if ! docker compose version >/dev/null 2>&1; then
            echo
            error "КРИТИЧЕСКАЯ ОШИБКА: Docker Compose plugin недоступен."
            echo "  Команда 'docker compose version' возвращает ошибку."
            echo "  Установите плагин командой:"
            echo "    apt-get install -y docker-compose-v2"
            return 1
        fi
        success "Docker Compose установлен: $(docker compose version)"
    fi

    return 0
}

ensure_rclone() {
    if ! command -v rclone >/dev/null 2>&1; then
        info "Установка rclone для интеграции с облаком..."
        apt-get update -qq && apt-get install -y -qq rclone >/dev/null 2>&1 || {
            curl -4 -fL https://rclone.org/install.sh 2>/dev/null | bash >/dev/null 2>&1 || true
        }
    fi
}

init_profiles_storage() {
    if [[ ! -f "$PROFILES_FILE" ]]; then
        touch "$PROFILES_FILE"
        chmod 600 "$PROFILES_FILE"
        echo "DOCKER|LERS-Docker-Local|127.0.0.1|1433|LERS|sa" >> "$PROFILES_FILE"
    fi
}

init_directories() {
    mkdir -p "${LERS_BASE_DIR}" \
             "${SQLDATA_DIR}" \
             "${LERS_DATA_DIR}" \
             "${LERS_CONF_DIR}" \
             "${BACKUP_DIR}" \
             "${SQL_BACKUP_DIR}" \
             "${INCOMING_DIR}" \
             "${LOCAL_BACKUP_DIR}" \
             "${ENCRYPTED_BACKUP_DIR}"

    chmod 755 "${LERS_BASE_DIR}"
    chmod 700 "${BACKUP_DIR}" "${SQL_BACKUP_DIR}" "${INCOMING_DIR}" "${LOCAL_BACKUP_DIR}" "${ENCRYPTED_BACKUP_DIR}"

    chgrp -R 0 "${SQLDATA_DIR}" "${SQL_BACKUP_DIR}" 2>/dev/null || true
    chmod -R g=u "${SQLDATA_DIR}" "${SQL_BACKUP_DIR}" 2>/dev/null || true

    init_profiles_storage
}

get_or_create_sa_password() {
    if [[ -s "$MSSQL_SA_PASSWORD_FILE" ]]; then
        MSSQL_SA_PASSWORD="$(<"$MSSQL_SA_PASSWORD_FILE")"
    else
        umask 077
        local rnd_hex
        rnd_hex="$(openssl rand -hex 16 2>/dev/null || od -vAn -N16 -tx1 /dev/urandom | tr -d ' \n')"
        MSSQL_SA_PASSWORD="Lers_Sql_${rnd_hex}#2026!"
        printf '%s' "$MSSQL_SA_PASSWORD" > "$MSSQL_SA_PASSWORD_FILE"
        chmod 600 "$MSSQL_SA_PASSWORD_FILE"
        info "Сгенерирован новый пароль SA для MS SQL: сохранён в $MSSQL_SA_PASSWORD_FILE"
    fi
}

save_profile() {
    local p_type="$1" p_label="$2" p_host="$3" p_port="$4" p_db="$5" p_user="$6"
    init_directories
    if [[ -f "$PROFILES_FILE" ]]; then
        grep -v "^${p_type}|${p_label}|" "$PROFILES_FILE" > "${PROFILES_FILE}.tmp" 2>/dev/null || true
        mv -f "${PROFILES_FILE}.tmp" "$PROFILES_FILE"
    fi
    echo "${p_type}|${p_label}|${p_host}|${p_port}|${p_db}|${p_user}" >> "$PROFILES_FILE"
    chmod 600 "$PROFILES_FILE"
}

windows_prompt_params() {
    local force_edit="${1:-0}"
    if [[ "$force_edit" != "1" && -n "$ACTIVE_HOST" && -n "$ACTIVE_PASS" ]]; then
        return 0
    fi

    echo
    echo -e "${BOLD}${CYAN}ПАРАМЕТРЫ WINDOWS MS SQL${NC}"
    echo "────────────────────────────────────────────────────────────"

    local cur_h="${ACTIVE_HOST}"
    local p_prompt="  IP / Host"
    [[ -n "$cur_h" ]] && p_prompt="  IP / Host [${cur_h}]"
    read -rp "${p_prompt}: " in_host
    ACTIVE_HOST="${in_host:-$cur_h}"
    while [[ -z "$ACTIVE_HOST" ]]; do
        warn "Адрес сервера не может быть пустым."
        read -rp "  IP / Host: " in_host
        ACTIVE_HOST="$in_host"
    done

    local def_p="${ACTIVE_PORT:-1433}"
    read -rp "  Порт [${def_p}]: " in_port
    ACTIVE_PORT="${in_port:-$def_p}"

    local def_db="${ACTIVE_DB:-LERS}"
    read -rp "  База данных [${def_db}]: " in_db
    ACTIVE_DB="${in_db:-$def_db}"

    local def_user="${ACTIVE_USER:-sa}"
    read -rp "  Пользователь [${def_user}]: " in_user
    ACTIVE_USER="${in_user:-$def_user}"

    local in_pass=""
    if [[ -n "$ACTIVE_PASS" && "$force_edit" == "1" ]]; then
        read_secret_masked "  Пароль [Enter = оставить прежний]: " in_pass
        echo
        [[ -n "$in_pass" ]] && ACTIVE_PASS="$in_pass"
    else
        while [[ -z "$ACTIVE_PASS" ]]; do
            read_secret_masked "  Пароль: " in_pass
            echo
            ACTIVE_PASS="$in_pass"
            [[ -z "$ACTIVE_PASS" ]] && warn "Пароль не может быть пустым."
        done
    fi

    echo
    echo -e "  Encrypt:                ${GREEN}YES (-N / Encrypt=True)${NC}"
    echo -e "  TrustServerCertificate: ${GREEN}YES (-C / TrustServerCertificate=True)${NC}"
    echo
}

linux_prompt_params() {
    local force_edit="${1:-0}"
    if [[ "$force_edit" != "1" && -n "$ACTIVE_HOST" && -n "$ACTIVE_PASS" ]]; then
        return 0
    fi

    echo
    echo -e "${BOLD}${CYAN}ПАРАМЕТРЫ LINUX MS SQL${NC}"
    echo "────────────────────────────────────────────────────────────"

    local cur_h="${ACTIVE_HOST}"
    local p_prompt="  IP / Host"
    [[ -n "$cur_h" ]] && p_prompt="  IP / Host [${cur_h}]"
    read -rp "${p_prompt}: " in_host
    ACTIVE_HOST="${in_host:-$cur_h}"
    while [[ -z "$ACTIVE_HOST" ]]; do
        warn "Адрес сервера не может быть пустым."
        read -rp "  IP / Host: " in_host
        ACTIVE_HOST="$in_host"
    done

    local def_p="${ACTIVE_PORT:-1433}"
    read -rp "  Порт [${def_p}]: " in_port
    ACTIVE_PORT="${in_port:-$def_p}"

    local def_db="${ACTIVE_DB:-LERS}"
    read -rp "  База данных [${def_db}]: " in_db
    ACTIVE_DB="${in_db:-$def_db}"

    local def_user="${ACTIVE_USER:-sa}"
    read -rp "  Пользователь [${def_user}]: " in_user
    ACTIVE_USER="${in_user:-$def_user}"

    local in_pass=""
    if [[ -n "$ACTIVE_PASS" && "$force_edit" == "1" ]]; then
        read_secret_masked "  Пароль SQL [Enter = оставить прежний]: " in_pass
        echo
        [[ -n "$in_pass" ]] && ACTIVE_PASS="$in_pass"
    else
        while [[ -z "$ACTIVE_PASS" ]]; do
            read_secret_masked "  Пароль SQL: " in_pass
            echo
            ACTIVE_PASS="$in_pass"
            [[ -z "$ACTIVE_PASS" ]] && warn "Пароль не может быть пустым."
        done
    fi
}

# ------------------------------------------------------------------------------
# 2. КЛИЕНТСКИЙ ДВИЖОК SQL (АВТОМАТИЧЕСКИЙ ВЫБОР БЕЗ ЗАВИСАНИЙ)
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

install_go_sqlcmd() {
    echo -e "${BOLD}${CYAN}>>> УСТАНОВКА GO-SQLCMD${NC}"
    
    # [1/4] Определение архитектуры
    echo -n "  [1/4] Определение архитектуры .... "
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
    echo -e "${GREEN}${go_arch}${NC}"

    # Проверка наличия bzip2 / tar / curl
    if ! command -v bzip2 >/dev/null 2>&1; then
        info "Установка bzip2 для распаковки архива..."
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y -qq bzip2 >/dev/null 2>&1 || true
    fi

    # [2/4] Получение версии
    echo -n "  [2/4] Получение версии ............ "
    local candidate_urls=(
        "https://github.com/microsoft/go-sqlcmd/releases/latest/download/sqlcmd-linux-${go_arch}.tar.bz2"
        "https://github.com/microsoft/go-sqlcmd/releases/download/v1.8.2/sqlcmd-linux-${go_arch}.tar.bz2"
        "https://github.com/microsoft/go-sqlcmd/releases/download/v1.8.0/sqlcmd-linux-${go_arch}.tar.bz2"
    )
    echo -e "${GREEN}OK${NC}"

    # [3/4] Загрузка клиента
    echo -n "  [3/4] Загрузка клиента ........... "
    local tmp_dir
    tmp_dir="$(mktemp -d /tmp/lers-sqlcmd-XXXXXX)"
    chmod 700 "$tmp_dir"
    local tmp_tar="${tmp_dir}/sqlcmd-linux-${go_arch}.tar.bz2"

    local download_ok=0
    local used_url=""
    local http_code="000"
    local file_size=0

    for u in "${candidate_urls[@]}"; do
        used_url="$u"
        http_code="$(curl -4 -sL -w "%{http_code}" --retry 2 --connect-timeout 10 -o "$tmp_tar" "$u" 2>/dev/null || echo "000")"
        if [[ "$http_code" == "200" && -s "$tmp_tar" ]]; then
            if bzip2 -t "$tmp_tar" 2>/dev/null; then
                download_ok=1
                break
            fi
        fi
    done

    file_size="$(wc -c < "$tmp_tar" 2>/dev/null || echo 0)"

    if [[ $download_ok -eq 0 ]]; then
        echo -e "${RED}FAILED${NC}"
        echo
        error "Не удалось установить go-sqlcmd."
        echo "  Архитектура : ${go_arch}"
        echo "  URL         : ${used_url}"
        echo "  HTTP status : ${http_code}"
        echo "  Размер      : ${file_size} bytes"
        echo "  Временный файл сохранён:"
        echo "  ${tmp_tar}"
        echo
        warn "Проверьте соединение с GitHub / CDN или установите sqlcmd вручную."
        return 1
    fi
    echo -e "${GREEN}OK (${file_size} bytes)${NC}"

    # [4/4] Распаковка и проверка sqlcmd
    echo -n "  [4/4] Проверка sqlcmd ............ "
    mkdir -p /usr/local/bin
    local tar_err=""
    if ! tar -xjf "$tmp_tar" -C /usr/local/bin/ sqlcmd 2>"${tmp_dir}/tar_err.log"; then
        echo -e "${RED}FAILED${NC}"
        tar_err="$(cat "${tmp_dir}/tar_err.log" 2>/dev/null)"
        error "Ошибка при распаковке архива tar: ${tar_err}"
        return 1
    fi
    chmod +x /usr/local/bin/sqlcmd 2>/dev/null || true
    rm -rf "$tmp_dir"

    if [[ ! -x /usr/local/bin/sqlcmd ]]; then
        echo -e "${RED}FAILED${NC}"
        error "Файл /usr/local/bin/sqlcmd не найден или не является исполняемым."
        return 1
    fi
    echo -e "${GREEN}OK${NC}"

    local v_out
    v_out="$(/usr/local/bin/sqlcmd --version 2>&1 || /usr/local/bin/sqlcmd -? 2>&1 | head -n1 || echo "sqlcmd ready")"
    success "sqlcmd успешно установлен в /usr/local/bin/sqlcmd!"
    info "Версия: ${v_out}"
    echo
    return 0
}

ensure_sql_client() {
    local __client_type_var="$1"
    local __client_path_var="$2"
    local __flags_var="$3"

    local c_type="" c_path="" c_flags=""
    if find_sqlcmd_client c_type c_path c_flags; then
        printf -v "$__client_type_var" '%s' "$c_type"
        printf -v "$__client_path_var" '%s' "$c_path"
        printf -v "$__flags_var" '%s' "$c_flags"
        return 0
    fi

    echo
    echo -e "  [2/5] SQL client .................. ${YELLOW}НЕ НАЙДЕН${NC}"
    echo
    echo "  Для подключения к MS SQL Server нужен sqlcmd."
    echo "  Будет использован официальный автономный go-sqlcmd от Microsoft."
    echo "  APT-репозитории Microsoft изменяться не будут."
    echo
    echo "  [1] Установить"
    echo "  [0] Отмена"
    local inst_c=""
    read -rp "  Выбор [1/0, по умолчанию 1]: " inst_c </dev/tty || inst_c="1"
    inst_c="${inst_c:-1}"
    if [[ "$inst_c" == "1" ]]; then
        if install_go_sqlcmd; then
            if find_sqlcmd_client c_type c_path c_flags; then
                printf -v "$__client_type_var" '%s' "$c_type"
                printf -v "$__client_path_var" '%s' "$c_path"
                printf -v "$__flags_var" '%s' "$c_flags"
                return 0
            fi
        fi
    fi

    error "Клиент sqlcmd не доступен."
    return 1
}

install_native_sqlcmd() {
    info "Установка официального Microsoft sqlcmd..."
    if [[ ! -f /etc/os-release ]]; then
        error "Файл /etc/os-release не найден."
        return 1
    fi
    source /etc/os-release
    local os_id="${ID:-ubuntu}"
    local os_ver="${VERSION_ID:-22.04}"

    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/microsoft.gpg 2>/dev/null || \
        curl -sSL https://packages.microsoft.com/keys/microsoft.asc | apt-key add - 2>/dev/null || true

    local repo_url="https://packages.microsoft.com/config/${os_id}/${os_ver}/prod.list"
    if curl -sSL -f "$repo_url" -o /etc/apt/sources.list.d/msprod.list 2>/dev/null; then
        apt-get update -qq
        ACCEPT_EULA=Y apt-get install -y -qq mssql-tools18 unixodbc-dev >/dev/null 2>&1 || \
        ACCEPT_EULA=Y apt-get install -y -qq mssql-tools unixodbc-dev >/dev/null 2>&1 || true

        if [[ -x /opt/mssql-tools18/bin/sqlcmd ]]; then
            ln -sf /opt/mssql-tools18/bin/sqlcmd /usr/local/bin/sqlcmd
            ln -sf /opt/mssql-tools18/bin/bcp /usr/local/bin/bcp
            success "sqlcmd18 успешно установлен в /usr/local/bin/sqlcmd!"
            return 0
        elif [[ -x /opt/mssql-tools/bin/sqlcmd ]]; then
            ln -sf /opt/mssql-tools/bin/sqlcmd /usr/local/bin/sqlcmd
            ln -sf /opt/mssql-tools/bin/bcp /usr/local/bin/bcp
            success "sqlcmd успешно установлен в /usr/local/bin/sqlcmd!"
            return 0
        fi
    fi

    info "Попытка установки бинарного go-sqlcmd..."
    local go_sqlcmd_url="https://github.com/microsoft/go-sqlcmd/releases/download/v1.8.0/sqlcmd-linux-amd64.tar.bz2"
    local tmp_go="/tmp/sqlcmd.tar.bz2"
    if curl -4 -fL "$go_sqlcmd_url" -o "$tmp_go" 2>/dev/null; then
        tar -xjf "$tmp_go" -C /usr/local/bin/ sqlcmd 2>/dev/null || true
        chmod +x /usr/local/bin/sqlcmd 2>/dev/null || true
        rm -f "$tmp_go"
        if [[ -x /usr/local/bin/sqlcmd ]]; then
            success "go-sqlcmd успешно установлен в /usr/local/bin/sqlcmd!"
            return 0
        fi
    fi

    error "Не удалось автоматически установить sqlcmd."
    return 1
}

remote_sqlcmd() {
    local host="$1" port="$2" user="$3" pass="$4" db="${5:-master}" query="$6" extra_flags="${7:-}" timeout_sec="${8:-20}"
    local client_type="" client_path="" flags=""

    if ! ensure_sql_client client_type client_path flags; then
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
            docker exec -i lers-db bash -c "
                if [ -x /opt/mssql-tools18/bin/sqlcmd ]; then
                    CMD=/opt/mssql-tools18/bin/sqlcmd; FLAGS=\"-C -N\"
                else
                    CMD=/opt/mssql-tools/bin/sqlcmd; FLAGS=\"\"
                fi
                SQLCMDPASSWORD=\"\$(cat)\" timeout ${timeout_sec}s \"\$CMD\" -S '${host},${port}' -U '${user}' -d '${db}' -Q '${query}' \$FLAGS -l $login_timeout -t $timeout_sec $extra_flags -b
            " <<< "$pass"
            ;;
        DOCKER_RUN)
            docker run --rm -i -e "SQLCMDPASSWORD=${pass}" "$client_path" \
                /opt/mssql-tools/bin/sqlcmd -S "${host},${port}" -U "${user}" -d "${db}" -Q "${query}" -l $login_timeout -t $timeout_sec $extra_flags -b
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 3. ШИФРОВАНИЕ И РАСШИФРОВКА (100% совместимо со стандартом setup.sh)
# ------------------------------------------------------------------------------
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
# 4. ДВИЖОК БЭКАПОВ: Dynamic RESTORE, VERIFYONLY, Local Backup
# ------------------------------------------------------------------------------
sql_local_exec() {
    local query="$1" db_context="${2:-master}" extra_flags="${3:-}"
    get_or_create_sa_password
    docker exec -i lers-db bash -c "
        if [ -x /opt/mssql-tools18/bin/sqlcmd ]; then
            CMD=/opt/mssql-tools18/bin/sqlcmd; FLAGS=\"-C\"
        elif [ -x /opt/mssql-tools/bin/sqlcmd ]; then
            CMD=/opt/mssql-tools/bin/sqlcmd; FLAGS=\"\"
        else
            echo 'sqlcmd не найден в контейнере' >&2; exit 1
        fi
        SQLCMDPASSWORD=\"\$MSSQL_SA_PASSWORD\" \"\$CMD\" -S localhost -U sa -d \"$db_context\" -Q \"$query\" \$FLAGS $extra_flags -b
    "
}

get_restore_file_moves() {
    local container_backup_path="$1" target_db_name="${2:-LERS}"
    local raw_filelist
    raw_filelist="$(sql_local_exec "RESTORE FILELISTONLY FROM DISK = N'$(sql_escape "$container_backup_path")';" "master" "-s | -W -h -1" 2>/dev/null || true)"

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

backup_local_database() {
    local out_bak_name="${1:-LERS_backup_$(date +%Y_%m_%d_%H%M%S).bak}"
    local target_bak="${LOCAL_BACKUP_DIR}/${out_bak_name}"

    step "БЭКАП" "Создание локального бэкапа базы LERS..."
    init_directories

    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'lers-db'; then
        error "Контейнер lers-db не запущен!"
        return 1
    fi

    local in_container_path="/var/opt/mssql/backup/${out_bak_name}"
    local sql_query="
        BACKUP DATABASE [${DEFAULT_DB_NAME}]
        TO DISK = N'$(sql_escape "${in_container_path}")'
        WITH COPY_ONLY, COMPRESSION, STATS = 20, FORMAT, INIT;
    "

    sql_local_exec "$sql_query" "master"
    local src_file="${SQL_BACKUP_DIR}/${out_bak_name}"
    [[ -s "$src_file" ]] && mv -f "$src_file" "$target_bak"

    chmod 600 "$target_bak"
    success "Резервная копия создана: $target_bak ($(du -h "$target_bak" | awk '{print $1}'))"
    return 0
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
    success "RESTORE VERIFYONLY: Резервная копия целостна и валидна."

    info "Проверка метаданных заголовка..."
    local header_info
    header_info="$(sql_local_exec "
        SET NOCOUNT ON;
        DECLARE @T TABLE (
            BackupName nvarchar(128), BackupDescription nvarchar(255), BackupType smallint,
            ExpirationDate datetime, Compressed tinyint, Position smallint, DeviceType tinyint,
            UserName nvarchar(128), ServerName nvarchar(128), DatabaseName nvarchar(128),
            DatabaseVersion int, DatabaseCreationDate datetime, BackupSize numeric(20,0),
            FirstLSN numeric(25,0), LastLSN numeric(25,0), CheckpointLSN numeric(25,0),
            DatabaseBackupLSN numeric(25,0), BackupStartDate datetime, BackupFinishDate datetime,
            SortOrder smallint, CodePage smallint, UnicodeLocaleId int, UnicodeComparisonStyle int,
            CompatibilityLevel tinyint, SoftwareVendorId int, SoftwareVersionMajor int,
            SoftwareVersionMinor int, SoftwareVersionBuild int, MachineName nvarchar(128),
            Flags int, BindingID uniqueidentifier, RecoveryForkID uniqueidentifier, Collation nvarchar(128),
            FamilyGUID uniqueidentifier, HasBulkLoggedData bit, IsSnapshot bit, IsReadOnly bit,
            IsSingleUser bit, HasBackupChecksums bit, IsDamaged bit, BeginsLogChain bit,
            IncompleteMetaDataOnly bit, IsForceOffline bit, IsCopyOnly bit, FirstRecoveryForkID uniqueidentifier,
            ForkPointLSN numeric(25,0), RecoveryModel nvarchar(60), DifferentialBaseLSN numeric(25,0),
            DifferentialBaseGUID uniqueidentifier, BackupTypeDescription nvarchar(60), BackupSetGUID uniqueidentifier,
            CompressedBackupSize numeric(20,0), Containment tinyint, KeyAlgorithm nvarchar(32),
            EncryptorThumbprint varbinary(20), EncryptorType nvarchar(32)
        );
        INSERT INTO @T EXEC('RESTORE HEADERONLY FROM DISK = N''$(sql_escape "${container_path}")''');
        SELECT CAST(SoftwareVersionMajor AS varchar) + '|' + ISNULL(DatabaseName,'') + '|' + CONVERT(varchar, BackupFinishDate, 120) + '|' + CAST(ISNULL(BackupSize,0) AS varchar) FROM @T;
    " "master" "-h -1 -W" 2>/dev/null || true)"

    local bak_major=0 bak_dbname="" bak_date="" bak_bytes=0
    if [[ -n "$header_info" ]]; then
        bak_major="$(echo "$header_info" | cut -d'|' -f1 | tr -d ' ')"
        bak_dbname="$(echo "$header_info" | cut -d'|' -f2 | tr -d ' ')"
        bak_date="$(echo "$header_info" | cut -d'|' -f3)"
        bak_bytes="$(echo "$header_info" | cut -d'|' -f4 | tr -d ' ')"
    fi

    local target_major target_pid
    target_major="$(sql_local_exec "SELECT SERVERPROPERTY('ProductMajorVersion')" "master" "-h -1 -W" 2>/dev/null | tr -d ' \r\n')"
    target_pid="$(sql_local_exec "SELECT SERVERPROPERTY('Edition')" "master" "-h -1 -W" 2>/dev/null | tr -d '\r\n')"

    echo "  Исходная база    : ${bak_dbname:-unknown}"
    echo "  Дата создания    : ${bak_date:-unknown}"
    echo "  Размер несжатый  : $(( bak_bytes / 1024 / 1024 )) MB"
    echo "  Версия в бэкапе  : SQL Major ${bak_major:-unknown}"
    echo "  Целевой сервер   : SQL Major ${target_major:-unknown} (${target_pid:-unknown})"

    if [[ -n "$bak_major" && -n "$target_major" ]] && (( bak_major > target_major )); then
        error "База создана в более новой версии SQL Server (${bak_major}), чем целевой сервер (${target_major})!"
        rm -f "$host_sql_bak"
        return 1
    fi

    if [[ "${target_pid:-}" =~ "Express" ]] && (( bak_bytes > 10737418240 )); then
        error "Размер базы данных в бэкапе превышает 10 ГБ (лимит SQL Express)!"
        rm -f "$host_sql_bak"
        return 1
    fi

    rm -f "$host_sql_bak"
    success "Совместимость резервной копии полностью подтверждена."
    return 0
}

# ==============================================================================
# 5. ОБЛАЧНЫЙ СЛОЙ И УНИВЕРСАЛЬНЫЙ ИМПОРТ ПО URL
# ==============================================================================
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
        error "Скачанный файл является HTML-страницей (нет публичного доступа к файлу на Google Drive)."
        rm -f "$dest_file"
        return 1
    fi

    chmod 600 "$dest_file"
    success "Файл успешно загружен: $dest_file ($(du -h "$dest_file" | awk '{print $1}'))"
    return 0
}

download_gdrive_backup() {
    step "GOOGLE DRIVE" "Загрузка файла ${CANONICAL_BACKUP_NAME} через rclone..."
    init_directories
    ensure_rclone

    local target_file="${INCOMING_DIR}/${CANONICAL_BACKUP_NAME}"
    [[ ! -f "$RCLONE_CONFIG_FILE" ]] && { error "rclone не настроен. Запустите 'rclone config'."; return 1; }

    info "Копирование ${GDRIVE_REMOTE}:${GDRIVE_PATH} -> ${target_file}..."
    if rclone copyto -P "${GDRIVE_REMOTE}:${GDRIVE_PATH}" "$target_file"; then
        chmod 600 "$target_file"
        success "Файл успешно получен: $target_file"
        return 0
    else
        error "Не удалось скачать файл через rclone."
        return 1
    fi
}

upload_gdrive_backup() {
    step "GOOGLE DRIVE" "Отправка ${CANONICAL_BACKUP_NAME} в Google Drive..."
    ensure_rclone
    local source_enc="${ENCRYPTED_BACKUP_DIR}/${CANONICAL_BACKUP_NAME}"
    [[ ! -s "$source_enc" ]] && { error "Файл ${CANONICAL_BACKUP_NAME} не найден."; return 1; }
    [[ ! -f "$RCLONE_CONFIG_FILE" ]] && { error "rclone не настроен."; return 1; }

    info "Отправка ${source_enc} -> ${GDRIVE_REMOTE}:${GDRIVE_PATH}..."
    if rclone copyto -P "$source_enc" "${GDRIVE_REMOTE}:${GDRIVE_PATH}"; then
        success "Файл успешно загружен в Google Drive!"
        return 0
    else
        error "Ошибка при выгрузке через rclone."
        return 1
    fi
}

setup_rclone_wizard() {
    step "RCLONE CONFIG" "Мастер настройки Google Drive через rclone..."
    ensure_rclone
    echo "Запуск официального конфигуратора 'rclone config'..."
    rclone config
}

# ==============================================================================
# 6. РАЗДЕЛ [1]: УСТАНОВКА И РАЗВЁРТЫВАНИЕ LERS
# ==============================================================================
install_clean_lers() {
    step "УСТАНОВКА LERS" "Мастер развёртывания сервера ЛЭРС УЧЁТ..."
    if ! ensure_docker; then
        error "Установка ЛЭРС прервана: Docker недоступен."
        return 1
    fi
    ensure_dependencies
    init_directories

    echo "1. Выберите режим развёртывания:"
    echo "  [1] Полный стек: Сервер ЛЭРС + MS SQL Server (Docker Compose на Linux) [По умолчанию]"
    echo "  [2] Только Сервер ЛЭРС (подключение к существующему SQL: Windows или Linux)"
    echo "  [3] Только Служба опроса (lersamr/pollservice для удалённого узла)"
    read -rp "Выбор [1-3, по умолчанию 1]: " inst_mode

    local lers_img="lersamr/full-r:latest"
    [[ "${inst_mode:-1}" == "3" ]] && lers_img="lersamr/pollservice:latest"

    read -rp "Порт сервера ЛЭРС [${DEFAULT_LERS_PORT}]: " user_port
    LERS_PORT="${user_port:-$DEFAULT_LERS_PORT}"

    echo
    echo "2. Выбор редакции MS SQL Server (для контейнера):"
    echo "  [1] Express   — Бесплатная для коммерческой эксплуатации (лимит базы строго 10 ГБ)"
    echo "  [2] Developer — Полный функционал Enterprise (только тест/лаборатория)"
    echo "  [3] Standard  — Коммерческая редакция"
    read -rp "Выбор редакции [1-3, по умолчанию 1]: " pid_choice
    case "${pid_choice:-1}" in
        1) MSSQL_PID="Express" ;;
        2) MSSQL_PID="Developer" ;;
        3) MSSQL_PID="Standard" ;;
        *) MSSQL_PID="Express" ;;
    esac

    get_or_create_sa_password
    generate_compose_files

    info "Загрузка Docker-образов..."
    docker compose -f "$COMPOSE_FILE" pull

    info "Запуск контейнеров..."
    docker compose -f "$COMPOSE_FILE" up -d

    info "Ожидание старта базы данных..."
    wait_for_local_mssql

    sleep 15
    local lers_logs
    lers_logs="$(docker compose -f "$COMPOSE_FILE" logs --tail 40 lers 2>&1 || true)"
    if echo "$lers_logs" | grep -qiE "install.sh|waiting for configuration|initial setup"; then
        info "Запуск встроенного конфигуратора /install.sh..."
        docker compose -f "$COMPOSE_FILE" exec -T lers /install.sh || true
    fi

    verify_lers_health

    local server_ip
    server_ip="$(hostname -I | awk '{print $1}')"
    echo
    echo -e "${GREEN}======================================================================${NC}"
    echo -e "${GREEN}  ✓ СЕРВЕР ЛЭРС УЧЁТ УСПЕШНО РАЗВЁРНУТ!${NC}"
    echo -e "  Веб-интерфейс : ${BOLD}http://${server_ip}:${LERS_PORT}${NC}"
    echo -e "  SQL Server    : 127.0.0.1:${DEFAULT_MSSQL_PORT} (${MSSQL_PID})"
    echo -e "  Пароль SA SQL : Сохранён в ${MSSQL_SA_PASSWORD_FILE}"
    echo -e "${GREEN}======================================================================${NC}"
    echo
}

wait_for_local_mssql() {
    local count=0
    until sql_local_exec "SELECT 1" "master" >/dev/null 2>&1; do
        sleep 2
        count=$((count + 1))
        (( count >= 30 )) && { error "Таймаут старта MS SQL Server."; return 1; }
    done
    success "MS SQL Server готов к работе."
}

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
    image: ${DEFAULT_MSSQL_IMAGE}
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
    info "Проверка доступности ЛЭРС УЧЁТ..."
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
    warn "Веб-интерфейс ещё инициализируется. Проверьте журналы: bash lers-manager.sh logs"
    return 0
}

update_lers_system() {
    step "ОБНОВЛЕНИЕ" "Обновление системы ЛЭРС УЧЁТ..."
    if ! ensure_docker; then
        error "Операция прервана: Docker недоступен."
        return 1
    fi
    [[ ! -f "$COMPOSE_FILE" ]] && { error "Файл compose.yml не найден. Сначала выполните установку."; return 1; }

    local pre_update_bak="LERS_before_update_$(date +%Y_%m_%d_%H%M%S).bak"
    info "Создание обязательной резервной копии базы перед обновлением..."
    backup_local_database "$pre_update_bak" || { error "Не удалось создать бэкап!"; return 1; }

    info "Загрузка обновлений образов (docker compose pull)..."
    docker compose -f "$COMPOSE_FILE" pull

    info "Перезапуск контейнеров с новыми образами..."
    docker compose -f "$COMPOSE_FILE" up -d

    verify_lers_health
    success "Обновление успешно завершено!"
}

# ==============================================================================
# 7. РАЗДЕЛ [3]: WINDOWS MS SQL SERVER (SMB / SFTP / ДИАГНОСТИКА)
# ==============================================================================
windows_mssql_menu() {
    while true; do
        print_banner
        echo -e "${BOLD}  🪟 WINDOWS MS SQL SERVER${NC}"
        local srv_status="[не выбран]"
        [[ -n "$ACTIVE_HOST" ]] && srv_status="[настроен (сессия)]"
        echo -e "  Сервер : ${CYAN}${srv_status}${NC}"
        echo -e "  БД     : ${CYAN}${ACTIVE_DB:-LERS}${NC}"
        echo -e "  User   : ${CYAN}${ACTIVE_USER:-sa}${NC}"
        echo "  ────────────────────────────────────────────────────────────"
        echo "  [1] Подключение и состояние SQL Server"
        echo "  [2] Создать BACKUP на Windows"
        echo "  [3] Скачать существующий .BAK"
        echo "  [4] BACKUP → скачать на VPS"
        echo "  [5] BACKUP → скачать → VERIFYONLY → шифрование"
        echo "  [6] Полный цикл → шифрование → Google Drive"
        echo "  [7] Изменить параметры подключения"
        echo "  [8] Диагностика TCP / TLS / SQL"
        echo "  [0] Назад"
        echo "  ────────────────────────────────────────────────────────────"
        read -rp "Выберите пункт [0-8]: " w_choice

        case "$w_choice" in
            1) windows_prompt_params 0; windows_test_connection ;;
            2) windows_prompt_params 0; windows_create_backup_only ;;
            3) windows_download_only ;;
            4) windows_prompt_params 0; windows_backup_and_download ;;
            5) windows_prompt_params 0; windows_full_pipeline 0 ;;
            6) windows_prompt_params 0; windows_full_pipeline 1 ;;
            7) windows_prompt_params 1 ;;
            8) windows_prompt_params 0; windows_network_diag ;;
            0) return 0 ;;
            *) error "Неверный выбор." ;;
        esac
        echo
        read -rp "Нажмите Enter для продолжения..." _dummy || true
    done
}

windows_test_connection() {
    echo
    echo -e "${BOLD}>>> [ПРОВЕРКА WINDOWS SQL]${NC}"
    echo
    echo -e "${CYAN}Профиль подключения:${NC}"
    echo -e "  Server     : ${BOLD}${ACTIVE_HOST},${ACTIVE_PORT}${NC}"
    echo -e "  Database   : ${BOLD}${ACTIVE_DB}${NC}"
    echo -e "  User       : ${BOLD}${ACTIVE_USER}${NC}"
    echo -e "  Encrypt    : ${GREEN}YES (-N / Encrypt=True)${NC}"
    echo -e "  Trust Cert : ${GREEN}YES (-C / TrustServerCertificate=True)${NC}"
    echo -e "  Timeout    : 20 sec"
    echo

    # [1/5] TCP connectivity
    echo -n "  [1/5] TCP connectivity .................... "
    if timeout 3 bash -c "</dev/tcp/${ACTIVE_HOST}/${ACTIVE_PORT}" 2>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
        echo
        error "TCP failed: сетевой порт ${ACTIVE_PORT} на ${ACTIVE_HOST} не отвечает!"
        warn "Проверьте:"
        warn "  • Включен ли протокол TCP/IP в SQL Server Configuration Manager"
        warn "  • Разрешен ли входящий порт ${ACTIVE_PORT} в Windows Firewall"
        warn "  • Сетевую маршрутизацию / NAT до сервера Windows"
        return 1
    fi

    # [2/5] SQL Client
    echo -n "  [2/5] SQL client .......................... "
    local c_type="" c_path="" c_flags=""
    if ! ensure_sql_client c_type c_path c_flags; then
        return 1
    fi

    local client_desc="${c_path}"
    if [[ "$c_type" == "NATIVE" ]]; then
        local v_info
        v_info="$("$c_path" --version 2>&1 || "$c_path" -? 2>&1 | head -n1 || true)"
        v_info="$(echo "$v_info" | grep -oE 'v[0-9]+(\.[0-9]+)*|Version [0-9]+(\.[0-9]+)*' || true)"
        [[ -n "$v_info" ]] && client_desc="${c_path} (${v_info})"
    elif [[ "$c_type" == "CONTAINER_LERS_DB" ]]; then
        client_desc="Docker container (lers-db)"
    fi
    echo -e "${GREEN}${client_desc}${NC}"

    # [3/5] TLS / SQL Handshake
    echo -n "  [3/5] TLS / SQL handshake ................. "
    local raw_out="" exit_code=0
    raw_out="$(remote_sqlcmd "$ACTIVE_HOST" "$ACTIVE_PORT" "$ACTIVE_USER" "$ACTIVE_PASS" "master" "SELECT 1;" "-h -1 -W" 20 2>&1)" || exit_code=$?

    if [[ $exit_code -eq 124 ]]; then
        echo -e "${RED}TIMEOUT${NC}"
        echo
        error "SQL handshake timeout: SQL Server не ответил за 20 секунд."
        echo
        warn "Проверьте:"
        warn "  • SQL Server Configuration Manager (включен ли TCP/IP)"
        warn "  • Порт ${ACTIVE_PORT} и брандмауэр Windows"
        warn "  • Параметры Encrypt=True / TrustServerCertificate=True"
        warn "  • Состояние службы SQL Server на Windows"
        return 1
    elif [[ $exit_code -ne 0 ]]; then
        echo -e "${RED}FAILED${NC}"
        echo
        if echo "$raw_out" | grep -qiE "login failed|password|authenticat"; then
            error "Authentication failed: ошибка проверки логина или пароля '${ACTIVE_USER}'."
        else
            error "SQL handshake / connection failed:"
        fi
        echo "$raw_out" | sed 's/^/    /'
        echo
        warn "Проверьте:"
        warn "  • Включен ли смешанный режим (SQL Server and Windows Authentication mode)"
        warn "  • Учетная запись '${ACTIVE_USER}' активна и не заблокирована"
        warn "  • Корректность пароля SQL"
        return 1
    fi
    echo -e "${GREEN}OK${NC}"
    if [[ "$c_flags" =~ "-C" ]]; then
        echo -e "        ${CYAN}⚠ TrustServerCertificate = YES (принят сертификат сервера)${NC}"
    fi

    # [4/5] SQL Authentication
    echo -n "  [4/5] SQL authentication .................. "
    echo -e "${GREEN}OK (${ACTIVE_USER})${NC}"

    # [5/5] Database check & Full diagnostics query
    echo -n "  [5/5] Database [${ACTIVE_DB}] ....................... "
    local check_query="
        SET NOCOUNT ON;
        SELECT
            ISNULL(CAST(@@SERVERNAME AS varchar), CAST(SERVERPROPERTY('ServerName') AS varchar)) + '|' +
            DB_NAME() + '|' +
            CAST(SERVERPROPERTY('ProductVersion') AS varchar) + '|' +
            CAST(DATABASEPROPERTYEX(DB_NAME(), 'Status') AS varchar) + '|' +
            CAST(SERVERPROPERTY('Edition') AS varchar);
    "
    local check_res="" check_exit=0
    check_res="$(remote_sqlcmd "$ACTIVE_HOST" "$ACTIVE_PORT" "$ACTIVE_USER" "$ACTIVE_PASS" "$ACTIVE_DB" "$check_query" "-h -1 -W" 20 2>&1)" || check_exit=$?

    if [[ $check_exit -ne 0 ]]; then
        echo -e "${RED}FAILED${NC}"
        echo
        error "Database unavailable или ошибка выполнения запроса:"
        echo "$check_res" | sed 's/^/    /'
        return 1
    fi

    local line srv_name curr_db ver db_status edition
    line="$(echo "$check_res" | grep '|' | tail -n1)"
    srv_name="$(echo "$line" | cut -d'|' -f1 | tr -d ' 
')"
    curr_db="$(echo "$line" | cut -d'|' -f2 | tr -d ' 
')"
    ver="$(echo "$line" | cut -d'|' -f3 | tr -d ' 
')"
    db_status="$(echo "$line" | cut -d'|' -f4 | tr -d ' 
')"
    edition="$(echo "$line" | cut -d'|' -f5 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | tr -d '
')"

    if [[ "$db_status" == "ONLINE" ]]; then
        echo -e "${GREEN}OK (ONLINE)${NC}"
    else
        echo -e "${YELLOW}${db_status:-UNKNOWN}${NC}"
    fi

    echo
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${BOLD}${GREEN} WINDOWS SQL CONNECTION — OK${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo -e "  Server     : ${BOLD}${ACTIVE_HOST},${ACTIVE_PORT}${NC} (${srv_name:-MSSQL})"
    echo -e "  Database   : ${BOLD}[${curr_db:-$ACTIVE_DB}]${NC} — Статус: ${GREEN}${db_status:-ONLINE}${NC}"
    echo -e "  Login      : ${BOLD}${ACTIVE_USER}${NC}"
    echo -e "  Encryption : ${GREEN}YES (-N / Encrypt=True)${NC}"
    echo -e "  Trust Cert : ${GREEN}YES (-C / TrustServerCertificate=True)${NC}"
    echo
    echo -e "  SQL Server : ${BOLD}${ver:-unknown}${NC}"
    echo -e "  Edition    : ${BOLD}${edition:-unknown}${NC}"
    echo
    echo "  Connection test:"
    echo -e "    SELECT 1 ..................... ${GREEN}OK${NC}"
    echo -e "    DB_NAME() .................... ${GREEN}${curr_db:-$ACTIVE_DB}${NC}"
    echo -e "    @@SERVERNAME ................. ${GREEN}${srv_name:-MSSQL}${NC}"
    echo -e "    Status ....................... ${GREEN}${db_status:-ONLINE}${NC}"
    echo -e "${CYAN}============================================================${NC}"
    return 0
}

windows_create_backup_only() {
    step "WINDOWS BACKUP" "Создание бэкапа на удалённом сервере Windows..."
    [[ -z "$ACTIVE_PASS" ]] && read_secret_masked "Пароль SQL: " ACTIVE_PASS
    local def_p="C:\\Backup\\LERS_backup_$(date +%Y_%m_%d_%H%M%S).bak"
    read -rp "Путь на сервере Windows [$def_p]: " rem_path
    rem_path="${rem_path:-$def_p}"

    info "Выполнение BACKUP DATABASE [${ACTIVE_DB}] TO DISK = N'${rem_path}'..."
    local b_query="BACKUP DATABASE [$(sql_escape "$ACTIVE_DB")] TO DISK = N'$(sql_escape "$rem_path")' WITH COPY_ONLY, COMPRESSION, STATS = 20, FORMAT, INIT;"
    remote_sqlcmd "$ACTIVE_HOST" "$ACTIVE_PORT" "$ACTIVE_USER" "$ACTIVE_PASS" "master" "$b_query" "" 300
    success "Резервная копия создана на сервере: ${rem_path}"
}

windows_download_transport() {
    local default_rem_path="${1:-}" __res_local_var="$2"
    echo
    echo "Выберите транспорт для передачи файла с Windows:"
    echo "  [1] SMB / Windows Share (smbclient — родной протокол Windows, без SSH)"
    echo "  [2] SFTP / SCP (OpenSSH на Windows)"
    read -rp "Выбор [1-2, по умолчанию 1]: " t_c

    local local_file=""
    if [[ "${t_c:-1}" == "1" ]]; then
        ensure_dependencies
        info "Настройка передачи через Windows Network Share (SMB):"
        local def_smb_h="${ACTIVE_HOST}"
        local prompt_smb_h="Хост Windows (IP или имя)"
        [[ -n "$def_smb_h" ]] && prompt_smb_h="Хост Windows (IP или имя) [${def_smb_h}]"
        read -rp "  ${prompt_smb_h}: " in_smb_host
        local smb_h="${in_smb_host:-$def_smb_h}"
        while [[ -z "$smb_h" ]]; do
            read -rp "  Введите IP адрес или имя хоста Windows: " smb_h
        done
        read -rp "Ресурс (Share) [C$ или Backup]: " smb_s
        smb_s="${smb_s:-C$}"
        read -rp "Пользователь Windows [Administrator]: " smb_u
        smb_u="${smb_u:-Administrator}"
        local smb_p=""
        read_secret_masked "Пароль Windows (${smb_u}): " smb_p
        echo

        local def_f="Backup\\LERS_backup.bak"
        [[ -n "$default_rem_path" ]] && def_f="${default_rem_path#*:\\}"
        read -rp "Путь внутри ресурса [${def_f}]: " smb_f
        smb_f="${smb_f:-$def_f}"
        smb_f="${smb_f//\//\\}"

        local target_name
        target_name="$(basename "${smb_f//\\//}")"
        local_file="${INCOMING_DIR}/${target_name}"

        local auth_f
        auth_f="$(mktemp /tmp/smb_auth.XXXXXX)"
        chmod 600 "$auth_f"
        cat > "$auth_f" <<EOF
username = ${smb_u}
password = ${smb_p}
EOF

        info "Скачивание //${smb_h}/${smb_s}/${smb_f} -> ${local_file}..."
        if smbclient "//${smb_h}/${smb_s}" -A "$auth_f" -c "get \"${smb_f}\" \"${local_file}\"" 2>&1; then
            rm -f "$auth_f"
            chmod 600 "$local_file"
            success "Файл получен по SMB: $local_file ($(du -h "$local_file" | awk '{print $1}'))"
        else
            rm -f "$auth_f"
            error "Сбой передачи SMB."
            return 1
        fi
    else
        local def_s_h="${ACTIVE_HOST}"
        local prompt_s_h="SSH хост (IP или имя)"
        [[ -n "$def_s_h" ]] && prompt_s_h="SSH хост (IP или имя) [${def_s_h}]"
        read -rp "  ${prompt_s_h}: " in_s_h
        local s_h="${in_s_h:-$def_s_h}"
        while [[ -z "$s_h" ]]; do
            read -rp "  Введите IP адрес или имя SSH хоста: " s_h
        done
        read -rp "SSH порт [22]: " s_port
        s_port="${s_port:-22}"
        read -rp "SSH пользователь [Administrator]: " s_user
        s_user="${s_user:-Administrator}"
        local def_sftp="/C:/Backup/LERS_backup.bak"
        [[ -n "$default_rem_path" ]] && def_sftp="/${default_rem_path//\\//}"
        read -rp "SFTP путь [${def_sftp}]: " s_path
        s_path="${s_path:-$def_sftp}"

        local target_name
        target_name="$(basename "$s_path")"
        local_file="${INCOMING_DIR}/${target_name}"

        info "Скачивание через SCP с ${s_h}:${s_port}..."
        scp -P "$s_port" "${s_user}@${s_h}:${s_path}" "$local_file"
        chmod 600 "$local_file"
        success "Файл получен через SCP: $local_file"
    fi

    printf -v "$__res_local_var" '%s' "$local_file"
    return 0
}

windows_download_only() {
    step "СКАЧИВАНИЕ .BAK" "Скачивание существующего файла с Windows без шифрования..."
    local dest=""
    if windows_download_transport "" dest; then
        success "Файл сохранён в папке входящих: $dest"
    fi
}

windows_backup_and_download() {
    step "BACKUP И СКАЧИВАНИЕ" "Создание бэкапа на Windows и передача на VPS..."
    [[ -z "$ACTIVE_PASS" ]] && read_secret_masked "Пароль SQL: " ACTIVE_PASS
    local rem_path="C:\\Backup\\LERS_$(date +%Y%m%d_%H%M%S).bak"
    local b_query="BACKUP DATABASE [$(sql_escape "$ACTIVE_DB")] TO DISK = N'$(sql_escape "$rem_path")' WITH COPY_ONLY, COMPRESSION, STATS = 20, FORMAT, INIT;"
    remote_sqlcmd "$ACTIVE_HOST" "$ACTIVE_PORT" "$ACTIVE_USER" "$ACTIVE_PASS" "master" "$b_query" "" 300
    success "Бэкап создан на Windows: $rem_path"

    local dest=""
    if windows_download_transport "$rem_path" dest; then
        success "Файл успешно скопирован на VPS: $dest"
    fi
}

windows_full_pipeline() {
    local upload_cloud="$1"
    step "ПОЛНЫЙ ЦИКЛ" "Запуск сквозного конвейера резервного копирования..."
    [[ -z "$ACTIVE_PASS" ]] && read_secret_masked "Пароль SQL: " ACTIVE_PASS

    local rem_path="C:\\Backup\\LERS_auto_$(date +%Y%m%d_%H%M%S).bak"
    info "[1/5] Выполнение BACKUP DATABASE на Windows..."
    local b_query="BACKUP DATABASE [$(sql_escape "$ACTIVE_DB")] TO DISK = N'$(sql_escape "$rem_path")' WITH COPY_ONLY, COMPRESSION, STATS = 20, FORMAT, INIT;"
    remote_sqlcmd "$ACTIVE_HOST" "$ACTIVE_PORT" "$ACTIVE_USER" "$ACTIVE_PASS" "master" "$b_query" "" 300

    info "[2/5] Скачивание файла на VPS..."
    local downloaded=""
    windows_download_transport "$rem_path" downloaded

    info "[3/5] Валидация файла через RESTORE VERIFYONLY..."
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'lers-db'; then
        verify_sql_backup "$downloaded"
    else
        warn "Локальный контейнер lers-db не запущен, пропуск VERIFYONLY."
    fi

    info "[4/5] Шифрование в ${CANONICAL_BACKUP_NAME} (AES-256-CBC PBKDF2)..."
    local epass=""
    read_secret_masked "Пароль шифрования бэкапа: " epass
    echo
    local canonical_f="${ENCRYPTED_BACKUP_DIR}/${CANONICAL_BACKUP_NAME}"
    encrypt_archive "$downloaded" "$canonical_f" "$epass"

    echo
    echo "Действие с исходным скачанным файлом .bak:"
    echo "  [1] Удалить .bak (оставить только зашифрованный .enc)"
    echo "  [2] Сохранить оба файла (.bak и .enc)"
    read -rp "Выбор [1/2, по умолчанию 1]: " del_c
    [[ "${del_c:-1}" == "1" ]] && rm -f "$downloaded"

    if [[ "$upload_cloud" == "1" ]]; then
        info "[5/5] Загрузка ${CANONICAL_BACKUP_NAME} в Google Drive..."
        upload_gdrive_backup || true
    fi
    success "Конвейер успешно завершён!"
}

windows_network_diag() {
    step "ДИАГНОСТИКА СЕТИ" "Проверка сетевого взаимодействия с сервером Windows..."
    echo "  Хост: ${ACTIVE_HOST}, Порт: ${ACTIVE_PORT}"
    ping -c 3 -W 2 "$ACTIVE_HOST" 2>/dev/null || warn "ICMP Ping заблокирован (нормально для Windows Firewall)."

    if timeout 3 bash -c "</dev/tcp/${ACTIVE_HOST}/${ACTIVE_PORT}" 2>/dev/null; then
        success "TCP порт SQL Server (${ACTIVE_PORT}) ОТКРЫТ."
    else
        error "TCP порт SQL Server (${ACTIVE_PORT}) ЗАКРЫТ или блокируется."
    fi

    if timeout 3 bash -c "</dev/tcp/${ACTIVE_HOST}/445" 2>/dev/null; then
        success "TCP порт SMB/CIFS (445) ОТКРЫТ."
    else
        warn "TCP порт SMB (445) закрыт."
    fi
}

# ==============================================================================
# 8. РАЗДЕЛ [4]: LINUX MS SQL SERVER
# ==============================================================================
linux_mssql_menu() {
    while true; do
        print_banner
        echo -e "${BOLD}  🐧 LINUX MS SQL SERVER${NC}"
        local srv_status="[не выбран]"
        [[ -n "$ACTIVE_HOST" ]] && srv_status="[настроен (сессия)]"
        echo -e "  Сервер : ${CYAN}${srv_status}${NC}"
        echo -e "  БД     : ${CYAN}${ACTIVE_DB:-LERS}${NC}"
        echo -e "  User   : ${CYAN}${ACTIVE_USER:-sa}${NC}"
        echo "  ────────────────────────────────────────────────────────────"
        echo "  [1] Подключение и состояние SQL Server"
        echo "  [2] Создать BACKUP на Linux сервере (/var/opt/mssql/backup/...)"
        echo "  [3] Скачать BACKUP на VPS через SCP"
        echo "  [4] Создать BACKUP → Скачать → VERIFYONLY"
        echo "  [5] Полный цикл → Зашифровать → Google Drive"
        echo "  [6] Изменить параметры подключения"
        echo "  [0] Назад в главное меню"
        echo "  ────────────────────────────────────────────────────────────"
        read -rp "Выберите пункт [0-6]: " l_choice

        case "$l_choice" in
            1) linux_prompt_params 0; windows_test_connection ;;
            2)
                linux_prompt_params 0
                local rem_p="/var/opt/mssql/backup/LERS_$(date +%Y%m%d_%H%M%S).bak"
                read -rp "Путь на Linux сервере [$rem_p]: " in_p
                rem_p="${in_p:-$rem_p}"
                remote_sqlcmd "$ACTIVE_HOST" "$ACTIVE_PORT" "$ACTIVE_USER" "$ACTIVE_PASS" "master" \
                    "BACKUP DATABASE [$(sql_escape "$ACTIVE_DB")] TO DISK = N'$(sql_escape "$rem_p")' WITH COPY_ONLY, COMPRESSION, FORMAT, INIT;" "" 300
                success "Бэкап создан: $rem_p"
                ;;
            3)
                local def_lh="${ACTIVE_HOST}"
                local prompt_lh="IP / Хост Linux"
                [[ -n "$def_lh" ]] && prompt_lh="IP / Хост Linux [${def_lh}]"
                read -rp "  ${prompt_lh}: " in_lh
                local target_lh="${in_lh:-$def_lh}"
                while [[ -z "$target_lh" ]]; do
                    read -rp "  Введите IP адрес или имя хоста Linux: " target_lh
                done
                read -rp "SSH порт [22]: " s_port
                s_port="${s_port:-22}"
                read -rp "SSH пользователь [root]: " s_u
                s_u="${s_u:-root}"
                read -rp "Путь на сервере [/var/opt/mssql/backup/LERS.bak]: " s_p
                s_p="${s_p:-/var/opt/mssql/backup/LERS.bak}"
                local local_f="${INCOMING_DIR}/$(basename "$s_p")"
                info "Скачивание через SCP с ${target_lh}:${s_port}..."
                scp -P "$s_port" "${s_u}@${target_lh}:${s_p}" "$local_f"
                chmod 600 "$local_f"
                success "Файл скачан: $local_f"
                ;;
            4)
                linux_prompt_params 0
                windows_full_pipeline 0
                ;;
            5)
                linux_prompt_params 0
                windows_full_pipeline 1
                ;;
            6) linux_prompt_params 1 ;;
            0) return 0 ;;
            *) error "Неверный выбор." ;;
        esac
        echo
        read -rp "Нажмите Enter для продолжения..." _dummy || true
    done
}

# ==============================================================================
# 9. РАЗДЕЛ [5]: DOCKER MS SQL SERVER
# ==============================================================================
docker_mssql_menu() {
    if ! ensure_docker; then
        error "Раздел недоступен: Docker не установлен."
        echo
        read -rp "Нажмите Enter для продолжения..." _dummy || true
        return 1
    fi

    while true; do
        print_banner
        echo -e "${BOLD}  🐳 DOCKER MS SQL SERVER${NC}"
        echo "  Контейнер: lers-db  |  Порт: 1433  |  Том: /var/opt/mssql/backup"
        echo "  ────────────────────────────────────────────────────────────"
        echo "  [1] Проверить состояние контейнера lers-db"
        echo "  [2] Создать BACKUP внутри контейнера"
        echo "  [3] Показать список файлов в каталоге бэкапов"
        echo "  [4] Проверить последний бэкап (VERIFYONLY)"
        echo "  [5] Зашифровать бэкап в ${CANONICAL_BACKUP_NAME}"
        echo "  [6] Загрузить зашифрованный бэкап в Google Drive"
        echo "  [7] Логи контейнера базы данных (docker logs lers-db)"
        echo "  [0] Назад в главное меню"
        echo "  ────────────────────────────────────────────────────────────"
        read -rp "Выберите пункт [0-7]: " d_choice

        case "$d_choice" in
            1)
                docker compose -f "$COMPOSE_FILE" ps db 2>/dev/null || docker ps -f name=lers-db
                ;;
            2) backup_local_database ;;
            3)
                echo "Файлы в ${LOCAL_BACKUP_DIR}:"
                ls -lh "${LOCAL_BACKUP_DIR}"
                ;;
            4)
                local last_b
                last_b="$(find "${LOCAL_BACKUP_DIR}" -name "*.bak" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -f2- -d" ")"
                [[ -s "$last_b" ]] && verify_sql_backup "$last_b" || warn "Бэкапов не найдено."
                ;;
            5)
                local last_b
                last_b="$(find "${LOCAL_BACKUP_DIR}" -name "*.bak" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -f2- -d" ")"
                if [[ -s "$last_b" ]]; then
                    local p=""
                    read_secret_masked "Пароль шифрования: " p
                    echo
                    encrypt_archive "$last_b" "${ENCRYPTED_BACKUP_DIR}/${CANONICAL_BACKUP_NAME}" "$p"
                fi
                ;;
            6) upload_gdrive_backup ;;
            7) docker compose -f "$COMPOSE_FILE" logs --tail 100 db ;;
            0) return 0 ;;
            *) error "Неверный выбор." ;;
        esac
        echo
        read -rp "Нажмите Enter для продолжения..." _dummy || true
    done
}

# ==============================================================================
# 10. РАЗДЕЛ [6]: РЕЗЕРВНОЕ КОПИРОВАНИЕ И ВОССТАНОВЛЕНИЕ (ОБЩИЙ ДВИЖОК)
# ==============================================================================
backup_restore_menu() {
    while true; do
        print_banner
        echo -e "${BOLD}  💾 РЕЗЕРВНОЕ КОПИРОВАНИЕ И ВОССТАНОВЛЕНИЕ LERS${NC}"
        echo "  ────────────────────────────────────────────────────────────"
        echo "  [1] Восстановить базу данных LERS (по URL, GDrive или файлу)"
        echo "  [2] Создать обычный локальный бэкап (.bak)"
        echo "  [3] Создать ЗАШИФРОВАННЫЙ бэкап (AES-256-CBC -> ${CANONICAL_BACKUP_NAME})"
        echo "  [4] Проверить целостность любого бэкапа (VERIFYONLY)"
        echo "  [5] Показать все сохранённые бэкапы (размеры, даты)"
        echo "  [6] Очистить старые бэкапы и временные файлы"
        echo "  [0] Назад в главное меню"
        echo "  ────────────────────────────────────────────────────────────"
        read -rp "Выберите пункт [0-6]: " br_choice

        case "$br_choice" in
            1) restore_database_flow ;;
            2) backup_local_database ;;
            3) backup_and_encrypt_local_database ;;
            4)
                read -rp "Путь к файлу для проверки: " vf
                if [[ -s "$vf" ]]; then
                    local chk_bak=""
                    if prepare_sql_bak_from_source "$vf" chk_bak; then
                        verify_sql_backup "$chk_bak"
                    fi
                fi
                ;;
            5)
                echo "1. Локальные сырые бэкапы (${LOCAL_BACKUP_DIR}):"
                ls -lh "${LOCAL_BACKUP_DIR}" 2>/dev/null || true
                echo
                echo "2. Зашифрованные бэкапы (${ENCRYPTED_BACKUP_DIR}):"
                ls -lh "${ENCRYPTED_BACKUP_DIR}" 2>/dev/null || true
                echo
                echo "3. Входящие бэкапы (${INCOMING_DIR}):"
                ls -lh "${INCOMING_DIR}" 2>/dev/null || true
                ;;
            6)
                read -rp "Удалить временные файлы из ${INCOMING_DIR}? [y/N]: " del_tmp
                [[ "$del_tmp" =~ ^[YyДд]$ ]] && rm -rf "${INCOMING_DIR}"/* && success "Очищено."
                ;;
            0) return 0 ;;
            *) error "Неверный выбор." ;;
        esac
        echo
        read -rp "Нажмите Enter для продолжения..." _dummy || true
    done
}

backup_and_encrypt_local_database() {
    step "ЗАШИФРОВАННЫЙ БЭКАП" "Создание и шифрование копии БД LERS..."
    init_directories

    local ts
    ts="$(date +%Y_%m_%d_%H%M%S)"
    local raw_bak_name="LERS_raw_${ts}.bak"
    local raw_bak_path="${LOCAL_BACKUP_DIR}/${raw_bak_name}"
    local enc_name="LERS_backup_${ts}.bak.enc"
    local enc_path="${ENCRYPTED_BACKUP_DIR}/${enc_name}"
    local canonical_path="${ENCRYPTED_BACKUP_DIR}/${CANONICAL_BACKUP_NAME}"

    if ! backup_local_database "$raw_bak_name"; then
        return 1
    fi

    echo
    echo -e "${YELLOW}Введите мастер-пароль для шифрования (AES-256-CBC + PBKDF2):${NC}"
    local pass1 pass2
    read_secret_masked "Пароль шифрования : " pass1
    read_secret_masked "Повторите пароль  : " pass2

    if [[ -z "$pass1" || "$pass1" != "$pass2" ]]; then
        error "Пароли не совпадают или пусты."
        rm -f "$raw_bak_path"
        return 1
    fi

    if ! encrypt_archive "$raw_bak_path" "$enc_path" "$pass1"; then
        rm -f "$raw_bak_path"
        return 1
    fi

    cp -f "$enc_path" "$canonical_path"
    chmod 600 "$canonical_path"
    rm -f "$raw_bak_path"

    echo
    echo -e "${GREEN}======================================================================${NC}"
    echo -e "${GREEN}  ✓ ЗАШИФРОВАННЫЙ БЭКАП УСПЕШНО СОЗДАН!${NC}"
    echo -e "  Файл: ${BOLD}${canonical_path}${NC} ($(du -h "$canonical_path" | awk '{print $1}'))"
    echo -e "${GREEN}======================================================================${NC}"
    echo
    return 0
}

restore_database_flow() {
    step "ВОССТАНОВЛЕНИЕ" "Мастер восстановления базы данных ЛЭРС УЧЁТ..."
    init_directories

    local pre_url="${LERS_BACKUP_URL:-}"
    [[ -z "$pre_url" && -f "$ENV_FILE" ]] && pre_url="$(grep -E '^LERS_BACKUP_URL=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"\r\n' || true)"

    echo "Выберите источник резервной копии:"
    echo "  [1] Скачать по ссылке (Google Drive публичная ссылка / любой HTTP/HTTPS URL)"
    if [[ -n "$pre_url" ]]; then
        echo "  [2] Использовать сохранённый URL (${pre_url:0:50}...)"
    fi
    echo "  [3] Указать локальный файл на сервере (.bak, .enc, .zip, .tar.gz)"
    echo "  [4] Выбрать файл из папки входящих (${INCOMING_DIR})"
    echo "  [5] Загрузить ${CANONICAL_BACKUP_NAME} из Google Drive через rclone"
    echo "  [0] Отмена"
    echo
    read -rp "Ваш выбор: " src_choice

    local source_file=""
    case "$src_choice" in
        1)
            read -rp "Введите ссылку: " download_url
            [[ -z "$download_url" ]] && { error "URL пуст."; return 1; }
            local dest_name="LERS_backup_downloaded_$(date +%Y_%m_%d_%H%M%S).tmp"
            source_file="${INCOMING_DIR}/${dest_name}"
            download_public_url "$download_url" "$source_file"
            ;;
        2)
            [[ -z "$pre_url" ]] && { error "Сохранённый URL отсутствует."; return 1; }
            local dest_name="LERS_backup_downloaded_$(date +%Y_%m_%d_%H%M%S).tmp"
            source_file="${INCOMING_DIR}/${dest_name}"
            download_public_url "$pre_url" "$source_file"
            ;;
        3)
            read -rp "Введите полный путь к файлу: " source_file
            ;;
        4)
            local files=()
            mapfile -t files < <(find "${INCOMING_DIR}" -type f \( -iname "*.bak" -o -iname "*.enc" -o -iname "*.zip" -o -iname "*.gz" -o -iname "*.tar.gz" \) -print)
            [[ ${#files[@]} -eq 0 ]] && { warn "Файлов не найдено."; return 0; }
            local i=1
            for f in "${files[@]}"; do
                echo "  [$i] $(basename "$f") ($(du -h "$f" | awk '{print $1}'))"
                i=$((i + 1))
            done
            read -rp "Номер [1-${#files[@]}]: " f_num
            source_file="${files[$((f_num - 1))]}"
            ;;
        5)
            download_gdrive_backup
            source_file="${INCOMING_DIR}/${CANONICAL_BACKUP_NAME}"
            ;;
        0) return 0 ;;
        *) error "Неверный выбор."; return 1 ;;
    esac

    [[ ! -s "$source_file" ]] && { error "Файл не найден или пуст."; return 1; }

    local target_bak=""
    prepare_sql_bak_from_source "$source_file" target_bak

    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'lers-db'; then
        info "Запуск контейнера MS SQL Server..."
        generate_compose_files
        docker compose -f "$COMPOSE_FILE" up -d db
        wait_for_local_mssql
    fi

    verify_sql_backup "$target_bak"

    local check_db
    check_db="$(sql_local_exec "IF DB_ID('${DEFAULT_DB_NAME}') IS NOT NULL PRINT 'EXISTS'" "master" 2>/dev/null | tr -d '\r\n ')"
    if [[ "$check_db" == *"EXISTS"* ]]; then
        info "Создание резервного снимка текущей базы..."
        backup_local_database "LERS_safety_before_restore_$(date +%Y_%m_%d_%H%M%S).bak" || true
    fi

    read -rp "Подтвердите замену рабочей базы данных LERS? [y/N]: " confirm_restore
    [[ ! "$confirm_restore" =~ ^[YyДд]$ ]] && { info "Отменено."; return 0; }

    docker compose -f "$COMPOSE_FILE" stop lers >/dev/null 2>&1 || true

    local restore_bak_name="restore_target_$(date +%s).bak"
    local restore_host_path="${SQL_BACKUP_DIR}/${restore_bak_name}"
    cp -f "$target_bak" "$restore_host_path"
    chmod 600 "$restore_host_path"
    chgrp 0 "$restore_host_path" 2>/dev/null || true
    local container_restore_path="/var/opt/mssql/backup/${restore_bak_name}"

    local move_statements
    move_statements="$(get_restore_file_moves "$container_restore_path" "${DEFAULT_DB_NAME}")"

    local restore_cmd="
        USE master;
        IF DB_ID('${DEFAULT_DB_NAME}') IS NOT NULL ALTER DATABASE [${DEFAULT_DB_NAME}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
        RESTORE DATABASE [${DEFAULT_DB_NAME}] FROM DISK = N'$(sql_escape "${container_restore_path}")' WITH REPLACE, ${move_statements};
        ALTER DATABASE [${DEFAULT_DB_NAME}] SET MULTI_USER;
    "

    info "Восстановление базы в MS SQL Server..."
    sql_local_exec "$restore_cmd" "master"
    rm -f "$restore_host_path"
    cleanup_orphaned_ndf_files "${DEFAULT_DB_NAME}"

    info "Запуск службы ЛЭРС..."
    docker compose -f "$COMPOSE_FILE" up -d lers
    verify_lers_health
    return 0
}

# ==============================================================================
# 11. РАЗДЕЛ [7]: ПРОВЕРКА БАЗЫ ДАННЫХ LERS
# ==============================================================================
check_database_menu() {
    while true; do
        print_banner
        echo -e "${BOLD}  🔍 ПРОВЕРКА И СОСТОЯНИЕ БАЗЫ ДАННЫХ LERS${NC}"
        echo "  ────────────────────────────────────────────────────────────"
        echo "  [1] Проверить существование и статус базы LERS"
        echo "  [2] Проверить ключевые таблицы LERS (Objects, MeasurePoints...)"
        echo "  [3] Показать размер таблиц и статистику базы"
        echo "  [4] Проверить целостность базы (DBCC CHECKDB)"
        echo "  [5] Проверить права учетной записи SQL"
        echo "  [0] Назад в главное меню"
        echo "  ────────────────────────────────────────────────────────────"
        read -rp "Выберите пункт [0-5]: " cdb_choice

        case "$cdb_choice" in
            1)
                sql_local_exec "SELECT name, state_desc, collation_name, compatibility_level, create_date FROM sys.databases WHERE name='${DEFAULT_DB_NAME}'" "master"
                ;;
            2)
                local t_query="
                    USE [${DEFAULT_DB_NAME}];
                    SELECT name, create_date FROM sys.tables WHERE name IN ('Object', 'Node', 'MeasurePoint', 'SystemParameter', 'Core_User', 'Account') ORDER BY name;
                "
                sql_local_exec "$t_query" "${DEFAULT_DB_NAME}"
                ;;
            3)
                sql_local_exec "USE [${DEFAULT_DB_NAME}]; EXEC sp_spaceused;" "${DEFAULT_DB_NAME}"
                ;;
            4)
                info "Запуск DBCC CHECKDB [${DEFAULT_DB_NAME}]..."
                sql_local_exec "DBCC CHECKDB([${DEFAULT_DB_NAME}]) WITH NO_INFOMSGS;" "master"
                success "DBCC CHECKDB завершён без критических ошибок."
                ;;
            5)
                sql_local_exec "SELECT SUSER_NAME() AS CurrentUser, IS_SRVROLEMEMBER('sysadmin') AS IsSysadmin;" "master"
                ;;
            0) return 0 ;;
            *) error "Неверный выбор." ;;
        esac
        echo
        read -rp "Нажмите Enter для продолжения..." _dummy || true
    done
}

# ==============================================================================
# 12. РАЗДЕЛ [8]: ПОЛНАЯ ДИАГНОСТИКА СИСТЕМЫ
# ==============================================================================
full_diagnostics() {
    print_banner
    step "ДИАГНОСТИКА" "Комплексная диагностика сервера LERS и MS SQL..."

    echo -e "${BOLD}1. Операционная система и ресурсы:${NC}"
    echo "  OS        : $(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"')"
    echo "  Архитектура: $(uname -m)"
    echo "  Память    : $(free -h | awk '/Mem:/ {print $3 "/" $2}')"
    echo "  Диск      : $(df -h / | awk 'NR==2 {print $3 "/" $2 " (Свободно: " $4 ")"}')"
    echo

    echo -e "${BOLD}2. Служба Docker и контейнеры:${NC}"
    if docker ps >/dev/null 2>&1; then
        echo -e "  Docker    : ${GREEN}АКТИВЕН${NC}"
        docker compose -f "$COMPOSE_FILE" ps 2>/dev/null || docker ps -f name=lers
    else
        echo -e "  Docker    : ${RED}НЕ ЗАПУЩЕН${NC}"
    fi
    echo

    echo -e "${BOLD}3. Сетевые порты:${NC}"
    local p10000="НЕДОСТУПЕН" p1433="НЕДОСТУПЕН"
    ss -tlpn 2>/dev/null | grep -q ":${DEFAULT_LERS_PORT}" && p10000="${GREEN}СЛУШАЕТ (:10000)${NC}"
    ss -tlpn 2>/dev/null | grep -q ":1433" && p1433="${GREEN}СЛУШАЕТ (:1433)${NC}"
    echo -e "  Веб ЛЭРС  : $p10000"
    echo -e "  MS SQL    : $p1433"
    echo

    echo -e "${BOLD}4. Подключение к локальной базе данных:${NC}"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'lers-db'; then
        local sql_chk
        sql_chk="$(sql_local_exec "SELECT 'SQL OK | ' + @@VERSION" "master" 2>/dev/null | head -n 1 || true)"
        if [[ -n "$sql_chk" ]]; then
            echo -e "  MS SQL    : ${GREEN}$sql_chk${NC}"
        else
            echo -e "  MS SQL    : ${RED}ОШИБКА АВТОРИЗАЦИИ SA${NC}"
        fi
    else
        echo -e "  MS SQL    : ${YELLOW}КОНТЕЙНЕР lers-db НЕ ЗАПУЩЕН${NC}"
    fi
    echo
}

# ==============================================================================
# 13. РАЗДЕЛ [9]: НАСТРОЙКИ И ПРОФИЛИ
# ==============================================================================
settings_and_profiles_menu() {
    while true; do
        print_banner
        echo -e "${BOLD}  ⚙️ ПРОФИЛИ ПОДКЛЮЧЕНИЙ И НАСТРОЙКИ${NC}"
        echo "  ────────────────────────────────────────────────────────────"
        echo "  [1] Показать сохранённые подключения"
        echo "  [2] Добавить подключение"
        echo "  [3] Удалить подключение"
        echo "  [4] Настройка Google Drive (rclone config)"
        echo "  [5] Установить постоянный LERS_BACKUP_URL"
        echo "  [6] Проверить системные зависимости"
        echo "  [7] Расширенная установка Microsoft SQL Tools (mssql-tools18 / APT)"
        echo "  [0] Назад в главное меню"
        echo "  ────────────────────────────────────────────────────────────"
        read -rp "Выберите пункт [0-7]: " set_c

        case "$set_c" in
            1)
                init_directories
                echo "Сохранённые подключения:"
                local p_idx=1
                while IFS='|' read -r p_t p_l p_h p_p p_d p_u; do
                    [[ -z "$p_t" || "$p_t" =~ ^# ]] && continue
                    echo "  [$p_idx] $p_l ($p_t)"
                    p_idx=$((p_idx + 1))
                done < "$PROFILES_FILE"
                [[ $p_idx -eq 1 ]] && echo "  (нет сохранённых подключений)"
                ;;
            2)
                read -rp "Название подключения: " p_l
                echo "Тип: 1) WINDOWS 2) LINUX 3) DOCKER"
                read -rp "Выбор [1-3]: " p_t_idx
                local p_t="WINDOWS"
                [[ "$p_t_idx" == "2" ]] && p_t="LINUX"
                [[ "$p_t_idx" == "3" ]] && p_t="DOCKER"
                read -rp "IP/Хост: " p_h
                read -rp "Порт [1433]: " p_p
                p_p="${p_p:-1433}"
                read -rp "База данных [LERS]: " p_d
                p_d="${p_d:-LERS}"
                read -rp "Пользователь [sa]: " p_u
                p_u="${p_u:-sa}"
                save_profile "$p_t" "$p_l" "$p_h" "$p_p" "$p_d" "$p_u"
                success "Подключение сохранено (пароль в конфигурации не хранится)!"
                ;;
            3)
                init_directories
                echo "Сохранённые подключения:"
                local p_idx=1
                local p_labels=()
                while IFS='|' read -r p_t p_l p_h p_p p_d p_u; do
                    [[ -z "$p_t" || "$p_t" =~ ^# ]] && continue
                    echo "  [$p_idx] $p_l ($p_t)"
                    p_labels+=("$p_l")
                    p_idx=$((p_idx + 1))
                done < "$PROFILES_FILE"
                read -rp "Номер или название для удаления: " del_val
                if [[ "$del_val" =~ ^[1-9][0-9]*$ ]] && (( del_val <= ${#p_labels[@]} )); then
                    local target_l="${p_labels[$((del_val-1))]}"
                    grep -v "^[^|]*|${target_l}|" "$PROFILES_FILE" > "${PROFILES_FILE}.tmp"
                    mv -f "${PROFILES_FILE}.tmp" "$PROFILES_FILE"
                    success "Подключение удалено."
                elif [[ -n "$del_val" ]]; then
                    grep -v "^[^|]*|${del_val}|" "$PROFILES_FILE" > "${PROFILES_FILE}.tmp"
                    mv -f "${PROFILES_FILE}.tmp" "$PROFILES_FILE"
                    success "Подключение удалено."
                fi
                ;;
            4) setup_rclone_wizard ;;
            5)
                read -rp "Введите URL по умолчанию для восстановления: " new_url
                LERS_BACKUP_URL="$new_url"
                generate_compose_files
                success "LERS_BACKUP_URL сохранён в конфигурации."
                ;;
            6) ensure_dependencies ;;
            7) install_native_sqlcmd ;;
            0) return 0 ;;
            *) error "Неверный выбор." ;;
        esac
        echo
        read -rp "Нажмите Enter для продолжения..." _dummy || true
    done
}

# ==============================================================================
# 14. ГЛАВНОЕ МЕНЮ И CLI ROUTER
# ==============================================================================
main_interactive_menu() {
    check_prerequisites
    init_directories

    while true; do
        print_banner
        echo -e "${BOLD}  УСТАНОВКА И РАЗВЁРТЫВАНИЕ${NC}"
        echo "  ────────────────────────────────────────────────────────────"
        echo "  [1] 🚀 Установка LERS (чистая установка Docker Compose / MS SQL)"
        echo "  [2] 🔄 Обновление и управление службами LERS"
        echo
        echo -e "${BOLD}  MS SQL SERVER (ИСТОЧНИКИ ДАННЫХ)${NC}"
        echo "  ────────────────────────────────────────────────────────────"
        echo "  [3] 🪟 MS SQL на Windows (тест, бэкап, SMB / SFTP)"
        echo "  [4] 🐧 MS SQL на Linux (тест, бэкап, SSH / SCP)"
        echo "  [5] 🐳 MS SQL в Docker (контейнеры, тома, бэкапы)"
        echo
        echo -e "${BOLD}  РАБОТА С БАЗОЙ LERS И ОБЛАКОМ${NC}"
        echo "  ────────────────────────────────────────────────────────────"
        echo "  [6] 💾 Резервное копирование и Восстановление (URL / Файл / GDrive)"
        echo "  [7] 🔍 Проверка и состояние базы LERS (таблицы, права, DBCC)"
        echo "  [8] 🩺 Полная диагностика системы"
        echo "  [9] ⚙️ Настройки и профили подключений"
        echo
        echo "  [0] Выход"
        echo "  ────────────────────────────────────────────────────────────"
        read -rp "Выберите пункт меню [0-9]: " main_choice

        case "$main_choice" in
            1) install_clean_lers ;;
            2)
                echo "  a) Обновить образы LERS (с обязательным автобэкапом)"
                echo "  b) Просмотр логов (docker compose logs)"
                echo "  c) Перезапустить LERS"
                echo "  d) Остановить LERS"
                echo "  e) Выполнить первичную инициализацию (/install.sh в контейнере lers)"
                read -rp "Действие [a-e]: " act
                case "$act" in
                    a) update_lers_system ;;
                    b) docker compose -f "$COMPOSE_FILE" logs -f --tail 100 ;;
                    c) docker compose -f "$COMPOSE_FILE" restart ;;
                    d) docker compose -f "$COMPOSE_FILE" stop ;;
                    e)
                        info "Запуск /install.sh внутри lers-server..."
                        docker compose -f "$COMPOSE_FILE" exec -it lers /install.sh || true
                        ;;
                esac
                ;;
            3) windows_mssql_menu ;;
            4) linux_mssql_menu ;;
            5) docker_mssql_menu ;;
            6) backup_restore_menu ;;
            7) check_database_menu ;;
            8) full_diagnostics ;;
            9) settings_and_profiles_menu ;;
            0) echo "Выход."; exit 0 ;;
            *) error "Неверный выбор." ;;
        esac
        echo
        read -rp "Нажмите Enter для продолжения..." _dummy || true
    done
}

if [[ $# -gt 0 ]]; then
    check_prerequisites
    init_directories
    case "$1" in
        install)
            install_clean_lers
            ;;
        backup)
            backup_local_database "${2:-}"
            ;;
        backup-enc)
            backup_and_encrypt_local_database
            ;;
        restore)
            if [[ -n "${2:-}" ]]; then
                input_src="$2"
                target_f="$input_src"
                if [[ "$input_src" =~ ^https?:// ]]; then
                    target_f="${INCOMING_DIR}/LERS_cli_$(date +%s).tmp"
                    download_public_url "$input_src" "$target_f"
                fi
                extracted_bak=""
                if prepare_sql_bak_from_source "$target_f" extracted_bak; then
                    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'lers-db'; then
                        generate_compose_files
                        docker compose -f "$COMPOSE_FILE" up -d db
                        wait_for_local_mssql
                    fi
                    verify_sql_backup "$extracted_bak"
                    backup_local_database "LERS_safety_before_restore_$(date +%Y_%m_%d_%H%M%S).bak" || true
                    docker compose -f "$COMPOSE_FILE" stop lers >/dev/null 2>&1 || true

                    r_bak_name="restore_cli_$(date +%s).bak"
                    r_host_p="${SQL_BACKUP_DIR}/${r_bak_name}"
                    cp -f "$extracted_bak" "$r_host_p"
                    chmod 600 "$r_host_p"
                    chgrp 0 "$r_host_p" 2>/dev/null || true

                    moves="$(get_restore_file_moves "/var/opt/mssql/backup/${r_bak_name}" "${DEFAULT_DB_NAME}")"
                    sql_local_exec "
                        USE master;
                        IF DB_ID('${DEFAULT_DB_NAME}') IS NOT NULL ALTER DATABASE [${DEFAULT_DB_NAME}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
                        RESTORE DATABASE [${DEFAULT_DB_NAME}] FROM DISK = N'/var/opt/mssql/backup/${r_bak_name}' WITH REPLACE, ${moves};
                        ALTER DATABASE [${DEFAULT_DB_NAME}] SET MULTI_USER;
                    " "master"
                    rm -f "$r_host_p"
                    cleanup_orphaned_ndf_files "${DEFAULT_DB_NAME}"
                    docker compose -f "$COMPOSE_FILE" up -d lers
                    verify_lers_health
                    success "База успешно восстановлена из CLI!"
                fi
            else
                restore_database_flow
            fi
            ;;
        verify)
            [[ -n "${2:-}" ]] && verify_sql_backup "$2" || error "Укажите файл."
            ;;
        windows-sql)
            windows_mssql_menu
            ;;
        linux-sql)
            linux_mssql_menu
            ;;
        docker-sql)
            docker_mssql_menu
            ;;
        upload-cloud)
            upload_gdrive_backup
            ;;
        download-cloud)
            download_gdrive_backup
            ;;
        update)
            update_lers_system
            ;;
        diag|status)
            full_diagnostics
            ;;
        logs)
            docker compose -f "$COMPOSE_FILE" logs -f --tail 100
            ;;
        *)
            echo "Использование: $0 [install|backup|backup-enc|restore [URL|file]|verify <file>|windows-sql|linux-sql|docker-sql|upload-cloud|download-cloud|update|diag|status|logs]"
            exit 1
            ;;
    esac
else
    main_interactive_menu
fi
