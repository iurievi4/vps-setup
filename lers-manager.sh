#!/usr/bin/env bash
# ==============================================================================
#  ЛЭРС УЧЁТ (LERS AMR) — МЕНЕДЖЕР РАЗВЁРТЫВАНИЯ, ОБСЛУЖИВАНИЯ И БЭКАПОВ
#  Версия: 2.4 (Production-Ready)
#
#  Архитектурные слои:
#  1. RUNTIME LAYER:    Docker Compose (lersamr/full-r + MS SQL Server)
#                       Раздельные тома: sqldata, data, config, backup/sql
#  2. DATABASE LAYER:   Динамический multi-file RESTORE (с защитой от SQL-инъекций),
#                       COPY_ONLY бэкап, очистка устаревших NDF, контроль лимита 10 ГБ Express
#  3. CRYPTO LAYER:     AES-256-CBC + PBKDF2 (100% совместимо со стандартом setup.sh)
#  4. INGRESS / CLOUD:  Универсальный импорт по публичным URL (Google Drive / HTTP / HTTPS)
#                       с автоматическим детектированием формата (.bak, .enc, .zip, .tar.gz)
#                       + rclone для выгрузки бэкапов в облако
#  5. REMOTE SQL LAYER: Автономный контур Windows/Linux MS SQL:
#                       SQL BACKUP -> Транспорт (SMB Share / SFTP / Local Mount)
#                       -> Скачивание без шифрования ИЛИ
#                       -> Проверка (VERIFYONLY) -> Шифрование -> Google Drive
#
#  Поддерживаемые ОС: Ubuntu 20.04/22.04/24.04+, Debian 11/12+ (amd64 / x86_64)
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
LERS_DATA_DIR="${LERS_BASE_DIR}/data"       # маппинг в /var/LERS контейнера
LERS_CONF_DIR="${LERS_BASE_DIR}/config"     # маппинг в /etc/LERS контейнера
BACKUP_DIR="${LERS_BASE_DIR}/backup"
SQL_BACKUP_DIR="${BACKUP_DIR}/sql"          # маппинг в /var/opt/mssql/backup контейнера
INCOMING_DIR="${BACKUP_DIR}/incoming"
LOCAL_BACKUP_DIR="${BACKUP_DIR}/local"
ENCRYPTED_BACKUP_DIR="${BACKUP_DIR}/encrypted"

MSSQL_SA_PASSWORD_FILE="/root/.mssql-sa-password"
RCLONE_CONFIG_FILE="/root/.config/rclone/rclone.conf"

# Канонические имена и пути Google Drive / Публичной ссылки
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

# Кэш параметров удалённого сервера в рамках сессии
CACHED_R_HOST=""
CACHED_R_PORT="1433"
CACHED_R_DB="LERS"
CACHED_R_USER="sa"
CACHED_R_PASS=""

# ------------------------------------------------------------------------------
# Вспомогательные функции вывода и логирования
# ------------------------------------------------------------------------------
info()    { echo -e "${BLUE}[ИНФО]${NC} $1"; }
success() { echo -e "${GREEN}[УСПЕХ]${NC} $1"; }
warn()    { echo -e "${YELLOW}[ВНИМАНИЕ]${NC} $1"; }
error()   { echo -e "${RED}[ОШИБКА]${NC} $1"; }
step()    { echo -e "\n${BOLD}${CYAN}>>> [$1]${NC} ${BOLD}$2${NC}"; }

print_banner() {
    clear 2>/dev/null || true
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}   ${BOLD}${CYAN}ЛЭРС УЧЁТ (LERS AMR) — PRODUCTION MANAGER v2.4${NC}                    ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${YELLOW}Слои: Runtime + MS SQL + Crypto + Universal URL/Cloud Ingress${NC}       ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════╝${NC}"
}

# Экранирование строк для T-SQL (удвоение одинарных кавычек)
sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

# ------------------------------------------------------------------------------
# Безопасный ввод паролей с маскировкой звёздочками (из setup.sh)
# ------------------------------------------------------------------------------
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
# 1. СЛОЙ СИСТЕМЫ: Проверки, каталоги, зависимости
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

ensure_dependencies() {
    local missing=()
    for tool in curl openssl tar jq gzip unzip sshpass smbclient file; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        info "Установка системных утилит: ${missing[*]}..."
        apt-get update -qq && apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1 || true
    fi

    if ! command -v docker >/dev/null 2>&1; then
        info "Установка docker.io..."
        apt-get update -qq && apt-get install -y -qq docker.io >/dev/null 2>&1
        systemctl enable --now docker >/dev/null 2>&1 || true
    fi

    if ! docker compose version >/dev/null 2>&1; then
        info "Установка docker-compose-plugin..."
        apt-get update -qq && apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1 || true
        if ! docker compose version >/dev/null 2>&1; then
            apt-get install -y -qq docker-compose >/dev/null 2>&1 || true
        fi
    fi

    if ! docker ps >/dev/null 2>&1; then
        error "Служба Docker не запущена или недоступна."
        exit 1
    fi
}

ensure_rclone() {
    if ! command -v rclone >/dev/null 2>&1; then
        info "Установка rclone для интеграции с облаком..."
        apt-get update -qq && apt-get install -y -qq rclone >/dev/null 2>&1 || {
            curl -4 -fL https://rclone.org/install.sh 2>/dev/null | bash >/dev/null 2>&1 || true
        }
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

# ------------------------------------------------------------------------------
# 2. СЛОЙ RUNTIME: Docker Compose, конфигурация, запуск и обновление
# ------------------------------------------------------------------------------
generate_compose_files() {
    get_or_create_sa_password
    init_directories

    local lers_port="${LERS_PORT:-$DEFAULT_LERS_PORT}"
    local mssql_image="${MSSQL_IMAGE:-$DEFAULT_MSSQL_IMAGE}"
    local lers_image="${LERS_IMAGE:-$DEFAULT_LERS_IMAGE}"
    local mssql_pid="${MSSQL_PID:-$DEFAULT_MSSQL_PID}"
    local expose_sql="${EXPOSE_MSSQL_EXTERNALLY:-0}"
    local backup_url="${LERS_BACKUP_URL:-}"

    local sql_port_binding="127.0.0.1:1433:1433"
    if [[ "$expose_sql" == "1" ]]; then
        sql_port_binding="1433:1433"
    fi

    cat > "$ENV_FILE" <<EOF
MSSQL_SA_PASSWORD=${MSSQL_SA_PASSWORD}
LERS_PORT=${lers_port}
LERS_IMAGE=${lers_image}
MSSQL_IMAGE=${mssql_image}
MSSQL_PID=${mssql_pid}
LERS_BACKUP_URL=${backup_url}
EOF
    chmod 600 "$ENV_FILE"

    cat > "$COMPOSE_FILE" <<EOF
services:
  db:
    image: ${mssql_image}
    container_name: lers-db
    restart: always
    environment:
      ACCEPT_EULA: "Y"
      MSSQL_SA_PASSWORD: "\${MSSQL_SA_PASSWORD}"
      MSSQL_PID: "${mssql_pid}"
    volumes:
      - "${SQLDATA_DIR}:/var/opt/mssql/data"
      - "${SQL_BACKUP_DIR}:/var/opt/mssql/backup"
    ports:
      - "${sql_port_binding}"
    healthcheck:
      test: ["CMD-SHELL", "/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P '\$\$MSSQL_SA_PASSWORD' -C -Q 'SELECT 1' || /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P '\$\$MSSQL_SA_PASSWORD' -Q 'SELECT 1'"]
      interval: 10s
      timeout: 5s
      retries: 25
      start_period: 15s

  lers:
    image: ${lers_image}
    container_name: lers-server
    restart: always
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "${lers_port}:10000"
    volumes:
      - "${LERS_DATA_DIR}:/var/LERS"
      - "${LERS_CONF_DIR}:/etc/LERS"
    environment:
      LERS_SERVER_DATABASE__ConnectionString: "Data Source=db,1433; Initial Catalog=${DEFAULT_DB_NAME}; User ID=sa; Password=\${MSSQL_SA_PASSWORD}; Integrated Security=false; Encrypt=true; TrustServerCertificate=true"
EOF
    chmod 644 "$COMPOSE_FILE"
}

verify_lers_health() {
    local lers_port="${LERS_PORT:-$DEFAULT_LERS_PORT}"
    local max_wait=40
    local waited=0
    info "Комплексная проверка состояния ЛЭРС УЧЁТ (HTTP + Logs + DB)..."

    while (( waited < max_wait )); do
        sleep 3
        waited=$((waited + 3))

        if ! docker ps --format '{{.Names}}' | grep -qx 'lers-server'; then
            warn "Контейнер lers-server остановлен или упал. Ожидание..."
            continue
        fi

        local http_code=""
        http_code="$(curl -4 -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://127.0.0.1:${lers_port}/" 2>/dev/null || true)"
        if [[ "$http_code" =~ ^(200|301|302|401|403)$ ]]; then
            success "Веб-интерфейс ЛЭРС УЧЁТ доступен (HTTP $http_code на порту $lers_port)!"
            return 0
        fi

        local log_err
        log_err="$(docker compose -f "$COMPOSE_FILE" logs --tail 30 lers 2>&1 | grep -iE "SqlException|Login failed|Cannot open database|Connection refused" || true)"
        if [[ -n "$log_err" ]]; then
            error "Обнаружена ошибка соединения с БД в логах ЛЭРС:"
            echo "$log_err" | sed 's/^/  /'
            return 1
        fi
    done

    warn "Сервер ЛЭРС запустился, но HTTP-интерфейс ещё не ответил за ${max_wait} сек. Проверьте журналы работы."
    return 0
}

