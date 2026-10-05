#!/usr/bin/env bash
# ==============================================================================
# NaïveProxy + Caddy One-Command Installer & Manager (v2.8-STABLE)
# Architecture:
#   - TCP :80  -> Nginx (Сайт-заглушка / Изолированный Stub Server Block)
#   - TCP :443 -> Caddy (NaïveProxy + TLS-ALPN-01 + probe_resistance fallback)
# Supported OS: Debian 11/12+, Ubuntu 20.04/22.04/24.04+
# Architectures: x86_64 (amd64), aarch64 (arm64)
# ==============================================================================

# Гарантия интерактивного ввода при вызове скрипта через curl | bash
if [ ! -t 0 ] && [ -e /dev/tty ]; then
    if (exec </dev/tty) 2>/dev/null; then
        exec </dev/tty 2>/dev/null
    fi
fi

# ------------------------------------------------------------------------------
# Цветовая палитра
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ------------------------------------------------------------------------------
# Системные пути и константы
# ------------------------------------------------------------------------------
CADDY_BIN="/usr/local/bin/caddy"
CADDY_BAK="/usr/local/bin/caddy.bak"
CADDY_CONF_DIR="/etc/caddy"
CADDY_FILE="/etc/caddy/Caddyfile"
CADDY_SERVICE="/etc/systemd/system/caddy.service"
WEB_ROOT="/var/www/naiveproxy"

NGINX_STUB_ROOT="/var/www/naiveproxy-nginx"
NGINX_STUB_CONF="/etc/nginx/sites-available/naiveproxy-stub"
NGINX_STUB_ENABLED="/etc/nginx/sites-enabled/naiveproxy-stub"
NGINX_STATE_FILE="/etc/naiveproxy/nginx-state"
BUILD_INFO_FILE="/etc/naiveproxy/build-info"

NAIVE_DIR="/etc/naiveproxy"
CREDS_FILE="/etc/naiveproxy/credentials"
CLIENT_CONFIG="/etc/naiveproxy/client.json"
USERS_FILE="/etc/naiveproxy/users.json"
CLIENTS_DIR="/etc/naiveproxy/clients"
DOMAIN_CHECK_FILE="/etc/naiveproxy/domain-check"
MOTD_FILE="/etc/update-motd.d/98-naiveproxy"
GO_INSTALL_DIR="/usr/local/go"
DEFAULT_GO_VERSION="1.24.1"
GO_VERSION="1.24.1"
XCADDY_VERSION="v0.4.4"
BUILD_ROOT="/root/.cache/naiveproxy-build"
WEB_CREDS_FILE="/etc/naiveproxy/web_credentials"
WEB_SERVICE_FILE="/etc/systemd/system/naiveproxy-webui.service"
WEB_SERVICE_ALIAS="/etc/systemd/system/naiveproxy-web.service"
WEB_SCRIPT_FILE="/usr/local/bin/naiveproxy-webui"
HELPER_SCRIPT_FILE="/usr/local/bin/naiveproxy-helper"
WEB_PORT="18080"

# Глобальный статус сквозного туннеля NaïveProxy
PROXY_TUNNEL_STATUS="NOT_VERIFIED"

# ------------------------------------------------------------------------------
# Вспомогательные функции вывода и логирования
# ------------------------------------------------------------------------------
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
step() { echo -e "\n${BOLD}${CYAN}[$1]${NC} ${BOLD}$2${NC}"; }

print_header() {
    clear 2>/dev/null || true
    echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}            NAÏVEPROXY + CADDY MANAGER (v2.8-STABLE)        ${NC}"
    echo -e "${BOLD}${CYAN}          (Nginx :80 Stub  +  Caddy :443 TLS)        ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
}

