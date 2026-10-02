#!/usr/bin/env bash

###############################################################################
# ☁️ VPS BOOTSTRAP / SETUP
# Версия: 3.9.3 (Production-Ready)
#
# Поддерживаемые ОС: Ubuntu / Debian (amd64, arm64)
#
# Ключевые особенности:
#   - SSH порт: 1241 (с авто-созданием /run/sshd для Ubuntu 24.04)
#   - Рабочие порты Xray: 2053, 8443
#   - WARP SOCKS5: 127.0.0.1:40000 (только localhost)
#   - Полное отключение стандартного спама Ubuntu MOTD
#   - Быстрый эксплуатационный MOTD (без задержек на ping и sleep)
#   - Защита паролей: MSSQL пароль в /root/.mssql-sa-password (права 600)
#   - Блокирующая финальная проверка компонентов
###############################################################################

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

SCRIPT_VERSION="5.0"
BOOTSTRAP_MARKER="/etc/vps-bootstrap-complete"
LOG_FILE="/var/log/vps-setup.log"

# Настраиваемые параметры
SSH_PORT="${SSH_PORT:-1241}"
XUI_PORT="${XUI_PORT:-8784}"
ACME_PORT="${ACME_PORT:-80}"
WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"

# Единый список рабочих портов входящих соединений Xray
XRAY_PORTS=("2053" "8443")

DB_RESTORED=0
PREPARED_XUI_DB=""
PREPARED_XUI_TMP_DIR=""
REG_CHOICE="${REG_CHOICE:-}"
INSTALL_POSTGRES="${INSTALL_POSTGRES:-}"
INSTALL_MSSQL="${INSTALL_MSSQL:-}"
INSTALL_TORRSERVER="${INSTALL_TORRSERVER:-}"

DISABLE_IPV6="${DISABLE_IPV6:-1}"
ENABLE_IP_FORWARD="${ENABLE_IP_FORWARD:-0}"

# Порт 54325 для вспомогательного сервиса бэкенда / RPC
ALLOW_PORT_54325="${ALLOW_PORT_54325:-1}"

# Настройки Cloudflare WARP
INSTALL_WARP="${INSTALL_WARP:-1}"
WARP_MANDATORY="${WARP_MANDATORY:-1}"

FORCE_BOOTSTRAP="${FORCE_BOOTSTRAP:-0}"

XUI_INSTALL_URL="https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh"
XUI_UPDATE_URL="https://raw.githubusercontent.com/MHSanaei/3x-ui/main/update.sh"

BACKUP_DIR="/root/xui_backups"
PRE_UPDATE_DIR="${BACKUP_DIR}/pre-update"
MAINTENANCE_FILE="/etc/cron.d/vps-maintenance"
MSSQL_SA_PASSWORD_FILE="/root/.mssql-sa-password"


###############################################################################
# 1. ROOT, МАРКЕР, OS & ARCH CHECK
###############################################################################

if [[ "${EUID}" -ne 0 ]]; then
    echo "❌ Скрипт необходимо запускать с правами root."
    exit 1
fi

if [[ -f "$BOOTSTRAP_MARKER" ]] && [[ "$FORCE_BOOTSTRAP" != "1" ]]; then
    echo
    echo "======================================================================"
    echo " ⚠️ ВНИМАНИЕ: Сервер уже настроен этим скриптом!"
    echo " Маркер: ${BOOTSTRAP_MARKER}"
    echo " Для повторного запуска используйте: FORCE_BOOTSTRAP=1 bash setup.sh"
    echo "======================================================================"
    echo
    exit 0
fi

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

echo
echo "======================================================================"
echo " ☁️ VPS BOOTSTRAP ${SCRIPT_VERSION}"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================================"
echo

on_error() {
    local exit_code=$?
    echo
    echo "======================================================================"
    echo " ❌ ОШИБКА РАЗВЕРТЫВАНИЯ: Код ${exit_code} на строке ${BASH_LINENO[0]:-unknown}"
    echo " Команда: ${BASH_COMMAND:-unknown}"
    echo " Лог: ${LOG_FILE}"
    echo "======================================================================"
    echo
    exit "$exit_code"
}
trap on_error ERR

if [[ ! -f /etc/os-release ]]; then
    echo "❌ Не найден /etc/os-release."
    exit 1
fi

source /etc/os-release
OS_ID="${ID:-unknown}"
OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"

echo "OS           : ${PRETTY_NAME:-$OS_ID}"
echo "Codename     : ${OS_CODENAME:-unknown}"
echo "Архитектура  : ${ARCH}"

case "$OS_ID" in
    ubuntu|debian) ;;
    *) echo "❌ Поддерживаются только Ubuntu и Debian."; exit 1 ;;
esac

case "$ARCH" in
    amd64|arm64|x86_64|aarch64) ;;
    *) echo "❌ Архитектура ${ARCH} не поддерживается."; exit 1 ;;
esac

###############################################################################
# ФУНКЦИИ ПОДГОТОВКИ И УСТАНОВКИ ЭТАЛОННОЙ БАЗЫ 3X-UI
###############################################################################

prepare_custom_database() {
    local reg_choice="${REG_CHOICE:-0}"
    local token="${GH_TOKEN:-}"
    local db_pass="${DB_PASS:-}"
    local repo="iurievi4/my-private-backups"
    local db_file=""

    if [[ -z "$reg_choice" ]] && [[ -r /dev/tty ]]; then
        echo
        echo "Выберите конфигурацию 3x-ui:"
        echo "  0) Чистая установка [по умолчанию]"
        echo "  1) Латвия  (lv-x-ui.db)"
        echo "  2) Москва  (mw-x-ui.db)"
        echo "  3) Турция  (tr-x-ui.db)"
        echo
        read -rp "Выбор [0-3]: " reg_choice </dev/tty || true
    fi

    reg_choice="${reg_choice:-0}"
    case "$reg_choice" in
        0)
            echo "  [i] Выбрана чистая установка 3x-ui."
            DB_RESTORED=0
            return 0
            ;;
        1) db_file="lv-x-ui.db" ;;
        2) db_file="mw-x-ui.db" ;;
        3) db_file="tr-x-ui.db" ;;
        *)
            echo "❌ Некорректный выбор конфигурации: '${reg_choice}'"
            return 1
            ;;
    esac

    # Минимальные зависимости для скачивания, расшифровки и проверки базы
    for pkg in curl openssl sqlite3 ca-certificates tar; do
        if ! command -v "$pkg" >/dev/null 2>&1; then
            echo ">>> Установка минимальных зависимостей для подготовки базы (${pkg})..."
            apt-get update -qq && apt-get install -y -qq curl openssl sqlite3 ca-certificates tar >/dev/null 2>&1 || true
            break
        fi
    done

    if [[ -z "$token" ]] && [[ -r /dev/tty ]]; then
        read -rsp "Введите GitHub Token (repo access): " token </dev/tty || true
        echo
    fi
    [[ -z "$token" ]] && { echo "❌ GitHub Token не указан. База не будет восстановлена."; return 1; }

    PREPARED_XUI_TMP_DIR="$(mktemp -d /tmp/xui-restore.XXXXXX)"
    chmod 700 "$PREPARED_XUI_TMP_DIR"
    local raw_download="${PREPARED_XUI_TMP_DIR}/${db_file}"
    local extract_dir="${PREPARED_XUI_TMP_DIR}/extract"
    mkdir -p "$extract_dir"

    echo ">>> Скачивание эталонной базы ${db_file} из ${repo}..."
    local http_code
    http_code="$(curl -4 -sS -w "%{http_code}" \
        -H "Authorization: Bearer ${token}" \
        -H "Accept: application/vnd.github.v3.raw, application/vnd.github.raw+json" \
        --connect-timeout 15 --max-time 300 \
        -o "$raw_download" \
        "https://api.github.com/repos/${repo}/contents/${db_file}")"

    if [[ "$http_code" != "200" ]] || [[ ! -s "$raw_download" ]]; then
        echo "❌ Ошибка скачивания базы (HTTP: ${http_code})."
        rm -rf "$PREPARED_XUI_TMP_DIR"
        return 1
    fi
    echo "✓ Файл скачан. Размер: $(du -h "$raw_download" | cut -f1)"

    # Если GitHub API вернул JSON (base64)
    if grep -q '"content":' "$raw_download" 2>/dev/null && grep -q '"encoding":' "$raw_download" 2>/dev/null; then
        if command -v jq >/dev/null 2>&1; then
            jq -r '.content' "$raw_download" | tr -d '\n\r ' | base64 -d > "${raw_download}.tmp" 2>/dev/null && mv -f "${raw_download}.tmp" "$raw_download"
        fi
    fi

    local decrypt_success=0

    # 1. Проверяем, не является ли файл готовой базой данных SQLite
    if sqlite3 "$raw_download" "PRAGMA integrity_check;" 2>/dev/null | grep -qx "ok"; then
        echo "✓ Файл является готовой базой SQLite."
        cp -f "$raw_download" "${extract_dir}/${db_file}"
        decrypt_success=1
    # 2. Проверяем, не является ли файл архивом tar.gz
    elif tar -tzf "$raw_download" >/dev/null 2>&1; then
        echo "✓ Файл является архивом tar.gz."
        tar -xzf "$raw_download" -C "$extract_dir" 2>/dev/null
        decrypt_success=1
    # 3. Файл зашифрован через OpenSSL AES-256-CBC + PBKDF2
    else
        local attempts=0
        while [[ "$attempts" -lt 3 ]]; do
            if [[ -z "$db_pass" ]] && [[ -r /dev/tty ]]; then
                [[ "$attempts" -eq 0 ]] && echo "Введите мастер-пароль базы. Допустимо до 3 попыток."
                read -rsp "Мастер-пароль: " db_pass </dev/tty || true
                echo
            fi

            if [[ -n "$db_pass" ]]; then
                if openssl enc -d -aes-256-cbc -pbkdf2 -in "$raw_download" -pass pass:"$db_pass" 2>/dev/null \
                    | tar -xzf - -C "$extract_dir" 2>/dev/null; then
                    decrypt_success=1
                    break
                elif openssl enc -d -aes-256-cbc -pbkdf2 -in "$raw_download" -out "${extract_dir}/${db_file}" -pass pass:"$db_pass" 2>/dev/null; then
                    if sqlite3 "${extract_dir}/${db_file}" "PRAGMA integrity_check;" 2>/dev/null | grep -qx "ok"; then
                        decrypt_success=1
                        break
                    else
                        rm -f "${extract_dir}/${db_file}"
                    fi
                fi
            fi

            echo "❌ Неверный пароль или повреждённый архив."
            db_pass=""
            attempts=$((attempts + 1))
        done
    fi

    rm -f "$raw_download"
    unset db_pass token

    if [[ "$decrypt_success" -ne 1 ]]; then
        echo "❌ Не удалось расшифровать резервную базу. Будет использована чистая база."
        rm -rf "$PREPARED_XUI_TMP_DIR"
        return 1
    fi

    echo "✓ База успешно распакована/расшифрована."

    local candidate_db
    candidate_db="$(find "$extract_dir" -type f -name "*.db" -print -quit)"

    if [[ -z "$candidate_db" ]] || [[ ! -f "$candidate_db" ]]; then
        echo "❌ Файл базы данных (.db) не найден внутри архива."
        rm -rf "$PREPARED_XUI_TMP_DIR"
        return 1
    fi

    echo "✓ Найдена БД: $(basename "$candidate_db")"

    if ! sqlite3 "$candidate_db" "PRAGMA integrity_check;" 2>/dev/null | grep -qx "ok"; then
        echo "❌ Ошибка integrity_check SQLite."
        rm -rf "$PREPARED_XUI_TMP_DIR"
        return 1
    fi
    echo "✓ SQLite integrity_check: OK"

    local inbounds_cnt users_cnt settings_cnt db_size
    inbounds_cnt="$(sqlite3 "$candidate_db" "SELECT count(*) FROM inbounds;" 2>/dev/null || echo 0)"
    users_cnt="$(sqlite3 "$candidate_db" "SELECT count(*) FROM users;" 2>/dev/null || echo 0)"
    settings_cnt="$(sqlite3 "$candidate_db" "SELECT count(*) FROM settings;" 2>/dev/null || echo 0)"
    db_size="$(du -h "$candidate_db" | cut -f1)"

    echo ">>> Проверка содержимого резервной БД:"
    echo "    Размер БД : ${db_size}"
    echo "    Inbounds  : ${inbounds_cnt}"
    echo "    Users     : ${users_cnt}"
    echo "    Settings  : ${settings_cnt}"

    if [[ "$inbounds_cnt" -lt 1 ]] || [[ "$users_cnt" -lt 1 ]] || [[ "$settings_cnt" -lt 10 ]]; then
        echo "❌ Резервная БД не соответствует структуре (ожидалось inbounds>=1, users>=1, settings>=10)."
        rm -rf "$PREPARED_XUI_TMP_DIR"
        return 1
    fi

    echo "✓ Резервная БД содержит рабочую конфигурацию."
    PREPARED_XUI_DB="$candidate_db"
    return 0
}