install_clean_lers() {
    step "УСТАНОВКА" "Развёртывание ЛЭРС УЧЁТ + MS SQL Server..."
    ensure_dependencies
    init_directories

    echo "1. Параметры порта веб-интерфейса:"
    read -rp "Порт сервера ЛЭРС [${DEFAULT_LERS_PORT}]: " user_port
    LERS_PORT="${user_port:-$DEFAULT_LERS_PORT}"

    echo
    echo "2. Выбор редакции MS SQL Server:"
    echo "  1) Express   — Бесплатная для коммерческой эксплуатации (лимит размера БД строго до 10 ГБ)"
    echo "  2) Developer — Полный функционал Enterprise (строго для разработки, тестирования и лабораторий)"
    echo "  3) Standard / Enterprise — Коммерческая редакция (при наличии лицензии)"
    read -rp "Выбор редакции [1-3, по умолчанию 1]: " pid_choice
    case "${pid_choice:-1}" in
        1) MSSQL_PID="Express" ;;
        2) MSSQL_PID="Developer" ;;
        3) MSSQL_PID="Standard" ;;
        *) MSSQL_PID="Express" ;;
    esac

    echo
    echo "3. Выбор Docker-образа ЛЭРС:"
    echo "  1) lersamr/full-r:latest — Русская сборка (Сервер + Служба опроса + Веб) [Основной выбор]"
    echo "  2) lersamr/full:latest   — Международная версия"
    echo "  3) lersamr/pollservice   — Только служба опроса для удалённого узла"
    read -rp "Выбор [1-3, по умолчанию 1]: " img_choice
    case "${img_choice:-1}" in
        1) LERS_IMAGE="lersamr/full-r:latest" ;;
        2) LERS_IMAGE="lersamr/full:latest" ;;
        3) LERS_IMAGE="lersamr/pollservice:latest" ;;
        *) LERS_IMAGE="lersamr/full-r:latest" ;;
    esac

    echo
    echo "4. Сетевой доступ к MS SQL Server (порт 1433):"
    echo "  0) Только локально на VPS (127.0.0.1) [Рекомендуется]"
    echo "  1) Открыть порт 1433 наружу"
    read -rp "Выбор [0/1, по умолчанию 0]: " exp_sql
    EXPOSE_MSSQL_EXTERNALLY="${exp_sql:-0}"

    echo
    echo "5. Публичная ссылка на актуальный бэкап (опционально):"
    echo "  (Google Drive ссылка или прямой HTTP/HTTPS URL)"
    read -rp "URL [пропустить]: " in_b_url
    LERS_BACKUP_URL="${in_b_url:-}"

    generate_compose_files

    info "Загрузка Docker-образов..."
    docker compose -f "$COMPOSE_FILE" pull

    info "Запуск контейнеров..."
    docker compose -f "$COMPOSE_FILE" up -d

    wait_for_mssql

    info "Анализ запуска LERS Server..."
    sleep 15

    local lers_logs
    lers_logs="$(docker compose -f "$COMPOSE_FILE" logs --tail 50 lers 2>&1 || true)"
    if echo "$lers_logs" | grep -qiE "install.sh|waiting for configuration|initial setup"; then
        info "Контейнер ожидает инициализации. Запуск встроенного /install.sh..."
        if ! docker compose -f "$COMPOSE_FILE" exec -T lers /install.sh; then
            error "Ошибка при выполнении /install.sh внутри контейнера lers!"
            return 1
        fi
    fi

    verify_lers_health

    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        info "Настройка правил UFW для порта ${LERS_PORT}..."
        ufw allow "${LERS_PORT}/tcp" comment "LERS Web" >/dev/null 2>&1 || true
        if [[ "$EXPOSE_MSSQL_EXTERNALLY" == "1" ]]; then
            ufw allow 1433/tcp comment "LERS MS SQL" >/dev/null 2>&1 || true
        fi
        ufw reload >/dev/null 2>&1 || true
    fi

    local server_ip
    server_ip="$(hostname -I | awk '{print $1}')"

    echo
    echo -e "${GREEN}======================================================================${NC}"
    echo -e "${GREEN}  ✓ УСТАНОВКА ЛЭРС УЧЁТ ЗАВЕРШЕНА!${NC}"
    echo -e "  Веб-интерфейс : ${BOLD}http://${server_ip}:${LERS_PORT}${NC}"
    echo -e "  Редакция SQL  : ${MSSQL_PID}"
    echo -e "  Пароль SA SQL : Сохранён в ${MSSQL_SA_PASSWORD_FILE}"
    [[ -n "$LERS_BACKUP_URL" ]] && echo -e "  Резервный URL : ${LERS_BACKUP_URL}"
    echo -e "${GREEN}======================================================================${NC}"
    echo
}

update_lers_system() {
    step "ОБНОВЛЕНИЕ" "Обновление системы ЛЭРС УЧЁТ..."

    if [[ ! -f "$COMPOSE_FILE" ]]; then
        error "Файл $COMPOSE_FILE не найден. Сначала выполните установку."
        return 1
    fi

    local pre_update_bak="LERS_before_update_$(date +%Y_%m_%d_%H%M%S).bak"
    info "Создание обязательной резервной копии базы перед обновлением..."
    if ! backup_local_database "$pre_update_bak"; then
        error "Не удалось создать резервную копию! Обновление прервано ради защиты данных."
        return 1
    fi

    info "Загрузка обновлений образов (docker compose pull)..."
    docker compose -f "$COMPOSE_FILE" pull

    info "Перезапуск контейнеров с новыми образами..."
    docker compose -f "$COMPOSE_FILE" up -d

    info "Верификация запуска контейнеров и доступности веб-интерфейса..."
    if ! verify_lers_health; then
        error "ВНИМАНИЕ: Проверка здоровья ЛЭРС после обновления не пройдена!"
        warn "Резервная копия базы сохранена в: ${LOCAL_BACKUP_DIR}/${pre_update_bak}"
        info "Вывод логов контейнера:"
        docker compose -f "$COMPOSE_FILE" logs --tail 40 lers || true
        return 1
    fi

    success "Обновление успешно завершено! Все сервисы функционируют штатно."
}

# ------------------------------------------------------------------------------
# 3. СЛОЙ БАЗЫ ДАННЫХ: SQL Server, динамический restore, verify, cleanup NDF
# ------------------------------------------------------------------------------
sql_exec() {
    local query="$1"
    local db_context="${2:-master}"
    local extra_flags="${3:-}"

    if ! docker ps --format '{{.Names}}' | grep -qx 'lers-db'; then
        error "Контейнер lers-db не запущен!"
        return 1
    fi

    get_or_create_sa_password

    docker exec -i lers-db bash -c "
        if [ -x /opt/mssql-tools18/bin/sqlcmd ]; then
            CMD=/opt/mssql-tools18/bin/sqlcmd
            FLAGS=\"-C\"
        elif [ -x /opt/mssql-tools/bin/sqlcmd ]; then
            CMD=/opt/mssql-tools/bin/sqlcmd
            FLAGS=\"\"
        else
            echo 'sqlcmd не найден в контейнере' >&2
            exit 1
        fi
        \"\$CMD\" -S localhost -U sa -P \"\$MSSQL_SA_PASSWORD\" \$FLAGS -d \"$db_context\" -Q \"$query\" $extra_flags -b
    "
}

wait_for_mssql() {
    local max_retries=35
    local count=0
    info "Ожидание готовности MS SQL Server..."
    until sql_exec "SELECT 1" "master" >/dev/null 2>&1; do
        sleep 2
        count=$((count + 1))
        if (( count >= max_retries )); then
            error "Таймаут ожидания старта MS SQL Server (70 сек)."
            return 1
        fi
    done
    success "MS SQL Server готов к обработке запросов."
}

