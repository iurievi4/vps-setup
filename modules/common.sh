#!/usr/bin/env bash
# ==============================================================================
# NaïveProxy Manager — Модуль общих функций и констант (common.sh)
# Версия: 1.0.0-MODULAR
# ==============================================================================

NAIVE_MANAGER_VERSION="1.0.0-MODULAR"

# Цветовая палитра
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Системные пути и константы
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

# Глобальные переменные состояния
PROXY_TUNNEL_STATUS="NOT_VERIFIED"
SERVER_IPV4=""
SERVER_IPV6=""
SERVER_IPV6_OUTBOUND=""
SERVER_IPV6_STATUS="NONE"
SERVER_IPV6_LIST=()
CHECKED_DOMAIN=""
CHECKED_SERVER_IPV4=""
CHECKED_DNS_IPV4=""
CHECKED_STATUS="NOT_CONFIGURED"
CHECKED_TIMESTAMP=""
CHECKED_TIMESTAMP_EPOCH="0"
ARCH=""
GO_ARCH=""

# Логирование и вывод
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
step() { echo -e "\n${BOLD}${CYAN}[$1]${NC} ${BOLD}$2${NC}"; }

print_header() {
    clear 2>/dev/null || true
    echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}            NAÏVEPROXY MANAGER (v1.0.0-MODULAR)       ${NC}"
    echo -e "${BOLD}${CYAN}          (Nginx :80 Stub  +  Caddy :443 TLS)        ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════${NC}\n"
}

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