install_prepared_database() {
    if [[ -z "${PREPARED_XUI_DB:-}" ]] || [[ ! -f "$PREPARED_XUI_DB" ]]; then
        echo "  [i] Эталонная база не выбиралась. Оставлена чистая конфигурация 3x-ui."
        return 0
    fi

    local target_db="/etc/x-ui/x-ui.db"
    local backup_dir="/root/xui_backups"
    mkdir -p "$backup_dir"
    local prev_backup="${backup_dir}/x-ui-before-restore-$(date +%Y%m%d-%H%M%S).db"

    echo
    echo "======================================================================"
    echo " 🔄 Финальная установка эталонной базы 3x-ui"
    echo "======================================================================"

    echo ">>> Остановка панели 3x-ui..."
    systemctl stop x-ui 2>/dev/null || true

    local wait_sec=0
    while pgrep -f "x-ui" >/dev/null 2>&1 && [[ "$wait_sec" -lt 10 ]]; do
        sleep 0.5
        wait_sec=$((wait_sec + 1))
    done
    echo "✓ x-ui остановлен."

    if [[ -f "$target_db" ]]; then
        cp -f "$target_db" "$prev_backup"
        chmod 600 "$prev_backup"
        echo "✓ Предыдущая БД сохранена: ${prev_backup}"
    fi

    echo ">>> Проверка БД перед заменой..."
    local src_inbounds src_users src_settings
    src_inbounds="$(sqlite3 "$PREPARED_XUI_DB" "SELECT count(*) FROM inbounds;" 2>/dev/null || echo 0)"
    src_users="$(sqlite3 "$PREPARED_XUI_DB" "SELECT count(*) FROM users;" 2>/dev/null || echo 0)"
    src_settings="$(sqlite3 "$PREPARED_XUI_DB" "SELECT count(*) FROM settings;" 2>/dev/null || echo 0)"
    echo "    Inbounds : ${src_inbounds}"
    echo "    Users    : ${src_users}"
    echo "    Settings : ${src_settings}"

    echo ">>> Замена рабочей БД..."
    # Обязательно удаляем старую базу и журналы WAL/SHM
    rm -f "$target_db" "${target_db}-wal" "${target_db}-shm"

    # Копируем проверенную базу
    cp -f "$PREPARED_XUI_DB" "$target_db"
    chmod 644 "$target_db"
    chown root:root "$target_db"
    echo "✓ /etc/x-ui/x-ui.db заменена."

    # Сброс счетчиков трафика
    sqlite3 "$target_db" "UPDATE client_traffics SET up = 0, down = 0, all_time = 0;" 2>/dev/null || true
    sqlite3 "$target_db" "UPDATE inbounds SET up = 0, down = 0;" 2>/dev/null || true
    sqlite3 "$target_db" "DELETE FROM inbound_client_ips;" 2>/dev/null || true

    # Сброс WAL режима для новой базы
    sqlite3 "$target_db" "PRAGMA journal_mode = WAL;" >/dev/null 2>&1 || true
    sqlite3 "$target_db" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true

    # Проверка и линковка путей SSL-сертификатов
    local cert_path key_path
    cert_path="$(sqlite3 "$target_db" "SELECT value FROM settings WHERE key = 'webCertFile';" 2>/dev/null || true)"
    key_path="$(sqlite3 "$target_db" "SELECT value FROM settings WHERE key = 'webKeyFile';" 2>/dev/null || true)"

    if [[ -n "$cert_path" ]] && [[ -n "$key_path" ]]; then
        mkdir -p "$(dirname "$cert_path")" "$(dirname "$key_path")"
        if [[ -f "/root/cert/fullchain.pem" ]]; then
            ln -sf "/root/cert/fullchain.pem" "$cert_path"
        elif [[ -f "/root/cert/xui.crt" ]]; then
            ln -sf "/root/cert/xui.crt" "$cert_path"
        fi
        if [[ -f "/root/cert/privkey.pem" ]]; then
            ln -sf "/root/cert/privkey.pem" "$key_path"
        elif [[ -f "/root/cert/xui.key" ]]; then
            ln -sf "/root/cert/xui.key" "$key_path"
        fi
        # Создание самоподписанного сертификата, если файлы отсутствуют
        if [[ ! -f "$cert_path" || ! -f "$key_path" ]]; then
            openssl req -x509 -newkey rsa:2048 -nodes -sha256 -keyout "$key_path" -out "$cert_path" -days 3650 -subj "/CN=vps" >/dev/null 2>&1 || true
            chmod 600 "$key_path" "$cert_path" 2>/dev/null || true
        fi
    fi

    # Автоматическое открытие портов восстановленных inbounds в UFW
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        while IFS= read -r in_port; do
            if [[ -n "$in_port" ]] && [[ "$in_port" =~ ^[0-9]+$ ]]; then
                ufw allow "${in_port}/tcp" comment "Xray Inbound :${in_port}" >/dev/null 2>&1 || true
            fi
        done < <(sqlite3 "$target_db" "SELECT port FROM inbounds WHERE enable = 1;" 2>/dev/null || true)
        ufw reload >/dev/null 2>&1 || true
    fi

    echo ">>> Проверка установленной БД..."
    local post_inbounds post_users post_settings
    post_inbounds="$(sqlite3 "$target_db" "SELECT count(*) FROM inbounds;" 2>/dev/null || echo 0)"
    post_users="$(sqlite3 "$target_db" "SELECT count(*) FROM users;" 2>/dev/null || echo 0)"
    post_settings="$(sqlite3 "$target_db" "SELECT count(*) FROM settings;" 2>/dev/null || echo 0)"

    echo "    Inbounds : ${post_inbounds}"
    echo "    Users    : ${post_users}"
    echo "    Settings : ${post_settings}"

    if [[ "$post_inbounds" -lt 1 ]] || [[ "$post_users" -lt 1 ]]; then
        echo "❌ После замены рабочая БД оказалась пустой."
        if [[ -f "$prev_backup" ]]; then
            rm -f "$target_db" "${target_db}-wal" "${target_db}-shm"
            cp -f "$prev_backup" "$target_db"
            chmod 644 "$target_db"
            echo "✓ Предыдущая БД восстановлена."
        fi
        systemctl start x-ui 2>/dev/null || true
        return 1
    fi

    echo ">>> Запуск службы 3x-ui..."
    systemctl start x-ui
    sleep 3

    if ! systemctl is-active --quiet x-ui; then
        echo "❌ Ошибка запуска службы 3x-ui. Выполняется откат..."
        systemctl stop x-ui 2>/dev/null || true
        rm -f "$target_db" "${target_db}-wal" "${target_db}-shm"
        if [[ -f "$prev_backup" ]]; then
            cp -f "$prev_backup" "$target_db"
            chmod 644 "$target_db"
        fi
        systemctl start x-ui 2>/dev/null || true
        return 1
    fi

    echo "✓ 3x-ui запущен и активен."
    DB_RESTORED=1

    if [[ -n "${PREPARED_XUI_TMP_DIR:-}" ]] && [[ -d "$PREPARED_XUI_TMP_DIR" ]]; then
        rm -rf "$PREPARED_XUI_TMP_DIR"
    fi

    return 0
}

###############################################################################
# 1.1. ВЫБОР КОМПОНЕНТОВ ДЛЯ УСТАНОВКИ (РУЧНОЙ / АВТОМАТИЧЕСКИЙ РЕЖИМ)
###############################################################################