get_restore_file_moves() {
    local container_backup_path="$1"
    local target_db_name="${2:-LERS}"

    local raw_filelist
    raw_filelist="$(sql_exec "RESTORE FILELISTONLY FROM DISK = N'$(sql_escape "$container_backup_path")';" "master" "-s | -W -h -1" 2>/dev/null || true)"

    if [[ -z "$raw_filelist" ]]; then
        error "Не удалось прочитать список файлов из резервной копии!"
        return 1
    fi

    local data_idx=0
    local log_idx=0
    local move_clauses=()

    while IFS='|' read -r col_logical col_phys col_type col_rest; do
        col_logical="$(echo "${col_logical:-}" | tr -d '\r\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        col_type="$(echo "${col_type:-}" | tr -d '\r\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | tr '[:lower:]' '[:upper:]')"

        [[ -z "$col_logical" || -z "$col_type" ]] && continue
        [[ "$col_logical" =~ ^-+ ]] && continue

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
    info "Анализ физических файлов базы '${target_db_name}' на предмет осиротевших .ndf..."

    local active_files
    active_files="$(sql_exec "SELECT physical_name FROM sys.master_files WHERE database_id = DB_ID('$(sql_escape "$target_db_name")')" "master" "-h -1 -W" 2>/dev/null || true)"

    if [[ -z "$active_files" ]]; then
        return 0
    fi

    for f in "${SQLDATA_DIR}/${target_db_name}_"*.ndf; do
        [[ ! -f "$f" ]] && continue
        local fname
        fname="$(basename "$f")"
        if ! echo "$active_files" | grep -q "$fname"; then
            warn "Удаление устаревшего файла, не связанного с восстановленной БД: $f"
            rm -f "$f"
        fi
    done
}

backup_local_database() {
    local out_bak_name="${1:-LERS_backup_$(date +%Y_%m_%d_%H%M%S).bak}"
    local target_bak="${LOCAL_BACKUP_DIR}/${out_bak_name}"

    step "БЭКАП" "Создание локального бэкапа базы LERS..."
    init_directories

    if ! docker ps --format '{{.Names}}' | grep -qx 'lers-db'; then
        error "Контейнер lers-db не запущен!"
        return 1
    fi

    local check_db
    check_db="$(sql_exec "IF DB_ID('${DEFAULT_DB_NAME}') IS NOT NULL PRINT 'EXISTS'" "master" 2>/dev/null | tr -d '\r\n ')"
    if [[ "$check_db" != *"EXISTS"* ]]; then
        error "База данных '${DEFAULT_DB_NAME}' не найдена в MS SQL Server."
        return 1
    fi

    info "Выполнение BACKUP DATABASE [${DEFAULT_DB_NAME}] WITH COPY_ONLY, COMPRESSION..."
    local in_container_path="/var/opt/mssql/backup/${out_bak_name}"

    local sql_query="
        BACKUP DATABASE [${DEFAULT_DB_NAME}]
        TO DISK = N'$(sql_escape "${in_container_path}")'
        WITH COPY_ONLY, COMPRESSION, STATS = 20, FORMAT, INIT;
    "

    if ! sql_exec "$sql_query" "master"; then
        error "Сбой при выполнении BACKUP DATABASE."
        return 1
    fi

    local src_file="${SQL_BACKUP_DIR}/${out_bak_name}"
    if [[ -s "$src_file" ]]; then
        mv -f "$src_file" "$target_bak"
    fi

    if [[ ! -s "$target_bak" ]]; then
        error "Файл резервной копии не найден в $target_bak"
        return 1
    fi

    chmod 600 "$target_bak"
    local size_h
    size_h="$(du -h "$target_bak" | awk '{print $1}')"
    success "Резервная копия создана: $target_bak ($size_h)"
    return 0
}

verify_sql_backup() {
    local bak_path="$1"
    step "ПРОВЕРКА БЭКАПА" "Валидация резервной копии средствами MS SQL Server..."

    if ! docker ps --format '{{.Names}}' | grep -qx 'lers-db'; then
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
    if ! verify_res="$(sql_exec "RESTORE VERIFYONLY FROM DISK = N'$(sql_escape "${container_path}")';" "master" 2>&1)"; then
        error "Файл повреждён или не является валидным бэкапом SQL Server!"
        echo "$verify_res"
        rm -f "$host_sql_bak"
        return 1
    fi
    success "RESTORE VERIFYONLY: Резервная копия целостна и валидна."

    info "Проверка совместимости версий и размера БД..."
    local header_info
    header_info="$(sql_exec "
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
    target_major="$(sql_exec "SELECT SERVERPROPERTY('ProductMajorVersion')" "master" "-h -1 -W" 2>/dev/null | tr -d ' \r\n')"
    target_pid="$(sql_exec "SELECT SERVERPROPERTY('Edition')" "master" "-h -1 -W" 2>/dev/null | tr -d '\r\n')"

    echo "  Исходная база    : ${bak_dbname:-unknown}"
    echo "  Дата создания    : ${bak_date:-unknown}"
    echo "  Размер несжатый  : $(( bak_bytes / 1024 / 1024 )) MB"
    echo "  Версия в бэкапе  : SQL Major ${bak_major:-unknown}"
    echo "  Целевой сервер   : SQL Major ${target_major:-unknown} (${target_pid:-unknown})"

    if [[ -n "$bak_major" && -n "$target_major" ]]; then
        if (( bak_major > target_major )); then
            error "База создана в более новой версии SQL Server (${bak_major}), чем целевой сервер (${target_major})!"
            error "Восстановление невозможно (ограничение Microsoft SQL Server)."
            rm -f "$host_sql_bak"
            return 1
        fi
    fi

    if [[ "${target_pid:-}" =~ "Express" ]] && (( bak_bytes > 10737418240 )); then
        error "Размер базы данных в бэкапе ($(( bak_bytes / 1024 / 1024 )) MB) превышает 10 ГБ!"
        error "SQL Server Express не сможет восстановить эту базу (лимит 10 ГБ)."
        error "Требуется переключить MSSQL_PID в Standard или Developer в файле .env."
        rm -f "$host_sql_bak"
        return 1
    fi

    rm -f "$host_sql_bak"
    success "Совместимость резервной копии полностью подтверждена."
    return 0
}

# ------------------------------------------------------------------------------
# 4. СЛОЙ ШИФРОВАНИЯ: AES-256-CBC + PBKDF2 (стандарт setup.sh)
# ------------------------------------------------------------------------------
encrypt_archive() {
    local input_bak="$1"
    local output_enc="$2"
    local master_pass="$3"

    if [[ ! -s "$input_bak" ]]; then
        error "Исходный файл бэкапа не найден или пуст: $input_bak"
        return 1
    fi

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

    if ! tar -tzf "$archive_tar" >/dev/null 2>&1; then
        error "Ошибка создания архива tar.gz."
        return 1
    fi

    info "Шифрование через OpenSSL (AES-256-CBC + PBKDF2)..."
    if ! openssl enc -aes-256-cbc -pbkdf2 \
        -in "$archive_tar" \
        -out "$tmp_enc" \
        -pass file:"$pass_file"; then
        error "Сбой OpenSSL при выполнении шифрования."
        return 1
    fi

    info "Сквозная проверка корректности расшифровки..."
    local test_tar="${work_dir}/test_verify.tar.gz"
    if ! openssl enc -d -aes-256-cbc -pbkdf2 \
        -in "$tmp_enc" \
        -out "$test_tar" \
        -pass file:"$pass_file" 2>/dev/null; then
        error "Тестовая расшифровка не удалась!"
        return 1
    fi

    if ! tar -tzf "$test_tar" >/dev/null 2>&1; then
        error "Тестовый архив повреждён при расшифровке."
        return 1
    fi

    mkdir -p "$(dirname "$output_enc")"
    mv -f "$tmp_enc" "$output_enc"
    chmod 600 "$output_enc"

    local size_h
    size_h="$(du -h "$output_enc" | awk '{print $1}')"
    success "Файл успешно зашифрован и верифицирован!"
    echo "  Итоговый файл: $output_enc ($size_h)"
    return 0
}

decrypt_archive() {
    local input_enc="$1"
    local output_dir="$2"
    local master_pass="$3"
    local __result_bak_var="$4"

    if [[ ! -s "$input_enc" ]]; then
        error "Зашифрованный файл не найден или пуст: $input_enc"
        return 1
    fi

    local work_dir
    work_dir="$(mktemp -d /tmp/lers-dec.XXXXXX)"
    chmod 700 "$work_dir"
    trap 'rm -rf "$work_dir"' RETURN

    local pass_file="${work_dir}/pass.tmp"
    printf '%s' "$master_pass" > "$pass_file"
    chmod 600 "$pass_file"

    local decrypted_tar="${work_dir}/decrypted.tar.gz"

    info "Расшифровка OpenSSL (AES-256-CBC + PBKDF2)..."
    if ! openssl enc -d -aes-256-cbc -pbkdf2 \
        -in "$input_enc" \
        -out "$decrypted_tar" \
        -pass file:"$pass_file" 2>/dev/null; then
        error "Неверный пароль или повреждённый зашифрованный файл."
        return 1
    fi

    mkdir -p "$output_dir"
    chmod 700 "$output_dir"
    local extracted_bak=""

    if tar -tzf "$decrypted_tar" >/dev/null 2>&1; then
        info "Архив tar.gz валиден. Распаковка..."
        tar -xzf "$decrypted_tar" -C "$output_dir"

        local candidates=()
        mapfile -t candidates < <(find "$output_dir" -maxdepth 2 -type f \( -iname "*.bak" -o -iname "*.db" \) -size +0c)
        if [[ ${#candidates[@]} -gt 0 ]]; then
            extracted_bak="${candidates[0]}"
        fi
    else
        # Прямой бэкап без tar
        if head -c 1024 "$decrypted_tar" 2>/dev/null | grep -qa "TAPE"; then
            local fallback_name
            fallback_name="$(basename "$input_enc" .enc)"
            [[ "$fallback_name" != *.bak ]] && fallback_name="${fallback_name}.bak"
            extracted_bak="${output_dir}/${fallback_name}"
            mv -f "$decrypted_tar" "$extracted_bak"
        fi
    fi

    if [[ -z "$extracted_bak" || ! -s "$extracted_bak" ]]; then
        error "В расшифрованном архиве не найдено файла базы данных (*.bak)."
        return 1
    fi

    chmod 600 "$extracted_bak"
    success "База успешно расшифрована: $extracted_bak"
    printf -v "$__result_bak_var" '%s' "$extracted_bak"
    return 0
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

    if [[ -z "$pass1" ]]; then
        error "Пароль не может быть пустым."
        rm -f "$raw_bak_path"
        return 1
    fi

    if [[ "$pass1" != "$pass2" ]]; then
        error "Пароли не совпадают!"
        rm -f "$raw_bak_path"
        return 1
    fi

    if ! encrypt_archive "$raw_bak_path" "$enc_path" "$pass1"; then
        rm -f "$raw_bak_path"
        return 1
    fi

    # Фиксированное имя LERS_BACKUP.enc
    cp -f "$enc_path" "$canonical_path"
    chmod 600 "$canonical_path"
    rm -f "$raw_bak_path"

    echo
    echo -e "${GREEN}======================================================================${NC}"
    echo -e "${GREEN}  ✓ ЗАШИФРОВАННЫЙ БЭКАП УСПЕШНО СОЗДАН И ПРОВЕРЕН!${NC}"
    echo -e "  Архивный файл      : ${BOLD}${enc_path}${NC}"
    echo -e "  Канонический файл  : ${BOLD}${canonical_path}${NC}"
    echo -e "  Размер             : $(du -h "$enc_path" | awk '{print $1}')"
    echo -e "  Алгоритм           : AES-256-CBC (PBKDF2) — стандарт setup.sh"
    echo -e "${GREEN}======================================================================${NC}"
    echo
    return 0
}

# ------------------------------------------------------------------------------
# 5. СЛОЙ УНИВЕРСАЛЬНОГО ИМПОРТА: URL, Google Drive и адаптивная распаковка
# ------------------------------------------------------------------------------

# Скачивание файла по ссылке (Google Drive публичная ссылка, HTTP, HTTPS)
download_public_url() {
    local raw_url="$1"
    local dest_file="$2"

    ensure_dependencies
    mkdir -p "$(dirname "$dest_file")"
    chmod 700 "$(dirname "$dest_file")"

    local file_id=""
    # Проверка формата Google Drive ссылки
    if [[ "$raw_url" =~ /d/([a-zA-Z0-9_-]+) ]]; then
        file_id="${BASH_REMATCH[1]}"
    elif [[ "$raw_url" =~ id=([a-zA-Z0-9_-]+) ]]; then
        file_id="${BASH_REMATCH[1]}"
    fi

    if [[ -n "$file_id" ]]; then
        info "Обнаружена публичная ссылка Google Drive. Извлечён File ID: ${file_id}"
        local cookie_jar
        cookie_jar="$(mktemp /tmp/gdrive_cookie.XXXXXX)"
        chmod 600 "$cookie_jar"
        trap 'rm -f "$cookie_jar"' RETURN

        # 1. Первый запрос для получения cookie и confirm-токена (для файлов > 100MB)
        local confirm_code
        confirm_code="$(curl -4 -sSL -c "$cookie_jar" "https://drive.google.com/uc?export=download&id=${file_id}" 2>/dev/null | grep -o 'confirm=[^&"]*' | head -n1 || true)"

        info "Загрузка файла с серверов Google Drive..."
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

    if [[ ! -s "$dest_file" ]]; then
        error "Скачанный файл пуст или отсутствует: $dest_file"
        return 1
    fi

    # Проверка: не является ли файл HTML-страницей ошибки/логина Google
    if head -c 512 "$dest_file" 2>/dev/null | grep -qiE "<!doctype|<html|<head|accounts.google.com"; then
        error "Скачанный файл является веб-страницей (HTML), а не файлом базы данных!"
        warn "Причина: файл на Google Drive не открыт для публичного доступа ('Доступ ограничен'), либо превышена квота скачивания."
        warn "Убедитесь, что в свойствах файла Google Drive выбрано: 'Все, у кого есть ссылка'."
        rm -f "$dest_file"
        return 1
    fi

    chmod 600 "$dest_file"
    success "Файл успешно загружен: $dest_file ($(du -h "$dest_file" | awk '{print $1}'))"
    return 0
}

# Адаптивное распознавание формата и извлечение .bak
prepare_sql_bak_from_source() {
    local input_file="$1"
    local __result_bak_var="$2"

    if [[ ! -s "$input_file" ]]; then
        error "Файл не существует или пуст: $input_file"
        return 1
    fi

    info "Анализ структуры и сигнатур файла $(basename "$input_file")..."

    local file_type="UNKNOWN"
    local head_bytes
    head_bytes="$(head -c 1024 "$input_file" 2>/dev/null || true)"

    if echo "$head_bytes" | grep -qa "TAPE"; then
        file_type="MSSQL_BAK"
    elif [[ "$head_bytes" =~ ^Salted__ ]]; then
        file_type="OPENSSL_ENC"
    elif [[ "$(head -c 2 "$input_file" 2>/dev/null)" == $'\x1f\x8b' ]]; then
        file_type="GZIP_TAR"
    elif [[ "$(head -c 4 "$input_file" 2>/dev/null)" == "PK"$'\x03\x04' ]]; then
        file_type="ZIP"
    fi

    echo "Определённый формат: ${BOLD}${file_type}${NC}"

    local extracted_bak=""
    local extract_dir="${INCOMING_DIR}/extract_$(date +%s)"
    mkdir -p "$extract_dir"
    chmod 700 "$extract_dir"

    case "$file_type" in
        MSSQL_BAK)
            success "Файл является стандартным несжатым дампом MS SQL Server (.bak)."
            extracted_bak="$input_file"
            ;;
        GZIP_TAR)
            info "Файл является архивом GZIP/tar.gz. Распаковка..."
            tar -xzf "$input_file" -C "$extract_dir"
            local candidates=()
            mapfile -t candidates < <(find "$extract_dir" -maxdepth 2 -type f \( -iname "*.bak" -o -iname "*.db" \) -size +0c)
            if [[ ${#candidates[@]} -gt 0 ]]; then
                extracted_bak="${candidates[0]}"
                success "В архиве обнаружен файл базы: $(basename "$extracted_bak")"
            else
                error "В архиве tar.gz не найдено файлов *.bak!"
                return 1
            fi
            ;;
        ZIP)
            info "Файл является ZIP-архивом. Распаковка..."
            unzip -q -o "$input_file" -d "$extract_dir"
            local candidates=()
            mapfile -t candidates < <(find "$extract_dir" -maxdepth 2 -type f \( -iname "*.bak" -o -iname "*.db" \) -size +0c)
            if [[ ${#candidates[@]} -gt 0 ]]; then
                extracted_bak="${candidates[0]}"
                success "В архиве обнаружен файл базы: $(basename "$extracted_bak")"
            else
                error "В архиве ZIP не найдено файлов *.bak!"
                return 1
            fi
            ;;
        OPENSSL_ENC|UNKNOWN)
            if [[ "$file_type" == "OPENSSL_ENC" ]]; then
                info "Файл зашифрован через OpenSSL (сигнатура Salted__). Требуется расшифровка."
            else
                warn "Формат не распознан однозначно. Возможно, файл зашифрован или имеет кастомный заголовок."
            fi

            echo
            echo "Выберите метод обработки:"
            echo "  [1] Расшифровать AES-256-CBC + PBKDF2 (стандарт setup.sh / lers-manager)"
            echo "  [2] Попробовать передать файл напрямую в SQL Server как .bak"
            echo "  [3] Ввести кастомные параметры OpenSSL для расшифровки"
            echo "  [0] Отмена"
            read -rp "Выбор [1-3, по умолчанию 1]: " dec_choice

            case "${dec_choice:-1}" in
                1)
                    local attempt
                    for attempt in 1 2 3; do
                        local pass=""
                        read_secret_masked "Мастер-пароль (попытка $attempt из 3): " pass
                        if [[ -z "$pass" ]]; then
                            warn "Пароль не введён."
                            continue
                        fi

                        if decrypt_archive "$input_file" "$extract_dir" "$pass" extracted_bak; then
                            break
                        else
                            (( attempt < 3 )) && warn "Попробуйте снова..."
                        fi
                    done
                    ;;
                2)
                    extracted_bak="$input_file"
                    ;;
                3)
                    read -rp "Укажите алгоритм шифрования [-aes-256-cbc]: " cust_cipher
                    cust_cipher="${cust_cipher:--aes-256-cbc}"
                    read -rp "Использовать PBKDF2? [Y/n]: " use_pbkdf2
                    local pbk_flag="-pbkdf2"
                    [[ "$use_pbkdf2" =~ ^[NnНн]$ ]] && pbk_flag=""

                    local pass=""
                    read_secret_masked "Пароль расшифровки: " pass
                    local pass_f="${extract_dir}/pass.tmp"
                    printf '%s' "$pass" > "$pass_f"
                    chmod 600 "$pass_f"

                    local out_tar="${extract_dir}/decrypted_custom.tar.gz"
                    if openssl enc -d "$cust_cipher" $pbk_flag -in "$input_file" -out "$out_tar" -pass file:"$pass_f" 2>/dev/null; then
                        rm -f "$pass_f"
                        if tar -tzf "$out_tar" >/dev/null 2>&1; then
                            tar -xzf "$out_tar" -C "$extract_dir"
                            local candidates=()
                            mapfile -t candidates < <(find "$extract_dir" -maxdepth 2 -type f -iname "*.bak" -size +0c)
                            [[ ${#candidates[@]} -gt 0 ]] && extracted_bak="${candidates[0]}"
                        else
                            extracted_bak="$out_tar"
                        fi
                    else
                        rm -f "$pass_f"
                        error "Сбой при расшифровке с заданными параметрами!"
                        return 1
                    fi
                    ;;
                0)
                    return 1
                    ;;
            esac
            ;;
    esac

    if [[ -z "$extracted_bak" || ! -s "$extracted_bak" ]]; then
        error "Не удалось получить готовый файл базы данных (*.bak)!"
        return 1
    fi

    chmod 600 "$extracted_bak"
    printf -v "$__result_bak_var" '%s' "$extracted_bak"
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
            read -rp "Введите ссылку (Google Drive или HTTP/HTTPS): " download_url
            if [[ -z "$download_url" ]]; then
                error "Ссылка не указана."
                return 1
            fi
            local dest_name="LERS_backup_downloaded_$(date +%Y_%m_%d_%H%M%S).tmp"
            source_file="${INCOMING_DIR}/${dest_name}"
            if ! download_public_url "$download_url" "$source_file"; then
                return 1
            fi
            ;;
        2)
            if [[ -z "$pre_url" ]]; then
                error "Сохранённый URL отсутствует."
                return 1
            fi
            local dest_name="LERS_backup_downloaded_$(date +%Y_%m_%d_%H%M%S).tmp"
            source_file="${INCOMING_DIR}/${dest_name}"
            if ! download_public_url "$pre_url" "$source_file"; then
                return 1
            fi
            ;;
        3)
            read -rp "Введите полный путь к файлу: " source_file
            ;;
        4)
            local files=()
            mapfile -t files < <(find "${INCOMING_DIR}" -type f \( -iname "*.bak" -o -iname "*.enc" -o -iname "*.zip" -o -iname "*.gz" -o -iname "*.tar.gz" \) -print)
            if [[ ${#files[@]} -eq 0 ]]; then
                warn "В папке ${INCOMING_DIR} нет подходящих файлов."
                return 0
            fi
            echo "Доступные файлы:"
            local i=1
            for f in "${files[@]}"; do
                echo "  $i) $(basename "$f") ($(du -h "$f" | awk '{print $1}'))"
                i=$((i + 1))
            done
            read -rp "Выберите номер [1-${#files[@]}]: " f_num
            if [[ "$f_num" =~ ^[0-9]+$ ]] && (( f_num >= 1 && f_num <= ${#files[@]} )); then
                source_file="${files[$((f_num - 1))]}"
            else
                error "Неверный номер файла."
                return 1
            fi
            ;;
        5)
            download_gdrive_backup
            source_file="${INCOMING_DIR}/${CANONICAL_BACKUP_NAME}"
            ;;
        0)
            info "Операция отменена."
            return 0
            ;;
        *)
            error "Некорректный выбор."
            return 1
            ;;
    esac

    if [[ ! -s "$source_file" ]]; then
        error "Выбранный файл не существует или пуст: $source_file"
        return 1
    fi

    # Адаптивное извлечение чистого файла .bak (с расшифровкой/распаковкой при необходимости)
    local target_bak=""
    if ! prepare_sql_bak_from_source "$source_file" target_bak; then
        return 1
    fi

    # Убеждаемся, что SQL Server запущен для проверки и восстановления
    if ! docker ps --format '{{.Names}}' | grep -qx 'lers-db'; then
        info "Запуск контейнера MS SQL Server для восстановления..."
        generate_compose_files
        docker compose -f "$COMPOSE_FILE" up -d db
        wait_for_mssql
    fi

    # Валидация бэкапа перед заменой рабочей базы
    if ! verify_sql_backup "$target_bak"; then
        error "Проверка бэкапа не пройдена! Восстановление отменено ради безопасности."
        return 1
    fi

    # СТРАХОВКА: Автоматический бэкап текущей базы данных
    local check_db
    check_db="$(sql_exec "IF DB_ID('${DEFAULT_DB_NAME}') IS NOT NULL PRINT 'EXISTS'" "master" 2>/dev/null | tr -d '\r\n ')"
    if [[ "$check_db" == *"EXISTS"* ]]; then
        warn "Обнаружена существующая база данных '${DEFAULT_DB_NAME}'!"
        info "Создание аварийного снимка текущей базы перед накатом новой..."
        backup_local_database "LERS_safety_before_restore_$(date +%Y_%m_%d_%H%M%S).bak" || true
    fi

    echo
    echo -e "${YELLOW}ВНИМАНИЕ! База данных '${DEFAULT_DB_NAME}' будет заменена данными из бэкапа.${NC}"
    read -rp "Продолжить восстановление? [y/N]: " confirm_restore
    if [[ ! "$confirm_restore" =~ ^[YyДд]$ ]]; then
        info "Восстановление отменено пользователем."
        return 0
    fi

    if docker ps --format '{{.Names}}' | grep -qx 'lers-server'; then
        info "Временная остановка контейнера lers-server..."
        docker compose -f "$COMPOSE_FILE" stop lers >/dev/null 2>&1 || true
    fi

    local restore_bak_name="restore_target_$(date +%s).bak"
    local restore_host_path="${SQL_BACKUP_DIR}/${restore_bak_name}"
    cp -f "$target_bak" "$restore_host_path"
    chmod 600 "$restore_host_path"
    chgrp 0 "$restore_host_path" 2>/dev/null || true
    local container_restore_path="/var/opt/mssql/backup/${restore_bak_name}"

    step "RESTORE" "Генерация динамических предложений MOVE..."
    local move_statements
    if ! move_statements="$(get_restore_file_moves "$container_restore_path" "${DEFAULT_DB_NAME}")"; then
        error "Не удалось сформировать список файлов для RESTORE!"
        rm -f "$restore_host_path"
        return 1
    fi

    echo "Сгенерированные перемещения файлов:"
    echo "$move_statements" | tr ',' '\n' | sed 's/^/  /'

    local restore_cmd="
        USE master;
        IF DB_ID('${DEFAULT_DB_NAME}') IS NOT NULL
        BEGIN
            ALTER DATABASE [${DEFAULT_DB_NAME}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
        END;

        RESTORE DATABASE [${DEFAULT_DB_NAME}]
        FROM DISK = N'$(sql_escape "${container_restore_path}")'
        WITH REPLACE, ${move_statements};

        ALTER DATABASE [${DEFAULT_DB_NAME}] SET MULTI_USER;
    "

    info "Выполнение команды RESTORE DATABASE в MS SQL Server..."
    if ! sql_exec "$restore_cmd" "master"; then
        error "Ошибка при восстановлении базы данных в MS SQL Server!"
        rm -f "$restore_host_path"
        return 1
    fi

    rm -f "$restore_host_path"
    success "База данных '${DEFAULT_DB_NAME}' успешно восстановлена в MS SQL!"

    cleanup_orphaned_ndf_files "${DEFAULT_DB_NAME}"

    info "Запуск службы ЛЭРС УЧЁТ..."
    docker compose -f "$COMPOSE_FILE" up -d lers

    verify_lers_health
    return 0
}

download_gdrive_backup() {
    step "GOOGLE DRIVE" "Загрузка файла ${CANONICAL_BACKUP_NAME} из Google Drive (rclone)..."
    init_directories
    ensure_rclone

    local target_file="${INCOMING_DIR}/${CANONICAL_BACKUP_NAME}"

    if ! command -v rclone >/dev/null 2>&1 || [[ ! -f "$RCLONE_CONFIG_FILE" ]]; then
        error "rclone не настроен. Запустите 'rclone config' для добавления Google Drive (remote: ${GDRIVE_REMOTE})."
        return 1
    fi

    info "Копирование ${GDRIVE_REMOTE}:${GDRIVE_PATH} -> ${target_file}..."
    if rclone copyto -P "${GDRIVE_REMOTE}:${GDRIVE_PATH}" "$target_file"; then
        chmod 600 "$target_file"
        success "Файл успешно загружен через rclone: $target_file"
        return 0
    else
        error "Не удалось скачать ${CANONICAL_BACKUP_NAME} из Google Drive через rclone!"
        return 1
    fi
}

upload_gdrive_backup() {
    step "GOOGLE DRIVE" "Отправка ${CANONICAL_BACKUP_NAME} в Google Drive..."
    ensure_rclone

    local source_enc="${ENCRYPTED_BACKUP_DIR}/${CANONICAL_BACKUP_NAME}"
    if [[ ! -s "$source_enc" ]]; then
        error "Зашифрованный файл ${CANONICAL_BACKUP_NAME} не найден."
        info "Сначала создайте его через пункт: 'Создать ЗАШИФРОВАННЫЙ бэкап'"
        return 1
    fi

    if ! command -v rclone >/dev/null 2>&1 || [[ ! -f "$RCLONE_CONFIG_FILE" ]]; then
        error "rclone не настроен. Запустите настройку через меню."
        return 1
    fi

    info "Отправка ${source_enc} -> ${GDRIVE_REMOTE}:${GDRIVE_PATH}..."
    if rclone copyto -P "$source_enc" "${GDRIVE_REMOTE}:${GDRIVE_PATH}"; then
        success "Файл ${CANONICAL_BACKUP_NAME} успешно отправлен в Google Drive!"
        return 0
    else
        error "Сбой при передаче файла в Google Drive через rclone!"
        return 1
    fi
}

setup_rclone_wizard() {
    step "RCLONE CONFIG" "Мастер настройки Google Drive через rclone..."
    ensure_rclone
    echo "Запуск официального конфигуратора 'rclone config'..."
    rclone config
}

# ------------------------------------------------------------------------------
# 6. СЛОЙ REMOTE SQL: Универсальный модуль Windows/Linux (SMB / SFTP / Local)
# ------------------------------------------------------------------------------
remote_mssql_ask_creds() {
    echo "Параметры подключения к удалённому MS SQL Server:"
    read -rp "IP или Хост SQL сервера [${CACHED_R_HOST:-192.168.1.100}]: " input_host
    CACHED_R_HOST="${input_host:-${CACHED_R_HOST:-192.168.1.100}}"

    read -rp "Порт SQL [${CACHED_R_PORT}]: " input_port
    CACHED_R_PORT="${input_port:-$CACHED_R_PORT}"

    read -rp "Имя базы данных [${CACHED_R_DB}]: " input_db
    CACHED_R_DB="${input_db:-$CACHED_R_DB}"

    read -rp "Пользователь SQL [${CACHED_R_USER}]: " input_user
    CACHED_R_USER="${input_user:-$CACHED_R_USER}"

    if [[ -z "$CACHED_R_PASS" ]]; then
        read_secret_masked "Пароль SQL (${CACHED_R_USER}): " CACHED_R_PASS
    else
        echo "Использовать сохранённый в сессии пароль SQL? [Y/n]: "
        read -rp "" reuse_pass
        if [[ "$reuse_pass" =~ ^[NnНн]$ ]]; then
            read_secret_masked "Новый пароль SQL (${CACHED_R_USER}): " CACHED_R_PASS
        fi
    fi
    echo
}

# ------------------------------------------------------------------------------
# Поиск доступного клиента SQL (sqlcmd18 -> sqlcmd -> lers-db -> docker run)
# ------------------------------------------------------------------------------
find_sqlcmd_client() {
    local __client_type_var="$1"
    local __client_path_var="$2"
    local __trust_flag_var="$3"

    # 1. Поиск нативного sqlcmd на хосте (без Docker)
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
            local trust_f=""
            if "$bin" -? 2>&1 | grep -q -- '-C'; then
                trust_f="-C"
            fi
            printf -v "$__client_type_var" '%s' "NATIVE"
            printf -v "$__client_path_var" '%s' "$bin"
            printf -v "$__trust_flag_var" '%s' "$trust_f"
            return 0
        fi
    done

    # 2. Использование локального контейнера lers-db (если он запущен)
    if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'lers-db'; then
        printf -v "$__client_type_var" '%s' "CONTAINER_LERS_DB"
        printf -v "$__client_path_var" '%s' "lers-db"
        printf -v "$__trust_flag_var" '%s' "-C"
        return 0
    fi

    # 3. Использование Docker run (только если Docker установлен)
    if command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1; then
        printf -v "$__client_type_var" '%s' "DOCKER_RUN"
        printf -v "$__client_path_var" '%s' "mcr.microsoft.com/mssql-tools:latest"
        printf -v "$__trust_flag_var" '%s' ""
        return 0
    fi

    return 1
}

# Установка официального клиента Microsoft sqlcmd без Docker
install_native_sqlcmd() {
    info "Установка официального Microsoft sqlcmd..."
    if [[ ! -f /etc/os-release ]]; then
        error "Файл /etc/os-release не найден."
        return 1
    fi
    source /etc/os-release
    local os_id="${ID:-ubuntu}"
    local os_ver="${VERSION_ID:-22.04}"

    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/microsoft.gpg 2>/dev/null ||         curl -sSL https://packages.microsoft.com/keys/microsoft.asc | apt-key add - 2>/dev/null || true

    local repo_url="https://packages.microsoft.com/config/${os_id}/${os_ver}/prod.list"
    if curl -sSL -f "$repo_url" -o /etc/apt/sources.list.d/msprod.list 2>/dev/null; then
        apt-get update -qq
        ACCEPT_EULA=Y apt-get install -y -qq mssql-tools18 unixodbc-dev >/dev/null 2>&1 ||         ACCEPT_EULA=Y apt-get install -y -qq mssql-tools unixodbc-dev >/dev/null 2>&1 || true

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

# Универсальное выполнение SQL на удалённом сервере
remote_sqlcmd() {
    local host="$1"
    local port="$2"
    local user="$3"
    local pass="$4"
    local db="${5:-master}"
    local query="$6"
    local extra_flags="${7:-}"

    local client_type="" client_path="" trust_flag=""

    if ! find_sqlcmd_client client_type client_path trust_flag; then
        warn "Утилита sqlcmd не найдена, и служба Docker не установлена/не запущена."
        echo "Для проверки и работы с удалённым MS SQL Server выберите:"
        echo "  [1] Установить официальный Microsoft sqlcmd (быстро, без Docker)"
        echo "  [2] Установить Docker"
        echo "  [0] Отмена"
        read -rp "Выбор [1-2, 0 для отмены]: " inst_choice
        case "$inst_choice" in
            1)
                install_native_sqlcmd
                if ! find_sqlcmd_client client_type client_path trust_flag; then
                    error "Клиент sqlcmd не найден после установки."
                    return 1
                fi
                ;;
            2)
                ensure_dependencies
                if ! find_sqlcmd_client client_type client_path trust_flag; then
                    error "Не удалось запустить Docker."
                    return 1
                fi
                ;;
            *)
                error "Операция отменена: отсутствует SQL-клиент."
                return 1
                ;;
        esac
    fi

    case "$client_type" in
        NATIVE)
            SQLCMDPASSWORD="$pass" "$client_path" -S "${host},${port}" -U "${user}" -d "${db}" -Q "${query}" $trust_flag $extra_flags -b
            ;;
        CONTAINER_LERS_DB)
            docker exec -i lers-db bash -c "
                if [ -x /opt/mssql-tools18/bin/sqlcmd ]; then
                    CMD=/opt/mssql-tools18/bin/sqlcmd; FLAGS="-C"
                else
                    CMD=/opt/mssql-tools/bin/sqlcmd; FLAGS=""
                fi
                SQLCMDPASSWORD="$(cat)" "\$CMD" -S '${host},${port}' -U '${user}' -d '${db}' -Q '${query}' \$FLAGS $extra_flags -b
            " <<< "$pass"
            ;;
        DOCKER_RUN)
            docker run --rm -i -e "SQLCMDPASSWORD=${pass}" "$client_path"                 /opt/mssql-tools/bin/sqlcmd -S "${host},${port}" -U "${user}" -d "${db}" -Q "${query}" $extra_flags -b
            ;;
    esac
}

remote_mssql_test_connection() {
    step "ПРОВЕРКА SQL" "Тестирование подключения к удалённому MS SQL Server..."
    remote_mssql_ask_creds

    local tcp_status="НЕДОСТУПЕН"
    if timeout 4 bash -c "</dev/tcp/${CACHED_R_HOST}/${CACHED_R_PORT}" 2>/dev/null; then
        tcp_status="OK"
    else
        warn "Сетевой порт ${CACHED_R_PORT} не отвечает напрямую через TCP."
    fi

    local client_type="" client_path="" trust_flag=""
    find_sqlcmd_client client_type client_path trust_flag || true
    local client_desc="${client_type:-НЕ НАЙДЕН} (${client_path:-отсутствует})"
    [[ "$client_type" == "NATIVE" ]] && client_desc="$(basename "$client_path") ($client_path)"
    [[ "$client_type" == "CONTAINER_LERS_DB" ]] && client_desc="sqlcmd (внутри контейнера lers-db)"

    info "Подключение и авторизация на ${CACHED_R_HOST}:${CACHED_R_PORT}..."
    local auth_query="
        SET NOCOUNT ON;
        SELECT
            CAST(SERVERPROPERTY('ProductVersion') AS varchar) + '|' +
            CAST(SERVERPROPERTY('Edition') AS varchar) + '|' +
            ISNULL((SELECT state_desc FROM sys.databases WHERE name='$(sql_escape "$CACHED_R_DB")'), 'NOT_FOUND');
    "

    local auth_result
    if ! auth_result="$(remote_sqlcmd "$CACHED_R_HOST" "$CACHED_R_PORT" "$CACHED_R_USER" "$CACHED_R_PASS" "master" "$auth_query" "-h -1 -W" 2>&1)"; then
        error "Ошибка подключения / авторизации на удалённом SQL Server!"
        echo "$auth_result" | sed 's/^/  /'
        return 1
    fi

    local r_ver="" r_edition="" r_db_state=""
    local line
    line="$(echo "$auth_result" | grep '|' | tail -n1)"
    r_ver="$(echo "$line" | cut -d'|' -f1 | tr -d ' ')"
    r_edition="$(echo "$line" | cut -d'|' -f2 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    r_db_state="$(echo "$line" | cut -d'|' -f3 | tr -d ' 
')"

    echo
    echo -e "${GREEN}======================================================================${NC}"
    echo -e "${GREEN}  ✓ ДИАГНОСТИКА УДАЛЁННОГО MS SQL SERVER${NC}"
    echo -e "${GREEN}======================================================================${NC}"
    printf "  %-24s: %b
" "TCP ${CACHED_R_HOST}:${CACHED_R_PORT}" "${GREEN}${tcp_status}${NC}"
    printf "  %-24s: %s
" "SQL client" "$client_desc"
    printf "  %-24s: %b
" "Authentication" "${GREEN}OK${NC}"
    printf "  %-24s: %s
" "SQL Server version" "${r_ver:-unknown}"
    printf "  %-24s: %s
" "SQL Server edition" "${r_edition:-unknown}"
    if [[ "$r_db_state" == "ONLINE" ]]; then
        printf "  %-24s: %b (ONLINE)
" "Database [${CACHED_R_DB}]" "${GREEN}OK${NC}"
    elif [[ "$r_db_state" == "NOT_FOUND" ]]; then
        printf "  %-24s: %b
" "Database [${CACHED_R_DB}]" "${RED}НЕ НАЙДЕНА НА СЕРВЕРЕ${NC}"
    else
        printf "  %-24s: %b (${r_db_state})
" "Database [${CACHED_R_DB}]" "${YELLOW}СТАТУС НЕ ONLINE${NC}"
    fi
    echo -e "${GREEN}======================================================================${NC}"
    echo
    return 0
}

remote_mssql_create_backup() {
    local __result_path_var="${1:-}"
    step "REMOTE BACKUP" "Запуск резервного копирования на удалённом SQL Server..."
    remote_mssql_ask_creds

    local default_rem_path="C:\Backup\LERS_backup_$(date +%Y_%m_%d_%H%M%S).bak"
    echo "Укажите локальный путь НА УДАЛЁННОМ СЕРВЕРЕ (диск Windows или Linux):"
    read -rp "Путь [$default_rem_path]: " rem_path
    rem_path="${rem_path:-$default_rem_path}"

    info "Выполнение BACKUP DATABASE [${CACHED_R_DB}] TO DISK = N'${rem_path}'..."
    local b_query="
        BACKUP DATABASE [$(sql_escape "$CACHED_R_DB")]
        TO DISK = N'$(sql_escape "$rem_path")'
        WITH COPY_ONLY, COMPRESSION, STATS = 20, FORMAT, INIT;
    "

    local b_res
    if ! b_res="$(remote_sqlcmd "$CACHED_R_HOST" "$CACHED_R_PORT" "$CACHED_R_USER" "$CACHED_R_PASS" "master" "$b_query" "" 2>&1)"; then
        error "Сбой при выполнении BACKUP DATABASE на удалённом сервере!"
        echo "$b_res" | sed 's/^/  /'
        return 1
    fi

    success "Резервная копия успешно создана на удалённом сервере: ${rem_path}"
    if [[ -n "$__result_path_var" ]]; then
        printf -v "$__result_path_var" '%s' "$rem_path"
    fi
    return 0
}

remote_transport_fetch_file() {
    local default_remote_path="${1:-}"
    local __result_local_path_var="$2"

    step "ТРАНСПОРТ" "Скачивание бэкапа с удалённого сервера на VPS..."
    init_directories

    echo "Выберите транспорт для передачи файла с Windows/Linux сервера:"
    echo "  [1] SMB / Windows Network Share (через smbclient — без необходимости SSH)"
    echo "  [2] SFTP / SCP (OpenSSH на Windows Server или Linux)"
    echo "  [3] Локальный / уже смонтированный каталог на VPS (NFS / CIFS mount)"
    echo "  [0] Отмена"
    read -rp "Выбор [0-3]: " t_choice

    local local_target=""

    case "$t_choice" in
        1)
            ensure_dependencies
            echo
            info "Настройка передачи по SMB (Windows Share):"
            read -rp "IP/Хост Windows сервера [${CACHED_R_HOST}]: " smb_host
            smb_host="${smb_host:-$CACHED_R_HOST}"

            read -rp "Имя сетевого ресурса (Share) [C$ или Backup]: " smb_share
            smb_share="${smb_share:-C$}"

            read -rp "Домен Windows (пусто если локальный пользователь): " smb_domain
            read -rp "Пользователь Windows [Administrator]: " smb_user
            smb_user="${smb_user:-Administrator}"

            local smb_pass=""
            read_secret_masked "Пароль Windows (${smb_user}): " smb_pass
            echo

            local def_rem_name="Backup\\LERS_backup.bak"
            if [[ -n "$default_remote_path" ]]; then
                def_rem_name="${default_remote_path#*:\\}"
            fi
            read -rp "Путь к файлу внутри ресурса [${def_rem_name}]: " smb_file
            smb_file="${smb_file:-$def_rem_name}"
            smb_file="${smb_file//\//\\}"

            local target_filename
            target_filename="$(basename "${smb_file//\\//}")"
            local_target="${INCOMING_DIR}/${target_filename}"

            local auth_file
            auth_file="$(mktemp /tmp/smb_auth.XXXXXX)"
            chmod 600 "$auth_file"
            cat > "$auth_file" <<EOF
username = ${smb_user}
password = ${smb_pass}
domain = ${smb_domain}
EOF

            info "Скачивание //${smb_host}/${smb_share}/${smb_file} -> ${local_target}..."
            local smb_cmd="get \"${smb_file}\" \"${local_target}\""

            if smbclient "//${smb_host}/${smb_share}" -A "$auth_file" -c "$smb_cmd" 2>&1; then
                rm -f "$auth_file"
                chmod 600 "$local_target"
                success "Файл успешно получен по SMB: $local_target ($(du -h "$local_target" | awk '{print $1}'))"
            else
                rm -f "$auth_file"
                error "Сбой передачи файла через SMB! Проверьте имя шары, права и путь."
                return 1
            fi
            ;;
        2)
            echo
            info "Настройка передачи по SFTP / SCP:"
            read -rp "SSH/SFTP хост [${CACHED_R_HOST}]: " sftp_host
            sftp_host="${sftp_host:-$CACHED_R_HOST}"
            read -rp "SSH/SFTP порт [22]: " sftp_port
            sftp_port="${sftp_port:-22}"
            read -rp "SSH/SFTP пользователь [Administrator/root]: " sftp_user
            sftp_user="${sftp_user:-Administrator}"

            echo "Путь к файлу на сервере в формате SFTP:"
            local def_sftp_path="/C:/Backup/LERS_backup.bak"
            if [[ -n "$default_remote_path" ]]; then
                def_sftp_path="/${default_remote_path//\\//}"
            fi
            read -rp "Путь [${def_sftp_path}]: " sftp_path
            sftp_path="${sftp_path:-$def_sftp_path}"

            local target_filename
            target_filename="$(basename "$sftp_path")"
            local_target="${INCOMING_DIR}/${target_filename}"

            info "Запуск передачи scp..."
            if scp -P "$sftp_port" "${sftp_user}@${sftp_host}:${sftp_path}" "$local_target"; then
                chmod 600 "$local_target"
                success "Файл успешно скачан через SCP: $local_target"
            else
                error "Сбой передачи через SCP."
                return 1
            fi
            ;;
        3)
            read -rp "Введите полный путь к смонтированному файлу .bak: " mounted_file
            if [[ ! -s "$mounted_file" ]]; then
                error "Файл не найден: $mounted_file"
                return 1
            fi
            local_target="${INCOMING_DIR}/$(basename "$mounted_file")"
            cp -f "$mounted_file" "$local_target"
            chmod 600 "$local_target"
            success "Файл скопирован из смонтированного каталога: $local_target"
            ;;
        0)
            return 1
            ;;
        *)
            error "Некорректный выбор."
            return 1
            ;;
    esac

    if [[ ! -s "$local_target" ]]; then
        error "Целевой файл пуст или отсутствует: $local_target"
        return 1
    fi

    printf -v "$__result_local_path_var" '%s' "$local_target"
    return 0
}