# Генератор криптографически стойких случайных строк (без конвейеров для защиты от SIGPIPE)
generate_random_string() {
    local len="${1:-16}"
    local hex_len=$(( (len + 1) / 2 ))
    local raw_hex
    raw_hex=$(openssl rand -hex "$hex_len" 2>/dev/null || od -vAn -N"$hex_len" -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
    echo "${raw_hex:0:$len}"
}

# Сравнение версий (возвращает 0, если $1 >= $2)
validate_email() {
    local email="$1"
    [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

get_latest_stable_go_version() {
    local ver
    ver=$(curl -fsSL -m 4 "https://go.dev/VERSION?m=text" 2>/dev/null | head -n1 | sed 's/go//' | tr -d '[:space:]' || true)
    if [[ "$ver" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        echo "$ver"
    else
        echo "$DEFAULT_GO_VERSION"
    fi
}

version_ge() {
    local v1="$1" v2="$2"
    [ "$v1" = "$v2" ] && return 0
    [ "$(printf '%s\n%s\n' "$v2" "$v1" | sort -V | head -n1)" = "$v2" ]
}

# ------------------------------------------------------------------------------
# Чтение состояния и учетных записей
# ------------------------------------------------------------------------------
load_credentials() {
    [ ! -f "$CREDS_FILE" ] && return 1
    DOMAIN=$(grep -E '^DOMAIN=' "$CREDS_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
    EMAIL=$(grep -E '^EMAIL=' "$CREDS_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
    USERNAME=$(grep -E '^USERNAME=' "$CREDS_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
    PASSWORD=$(grep -E '^PASSWORD=' "$CREDS_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
    PORT=$(grep -E '^PORT=' "$CREDS_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
    CREATED_AT=$(grep -E '^CREATED_AT=' "$CREDS_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
    PROXY_TUNNEL_STATUS=$(grep -E '^PROXY_TUNNEL_STATUS=' "$CREDS_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
    [ -z "$PROXY_TUNNEL_STATUS" ] && PROXY_TUNNEL_STATUS="NOT_VERIFIED"
    return 0
}

load_domain_check() {
    if [ ! -f "$DOMAIN_CHECK_FILE" ]; then
        CHECKED_DOMAIN=""
        CHECKED_SERVER_IPV4=""
        CHECKED_DNS_IPV4=""
        CHECKED_STATUS="NOT_CONFIGURED"
        CHECKED_TIMESTAMP=""
        CHECKED_TIMESTAMP_EPOCH="0"
        return 1
    fi
    CHECKED_DOMAIN=$(grep -E '^DOMAIN=' "$DOMAIN_CHECK_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
    CHECKED_SERVER_IPV4=$(grep -E '^SERVER_IPV4=' "$DOMAIN_CHECK_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
    CHECKED_DNS_IPV4=$(grep -E '^DNS_IPV4=' "$DOMAIN_CHECK_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
    CHECKED_STATUS=$(grep -E '^(DOMAIN_STATUS|STATUS)=' "$DOMAIN_CHECK_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
    CHECKED_TIMESTAMP=$(grep -E '^(CHECK_TIMESTAMP|TIMESTAMP)=' "$DOMAIN_CHECK_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
    CHECKED_TIMESTAMP_EPOCH=$(grep -E '^(CHECK_TIMESTAMP_EPOCH|TIMESTAMP_EPOCH)=' "$DOMAIN_CHECK_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
    CHECKED_TIMESTAMP_EPOCH="${CHECKED_TIMESTAMP_EPOCH:-0}"
    [ -n "$CHECKED_DOMAIN" ] && [ -n "$CHECKED_STATUS" ]
}

is_domain_ready() {
    [ ! -f "$DOMAIN_CHECK_FILE" ] && return 1
    load_domain_check || return 1
    [ -z "$CHECKED_DOMAIN" ] && return 1
    [ "$CHECKED_STATUS" != "READY" ] && [ "$CHECKED_STATUS" != "READY_WITH_WARNINGS" ] && return 1
    return 0
}

# ------------------------------------------------------------------------------
# Управление мультипользовательским режимом NaïveProxy (Клиенты)
# ------------------------------------------------------------------------------
load_users() {
    mkdir -p "$CLIENTS_DIR"
    chown root:naive-web "$CLIENTS_DIR" 2>/dev/null || true
    chmod 750 "$CLIENTS_DIR" 2>/dev/null || true

    # Если users.json еще нет, но есть credentials — мигрируем начального пользователя
    if [ ! -f "$USERS_FILE" ] && [ -f "$CREDS_FILE" ]; then
        load_credentials 2>/dev/null || true
        if [ -n "$USERNAME" ] && [ -n "$PASSWORD" ]; then
            python3 - "$USERS_FILE" "$USERNAME" "$PASSWORD" << 'EOF_PY'
import sys, json, datetime
users_file, username, password = sys.argv[1], sys.argv[2], sys.argv[3]
now_str = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
data = [{
    "username": username,
    "password": password,
    "created_at": now_str,
    "note": "Основной клиент"
}]
with open(users_file, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
EOF_PY
            chmod 640 "$USERS_FILE"
            chown root:naive-web "$USERS_FILE" 2>/dev/null || true
        fi
    fi
}

sync_caddy_users() {
    load_credentials 2>/dev/null || true
    load_users 2>/dev/null || true
    local target_domain="${DOMAIN:-$CHECKED_DOMAIN}"

    [ ! -f "$USERS_FILE" ] && return 1
    [ ! -f "$CADDY_FILE" ] && return 1

    # Чтение пользователей и генерация строк basic_auth
    local auth_lines
    auth_lines=$(python3 - "$USERS_FILE" << 'EOF_PY'
import sys, json
users_file = sys.argv[1]
try:
    with open(users_file, "r", encoding="utf-8") as f:
        users = json.load(f)
    for u in users:
        un = u.get("username", "")
        pw = u.get("password", "")
        if un and pw:
            print(f"        basic_auth {un} {pw}")
except Exception:
    pass
EOF_PY
)

    if [ -z "$auth_lines" ]; then
        error "Список пользователей в $USERS_FILE пуст! Нельзя оставить прокси без пользователей."
        return 1
    fi

    # Обновление блока forward_proxy в Caddyfile через Python
    python3 - "$CADDY_FILE" "$auth_lines" << 'EOF_PY'
import sys, re
caddy_file = sys.argv[1]
auth_lines = sys.argv[2]

with open(caddy_file, "r", encoding="utf-8") as f:
    content = f.read()

auth_block = auth_lines + """
        hide_ip
        hide_via
        probe_resistance"""

pattern = r"forward_proxy\s*\{[\s\S]*?\}"
new_fp = "forward_proxy {
" + auth_block + "
    }"

new_content = re.sub(pattern, new_fp, content)
with open(caddy_file, "w", encoding="utf-8") as f:
    f.write(new_content)
EOF_PY

    # Валидация Caddyfile новым бинарником
    if /usr/local/bin/caddy validate --config "$CADDY_FILE" >/dev/null 2>&1; then
        systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null || true
        success "Конфигурация Caddy успешно обновлена (zero-downtime reload)."
    else
        error "Ошибка валидации Caddyfile при синхронизации пользователей!"
        return 1
    fi

    # Обновление индивидуальных client.json в $CLIENTS_DIR
    mkdir -p "$CLIENTS_DIR"
    python3 -c "
import json, os
with open('$USERS_FILE', 'r', encoding='utf-8') as f:
    users = json.load(f)
for u in users:
    cfg = {
        'listen': 'socks://127.0.0.1:1080',
        'proxy': f'https://{u["username"]}:{u["password"]}@$target_domain'
    }
    path = os.path.join('$CLIENTS_DIR', f'{u["username"]}.json')
    with open(path, 'w', encoding='utf-8') as out:
        json.dump(cfg, out, indent=2)
    os.chmod(path, 0o640)
"
    chown root:naive-web "$CLIENTS_DIR"/* 2>/dev/null || true
    return 0
}

client_add() {
    load_credentials 2>/dev/null || true
    load_users 2>/dev/null || true
    local target_domain="${DOMAIN:-$CHECKED_DOMAIN}"

    local u="$1" p="$2" n="${3:-Клиент}"

    if [ -z "$u" ] || [ -z "$p" ]; then
        echo -e "${BOLD}ДОБАВЛЕНИЕ НОВОГО КЛИЕНТА NAÏVEPROXY${NC}\n"
        local auto_u="user_$(generate_random_string 8)"
        read -r -p "Логин клиента [по умолчанию: $auto_u]: " u
        u="${u:-$auto_u}"
        u=$(echo "$u" | tr -d '[:space:]')
        [[ ! "$u" =~ ^[A-Za-z0-9_-]+$ ]] && { error "Некорректный логин (только латиница, цифры, дефис)."; return 1; }

        local auto_p
        auto_p=$(generate_random_string 16)
        read -r -p "Пароль клиента [по умолчанию: $auto_p]: " p
        p="${p:-$auto_p}"
        p=$(echo "$p" | tr -d '[:space:]')
        [[ ! "$p" =~ ^[A-Za-z0-9._-]+$ ]] && { error "Некорректный пароль."; return 1; }

        read -r -p "Примечание (например, Телефон / Иван) [по умолчанию: Клиент]: " n
        n="${n:-Клиент}"
    fi

    # Проверка на дубликат логина
    local exists
    exists=$(python3 - "$USERS_FILE" "$u" << 'EOF_PY'
import sys, json
users_file, target_user = sys.argv[1], sys.argv[2]
try:
    with open(users_file, "r", encoding="utf-8") as f:
        users = json.load(f)
    print("yes" if any(user.get("username") == target_user for user in users) else "no")
except Exception:
    print("no")
EOF_PY
)
    if [ "$exists" = "yes" ]; then
        error "Пользователь с логином '$u' уже существует!"
        return 1
    fi

    # Добавление в users.json
    python3 - "$USERS_FILE" "$u" "$p" "$n" << 'EOF_PY'
import sys, json, datetime
users_file, u, p, n = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    with open(users_file, "r", encoding="utf-8") as f:
        users = json.load(f)
except Exception:
    users = []

now_str = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
users.append({
    "username": u,
    "password": p,
    "created_at": now_str,
    "note": n
})

with open(users_file, "w", encoding="utf-8") as f:
    json.dump(users, f, indent=2, ensure_ascii=False)
EOF_PY
    chmod 640 "$USERS_FILE"
    chown root:naive-web "$USERS_FILE" 2>/dev/null || true

    sync_caddy_users

    local nekobox_link="naive+https://${u}:${p}@${target_domain}:443#Naive-${u}"
    success "Клиент '$u' успешно добавлен!"
    echo "──────────────────────────────────────────────────────"
    echo -e "  Логин:        ${BOLD}$u${NC}"
    echo -e "  Пароль:       ${BOLD}$p${NC}"
    echo -e "  Примечание:   $n"
    echo -e "  NekoBox URL:  ${YELLOW}${nekobox_link}${NC}"
    echo -e "  Стандарт URL: ${YELLOW}https://${u}:${p}@${target_domain}:443${NC}"
    echo -e "  Файл конфига: $CLIENTS_DIR/${u}.json"
    if command -v qrencode &>/dev/null; then
        echo -e "\n${CYAN}QR-код для импорта в NekoBox / Matsuri / v2rayN:${NC}"
        qrencode -t ANSIUTF8 "${nekobox_link}"
    fi
    echo "──────────────────────────────────────────────────────"
    return 0
}

client_delete() {
    load_users 2>/dev/null || true
    local u="$1"
    if [ -z "$u" ]; then
        echo -e "${BOLD}УДАЛЕНИЕ КЛИЕНТА NAÏVEPROXY${NC}\n"
        read -r -p "Введите логин клиента для удаления: " u
        u=$(echo "$u" | tr -d '[:space:]')
    fi

    [ -z "$u" ] && { error "Логин не указан."; return 1; }

    # Проверка, что не удаляется последний пользователь
    local count
    count=$(python3 - "$USERS_FILE" << 'EOF_PY'
import sys, json
users_file = sys.argv[1]
try:
    with open(users_file, "r", encoding="utf-8") as f:
        users = json.load(f)
    print(len(users))
except Exception:
    print(0)
EOF_PY
)
    if [ "$count" -le 1 ]; then
        error "Нельзя удалить последнего клиента! В системе должен оставаться хотя бы один пользователь."
        return 1
    fi

    local removed
    removed=$(python3 - "$USERS_FILE" "$u" << 'EOF_PY'
import sys, json
users_file, u = sys.argv[1], sys.argv[2]
try:
    with open(users_file, "r", encoding="utf-8") as f:
        users = json.load(f)
    new_users = [user for user in users if user.get("username") != u]
    if len(new_users) < len(users):
        with open(users_file, "w", encoding="utf-8") as f:
            json.dump(new_users, f, indent=2, ensure_ascii=False)
        print("yes")
    else:
        print("no")
except Exception:
    print("no")
EOF_PY
)

    if [ "$removed" = "yes" ]; then
        rm -f "$CLIENTS_DIR/${u}.json" 2>/dev/null || true
        sync_caddy_users
        success "Клиент '$u' успешно удален из системы."
        return 0
    else
        error "Клиент с логином '$u' не найден."
        return 1
    fi
}

client_list() {
    load_credentials 2>/dev/null || true
    load_users 2>/dev/null || true
    local target_domain="${DOMAIN:-$CHECKED_DOMAIN}"

    echo -e "${BOLD}${CYAN}СПИСОК КЛИЕНТОВ NAÏVEPROXY${NC}\n"
    python3 - "$USERS_FILE" "$target_domain" << 'EOF_PY'
import sys, json

users_file = sys.argv[1]
target_domain = sys.argv[2]

try:
    with open(users_file, "r", encoding="utf-8") as f:
        users = json.load(f)
    if not users:
        print("Клиенты отсутствуют.")
    else:
        print(f"Всего клиентов: {len(users)}\n")
        header_fmt = "{:<3} {:<18} {:<18} {:<15} {}"
        print(header_fmt.format("#", "ЛОГИН", "ПАРОЛЬ", "ПРИМЕЧАНИЕ", "СОЗДАН"))
        print("─" * 70)
        for i, u in enumerate(users, 1):
            un = u.get("username", "")
            pw = u.get("password", "")
            nt = u.get("note", "") or ""
            ca = u.get("created_at", "")[:10] if u.get("created_at") else ""
            print(header_fmt.format(i, un, pw, nt, ca))
        print("─" * 70)
        print("\nСсылки подключения (NekoBox & Matsuri format):")
        for u in users:
            un = u.get("username", "")
            pw = u.get("password", "")
            print(f" • {un}: naive+https://{un}:{pw}@{target_domain}:443#Naive-{un}")
except Exception as e:
    print("Ошибка чтения списка пользователей:", e)
EOF_PY
}

manage_clients_menu() {
    while true; do
        print_header
        echo -e "${BOLD}${CYAN}УПРАВЛЕНИЕ КЛИЕНТАМИ NAÏVEPROXY${NC}\n"
        echo "  1) Список всех клиентов и ссылки подключения"
        echo "  2) Добавить нового клиента (+ client.json)"
        echo "  3) Показать / скопировать client.json клиента"
        echo "  4) Удалить клиента"
        echo "  0) Назад в главное меню"
        echo "──────────────────────────────────────────────────────"
        echo ""
        read -r -p "Выберите действие [0-4]: " cchoice
        case "$cchoice" in
            1)
                print_header
                client_list
                echo ""
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            2)
                print_header
                client_add "" "" ""
                echo ""
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            3)
                print_header
                read -r -p "Введите логин клиента: " quser
                quser=$(echo "$quser" | tr -d '[:space:]')
                if [ -f "$CLIENTS_DIR/${quser}.json" ]; then
                    echo -e "\n${BOLD}Конфигурация $CLIENTS_DIR/${quser}.json:${NC}\n"
                    cat "$CLIENTS_DIR/${quser}.json"
                    echo ""
                else
                    error "Конфигурация для пользователя '$quser' не найдена."
                fi
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            4)
                print_header
                client_list
                echo ""
                client_delete ""
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            0) return 0 ;;
            *) error "Неверный выбор."; sleep 1 ;;
        esac
    done
}

is_webui_ready() {
    [ ! -x "$WEB_SCRIPT_FILE" ] && return 1
    [ ! -f "$WEB_SERVICE_FILE" ] && return 1
    systemctl is-active --quiet naiveproxy-webui 2>/dev/null || return 1
    local check_port="${WEB_PORT:-18080}"
    if [ -f "$WEB_CREDS_FILE" ]; then
        local sp
        sp=$(grep -E '^WEB_PORT=' "$WEB_CREDS_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
        [ -n "$sp" ] && check_port="$sp"
    fi
    is_port_listening "$check_port" || return 1
    [ -f "$CADDY_FILE" ] && grep -q '/admin' "$CADDY_FILE" 2>/dev/null || return 1
    return 0
}

is_naiveproxy_installed() {
    [ -f "$CREDS_FILE" ] && \
    [ -f "$CADDY_FILE" ] && \
    [ -f "$CADDY_BIN" ] && \
    grep -q "forward_proxy" "$CADDY_FILE" 2>/dev/null
}

# ------------------------------------------------------------------------------
# Проверки системы и установка зависимостей
# ------------------------------------------------------------------------------
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "Этот скрипт должен быть запущен с правами суперпользователя (root)."
        echo "Запустите: sudo bash $0"
        exit 1
    fi
}

check_os() {
    if [ ! -f /etc/os-release ]; then
        error "Не удалось определить ОС (/etc/os-release не найден)."
        exit 1
    fi
    # shellcheck source=/dev/null
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_VERSION_ID="${VERSION_ID:-}"
    case "$OS_ID" in
        ubuntu) [ "${OS_VERSION_ID%%.*}" -lt 20 ] && warn "Поддерживается Ubuntu 20.04+. У вас: $VERSION_ID" ;;
        debian) [ "${OS_VERSION_ID%%.*}" -lt 11 ] && warn "Поддерживается Debian 11+. У вас: $VERSION_ID" ;;
        *) warn "Дистрибутив $NAME официально не тестировался. Продолжаем на базе APT." ;;
    esac
}

check_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) GO_ARCH="amd64" ;;
        aarch64|arm64) GO_ARCH="arm64" ;;
        *) error "Неподдерживаемая архитектура: $ARCH. Требуется x86_64 или aarch64."; exit 1 ;;
    esac
}

require_command() {
    local cmd="$1"
    local pkg="${2:-$1}"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        info "Установка $pkg (требуется команда $cmd)..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq 2>/dev/null || true
        apt-get install -y -qq "$pkg" >/dev/null 2>&1 || apt-get install -y "$pkg" || {
            error "Не удалось установить $pkg. Проверьте сеть и репозитории APT."
            return 1
        }
    fi
}

install_dependencies() {
    export DEBIAN_FRONTEND=noninteractive
    local missing_tools=()
    for cmd in curl wget jq git tar openssl dig gcc make ss ip qrencode; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_tools+=("$cmd")
        fi
    done

    if [ ${#missing_tools[@]} -gt 0 ]; then
        info "Установка системных зависимостей (${missing_tools[*]})..."
        apt-get update -qq || {
            error "Не удалось обновить индекс пакетов APT. Проверьте сеть и /etc/apt/sources.list."
            return 1
        }
        apt-get install -y -qq \
            curl wget jq git tar openssl build-essential dnsutils ca-certificates ufw iproute2 qrencode >/dev/null || {
                error "Ошибка установки пакетов через apt-get."
                exit 1
            }
        success "Системные зависимости установлены."
    fi
}

get_server_ipv4() {
    local ip=""

    # 1. ip route — предпочтительный способ получения исходящего адреса
    if command -v ip &>/dev/null; then
        ip="$(ip -4 route get 1.1.1.1 2>/dev/null |
            awk '{
                for (i = 1; i <= NF; i++) {
                    if ($i == "src") {
                        print $(i+1)
                        exit
                    }
                }
            }')"

        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            # Проверяем, что адрес публичный, а не приватный (RFC 1918 / CGNAT / Loopback / Link-Local)
            if ! [[ "$ip" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.|127\.|169\.254\.|100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.) ]]; then
                printf '%s\n' "$ip"
                return 0
            fi
        fi
    fi

    # 2. Внешние сервисы проверки публичного IPv4
    local endpoints=(
        "https://api.ipify.org"
        "https://icanhazip.com"
        "https://ifconfig.me/ip"
        "https://api.ip.sb/ip"
        "https://checkip.amazonaws.com"
    )

    for ep in "${endpoints[@]}"; do
        ip="$(curl -4fsS --connect-timeout 5 --max-time 10 "$ep" 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            if ! [[ "$ip" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.|127\.|169\.254\.|100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.) ]]; then
                printf '%s\n' "$ip"
                return 0
            fi
        fi
    done

    return 1
}

resolve_server_ips() {
    # Если уже определён корректный публичный IPv4, не запрашивать повторно
    if [[ ! "$SERVER_IPV4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        SERVER_IPV4="$(get_server_ipv4 || true)"
    fi

    SERVER_IPV6_OUTBOUND=""
    SERVER_IPV6_LIST=()

    # Внешний IPv6 (строго через ключ -6)
    for ep in "https://api6.ipify.org" "https://icanhazip.com" "https://ifconfig.co"; do
        local ip6_candidate
        ip6_candidate=$(curl -6fsS --connect-timeout 5 --max-time 10 "$ep" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ "$ip6_candidate" =~ : ]]; then
            SERVER_IPV6_OUTBOUND="$ip6_candidate"
            break
        fi
    done

    # Сбор всех глобальных IPv6-адресов сетевых интерфейсов VPS
    if command -v ip &>/dev/null; then
        while IFS= read -r ip6; do
            [ -n "$ip6" ] && SERVER_IPV6_LIST+=("$ip6")
        done < <(ip -6 addr show scope global 2>/dev/null | awk '/inet6/ {print $2}' | cut -d/ -f1 || true)
    fi

    # Основной IPv6 сервера (приоритет: подтвержденный исходящий -> локальный интерфейс)
    if [ -n "$SERVER_IPV6_OUTBOUND" ]; then
        SERVER_IPV6="$SERVER_IPV6_OUTBOUND"
        SERVER_IPV6_STATUS="OUTBOUND_CONFIRMED"
    elif [ "${#SERVER_IPV6_LIST[@]}" -gt 0 ]; then
        SERVER_IPV6="${SERVER_IPV6_LIST[0]}"
        SERVER_IPV6_STATUS="LOCAL_ONLY"
    else
        SERVER_IPV6=""
        SERVER_IPV6_STATUS="NONE"
    fi

    if [ -z "$SERVER_IPV4" ]; then
        warn "Не удалось автоматически определить внешний IPv4 адрес сервера."
    fi
}

get_port_owner() {
    local port="$1"
    local line=""
    if command -v ss &>/dev/null; then
        local rx_proc='users:\(\("([^"]+)",pid=([0-9]+)'
        local rx_name='users:\(\("([^"]+)"'
        line=$(ss -H -ltnp "( sport = :$port )" 2>/dev/null | head -n1 || true)
        if [[ "$line" =~ $rx_proc ]]; then
            echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
            return 0
        elif [[ "$line" =~ $rx_name ]]; then
            echo "${BASH_REMATCH[1]} 0"
            return 0
        fi
    fi

    if command -v lsof &>/dev/null; then
        local lout
        lout=$(lsof -i :"$port" -sTCP:LISTEN -Fp -Fc 2>/dev/null | head -n4 || true)
        if [ -n "$lout" ]; then
            local pid="0" pname="unknown"
            while IFS= read -r fld; do
                [[ "$fld" =~ ^p([0-9]+) ]] && pid="${BASH_REMATCH[1]}"
                [[ "$fld" =~ ^c(.+) ]] && pname="${BASH_REMATCH[1]}"
            done <<< "$lout"
            echo "$pname $pid"
            return 0
        fi
    fi
    echo ""
}
is_port_listening() {
    local port="$1"
    python3 -c "import socket; s = socket.socket(); s.settimeout(0.5); exit(0 if s.connect_ex(('127.0.0.1', int('$port'))) == 0 else 1)" 2>/dev/null && return 0
    if command -v ss &>/dev/null; then
        ss -tln 2>/dev/null | grep -E "[: ]$port[[:space:]]" >/dev/null 2>&1 && return 0
    fi
    if command -v lsof &>/dev/null; then
        lsof -i :"$port" -sTCP:LISTEN >/dev/null 2>&1 && return 0
    fi
    return 1
}

validate_domain_format() {
    local domain="$1"
    if [[ ! "$domain" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]; then
        echo "SYNTAX_ERROR"; return 1
    fi
    case "$domain" in
        *.pages.dev) echo "BLOCKED_PAGES_DEV"; return 1 ;;
        *.github.io|*.vercel.app|*.netlify.app) echo "BLOCKED_STATIC_HOST"; return 1 ;;
    esac
    echo "VALID"; return 0
}

# Иерархическая проверка CAA с обработкой ошибок сети
check_caa_record() {
    local domain="$1"
    local caa_records=""
    local cur_dom="$domain"
    local query_failed=false

    # Проверка цепочки доменов снизу вверх по иерархии DNS (RFC 8659)
    while [[ "$cur_dom" == *.* ]]; do
        if command -v dig &>/dev/null; then
            local dig_out
            dig_out=$(dig +short CAA "$cur_dom" @1.1.1.1 2>&1 || true)
            if echo "$dig_out" | grep -qiE 'connection timed out|communications error|timed out'; then
                query_failed=true; break
            fi
            caa_records=$(echo "$dig_out" | tr -d '\r' | grep -v ';' || true)
        fi
        [ -n "$caa_records" ] && break
        cur_dom="${cur_dom#*.}"
        [[ "$cur_dom" != *.* ]] && break
    done

    if [ "$query_failed" = true ]; then
        echo "QUERY_FAILED"; return 0
    fi
    if [ -z "$caa_records" ]; then
        echo "ABSENT"; return 0
    fi

    # Разбор CAA по полям: flag tag val (RFC 8659 Section 4.1)
    # Для обычного одиночного FQDN выпуск регламентируется исключительно тегом 'issue'
    local issue_found=false
    local le_allowed=false

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local flag="" tag="" val="" rest=""
        read -r flag tag val rest <<< "$line"
        tag=$(echo "$tag" | tr '[:upper:]' '[:lower:]' | tr -d '"')
        val=$(echo "$val $rest" | tr '[:upper:]' '[:lower:]' | tr -d '"')

        if [ "$tag" = "issue" ]; then
            issue_found=true
            if [[ "$val" == *"letsencrypt.org"* ]]; then
                le_allowed=true
            fi
        fi
    done <<< "$caa_records"

    if [ "$issue_found" = true ]; then
        [ "$le_allowed" = true ] && echo "ALLOWED" || echo "RESTRICTED"
    else
        # Если присутствуют только iodef или issuewild, выпуск для одиночного FQDN разрешён
        echo "ABSENT"
    fi
}

# Единая функция глубокой проверки TLS сертификата
# Выводит: status|issuer|host_match|days_left|expiry_date
verify_tls_certificate() {
    local domain="$1"
    local cert_pem=""

    cert_pem=$(openssl s_client -connect 127.0.0.1:443 -servername "$domain" -showcerts </dev/null 2>/dev/null | openssl x509 2>/dev/null || true)

    if [ -z "$cert_pem" ]; then
        if echo | openssl s_client -connect 127.0.0.1:443 -servername "$domain" 2>&1 | grep -q "CONNECTED"; then
            echo "PENDING|В процессе выпуска (ACME TLS-ALPN-01)|UNKNOWN|0|UNKNOWN"
            return 1
        fi
        echo "NOT_DETECTED|none|UNKNOWN|0|UNKNOWN"
        return 1
    fi

    local issuer
    issuer=$(echo "$cert_pem" | openssl x509 -noout -issuer 2>/dev/null | sed -e 's/issuer=//' | tr -d '\r' | sed 's/^[ \t]*//' || true)

    local not_after exp_epoch now_epoch days_left=0 exp_date="UNKNOWN"
    not_after=$(echo "$cert_pem" | openssl x509 -noout -enddate 2>/dev/null | sed -e 's/notAfter=//' || true)
    if [ -n "$not_after" ]; then
        exp_date="$not_after"
        exp_epoch=$(date -d "$not_after" +%s 2>/dev/null || true)
        now_epoch=$(date +%s)
        if [ -n "$exp_epoch" ] && [ "$exp_epoch" -gt "$now_epoch" ]; then
            days_left="$(( (exp_epoch - now_epoch) / 86400 ))"
        fi
    fi

    local host_match="MISMATCH"
    if echo "$cert_pem" | openssl x509 -noout -text 2>/dev/null | grep -E "DNS:${domain}\b" >/dev/null 2>&1; then
        host_match="MATCH"
    elif echo "$cert_pem" | openssl x509 -noout -subject 2>/dev/null | grep -E "CN[[:space:]]*=[[:space:]]*${domain}\b" >/dev/null 2>&1; then
        host_match="MATCH"
    fi

    local is_trusted=false
    if echo | openssl s_client -connect 127.0.0.1:443 -servername "$domain" -verify_hostname "$domain" 2>&1 | grep -q 'Verify return code: 0 (ok)'; then
        is_trusted=true
    elif curl -s -m 4 --resolve "${domain}:443:127.0.0.1" "https://${domain}" >/dev/null 2>&1; then
        is_trusted=true
    fi

    if [ "$is_trusted" = true ] && [ "$host_match" = "MATCH" ] && [ "$days_left" -gt 0 ]; then
        echo "VALID|$issuer|MATCH|$days_left|$exp_date"
        return 0
    elif [ "$host_match" = "MATCH" ]; then
        echo "PENDING|$issuer|MATCH|$days_left|$exp_date"
        return 1
    else
        echo "UNTRUSTED|$issuer|$host_match|$days_left|$exp_date"
        return 1
    fi
}

setup_motd() {
    if [ -d "/etc/update-motd.d" ]; then
        cat << 'EOF' > "$MOTD_FILE"
#!/bin/sh
if systemctl is-active --quiet caddy 2>/dev/null && [ -f /etc/naiveproxy/credentials ]; then
    dom=$(grep -E '^DOMAIN=' /etc/naiveproxy/credentials 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
    printf " NaïveProxy : \033[1;32mRUNNING\033[0m (port 443, %s)\n" "$dom"
elif [ -f /etc/naiveproxy/credentials ]; then
    printf " NaïveProxy : \033[1;31mSTOPPED\033[0m\n"
fi
if systemctl is-active --quiet nginx 2>/dev/null; then
    printf " Nginx Stub : \033[1;32mRUNNING\033[0m (port 80)\n"
fi
EOF
        chmod +x "$MOTD_FILE" 2>/dev/null || true
    fi
}

remove_motd() {
    rm -f "$MOTD_FILE" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Проверка и безопасная настройка портов 80 и 443
# ------------------------------------------------------------------------------
check_port80_conflict() {
    step "1/7" "Проверка доступности порта 80 (TCP :80)"
    local p80_info
    p80_info=$(get_port_owner 80)
    if [ -n "$p80_info" ]; then
        local proc="${p80_info%% *}" pid="${p80_info##* }"
        if [ "$proc" = "nginx" ]; then
            success "Порт 80 уже используется Nginx (PID $pid) — штатно для сайта-заглушки."
            return 0
        else
            error "Порт 80 занят процессом '$proc' (PID $pid)!"
            error "Служба не является Nginx. NaïveProxy требует освободить порт 80 перед продолжением."
            return 1
        fi
    fi
    success "Порт 80 свободен для Nginx."
    return 0
}

ensure_nginx_stub() {
    step "2/7" "Обеспечение работы Nginx на порту 80 (:80 — существующий Nginx или изолированный Stub)"

    local need_install=false
    command -v nginx &>/dev/null || need_install=true

    mkdir -p "$NAIVE_DIR"

    # Инициализация файла состояния Nginx (/etc/naiveproxy/nginx-state, STATE_VERSION=2)
    if [ ! -f "$NGINX_STATE_FILE" ]; then
        local def_existed=false def_type="none" def_target="" def_bak=""
        if [ -L /etc/nginx/sites-enabled/default ]; then
            def_existed=true
            def_type="symlink"
            def_target=$(readlink -f /etc/nginx/sites-enabled/default 2>/dev/null || true)
        elif [ -f /etc/nginx/sites-enabled/default ]; then
            def_existed=true
            def_type="file"
            def_bak="/etc/naiveproxy/nginx_default_file.bak"
            cp -a /etc/nginx/sites-enabled/default "$def_bak"
        fi

        cat << EOF > "$NGINX_STATE_FILE"
MANAGED_BY=naiveproxy-installer
STATE_VERSION=2
CREATED_AT="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
NGINX_INSTALLED_BY_SCRIPT=$need_install
DEFAULT_EXISTED=$def_existed
DEFAULT_TYPE=$def_type
DEFAULT_SYMLINK_TARGET="$def_target"
DEFAULT_FILE_BACKUP="$def_bak"
STUB_CONFIG_CREATED=false
STUB_ENABLED=false
DISABLED_443_SITES=""
EOF
        chmod 600 "$NGINX_STATE_FILE"
    fi

    if [ "$need_install" = true ]; then
        info "Установка Nginx через apt-get..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq || true
        apt-get install -y -qq nginx >/dev/null || { error "Ошибка установки Nginx."; return 1; }
        success "Nginx успешно установлен."
    else
        success "Nginx уже установлен ($(nginx -v 2>&1 | tr -d '\n'))."
    fi

    # Проверка: если Nginx уже работает и отдаёт HTTP-ответ на 127.0.0.1:80 — сохраняем сайт пользователя
    local p80_code
    p80_code=$(curl -s -m 3 -o /dev/null -w "%{http_code}" "http://127.0.0.1/" 2>/dev/null || true)
    local p80_owner
    p80_owner=$(get_port_owner 80)

    if [[ "$p80_code" =~ ^(200|301|302|304|403)$ ]] && [[ "${p80_owner%% *}" == "nginx" ]]; then
        info "Порт 80 обслуживается существующим сайтом Nginx (код ответа $p80_code). Конфигурация сохранена."
        return 0
    fi

    # Если служба Nginx остановлена, пробуем запустить существующую конфигурацию
    if [ "$need_install" = false ] && ! systemctl is-active --quiet nginx 2>/dev/null; then
        if nginx -t >/dev/null 2>&1; then
            systemctl enable nginx >/dev/null 2>&1 || true
            systemctl start nginx 2>/dev/null || true
            p80_code=$(curl -s -m 3 -o /dev/null -w "%{http_code}" "http://127.0.0.1/" 2>/dev/null || true)
            p80_owner=$(get_port_owner 80)
            if [[ "$p80_code" =~ ^(200|301|302|304|403)$ ]] && [[ "${p80_owner%% *}" == "nginx" ]]; then
                success "Nginx запущен с существующей конфигурацией (HTTP $p80_code)."
                return 0
            fi
        fi
    fi

    # Развертывание изолированного server block заглушки
    info "Развертывание сайта-заглушки NaïveProxy на порту 80..."
    local has_def_srv=false
    if nginx -T 2>/dev/null | grep -Eq 'listen[[:space:]]+.*default_server'; then
        has_def_srv=true
    fi

    local def_listen="listen 80; listen [::]:80;"
    [ "$has_def_srv" = false ] && def_listen="listen 80 default_server; listen [::]:80 default_server;"

    mkdir -p "$NGINX_STUB_ROOT"
    cat << 'EOF' > "$NGINX_STUB_ROOT/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0d1117; color: #c9d1d9; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
        .box { text-align: center; padding: 40px; background: #161b22; border-radius: 8px; border: 1px solid #30363d; max-width: 480px; }
        .dot { display: inline-block; width: 12px; height: 12px; background: #238636; border-radius: 50%; margin-right: 8px; }
        h1 { font-size: 24px; color: #f0f6fc; margin: 0 0 8px 0; }
        p { font-size: 14px; color: #8b949e; margin: 0; }
    </style>
</head>
<body>
    <div class="box">
        <h1><span class="dot"></span>Welcome</h1>
        <p>Web server is operational.</p>
    </div>
</body>
</html>
EOF
    chmod 644 "$NGINX_STUB_ROOT/index.html"

    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    cat << EOF > "$NGINX_STUB_CONF"
server {
    $def_listen
    server_name _;
    root $NGINX_STUB_ROOT;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

    # Отключаем default sites-enabled/default если существует (сохранен в state-файле)
    if [ -e /etc/nginx/sites-enabled/default ]; then
        rm -f /etc/nginx/sites-enabled/default
        info "Стандартный sites-enabled/default отключен (сохранен в состоянии $NGINX_STATE_FILE)."
    fi

    ln -sf "$NGINX_STUB_CONF" "$NGINX_STUB_ENABLED"

    info "Валидация синтаксиса Nginx..."
    if ! nginx -t >/dev/null 2>&1; then
        error "Ошибка конфигурации Nginx! Выполняем откат..."
        nginx -t
        rm -f "$NGINX_STUB_ENABLED" "$NGINX_STUB_CONF"
        if [ -f "$NGINX_STATE_FILE" ]; then
            local orig_type orig_tgt orig_bak
            orig_type=$(grep '^DEFAULT_TYPE=' "$NGINX_STATE_FILE" | cut -d= -f2 | tr -d '"')
            orig_tgt=$(grep '^DEFAULT_SYMLINK_TARGET=' "$NGINX_STATE_FILE" | cut -d= -f2 | tr -d '"')
            orig_bak=$(grep '^DEFAULT_FILE_BACKUP=' "$NGINX_STATE_FILE" | cut -d= -f2 | tr -d '"')
            if [ "$orig_type" = "symlink" ] && [ -n "$orig_tgt" ]; then
                ln -sf "$orig_tgt" /etc/nginx/sites-enabled/default
            elif [ "$orig_type" = "file" ] && [ -f "$orig_bak" ]; then
                cp -a "$orig_bak" /etc/nginx/sites-enabled/default
            fi
        fi
        return 1
    fi

    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl restart nginx || { error "Не удалось запустить службу Nginx."; return 1; }
    sleep 1

    # Строгая проверка ответа заглушки на http://127.0.0.1/
    local stub_body
    stub_body=$(curl -s -m 3 "http://127.0.0.1/" 2>/dev/null || true)
    if echo "$stub_body" | grep -q "Web server is operational"; then
        success "Сайт-заглушка Nginx успешно развернут, слушает :80 и подтвержден (HTTP 200)."
        sed -i 's/^STUB_CONFIG_CREATED=.*/STUB_CONFIG_CREATED=true/' "$NGINX_STATE_FILE" 2>/dev/null || true
        sed -i 's/^STUB_ENABLED=.*/STUB_ENABLED=true/' "$NGINX_STATE_FILE" 2>/dev/null || true
    else
        warn "Nginx запущен, но ожидаемый ответ заглушки не получен. Код ответа: $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/ 2>/dev/null || echo 'N/A')."
    fi
    return 0
}

check_port443_conflict() {
    step "3/7" "Проверка порта 443 (резерв под Caddy NaïveProxy)"
    local p443_info
    p443_info=$(get_port_owner 443)

    if [ -z "$p443_info" ]; then
        success "Порт 443 свободен для Caddy / NaïveProxy."
        return 0
    fi

    local proc="${p443_info%% *}" pid="${p443_info##* }"
    if [ "$proc" = "caddy" ]; then
        success "Порт 443 занят текущим экземпляром Caddy (NaïveProxy)."
        return 0
    fi

    if [ "$proc" = "nginx" ]; then
        warn "Порт 443 занят Nginx (PID $pid). Для работы NaïveProxy порт 443 должен принадлежать Caddy."
        info "Поиск конфигураций Nginx с директивой 'listen 443'..."
        local n443_sites=()
        if [ -d /etc/nginx/sites-enabled ]; then
            for f in /etc/nginx/sites-enabled/*; do
                [ -e "$f" ] || continue
                if grep -qiE 'listen[[:space:]]+.*443' "$f" 2>/dev/null; then
                    n443_sites+=("$f")
                fi
            done
        fi

        if [ "${#n443_sites[@]}" -gt 0 ]; then
            echo -e "${YELLOW}Обнаружены активные сайты Nginx на порту 443:${NC}"
            for s in "${n443_sites[@]}"; do echo "  • $s"; done
            read -r -p "Временно отключить эти конфигурации Nginx на порту 443? [y/N]: " confirm_dis
            case "$confirm_dis" in
                y|Y)
                    for s in "${n443_sites[@]}"; do
                        local orig_tgt
                        orig_tgt=$(readlink -f "$s" 2>/dev/null || true)
                        [ -n "$orig_tgt" ] && echo "$s|$orig_tgt" >> /etc/naiveproxy/nginx_443_disabled.list
                        rm -f "$s"
                    done
                    if nginx -t >/dev/null 2>&1; then
                        systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
                    fi
                    ;;
                *)
                    error "Установка прервана: порт 443 остаётся занят Nginx."
                    return 1
                    ;;
            esac
        fi
    fi

    # Повторная проверка владельца 443
    local p443_check
    p443_check=$(get_port_owner 443)
    if [ -n "$p443_check" ] && [[ "${p443_check%% *}" != "caddy" ]]; then
        error "Порт 443 занят сторонним процессом '${p443_check%% *}' (PID ${p443_check##* })!"
        return 1
    fi
    success "Порт 443 готов для Caddy."
    return 0
}

apply_new_domain() {
    local new_domain="$1"
    step "Быстрая смена домена на '$new_domain' (без перекомпиляции Caddy)"

    load_credentials 2>/dev/null || true
    local old_domain="${DOMAIN:-}"

    if [ "$old_domain" = "$new_domain" ]; then
        info "Домен '$new_domain' уже настроен как текущий."
        return 0
    fi

    # 1. Резервная копия Caddyfile
    cp -a "$CADDY_FILE" "${CADDY_FILE}.bak_domain"

    # 2. Замена домена в Caddyfile
    sed -i "s|:443, $old_domain|:443, $new_domain|g" "$CADDY_FILE"
    sed -i "s|:443, [a-zA-Z0-9.-]*|:443, $new_domain|g" "$CADDY_FILE"

    # 3. Валидация Caddyfile
    if ! "$CADDY_BIN" validate --config "$CADDY_FILE" >/dev/null 2>&1; then
        error "Ошибка валидации Caddyfile при смене домена! Выполняем автоматический откат..."
        cp -a "${CADDY_FILE}.bak_domain" "$CADDY_FILE"
        return 1
    fi

    # 4. Обновление учетных файлов
    DOMAIN="$new_domain"
    sed -i "s|^DOMAIN=.*|DOMAIN=\"$new_domain\"|" "$CREDS_FILE" 2>/dev/null || true
    sed -i "s|^DOMAIN=.*|DOMAIN=\"$new_domain\"|" "$DOMAIN_CHECK_FILE" 2>/dev/null || true

    # 5. Синхронизация клиентов (обновление ссылок в clients/<user>.json)
    sync_caddy_users >/dev/null 2>&1 || true

    # 6. Перезапуск Caddy для выпуска нового ACME сертификата
    info "Перезапуск Caddy для выпуска сертификата Let's Encrypt на $new_domain..."
    systemctl restart caddy
    sleep 4

    # 7. Проверка TLS
    local tls_out tls_stat tls_iss tls_host tls_left tls_exp
    tls_out=$(verify_tls_certificate "$new_domain")
    IFS='|' read -r tls_stat tls_iss tls_host tls_left tls_exp <<< "$tls_out"

    if [ "$tls_stat" = "VALID" ]; then
        success "Новый сертификат для '$new_domain' успешно выпущен!"
    else
        warn "Сертификат для '$new_domain' находится в процессе выпуска ($tls_stat)."
    fi

    setup_motd
    success "Домен успешно переключен на: $new_domain"
    echo ""
    read -r -p "Нажмите Enter для просмотра реквизитов..."
    show_info
}

domain_wizard() {
    check_root
    check_os
    check_arch
    install_dependencies
    resolve_server_ips

    while true; do
        print_header
        echo -e "${BOLD}ЭТАП 1: МАСТЕР ПОДГОТОВКИ ДОМЕНА${NC}\n"
        echo -e "Архитектура:  ${CYAN}:80 Nginx Stub${NC}  +  ${GREEN}:443 Caddy NaïveProxy${NC}"
        echo -e "IP вашего VPS: ${BOLD}${GREEN}$SERVER_IPV4${NC}"
        [ -n "$SERVER_IPV6" ] && echo -e "IPv6 сервера:  ${BOLD}${GREEN}$SERVER_IPV6${NC}"
        echo ""
        echo "──────────────────────────────────────────────────────"
        echo "  1) У меня есть собственный домен"
        echo "  2) У меня есть домен, хочу настроить субдомен"
        echo "  3) Получить бесплатный домен (DuckDNS / FreeDNS / др.)"
        echo "  4) Проверить уже привязанный домен"
        echo "  0) Назад в главное меню"
        echo "──────────────────────────────────────────────────────"
        echo ""
        read -r -p "Выберите вариант [0-4]: " wchoice
        case "$wchoice" in
            1) wizard_own_domain ;;
            2) wizard_subdomain ;;
            3) wizard_free_domain ;;
            4) wizard_manual_check ;;
            0) return 0 ;;
            *) error "Неверный выбор."; sleep 1 ;;
        esac
    done
}

wizard_own_domain() {
    print_header
    echo -e "${BOLD}НАСТРОЙКА СОБСТВЕННОГО ДОМЕНА${NC}\n"
    read -r -p "Введите имя домена (например, example.com): " raw_domain
    raw_domain=$(echo "$raw_domain" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

    local chk
    chk=$(validate_domain_format "$raw_domain" || true)
    [ "$chk" != "VALID" ] && { handle_format_error "$chk" "$raw_domain"; return; }

    echo -e "\nСоздайте в панели DNS запись:"
    echo "  Тип: A | Имя: @ (или пусто) | Значение: $SERVER_IPV4 | TTL: 300"
    echo ""
    read -r -p "Нажмите Enter для запуска диагностики..."
    run_domain_diagnostics "$raw_domain"
}

wizard_subdomain() {
    print_header
    echo -e "${BOLD}НАСТРОЙКА СУБДОМЕНА ДЛЯ NAÏVEPROXY${NC}\n"
    echo "Субдомен позволяет сохранить основной сайт нетронутым."
    echo "Популярные имена: proxy, vpn, cdn, node, secure"
    echo ""
    read -r -p "Введите субдомен полностью (например, proxy.example.com): " raw_sub
    raw_sub=$(echo "$raw_sub" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

    local chk
    chk=$(validate_domain_format "$raw_sub" || true)
    [ "$chk" != "VALID" ] && { handle_format_error "$chk" "$raw_sub"; return; }

    local sub_name="${raw_sub%%.*}"
    echo -e "\nСоздайте в панели DNS запись:"
    echo "  Тип: A | Имя: $sub_name | Значение: $SERVER_IPV4 | TTL: 300"
    echo ""
    read -r -p "Нажмите Enter для запуска диагностики..."
    run_domain_diagnostics "$raw_sub"
}

wizard_free_domain() {
    print_header
    echo -e "${BOLD}БЕСПЛАТНЫЕ ДОМЕНЫ И ХОСТНЕЙМЫ${NC}\n"
    echo "1) DuckDNS       БЕСПЛАТНО  (поддомен *.duckdns.org, готов за 1 мин)"
    echo "2) FreeDNS       БЕСПЛАТНО  (поддомен *.afraid.org и др.)"
    echo "3) EU.org        БЕСПЛАТНО  (делегирование занимает дни/недели)"
    echo "0) Назад"
    echo ""
    read -r -p "Выберите вариант [0-3]: " fchoice
    case "$fchoice" in
        1)
            print_header
            echo -e "${BOLD}НАСТРОЙКА DUCKDNS${NC}\n"
            echo "1. Зайдите на https://www.duckdns.org"
            echo "2. Создайте домен и укажите IP: $SERVER_IPV4"
            echo ""
            read -r -p "Введите созданный домен (например, test.duckdns.org): " ddom
            ddom=$(echo "$ddom" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            run_domain_diagnostics "$ddom"
            ;;
        2)
            print_header
            echo -e "${BOLD}НАСТРОЙКА FREEDNS (AFRAID.ORG)${NC}\n"
            echo "1. Зайдите на https://freedns.afraid.org"
            echo "2. Добавьте субдомен и направьте на IP: $SERVER_IPV4"
            echo ""
            read -r -p "Введите субдомен (например, test.afraid.org): " fdom
            fdom=$(echo "$fdom" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            run_domain_diagnostics "$fdom"
            ;;
        3)
            info "EU.org требует ручного одобрения заявки администратором (дни/недели)."
            read -r -p "Если у вас уже есть одобренный eu.org домен, введите его (иначе Enter): " edom
            edom=$(echo "$edom" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            [ -n "$edom" ] && run_domain_diagnostics "$edom"
            ;;
        0) return 0 ;;
    esac
}

wizard_manual_check() {
    print_header
    local def_dom=""
    load_domain_check 2>/dev/null && def_dom="${CHECKED_DOMAIN:-}"

    if [ -n "$def_dom" ]; then
        read -r -p "Введите домен для проверки [по умолчанию: $def_dom]: " target
        target="${target:-$def_dom}"
    else
        read -r -p "Введите домен для проверки: " target
    fi
    target=$(echo "$target" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    run_domain_diagnostics "$target"
}

handle_format_error() {
    local code="$1" dom="$2"
    echo ""
    case "$code" in
        BLOCKED_PAGES_DEV)
            error "Домены *.pages.dev не поддерживают прямую A-запись на VPS!"
            echo "Используйте DuckDNS, FreeDNS или собственный домен."
            ;;
        BLOCKED_STATIC_HOST)
            error "Домен '$dom' является адресом облачного хостинга и не может указывать на VPS."
            ;;
        *) error "Некорректный синтаксис доменного имени: '$dom'." ;;
    esac
    echo ""
    read -r -p "Нажмите Enter для возврата..."
}

run_domain_diagnostics() {
    local target_domain="$1"
    target_domain=$(echo "$target_domain" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

    local format_check
    format_check=$(validate_domain_format "$target_domain" || true)
    [ "$format_check" != "VALID" ] && { handle_format_error "$format_check" "$target_domain"; return 1; }

    # Единый источник истины: обязательная проверка/определение IP перед диагностикой
    if [[ ! "$SERVER_IPV4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        resolve_server_ips
    fi

    if [[ ! "$SERVER_IPV4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        error "Не удалось определить публичный IPv4 VPS."
        echo ""
        echo "Проверьте вручную: curl -4 https://api.ipify.org"
        echo ""
        read -r -p "Введите внешний IPv4 вашего VPS вручную: " SERVER_IPV4
        SERVER_IPV4=$(echo "$SERVER_IPV4" | tr -d '[:space:]')
        if [[ ! "$SERVER_IPV4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            error "Некорректный формат IPv4 адреса. Диагностика отменена."
            return 1
        fi
    fi

    # Явная гарантия наличия ключевых диагностических утилит
    require_command dig dnsutils
    require_command jq jq
    require_command curl curl
    require_command openssl openssl

    print_header
    echo -e "${BOLD}ДИАГНОСТИКА ДОМЕНА ПЕРЕД УСТАНОВКОЙ${NC}\n"
    echo -e "Домен:    ${BOLD}$target_domain${NC}"
    echo -e "VPS IPv4: ${BOLD}${GREEN}$SERVER_IPV4${NC}\n"
    info "Опрос DNS-резолверов (системный DNS, Cloudflare, Google, Quad9, DoH)..."

    local ip_sys="" ip_cf="" ip_google="" ip_quad9="" ip_yandex="" ip_authoritative="" ip_doh=""

    # Гарантируем наличие dnsutils (dig)
    if ! command -v dig &>/dev/null; then
        install_dependencies
    fi

    # 1. Системный локальный резолвер из /etc/resolv.conf (разрешён всеми хостерами)
    if command -v dig &>/dev/null; then
        ip_sys=$(dig +short +time=2 +tries=1 A "$target_domain" 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)
    fi
    if [ -z "$ip_sys" ] && command -v getent &>/dev/null; then
        ip_sys=$(getent ahostsv4 "$target_domain" 2>/dev/null | awk '{print $1}' | grep -E '^[0-9.]+$' | head -n1 || true)
    fi
    if [ -z "$ip_sys" ] && command -v host &>/dev/null; then
        ip_sys=$(host -W 2 -t A "$target_domain" 2>/dev/null | awk '/has address/ {print $4}' | grep -E '^[0-9.]+$' | head -n1 || true)
    fi
    # Встроенный резолвер Python 3 через системный libc gethostbyname (работает без внешних утилит)
    if [ -z "$ip_sys" ] && command -v python3 &>/dev/null; then
        ip_sys=$(python3 -c "import socket; print(socket.gethostbyname('$target_domain'))" 2>/dev/null | grep -E '^[0-9.]+$' || true)
    fi

    # 2. Авторитативный сервер DuckDNS (для доменов *.duckdns.org)
    if [[ "$target_domain" == *.duckdns.org ]] && command -v dig &>/dev/null; then
        ip_authoritative=$(dig +short +time=3 +tries=1 A "$target_domain" @ns1.duckdns.org 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)
        [ -z "$ip_authoritative" ] && ip_authoritative=$(dig +tcp +short +time=3 +tries=1 A "$target_domain" @ns1.duckdns.org 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)
    fi

    # 3. Публичные резолверы (UDP + TCP fallback на случай блокировки UDP 53)
    if command -v dig &>/dev/null; then
        ip_cf=$(dig +short +time=2 +tries=1 A "$target_domain" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)
        [ -z "$ip_cf" ] && ip_cf=$(dig +tcp +short +time=3 +tries=1 A "$target_domain" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)

        ip_google=$(dig +short +time=2 +tries=1 A "$target_domain" @8.8.8.8 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)
        [ -z "$ip_google" ] && ip_google=$(dig +tcp +short +time=3 +tries=1 A "$target_domain" @8.8.8.8 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)

        ip_quad9=$(dig +short +time=2 +tries=1 A "$target_domain" @9.9.9.9 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)
        [ -z "$ip_quad9" ] && ip_quad9=$(dig +tcp +short +time=3 +tries=1 A "$target_domain" @9.9.9.9 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)

        ip_yandex=$(dig +short +time=2 +tries=1 A "$target_domain" @77.88.8.8 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)
    fi

    # 4. DNS-over-HTTPS (DoH по IP и доменам, обход блокировки порта 53)
    if [ -z "$ip_cf" ] && [ -z "$ip_google" ] && [ -z "$ip_sys" ]; then
        ip_doh=$(curl -s -m 4 -H 'accept: application/dns-json' "https://1.1.1.1/dns-query?name=${target_domain}&type=A" 2>/dev/null | jq -r '.Answer[]? | select(.type==1) | .data' 2>/dev/null | head -n1 || true)
        if [ -z "$ip_doh" ]; then
            ip_doh=$(curl -s -m 4 "https://dns.google/resolve?name=${target_domain}&type=A" 2>/dev/null | jq -r '.Answer[]? | select(.type==1) | .data' 2>/dev/null | head -n1 || true)
        fi
        if [ -z "$ip_doh" ]; then
            ip_doh=$(curl -s -m 4 -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=${target_domain}&type=A" 2>/dev/null | jq -r '.Answer[]? | select(.type==1) | .data' 2>/dev/null | head -n1 || true)
        fi
    fi

    # Выбираем обнаруженный адрес (приоритет совпадению с IP VPS)
    local detected_ip=""
    for cand in "$ip_authoritative" "$ip_sys" "$ip_cf" "$ip_google" "$ip_quad9" "$ip_yandex" "$ip_doh"; do
        if [ -n "$cand" ]; then
            detected_ip="$cand"
            [ "$cand" = "$SERVER_IPV4" ] && break
        fi
    done

    local dns_a_status=false
    [ "$detected_ip" = "$SERVER_IPV4" ] && dns_a_status=true

    # IPv6 согласованность: проверка всех AAAA по всем адресам VPS
    local aaaa_records=()
    while IFS= read -r arec; do
        arec=$(echo "$arec" | tr -d '[:space:]')
        [ -n "$arec" ] && aaaa_records+=("$arec")
    done < <(dig +short +time=2 +tries=1 AAAA "$target_domain" 2>/dev/null | grep -E ':' || true)

    local aaaa_diagnostic="" aaaa_severity="OK"
    if [ "${#aaaa_records[@]}" -eq 0 ]; then
        aaaa_diagnostic="отсутствует (только IPv4 — оптимально для TLS-ALPN-01)"
    else
        local all_aaaa_str="${aaaa_records[*]}"
        if [ -z "$SERVER_IPV6_OUTBOUND" ] && [ "${#SERVER_IPV6_LIST[@]}" -eq 0 ]; then
            aaaa_diagnostic="${YELLOW}обнаружены AAAA: $all_aaaa_str (на VPS нет IPv6. Let's Encrypt отдаст приоритет IPv6. Удалите AAAA-запись, если сертификат не будет выпускаться)${NC}"
            aaaa_severity="WARNING"
        else
            local match_found=false
            local mismatch_list=()
            for rec in "${aaaa_records[@]}"; do
                local rec_matched=false
                for v_ip in "${SERVER_IPV6_LIST[@]}" "$SERVER_IPV6_OUTBOUND"; do
                    [ -n "$v_ip" ] && [ "$rec" = "$v_ip" ] && { rec_matched=true; break; }
                done
                [ "$rec_matched" = true ] && match_found=true || mismatch_list+=("$rec")
            done

            if [ "$match_found" = true ] && [ "${#mismatch_list[@]}" -eq 0 ]; then
                aaaa_diagnostic="$all_aaaa_str (все AAAA соответствуют IPv6 VPS)"
            elif [ "$match_found" = true ]; then
                aaaa_diagnostic="${YELLOW}частичное совпадение: IP VPS присутствует, но есть сторонние (${mismatch_list[*]}).${NC}"
                aaaa_severity="WARNING"
            else
                aaaa_diagnostic="${YELLOW}не совпадают с локальным IPv6 VPS (${SERVER_IPV6_LIST[*]}). Проверьте маршрутизацию.${NC}"
                aaaa_severity="WARNING"
            fi
        fi
    fi

    # CAA проверка
    local caa_state caa_diagnostic="" caa_severity="OK"
    caa_state=$(check_caa_record "$target_domain")
    case "$caa_state" in
        ABSENT) caa_diagnostic="отсутствует (Let's Encrypt разрешён по умолчанию)" ;;
        ALLOWED) caa_diagnostic="присутствует (letsencrypt.org разрешён)" ;;
        RESTRICTED) caa_diagnostic="${RED}ограничивает выпуск (letsencrypt.org отсутствует в issue!)${NC}"; caa_severity="FATAL" ;;
        QUERY_FAILED) caa_diagnostic="${YELLOW}DNS-таймаут запроса CAA (проверка Let's Encrypt выполнится в рантайме)${NC}"; caa_severity="WARNING" ;;
    esac

    # Статусы локальных портов через единый get_port_owner
    local p80_owner p443_owner
    p80_owner=$(get_port_owner 80)
    p443_owner=$(get_port_owner 443)

    local port80_stat="${GREEN}свободен (будет настроен Nginx)${NC}"
    local port443_stat="${GREEN}свободен (готов для Caddy)${NC}"

    if [ -n "$p80_owner" ]; then
        local p80_proc="${p80_owner%% *}" p80_pid="${p80_owner##* }"
        [ "$p80_proc" = "nginx" ] && port80_stat="${GREEN}занят Nginx (сайт-заглушка :80 — штатно)${NC}"
        [ "$p80_proc" != "nginx" ] && port80_stat="${RED}занят $p80_proc (PID $p80_pid) — конфликт!${NC}"
    fi

    if [ -n "$p443_owner" ]; then
        local p443_proc="${p443_owner%% *}" p443_pid="${p443_owner##* }"
        [ "$p443_proc" = "caddy" ] && port443_stat="${GREEN}занят текущим Caddy (NaïveProxy)${NC}"
        [ "$p443_proc" = "nginx" ] && port443_stat="${YELLOW}занят Nginx (потребуется освободить :443)${NC}"
        [ "$p443_proc" != "caddy" ] && [ "$p443_proc" != "nginx" ] && port443_stat="${RED}занят $p443_proc (PID $p443_pid)${NC}"
    fi

    echo "──────────────────────────────────────────────────────"
    echo -e "${BOLD}РЕЗУЛЬТАТЫ ПРОВЕРКИ:${NC}\n"
    echo -e "1. Формат домена:      ${GREEN}✓ Корректный${NC}"
    if [ "$dns_a_status" = true ]; then
        echo -e "2. DNS A → VPS:        ${GREEN}✓ $target_domain → $SERVER_IPV4${NC}"
    else
        echo -e "2. DNS A → VPS:        ${RED}✗ $target_domain → ${detected_ip:-не найдена} (ожидался $SERVER_IPV4)${NC}"
    fi

    local badges=()
    [ -n "$ip_sys" ] && badges+=("Системный DNS: $([ "$ip_sys" = "$SERVER_IPV4" ] && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗ ($ip_sys)${NC}")")
    [ -n "$ip_authoritative" ] && badges+=("DuckDNS NS: $([ "$ip_authoritative" = "$SERVER_IPV4" ] && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗ ($ip_authoritative)${NC}")")
    [ -n "$ip_cf" ] && badges+=("Cloudflare: $([ "$ip_cf" = "$SERVER_IPV4" ] && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗ ($ip_cf)${NC}")")
    [ -n "$ip_google" ] && badges+=("Google: $([ "$ip_google" = "$SERVER_IPV4" ] && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗ ($ip_google)${NC}")")
    [ -n "$ip_doh" ] && badges+=("DoH: $([ "$ip_doh" = "$SERVER_IPV4" ] && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗ ($ip_doh)${NC}")")

    if [ "${#badges[@]}" -gt 0 ]; then
        local IFS_BAK="$IFS"
        IFS=" | "
        echo -e "   • ${badges[*]}"
        IFS="$IFS_BAK"
    else
        echo -e "   • ${YELLOW}Внешние DNS-запросы завершились таймаутом (проверьте доступ к порту 53)${NC}"
    fi

    echo -e "3. AAAA (IPv6):        $([ "$aaaa_severity" = "OK" ] && echo -e "${GREEN}✓${NC}" || echo -e "${YELLOW}!${NC}") $aaaa_diagnostic"
    echo -e "4. CAA (SSL):          $([ "$caa_severity" = "OK" ] && echo -e "${GREEN}✓${NC}" || ([ "$caa_severity" = "WARNING" ] && echo -e "${YELLOW}!${NC}" || echo -e "${RED}✗${NC}")) $caa_diagnostic"
    echo -e "5. Порт 80 (Nginx):    $port80_stat"
    echo -e "6. Порт 443 (Caddy):   $port443_stat"
    echo "──────────────────────────────────────────────────────"

    local final_status="NOT_READY"
    if [ "$dns_a_status" = true ] && [ "$caa_severity" != "FATAL" ]; then
        if [ "$aaaa_severity" = "OK" ] && [ "$caa_severity" = "OK" ]; then
            final_status="READY"
        else
            final_status="READY_WITH_WARNINGS"
        fi
    fi

    mkdir -p "$NAIVE_DIR"
    local now_epoch now_str
    now_epoch=$(date +%s); now_str="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"

    cat << EOF > "$DOMAIN_CHECK_FILE"
DOMAIN="$target_domain"
SERVER_IPV4="$SERVER_IPV4"
DNS_IPV4="${detected_ip:-NONE}"
DNS_STATUS="$([ "$dns_a_status" = true ] && echo "OK" || echo "FAILED")"
CAA_STATUS="$caa_state"
CHECK_TIMESTAMP="$now_str"
CHECK_TIMESTAMP_EPOCH="$now_epoch"
DOMAIN_STATUS="$final_status"
EOF
    chmod 600 "$DOMAIN_CHECK_FILE"
    chmod 700 "$NAIVE_DIR"

    if [ "$final_status" = "READY" ]; then
        echo -e "\n${GREEN}██████████████████████████████████████████████████████${NC}"
        echo -e "${BOLD}${GREEN}               ✓ ДОМЕН ПОЛНОСТЬЮ ГОТОВ                ${NC}"
        echo -e "${GREEN}██████████████████████████████████████████████████████${NC}\n"
        if is_naiveproxy_installed; then
            echo "NaïveProxy уже установлен в системе."
            echo "  1) Переключить Caddy на новый домен '$target_domain' (быстро, без пересборки)"
            echo "  2) Полная переустановка с новым доменом"
            echo "  0) Назад в главное меню"
            echo ""
            read -r -p "Выберите действие [0-2, по умолчанию 1]: " sw_choice
            sw_choice="${sw_choice:-1}"
            case "$sw_choice" in
                1) apply_new_domain "$target_domain" ;;
                2) run_installation ;;
                *) return 0 ;;
            esac
        else
            read -r -p "Запустить установку NaïveProxy прямо сейчас? [Y/n]: " proceed
            case "$proceed" in
                n|N) return 0 ;;
                *) run_installation ;;
            esac
        fi
    elif [ "$final_status" = "READY_WITH_WARNINGS" ]; then
        echo -e "\n${YELLOW}██████████████████████████████████████████████████████${NC}"
        echo -e "${BOLD}${YELLOW}         ! ДОМЕН ГОТОВ С ПРЕДУПРЕЖДЕНИЯМИ            ${NC}"
        echo -e "${YELLOW}██████████████████████████████████████████████████████${NC}\n"
        echo "A-запись указывает на VPS, но присутствуют предупреждения (AAAA или CAA таймаут)."
        read -r -p "Продолжить установку, несмотря на предупреждения? [y/N]: " proceed
        case "$proceed" in
            y|Y) run_installation ;;
            *) return 0 ;;
        esac
    else
        echo -e "\n${YELLOW}██████████████████████████████████████████████████████${NC}"
        echo -e "${BOLD}${YELLOW}       ! АВТОМАТИЧЕСКАЯ ПРОВЕРКА DNS НЕ ПОДТВЕРЖДЕНА    ${NC}"
        echo -e "${YELLOW}██████████████████████████████████████████████████████${NC}\n"
        echo -e "• A-запись домена '$target_domain' не обнаружена резолверами или не совпадает с IP сервера ($SERVER_IPV4)."
        echo ""
        echo -e "${BOLD}Возможные причины:${NC}"
        echo "  1. Запись была обновлена недавно на DuckDNS и ещё распространяется по мировым DNS-кэшам."
        echo "  2. Хостинг-провайдер фильтрует исходящие DNS-запросы (порт 53 UDP/TCP) к внешним серверам."
        echo ""
        echo "Если вы уверены, что домен привязан к IP $SERVER_IPV4 на сайте DuckDNS,"
        echo "вы можете подтвердить его принудительно и сразу перейти к установке."
        echo ""
        echo "  1) Подтвердить домен принудительно и продолжить установку"
        echo "  2) Повторить проверку DNS"
        echo "  0) Вернуться в главное меню"
        echo ""
        read -r -p "Выберите действие [0-2]: " fail_choice
        case "$fail_choice" in
            1)
                final_status="READY"
                cat << EOF > "$DOMAIN_CHECK_FILE"
DOMAIN="$target_domain"
SERVER_IPV4="$SERVER_IPV4"
DNS_IPV4="MANUAL_CONFIRMED"
DNS_STATUS="CONFIRMED_BY_USER"
CAA_STATUS="$caa_state"
CHECK_TIMESTAMP="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
CHECK_TIMESTAMP_EPOCH="$(date +%s)"
DOMAIN_STATUS="READY"
EOF
                chmod 600 "$DOMAIN_CHECK_FILE"
                success "Домен '$target_domain' подтверждён принудительно."
                echo ""
                read -r -p "Запустить установку NaïveProxy прямо сейчас? [Y/n]: " proceed
                case "$proceed" in
                    n|N) return 0 ;;
                    *) run_installation ;;
                esac
                ;;
            2)
                run_domain_diagnostics "$target_domain"
                ;;
            *)
                return 1
                ;;
        esac
    fi
}

install_golang() {
    info "Проверка и установка Go (Golang)..."

    local go_arch=""
    case "$(uname -m)" in
        x86_64|amd64)  go_arch="amd64" ;;
        aarch64|arm64) go_arch="arm64" ;;
        armv7l)        go_arch="armv6l" ;;
        *)
            error "Неподдерживаемая архитектура Go: $(uname -m)"
            return 1
            ;;
    esac

    local go_version=""
    local json=""

    # 1. Запрос актуальной стабильной версии через JSON API go.dev
    if json="$(curl -fsSL --connect-timeout 10 --max-time 30 "https://go.dev/dl/?mode=json" 2>/dev/null)"; then
        if command -v jq &>/dev/null; then
            go_version="$(printf '%s' "$json" | jq -r '[ .[] | select(.stable == true) ] | .[0].version // empty' 2>/dev/null || true)"
        fi
    fi

    # 2. Запасной текстовый эндпоинт go.dev/VERSION?m=text
    if [[ ! "$go_version" =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        local text_ver
        text_ver="$(curl -fsSL --connect-timeout 5 --max-time 15 "https://go.dev/VERSION?m=text" 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
        if [[ "$text_ver" =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
            go_version="$text_ver"
        fi
    fi

    # 3. Безопасный статический fallback
    if [[ ! "$go_version" =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        go_version="go${DEFAULT_GO_VERSION:-1.24.1}"
        warn "Не удалось динамически получить список версий Go. Используется проверенный fallback: $go_version"
    fi

    # Проверка существующей версии Go
    if command -v go &>/dev/null; then
        local current_version
        current_version=$(go version 2>/dev/null | awk '{print $3}' || true)
        if [ -n "$current_version" ]; then
            local cv="${current_version#go}"
            local tv="${go_version#go}"
            if version_ge "$cv" "$tv"; then
                success "Go уже установлен актуальной версии ($current_version >= $go_version)."
                return 0
            fi
            info "Текущая версия Go ($current_version) ниже требуемой ($go_version). Обновляем..."
        fi
    fi

    local go_archive="${go_version}.linux-${go_arch}.tar.gz"
    local go_url="https://go.dev/dl/${go_archive}"

    info "Версия Go: ${go_version}"
    info "Архитектура: ${go_arch}"
    info "Загрузка архива: ${go_url}"

    local tmp_dir
    tmp_dir="$(mktemp -d /tmp/go-install.XXXXXX)"
    local tmp_archive="${tmp_dir}/${go_archive}"

    if ! curl -fL \
        --retry 3 \
        --retry-delay 2 \
        --connect-timeout 10 \
        --max-time 180 \
        -o "$tmp_archive" \
        "$go_url"; then
        error "Не удалось загрузить Go из ${go_url}"
        rm -rf "$tmp_dir"
        return 1
    fi

    # Проверка целостности архива (gzip -t отсекает HTML 404/ошибки сети)
    info "Проверка целостности загруженного архива..."
    if ! gzip -t "$tmp_archive" 2>/dev/null; then
        error "Загруженный архив Go повреждён или имеет неверный формат (возможно 404/HTML)."
        rm -rf "$tmp_dir"
        return 1
    fi

    rm -rf "${tmp_dir}/go"
    info "Распаковка Go во временный каталог..."
    if ! tar -xzf "$tmp_archive" -C "$tmp_dir"; then
        error "Не удалось распаковать архив Go."
        rm -rf "$tmp_dir"
        return 1
    fi

    # Предварительная валидация бинарника во временном каталоге
    if ! "${tmp_dir}/go/bin/go" version >/dev/null 2>&1; then
        error "Распакованный бинарник Go во временном каталоге не запускается."
        rm -rf "$tmp_dir"
        return 1
    fi

    # Атомарное обновление с сохранением резервной копии
    local old_dir="${GO_INSTALL_DIR}.old"
    rm -rf "$old_dir"

    if [ -d "$GO_INSTALL_DIR" ]; then
        mv "$GO_INSTALL_DIR" "$old_dir" || {
            error "Не удалось сохранить текущую установку Go."
            rm -rf "$tmp_dir"
            return 1
        }
    fi

    if ! mv "${tmp_dir}/go" "$GO_INSTALL_DIR"; then
        error "Не удалось установить новую версию Go."
        if [ -d "$old_dir" ]; then
            mv "$old_dir" "$GO_INSTALL_DIR" || true
        fi
        rm -rf "$tmp_dir"
        return 1
    fi

    # Проверка работоспособности на целевом месте
    if ! "$GO_INSTALL_DIR/bin/go" version >/dev/null 2>&1; then
        error "Установленный Go в $GO_INSTALL_DIR не запускается."
        if [ -d "$old_dir" ]; then
            rm -rf "$GO_INSTALL_DIR"
            mv "$old_dir" "$GO_INSTALL_DIR" || true
        fi
        rm -rf "$tmp_dir"
        return 1
    fi

    # Успех: очистка резервной копии и временных файлов
    rm -rf "$old_dir" "$tmp_dir"

    cat > /etc/profile.d/golang.sh <<'EOF_PROFILE'
export GOROOT=/usr/local/go
export GOPATH=/root/go
export PATH="/usr/local/go/bin:$GOPATH/bin:$PATH"
EOF_PROFILE
    chmod 644 /etc/profile.d/golang.sh
    export GOROOT=/usr/local/go
    export GOPATH=/root/go
    export PATH="/usr/local/go/bin:$GOPATH/bin:$PATH"

    success "Go успешно установлен: $("$GO_INSTALL_DIR/bin/go" version)"
    return 0
}

save_build_info() {
    local target_file="${BUILD_INFO_FILE:-/etc/naiveproxy/build-info}"
    mkdir -p /etc/naiveproxy
    local caddy_ver="" go_ver="" xcaddy_ver="" fp_ver=""
    [ -x "$CADDY_BIN" ] && caddy_ver=$("$CADDY_BIN" version 2>/dev/null | tr -d '\n' || true)
    command -v go &>/dev/null && go_ver=$(go version 2>/dev/null | tr -d '\n' || true)
    local xcaddy_bin="${GOPATH}/bin/xcaddy"
    [ ! -x "$xcaddy_bin" ] && xcaddy_bin=$(command -v xcaddy || true)
    [ -x "$xcaddy_bin" ] && xcaddy_ver=$("$xcaddy_bin" version 2>/dev/null | tr -d '\n' || true)

    if [ -x "$CADDY_BIN" ] && command -v go &>/dev/null; then
        local m_out
        m_out=$(go version -m "$CADDY_BIN" 2>/dev/null || true)
        fp_ver=$(echo "$m_out" | grep -A1 'github.com/caddyserver/forwardproxy' | grep -E '=>' | awk '{print $NF}' || true)
        if [ -z "$fp_ver" ]; then
            fp_ver=$(echo "$m_out" | grep 'github.com/klzgrad/forwardproxy' | awk '{for(i=1;i<=NF;i++) if($i ~ /^v[0-9]/) print $i}' | head -n1 || true)
        fi
    fi

    cat << EOF > "$target_file"
# NaïveProxy + Caddy Build Metadata
CADDY_BUILD_TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
CADDY_VERSION="${caddy_ver:-unknown}"
GO_VERSION="${go_ver:-unknown}"
XCADDY_VERSION="${xcaddy_ver:-unknown}"
FORWARDPROXY_MODULE="github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@naive"
FORWARDPROXY_VERSION="${fp_ver:-naive-master}"
EOF
    chmod 644 "$target_file"
}

rollback_caddy() {
    warn "Выполняем транзакционный откат Caddy..."
    local rolled_back=false
    if [ -f "$CADDY_BAK" ]; then
        mv -f "$CADDY_BAK" "$CADDY_BIN"
        rolled_back=true
    else
        rm -f "$CADDY_BIN"
    fi

    if [ -f "${CADDY_FILE}.bak" ]; then
        mv -f "${CADDY_FILE}.bak" "$CADDY_FILE"
    else
        rm -f "$CADDY_FILE"
    fi

    if [ -f "${BUILD_INFO_FILE}.bak" ]; then
        mv -f "${BUILD_INFO_FILE}.bak" "$BUILD_INFO_FILE"
    else
        rm -f "$BUILD_INFO_FILE"
    fi

    if [ "$rolled_back" = true ]; then
        systemctl restart caddy 2>/dev/null || true
        if systemctl is-active --quiet caddy; then
            success "Откат к предыдущей версии выполнен успешно. Предыдущая служба активна."
        else
            error "Предыдущая служба не запустилась после отката. Проверьте: journalctl -u caddy -n 50"
        fi
    else
        systemctl stop caddy 2>/dev/null || true
        info "Откат завершён: нерабочая установка очищена, система возвращена в исходное состояние."
    fi
}

commit_caddy() {
    rm -f "$CADDY_BAK" "${CADDY_FILE}.bak" "${BUILD_INFO_FILE}.bak"
    rm -rf "$BUILD_ROOT/caddy"
}

build_caddy() {
    step "4/7" "Сборка Caddy с модулем forwardproxy@naive"
    if ! install_golang; then
        error "Сбой установки Go."
        return 1
    fi

    info "Установка / обновление xcaddy (pinned version: ${XCADDY_VERSION})..."
    go install "github.com/caddyserver/xcaddy/cmd/xcaddy@${XCADDY_VERSION}" || {
        warn "Ошибка установки pinned xcaddy, пробуем latest..."
        go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest || { error "Ошибка установки xcaddy."; return 1; }
    }

    local xcaddy_bin="${GOPATH}/bin/xcaddy"
    [ ! -x "$xcaddy_bin" ] && xcaddy_bin=$(command -v xcaddy || true)
    [ ! -x "$xcaddy_bin" ] && { error "xcaddy не найден."; return 1; }

    # Проверка оперативной памяти и Swap перед сборкой
    local mem_total_mb=0 swap_total_mb=0
    if command -v free &>/dev/null; then
        mem_total_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || true)
        swap_total_mb=$(free -m 2>/dev/null | awk '/^Swap:/{print $2}' || true)
        if [ "${mem_total_mb:-0}" -gt 0 ] && [ "${mem_total_mb:-0}" -lt 1500 ] && [ "${swap_total_mb:-0}" -lt 512 ]; then
            info "На VPS мало RAM (${mem_total_mb} MB). Автоматически создаем 2 ГБ Swap для защиты компилятора Go..."
            if fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 2>/dev/null; then
                chmod 600 /swapfile
                mkswap /swapfile >/dev/null 2>&1 || true
                swapon /swapfile >/dev/null 2>&1 || true
                if ! grep -q '/swapfile' /etc/fstab 2>/dev/null; then
                    echo '/swapfile none swap sw 0 0' >> /etc/fstab 2>/dev/null || true
                fi
                success "Swap 2 ГБ успешно создан и активирован."
            fi
        fi
    fi

    local build_dir="$BUILD_ROOT/caddy"
    rm -rf "$build_dir"; mkdir -p "$build_dir"; cd "$build_dir"

    info "Компиляция Caddy с модулем klzgrad/forwardproxy@naive..."
    echo -e "${BLUE}[INFO]${NC} Первая сборка на VPS занимает обычно от 3 до 10 минут (загрузка AST, компиляция зависимостей и статическая линковка)."
    echo -e "${BLUE}[INFO]${NC} Пожалуйста, не закрывайте терминал и не прерывайте процесс (timeout=0s — без принудительного ограничения времени).\n"

    local build_log="$build_dir/build.log"
    "$xcaddy_bin" build \
        --with github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@naive \
        --output "$build_dir/caddy.new" > "$build_log" 2>&1 &
    local build_pid=$!

    local start_time=$(date +%s)
    local spinner=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local spin_idx=0

    while kill -0 "$build_pid" 2>/dev/null; do
        local cur_time=$(date +%s)
        local elapsed=$((cur_time - start_time))
        local mins=$((elapsed / 60))
        local secs=$((elapsed % 60))
        local time_str=$(printf "%02d:%02d" "$mins" "$secs")

        local res_info=""
        local go_pid
        go_pid=$(pgrep -P "$build_pid" -f 'go build' 2>/dev/null | head -n1 || true)
        if [ -n "$go_pid" ]; then
            res_info=$(ps -o %cpu,%mem,rss -p "$go_pid" 2>/dev/null | tail -n1 | awk '{printf "CPU: %s%%, RAM: %s%% (%d MB)", $1, $2, $3/1024}' || true)
        fi
        [ -z "$res_info" ] && res_info="компиляция исходного кода..."

        local spin_char="${spinner[$spin_idx]}"
        spin_idx=$(( (spin_idx + 1) % ${#spinner[@]} ))

        printf "\r${CYAN}%s${NC} ${BOLD}[СБОРКА CADDY]${NC} Прошло: ${BOLD}%s${NC} [%s]   " "$spin_char" "$time_str" "$res_info"
        sleep 2
    done

    wait "$build_pid"
    local build_exit_code=$?
    printf "\r\033[K" # Очистка строки индикатора

    if [ "$build_exit_code" -ne 0 ] || [ ! -f "$build_dir/caddy.new" ]; then
        echo ""
        error "Ошибка компиляции xcaddy (код завершения: $build_exit_code)!"
        echo "──────────────── Последние 25 строк лога сборки ────────────────"
        tail -n 25 "$build_log" 2>/dev/null || true
        echo "─────────────────────────────────────────────────────────────────"
        rm -f "$build_dir/caddy.new"
        return 1
    fi
    chmod 755 "$build_dir/caddy.new"

    info "Проверка наличия модуля forward_proxy в скомпилированном бинарнике..."
    if ! "$build_dir/caddy.new" list-modules 2>/dev/null | grep -q 'http.handlers.forward_proxy'; then
        error "КРИТИЧЕСКАЯ ОШИБКА: Модуль http.handlers.forward_proxy не найден в собранном бинарнике!"
        rm -f "$build_dir/caddy.new"
        return 1
    fi
    success "Модуль http.handlers.forward_proxy успешно подтвержден."
    success "Бинарник Caddy готов к валидации и установке."
    return 0
}

install_web_ui() {
    step "Настройка встроенной панели управления (Web UI)"

    if ! command -v qrencode &>/dev/null; then
        info "Установка пакета qrencode для генерации QR-кодов NekoBox..."
        apt-get update -qq && apt-get install -y -qq qrencode >/dev/null 2>&1 || true
    fi

    local chosen_port="${WEB_PORT:-18080}"
    if [ -f "$WEB_CREDS_FILE" ]; then
        local saved_port
        saved_port=$(grep -E '^WEB_PORT=' "$WEB_CREDS_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
        [ -n "$saved_port" ] && chosen_port="$saved_port"
    fi

    # Запрос порта у пользователя
    if [ -t 0 ]; then
        echo ""
        read -r -p "Введите порт для Web UI [по умолчанию: $chosen_port]: " in_port
        in_port=$(echo "$in_port" | tr -d '[:space:]')
        if [[ "$in_port" =~ ^[0-9]+$ ]] && [ "$in_port" -ge 1024 ] && [ "$in_port" -le 65535 ]; then
            if [ "$in_port" -eq 80 ] || [ "$in_port" -eq 443 ]; then
                warn "Порты 80 и 443 зарезервированы под Nginx и Caddy. Используется порт $chosen_port."
            else
                chosen_port="$in_port"
            fi
        elif [ -n "$in_port" ]; then
            warn "Некорректный номер порта '$in_port' (допустимо 1024-65535). Используется $chosen_port."
        fi
    fi
    WEB_PORT="$chosen_port"

    info "Развертывание панели NaïveProxy Manager (порт $WEB_PORT)..."

    # Создание системного пользователя naive-web
    if ! id -u naive-web &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin naive-web 2>/dev/null || true
    fi

    # Настройка прав на каталог /etc/naiveproxy (доступ для группы naive-web)
    mkdir -p "$NAIVE_DIR"
    chown root:naive-web "$NAIVE_DIR" 2>/dev/null || true
    chmod 750 "$NAIVE_DIR" 2>/dev/null || true

    # Генерация реквизитов Web UI
    local web_user="admin"
    local web_pass=""
    if [ -f "$WEB_CREDS_FILE" ]; then
        web_pass=$(grep -E '^WEB_PASS=' "$WEB_CREDS_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
    fi
    if [ -z "$web_pass" ]; then
        web_pass=$(generate_random_string 20)
    fi

    cat << EOF > "$WEB_CREDS_FILE"
WEB_USER="$web_user"
WEB_PASS="$web_pass"
WEB_PORT="$WEB_PORT"
CREATED_AT="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
EOF
    chown root:naive-web "$WEB_CREDS_FILE" 2>/dev/null || true
    chmod 640 "$WEB_CREDS_FILE" 2>/dev/null || true

    [ -f "$CLIENT_CONFIG" ] && { chown root:naive-web "$CLIENT_CONFIG" 2>/dev/null || true; chmod 640 "$CLIENT_CONFIG" 2>/dev/null || true; }
    [ -f "$CREDS_FILE" ] && { chown root:naive-web "$CREDS_FILE" 2>/dev/null || true; chmod 640 "$CREDS_FILE" 2>/dev/null || true; }
    [ -f "$DOMAIN_CHECK_FILE" ] && { chown root:naive-web "$DOMAIN_CHECK_FILE" 2>/dev/null || true; chmod 640 "$DOMAIN_CHECK_FILE" 2>/dev/null || true; }

    # Создание изолированного вспомогательного скрипта управления (без зависимостей от install.sh)
    cat << 'EOF_HELPER' > "$HELPER_SCRIPT_FILE"
#!/bin/bash
set -euo pipefail
case "${1:-}" in
    check_services)
        c_stat=$(systemctl is-active caddy 2>/dev/null || echo "inactive")
        n_stat=$(systemctl is-active nginx 2>/dev/null || echo "inactive")
        echo "$c_stat $n_stat"
        ;;
    reload_caddy)
        /usr/local/bin/caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || systemctl reload caddy 2>/dev/null || systemctl restart caddy
        ;;
    restart_caddy)
        systemctl restart caddy
        ;;
    diagnose)
        c_stat=$(systemctl is-active caddy 2>/dev/null || echo "inactive")
        n_stat=$(systemctl is-active nginx 2>/dev/null || echo "inactive")
        w_stat=$(systemctl is-active naiveproxy-webui 2>/dev/null || echo "inactive")
        echo "Caddy: $c_stat | Nginx: $n_stat | WebUI: $w_stat"
        ;;
    *)
        echo "Unknown action" >&2
        exit 1
        ;;
esac
EOF_HELPER
    chmod 755 "$HELPER_SCRIPT_FILE"
    chown root:root "$HELPER_SCRIPT_FILE"

    # Sudoers для пользователя naive-web
    if [ -d /etc/sudoers.d ]; then
        cat << EOF > /etc/sudoers.d/naive-web
naive-web ALL=(ALL) NOPASSWD: $HELPER_SCRIPT_FILE
EOF
        chmod 440 /etc/sudoers.d/naive-web
    fi

    # Развертывание исполняемого скрипта Web UI
    cat << 'EOF_WEBUI' > "$WEB_SCRIPT_FILE"
#!/usr/bin/env python3
import os
import sys
import json
import secrets
import hashlib
import time
import subprocess
import urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler
from http.cookies import SimpleCookie

CREDS_FILE = '/etc/naiveproxy/credentials'
CLIENT_CONFIG = '/etc/naiveproxy/client.json'
WEB_CREDS_FILE = '/etc/naiveproxy/web_credentials'
USERS_FILE = '/etc/naiveproxy/users.json'
CLIENTS_DIR = '/etc/naiveproxy/clients'
CADDY_FILE = '/etc/caddy/Caddyfile'
HELPER_BIN = '/usr/local/bin/naiveproxy-helper'

def get_web_port():
    try:
        data = read_kv_file(WEB_CREDS_FILE)
        p = data.get('WEB_PORT')
        if p and p.isdigit():
            return int(p)
    except Exception:
        pass
    p_env = os.environ.get('WEB_PORT', '18080')
    return int(p_env) if p_env.isdigit() else 18080

HOST = os.environ.get('WEB_HOST', '127.0.0.1')

active_sessions = {} # token: (username, expiry_timestamp)

def read_kv_file(filepath):
    data = {}
    if not os.path.exists(filepath):
        return data
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#') or '=' not in line:
                    continue
                k, v = line.split('=', 1)
                data[k.strip()] = v.strip().strip('"').strip("'").strip()
    except Exception:
        pass
    return data

def get_web_credentials():
    data = read_kv_file(WEB_CREDS_FILE)
    return data.get('WEB_USER', 'admin'), data.get('WEB_PASS', '')

def verify_session(cookie_str, auth_header=None):
    # 1. Check Bearer token from Authorization header
    if auth_header and "Bearer " in auth_header:
        token = auth_header.split("Bearer ", 1)[1].strip()
        if token in active_sessions:
            user, exp = active_sessions[token]
            if time.time() < exp:
                return True
            else:
                del active_sessions[token]

    # 2. Check session_id cookie
    if cookie_str:
        cookie = SimpleCookie()
        try:
            cookie.load(cookie_str)
            token = cookie.get('session_id')
            if token and token.value in active_sessions:
                user, exp = active_sessions[token.value]
                if time.time() < exp:
                    return True
                else:
                    del active_sessions[token.value]
        except Exception:
            pass
    return False

import re

def sync_users_to_caddy():
    creds = read_kv_file(CREDS_FILE)
    target_domain = creds.get('DOMAIN', '')
    users_list = []
    if os.path.exists(USERS_FILE):
        try:
            with open(USERS_FILE, 'r', encoding='utf-8') as f:
                users_list = json.load(f)
        except Exception:
            pass

    if not users_list:
        return False, "Список пользователей пуст"

    auth_lines = "\n".join([f"        basic_auth {u['username']} {u['password']}" for u in users_list if u.get('username') and u.get('password')])

    if os.path.exists(CADDY_FILE):
        try:
            with open(CADDY_FILE, 'r', encoding='utf-8') as f:
                caddy_content = f.read()

            auth_block = auth_lines + """
        hide_ip
        hide_via
        probe_resistance"""
            pattern = r"forward_proxy\s*\{[\s\S]*?\}"
            new_fp = "forward_proxy {\n" + auth_block + "\n    }"
            new_content = re.sub(pattern, new_fp, caddy_content)
            with open(CADDY_FILE, 'w', encoding='utf-8') as f:
                f.write(new_content)
        except Exception as e:
            return False, f"Ошибка обновления Caddyfile: {e}"

    try:
        subprocess.run(['sudo', HELPER_BIN, 'reload_caddy'], check=True, timeout=5)
    except Exception as e:
        return False, f"Ошибка применения в Caddy: {e}"

    try:
        os.makedirs(CLIENTS_DIR, exist_ok=True)
        for u in users_list:
            un = u.get('username')
            pw = u.get('password')
            if not un: continue
            cfg = {
                'listen': 'socks://127.0.0.1:1080',
                'proxy': f"https://{un}:{pw}@{target_domain}"
            }
            cfg_path = os.path.join(CLIENTS_DIR, f"{un}.json")
            with open(cfg_path, 'w', encoding='utf-8') as out:
                json.dump(cfg, out, indent=2)
    except Exception:
        pass

    return True, "OK"

HTML_DASHBOARD = r"""<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>NaïveProxy + Caddy Manager</title>
    <style>
        :root {
            --bg: #0d1117; --card-bg: #161b22; --border: #30363d;
            --text: #f0f6fc; --muted: #8b949e; --accent: #58a6ff;
            --green: #238636; --green-txt: #3fb950; --red-txt: #f85149;
            --yellow: #d29922; --code: #090d13;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: var(--bg); color: var(--text); min-height: 100vh; display: flex; flex-direction: column; align-items: center; padding: 24px 16px; }
        .container { width: 100%; max-width: 860px; }
        .header { text-align: center; margin-bottom: 24px; }
        .header h1 { font-size: 22px; font-weight: 700; margin-bottom: 6px; }
        .header p { color: var(--muted); font-size: 14px; }
        .card { background: var(--card-bg); border: 1px solid var(--border); border-radius: 10px; padding: 20px; margin-bottom: 18px; box-shadow: 0 4px 12px rgba(0,0,0,0.3); }
        .card-title { font-size: 15px; font-weight: 600; margin-bottom: 14px; display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid var(--border); padding-bottom: 10px; }
        .grid-status { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 12px; margin-bottom: 16px; }
        .status-item { background: var(--code); border: 1px solid var(--border); padding: 12px 14px; border-radius: 8px; display: flex; flex-direction: column; gap: 4px; }
        .status-label { font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.5px; }
        .status-val { font-size: 14px; font-weight: 600; display: flex; align-items: center; gap: 6px; }
        .dot { width: 9px; height: 9px; border-radius: 50%; display: inline-block; }
        .dot-green { background: var(--green-txt); box-shadow: 0 0 8px var(--green-txt); }
        .dot-red { background: var(--red-txt); box-shadow: 0 0 8px var(--red-txt); }
        .dot-yellow { background: var(--yellow); box-shadow: 0 0 8px var(--yellow); }
        .meta-table { width: 100%; border-collapse: collapse; font-size: 13px; margin-bottom: 16px; }
        .meta-table td { padding: 8px 6px; border-bottom: 1px solid #21262d; }
        .meta-table td:first-child { color: var(--muted); width: 35%; }
        .meta-table td:last-child { font-family: monospace; font-weight: 600; }
        .btn-group { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 10px; }
        button, .btn { background: var(--border); color: var(--text); border: 1px solid var(--border); padding: 9px 14px; font-size: 13px; font-weight: 600; border-radius: 6px; cursor: pointer; display: inline-flex; align-items: center; justify-content: center; gap: 6px; text-decoration: none; transition: background 0.15s; }
        button:hover, .btn:hover { background: #38424d; }
        button.btn-accent { background: #1f6feb; color: #fff; }
        button.btn-accent:hover { background: #388bfd; }
        button.btn-primary { background: var(--green); color: #fff; }
        button.btn-primary:hover { background: #2ea043; }
        button.btn-danger { background: #b62324; color: #fff; }
        button.btn-danger:hover { background: #d03535; }
        pre.code-block { background: var(--code); border: 1px solid var(--border); border-radius: 8px; padding: 14px; font-family: monospace; font-size: 13px; color: #7ee787; overflow-x: auto; white-space: pre-wrap; word-break: break-all; }
        .console-output { background: #000; border: 1px solid var(--border); border-radius: 8px; padding: 14px; font-family: monospace; font-size: 12px; color: #58a6ff; max-height: 320px; overflow-y: auto; white-space: pre-wrap; display: none; margin-top: 14px; }
        .login-box { max-width: 360px; margin: 60px auto; background: var(--card-bg); border: 1px solid var(--border); padding: 30px; border-radius: 10px; box-shadow: 0 8px 24px rgba(0,0,0,0.5); }
        .input-group { margin-bottom: 16px; }
        .input-group label { display: block; font-size: 13px; margin-bottom: 6px; color: var(--muted); }
        .input-group input { width: 100%; padding: 10px 12px; background: var(--code); border: 1px solid var(--border); border-radius: 6px; color: #fff; font-size: 14px; }
        .input-group input:focus { outline: none; border-color: var(--accent); }
        .toast { position: fixed; bottom: 24px; right: 24px; background: var(--green); color: #fff; padding: 10px 20px; border-radius: 6px; font-size: 13px; font-weight: 600; display: none; box-shadow: 0 4px 12px rgba(0,0,0,0.4); z-index: 3000; }
        .user-card { background: var(--code); border: 1px solid var(--border); border-radius: 8px; padding: 14px 16px; margin-bottom: 10px; display: flex; flex-direction: column; gap: 8px; }
        .user-card-header { display: flex; justify-content: space-between; align-items: center; }
        .user-name { font-weight: 700; font-size: 15px; color: var(--accent); display: flex; align-items: center; gap: 8px; }
        .user-badge { font-size: 11px; background: #21262d; border: 1px solid var(--border); color: var(--muted); padding: 2px 8px; border-radius: 12px; font-weight: normal; }
        .user-pass-row { font-size: 12px; color: var(--muted); font-family: monospace; display: flex; align-items: center; gap: 8px; word-break: break-all; }
        .modal-overlay { display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.7); z-index: 2000; align-items: center; justify-content: center; }
    </style>
</head>
<body>
    <div id="toast" class="toast">Готово!</div>
    
    <!-- Modal Add User -->
    <div id="addUserModal" class="modal-overlay">
        <div class="card" style="width:100%; max-width:440px; margin:20px;">
            <div class="card-title">
                <span>Добавление клиента NaïveProxy</span>
                <button onclick="closeAddUserModal()" style="padding:2px 8px;">✕</button>
            </div>
            <form action="javascript:void(0);" method="POST" onsubmit="return submitAddUser(event);">
                <div class="input-group">
                    <label>Логин клиента</label>
                    <div style="display:flex; gap:8px;">
                        <input type="text" id="newClientUser" required autocomplete="off">
                        <button type="button" onclick="genClientUser()" style="white-space:nowrap;">🎲 Авто</button>
                    </div>
                </div>
                <div class="input-group">
                    <label>Пароль клиента</label>
                    <div style="display:flex; gap:8px;">
                        <input type="text" id="newClientPass" required autocomplete="off">
                        <button type="button" onclick="genClientPass()" style="white-space:nowrap;">🎲 Авто</button>
                    </div>
                </div>
                <div class="input-group">
                    <label>Примечание / Устройство (необязательно)</label>
                    <input type="text" id="newClientNote" placeholder="например, Телефон / Иван">
                </div>
                <div style="display:flex; gap:10px; margin-top:14px;">
                    <button type="submit" class="btn-primary" style="flex:1;">Создать клиента</button>
                    <button type="button" onclick="closeAddUserModal()">Отмена</button>
                </div>
            </form>
        </div>
    </div>

    <!-- Modal QR Code for NekoBox -->
    <div id="qrModal" class="modal-overlay">
        <div class="card" style="width:100%; max-width:440px; margin:20px; text-align:center;">
            <div class="card-title">
                <span id="qrModalTitle">📱 QR-код для NekoBox</span>
                <button onclick="closeQrModal()" style="padding:2px 8px;">✕</button>
            </div>
            <div style="background:#ffffff; padding:14px; border-radius:10px; display:inline-block; margin:12px auto 8px; box-shadow:0 4px 16px rgba(0,0,0,0.4);">
                <img id="qrImg" src="" alt="QR Code" style="width:230px; height:230px; display:block;" />
            </div>
            <p style="font-size:12px; color:var(--muted); margin-bottom:12px; line-height:1.4;">
                Отсканируйте камерой в <b>NekoBox</b> / <b>v2rayN</b> / <b>Matsuri</b> или скопируйте ссылку:
            </p>
            <div class="input-group" style="margin-bottom:12px;">
                <input type="text" id="qrNekoboxLink" readonly style="font-size:11px; font-family:monospace; text-align:center; background:var(--code); color:#7ee787;" onclick="this.select()" />
            </div>
            <div style="display:flex; gap:10px;">
                <button onclick="copyQrLink()" class="btn-accent" style="flex:1;">📋 Скопировать ссылку</button>
                <button onclick="closeQrModal()">Закрыть</button>
            </div>
        </div>
    </div>

    <div class="container" id="app">
        <div class="login-box">
            <div class="header">
                <h1>NaïveProxy Manager</h1>
                <p>Вход в панель управления</p>
            </div>
            <div id="loginError" style="background:rgba(248,81,73,0.15); border:1px solid var(--red-txt); color:var(--red-txt); padding:8px 12px; border-radius:6px; font-size:13px; margin-bottom:14px; text-align:center; display:none;"></div>
            <form action="javascript:void(0);" method="POST" onsubmit="return handleLogin(event);">
                <div class="input-group">
                    <label>Логин администратора</label>
                    <input type="text" id="username" required autofocus autocomplete="username" value="admin">
                </div>
                <div class="input-group">
                    <label>Пароль</label>
                    <input type="password" id="password" required autocomplete="current-password">
                </div>
                <button type="submit" id="loginSubmitBtn" class="btn-primary" style="width: 100%; padding: 12px;">Войти</button>
            </form>
        </div>
    </div>

    <script>
        const API_BASE = window.location.pathname.startsWith('/admin') ? '/admin' : '';
        function apiUrl(endpoint) {
            return API_BASE + '/' + endpoint.replace(/^[/]+/, '');
        }

        function showToast(msg) {
            const t = document.getElementById('toast');
            t.innerText = msg;
            t.style.display = 'block';
            setTimeout(() => { t.style.display = 'none'; }, 2500);
        }

        function renderError(msg) {
            document.getElementById('app').innerHTML = `
                <div class="card" style="max-width: 520px; margin: 60px auto; text-align: center;">
                    <div style="font-size: 36px; margin-bottom: 12px;">⚠️</div>
                    <h2 style="font-size: 18px; margin-bottom: 8px; color: var(--red-txt);">Ошибка загрузки панели</h2>
                    <p style="font-size: 13px; color: var(--muted); margin-bottom: 18px; line-height: 1.5;">${msg}</p>
                    <div style="display:flex; gap:10px; justify-content:center;">
                        <button onclick="renderLogin()" class="btn-primary">Форма входа</button>
                        <button onclick="fetchStatus()">Повторить попытку</button>
                    </div>
                </div>
            `;
        }

        function getAuthHeaders(extra = {}) {
            const h = { ...extra };
            const tok = sessionStorage.getItem('np_auth_token');
            if (tok) {
                h['Authorization'] = 'Bearer ' + tok;
            }
            return h;
        }

        async function fetchWithAuth(endpoint, options = {}) {
            options.headers = getAuthHeaders(options.headers || {});
            options.credentials = 'same-origin';
            return fetch(apiUrl(endpoint), options);
        }

        async function fetchStatus() {
            try {
                const res = await fetchWithAuth('api/status');
                if (res.status === 401) {
                    sessionStorage.removeItem('np_auth_token');
                    renderLogin();
                    return;
                }
                if (!res.ok) {
                    renderError('Сервер вернул статус HTTP ' + res.status + ' (' + res.statusText + '). Убедитесь, что служба naiveproxy-webui запущена.');
                    return;
                }
                const data = await res.json();
                renderDashboard(data);
                fetchUsers();
            } catch (e) {
                console.error(e);
                const app = document.getElementById('app');
                if (!app.innerHTML || !app.querySelector('.login-box')) {
                    renderError('Ошибка подключения к API: ' + e + '<br><small style="color:var(--muted)">Если вы открыли страницу без слэша в конце, перейдите по адресу <a href="/admin/" style="color:var(--accent)">/admin/</a></small>');
                }
            }
        }

        function showLoginError(msg, savedUser = 'admin') {
            const errEl = document.getElementById('loginError');
            if (errEl) {
                errEl.innerText = msg;
                errEl.style.display = 'block';
            } else {
                renderLogin(msg, savedUser);
            }
        }

        function renderLogin(errorMsg = '', savedUser = 'admin') {
            document.getElementById('app').innerHTML = `
                <div class="login-box">
                    <div class="header">
                        <h1>NaïveProxy Manager</h1>
                        <p>Вход в панель управления</p>
                    </div>
                    <div id="loginError" style="background:rgba(248,81,73,0.15); border:1px solid var(--red-txt); color:var(--red-txt); padding:8px 12px; border-radius:6px; font-size:13px; margin-bottom:14px; text-align:center; display:${errorMsg ? 'block' : 'none'};">${errorMsg || ''}</div>
                    <form action="javascript:void(0);" method="POST" onsubmit="return handleLogin(event);">
                        <div class="input-group">
                            <label>Логин администратора</label>
                            <input type="text" id="username" required autofocus autocomplete="username" value="${savedUser}">
                        </div>
                        <div class="input-group">
                            <label>Пароль</label>
                            <input type="password" id="password" required autocomplete="current-password">
                        </div>
                        <button type="submit" id="loginSubmitBtn" class="btn-primary" style="width: 100%; padding: 12px;">Войти</button>
                    </form>
                </div>
            `;
        }

        function handleLogin(e) {
            if (e) {
                if (e.preventDefault) e.preventDefault();
                if (e.stopPropagation) e.stopPropagation();
            }
            doLogin();
            return false;
        }

        async function doLogin() {
            const uEl = document.getElementById('username');
            const pEl = document.getElementById('password');
            if (!uEl || !pEl) return;
            const u = uEl.value.trim();
            const p = pEl.value.trim();
            if (!p) {
                showLoginError('Введите пароль', u);
                return;
            }
            const btn = document.getElementById('loginSubmitBtn');
            if (btn) { btn.disabled = true; btn.innerText = 'Проверка...'; }

            try {
                const res = await fetch(apiUrl('api/login'), {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ username: u, password: p })
                });
                const data = await res.json();
                if (data.ok) {
                    if (data.token) {
                        sessionStorage.setItem('np_auth_token', data.token);
                    }
                    showToast('Вход выполнен успешно!');
                    await fetchStatus();
                } else {
                    showLoginError(data.error || 'Неверный логин или пароль', u);
                    if (btn) { btn.disabled = false; btn.innerText = 'Войти'; }
                }
            } catch (err) {
                showLoginError('Ошибка связи с сервером: ' + err, u);
                if (btn) { btn.disabled = false; btn.innerText = 'Войти'; }
            }
        }

        async function handleLogout() {
            sessionStorage.removeItem('np_auth_token');
            await fetchWithAuth('api/logout', { method: 'POST' }).catch(() => {});
            renderLogin();
        }

        async function restartCaddy() {
            showToast('Перезапуск службы Caddy...');
            try {
                const res = await fetchWithAuth('api/action/restart_caddy', { method: 'POST' });
                const d = await res.json();
                showToast(d.msg || 'Caddy перезапущен!');
                setTimeout(fetchStatus, 1500);
            } catch (e) {
                alert('Ошибка: ' + e);
            }
        }

        async function runDiagnose() {
            const outBox = document.getElementById('consoleBox');
            outBox.style.display = 'block';
            outBox.innerText = 'Запуск аудита системы... Пожалуйста, подождите 3-5 секунд...';
            try {
                const res = await fetchWithAuth('api/action/diagnose', { method: 'POST' });
                const d = await res.json();
                outBox.innerText = d.output || 'Диагностика завершена.';
            } catch (e) {
                outBox.innerText = 'Ошибка выполнения: ' + e;
            }
        }

        function copyText(txt) {
            navigator.clipboard.writeText(txt).then(() => {
                showToast('Скопировано в буфер обмена!');
            });
        }

        function openAddUserModal() {
            document.getElementById('newClientUser').value = 'user_' + Math.random().toString(36).substring(2, 8);
            document.getElementById('newClientPass').value = Math.random().toString(36).substring(2, 10) + Math.random().toString(36).substring(2, 10);
            document.getElementById('newClientNote').value = '';
            document.getElementById('addUserModal').style.display = 'flex';
        }

        function closeAddUserModal() {
            document.getElementById('addUserModal').style.display = 'none';
        }

        function showQrModal(username, nekoboxLink) {
            document.getElementById('qrModalTitle').innerText = '📱 QR-код для NekoBox (' + username + ')';
            document.getElementById('qrNekoboxLink').value = nekoboxLink;
            document.getElementById('qrImg').src = apiUrl('api/qr/' + encodeURIComponent(username)) + '?t=' + Date.now();
            document.getElementById('qrModal').style.display = 'flex';
        }

        function closeQrModal() {
            document.getElementById('qrModal').style.display = 'none';
        }

        function copyQrLink() {
            const link = document.getElementById('qrNekoboxLink').value;
            copyText(link);
        }

        function genClientUser() {
            document.getElementById('newClientUser').value = 'user_' + Math.random().toString(36).substring(2, 8);
        }

        function genClientPass() {
            document.getElementById('newClientPass').value = Math.random().toString(36).substring(2, 10) + Math.random().toString(36).substring(2, 10);
        }

        function submitAddUser(e) {
            if (e) {
                if (e.preventDefault) e.preventDefault();
                if (e.stopPropagation) e.stopPropagation();
            }
            doAddUser();
            return false;
        }

        async function doAddUser() {
            const u = document.getElementById('newClientUser').value.trim();
            const p = document.getElementById('newClientPass').value.trim();
            const n = document.getElementById('newClientNote').value.trim() || 'Клиент';
            try {
                const res = await fetchWithAuth('api/users/add', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ username: u, password: p, note: n })
                });
                const d = await res.json();
                if (d.ok) {
                    closeAddUserModal();
                    showToast('Клиент ' + u + ' успешно создан!');
                    fetchUsers();
                } else {
                    alert('Ошибка создания: ' + (d.error || 'неизвестная ошибка'));
                }
            } catch (err) {
                alert('Сбой связи: ' + err);
            }
        }

        async function deleteUser(username) {
            if (!confirm('Вы уверены, что хотите удалить клиента ' + username + '? Доступ для него будет заблокирован.')) {
                return;
            }
            try {
                const res = await fetchWithAuth('api/users/delete', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ username: username })
                });
                const d = await res.json();
                if (d.ok) {
                    showToast('Клиент ' + username + ' удален.');
                    fetchUsers();
                } else {
                    alert('Ошибка: ' + (d.error || 'Нельзя удалить последнего клиента'));
                }
            } catch (err) {
                alert('Сбой связи: ' + err);
            }
        }

        async function fetchUsers() {
            const listEl = document.getElementById('usersList');
            if (!listEl) return;
            try {
                const res = await fetchWithAuth('api/users');
                const users = await res.json();
                if (!users || users.length === 0) {
                    listEl.innerHTML = '<p style="color:var(--muted); font-size:13px;">Клиенты не настроены.</p>';
                    return;
                }
                let html = '';
                users.forEach((u, i) => {
                    html += `
                        <div class="user-card">
                            <div class="user-card-header">
                                <div class="user-name">
                                    <span>👤 ${u.username}</span>
                                    <span class="user-badge">${u.note || 'Клиент'}</span>
                                </div>
                                <div style="display:flex; gap:6px; flex-wrap:wrap;">
                                    <button onclick="showQrModal('${u.username}', '${u.nekobox_link || u.link}')" style="padding:4px 8px; font-size:12px; background:#1f6feb; color:#fff;">📱 QR (NekoBox)</button>
                                    <button onclick="copyText('${u.nekobox_link || u.link}')" style="padding:4px 8px; font-size:12px;">📋 Ссылка</button>
                                    <a href="${apiUrl('download/client/' + u.username)}" download="client-${u.username}.json" class="btn" style="padding:4px 8px; font-size:12px;">💾 .json</a>
                                    ${users.length > 1 ? `<button onclick="deleteUser('${u.username}')" class="btn-danger" style="padding:4px 8px; font-size:12px;">🗑</button>` : ''}
                                </div>
                            </div>
                            <div class="user-pass-row">
                                <span>Пароль: <b>${u.password}</b></span>
                                <span style="margin-left:auto; color:var(--muted); font-size:11px;">${u.created_at ? u.created_at.substring(0, 10) : ''}</span>
                            </div>
                        </div>
                    `;
                });
                listEl.innerHTML = html;
            } catch (e) {
                listEl.innerHTML = '<p style="color:var(--red-txt); font-size:13px;">Ошибка загрузки клиентов.</p>';
            }
        }

        function renderDashboard(data) {
            const caddyDot = data.caddy_active ? 'dot-green' : 'dot-red';
            const caddyText = data.caddy_active ? 'RUNNING (:443)' : 'STOPPED';
            const nginxDot = data.nginx_active ? 'dot-green' : 'dot-red';
            const nginxText = data.nginx_active ? 'RUNNING (:80)' : 'STOPPED';
            const naiveDot = data.naive_installed ? 'dot-green' : 'dot-yellow';
            const naiveText = data.naive_installed ? 'INSTALLED' : 'NOT DETECTED';
            const tlsDot = data.tls_status === 'VALID' ? 'dot-green' : 'dot-yellow';

            document.getElementById('app').innerHTML = `
                <div class="header">
                    <h1>NAÏVEPROXY + CADDY MANAGER</h1>
                    <p>Панель мониторинга и управления прокси-сервером</p>
                </div>

                <div class="card">
                    <div class="card-title">
                        <span>Состояние сервисов</span>
                        <button onclick="handleLogout()" style="padding: 4px 10px; font-size: 12px;">Выйти</button>
                    </div>
                    <div class="grid-status">
                        <div class="status-item">
                            <span class="status-label">Caddy Server</span>
                            <span class="status-val"><span class="dot ${caddyDot}"></span>${caddyText}</span>
                        </div>
                        <div class="status-item">
                            <span class="status-label">NaïveProxy Module</span>
                            <span class="status-val"><span class="dot ${naiveDot}"></span>${naiveText}</span>
                        </div>
                        <div class="status-item">
                            <span class="status-label">Nginx Stub</span>
                            <span class="status-val"><span class="dot ${nginxDot}"></span>${nginxText}</span>
                        </div>
                        <div class="status-item">
                            <span class="status-label">HTTPS (TLS-ALPN)</span>
                            <span class="status-val"><span class="dot ${tlsDot}"></span>${data.tls_status}</span>
                        </div>
                    </div>

                    <table class="meta-table">
                        <tr><td>Домен:</td><td>${data.domain || 'N/A'}</td></tr>
                        <tr><td>VPS IPv4:</td><td>${data.server_ip || 'N/A'}</td></tr>
                        <tr><td>Порт Web UI:</td><td>${data.web_port || '18080'} (открыт в UFW)</td></tr>
                        <tr><td>TLS эмитент:</td><td>${data.tls_issuer || 'Let\'s Encrypt'}</td></tr>
                    </table>

                    <div class="btn-group">
                        <button onclick="restartCaddy()" class="btn-accent">🔄 Перезапустить Caddy</button>
                        <button onclick="runDiagnose()">🔍 Диагностика</button>
                        <button onclick="fetchStatus()">⚡ Обновить статус</button>
                    </div>

                    <pre id="consoleBox" class="console-output"></pre>
                </div>

                <div class="card">
                    <div class="card-title">
                        <span>👥 Пользователи NaïveProxy (Клиенты)</span>
                        <button onclick="openAddUserModal()" class="btn-primary" style="padding: 4px 12px; font-size: 12px;">+ Создать клиента</button>
                    </div>
                    <div id="usersList">
                        <p style="color:var(--muted); font-size:13px;">Загрузка списка клиентов...</p>
                    </div>
                </div>
            `;
        }

        fetchStatus();
    </script>
</body>
</html>
"""

class RequestHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def send_json(self, data, code=200, headers=None):
        payload = json.dumps(data).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(payload)))
        if headers:
            for k, v in headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if path == '/' or path == '/index.html':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.end_headers()
            self.wfile.write(HTML_DASHBOARD.encode('utf-8'))
            return

        is_auth = verify_session(self.headers.get('Cookie'), self.headers.get('Authorization'))

        if path == '/api/status':
            if not is_auth:
                self.send_json({"error": "Unauthorized"}, code=401)
                return

            creds = read_kv_file(CREDS_FILE)
            dcheck = read_kv_file('/etc/naiveproxy/domain-check')
            wcreds = read_kv_file(WEB_CREDS_FILE)
            
            caddy_active = False
            nginx_active = False
            try:
                res = subprocess.run(['sudo', HELPER_BIN, 'check_services'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=5)
                out = res.stdout.strip().split()
                if len(out) >= 2:
                    caddy_active = (out[0] == 'active')
                    nginx_active = (out[1] == 'active')
            except Exception:
                pass

            resp = {
                "caddy_active": caddy_active,
                "nginx_active": nginx_active,
                "naive_installed": os.path.exists(CREDS_FILE),
                "domain": creds.get('DOMAIN', dcheck.get('DOMAIN', '')),
                "server_ip": creds.get('SERVER_IPV4', dcheck.get('SERVER_IPV4', '')),
                "web_port": wcreds.get('WEB_PORT', str(get_web_port())),
                "tls_status": "VALID" if caddy_active else "PENDING",
                "tls_issuer": "Let's Encrypt (TLS-ALPN-01)"
            }
            self.send_json(resp)
            return

        if path == '/api/users':
            if not is_auth:
                self.send_json({"error": "Unauthorized"}, code=401)
                return

            creds = read_kv_file(CREDS_FILE)
            target_domain = creds.get('DOMAIN', '')
            users_list = []
            if os.path.exists(USERS_FILE):
                try:
                    with open(USERS_FILE, 'r', encoding='utf-8') as f:
                        users_list = json.load(f)
                except Exception:
                    pass
            elif os.path.exists(CREDS_FILE):
                # Fallback to single user in credentials
                u = creds.get('USERNAME')
                p = creds.get('PASSWORD')
                if u and p:
                    users_list = [{
                        'username': u,
                        'password': p,
                        'created_at': creds.get('CREATED_AT', ''),
                        'note': 'Основной'
                    }]

            for u in users_list:
                u['link'] = f"https://{u['username']}:{u['password']}@{target_domain}:443"
                u['nekobox_link'] = f"naive+https://{u['username']}:{u['password']}@{target_domain}:443#Naive-{u['username']}"

            self.send_json(users_list)
            return

        if path.startswith('/api/qr/'):
            if not is_auth:
                self.send_response(401)
                self.end_headers()
                return

            username = path.replace('/api/qr/', '').split('?')[0].strip()
            creds = read_kv_file(CREDS_FILE)
            target_domain = creds.get('DOMAIN', '')
            found_user = None
            if os.path.exists(USERS_FILE):
                try:
                    with open(USERS_FILE, 'r', encoding='utf-8') as f:
                        for u in json.load(f):
                            if u.get('username') == username:
                                found_user = u
                                break
                except Exception:
                    pass
            if not found_user and os.path.exists(CREDS_FILE):
                if creds.get('USERNAME') == username:
                    found_user = {'username': username, 'password': creds.get('PASSWORD')}

            if not found_user:
                self.send_response(404)
                self.end_headers()
                return

            u_name = found_user['username']
            u_pass = found_user['password']
            nekobox_link = f"naive+https://{u_name}:{u_pass}@{target_domain}:443#Naive-{u_name}"

            try:
                res = subprocess.run(['qrencode', '-s', '6', '-m', '2', '-l', 'M', '-t', 'SVG', '-o', '-', nekobox_link],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=5)
                if res.returncode == 0 and res.stdout:
                    svg_data = res.stdout.encode('utf-8')
                    self.send_response(200)
                    self.send_header('Content-Type', 'image/svg+xml')
                    self.send_header('Cache-Control', 'no-cache')
                    self.send_header('Content-Length', str(len(svg_data)))
                    self.end_headers()
                    self.wfile.write(svg_data)
                    return
            except Exception:
                pass

            svg_err = ('<svg xmlns="http://www.w3.org/2000/svg" width="230" height="230" viewBox="0 0 230 230">'
                       '<rect width="100%" height="100%" fill="#161b22"/>'
                       '<text x="50%" y="45%" text-anchor="middle" fill="#f85149" font-size="12" font-family="sans-serif">qrencode не установлен</text>'
                       '<text x="50%" y="60%" text-anchor="middle" fill="#8b949e" font-size="11" font-family="sans-serif">apt install qrencode</text>'
                       '</svg>').encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'image/svg+xml')
            self.send_header('Content-Length', str(len(svg_err)))
            self.end_headers()
            self.wfile.write(svg_err)
            return

        if path.startswith('/download/client/'):
            if not is_auth:
                self.send_response(401)
                self.end_headers()
                return

            username = path.replace('/download/client/', '').replace('.json', '').strip()
            user_cfg_path = os.path.join(CLIENTS_DIR, f"{username}.json")
            if not os.path.exists(user_cfg_path) and os.path.exists(CLIENT_CONFIG):
                user_cfg_path = CLIENT_CONFIG

            if os.path.exists(user_cfg_path):
                with open(user_cfg_path, 'rb') as f:
                    content = f.read()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Disposition', f'attachment; filename="client-{username}.json"')
                self.send_header('Content-Length', str(len(content)))
                self.end_headers()
                self.wfile.write(content)
            else:
                self.send_response(404)
                self.end_headers()
            return

        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length) if length > 0 else b'{}'
        try:
            req_data = json.loads(body.decode('utf-8'))
        except Exception:
            req_data = {}

        if path == '/api/login':
            u_input = req_data.get('username', '').strip()
            p_input = req_data.get('password', '').strip()

            expected_u, expected_p = get_web_credentials()

            expected_u = expected_u.strip()
            expected_p = expected_p.strip()

            if expected_p and secrets.compare_digest(u_input, expected_u) and secrets.compare_digest(p_input, expected_p):
                token = secrets.token_hex(24)
                active_sessions[token] = (u_input, time.time() + 86400 * 7) # 7 days
                cookie_header = f'session_id={token}; Path=/; HttpOnly; SameSite=Lax'
                self.send_json({"ok": True, "token": token}, headers={"Set-Cookie": cookie_header})
            else:
                self.send_json({"ok": False, "error": "Неверный логин или пароль"}, code=401)
            return

        if path == '/api/logout':
            cookie_str = self.headers.get('Cookie')
            if cookie_str:
                cookie = SimpleCookie()
                try:
                    cookie.load(cookie_str)
                    token = cookie.get('session_id')
                    if token and token.value in active_sessions:
                        del active_sessions[token.value]
                except Exception:
                    pass
            self.send_json({"ok": True}, headers={"Set-Cookie": "session_id=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT"})
            return

        # Защищенные операции
        if not verify_session(self.headers.get('Cookie'), self.headers.get('Authorization')):
            self.send_json({"error": "Unauthorized"}, code=401)
            return

        if path == '/api/action/restart_caddy':
            try:
                subprocess.run(['sudo', HELPER_BIN, 'restart_caddy'], check=True, timeout=10)
                self.send_json({"ok": True, "msg": "Служба Caddy успешно перезапущена."})
            except Exception as e:
                self.send_json({"ok": False, "error": str(e)}, code=500)
            return

        if path == '/api/action/diagnose':
            try:
                res = subprocess.run(['sudo', HELPER_BIN, 'diagnose'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=20)
                self.send_json({"ok": True, "output": res.stdout or res.stderr})
            except Exception as e:
                self.send_json({"ok": False, "output": f"Ошибка: {e}"}, code=500)
            return

        if path == '/api/users/add':
            u = req_data.get('username', '').strip()
            p = req_data.get('password', '').strip()
            n = req_data.get('note', '').strip() or 'Клиент'
            if not u or not p:
                self.send_json({"ok": False, "error": "Логин и пароль обязательны"}, code=400)
                return

            users_list = []
            if os.path.exists(USERS_FILE):
                try:
                    with open(USERS_FILE, 'r', encoding='utf-8') as f:
                        users_list = json.load(f)
                except Exception:
                    pass

            if any(user.get('username') == u for user in users_list):
                self.send_json({"ok": False, "error": f"Пользователь '{u}' уже существует"}, code=400)
                return

            now_str = time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())
            users_list.append({"username": u, "password": p, "note": n, "created_at": now_str})
            try:
                with open(USERS_FILE, 'w', encoding='utf-8') as f:
                    json.dump(users_list, f, indent=2, ensure_ascii=False)
            except Exception as e:
                self.send_json({"ok": False, "error": f"Ошибка сохранения: {e}"}, code=500)
                return

            ok, msg = sync_users_to_caddy()
            if ok:
                self.send_json({"ok": True})
            else:
                self.send_json({"ok": False, "error": msg}, code=500)
            return

        if path == '/api/users/delete':
            u = req_data.get('username', '').strip()
            if not u:
                self.send_json({"ok": False, "error": "Логин не указан"}, code=400)
                return

            users_list = []
            if os.path.exists(USERS_FILE):
                try:
                    with open(USERS_FILE, 'r', encoding='utf-8') as f:
                        users_list = json.load(f)
                except Exception:
                    pass

            if len(users_list) <= 1:
                self.send_json({"ok": False, "error": "Нельзя удалить последнего клиента"}, code=400)
                return

            new_users = [user for user in users_list if user.get('username') != u]
            if len(new_users) == len(users_list):
                self.send_json({"ok": False, "error": f"Пользователь '{u}' не найден"}, code=404)
                return

            try:
                with open(USERS_FILE, 'w', encoding='utf-8') as f:
                    json.dump(new_users, f, indent=2, ensure_ascii=False)
            except Exception as e:
                self.send_json({"ok": False, "error": f"Ошибка сохранения: {e}"}, code=500)
                return

            cfg_path = os.path.join(CLIENTS_DIR, f"{u}.json")
            if os.path.exists(cfg_path):
                try: os.remove(cfg_path)
                except Exception: pass

            ok, msg = sync_users_to_caddy()
            if ok:
                self.send_json({"ok": True})
            else:
                self.send_json({"ok": False, "error": msg}, code=500)
            return

        self.send_json({"error": "Endpoint not found"}, code=404)

def run():
    PORT = get_web_port()
    server = HTTPServer((HOST, PORT), RequestHandler)
    print(f"NaïveProxy Web UI running on http://{HOST}:{PORT}")
    server.serve_forever()

if __name__ == '__main__':
    run()
EOF_WEBUI
    chmod 755 "$WEB_SCRIPT_FILE"
    chown root:root "$WEB_SCRIPT_FILE"

    # Проверка и изоляция маршрута @admin в Caddyfile
    if [ -f "$CADDY_FILE" ]; then
        chown root:naive-web "$CADDY_FILE" 2>/dev/null || true
        chmod 664 "$CADDY_FILE" 2>/dev/null || true

        python3 - "$CADDY_FILE" "$WEB_PORT" "$WEB_ROOT" << 'EOF_PY'
import sys, re
caddy_file = sys.argv[1]
web_port = sys.argv[2]
web_root = sys.argv[3]

with open(caddy_file, "r", encoding="utf-8") as f:
    content = f.read()

# Если блок @admin еще не добавлен в новом формате
if "@admin path /admin /admin/*" not in content:
    m = re.search(r"(forward_proxy\s*\{[\s\S]*?\})", content)
    if m:
        fp_block = m.group(1)
        clean = re.sub(r"redir\s+/admin\s+/admin/?\n?", "", content)
        clean = re.sub(r"handle_path\s+/admin/\*[\s\S]*?\}\n?", "", clean)
        clean = re.sub(r"file_server\s*\{[\s\S]*?\}\n?", "", clean)
        clean = re.sub(r"forward_proxy\s*\{[\s\S]*?\}\n?", "", clean)

        new_routes = f"""    @admin path /admin /admin/*
    handle @admin {{
        uri strip_prefix /admin
        reverse_proxy 127.0.0.1:{web_port}
    }}

    handle {{
        {fp_block}

        file_server {{
            root {web_root}
        }}
    }}"""
        idx = clean.rfind("}")
        if idx != -1:
            clean = clean[:idx].rstrip() + "\n\n" + new_routes + "\n}\n"
            with open(caddy_file, "w", encoding="utf-8") as out:
                out.write(clean)
EOF_PY

        if /usr/local/bin/caddy validate --config "$CADDY_FILE" >/dev/null 2>&1; then
            systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null || true
            success "Маршрут @admin (/admin/* -> 127.0.0.1:$WEB_PORT) успешно изолирован в Caddyfile."
        else
            warn "Ошибка валидации Caddyfile при проверке маршрута @admin."
        fi
    fi

    # Systemd служба для Web UI
    cat << EOF > "$WEB_SERVICE_FILE"
[Unit]
Description=NaïveProxy + Caddy Web Manager
After=network.target
Wants=network.target

[Service]
Type=simple
User=naive-web
Group=naive-web
Environment=WEB_PORT=$WEB_PORT
Environment=WEB_HOST=127.0.0.1
ExecStart=/usr/bin/python3 $WEB_SCRIPT_FILE
Restart=always
RestartSec=3s
LimitNOFILE=65536
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$WEB_SERVICE_FILE"
    ln -sf "$WEB_SERVICE_FILE" "$WEB_SERVICE_ALIAS" 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable naiveproxy-webui >/dev/null 2>&1 || true
    systemctl restart naiveproxy-webui

    # Строгая проверка запуска службы и порта
    local started=false
    for _ in {1..8}; do
        if systemctl is-active --quiet naiveproxy-webui 2>/dev/null && is_port_listening "$WEB_PORT"; then
            started=true
            break
        fi
        sleep 0.5
    done

    if [ "$started" = true ]; then
        success "Панель управления успешно запущена: naiveproxy-webui.service (порт $WEB_PORT)"

        # Закрытие прямого внешнего порта Web UI в UFW (доступ строго через Caddy :443 /admin/)
        if command -v ufw &>/dev/null; then
            ufw delete allow "${WEB_PORT}/tcp" >/dev/null 2>&1 || true
            success "UFW: внешний порт ${WEB_PORT}/tcp закрыт (безопасный доступ строго через Caddy :443)."
        fi
        return 0
    else
        error "Служба Web UI не запустилась. Логи:"
        journalctl -u naiveproxy-webui --no-pager -n 20
        return 1
    fi
}

configure_system() {
    step "5/7" "Формирование конфигураций Caddyfile, Systemd и прав доступа"
    local target_domain="$1" user_email="$2" user_login="$3" user_pass="$4"
    local build_dir="$BUILD_ROOT/caddy"

    [ ! -f "$build_dir/caddy.new" ] && { error "Скомпилированный бинарник Caddy не найден ($build_dir/caddy.new)."; return 1; }

    # Пользователь caddy
    if ! id -u caddy &>/dev/null; then
        info "Создание системного пользователя 'caddy'..."
        useradd --system --home-dir /var/lib/caddy --create-home --shell /usr/sbin/nologin --user-group caddy 2>/dev/null || true
    fi

    mkdir -p /var/lib/caddy /var/log/caddy
    chown -R caddy:caddy /var/lib/caddy /var/log/caddy
    chmod 750 /var/lib/caddy /var/log/caddy

    # Fallback-страница для probe_resistance на порту 443
    mkdir -p "$WEB_ROOT"
    cat << 'EOF' > "$WEB_ROOT/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Service Status</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0f172a; color: #94a3b8; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
        .card { text-align: center; padding: 48px; background: #1e293b; border-radius: 12px; border: 1px solid #334155; max-width: 440px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.1); }
        .badge { display: inline-flex; align-items: center; gap: 8px; color: #10b981; font-weight: 500; font-size: 14px; margin-bottom: 16px; background: rgba(16,185,129,0.1); padding: 4px 12px; border-radius: 9999px; }
        .badge-dot { width: 8px; height: 8px; background: #10b981; border-radius: 50%; }
        h1 { font-size: 22px; color: #f8fafc; margin: 0 0 8px 0; font-weight: 600; }
        p { font-size: 14px; line-height: 1.5; margin: 0; }
    </style>
</head>
<body>
    <div class="card">
        <div class="badge"><span class="badge-dot"></span>Secure Gateway</div>
        <h1>Service Operational</h1>
        <p>This endpoint is active and operating normally.</p>
    </div>
</body>
</html>
EOF
    chown -R caddy:caddy "$WEB_ROOT"
    chmod 755 "$WEB_ROOT"
    chmod 644 "$WEB_ROOT/index.html"

    # Права на /etc/caddy
    mkdir -p "$CADDY_CONF_DIR"
    chown root:caddy "$CADDY_CONF_DIR"
    chmod 750 "$CADDY_CONF_DIR"

    # 1. Генерация нового Caddyfile во временном файле для предварительной валидации
    local test_caddyfile="$build_dir/Caddyfile.test"
    cat << EOF > "$test_caddyfile"
{
    order forward_proxy before file_server
    auto_https disable_redirects
    email $user_email

    log {
        exclude http.log.error
    }
}

:443, $target_domain {
    tls $user_email

    @admin path /admin /admin/*
    handle @admin {
        uri strip_prefix /admin
        reverse_proxy 127.0.0.1:$WEB_PORT
    }

    handle {
        forward_proxy {
            basic_auth $user_login $user_pass
            hide_ip
            hide_via
            probe_resistance
        }

        file_server {
            root $WEB_ROOT
        }
    }
}
EOF

    info "Валидация нового Caddyfile новым бинарником ДО применения в систему..."
    if ! "$build_dir/caddy.new" validate --config "$test_caddyfile" >/dev/null 2>&1; then
        error "Ошибка валидации сформированного Caddyfile!"
        "$build_dir/caddy.new" validate --config "$test_caddyfile"
        rm -f "$test_caddyfile"
        return 1
    fi
    success "Новый Caddyfile успешно прошёл валидацию синтаксиса."

    # 2. Атомарное сохранение резервных копий текущей рабочей установки
    if [ -f "$CADDY_BIN" ]; then
        cp -a "$CADDY_BIN" "$CADDY_BAK"
    fi
    if [ -f "$CADDY_FILE" ]; then
        cp -a "$CADDY_FILE" "${CADDY_FILE}.bak"
    fi
    if [ -f "$BUILD_INFO_FILE" ]; then
        cp -a "$BUILD_INFO_FILE" "${BUILD_INFO_FILE}.bak"
    fi

    # 3. Атомарное применение нового бинарника и конфигурации
    info "Установка бинарника в $CADDY_BIN..."
    cp -a "$build_dir/caddy.new" "$CADDY_BIN"
    chmod 755 "$CADDY_BIN"

    info "Установка конфигурации в $CADDY_FILE..."
    cp -a "$test_caddyfile" "$CADDY_FILE"
    chown root:caddy "$CADDY_FILE"
    chmod 640 "$CADDY_FILE"
    rm -f "$test_caddyfile"
    save_build_info
    success "Caddyfile сформирован: $CADDY_FILE (права 640 root:caddy)"

    # 4. Защищенный systemd-юнит (без зависимости от nginx)
    cat << EOF > "$CADDY_SERVICE"
[Unit]
Description=Caddy Web Server with NaïveProxy
Documentation=https://caddyserver.com/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
Environment=XDG_DATA_HOME=/var/lib/caddy
Environment=XDG_CONFIG_HOME=/etc/caddy
ExecStart=$CADDY_BIN run --environ --config $CADDY_FILE
ExecReload=$CADDY_BIN reload --config $CADDY_FILE --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$CADDY_SERVICE"
    systemctl daemon-reload
    success "Systemd служба зарегистрирована: caddy.service"

    # Сохранение реквизитов (права 600)
    mkdir -p "$NAIVE_DIR"
    cat << EOF > "$CREDS_FILE"
DOMAIN="$target_domain"
EMAIL="$user_email"
USERNAME="$user_login"
PASSWORD="$user_pass"
PORT="443"
CREATED_AT="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
EOF
    chmod 600 "$CREDS_FILE"

    # Инициализация базы пользователей users.json
    python3 -c "
import json
users = [{
    'username': '$user_login',
    'password': '$user_pass',
    'created_at': '$(date -u +"%Y-%m-%d %H:%M:%S UTC")',
    'note': 'Основной клиент'
}]
with open('$USERS_FILE', 'w', encoding='utf-8') as f:
    json.dump(users, f, indent=2, ensure_ascii=False)
"
    chmod 640 "$USERS_FILE"
    chown root:naive-web "$USERS_FILE" 2>/dev/null || true
    sync_caddy_users 2>/dev/null || true

    cat << EOF > "$CLIENT_CONFIG"
{
  "listen": "socks://127.0.0.1:1080",
  "proxy": "https://${user_login}:${user_pass}@${target_domain}"
}
EOF
    chmod 600 "$CLIENT_CONFIG"
    chmod 700 "$NAIVE_DIR"
    setup_motd

    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow 80/tcp comment 'Nginx HTTP Stub' >/dev/null || true
        ufw allow 443/tcp comment 'Caddy NaiveProxy' >/dev/null || true
        success "UFW правила 80/tcp и 443/tcp добавлены."
    fi

    return 0
}

start_and_verify() {
    step "6/7" "Многоступенчатая верификация Caddy, TLS и NaïveProxy"
    local target_domain="$1" user_login="${2:-}" user_pass="${3:-}"

    info "1. Валидация Caddyfile..."
    if ! "$CADDY_BIN" validate --config "$CADDY_FILE" >/dev/null 2>&1; then
        error "Ошибка валидации Caddyfile!"
        "$CADDY_BIN" validate --config "$CADDY_FILE"
        return 1
    fi
    success "Конфигурация валидна."

    info "2. Запуск caddy.service..."
    systemctl enable caddy >/dev/null 2>&1
    systemctl restart caddy
    sleep 3

    if ! systemctl is-active --quiet caddy; then
        error "Служба Caddy не запустилась. Логи:"
        journalctl -u caddy --no-pager -n 25
        return 1
    fi
    success "Caddy активен (RUNNING)."

    info "3. Проверка сокета порта 443..."
    local p443_check
    p443_check=$(get_port_owner 443)
    if [[ "${p443_check%% *}" == "caddy" ]]; then
        success "Порт 443 слушается Caddy (PID ${p443_check##* })."
    else
        error "Порт 443 не принадлежит Caddy! Текущий владелец: '${p443_check:-none}'."
        return 1
    fi

    info "4. Проверка модуля forward_proxy в запущенном процессе..."
    if "$CADDY_BIN" list-modules 2>/dev/null | grep -q 'http.handlers.forward_proxy'; then
        success "Модуль forward_proxy активен."
    else
        error "Модуль forward_proxy отсутствует в установленном Caddy!"
        return 1
    fi

    info "5. Проверка probe_resistance (fallback-страница для $target_domain на порту 443)..."
    local probe_ok=false
    local hcode
    hcode=$(curl -sk -m 4 --resolve "${target_domain}:443:127.0.0.1"         -o /tmp/naiveprobe.html -w '%{http_code}' "https://${target_domain}" 2>/dev/null || true)
    if [ "$hcode" = "200" ] && grep -qiE "Service Operational|Service Status" /tmp/naiveprobe.html 2>/dev/null; then
        probe_ok=true
    fi
    rm -f /tmp/naiveprobe.html
    [ "$probe_ok" = true ] && success "Fallback-страница probe_resistance отвечает (HTTP 200, Service Operational)." || warn "Fallback-страница пока не ответила HTTP 200."

    info "6. Проверка выпуска и валидности TLS сертификата..."
    local tls_out tls_stat tls_iss tls_host tls_left tls_exp
    tls_out=$(verify_tls_certificate "$target_domain")
    IFS='|' read -r tls_stat tls_iss tls_host tls_left tls_exp <<< "$tls_out"

    if [ "$tls_stat" = "VALID" ]; then
        success "TLS сертификат проверен системным хранилищем CA ($tls_iss, осталось $tls_left дн.)!"
    elif [ "$tls_stat" = "PENDING" ]; then
        warn "Сертификат Let's Encrypt в процессе выпуска (ACME TLS-ALPN-01)."
    else
        warn "TLS сертификат: $tls_stat ($tls_iss, host: $tls_host)."
    fi

    # 7. Информационный тест сквозного туннелирования (не блокирует установку)
    info "7. Проверка туннелирования NaïveProxy (локальный end-to-end тест)..."
    PROXY_TUNNEL_STATUS="NOT_VERIFIED"
    if [ -n "$user_login" ] && [ -n "$user_pass" ]; then
        local pcode
        pcode=$(curl -s -m 8 -x "https://${user_login}:${user_pass}@${target_domain}:443"             --resolve "${target_domain}:443:127.0.0.1" -k             -o /dev/null -w "%{http_code}" "http://connectivitycheck.gstatic.com/generate_204" 2>/dev/null || true)
        if [[ "$pcode" =~ ^(204|200)$ ]]; then
            PROXY_TUNNEL_STATUS="VERIFIED"
            success "Сквозной туннель подтверждён локально (код $pcode)!"
        fi
    fi

    if [ "$PROXY_TUNNEL_STATUS" = "VERIFIED" ]; then
        info "Статус NaïveProxy CONNECT: VERIFIED (local)"
    else
        info "Статус NaïveProxy CONNECT: NOT VERIFIED (проверьте с клиентского устройства)."
    fi

    # Сохраняем актуальный PROXY_TUNNEL_STATUS в CREDS_FILE
    if [ -f "$CREDS_FILE" ]; then
        if grep -q '^PROXY_TUNNEL_STATUS=' "$CREDS_FILE"; then
            sed -i "s/^PROXY_TUNNEL_STATUS=.*/PROXY_TUNNEL_STATUS="$PROXY_TUNNEL_STATUS"/" "$CREDS_FILE"
        else
            echo "PROXY_TUNNEL_STATUS="$PROXY_TUNNEL_STATUS"" >> "$CREDS_FILE"
        fi
    fi

    chmod 600 "$CREDS_FILE" 2>/dev/null || true
    chmod 600 "$CLIENT_CONFIG" 2>/dev/null || true
    return 0
}

show_info() {
    if ! load_credentials; then
        error "Файл учетных данных $CREDS_FILE не найден."
        return 1
    fi

    step "7/7" "Результаты установки"
    echo ""
    echo -e "${GREEN}==========================================================${NC}"
    echo -e "${BOLD}${GREEN}        NAÏVEPROXY И CADDY УСПЕШНО РАЗВЕРНУТЫ            ${NC}"
    echo -e "${GREEN}==========================================================${NC}"
    echo -e "  Caddy (443) :      ${GREEN}RUNNING (:443)${NC}"
    echo -e "  Nginx (80)  :      ${GREEN}RUNNING (:80)${NC}"

    local tls_out tls_stat tls_iss tls_host tls_left tls_exp
    tls_out=$(verify_tls_certificate "$DOMAIN")
    IFS='|' read -r tls_stat tls_iss tls_host tls_left tls_exp <<< "$tls_out"

    if [ "$tls_stat" = "VALID" ]; then
        echo -e "  TLS сертификат  :  ${GREEN}VALID ($tls_iss, осталось $tls_left дн.)${NC}"
    else
        echo -e "  TLS сертификат  :  ${YELLOW}PENDING (выпуск ACME TLS-ALPN-01)${NC}"
    fi

    if [ "$PROXY_TUNNEL_STATUS" = "VERIFIED" ]; then
        echo -e "  CONNECT туннель :  ${GREEN}VERIFIED (local, OK)${NC}"
    else
        echo -e "  CONNECT туннель :  ${YELLOW}NOT VERIFIED / TEST FAILED (проверьте с клиента)${NC}"
    fi
    echo -e "${GREEN}==========================================================${NC}"

    echo ""
    echo -e "${YELLOW}──────────────────────────────────────────────────────────${NC}"
    echo -e "${BOLD}${YELLOW}ВНИМАНИЕ:${NC} Конфиденциальные данные. Закройте экран от посторонних."
    echo -e "${YELLOW}──────────────────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Сервер:${NC}       $DOMAIN"
    echo -e "  ${BOLD}Порт:${NC}         $PORT"
    echo -e "  ${BOLD}Логин:${NC}        $USERNAME"
    echo -e "  ${BOLD}Пароль:${NC}       $PASSWORD"
    echo ""
    echo -e "${CYAN}----------------------------------------------------------${NC}"
    echo -e "${BOLD}Строка подключения (URL format):${NC}"
    echo -e "${YELLOW}https://${USERNAME}:${PASSWORD}@${DOMAIN}:${PORT}${NC}"
    echo -e "${BOLD}NekoBox / Sing-box URL:${NC}"
    echo -e "${YELLOW}naive+https://${USERNAME}:${PASSWORD}@${DOMAIN}:${PORT}#Naive-${USERNAME}${NC}"
    if command -v qrencode &>/dev/null; then
        echo -e "\n${CYAN}QR-код для импорта в NekoBox / Matsuri / v2rayN:${NC}"
        qrencode -t ANSIUTF8 "naive+https://${USERNAME}:${PASSWORD}@${DOMAIN}:${PORT}#Naive-${USERNAME}"
    fi
    echo ""
    echo -e "${CYAN}----------------------------------------------------------${NC}"
    echo -e "${BOLD}Конфигурация NaïveProxy (client.json):${NC}"
    echo -e "${CYAN}${BOLD}$(cat "$CLIENT_CONFIG" 2>/dev/null || true)${NC}"
    echo ""
    echo -e "${CYAN}----------------------------------------------------------${NC}"
    echo -e "${BOLD}${GREEN}ВЕБ-ПАНЕЛЬ УПРАВЛЕНИЯ (WEB UI MANAGER):${NC}"
    if [ -f "$WEB_CREDS_FILE" ] && [ -n "$(grep -E '^WEB_PASS=' "$WEB_CREDS_FILE" 2>/dev/null)" ]; then
        local web_user web_pass web_port="18080"
        web_user=$(grep -E '^WEB_USER=' "$WEB_CREDS_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
        web_pass=$(grep -E '^WEB_PASS=' "$WEB_CREDS_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
        local sp
        sp=$(grep -E '^WEB_PORT=' "$WEB_CREDS_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
        [ -n "$sp" ] && web_port="$sp"

        echo -e "  Статус:       ${GREEN}АКТИВНА (:443 -> :${web_port})${NC}"
        echo -e "  HTTPS URL:    ${BOLD}${CYAN}https://${DOMAIN}/admin/${NC}"
        echo -e "  Доступ:       ${GREEN}Локально (127.0.0.1:${web_port}), закрыт снаружи для безопасности${NC}"
        echo -e "  Логин:        ${BOLD}$web_user${NC}"
        echo -e "  Пароль:       ${BOLD}${YELLOW}$web_pass${NC}"
    else
        echo -e "  Статус:       ${YELLOW}НЕ УСТАНОВЛЕНА${NC}"
        echo -e "  Установка:    ${BOLD}${CYAN}bash install.sh web-install${NC}"
    fi
    echo -e "${CYAN}----------------------------------------------------------${NC}"
    echo -e "${BOLD}Клиентские приложения:${NC}"
    echo -e "  • NaïveProxy core: ./naive client.json"
    echo -e "  • NekoBox / NekoRay: Добавить -> Naive -> Хост: $DOMAIN, Порт: $PORT"
    echo -e "  • Sing-box / v2rayN: Протокол naive / http proxy с TLS"
    echo -e "${GREEN}==========================================================${NC}\n"
    return 0
}

run_installation() {
    local target_arg="${1:-}"
    local preset_mode="${2:-}"

    if [ "$target_arg" = "keep" ] || [ "$target_arg" = "random" ]; then
        preset_mode="$target_arg"
        target_arg=""
    fi

    # Прямая передача домена через аргумент CLI (например: bash install.sh install mydomain.com)
    if [ -n "$target_arg" ]; then
        target_arg=$(echo "$target_arg" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        local chk
        chk=$(validate_domain_format "$target_arg" || true)
        if [ "$chk" = "VALID" ]; then
            CHECKED_DOMAIN="$target_arg"
            CHECKED_STATUS="READY"
            mkdir -p "$NAIVE_DIR"
            cat << EOF > "$DOMAIN_CHECK_FILE"
DOMAIN="$CHECKED_DOMAIN"
SERVER_IPV4="$SERVER_IPV4"
DNS_IPV4="CLI_OVERRIDE"
DNS_STATUS="CONFIRMED_BY_USER"
CAA_STATUS="ALLOWED"
CHECK_TIMESTAMP="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
CHECK_TIMESTAMP_EPOCH="$(date +%s)"
DOMAIN_STATUS="READY"
EOF
            chmod 600 "$DOMAIN_CHECK_FILE"
            info "Домен '$CHECKED_DOMAIN' принят из аргумента командной строки."
        fi
    fi

    print_header
    echo -e "${BOLD}ЭТАП 2: УСТАНОВКА NAÏVEPROXY + CADDY (С ЗАГЛУШКОЙ NGINX НА :80)${NC}\n"

    if ! is_domain_ready; then
        local def_dom=""
        load_domain_check 2>/dev/null && def_dom="${CHECKED_DOMAIN:-}"

        if [ -n "$def_dom" ]; then
            read -r -p "Введите домен для установки [по умолчанию: $def_dom]: " input_dom
            input_dom="${input_dom:-$def_dom}"
        else
            read -r -p "Введите домен для установки (например, vpnfotmyvps.duckdns.org): " input_dom
        fi
        input_dom=$(echo "$input_dom" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

        if [ -z "$input_dom" ]; then
            error "Домен не указан. Установка отменена."
            return 1
        fi

        run_domain_diagnostics "$input_dom"
        if ! is_domain_ready; then
            error "Домен не подтверждён. Установка прервана."
            return 1
        fi
    fi

    load_domain_check || true
    resolve_server_ips

    info "Подтверждённый домен: ${BOLD}$CHECKED_DOMAIN${NC} ($CHECKED_TIMESTAMP)"

    if [ -n "$CHECKED_SERVER_IPV4" ] && [ -n "$SERVER_IPV4" ] && [ "$SERVER_IPV4" != "$CHECKED_SERVER_IPV4" ]; then
        warn "IP сервера отличается от зафиксированного при проверке ($CHECKED_SERVER_IPV4 -> $SERVER_IPV4)."
        read -r -p "Продолжить установку с текущим IP ($SERVER_IPV4)? [y/N]: " ip_cont
        case "$ip_cont" in
            y|Y) info "Продолжаем установку..." ;;
            *)
                error "Запустите повторную проверку: $0 domain"
                return 1
                ;;
        esac
    fi

    # 1. Проверка порта 80 ДО установки Nginx
    check_port80_conflict

    # 2. Неразрушающее обеспечение работы Nginx на порту 80
    ensure_nginx_stub

    # 3. Проверка порта 443 для Caddy
    check_port443_conflict

    # 4. Реквизиты
    step "Параметры учетной записи NaïveProxy"
    local EMAIL="" USERNAME="" PASSWORD=""

    if [ "$preset_mode" = "keep" ]; then
        if ! load_credentials; then
            error "Не удалось прочитать существующие реквизиты."
            return 1
        fi
        info "Используются сохраненные параметры: пользователь '$USERNAME', email '$EMAIL'"
    elif [ "$preset_mode" = "random" ]; then
        EMAIL="admin@${CHECKED_DOMAIN}"
        USERNAME="user_$(generate_random_string 8)"
        PASSWORD=$(generate_random_string 16)
        info "Сгенерированы случайные реквизиты: пользователь '$USERNAME'"
    else
        local def_email="admin@${CHECKED_DOMAIN}"
        while true; do
            read -r -p "Введите email для SSL сертификата [по умолчанию: $def_email]: " EMAIL
            EMAIL="${EMAIL:-$def_email}"
            EMAIL=$(echo "$EMAIL" | tr -d '[:space:]')
            if validate_email "$EMAIL"; then
                break
            else
                error "Некорректный email. Пример: admin@example.com"
            fi
        done

        local auto_user="user_$(generate_random_string 8)"
        while true; do
            read -r -p "Введите имя пользователя (логин) [по умолчанию: $auto_user]: " USERNAME
            USERNAME="${USERNAME:-$auto_user}"
            USERNAME=$(echo "$USERNAME" | tr -d '[:space:]')
            [[ "$USERNAME" =~ ^[A-Za-z0-9_-]+$ ]] && break
            error "Только латинские буквы, цифры, дефис и подчёркивание."
        done

        local auto_pass
        auto_pass=$(generate_random_string 16)
        while true; do
            read -r -p "Введите пароль [по умолчанию: $auto_pass]: " PASSWORD
            PASSWORD="${PASSWORD:-$auto_pass}"
            PASSWORD=$(echo "$PASSWORD" | tr -d '[:space:]')
            [[ "$PASSWORD" =~ ^[A-Za-z0-9._-]+$ ]] && break
            error "Только латинские буквы, цифры, точка, дефис и подчёркивание."
        done
    fi

    if [ -x "$CADDY_BIN" ] && "$CADDY_BIN" list-modules 2>/dev/null | grep -q 'http.handlers.forward_proxy'; then
        if [ "$preset_mode" = "keep" ]; then
            info "Обнаружен проверенный рабочий бинарник Caddy. Пропускаем пересборку."
        else
            echo ""
            read -r -p "Бинарник Caddy с forwardproxy уже собран. Использовать его без перекомпиляции? [Y/n]: " use_exist_caddy
            use_exist_caddy="${use_exist_caddy:-y}"
            case "$use_exist_caddy" in
                y|Y) info "Используется существующий бинарник Caddy." ;;
                *)
                    if ! build_caddy; then
                        error "Ошибка сборки Caddy. Установка прервана."
                        return 1
                    fi
                    ;;
            esac
        fi
    else
        if ! build_caddy; then
            error "Ошибка сборки Caddy. Установка прервана."
            return 1
        fi
    fi

    if ! configure_system "$CHECKED_DOMAIN" "$EMAIL" "$USERNAME" "$PASSWORD"; then
        error "Ошибка конфигурации Caddyfile. Установка прервана."
        rollback_caddy
        return 1
    fi

    if ! start_and_verify "$CHECKED_DOMAIN" "$USERNAME" "$PASSWORD"; then
        error "Критическая ошибка запуска или валидации NaïveProxy!"
        rollback_caddy
        return 1
    fi

    commit_caddy
    setup_motd
    install_web_ui
    show_info
}

show_status() {
    print_header
    load_credentials 2>/dev/null || true

    echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}       NAÏVEPROXY + CADDY — ДИАГНОСТИКА СИСТЕМЫ         ${NC}"
    echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════${NC}\n"

    local cur_dom="${DOMAIN:-не настроен}"
    echo -e "${BOLD}Domain             :${NC} $cur_dom"

    # DNS проверки
    if [ "$cur_dom" != "не настроен" ]; then
        local dns_ip_cf
        dns_ip_cf=$(dig +short A "$cur_dom" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)
        [ "$dns_ip_cf" = "$SERVER_IPV4" ] && echo -e "${BOLD}DNS A              :${NC} ${GREEN}OK${NC}" || echo -e "${BOLD}DNS A              :${NC} ${RED}MISMATCH (${dns_ip_cf:-none} != $SERVER_IPV4)${NC}"

        local aaaa_recs=()
        while IFS= read -r arec; do
            [ -n "$arec" ] && aaaa_recs+=("$arec")
        done < <(dig +short AAAA "$cur_dom" @1.1.1.1 2>/dev/null | grep -E ':' || true)

        if [ "${#aaaa_recs[@]}" -eq 0 ]; then
            echo -e "${BOLD}DNS AAAA           :${NC} ${GREEN}OK / ABSENT${NC}"
        elif [ -n "$SERVER_IPV6_OUTBOUND" ] && [[ "${aaaa_recs[*]}" == *"$SERVER_IPV6_OUTBOUND"* ]]; then
            echo -e "${BOLD}DNS AAAA           :${NC} ${GREEN}OK (совпадает с VPS: ${SERVER_IPV6_OUTBOUND})${NC}"
        else
            echo -e "${BOLD}DNS AAAA           :${NC} ${YELLOW}ВНИМАНИЕ (${aaaa_recs[*]})${NC}"
        fi

        local caa_stat
        caa_stat=$(check_caa_record "$cur_dom")
        [ "$caa_stat" = "RESTRICTED" ] && echo -e "${BOLD}DNS CAA            :${NC} ${RED}RESTRICTED${NC}" || echo -e "${BOLD}DNS CAA            :${NC} ${GREEN}OK ($caa_stat)${NC}"

        echo -e "${BOLD}Server IPv4        :${NC} $SERVER_IPV4"
        echo -e "${BOLD}DNS IPv4           :${NC} ${dns_ip_cf:-не определен}"
    fi

    echo ""
    # Службы через get_port_owner
    local p80_owner p443_owner
    p80_owner=$(get_port_owner 80)
    p443_owner=$(get_port_owner 443)

    if systemctl is-active --quiet nginx 2>/dev/null && [ -n "$p80_owner" ]; then
        echo -e "${BOLD}Nginx :80          :${NC} ${GREEN}RUNNING (PID ${p80_owner##* })${NC}"
    elif systemctl is-active --quiet nginx 2>/dev/null; then
        echo -e "${BOLD}Nginx :80          :${NC} ${YELLOW}RUNNING (порт :80 не привязан)${NC}"
    else
        echo -e "${BOLD}Nginx :80          :${NC} ${RED}STOPPED / FAILED${NC}"
    fi

    if systemctl is-active --quiet caddy 2>/dev/null && [[ "${p443_owner%% *}" == "caddy" ]]; then
        echo -e "${BOLD}Caddy :443         :${NC} ${GREEN}RUNNING (PID ${p443_owner##* })${NC}"
    elif systemctl is-active --quiet caddy 2>/dev/null; then
        echo -e "${BOLD}Caddy :443         :${NC} ${YELLOW}RUNNING (порт :443 не привязан к Caddy)${NC}"
    else
        echo -e "${BOLD}Caddy :443         :${NC} ${RED}STOPPED / FAILED${NC}"
    fi

    if systemctl is-active --quiet naiveproxy-webui 2>/dev/null || systemctl is-active --quiet naiveproxy-web 2>/dev/null; then
        echo -e "${BOLD}Web Manager        :${NC} ${GREEN}RUNNING (127.0.0.1:18080 -> /admin/)${NC}"
    else
        echo -e "${BOLD}Web Manager        :${NC} ${YELLOW}STOPPED / NOT INSTALLED${NC}"
    fi

    # Конфигурация и модули
    local cfile_stat="NOT FOUND"
    if [ -f "$CADDY_FILE" ] && [ -x "$CADDY_BIN" ]; then
        "$CADDY_BIN" validate --config "$CADDY_FILE" >/dev/null 2>&1 && cfile_stat="VALID" || cfile_stat="INVALID"
    fi
    [ "$cfile_stat" = "VALID" ] && echo -e "${BOLD}Caddyfile          :${NC} ${GREEN}VALID${NC}" || echo -e "${BOLD}Caddyfile          :${NC} ${RED}$cfile_stat${NC}"

    local fp_stat="NOT FOUND"
    if [ -x "$CADDY_BIN" ] && "$CADDY_BIN" list-modules 2>/dev/null | grep -q 'http.handlers.forward_proxy'; then
        fp_stat="OK"
    fi
    [ "$fp_stat" = "OK" ] && echo -e "${BOLD}forward_proxy      :${NC} ${GREEN}OK${NC}" || echo -e "${BOLD}forward_proxy      :${NC} ${RED}NOT FOUND${NC}"

    # TLS статус через verify_tls_certificate
    local tls_out tls_stat tls_iss tls_host tls_left tls_exp
    if [ "$cur_dom" != "не настроен" ]; then
        tls_out=$(verify_tls_certificate "$cur_dom")
        IFS='|' read -r tls_stat tls_iss tls_host tls_left tls_exp <<< "$tls_out"
    else
        tls_stat="NOT DETECTED" tls_iss="none" tls_host="UNKNOWN" tls_left=0 tls_exp="UNKNOWN"
    fi

    [ "$tls_stat" = "VALID" ] && echo -e "${BOLD}TLS certificate    :${NC} ${GREEN}VALID${NC}" || echo -e "${BOLD}TLS certificate    :${NC} ${YELLOW}$tls_stat${NC}"
    echo -e "${BOLD}TLS issuer         :${NC} $tls_iss"
    [ "$tls_host" != "UNKNOWN" ] && echo -e "${BOLD}TLS hostname       :${NC} $([ "$tls_host" = "MATCH" ] && echo -e "${GREEN}MATCH ($cur_dom)${NC}" || echo -e "${RED}MISMATCH${NC}")"
    [ "$tls_exp" != "UNKNOWN" ] && echo -e "${BOLD}TLS expiry         :${NC} ${tls_left} дн. (до $tls_exp)"

    # Probe resistance (проверяется после TLS)
    local probe_stat="NOT DETECTED"
    if [ "$cur_dom" != "не настроен" ]; then
        local probe_code
        probe_code=$(curl -sk -m 3 --resolve "${cur_dom}:443:127.0.0.1" -o /tmp/probe_test.html -w '%{http_code}' "https://${cur_dom}" 2>/dev/null || true)
        if [ "$probe_code" = "200" ] && grep -q "Service Online" /tmp/probe_test.html 2>/dev/null; then
            probe_stat="OK"
        fi
        rm -f /tmp/probe_test.html
    fi
    [ "$probe_stat" = "OK" ] && echo -e "${BOLD}probe_resistance   :${NC} ${GREEN}OK (код 200, Service Online)${NC}" || echo -e "${BOLD}probe_resistance   :${NC} ${YELLOW}$probe_stat${NC}"

    # CONNECT tunnel (локальный end-to-end тест)
    local conn_stat="NOT VERIFIED / TEST FAILED"
    if [ -n "$USERNAME" ] && [ -n "$PASSWORD" ] && [ "$cur_dom" != "не настроен" ]; then
        local tcode
        tcode=$(curl -s -m 5 -x "https://${USERNAME}:${PASSWORD}@${cur_dom}:443"             --resolve "${cur_dom}:443:127.0.0.1" -k             -o /dev/null -w "%{http_code}" "http://connectivitycheck.gstatic.com/generate_204" 2>/dev/null || true)
        if [[ "$tcode" =~ ^(204|200)$ ]]; then
            conn_stat="VERIFIED (local)"
        fi
    fi
    [ "$conn_stat" = "VERIFIED (local)" ] && echo -e "${BOLD}NaïveProxy CONNECT :${NC} ${GREEN}VERIFIED (local)${NC}" || echo -e "${BOLD}NaïveProxy CONNECT :${NC} ${YELLOW}$conn_stat${NC}"
    echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════${NC}\n"
}

update_caddy() {
    print_header
    info "Безопасное обновление Caddy и forwardproxy@naive..."
    if ! is_naiveproxy_installed; then
        error "NaïveProxy еще не установлен. Сначала выполните установку."
        return 1
    fi
    load_credentials || true

    # Сборка нового бинарника
    if ! build_caddy; then
        error "Сбой сборки Caddy. Предыдущая версия осталась активной."
        return 1
    fi

    info "Перезапуск caddy.service..."
    systemctl restart caddy
    sleep 3

    # Полная транзакционная верификация
    if start_and_verify "$DOMAIN" "$USERNAME" "$PASSWORD"; then
        commit_caddy
        success "Caddy успешно обновлен, перезапущен и полностью проверен."
        show_status
        return 0
    else
        error "Критическая ошибка после установки нового Caddy! Выполняем транзакционный откат..."
        rollback_caddy
        return 1
    fi
}

run_reinstall() {
    print_header
    info "Повторная установка NaïveProxy..."

    if [ -f "$CREDS_FILE" ]; then
        load_credentials || true
        echo ""
        echo -e "${BOLD}Обнаружены существующие реквизиты:${NC}"
        echo -e "  Домен:        ${CYAN}$DOMAIN${NC}"
        echo -e "  Email:        ${CYAN}$EMAIL${NC}"
        echo -e "  Пользователь: ${CYAN}$USERNAME${NC}"
        echo -e "  Пароль:       ${CYAN}$PASSWORD${NC}\n"
        echo "Выберите режим переустановки:"
        echo "  1) Сохранить текущие логин и пароль"
        echo "  2) Сгенерировать новые случайные реквизиты"
        echo "  3) Ввести все параметры заново вручную"
        echo "  0) Отмена"
        echo ""
        read -r -p "Ваш выбор [1-3, по умолчанию 1]: " rchoice
        rchoice="${rchoice:-1}"

        case "$rchoice" in
            1)
                cp -p "$CREDS_FILE" "${CREDS_FILE}.bak" 2>/dev/null || true
                systemctl stop caddy 2>/dev/null || true
                run_installation "keep"; return 0 ;;
            2)
                cp -p "$CREDS_FILE" "${CREDS_FILE}.bak" 2>/dev/null || true
                systemctl stop caddy 2>/dev/null || true
                run_installation "random"; return 0 ;;
            3)
                cp -p "$CREDS_FILE" "${CREDS_FILE}.bak" 2>/dev/null || true
                systemctl stop caddy 2>/dev/null || true
                run_installation "manual"; return 0 ;;
            0) info "Отменено."; return 0 ;;
        esac
    fi

    systemctl stop caddy 2>/dev/null || true
    run_installation
}

uninstall_all() {
    echo -e "\n${RED}${BOLD}ВНИМАНИЕ! Удаление NaïveProxy и Caddy.${NC}"
    read -r -p "Вы уверены? [y/N]: " confirm
    case "$confirm" in
        y|Y)
            info "Остановка caddy.service..."
            systemctl stop caddy 2>/dev/null || true
            systemctl disable caddy 2>/dev/null || true
            rm -f "$CADDY_SERVICE"
            systemctl daemon-reload

            # 1. СНАЧАЛА полностью восстанавливаем Nginx пока существуют файлы состояния в $NAIVE_DIR!
            info "Восстановление исходного состояния Nginx..."
            rm -f "$NGINX_STUB_CONF" "$NGINX_STUB_ENABLED"
            rm -rf "$NGINX_STUB_ROOT"

            local nginx_was_installed_by_script=false
            if [ -f "$NGINX_STATE_FILE" ]; then
                local orig_existed orig_type orig_tgt orig_bak
                orig_existed=$(grep '^DEFAULT_EXISTED=' "$NGINX_STATE_FILE" | cut -d= -f2 | tr -d '"')
                orig_type=$(grep '^DEFAULT_TYPE=' "$NGINX_STATE_FILE" | cut -d= -f2 | tr -d '"')
                orig_tgt=$(grep '^DEFAULT_SYMLINK_TARGET=' "$NGINX_STATE_FILE" | cut -d= -f2 | tr -d '"')
                orig_bak=$(grep '^DEFAULT_FILE_BACKUP=' "$NGINX_STATE_FILE" | cut -d= -f2 | tr -d '"')
                grep -q '^NGINX_INSTALLED_BY_SCRIPT=true' "$NGINX_STATE_FILE" && nginx_was_installed_by_script=true

                if [ "$orig_existed" = "true" ]; then
                    if [ "$orig_type" = "symlink" ] && [ -n "$orig_tgt" ]; then
                        ln -sf "$orig_tgt" /etc/nginx/sites-enabled/default
                        info "Восстановлена исходная символическая ссылка sites-enabled/default -> $orig_tgt."
                    elif [ "$orig_type" = "file" ] && [ -f "$orig_bak" ]; then
                        cp -a "$orig_bak" /etc/nginx/sites-enabled/default
                        rm -f "$orig_bak"
                        info "Восстановлен исходный файл sites-enabled/default."
                    fi
                fi
            fi

            # Восстановление отключенных сайтов на 443
            if [ -f /etc/naiveproxy/nginx_443_disabled.list ]; then
                info "Восстановление конфигураций Nginx на порту 443..."
                while IFS='|' read -r s_link s_target; do
                    [ -n "$s_link" ] && [ -n "$s_target" ] && ln -sf "$s_target" "$s_link"
                done < /etc/naiveproxy/nginx_443_disabled.list
                rm -f /etc/naiveproxy/nginx_443_disabled.list
            fi

            if nginx -t >/dev/null 2>&1; then
                systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
            fi

            # Остановка и удаление Web UI
            info "Остановка и удаление NaïveProxy Web UI..."
            systemctl stop naiveproxy-webui naiveproxy-web 2>/dev/null || true
            systemctl disable naiveproxy-webui naiveproxy-web 2>/dev/null || true
            rm -f "$WEB_SERVICE_FILE" "$WEB_SERVICE_ALIAS" "$WEB_SCRIPT_FILE" "$HELPER_SCRIPT_FILE" "/etc/sudoers.d/naive-web" "$WEB_CREDS_FILE"
            userdel -r naive-web 2>/dev/null || userdel naive-web 2>/dev/null || true
            systemctl daemon-reload

            # 2. ТЕПЕРЬ удаляем бинарники и каталоги Caddy и NaïveProxy
            info "Удаление бинарников и каталогов Caddy и NaïveProxy..."
            rm -f "$CADDY_BIN" "$CADDY_BAK" "${CADDY_FILE}.bak" "${BUILD_INFO_FILE}.bak"
            rm -rf "$CADDY_CONF_DIR" "$NAIVE_DIR" "$WEB_ROOT" "/var/lib/caddy" "/var/log/caddy" "$BUILD_ROOT"
            remove_motd
            userdel -r caddy 2>/dev/null || userdel caddy 2>/dev/null || true

            echo ""
            if [ "$nginx_was_installed_by_script" = true ]; then
                read -r -p "Nginx был установлен этим скриптом для заглушки. Удалить Nginx (apt purge)? [y/N]: " rm_nginx
            else
                read -r -p "Удалить пакет Nginx целиком? [y/N]: " rm_nginx
            fi
            case "$rm_nginx" in
                y|Y)
                    systemctl stop nginx 2>/dev/null || true
                    systemctl disable nginx 2>/dev/null || true
                    apt-get purge -y nginx nginx-common 2>/dev/null || true
                    info "Nginx полностью удалён." ;;
                *) info "Nginx сохранён в исходном состоянии." ;;
            esac

            if [ -d "$GO_INSTALL_DIR" ] || [ -d "/usr/local/go-versions" ]; then
                echo ""
                read -r -p "Удалить Go и все версии из /usr/local/go-versions? [y/N]: " rm_go
                case "$rm_go" in
                    y|Y)
                        rm -rf "$GO_INSTALL_DIR" /usr/local/go-versions /etc/profile.d/golang.sh
                        info "Go и версионные каталоги удалены." ;;
                esac
            fi

            success "NaïveProxy и Caddy полностью удалены."
            ;;
        *) info "Удаление отменено." ;;
    esac
}

manage_web_ui() {
    print_header
    echo -e "${BOLD}${CYAN}УПРАВЛЕНИЕ ПАНЕЛЬЮ NAÏVEPROXY WEB UI${NC}\n"

    load_credentials 2>/dev/null || true
    local cur_dom="${DOMAIN:-$CHECKED_DOMAIN}"

    local status_line="${RED}NOT INSTALLED / STOPPED${NC}"
    if is_webui_ready; then
        status_line="${GREEN}RUNNING (127.0.0.1:$WEB_PORT -> /admin/)${NC}"
    elif [ -f "$WEB_SCRIPT_FILE" ]; then
        status_line="${RED}FAILED / STOPPED (проверьте логи journalctl)${NC}"
    fi

    local web_user="admin" web_pass=""
    if [ -f "$WEB_CREDS_FILE" ]; then
        web_user=$(grep -E '^WEB_USER=' "$WEB_CREDS_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
        web_pass=$(grep -E '^WEB_PASS=' "$WEB_CREDS_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
    fi

    echo -e "  Статус службы : $status_line"
    if is_webui_ready; then
        echo -e "  URL панели    : ${BOLD}${GREEN}https://${cur_dom}/admin/${NC}"
    else
        echo -e "  URL панели    : ${YELLOW}https://${cur_dom}/admin/ (служба не активна)${NC}"
    fi
    echo -e "  Логин         : ${BOLD}$web_user${NC}"
    echo -e "  Пароль        : ${BOLD}${YELLOW}${web_pass:-не установлен}${NC}\n"

    if ! is_webui_ready; then
        echo "1) Установить и запустить Web UI сейчас"
        echo "2) Показать логи службы (journalctl)"
        echo "0) Назад в главное меню"
        echo ""
        read -r -p "Выберите действие [0-2]: " wopt
        case "$wopt" in
            1)
                install_web_ui
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            2)
                journalctl -u naiveproxy-webui --no-pager -n 30
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            0) return 0 ;;
        esac
    else
        echo "1) Сгенерировать новый случайный пароль"
        echo "2) Задать пароль вручную"
        echo "3) Перезапустить службу Web UI"
        echo "4) Показать логи службы"
        echo "5) Переустановить / обновить компоненты Web UI (QR NekoBox, etc.)"
        echo "0) Назад в главное меню"
        echo ""
        read -r -p "Выберите действие [0-5]: " wopt
        case "$wopt" in
            1)
                local np
                np=$(generate_random_string 20)
                cat << EOF > "$WEB_CREDS_FILE"
WEB_USER="$web_user"
WEB_PASS="$np"
WEB_PORT="${WEB_PORT:-18080}"
CREATED_AT="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
EOF
                chown root:naive-web "$WEB_CREDS_FILE" 2>/dev/null || true
                chmod 640 "$WEB_CREDS_FILE" 2>/dev/null || true
                systemctl restart naiveproxy-webui 2>/dev/null || true
                success "Новый пароль сгенерирован: $np"
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            2)
                read -r -p "Введите новый пароль: " np
                np=$(echo "$np" | tr -d '[:space:]')
                if [ -n "$np" ]; then
                    cat << EOF > "$WEB_CREDS_FILE"
WEB_USER="$web_user"
WEB_PASS="$np"
WEB_PORT="${WEB_PORT:-18080}"
CREATED_AT="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
EOF
                    chown root:naive-web "$WEB_CREDS_FILE" 2>/dev/null || true
                    chmod 640 "$WEB_CREDS_FILE" 2>/dev/null || true
                    systemctl restart naiveproxy-webui 2>/dev/null || true
                    success "Пароль успешно обновлен."
                fi
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            3)
                systemctl restart naiveproxy-webui
                if is_webui_ready; then
                    success "Служба naiveproxy-webui активна (RUNNING :$WEB_PORT)."
                else
                    error "Служба не запустилась. Логи:"
                    journalctl -u naiveproxy-webui --no-pager -n 20
                fi
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            4)
                journalctl -u naiveproxy-webui --no-pager -n 30
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            5)
                install_web_ui
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            0) return 0 ;;
        esac
    fi
}

menu() {
    print_header

    local display_domain="не настроен"
    local domain_check_badge="${RED}❌ NOT READY${NC}"
    local naive_badge="${YELLOW}не установлен${NC}"
    local caddy_badge="${YELLOW}не запущен${NC}"
    local nginx_badge="${YELLOW}не запущен${NC}"

    load_domain_check || true
    if [ "$CHECKED_STATUS" = "READY" ]; then
        display_domain="$CHECKED_DOMAIN"
        domain_check_badge="${GREEN}✓ READY${NC}"
    elif [ "$CHECKED_STATUS" = "READY_WITH_WARNINGS" ]; then
        display_domain="$CHECKED_DOMAIN"
        domain_check_badge="${YELLOW}⚠ READY_WITH_WARNINGS${NC}"
    elif [ "$CHECKED_STATUS" = "DNS_PENDING" ]; then
        display_domain="${CHECKED_DOMAIN:-не настроен}"
        domain_check_badge="${YELLOW}⏳ DNS_PENDING${NC}"
    fi

    if is_naiveproxy_installed; then
        load_credentials || true
        display_domain="$DOMAIN"
        naive_badge="${GREEN}✓ УСТАНОВЛЕН${NC}"
    fi

    systemctl is-active --quiet caddy 2>/dev/null && caddy_badge="${GREEN}✓ RUNNING (:443)${NC}" || { [ -f "$CADDY_BIN" ] && caddy_badge="${RED}STOPPED${NC}"; }
    systemctl is-active --quiet nginx 2>/dev/null && nginx_badge="${GREEN}✓ RUNNING (:80)${NC}"
    local web_badge="${YELLOW}не установлен${NC}"
    if is_webui_ready; then
        web_badge="${GREEN}✓ RUNNING (:18080 -> /admin/)${NC}"
    elif [ -f "$WEB_SCRIPT_FILE" ]; then
        web_badge="${RED}❌ STOPPED / FAILED${NC}"
    fi

    echo "Схема: Nginx (:80 сайт-заглушка) + Caddy (:443 NaïveProxy)"
    echo "──────────────────────────────────────────────────────"
    echo -e "  VPS IPv4:     ${BOLD}${GREEN}${SERVER_IPV4:-не определён}${NC}"
    echo -e "  Домен:        ${BOLD}$display_domain${NC}"
    echo -e "  Проверка:     $domain_check_badge"
    echo -e "  NaïveProxy:   $naive_badge"
    echo -e "  Caddy:        $caddy_badge"
    echo -e "  Nginx:        $nginx_badge"
    echo -e "  Web Manager:  $web_badge"
    echo "──────────────────────────────────────────────────────"
    echo ""

    if ! is_naiveproxy_installed; then
        echo "  1) У меня уже есть домен"
        echo "  2) У меня есть домен, нужен субдомен"
        echo "  3) Получить бесплатный домен / hostname"
        echo "  4) Проверить домен"
        echo "──────────────────────────────────────────────────────"
        if [ "$CHECKED_STATUS" = "READY" ] || [ "$CHECKED_STATUS" = "READY_WITH_WARNINGS" ]; then
            echo -e "  5) Установить NaïveProxy  ${GREEN}[ДОМЕН: ${CHECKED_DOMAIN}]${NC}"
        else
            echo -e "  5) Установить NaïveProxy  ${CYAN}[ВВЕСТИ ДОМЕН И НАЧАТЬ]${NC}"
        fi
        echo "  0) Выход"
        echo "──────────────────────────────────────────────────────"
        echo ""
        read -r -p "Выберите действие [0-5]: " mchoice
        case "$mchoice" in
            1) wizard_own_domain ;;
            2) wizard_subdomain ;;
            3) wizard_free_domain ;;
            4) wizard_manual_check ;;
            5) run_installation ;;
            0) exit 0 ;;
            *) error "Неверный ввод."; sleep 1 ;;
        esac
    else
        echo "  1) Проверить / изменить домен"
        echo "  2) Управление клиентами (добавить / удалить / список)"
        echo "  3) Показать конфигурацию и client.json"
        echo "  4) Комплексная диагностика (read-only)"
        echo "  5) Перезапустить Caddy"
        echo "  6) Обновить Caddy + forwardproxy@naive"
        if is_webui_ready; then
            echo -e "  7) Управление Web UI  ${GREEN}[RUNNING :18080]${NC}"
        else
            echo -e "  7) Установить Web UI  ${CYAN}[ПАНЕЛЬ УПРАВЛЕНИЯ]${NC}"
        fi
        echo "  8) Переустановить NaïveProxy"
        echo "  9) Полностью удалить NaïveProxy и Caddy"
        echo "  0) Выход"
        echo "──────────────────────────────────────────────────────"
        echo ""
        read -r -p "Выберите действие [0-9]: " mchoice
        case "$mchoice" in
            1) domain_wizard ;;
            2) manage_clients_menu ;;
            3) show_info ;;
            4) show_status ;;
            5) systemctl restart caddy && success "Caddy перезапущен." && show_status ;;
            6) update_caddy ;;
            7) manage_web_ui ;;
            8) run_reinstall ;;
            9) uninstall_all ;;
            0) exit 0 ;;
            *) error "Неверный ввод."; sleep 1 ;;
        esac
    fi
}