prompt_yn() {
    local prompt_msg="$1"
    local default_val="${2:-N}"
    local reply=""
    if [[ -r /dev/tty ]]; then
        read -rp "${prompt_msg} [y/N]: " reply </dev/tty || true
        reply="${reply:-$default_val}"
        if [[ "$reply" =~ ^[YyДд]$ ]]; then
            echo "1"
        else
            echo "0"
        fi
    else
        echo "0"
    fi
}

echo "======================================================================"
echo " ⚙️ ВЫБОР КОМПОНЕНТОВ ДЛЯ УСТАНОВКИ"
echo "======================================================================"

# 1. Выбор конфигурации 3x-ui
if [[ -z "${REG_CHOICE}" ]] && [[ -r /dev/tty ]]; then
    echo "Выберите конфигурацию 3x-ui:"
    echo "  0) Чистая установка [по умолчанию]"
    echo "  1) Латвия  (lv-x-ui.db)"
    echo "  2) Москва  (mw-x-ui.db)"
    echo "  3) Турция  (tr-x-ui.db)"
    read -rp "Выбор [0-3]: " REG_CHOICE </dev/tty || true
fi
REG_CHOICE="${REG_CHOICE:-0}"

# Подготовка эталонной базы 3x-ui во временный каталог (без изменения /etc/x-ui/x-ui.db)
prepare_custom_database

# 2. Выбор PostgreSQL
if [[ -z "${INSTALL_POSTGRES}" ]]; then
    if [[ -r /dev/tty ]]; then
        INSTALL_POSTGRES="$(prompt_yn "Устанавливать PostgreSQL?" "N")"
    else
        INSTALL_POSTGRES="0"
    fi
fi

# 3. Выбор MS SQL Server
if [[ -z "${INSTALL_MSSQL}" ]]; then
    if [[ -r /dev/tty ]]; then
        INSTALL_MSSQL="$(prompt_yn "Устанавливать MS SQL Server (Docker)?" "N")"
    else
        INSTALL_MSSQL="0"
    fi
fi

# 4. Выбор TorrServer
if [[ -z "${INSTALL_TORRSERVER}" ]]; then
    if [[ -r /dev/tty ]]; then
        INSTALL_TORRSERVER="$(prompt_yn "Устанавливать TorrServer MatriX?" "N")"
    else
        INSTALL_TORRSERVER="0"
    fi
fi

echo
echo "Выбранные компоненты:"
echo "  - 3x-ui конфигурация : ${REG_CHOICE}"
echo "  - PostgreSQL         : $( [[ "$INSTALL_POSTGRES" == "1" ]] && echo "ДА" || echo "НЕТ" )"
echo "  - MS SQL Server      : $( [[ "$INSTALL_MSSQL" == "1" ]] && echo "ДА" || echo "НЕТ" )"
echo "  - TorrServer         : $( [[ "$INSTALL_TORRSERVER" == "1" ]] && echo "ДА" || echo "НЕТ" )"
echo "======================================================================"
echo


###############################################################################
# 2. УСТАНОВКА ПАКЕТОВ
###############################################################################

echo
echo ">>> Обновление пакетов и установка системных утилит..."
apt-get update
apt-get upgrade -y

apt-get install -y \
    nginx git curl wget gnupg cron iproute2 iputils-ping fail2ban ipset \
    
    iptables ufw socat sqlite3 ca-certificates openssl jq \
    unzip lsof procps net-tools util-linux

systemctl enable --now cron


###############################################################################
# 3. SYSCTL (IPV6, BBR/FQ С ПРОВЕРКОЙ ЯДРА, IP FORWARD)
###############################################################################

echo ">>> Настройка сетевого стека ядра..."