handle_post_download_flow() {
    local bak_file="$1"
    local do_verify="${2:-ask}"
    local do_encrypt="${3:-ask}"

    if [[ ! -s "$bak_file" ]]; then
        error "Файл для обработки не найден: $bak_file"
        return 1
    fi

    if [[ "$do_verify" == "1" ]] || [[ "$do_verify" == "ask" ]]; then
        if [[ "$do_verify" == "ask" ]]; then
            echo
            read -rp "Выполнить немедленную проверку целостности (RESTORE VERIFYONLY)? [Y/n]: " v_choice
            [[ ! "$v_choice" =~ ^[NnНн]$ ]] && do_verify="1" || do_verify="0"
        fi

        if [[ "$do_verify" == "1" ]]; then
            if ! verify_sql_backup "$bak_file"; then
                error "Резервная копия не прошла проверку целостности!"
                return 1
            fi
        fi
    fi

    if [[ "$do_encrypt" == "1" ]] || [[ "$do_encrypt" == "ask" ]]; then
        if [[ "$do_encrypt" == "ask" ]]; then
            echo
            echo "Действие с полученным файлом .bak:"
            echo "  [1] Оставить .bak как есть (без шифрования)"
            echo "  [2] Зашифровать в ${CANONICAL_BACKUP_NAME} и сохранить оба файла"
            echo "  [3] Зашифровать в ${CANONICAL_BACKUP_NAME} и удалить исходный .bak"
            read -rp "Выбор [1-3, по умолчанию 1]: " post_act
            case "${post_act:-1}" in
                1) do_encrypt="0" ;;
                2) do_encrypt="keep_both" ;;
                3) do_encrypt="delete_bak" ;;
                *) do_encrypt="0" ;;
            esac
        fi

        if [[ "$do_encrypt" == "1" || "$do_encrypt" == "keep_both" || "$do_encrypt" == "delete_bak" ]]; then
            local canonical_target="${ENCRYPTED_BACKUP_DIR}/${CANONICAL_BACKUP_NAME}"
            local master_p=""
            read_secret_masked "Мастер-пароль шифрования (AES-256-CBC PBKDF2): " master_p
            echo

            if encrypt_archive "$bak_file" "$canonical_target" "$master_p"; then
                if [[ "$do_encrypt" == "delete_bak" ]]; then
                    rm -f "$bak_file"
                    info "Исходный файл .bak удалён. Сохранён только зашифрованный архив."
                fi

                echo
                read -rp "Загрузить ${CANONICAL_BACKUP_NAME} в Google Drive (rclone)? [y/N]: " up_gdrive
                if [[ "$up_gdrive" =~ ^[YyДд]$ ]]; then
                    upload_gdrive_backup || true
                fi
            fi
        fi
    fi
    return 0
}