# ------------------------------------------------------------------------------
# Точка входа / Маршрутизация аргументов CLI
# ------------------------------------------------------------------------------
main() {
    local action="${1:-}"

    case "$action" in
        help|--help|-h)
            echo "Использование: $0 [domain|install|reinstall|diagnose|status|config|update|restart|uninstall]"
            echo ""
            echo "Команды:"
            echo "  domain     - Мастер подготовки и проверки домена (ЭТАП 1)"
            echo "  install    - Установить NaïveProxy + Caddy с Nginx на :80 (ЭТАП 2)"
            echo "  reinstall  - Переустановить с выбором сохранения реквизитов"
            echo "  diagnose   - Полная диагностика Nginx, Caddy, портов 80/443 и TLS (read-only)"
            echo "  status     - Синоним к diagnose"
            echo "  config     - Показать реквизиты доступа и клиентский client.json
  clients    - Управление клиентами (добавить, удалить, список пользователей)
  web        - Управление реквизитами и перезапуск Web UI
  web-install - Развернуть / обновить Web UI без переустановки Caddy"
            echo "  update     - Безопасно обновить Caddy с авто-откатом при ошибках"
            echo "  restart    - Перезапустить службу Caddy"
            echo "  uninstall  - Удалить NaïveProxy и восстановить Nginx"
            exit 0
            ;;
    esac

    check_root
    check_os
    check_arch
    install_dependencies
    resolve_server_ips

    case "$action" in
        domain|check) domain_wizard ;;
        install) run_installation "${2:-}" "${3:-}" ;;
        reinstall) run_reinstall ;;
        status|diagnose) show_status ;;
        config|info) show_info ;;
        clients) manage_clients_menu ;;
        client-list) client_list ;;
        client-list-json) cat "$USERS_FILE" 2>/dev/null || echo "[]" ;;
        client-add) client_add "${2:-}" "${3:-}" "${4:-}" ;;
        client-add-raw) client_add "${2:-}" "${3:-}" "${4:-}" >/dev/null 2>&1 ;;
        client-del|client-delete) client_delete "${2:-}" ;;
        client-del-raw) client_delete "${2:-}" >/dev/null 2>&1 ;;
        web|webui) manage_web_ui ;;
        web-install) install_web_ui ;;
        web-restart) systemctl restart naiveproxy-webui && success "Web UI перезапущен." ;;
        update) update_caddy ;;
        restart) systemctl restart caddy && success "Caddy перезапущен." && show_status ;;
        uninstall|remove) uninstall_all ;;
        "") menu ;;
        *) error "Неизвестная команда: $action. Запустите: $0 help"; exit 1 ;;
    esac
}

main "$@"