# 3.1. IPv6
if [[ "$DISABLE_IPV6" == "1" ]]; then
    cat > /etc/sysctl.d/99-disable-ipv6.conf <<'EOF_SYSCTL_IPV6'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF_SYSCTL_IPV6
    for iface in /proc/sys/net/ipv6/conf/*; do
        [[ -d "$iface" ]] && sysctl -w "net.ipv6.conf.$(basename "$iface").disable_ipv6=1" >/dev/null 2>&1 || true
    done
    [[ -f /etc/default/ufw ]] && sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw
else
    rm -f /etc/sysctl.d/99-disable-ipv6.conf
    [[ -f /etc/default/ufw ]] && sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
fi

# 3.2. BBR
modprobe tcp_bbr 2>/dev/null || true
BBR_CONFIG="# BBR unavailable in kernel"
if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    BBR_CONFIG="net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr"
    echo "✓ BBR поддерживается ядром и активирован."
else
    echo "ℹ️ BBR не обнаружен в доступных алгоритмах ядра, оставлен системный по умолчанию."
fi

cat > /etc/sysctl.d/99-vps-optimization.conf <<EOF_SYSCTL_OPT
${BBR_CONFIG}
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_syncookies = 1
net.ipv4.ip_forward = ${ENABLE_IP_FORWARD}
vm.swappiness = 10
EOF_SYSCTL_OPT

sysctl --system

if [[ "$DISABLE_IPV6" == "1" ]]; then
    if [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" == "1" ]]; then
        echo "✓ IPv6 успешно отключен."
    fi
fi


###############################################################################
# 4. SWAP (2 GB)
###############################################################################

if ! swapon --show | grep -q .; then
    echo ">>> Создание SWAP 2 GB..."
    if [[ ! -f /swapfile ]]; then
        dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress
        chmod 600 /swapfile
        mkswap /swapfile
    fi
    swapon /swapfile
    if ! grep -qE '^/swapfile\s' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    echo "✓ SWAP активирован."
else
    echo "✓ SWAP уже присутствует в системе."
fi


###############################################################################
# 5. БЕЗОПАСНОСТЬ: UFW -> ПРОВЕРКА -> SSH (ПОРТ 1241)
###############################################################################

echo ">>> Настройка сетевого экрана (UFW)..."

if [[ ! -f "$BOOTSTRAP_MARKER" ]] || [[ "$FORCE_BOOTSTRAP" == "1" ]]; then
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing

    # Открытие портов в UFW ДО смены порта в SSH
    ufw allow "${SSH_PORT}/tcp" comment 'SSH'
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    ufw allow "${XUI_PORT}/tcp" comment 'x-ui panel'

    for port in "${XRAY_PORTS[@]}"; do
        ufw allow "${port}/tcp" comment "x-ui / xray :${port}"
    done

    [[ "$ALLOW_PORT_54325" == "1" ]] && ufw allow 54325/tcp comment 'Service 54325'

    ufw --force enable
    ufw reload
fi

echo ">>> Настройка и проверка службы SSH на порт ${SSH_PORT}..."

SSHD_CONFIG="/etc/ssh/sshd_config"
mkdir -p /etc/ssh/sshd_config.d

sed -i -E 's/^[[:space:]]*Port[[:space:]]+/# Disabled: &/' "$SSHD_CONFIG"
shopt -s nullglob
for file in /etc/ssh/sshd_config.d/*.conf; do
    [[ "$(basename "$file")" == "99-custom-port.conf" ]] && continue
    sed -i -E 's/^[[:space:]]*Port[[:space:]]+/# Disabled: &/' "$file"
done
shopt -u nullglob

cat > /etc/ssh/sshd_config.d/99-custom-port.conf <<EOF_SSH_PORT
Port ${SSH_PORT}
EOF_SSH_PORT
chmod 644 /etc/ssh/sshd_config.d/99-custom-port.conf

systemctl disable --now ssh.socket 2>/dev/null || true
systemctl enable ssh.service

# Создаем каталог разделения привилегий для исключения ошибки в Ubuntu 24.04
mkdir -p /run/sshd
chmod 0755 /run/sshd

sshd -t
systemctl restart ssh
sleep 2

EFFECTIVE_SSH_PORT="$(sshd -T 2>/dev/null | awk '$1 == "port" && p == "" {p = $2} END {print p}' || true)"
if [[ -z "$EFFECTIVE_SSH_PORT" ]] || [[ "$EFFECTIVE_SSH_PORT" != "$SSH_PORT" ]]; then
    if ss -lnt 2>/dev/null | grep -qE ":${SSH_PORT}[[:space:]]"; then
        EFFECTIVE_SSH_PORT="$SSH_PORT"
    fi
fi

if [[ "$EFFECTIVE_SSH_PORT" != "$SSH_PORT" ]]; then
    echo "❌ SSH не применил порт ${SSH_PORT}. Фактический: ${EFFECTIVE_SSH_PORT}"
    exit 1
fi
echo "✓ SSH успешно работает на порту ${SSH_PORT} (UFW предварительно открыт)."

###############################################################################
# 5.1. FAIL2BAN
###############################################################################

echo ">>> Настройка Fail2ban..."
mkdir -p /etc/fail2ban/jail.d

cat > /etc/fail2ban/jail.d/vps-setup.local <<EOF_F2B
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
backend = systemd
maxretry = 3
findtime = 10m
bantime = 24h

[recidive]
enabled = true
logpath = /var/log/fail2ban.log
banaction = %(banaction_allports)s
bantime = 1w
findtime = 1d
maxretry = 3
EOF_F2B
chmod 644 /etc/fail2ban/jail.d/vps-setup.local

systemctl enable --now fail2ban
systemctl restart fail2ban || true


###############################################################################
# 5.2. ANTISCANNER
###############################################################################

echo ">>> Настройка AntiScanner..."
ANTISCAN_URL="https://gist.githubusercontent.com/sngvy/07cee7ac810c9d222fbebddff8c1d1b8/raw/974d3d87f190468e134e9b56f1e0a93c7caa0fcd/blacklist.txt"
ANTISCAN_SET="SCANNERS-BLOCK-V4"
ANTISCAN_SCRIPT="/usr/local/sbin/antiscan-update.sh"
ANTISCAN_SERVICE="/etc/systemd/system/antiscan.service"
ANTISCAN_TIMER="/etc/systemd/system/antiscan.timer"
ANTISCAN_LOG="/var/log/antiscan-update.log"
ANTISCAN_ENV="/etc/default/antiscan"

cat > "$ANTISCAN_ENV" <<EOF_ANTISCAN_ENV
ANTISCAN_URL="$ANTISCAN_URL"
ANTISCAN_SET="$ANTISCAN_SET"
ANTISCAN_LOG="$ANTISCAN_LOG"
EOF_ANTISCAN_ENV
chmod 600 "$ANTISCAN_ENV"

cat > "$ANTISCAN_SCRIPT" <<'EOF_ANTISCAN_SH'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/default/antiscan
URL="$ANTISCAN_URL"
SET_NAME="$ANTISCAN_SET"
TMP_FILE="/run/antiscan-blacklist.txt"
LOG="$ANTISCAN_LOG"
mkdir -p "$(dirname "$LOG")"
exec >> "$LOG" 2>&1
log() { echo "[$(date '+%F %T')] $*"; }
command -v ipset >/dev/null 2>&1 || exit 1
command -v curl >/dev/null 2>&1 || exit 1
command -v iptables >/dev/null 2>&1 || exit 1

if ! ipset list "$SET_NAME" >/dev/null 2>&1; then
    ipset create "$SET_NAME" hash:net maxelem 65536 2>/dev/null || true
fi

if ! iptables -C INPUT -m set --match-set "$SET_NAME" src -j DROP 2>/dev/null; then
    iptables -I INPUT 1 -m set --match-set "$SET_NAME" src -j DROP
fi

if curl -fsSL --retry 3 --connect-timeout 15 -o "$TMP_FILE" "$URL" && [[ -s "$TMP_FILE" ]]; then
    TMP_SET="${SET_NAME}_TMP"
    ipset create "$TMP_SET" hash:net maxelem 65536 2>/dev/null || true
    ipset flush "$TMP_SET"
    while read -r cidr; do
        [[ -z "$cidr" || "$cidr" =~ ^# ]] && continue
        ipset add "$TMP_SET" "$cidr" 2>/dev/null || true
    done < "$TMP_FILE"
    ipset swap "$TMP_SET" "$SET_NAME" 2>/dev/null || true
    ipset destroy "$TMP_SET" 2>/dev/null || true
    rm -f "$TMP_FILE"
    log "AntiScanner: blacklist updated successfully."
fi
EOF_ANTISCAN_SH
chmod 700 "$ANTISCAN_SCRIPT"

cat > "$ANTISCAN_SERVICE" <<EOF_ANTISCAN_SVC
[Unit]
Description=Update AntiScanner Blacklist
After=network.target

[Service]
Type=oneshot
ExecStart=$ANTISCAN_SCRIPT
EOF_ANTISCAN_SVC

cat > "$ANTISCAN_TIMER" <<EOF_ANTISCAN_TMR
[Unit]
Description=Daily update of AntiScanner Blacklist

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF_ANTISCAN_TMR

systemctl daemon-reload
systemctl enable --now antiscan.timer
bash "$ANTISCAN_SCRIPT" 2>/dev/null || true



###############################################################################
# 6. CLOUDFLARE WARP (SOCKS5 127.0.0.1:40000)
###############################################################################

if [[ "$INSTALL_WARP" == "1" ]]; then
    echo ">>> Установка и настройка Cloudflare WARP..."

    install_cloudflare_warp() {
        local keyring="/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg"
        local list_file="/etc/apt/sources.list.d/cloudflare-client.list"
        local repo_codename=""

        case "$OS_ID" in
            ubuntu)
                case "$OS_CODENAME" in
                    noble|jammy|focal) repo_codename="$OS_CODENAME" ;;
                    *) repo_codename="" ;;
                esac
                ;;
            debian)
                case "$OS_CODENAME" in
                    bookworm|bullseye) repo_codename="$OS_CODENAME" ;;
                    *) repo_codename="" ;;
                esac
                ;;
        esac

        if [[ -z "$repo_codename" ]]; then
            echo "⚠️ Репозиторий Cloudflare WARP не поддерживает ${OS_ID} '${OS_CODENAME}'."
            if [[ "$WARP_MANDATORY" == "1" ]]; then
                echo "❌ Ошибка: WARP объявлен обязательным (WARP_MANDATORY=1). Прерывание."
                return 1
            else
                echo "ℹ️ Пропуск установки WARP (WARP_MANDATORY=0)."
                return 0
            fi
        fi

        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o "$keyring"
        echo "deb [signed-by=${keyring}] https://pkg.cloudflareclient.com/ ${repo_codename} main" > "$list_file"

        apt-get update
        if apt-get install -y cloudflare-warp; then
            systemctl enable --now warp-svc
            sleep 3
            warp-cli --accept-tos registration new 2>/dev/null || true
            warp-cli --accept-tos mode proxy
            warp-cli --accept-tos proxy port "$WARP_PROXY_PORT" 2>/dev/null || true
            warp-cli --accept-tos connect
            sleep 3
            echo "✓ Cloudflare WARP настроен в режиме SOCKS5 (127.0.0.1:${WARP_PROXY_PORT})."
        else
            echo "⚠️ Ошибка установки пакета cloudflare-warp."
            [[ "$WARP_MANDATORY" == "1" ]] && return 1 || return 0
        fi
    }

    install_cloudflare_warp
fi


###############################################################################
# 7. NGINX
###############################################################################

echo ">>> Настройка Nginx..."

mkdir -p /var/www/acme/.well-known/acme-challenge
rm -f /etc/nginx/sites-enabled/default

cat > /etc/nginx/sites-available/cloud-node <<EOF_NGINX
server {
    listen 80 default_server;
$( [[ "$DISABLE_IPV6" != "1" ]] && echo "    listen [::]:80 default_server;" )
    server_name _;

    root /var/www/acme;

    location /.well-known/acme-challenge/ {
        allow all;
    }

    location / {
        default_type text/plain;
        return 200 "Cloud Node Active\n";
    }
}
EOF_NGINX

ln -sf /etc/nginx/sites-available/cloud-node /etc/nginx/sites-enabled/cloud-node

nginx -t
systemctl enable nginx
systemctl restart nginx


###############################################################################
# 8. УСТАНОВКА 3X-UI И ЭТАЛОННАЯ БАЗА
###############################################################################

echo
echo "======================================================================"
echo " 📦 Установка 3x-ui"
echo "======================================================================"

NGINX_WAS_ACTIVE=0
if systemctl is-active --quiet nginx; then
    NGINX_WAS_ACTIVE=1
    systemctl stop nginx
fi

restore_nginx_emergency() {
    local exit_code=$?
    [[ "$NGINX_WAS_ACTIVE" -eq 1 ]] && systemctl start nginx || true
    exit "$exit_code"
}
trap restore_nginx_emergency EXIT

TMP_XUI_INSTALL="/tmp/3x-ui-install.sh"
rm -f "$TMP_XUI_INSTALL"
curl -4 -fL --retry 3 --connect-timeout 15 --max-time 300 "$XUI_INSTALL_URL" -o "$TMP_XUI_INSTALL"
chmod 700 "$TMP_XUI_INSTALL"

if ! grep -qi "3x-ui" "$TMP_XUI_INSTALL"; then
    echo "❌ Ошибка: скачанный скрипт 3x-ui не прошёл проверку подлинности."
    rm -f "$TMP_XUI_INSTALL"
    exit 1
fi

export XUI_NONINTERACTIVE=1
export XUI_DB_TYPE="sqlite"
export XUI_SSL_MODE="ip"
export XUI_PANEL_PORT="$XUI_PORT"
export XUI_ACME_HTTP_PORT="$ACME_PORT"

bash "$TMP_XUI_INSTALL"
rm -f "$TMP_XUI_INSTALL"

ACME="/root/.acme.sh/acme.sh"
if [[ -x "$ACME" ]]; then
    "$ACME" --uninstall-cronjob >/dev/null 2>&1 || true
fi


install_prepared_database() {
    if [[ -z "${PREPARED_XUI_DB:-}" ]] || [[ ! -f "$PREPARED_XUI_DB" ]]; then
        echo "  [i] Эталонная база не выбиралась. Оставлена чистая конфигурация 3x-ui."
        return 0
    fi

    local target_db="/etc/x-ui/x-ui.db"
    local backup_dir="/root/xui_backups"
    mkdir -p "$backup_dir"
    local prev_backup="${backup_dir}/x-ui-before-restore-$(date +%Y%m%d-%H%M%S).db"

    echo
    echo "======================================================================"
    echo " 🔄 Финальная установка эталонной базы 3x-ui"
    echo "======================================================================"

    echo ">>> Остановка панели 3x-ui..."
    systemctl stop x-ui 2>/dev/null || true

    local wait_sec=0
    while pgrep -f "x-ui" >/dev/null 2>&1 && [[ "$wait_sec" -lt 10 ]]; do
        sleep 0.5
        wait_sec=$((wait_sec + 1))
    done
    echo "✓ x-ui остановлен."

    if [[ -f "$target_db" ]]; then
        cp -f "$target_db" "$prev_backup"
        chmod 600 "$prev_backup"
        echo "✓ Предыдущая БД сохранена: ${prev_backup}"
    fi

    echo ">>> Проверка БД перед заменой..."
    local src_inbounds src_users src_settings
    src_inbounds="$(sqlite3 "$PREPARED_XUI_DB" "SELECT count(*) FROM inbounds;" 2>/dev/null || echo 0)"
    src_users="$(sqlite3 "$PREPARED_XUI_DB" "SELECT count(*) FROM users;" 2>/dev/null || echo 0)"
    src_settings="$(sqlite3 "$PREPARED_XUI_DB" "SELECT count(*) FROM settings;" 2>/dev/null || echo 0)"
    echo "    Inbounds : ${src_inbounds}"
    echo "    Users    : ${src_users}"
    echo "    Settings : ${src_settings}"

    echo ">>> Замена рабочей БД..."
    # Обязательно удаляем старую базу и журналы WAL/SHM
    rm -f "$target_db" "${target_db}-wal" "${target_db}-shm"

    # Копируем проверенную базу
    cp -f "$PREPARED_XUI_DB" "$target_db"
    chmod 644 "$target_db"
    chown root:root "$target_db"
    echo "✓ /etc/x-ui/x-ui.db заменена."

    # Сброс счетчиков трафика
    sqlite3 "$target_db" "UPDATE client_traffics SET up = 0, down = 0, all_time = 0;" 2>/dev/null || true
    sqlite3 "$target_db" "UPDATE inbounds SET up = 0, down = 0;" 2>/dev/null || true
    sqlite3 "$target_db" "DELETE FROM inbound_client_ips;" 2>/dev/null || true

    # Сброс WAL режима для новой базы
    sqlite3 "$target_db" "PRAGMA journal_mode = WAL;" >/dev/null 2>&1 || true
    sqlite3 "$target_db" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true

    # Проверка и линковка путей SSL-сертификатов
    local cert_path key_path
    cert_path="$(sqlite3 "$target_db" "SELECT value FROM settings WHERE key = 'webCertFile';" 2>/dev/null || true)"
    key_path="$(sqlite3 "$target_db" "SELECT value FROM settings WHERE key = 'webKeyFile';" 2>/dev/null || true)"

    if [[ -n "$cert_path" ]] && [[ ! -f "$cert_path" ]]; then
        mkdir -p "$(dirname "$cert_path")"
        if [[ -f "/root/cert/fullchain.pem" ]]; then
            ln -sf "/root/cert/fullchain.pem" "$cert_path"
        elif [[ -f "/root/cert/xui.crt" ]]; then
            ln -sf "/root/cert/xui.crt" "$cert_path"
        fi
    fi

    if [[ -n "$key_path" ]] && [[ ! -f "$key_path" ]]; then
        mkdir -p "$(dirname "$key_path")"
        if [[ -f "/root/cert/privkey.pem" ]]; then
            ln -sf "/root/cert/privkey.pem" "$key_path"
        elif [[ -f "/root/cert/xui.key" ]]; then
            ln -sf "/root/cert/xui.key" "$key_path"
        fi
    fi

    echo ">>> Проверка установленной БД..."
    local post_inbounds post_users post_settings
    post_inbounds="$(sqlite3 "$target_db" "SELECT count(*) FROM inbounds;" 2>/dev/null || echo 0)"
    post_users="$(sqlite3 "$target_db" "SELECT count(*) FROM users;" 2>/dev/null || echo 0)"
    post_settings="$(sqlite3 "$target_db" "SELECT count(*) FROM settings;" 2>/dev/null || echo 0)"

    echo "    Inbounds : ${post_inbounds}"
    echo "    Users    : ${post_users}"
    echo "    Settings : ${post_settings}"

    if [[ "$post_inbounds" -ne 3 ]] || [[ "$post_users" -lt 1 ]]; then
        echo "❌ После замены рабочая БД оказалась пустой."
        if [[ -f "$prev_backup" ]]; then
            rm -f "$target_db" "${target_db}-wal" "${target_db}-shm"
            cp -f "$prev_backup" "$target_db"
            chmod 644 "$target_db"
            echo "✓ Предыдущая БД восстановлена."
        fi
        systemctl start x-ui 2>/dev/null || true
        return 1
    fi

    echo ">>> Запуск службы 3x-ui..."
    systemctl start x-ui
    sleep 3

    if ! systemctl is-active --quiet x-ui; then
        echo "❌ Ошибка запуска службы 3x-ui. Выполняется откат..."
        systemctl stop x-ui 2>/dev/null || true
        rm -f "$target_db" "${target_db}-wal" "${target_db}-shm"
        cp -f "$prev_backup" "$target_db"
        chmod 644 "$target_db"
        systemctl start x-ui
        return 1
    fi

    echo "✓ 3x-ui запущен и активен."
    DB_RESTORED=1

    if [[ -n "${PREPARED_XUI_TMP_DIR:-}" ]] && [[ -d "$PREPARED_XUI_TMP_DIR" ]]; then
        rm -rf "$PREPARED_XUI_TMP_DIR"
    fi

    return 0
}

mkdir -p /usr/local/x-ui/bin "$BACKUP_DIR" "$PRE_UPDATE_DIR"
chmod 700 "$BACKUP_DIR" "$PRE_UPDATE_DIR"


###############################################################################
# 9. СЛУЖБЫ ОБСЛУЖИВАНИЯ
###############################################################################

# 9.1. BACKUP
cat > /usr/local/sbin/xui-backup.sh <<'EOF_XUI_BACKUP'
#!/usr/bin/env bash

set -Eeuo pipefail
BACKUP_DIR="/root/xui_backups"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

DATE="$(date '+%Y-%m-%d_%H-%M-%S')"
BACKUP_FILE="${BACKUP_DIR}/x-ui_${DATE}.tar.gz"
TMP_FILE="${BACKUP_FILE}.tmp"

SOURCE_LIST=()
[[ -d /etc/x-ui ]] && SOURCE_LIST+=("etc/x-ui")
[[ -d /usr/local/x-ui ]] && SOURCE_LIST+=("usr/local/x-ui")
[[ -f /usr/bin/x-ui ]] && SOURCE_LIST+=("usr/bin/x-ui")
[[ -f /etc/systemd/system/x-ui.service ]] && SOURCE_LIST+=("etc/systemd/system/x-ui.service")
[[ -f /etc/default/x-ui ]] && SOURCE_LIST+=("etc/default/x-ui")
[[ -d /root/cert ]] && SOURCE_LIST+=("root/cert")
[[ -d /root/.acme.sh ]] && SOURCE_LIST+=("root/.acme.sh")

[[ "${#SOURCE_LIST[@]}" -eq 0 ]] && exit 0

tar -czf "$TMP_FILE" -C / "${SOURCE_LIST[@]}"

if ! tar -tzf "$TMP_FILE" >/dev/null 2>&1; then
    echo "ERROR: Backup archive verification failed!"
    rm -f "$TMP_FILE"
    exit 1
fi

mv "$TMP_FILE" "$BACKUP_FILE"
chmod 600 "$BACKUP_FILE"
find "$BACKUP_DIR" -type f -name 'x-ui_*.tar.gz' -mtime +14 -delete
echo "Backup created and verified: $BACKUP_FILE"
EOF_XUI_BACKUP
chmod 700 /usr/local/sbin/xui-backup.sh


# 9.2. HEALTHCHECK С ЗАЩИТОЙ ОТ RESTART-LOOP
cat > /usr/local/sbin/xui-health.sh <<'EOF_HEALTH'
#!/usr/bin/env bash

set -u
LOG="/var/log/xui-health.log"
SERVICE="x-ui"
RESTART_TRACK_FILE="/run/xui-restarts.log"
MAX_RESTARTS_PER_HOUR=3

need_restart=0
reason=""

if ! systemctl is-active --quiet "$SERVICE"; then
    need_restart=1
    reason="служба x-ui не активна"
elif ! pgrep -af 'xray' >/dev/null 2>&1; then
    need_restart=1
    reason="процесс xray не найден"
else
    # Проверяем порты входящих соединений только если они настроены в базе 3x-ui
    CHECK_PORTS=()
    if [[ -f /etc/x-ui/x-ui.db ]] && command -v sqlite3 >/dev/null 2>&1; then
        while IFS= read -r p; do
            [[ -n "$p" ]] && CHECK_PORTS+=("$p")
        done < <(sqlite3 /etc/x-ui/x-ui.db "SELECT port FROM inbounds WHERE enable = 1;" 2>/dev/null || true)
    fi

    for port in "${CHECK_PORTS[@]}"; do
        if ! ss -lnt 2>/dev/null | grep -qE ":${port}[[:space:]]"; then
            need_restart=1
            reason="порт ${port} не слушается"
            break
        fi
    done
fi

check_restart_limit() {
    local now
    now="$(date +%s)"
    local one_hour_ago=$((now - 3600))
    local recent_restarts=0
    local filtered_lines=()

    if [[ -f "$RESTART_TRACK_FILE" ]]; then
        while read -r ts; do
            if [[ "$ts" =~ ^[0-9]+$ ]] && [[ "$ts" -ge "$one_hour_ago" ]]; then
                recent_restarts=$((recent_restarts + 1))
                filtered_lines+=("$ts")
            fi
        done < "$RESTART_TRACK_FILE"
    fi

    if [[ "$recent_restarts" -ge "$MAX_RESTARTS_PER_HOUR" ]]; then
        return 1
    fi

    filtered_lines+=("$now")
    printf "%s\n" "${filtered_lines[@]}" > "$RESTART_TRACK_FILE"
    return 0
}

if [[ "$need_restart" -eq 1 ]]; then
    if ! check_restart_limit; then
        echo "$(date '+%F %T') [RESTART-LOOP BLOCKED] Превышен лимит (${MAX_RESTARTS_PER_HOUR}/час). Перезапуск отменен. Требуется ручная проверка!" >> "$LOG"
        logger -t xui-health "Restart loop detected. Skipping automatic restart."
        exit 0
    fi

    echo "$(date '+%F %T') [RESTART] Причина: ${reason}" >> "$LOG"
    logger -t xui-health "x-ui restart. Reason: ${reason}"
    systemctl restart "$SERVICE"
    sleep 5
    if systemctl is-active --quiet "$SERVICE"; then
        echo "$(date '+%F %T') [OK] x-ui восстановлен" >> "$LOG"
    else
        echo "$(date '+%F %T') [FAIL] x-ui не восстановился" >> "$LOG"
    fi
else
    echo "$(date '+%F %T') [OK] x-ui + Xray (порты: ${CHECK_PORTS[*]:-нет активных})" >> "$LOG"
fi
EOF_HEALTH
chmod 700 /usr/local/sbin/xui-health.sh
touch /var/log/xui-health.log && chmod 600 /var/log/xui-health.log


# 9.3. БЕЗОПАСНЫЙ UPDATER 3X-UI С ROLLBACK ЧЕРЕЗ .BAK
cat > /usr/local/sbin/xui-update-safe.sh <<'EOF_UPDATER'
#!/usr/bin/env bash

set -Eeuo pipefail
LOG="/var/log/xui-auto-update.log"
MAINTENANCE_LOCK="/run/lock/vps-maintenance.lock"
BACKUP_DIR="/root/xui_backups"
PRE_UPDATE_DIR="${BACKUP_DIR}/pre-update"
UPDATE_URL="${XUI_UPDATE_URL:-https://raw.githubusercontent.com/MHSanaei/3x-ui/main/update.sh}"
XUI_PORT="${XUI_PORT:-8784}"

exec >> "$LOG" 2>&1
mkdir -p "$PRE_UPDATE_DIR"

exec 9>"$MAINTENANCE_LOCK"
if ! flock -n 9; then
    echo "[$(date '+%F %T')] Update skipped: maintenance lock active."
    exit 0
fi

log() { echo "[$(date '+%F %T')] $*"; }

health_check() {
    sleep 10
    systemctl is-active --quiet x-ui || return 1
    ss -lnt 2>/dev/null | grep -qE ":${XUI_PORT}[[:space:]]" || return 1
    pgrep -af 'xray' >/dev/null 2>&1 || return 1
    local check_ports=()
    if [[ -f /etc/x-ui/x-ui.db ]] && command -v sqlite3 >/dev/null 2>&1; then
        while IFS= read -r p; do
            [[ -n "$p" ]] && check_ports+=("$p")
        done < <(sqlite3 /etc/x-ui/x-ui.db "SELECT port FROM inbounds WHERE enable = 1;" 2>/dev/null || true)
    fi
    for port in "${check_ports[@]}"; do
        ss -lnt 2>/dev/null | grep -qE ":${port}[[:space:]]" || return 1
    done
    return 0
}

create_snapshot() {
    local label="$1"
    local dir="${PRE_UPDATE_DIR}/${label}"
    local archive="${dir}/x-ui-state.tar.gz"
    local tmp_archive="${archive}.tmp"

    mkdir -p "$dir"
    local source_list=()
    [[ -d /etc/x-ui ]] && source_list+=("etc/x-ui")
    [[ -d /usr/local/x-ui ]] && source_list+=("usr/local/x-ui")
    [[ -f /usr/bin/x-ui ]] && source_list+=("usr/bin/x-ui")
    [[ -f /etc/systemd/system/x-ui.service ]] && source_list+=("etc/systemd/system/x-ui.service")
    [[ -f /etc/default/x-ui ]] && source_list+=("etc/default/x-ui")
    [[ -d /root/cert ]] && source_list+=("root/cert")

    [[ "${#source_list[@]}" -eq 0 ]] && return 1

    tar -czf "$tmp_archive" -C / "${source_list[@]}"
    if ! tar -tzf "$tmp_archive" >/dev/null 2>&1; then
        rm -f "$tmp_archive"
        return 1
    fi
    mv "$tmp_archive" "$archive"
    chmod 600 "$archive"
    echo "$archive"
}

restore_snapshot() {
    local archive="$1"
    [[ ! -f "$archive" ]] && return 1

    if ! tar -tzf "$archive" >/dev/null 2>&1; then
        log "CRITICAL: Corrupted rollback archive. Aborting."
        return 1
    fi

    log "Stopping x-ui..."
    systemctl stop x-ui 2>/dev/null || true

    local bak_suffix="rollback-bak-$(date +%s)"
    [[ -d /etc/x-ui ]] && mv /etc/x-ui "/etc/x-ui.${bak_suffix}"
    [[ -d /usr/local/x-ui ]] && mv /usr/local/x-ui "/usr/local/x-ui.${bak_suffix}"
    [[ -d /root/cert ]] && mv /root/cert "/root/cert.${bak_suffix}"

    if tar -xzf "$archive" -C /; then
        systemctl daemon-reload
        systemctl enable x-ui >/dev/null 2>&1 || true
        systemctl start x-ui

        if health_check; then
            log "Rollback verified. Removing temp backup..."
            rm -rf "/etc/x-ui.${bak_suffix}" "/usr/local/x-ui.${bak_suffix}" "/root/cert.${bak_suffix}"
            return 0
        fi
    fi

    log "Reverting from temp backup..."
    systemctl stop x-ui 2>/dev/null || true
    rm -rf /etc/x-ui /usr/local/x-ui /root/cert
    [[ -d "/etc/x-ui.${bak_suffix}" ]] && mv "/etc/x-ui.${bak_suffix}" /etc/x-ui
    [[ -d "/usr/local/x-ui.${bak_suffix}" ]] && mv "/usr/local/x-ui.${bak_suffix}" /usr/local/x-ui
    [[ -d "/root/cert.${bak_suffix}" ]] && mv "/root/cert.${bak_suffix}" /root/cert
    systemctl daemon-reload
    systemctl start x-ui 2>/dev/null || true
    return 1
}

main() {
    systemctl is-active --quiet x-ui || exit 1
    local pre_archive
    pre_archive="$(create_snapshot "current")"
    [[ ! -f "$pre_archive" ]] && exit 1

    local tmp_update="/tmp/xui-update.sh"
    rm -f "$tmp_update"
    if ! curl -4 -fL --retry 3 --connect-timeout 15 --max-time 300 "$UPDATE_URL" -o "$tmp_update"; then
        rm -f "$tmp_update"
        exit 1
    fi

    if ! grep -qi "3x-ui" "$tmp_update"; then
        log "ERROR: downloaded script failed sanity check."
        rm -f "$tmp_update"
        exit 1
    fi
    chmod 700 "$tmp_update"

    if ! bash "$tmp_update"; then
        rm -f "$tmp_update"
        restore_snapshot "$pre_archive" && exit 0
        exit 1
    fi
    rm -f "$tmp_update"

    health_check && exit 0

    log "Healthcheck failed. Initiating rollback..."
    create_snapshot "failed-$(date '+%Y%m%d-%H%M%S')" 2>/dev/null || true
    restore_snapshot "$pre_archive" && exit 0
    exit 1
}

main "$@"
EOF_UPDATER
chmod 700 /usr/local/sbin/xui-update-safe.sh
touch /var/log/xui-auto-update.log && chmod 600 /var/log/xui-auto-update.log


# 9.4. ОБНОВЛЕНИЕ APT
cat > /usr/local/sbin/system-update.sh <<'EOF_SYS_UPDATE'
#!/usr/bin/env bash

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
LOG="/var/log/vps-system-update.log"
MAINTENANCE_LOCK="/run/lock/vps-maintenance.lock"

exec >> "$LOG" 2>&1

exec 9>"$MAINTENANCE_LOCK"
if ! flock -n 9; then
    echo "[$(date '+%F %T')] System update skipped: maintenance lock active."
    exit 0
fi

echo "[$(date '+%F %T')] Starting scheduled system update..."
apt-get update
apt-get upgrade -y
apt-get autoremove -y
apt-get autoclean

if [[ -f /var/run/reboot-required ]]; then
    echo "[$(date '+%F %T')] Reboot required! Scheduling graceful reboot in 2 minutes..."
    logger -t system-update "Reboot required after updates. Rebooting..."
    /sbin/shutdown -r +2 "Scheduled maintenance reboot after package updates"
else
    echo "[$(date '+%F %T')] Update complete. Reboot not required."
fi
EOF_SYS_UPDATE
chmod 700 /usr/local/sbin/system-update.sh


# 9.5. ГЕО-БАЗЫ И SSL
cat > /usr/local/sbin/update-geo.sh <<'EOF_GEO'
#!/usr/bin/env bash

set -u
LOG="/var/log/xui-geo-update.log"
MAINTENANCE_LOCK="/run/lock/vps-maintenance.lock"
TARGET_DIR="/usr/local/x-ui/bin"

exec >> "$LOG" 2>&1
exec 9>"$MAINTENANCE_LOCK"
if ! flock -n 9; then
    exit 0
fi

mkdir -p "$TARGET_DIR"

update_file() {
    local url="$1"
    local dest="$2"
    local tmp="${dest}.tmp"
    if curl -fsSL --retry 3 --connect-timeout 15 -o "$tmp" "$url" && [[ -s "$tmp" ]]; then
        mv -f "$tmp" "$dest"
        echo "$(date '+%F %T') OK: $(basename "$dest")"
    else
        rm -f "$tmp"
        echo "$(date '+%F %T') ERROR: $(basename "$dest")"
    fi
}

update_file "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat" "${TARGET_DIR}/geosite.dat"
update_file "https://github.com/v2fly/geoip/releases/latest/download/geoip.dat" "${TARGET_DIR}/geoip.dat"
update_file "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/geosite.dat" "${TARGET_DIR}/geosite_RU.dat"

command -v x-ui >/dev/null 2>&1 && x-ui update-all-geofiles >/dev/null 2>&1 || true
EOF_GEO
chmod 700 /usr/local/sbin/update-geo.sh

cat > /usr/local/bin/renew-ssl.sh <<'EOF_SSL'
#!/usr/bin/env bash
set -Eeuo pipefail
LOG="/var/log/acme-renew.log"
ACME="/root/.acme.sh/acme.sh"
NGINX_WAS_ACTIVE=0
exec >> "$LOG" 2>&1

if systemctl is-active --quiet nginx; then
    NGINX_WAS_ACTIVE=1
    systemctl stop nginx
fi

cleanup() {
    local exit_code=$?
    [[ "$NGINX_WAS_ACTIVE" -eq 1 ]] && systemctl start nginx || true
    exit "$exit_code"
}
trap cleanup EXIT

if [[ -x "$ACME" ]]; then
    "$ACME" --cron --home "/root/.acme.sh"
fi
EOF_SSL
chmod 700 /usr/local/bin/renew-ssl.sh


# Восстанавливаем Nginx
systemctl enable nginx
nginx -t
systemctl start nginx
trap - EXIT

###############################################################################
# 8.5. УСТАНОВКА ДОПОЛНИТЕЛЬНЫХ КОМПОНЕНТОВ (POSTGRESQL, MSSQL, TORRSERVER)
###############################################################################

install_additional_components() {
    # 1. PostgreSQL
    if [[ "${INSTALL_POSTGRES:-0}" == "1" ]]; then
        echo
        echo ">>> Установка и настройка PostgreSQL..."
        apt-get install -y postgresql postgresql-contrib
        systemctl enable --now postgresql
        sleep 2
        if pg_isready >/dev/null 2>&1; then
            echo "✓ PostgreSQL успешно установлен и запущен."
        else
            echo "⚠️ PostgreSQL установлен, но служба ожидает готовности."
        fi
    fi

    # 2. MS SQL Server в Docker
    if [[ "${INSTALL_MSSQL:-0}" == "1" ]]; then
        echo
        echo ">>> Установка и запуск MS SQL Server 2022 в Docker..."
        if ! command -v docker >/dev/null 2>&1; then
            echo "  [i] Установка Docker..."
            apt-get install -y docker.io
            systemctl enable --now docker
        fi

        mkdir -p "$(dirname "$MSSQL_SA_PASSWORD_FILE")"
        if [[ ! -f "$MSSQL_SA_PASSWORD_FILE" ]]; then
            local gen_pass="Sql_$(openssl rand -hex 8)!Pass"
            printf "%s" "$gen_pass" > "$MSSQL_SA_PASSWORD_FILE"
            chmod 600 "$MSSQL_SA_PASSWORD_FILE"
        fi
        local sa_pass
        sa_pass="$(<"$MSSQL_SA_PASSWORD_FILE")"

        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Eq "^mssql_server$"; then
            echo "  [i] Перезапуск контейнера mssql_server..."
            docker rm -f mssql_server >/dev/null 2>&1 || true
        fi

        echo "  [i] Запуск mssql_server (порт 1433)..."
        docker run -d             --name mssql_server             --restart always             -e "ACCEPT_EULA=Y"             -e "MSSQL_SA_PASSWORD=${sa_pass}"             -p 1433:1433             mcr.microsoft.com/mssql/server:2022-latest

        ufw allow 1433/tcp comment 'MS SQL Server' || true
        echo "✓ MS SQL Server запущен в Docker (порт 1433)."
        echo "  Пароль SA сохранен в: ${MSSQL_SA_PASSWORD_FILE}"
    fi

    # 3. TorrServer MatriX
    if [[ "${INSTALL_TORRSERVER:-0}" == "1" ]]; then
        echo
        echo ">>> Установка и запуск TorrServer MatriX..."
        local ts_arch="amd64"
        case "$ARCH" in
            amd64|x86_64) ts_arch="amd64" ;;
            arm64|aarch64) ts_arch="arm64" ;;
        esac

        mkdir -p /opt/torrserver
        local ts_url="https://github.com/YouROK/TorrServer/releases/latest/download/TorrServer-linux-${ts_arch}"
        if curl -fsSL --connect-timeout 15 --max-time 180 -o /usr/local/bin/TorrServer "$ts_url"; then
            chmod +x /usr/local/bin/TorrServer

            cat > /etc/systemd/system/torrserver.service <<'EOF_TS'
[Unit]
Description=TorrServer MatriX
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/torrserver
ExecStart=/usr/local/bin/TorrServer -d /opt/torrserver -p 8090
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_TS

            systemctl daemon-reload
            systemctl enable --now torrserver
            ufw allow 8090/tcp comment 'TorrServer' || true
            sleep 2
            if systemctl is-active --quiet torrserver; then
                echo "✓ TorrServer успешно установлен и запущен на порту 8090."
            else
                echo "⚠️ TorrServer установлен, но сервис не запустился."
            fi
        else
            echo "❌ Ошибка скачивания TorrServer с GitHub."
        fi
    fi
}

install_additional_components


###############################################################################
# 10. CRON ПЛАНИРОВЩИК (/etc/cron.d/vps-maintenance)
###############################################################################

echo ">>> Настройка расписания обслуживания..."

cat > "$MAINTENANCE_FILE" <<'EOF_CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 1. SSL ACME (ежедневно)
16 10 * * * root /usr/local/bin/renew-ssl.sh

# 2. Бэкап x-ui (ежедневно)
0 3 * * * root /usr/local/sbin/xui-backup.sh

# 3. Обновление APT с умным ребутом (среда 03:30)
30 3 * * 3 root /usr/local/sbin/system-update.sh

# 4. Обновление 3x-ui с rollback (пятница 04:30)
30 4 * * 5 root /usr/local/sbin/xui-update-safe.sh

# 5. Гео-базы v2fly / runetfreedom (понедельник 05:00)
0 5 * * 1 root /usr/local/sbin/update-geo.sh

# 6. Мониторинг healthcheck с анти-лупом (каждые 30 мин)
*/30 * * * * root /usr/local/sbin/xui-health.sh