remote_mssql_menu() {
    while true; do
        print_banner
        echo -e "${BOLD}  МОДУЛЬ: УДАЛЁННЫЙ MS SQL SERVER (WINDOWS / LINUX)${NC}"
        echo "  ──────────────────────────────────────────────────────────────────"
        echo "  [1] Подключиться и проверить связь с SQL Server"
        echo "  [2] Создать BACKUP на удалённом сервере (только на Windows без скачивания)"
        echo "  [3] Скачать существующий BACKUP с сервера на VPS (SMB Share или SFTP)"
        echo "  [4] Скачать без шифрования (просто положить .bak в incoming/)"
        echo "  [5] Скачать → Проверить (VERIFYONLY) → Зашифровать в ${CANONICAL_BACKUP_NAME}"
        echo "  [6] Полный цикл: BACKUP на сервере → Скачать → Проверить → Зашифровать"
        echo "  [7] Полный цикл + Загрузка в Google Drive (rclone)"
        echo "  [8] Проверить любой скачанный файл бэкапа (RESTORE VERIFYONLY)"
        echo "  [0] Назад в главное меню"
        echo "  ──────────────────────────────────────────────────────────────────"
        read -rp "Выберите пункт [0-8]: " r_menu_choice

        case "$r_menu_choice" in
            1)
                remote_mssql_test_connection
                ;;
            2)
                remote_mssql_create_backup
                ;;
            3)
                local downloaded=""
                if remote_transport_fetch_file "" downloaded; then
                    handle_post_download_flow "$downloaded" "ask" "ask"
                fi
                ;;
            4)
                local downloaded=""
                if remote_transport_fetch_file "" downloaded; then
                    success "Файл сохранён в исходном виде: $downloaded"
                fi
                ;;
            5)
                local downloaded=""
                if remote_transport_fetch_file "" downloaded; then
                    handle_post_download_flow "$downloaded" "1" "1"
                fi
                ;;
            6)
                local rem_bak=""
                if remote_mssql_create_backup rem_bak; then
                    local downloaded=""
                    if remote_transport_fetch_file "$rem_bak" downloaded; then
                        handle_post_download_flow "$downloaded" "1" "1"
                    fi
                fi
                ;;
            7)
                local rem_bak=""
                if remote_mssql_create_backup rem_bak; then
                    local downloaded=""
                    if remote_transport_fetch_file "$rem_bak" downloaded; then
                        if handle_post_download_flow "$downloaded" "1" "1"; then
                            upload_gdrive_backup || true
                        fi
                    fi
                fi
                ;;
            8)
                read -rp "Путь к файлу для проверки: " check_f
                [[ -s "$check_f" ]] && verify_sql_backup "$check_f" || error "Файл не найден."
                ;;
            0)
                return 0
                ;;
            *)
                error "Неверный ввод."
                ;;
        esac

        echo
        read -rp "Нажмите Enter для продолжения..." _dummy || true
    done
}