# 7. Ротация журналов journalctl (суббота 04:15)
15 4 * * 6 root /usr/bin/journalctl --vacuum-time=7d --vacuum-size=200M > /dev/null 2>&1
EOF_CRON

chmod 644 "$MAINTENANCE_FILE"
systemctl restart cron


###############################################################################
# 11. КОМПАКТНЫЙ ЭКСПЛУАТАЦИОННЫЙ MOTD
###############################################################################

echo ">>> Установка чистого эксплуатационного MOTD..."

# 11.1. Отключаем вообще все скрипты в каталоге MOTD
chmod -x /etc/update-motd.d/* 2>/dev/null || true

# 11.2. Отключаем службу новостей и рекламы Ubuntu Pro
if [[ -f /etc/default/motd-news ]]; then
    sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news
fi
systemctl disable --now motd-news.timer 2>/dev/null || true

# 11.3. Очищаем динамический кэш старого баннера
> /run/motd.dynamic 2>/dev/null || true

# 11.4. Генерация безопасного пароля MSSQL без хардкода
if [[ ! -f "$MSSQL_SA_PASSWORD_FILE" ]]; then
    ( umask 077; openssl rand -base64 24 > "$MSSQL_SA_PASSWORD_FILE" )
    chmod 600 "$MSSQL_SA_PASSWORD_FILE"
fi

cat > /etc/update-motd.d/99-custom-sysinfo <<'EOF_MOTD'
#!/bin/bash

# --- Цветовая палитра ---
NONE='\033[0m'
GREEN_B='\033[1;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED_B='\033[1;31m'
PURPLE='\033[0;35m'

# --- Uptime ---
UPTIME=$(uptime -p 2>/dev/null | sed 's/up //' || uptime)

# --- Сетевые соединения ---
CONN_ESTAB=$(ss -tun -a 2>/dev/null | awk '/ESTAB/ {c++} END {print c+0}')
CONN_TOTAL=$(ss -tun -a 2>/dev/null | awk 'NR>1 {c++} END {print c+0}')

# --- Память ---
MEM_TOTAL=$(free -m 2>/dev/null | awk '/Mem:/ {print $2}')
MEM_USED=$(free -m 2>/dev/null | awk '/Mem:/ {print $3}')
[ -n "$MEM_TOTAL" ] && [ "$MEM_TOTAL" -gt 0 ] && MEM_PCT=$((MEM_USED * 100 / MEM_TOTAL)) || MEM_PCT=0

# --- Swap ---
SWAP_TOTAL=$(free -m 2>/dev/null | awk '/Swap:/ {print $2}')
SWAP_USED=$(free -m 2>/dev/null | awk '/Swap:/ {print $3}')
[ -n "$SWAP_TOTAL" ] && [ "$SWAP_TOTAL" -gt 0 ] && SWAP_PCT=$((SWAP_USED * 100 / SWAP_TOTAL)) || SWAP_PCT=0

# --- Диск ---
DISK_TOTAL=$(df -h / 2>/dev/null | awk 'NR==2 {print $2}')
DISK_USED=$(df -h / 2>/dev/null | awk 'NR==2 {print $3}')
DISK_PCT=$(df -h / 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')

# --- IP с быстрым кэшированием ---
IP_LOCAL=$(hostname -I 2>/dev/null | awk '{print $1}')
IP_CACHE="/tmp/pub_ip_cache"

update_pub_ip() {
    local temp_ip
    temp_ip=$(curl -s --connect-timeout 2 https://api.ipify.org 2>/dev/null)
    if [[ "$temp_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$temp_ip" > "$IP_CACHE"
    fi
}

if [ ! -s "$IP_CACHE" ]; then
    update_pub_ip
elif [ $(find "$IP_CACHE" -mmin +60 2>/dev/null) ]; then
    update_pub_ip &
fi

IP_PUB=$(cat "$IP_CACHE" 2>/dev/null || echo "Ожидание...")
[[ "$IP_PUB" == *"<html"* ]] && IP_PUB="N/A"

# --- SSH-сессии, Cron-задачи, APT ---
SSH_CONN=$(ss -t 2>/dev/null | awk '/ssh/ {c++} END {print c+0}')
CRON_COUNT=$(grep -cE '^[0-9*@]' /etc/cron.d/vps-maintenance 2>/dev/null || echo 0)
UPDATES=$(apt list --upgradable 2>/dev/null | wc -l || echo 0)

# --- Docker ---
DOCKER_COUNT=$(docker ps -q 2>/dev/null | wc -l || echo 0)
DOCKER_LIST=$(docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true)

# --- Статусы служб ---
check_service() {
    if systemctl is-active --quiet "$1" 2>/dev/null; then
        echo -e "${GREEN_B}RUNNING${NONE}"
    else
        echo -e "${RED_B}STOPPED${NONE}"
    fi
}

STATUS_XUI=$(check_service x-ui)
STATUS_NGINX=$(check_service nginx)

# WARP (локальная проверка сокета :40000)
if ss -lnt 2>/dev/null | grep -qE ":40000[[:space:]]"; then
    STATUS_WARP="${GREEN_B}RUNNING (SOCKS5 :40000)${NONE}"
elif systemctl is-active --quiet warp-svc 2>/dev/null; then
    STATUS_WARP="${YELLOW}CONNECTING (warp-svc)${NONE}"
else
    STATUS_WARP="${RED_B}STOPPED${NONE}"
fi

STATUS_POSTGRES=$(pg_isready >/dev/null 2>&1 && echo -e "${GREEN_B}RUNNING${NONE}" || echo -e "${RED_B}STOPPED${NONE}")
STATUS_TORRSERVER=$(check_service torrserver)

# Проверка MS SQL через безопасный файл пароля
MSSQL_SA_PASSWORD_FILE="/root/.mssql-sa-password"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -Eq "^mssql_server$"; then
    if [[ -r "$MSSQL_SA_PASSWORD_FILE" ]]; then
        MSSQL_SA_PASSWORD="$(<"$MSSQL_SA_PASSWORD_FILE")"
        if docker exec mssql_server /opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P "$MSSQL_SA_PASSWORD" -C -Q "SELECT 1" >/dev/null 2>&1; then
            STATUS_MSSQL="${GREEN_B}RUNNING${NONE}"
        else
            STATUS_MSSQL="${YELLOW}STARTING/ERROR${NONE}"
        fi
    else
        STATUS_MSSQL="${YELLOW}PASSWORD FILE MISSING${NONE}"
    fi
else
    STATUS_MSSQL="${RED_B}STOPPED${NONE}"
fi

# Проверка Amnezia VPN в Docker
if docker ps --format '{{.Names}}' 2>/dev/null | grep -Eq "^amnezia-"; then
    STATUS_AMNEZIA="${GREEN_B}RUNNING (Docker)${NONE}"
else
    STATUS_AMNEZIA="${RED_B}STOPPED${NONE}"
fi

# --- Вывод ---
echo -e "${CYAN}┌────────────────────────────────────────────────────────────────────────┐${NONE}"
echo -e "  ${GREEN_B}СЕРВЕР ПОДКЛЮЧЕН СТАБИЛЬНО${NONE}"
echo -e "  Uptime: $UPTIME"
echo -e "${CYAN}├────────────────────────────────────────────────────────────────────────┤${NONE}"

echo -e "  ${PURPLE}МЕТРИКИ СИСТЕМЫ:${NONE}"
printf "    %-24s : %s (Pub: %s)\n" "IPv4 адреса" "$IP_LOCAL" "$IP_PUB"
printf "    %-24s : %sMB / %sMB (%s%%)\n" "Оперативная память" "$MEM_USED" "$MEM_TOTAL" "$MEM_PCT"
printf "    %-24s : %sMB / %sMB (%s%%)\n" "Swap" "$SWAP_USED" "$SWAP_TOTAL" "$SWAP_PCT"
printf "    %-24s : %s / %s (%s%%)\n" "Диск (/)" "$DISK_USED" "$DISK_TOTAL" "$DISK_PCT"
printf "    %-24s : %s (Всего: %s)\n" "Активные соединения" "$CONN_ESTAB" "$CONN_TOTAL"
printf "    %-24s : %s\n" "SSH-сессии" "$SSH_CONN"
printf "    %-24s : %s\n" "Задачи обслуживания" "$CRON_COUNT"
printf "    %-24s : %s\n" "Обновления APT" "$UPDATES"

echo -e "${CYAN}├────────────────────────────────────────────────────────────────────────┤${NONE}"
echo -e "  ${PURPLE}СТАТУС СЛУЖБ:${NONE}"
printf "    %-24s : %b\n" "3x-ui / Xray" "$STATUS_XUI"
printf "    %-24s : %b\n" "Nginx" "$STATUS_NGINX"
printf "    %-24s : %b\n" "Cloudflare WARP" "$STATUS_WARP"
printf "    %-24s : %b\n" "PostgreSQL" "$STATUS_POSTGRES"
printf "    %-24s : %b\n" "MS SQL Server" "$STATUS_MSSQL"
printf "    %-24s : %b\n" "TorrServer" "$STATUS_TORRSERVER"
printf "    %-24s : %b\n" "Amnezia VPN" "$STATUS_AMNEZIA"

echo -e "${CYAN}├────────────────────────────────────────────────────────────────────────┤${NONE}"
echo -e "  ${PURPLE}DOCKER:${NONE}"
printf "    %-24s : %s\n" "Активные контейнеры" "$DOCKER_COUNT"
if [[ -n "$DOCKER_LIST" ]]; then
    echo "$DOCKER_LIST"
else
    echo -e "    ${YELLOW}Нет активных контейнеров${NONE}"
fi

echo -e "${CYAN}└────────────────────────────────────────────────────────────────────────┘${NONE}"
echo
EOF_MOTD

# 11.5. Включаем обратно ТОЛЬКО наш кастомный мониторинг
chmod +x /etc/update-motd.d/99-custom-sysinfo


###############################################################################
###############################################################################
# 11.6. ФИНАЛЬНАЯ УСТАНОВКА ЭТАЛОННОЙ БАЗЫ 3X-UI
###############################################################################
install_prepared_database


# 12. БЛОКИРУЮЩАЯ ФИНАЛЬНАЯ ПРОВЕРКА
###############################################################################

echo
echo "======================================================================"
echo " ✅ ФИНАЛЬНАЯ ПРОВЕРКА СИСТЕМЫ"
echo "======================================================================"

FAILED_CHECKS=0

check_item() {
    local label="$1"
    local condition="$2"
    local mandatory="${3:-1}"

    printf "%-26s : " "$label"
    if eval "$condition"; then
        echo "OK"
    else
        case "$mandatory" in
            1)
                echo "FAIL"
                FAILED_CHECKS=$((FAILED_CHECKS + 1))
                ;;
            skip)
                echo "SKIP (Чистая база - порты не созданы)"
                ;;
            *)
                echo "WARN (Опционально)"
                ;;
        esac
    fi
}

check_item "Nginx" "systemctl is-active --quiet nginx" 1
check_item "SSH (:1241)" "ss -lnt | grep -qE ':${SSH_PORT}[[:space:]]'" 1
check_item "Cron" "systemctl is-active --quiet cron" 1
check_item "Fail2ban" "systemctl is-active --quiet fail2ban" 1
check_item "Fail2ban SSH jail" "fail2ban-client status sshd >/dev/null 2>&1" 1
check_item "AntiScanner service" "systemctl is-active --quiet antiscan.timer || systemctl is-active --quiet antiscan" 1
check_item "AntiScanner ipset" "ipset list SCANNERS-BLOCK-V4 >/dev/null 2>&1" 1
check_item "AntiScanner rule" "iptables -C INPUT -m set --match-set SCANNERS-BLOCK-V4 src -j DROP >/dev/null 2>&1" 1
check_item "3x-ui service" "systemctl is-active --quiet x-ui" 1
check_item "Xray core process" "pgrep -af 'xray' >/dev/null 2>&1" 1

# Проверка портов Xray:
# Проверяем фактические активные входящие порты из базы данных 3x-ui
HAS_ACTIVE_INBOUNDS=0
ACTIVE_XRAY_PORTS=()
if [[ -f /etc/x-ui/x-ui.db ]] && command -v sqlite3 >/dev/null 2>&1; then
    while IFS= read -r p; do
        if [[ -n "$p" ]] && [[ "$p" =~ ^[0-9]+$ ]]; then
            ACTIVE_XRAY_PORTS+=("$p")
            HAS_ACTIVE_INBOUNDS=1
        fi
    done < <(sqlite3 /etc/x-ui/x-ui.db "SELECT port FROM inbounds WHERE enable = 1;" 2>/dev/null || true)
fi

if [[ "$HAS_ACTIVE_INBOUNDS" == "1" ]] && [[ "${#ACTIVE_XRAY_PORTS[@]}" -gt 0 ]]; then
    for port in "${ACTIVE_XRAY_PORTS[@]}"; do
        check_item "Xray Inbound :${port}" "ss -lnt | grep -qE ':${port}[[:space:]]'" 1
    done
elif [[ "${DB_RESTORED:-0}" == "1" ]]; then
    for port in "${XRAY_PORTS[@]}"; do
        check_item "Xray Port ${port}" "ss -lnt | grep -qE ':${port}[[:space:]]'" 1
    done
else
    for port in "${XRAY_PORTS[@]}"; do
        check_item "Xray Port ${port}" "ss -lnt | grep -qE ':${port}[[:space:]]'" "skip"
    done
fi

if [[ "$INSTALL_WARP" == "1" ]]; then
    check_item "WARP SOCKS5 (:40000)" "ss -lnt | grep -qE ':${WARP_PROXY_PORT}[[:space:]]'" "$WARP_MANDATORY"
fi

check_item "UFW Firewall" "ufw status | grep -q 'Status: active'" 1

if [[ "$DISABLE_IPV6" == "1" ]]; then
    check_item "IPv6 Disabled" "[[ \"\$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)\" == \"1\" ]]" 1
fi

if [[ "${INSTALL_POSTGRES:-0}" == "1" ]]; then
    check_item "PostgreSQL" "pg_isready >/dev/null 2>&1" 1
fi

if [[ "${INSTALL_MSSQL:-0}" == "1" ]]; then
    check_item "MS SQL Server" "docker ps --format '{{.Names}}' 2>/dev/null | grep -Eq '^mssql_server$'" 1
fi

if [[ "${INSTALL_TORRSERVER:-0}" == "1" ]]; then
    check_item "TorrServer (:8090)" "systemctl is-active --quiet torrserver" 1
fi

echo

# Блокировка создания маркера при наличии сбоев
if [[ "$FAILED_CHECKS" -gt 0 ]]; then
    echo "======================================================================"
    echo " ❌ РАЗВЕРТЫВАНИЕ НЕ ЗАВЕРШЕНО: Ошибок обязательных служб: ${FAILED_CHECKS}"
    echo " Маркер '${BOOTSTRAP_MARKER}' НЕ был создан."
    echo " Подробности смотрите в лог-файле: ${LOG_FILE}"
    echo "======================================================================"
    echo
    exit 1
fi

# Фиксация успешного завершения только при всех зелёных тестах
touch "$BOOTSTRAP_MARKER"

SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' || true)"

echo "======================================================================"
echo " ☁️ VPS УСПЕШНО НАСТРОЕН И ПРОВЕРЕН"
echo "======================================================================"
echo "IP VPS           : ${SERVER_IP:-unknown}"
echo "SSH Порт         : ${SSH_PORT}"
echo "Панель 3x-ui     : ${XUI_PORT}"
if [[ "$HAS_ACTIVE_INBOUNDS" == "1" ]]; then
    echo "Xray Inbounds    : ${XRAY_PORTS[*]}"
else
    echo "Xray Inbounds    : Не активированы (чистая установка без восстановления базы)"
fi
echo "WARP SOCKS5      : 127.0.0.1:${WARP_PROXY_PORT}"
echo "IPv6             : $( [[ "$DISABLE_IPV6" == "1" ]] && echo "Отключен" || echo "Включен" )"
echo "BBR              : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "default")"
[[ "${INSTALL_POSTGRES:-0}" == "1" ]] && echo "PostgreSQL       : 127.0.0.1:5432 (RUNNING)"
[[ "${INSTALL_MSSQL:-0}" == "1" ]] && echo "MS SQL Server    : 0.0.0.0:1433 (RUNNING)"
[[ "${INSTALL_TORRSERVER:-0}" == "1" ]] && echo "TorrServer       : :8090 (RUNNING)"
echo "======================================================================"
echo " ✅ Завершено успешно: $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================================"
echo