# ------------------------------------------------------------------------------
# 7. ДИАГНОСТИКА И СЛУЖЕБНЫЕ ФУНКЦИИ
# ------------------------------------------------------------------------------
show_status_and_diagnostics() {
    print_banner
    step "СТАТУС" "Диагностика компонентов ЛЭРС УЧЁТ и MS SQL Server"

    echo -e "${BOLD}1. Контейнеры Docker Compose:${NC}"
    if docker compose -f "$COMPOSE_FILE" ps 2>/dev/null; then
        echo
    else
        warn "Контейнеры не запущены или compose.yml отсутствует."
    fi

    echo -e "${BOLD}2. Сетевые порты:${NC}"
    local p10000="НЕДОСТУПЕН"
    local p1433="НЕДОСТУПЕН"

    if ss -tlpn 2>/dev/null | grep -q ":${DEFAULT_LERS_PORT}"; then
        p10000="${GREEN}СЛУШАЕТ (:10000)${NC}"
    fi
    if ss -tlpn 2>/dev/null | grep -q ":1433"; then
        p1433="${GREEN}СЛУШАЕТ (:1433)${NC}"
    fi

    echo -e "  Веб-интерфейс ЛЭРС (:10000) : $p10000"
    echo -e "  MS SQL Server (:1433)       : $p1433"
    echo

    echo -e "${BOLD}3. Подключение к БД и версия:${NC}"
    if docker ps --format '{{.Names}}' | grep -qx 'lers-db'; then
        local sql_ver
        if sql_ver="$(sql_exec "SELECT @@VERSION" "master" 2>/dev/null | head -n 2)"; then
            echo -e "${GREEN}✓ MS SQL Server активен:${NC}"
            echo "$sql_ver" | sed 's/^/    /'
            echo
            local lers_db_check
            lers_db_check="$(sql_exec "SELECT name, state_desc, create_date FROM sys.databases WHERE name='${DEFAULT_DB_NAME}'" "master" 2>/dev/null)"
            if [[ -n "$lers_db_check" ]]; then
                echo -e "${GREEN}✓ База данных '${DEFAULT_DB_NAME}' активна:${NC}"
                echo "$lers_db_check" | sed 's/^/    /'
            else
                warn "База данных '${DEFAULT_DB_NAME}' отсутствует."
            fi
        else
            error "Не удалось подключиться к MS SQL Server через sa."
        fi
    else
        error "Контейнер lers-db не запущен."
    fi

    echo
    echo -e "${BOLD}4. Дисковые каталоги:${NC}"
    if [[ -d "$LERS_BASE_DIR" ]]; then
        du -sh "${LERS_BASE_DIR}" "${SQLDATA_DIR}" "${BACKUP_DIR}" 2>/dev/null | sed 's/^/  /'
    fi
    echo
}

view_logs_menu() {
    echo
    echo "Выберите логи:"
    echo "  1) Сервер ЛЭРС УЧЁТ (lers-server)"
    echo "  2) База данных MS SQL (lers-db)"
    echo "  3) Совместные логи обоих контейнеров"
    echo "  0) Назад"
    read -rp "Выбор [0-3]: " log_choice

    case "$log_choice" in
        1) docker compose -f "$COMPOSE_FILE" logs -f --tail 100 lers ;;
        2) docker compose -f "$COMPOSE_FILE" logs -f --tail 100 db ;;
        3) docker compose -f "$COMPOSE_FILE" logs -f --tail 100 ;;
        0) return 0 ;;
        *) error "Неверный выбор." ;;
    esac
}

control_services() {
    local action="$1"
    case "$action" in
        start)
            info "Запуск сервисов..."
            docker compose -f "$COMPOSE_FILE" up -d
            success "Сервисы запущены."
            ;;
        stop)
            info "Остановка сервисов..."
            docker compose -f "$COMPOSE_FILE" stop
            success "Сервисы остановлены."
            ;;
        restart)
            info "Перезапуск сервисов..."
            docker compose -f "$COMPOSE_FILE" restart
            success "Сервисы перезапущены."
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 8. ИНТЕРАКТИВНОЕ МЕНЮ И CLI
# ------------------------------------------------------------------------------
main_interactive_menu() {
    check_prerequisites

    while true; do
        print_banner
        echo -e "${BOLD}  [ РАЗВЁРТЫВАНИЕ И СЕРВИСЫ ]${NC}"
        echo "  [1]  Установить ЛЭРС УЧЁТ + MS SQL (чистая установка Docker Compose)"
        echo "  [2]  Обновить ЛЭРС УЧЁТ (с обязательным автобэкапом и верификацией)"
        echo "  [3]  Статус системы, портов и базы данных"
        echo "  [4]  Журналы и логи (docker compose logs)"
        echo "  [5]  Управление питанием (start / stop / restart)"
        echo
        echo -e "${BOLD}  [ РЕЗЕРВНОЕ КОПИРОВАНИЕ И ВОССТАНОВЛЕНИЕ ]${NC}"
        echo "  [6]  Восстановить БД (по URL, Google Drive ссылке или локальному файлу)"
        echo "  [7]  Создать локальный бэкап (.bak)"
        echo "  [8]  Создать ЗАШИФРОВАННЫЙ бэкап (AES-256-CBC PBKDF2 -> ${CANONICAL_BACKUP_NAME})"
        echo "  [9]  Проверить / верифицировать бэкап (.enc, .bak, .zip, .tar.gz)"
        echo "  [10] Удалённый MS SQL Server (Windows/Linux: SMB / SFTP / Backup)"
        echo
        echo -e "${BOLD}  [ GOOGLE DRIVE (RCLONE) ]${NC}"
        echo "  [11] Скачать актуальный ${CANONICAL_BACKUP_NAME} из Google Drive (rclone)"
        echo "  [12] Загрузить ${CANONICAL_BACKUP_NAME} в Google Drive (rclone)"
        echo "  [13] Настройка подключения rclone к Google Drive"
        echo
        echo "  [0]  Выход"
        echo "  ──────────────────────────────────────────────────────────────────"
        read -rp "Выберите пункт меню [0-13]: " menu_choice

        case "$menu_choice" in
            1)  install_clean_lers ;;
            2)  update_lers_system ;;
            3)  show_status_and_diagnostics ;;
            4)  view_logs_menu ;;
            5)
                echo "  a) Запустить (start)"
                echo "  b) Остановить (stop)"
                echo "  c) Перезапустить (restart)"
                read -rp "Действие [a/b/c]: " p_act
                case "$p_act" in
                    a) control_services start ;;
                    b) control_services stop ;;
                    c) control_services restart ;;
                esac
                ;;
            6)  restore_database_flow ;;
            7)  backup_local_database ;;
            8)  backup_and_encrypt_local_database ;;
            9)
                read -rp "Укажите путь к файлу для проверки: " v_file
                if [[ -s "$v_file" ]]; then
                    local checked_bak=""
                    if prepare_sql_bak_from_source "$v_file" checked_bak; then
                        verify_sql_backup "$checked_bak"
                    fi
                else
                    error "Файл не найден: $v_file"
                fi
                ;;
            10) remote_mssql_menu ;;
            11) download_gdrive_backup ;;
            12) upload_gdrive_backup ;;
            13) setup_rclone_wizard ;;
            0)
                echo "Выход."
                exit 0
                ;;
            *)
                error "Неверный выбор."
                ;;
        esac

        echo
        read -rp "Нажмите Enter для продолжения..." _dummy || true
    done
}

if [[ $# -gt 0 ]]; then
    check_prerequisites
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
                # Если передан URL или файл напрямую
                init_directories
                local input_src="$2"
                local target_f="$input_src"
                if [[ "$input_src" =~ ^https?:// ]]; then
                    target_f="${INCOMING_DIR}/LERS_backup_cli_$(date +%s).tmp"
                    download_public_url "$input_src" "$target_f"
                fi
                local extracted_bak=""
                if prepare_sql_bak_from_source "$target_f" extracted_bak; then
                    if ! docker ps --format '{{.Names}}' | grep -qx 'lers-db'; then
                        generate_compose_files
                        docker compose -f "$COMPOSE_FILE" up -d db
                        wait_for_mssql
                    fi
                    if verify_sql_backup "$extracted_bak"; then
                        backup_local_database "LERS_safety_before_restore_$(date +%Y_%m_%d_%H%M%S).bak" || true
                        docker compose -f "$COMPOSE_FILE" stop lers >/dev/null 2>&1 || true

                        local r_bak_name="restore_cli_$(date +%s).bak"
                        local r_host_p="${SQL_BACKUP_DIR}/${r_bak_name}"
                        cp -f "$extracted_bak" "$r_host_p"
                        chmod 600 "$r_host_p"
                        chgrp 0 "$r_host_p" 2>/dev/null || true

                        local moves
                        moves="$(get_restore_file_moves "/var/opt/mssql/backup/${r_bak_name}" "${DEFAULT_DB_NAME}")"
                        local r_sql="
                            USE master;
                            IF DB_ID('${DEFAULT_DB_NAME}') IS NOT NULL ALTER DATABASE [${DEFAULT_DB_NAME}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
                            RESTORE DATABASE [${DEFAULT_DB_NAME}] FROM DISK = N'/var/opt/mssql/backup/${r_bak_name}' WITH REPLACE, ${moves};
                            ALTER DATABASE [${DEFAULT_DB_NAME}] SET MULTI_USER;
                        "
                        sql_exec "$r_sql" "master"
                        rm -f "$r_host_p"
                        cleanup_orphaned_ndf_files "${DEFAULT_DB_NAME}"
                        docker compose -f "$COMPOSE_FILE" up -d lers
                        verify_lers_health
                        success "База данных успешно восстановлена из CLI!"
                    fi
                fi
            else
                restore_database_flow
            fi
            ;;
        verify)
            if [[ -n "${2:-}" ]]; then
                init_directories
                local checked_bak=""
                if prepare_sql_bak_from_source "$2" checked_bak; then
                    verify_sql_backup "$checked_bak"
                fi
            else
                error "Укажите путь к файлу: bash lers-manager.sh verify <file>"
            fi
            ;;
        remote)
            remote_mssql_menu
            ;;
        download-cloud)
            download_gdrive_backup
            ;;
        upload-cloud)
            upload_gdrive_backup
            ;;
        update)
            update_lers_system
            ;;
        status)
            show_status_and_diagnostics
            ;;
        logs)
            docker compose -f "$COMPOSE_FILE" logs -f --tail 100
            ;;
        start)
            control_services start
            ;;
        stop)
            control_services stop
            ;;
        restart)
            control_services restart
            ;;
        *)
            echo "Использование: $0 [install|backup|backup-enc|restore [URL|file]|verify <file>|remote|download-cloud|upload-cloud|update|status|logs|start|stop|restart]"
            exit 1
            ;;
    esac
else
    main_interactive_menu
fi
