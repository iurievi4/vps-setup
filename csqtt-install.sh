#!/usr/bin/env bash
# ==============================================================================
# CSQTT Server Installer & Manager (Version-Agnostic)
# Autonomous management script for official Linux CSQTT Server (amurcanov/csqtt)
# Dynamically resolves upstream versions, Rust requirements, and build scripts.
# License: PolyForm Noncommercial 1.0.0
# ==============================================================================

set -u

# --- Configuration & Fixed System Paths ---
readonly SCRIPT_VERSION="3.0.0"
readonly UPSTREAM_REPO="amurcanov/csqtt"
readonly UPSTREAM_URL="https://github.com/${UPSTREAM_REPO}.git"

readonly BIN_DIR="/usr/local/bin"
readonly BIN_PATH="${BIN_DIR}/csqtt"
readonly BIN_BACKUP="${BIN_DIR}/csqtt.backup"

readonly CONFIG_DIR="/etc/csqtt"
readonly CONFIG_FILE="${CONFIG_DIR}/csqtt.conf"
readonly VERSION_FILE="${CONFIG_DIR}/version.info"
readonly CONFIG_BACKUP_DIR="${CONFIG_DIR}/backup"

readonly DATA_DIR="/var/lib/csqtt"
readonly LOG_DIR="/var/log/csqtt"
readonly SYSTEM_BACKUP_DIR="/var/backups/csqtt"

readonly SERVICE_NAME="csqtt"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# --- Styling & Colors (ANSI Escapes) ---
if [ -t 1 ]; then
    readonly C_RESET=$'\033[0m'
    readonly C_RED=$'\033[0;31m'
    readonly C_GREEN=$'\033[0;32m'
    readonly C_YELLOW=$'\033[1;33m'
    readonly C_BLUE=$'\033[0;34m'
    readonly C_CYAN=$'\033[0;36m'
    readonly C_BOLD=$'\033[1m'
else
    readonly C_RESET=''
    readonly C_RED=''
    readonly C_GREEN=''
    readonly C_YELLOW=''
    readonly C_BLUE=''
    readonly C_CYAN=''
    readonly C_BOLD=''
fi

# --- Logging Helpers ---
log_ok()    { echo -e "  [${C_GREEN}OK${C_RESET}] $*"; }
log_info()  { echo -e "  [${C_BLUE}INFO${C_RESET}] $*"; }
log_warn()  { echo -e "  [${C_YELLOW}WARN${C_RESET}] $*"; }
log_err()   { echo -e "  [${C_RED}ERROR${C_RESET}] $*"; }
log_step()  { echo -e "  [${C_CYAN}$1${C_RESET}] $2"; }

# --- Architecture Detection ---
detect_arch() {
    local raw_arch
    raw_arch="$(uname -m)"
    case "${raw_arch}" in
        x86_64|amd64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        armv7*|armhf)
            echo "armv7"
            ;;
        *)
            echo "unsupported"
            ;;
    esac
}

get_musl_target() {
    local arch="$1"
    case "${arch}" in
        amd64) echo "x86_64-unknown-linux-musl" ;;
        arm64) echo "aarch64-unknown-linux-musl" ;;
        armv7) echo "armv7-unknown-linux-musleabihf" ;;
        *)     echo "" ;;
    esac
}

# --- Pre-Flight System Checks ---
run_preflight_checks() {
    local quiet="${1:-0}"
    local failed=0

    # 1. Root check
    if [ "$(id -u)" -ne 0 ]; then
        [ "${quiet}" -eq 0 ] && log_err "Скрипт должен быть запущен с правами root!"
        return 1
    fi
    [ "${quiet}" -eq 0 ] && log_ok "Root-доступ"

    # 2. OS check
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}" in
            debian|ubuntu)
                [ "${quiet}" -eq 0 ] && log_ok "${PRETTY_NAME:-$ID}"
                ;;
            *)
                [ "${quiet}" -eq 0 ] && log_warn "Дистрибутив ${ID:-неизвестно}. Рекомендуется Debian или Ubuntu."
                ;;
        esac
    else
        [ "${quiet}" -eq 0 ] && log_err "Не удалось определить ОС (/etc/os-release отсутствует)."
        failed=1
    fi

    # 3. Architecture check
    local arch
    arch="$(detect_arch)"
    if [ "${arch}" = "unsupported" ]; then
        [ "${quiet}" -eq 0 ] && log_err "Архитектура $(uname -m) не поддерживается (поддерживаются amd64, arm64, armv7)."
        return 1
    fi
    [ "${quiet}" -eq 0 ] && log_ok "Архитектура: ${arch} ($(uname -m))"

    # 4. systemd check
    if pidof systemd >/dev/null 2>&1 || [ -d /run/systemd/system ]; then
        [ "${quiet}" -eq 0 ] && log_ok "systemd"
    else
        [ "${quiet}" -eq 0 ] && log_err "systemd не обнаружен. CSQTT требует systemd."
        return 1
    fi

    # 5. Disk space check
    local free_mb
    free_mb=$(df -m /usr/local | awk 'NR==2 {print $4}')
    if [ -n "${free_mb}" ] && [ "${free_mb}" -lt 500 ]; then
        [ "${quiet}" -eq 0 ] && log_warn "Свободно на диске ${free_mb} MB. Рекомендуется минимум 1 GB для сборки."
    else
        local free_gb
        free_gb=$(df -h /usr/local | awk 'NR==2 {print $4}')
        [ "${quiet}" -eq 0 ] && log_ok "Свободно на диске: ${free_gb}"
    fi

    # 6. Existing status
    if [ -f "${BIN_PATH}" ]; then
        local cur_ver="установлен"
        [ -f "${VERSION_FILE}" ] && cur_ver="$(grep -E '^CSQTT_VERSION=' "${VERSION_FILE}" 2>/dev/null | cut -d= -f2-)"
        [ "${quiet}" -eq 0 ] && log_info "CSQTT Server уже установлен (версия: ${cur_ver})"
        
        if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
            [ "${quiet}" -eq 0 ] && log_info "Сервис: active (running)"
        else
            [ "${quiet}" -eq 0 ] && log_info "Сервис: не активен или остановлен"
        fi
    else
        [ "${quiet}" -eq 0 ] && echo -e "  [${C_BLUE}INFO${C_RESET}] CSQTT Server: не установлен"
    fi

    return "${failed}"
}

# --- Base Dependencies ---
ensure_base_tools() {
    local missing_pkgs=()
    for pkg in curl jq git build-essential pkg-config libssl-dev python3 python3-pip iptables iproute2; do
        if ! dpkg -s "${pkg}" >/dev/null 2>&1; then
            missing_pkgs+=("${pkg}")
        fi
    done

    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        log_info "Установка базовых системных зависимостей: ${missing_pkgs[*]}..."
        apt-get update -qq >/dev/null 2>&1 || true
        # shellcheck disable=SC2068
        apt-get install -y -qq ${missing_pkgs[@]} >/dev/null 2>&1 || {
            log_err "Не удалось установить базовые пакеты."
            return 1
        }
        log_ok "Базовые пакеты установлены"
    fi
    return 0
}

# --- Dynamic Upstream Version Discovery ---
fetch_upstream_version() {
    local tag=""
    local api_url="https://api.github.com/repos/${UPSTREAM_REPO}/releases/latest"
    local release_json
    release_json=$(curl -fsSLm 7 "${api_url}" 2>/dev/null || echo "")

    if [ -n "${release_json}" ] && command -v jq >/dev/null 2>&1; then
        tag=$(echo "${release_json}" | jq -r '.tag_name // empty' 2>/dev/null || echo "")
    fi

    # Fallback to git ls-remote if GitHub API is restricted/rate-limited
    if [ -z "${tag}" ]; then
        tag=$(git ls-remote --tags --refs "${UPSTREAM_URL}" 2>/dev/null | awk -F/ '{print $NF}' | grep -v '\^{}' | sort -V | tail -n1 || echo "")
    fi

    if [ -z "${tag}" ]; then
        tag="main"
    fi

    echo "${tag}"
}

# --- Dynamic Rust Version Resolution ---
detect_and_prepare_rust() {
    local src_dir="$1"

    # Ensure rustup is installed
    if [ -f "$HOME/.cargo/env" ]; then
        # shellcheck disable=SC1091
        . "$HOME/.cargo/env"
    fi

    if ! command -v rustup >/dev/null 2>&1; then
        log_info "Установка rustup..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain none >/dev/null 2>&1
        if [ -f "$HOME/.cargo/env" ]; then
            # shellcheck disable=SC1091
            . "$HOME/.cargo/env"
        fi
    fi

    if ! command -v rustup >/dev/null 2>&1; then
        log_err "Не удалось инициализировать rustup."
        return 1
    fi

    # Check if upstream specifies rust-version in Cargo.toml
    local required_rust=""
    local cargo_toml="${src_dir}/rust-server/Cargo.toml"
    [ ! -f "${cargo_toml}" ] && cargo_toml="${src_dir}/Cargo.toml"

    if [ -f "${cargo_toml}" ]; then
        required_rust=$(grep -E '^\s*rust-version\s*=' "${cargo_toml}" 2>/dev/null | head -n1 | sed -E 's/.*"([^"]+)".*/\1/' || echo "")
    fi

    if [ -n "${required_rust}" ]; then
        log_info "Обнаружено требование к версии Rust в Cargo.toml: ${required_rust}"
        if rustup toolchain install "${required_rust}" >/dev/null 2>&1; then
            rustup default "${required_rust}" >/dev/null 2>&1
            log_ok "Активирован требуемый тулчейн: $(rustc --version 2>/dev/null || echo "${required_rust}")"
        else
            log_warn "Версия ${required_rust} недоступна напрямую, установка стабильного Rust..."
            rustup toolchain install stable >/dev/null 2>&1
            rustup default stable >/dev/null 2>&1
            log_ok "Активирован тулчейн: $(rustc --version)"
        fi
    else
        log_info "Версия Rust в Cargo.toml не зафиксирована. Проверка стабильного тулчейна..."
        rustup toolchain install stable >/dev/null 2>&1
        rustup default stable >/dev/null 2>&1
        log_ok "Активирован тулчейн: $(rustc --version)"
    fi

    # Ensure musl target for target arch
    local arch
    arch="$(detect_arch)"
    local target
    target="$(get_musl_target "${arch}")"
    if [ -n "${target}" ]; then
        rustup target add "${target}" >/dev/null 2>&1 || true
    fi

    return 0
}

# --- Dynamic Zig & Cargo-Zigbuild Support ---
ensure_zig_and_zigbuild() {
    # Zig
    if ! command -v zig >/dev/null 2>&1; then
        log_info "Проверка наличия компилятора Zig для сборки..."
        if apt-get install -y -qq zig >/dev/null 2>&1; then
            log_ok "Zig установлен: $(zig version 2>/dev/null || echo 'ok')"
        elif snap install zig --classic --beta >/dev/null 2>&1; then
            log_ok "Zig установлен через snap"
        else
            local zig_tmp="/tmp/zig_dl_$$"
            mkdir -p "${zig_tmp}"
            local zig_url="https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz"
            [ "$(detect_arch)" = "arm64" ] && zig_url="https://ziglang.org/download/0.13.0/zig-linux-aarch64-0.13.0.tar.xz"
            if curl -fsSL -o "${zig_tmp}/zig.tar.xz" "${zig_url}" 2>/dev/null; then
                tar -xf "${zig_tmp}/zig.tar.xz" -C "${zig_tmp}" 2>/dev/null
                local zig_bin
                zig_bin=$(find "${zig_tmp}" -type f -name "zig" | head -n1)
                if [ -n "${zig_bin}" ]; then
                    cp -a "${zig_bin}" /usr/local/bin/zig
                    chmod +x /usr/local/bin/zig
                    log_ok "Zig установлен в /usr/local/bin/zig"
                fi
            fi
            rm -rf "${zig_tmp}"
        fi
    fi

    # cargo-zigbuild
    if ! command -v cargo-zigbuild >/dev/null 2>&1; then
        if pip3 install cargo-zigbuild --break-system-packages >/dev/null 2>&1 || pip3 install cargo-zigbuild >/dev/null 2>&1; then
            log_ok "cargo-zigbuild готов к использованию"
        elif cargo install cargo-zigbuild --locked >/dev/null 2>&1; then
            log_ok "cargo-zigbuild установлен через cargo"
        fi
    fi
}

# --- Upstream Build Process ---
build_upstream_server() {
    local target_tag="$1"
    local dest_bin="$2"
    local arch
    arch="$(detect_arch)"

    ensure_base_tools || return 1

    local src_dir="/tmp/csqtt_build_src_$$"
    rm -rf "${src_dir}"

    log_info "Клонирование ${UPSTREAM_REPO} (метка: ${target_tag})..."
    if ! git clone --depth 1 --branch "${target_tag}" "${UPSTREAM_URL}" "${src_dir}" 2>/dev/null; then
        log_warn "Ветка/тег ${target_tag} не найдены напрямую. Клонирование репозитория по умолчанию..."
        if ! git clone --depth 1 "${UPSTREAM_URL}" "${src_dir}"; then
            log_err "Не удалось клонировать ${UPSTREAM_URL}"
            rm -rf "${src_dir}"
            return 1
        fi
    fi

    detect_and_prepare_rust "${src_dir}" || return 1
    ensure_zig_and_zigbuild

    cd "${src_dir}" || return 1

    # 1. Check for official upstream build_linux.sh
    local build_script
    build_script=$(find "${src_dir}" -maxdepth 2 -type f -name "build_linux.sh" | head -n1)

    local target_bin_name="csqtt-linux-${arch}"

    if [ -n "${build_script}" ] && [ -f "${build_script}" ]; then
        log_ok "Используем официальный сборочный скрипт: ${build_script}"
        chmod +x "${build_script}"
        (
            cd "$(dirname "${build_script}")" || exit 1
            bash "$(basename "${build_script}")"
        ) || {
            log_warn "Официальный build_linux.sh сообщил о предупреждении. Проверка собранных файлов..."
        }
    fi

    # Check if target binary was produced by build_linux.sh
    local found_bin=""
    found_bin=$(find "${src_dir}" -type f -name "${target_bin_name}" | head -n1)

    # 2. If target binary was not produced, build using cargo-zigbuild or cargo for current architecture
    if [ -z "${found_bin}" ] || [ ! -f "${found_bin}" ]; then
        local server_dir="${src_dir}/rust-server"
        [ ! -d "${server_dir}" ] && server_dir="${src_dir}"

        local musl_target
        musl_target="$(get_musl_target "${arch}")"

        log_info "Сборка сервера под текущую архитектуру (${arch})..."
        (
            cd "${server_dir}" || exit 1
            if command -v cargo-zigbuild >/dev/null 2>&1 && [ -n "${musl_target}" ]; then
                cargo zigbuild --release --target "${musl_target}"
            else
                cargo build --release
            fi
        ) || {
            log_err "Сборка Cargo завершилась с ошибкой."
            rm -rf "${src_dir}"
            return 1
        }

        found_bin=$(find "${server_dir}/target" -type f -executable ! -name "*.so" ! -name "*.d" | grep -E "release/(csqtt|rust-server|server)$" | head -n1)
        if [ -z "${found_bin}" ]; then
            found_bin=$(find "${server_dir}/target" -type f -executable ! -name "*.so" ! -name "*.d" | head -n1)
        fi
    fi

    if [ -n "${found_bin}" ] && [ -f "${found_bin}" ]; then
        cp -a "${found_bin}" "${dest_bin}"
        chmod 755 "${dest_bin}"
        rm -rf "${src_dir}"
        log_ok "Серверный бинарник готов: $(basename "${dest_bin}")"
        return 0
    else
        log_err "Не удалось получить скомпилированный бинарный файл CSQTT Server."
        rm -rf "${src_dir}"
        return 1
    fi
}

# --- Networking & System Config ---
configure_networking() {
    local current_fwd
    current_fwd="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
    if [ "${current_fwd}" != "1" ]; then
        log_info "Включение IP Forwarding (net.ipv4.ip_forward=1)..."
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
        if ! grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf /etc/sysctl.d/* 2>/dev/null; then
            echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-csqtt-forward.conf
        fi
        log_ok "IP Forwarding активирован"
    fi
}

get_public_ip() {
    local ip
    ip=$(curl -fs4m 3 https://api.ipify.org 2>/dev/null || \
         curl -fs4m 3 https://icanhazip.com 2>/dev/null || \
         ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7}' | tr -d ' \n')
    echo "${ip:-127.0.0.1}"
}

rotate_config_backups() {
    mkdir -p "${CONFIG_BACKUP_DIR}"
    if [ -f "${CONFIG_FILE}" ]; then
        local ts
        ts="$(date +'%Y%m%d_%H%M%S')"
        cp -a "${CONFIG_FILE}" "${CONFIG_BACKUP_DIR}/csqtt_${ts}.conf"
        log_ok "Резервная копия конфигурации: ${CONFIG_BACKUP_DIR}/csqtt_${ts}.conf"
        
        local count
        count=$(find "${CONFIG_BACKUP_DIR}" -maxdepth 1 -name 'csqtt_*.conf' | wc -l)
        if [ "${count}" -gt 10 ]; then
            find "${CONFIG_BACKUP_DIR}" -maxdepth 1 -name 'csqtt_*.conf' -type f -printf '%T+ %p\n' | \
                sort | head -n "$((count - 10))" | awk '{print $2}' | xargs -r rm -f
        fi
    fi
}

configure_firewall() {
    local port="$1"
    if command -v ufw >/dev/null 2>&1; then
        if ufw status | grep -q "Status: active"; then
            log_info "Обнаружен активный UFW Firewall"
            log_info "Для CSQTT требуется входящий UDP/TCP порт: ${port}"
            
            local do_ufw="y"
            if [ -t 0 ]; then
                read -r -p "  Добавить правило UFW allow ${port}/udp и ${port}/tcp? [Y/n]: " ans
                ans=$(echo "${ans:-y}" | tr '[:upper:]' '[:lower:]')
                if [[ "${ans}" =~ ^(n|no)$ ]]; then
                    do_ufw="n"
                fi
            fi

            if [ "${do_ufw}" = "y" ]; then
                ufw allow "${port}/udp" comment "CSQTT Server UDP" >/dev/null 2>&1
                ufw allow "${port}/tcp" comment "CSQTT Server TCP" >/dev/null 2>&1
                log_ok "Правила добавлены в UFW: порт ${port} (UDP/TCP)"
            else
                log_warn "Правило UFW пропущено по запросу пользователя. Не забудьте открыть порт ${port} вручную."
            fi
        fi
    fi
}

create_or_update_systemd_service() {
    cat <<EOF > "${SERVICE_FILE}"
[Unit]
Description=CSQTT Linux Server (amurcanov/csqtt)
After=network.target network-online.target
Wants=network-online.target
Documentation=https://github.com/amurcanov/csqtt

[Service]
Type=simple
User=root
WorkingDirectory=${CONFIG_DIR}
ExecStart=${BIN_PATH}
Restart=on-failure
RestartSec=3s
TimeoutStartSec=15
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1
    log_ok "Сервис systemd настроен: ${SERVICE_FILE}"
}

# --- Installation Command ---
install_csqtt() {
    echo ""
    echo -e "${C_BOLD}=== УСТАНОВКА CSQTT LINUX SERVER (${UPSTREAM_REPO}) ===${C_RESET}"
    echo -e "  Лицензия: ${C_CYAN}PolyForm Noncommercial 1.0.0${C_RESET}"
    echo -e "  Назначение: ${C_CYAN}Автономный Linux-сервер (без установки Android APK)${C_RESET}"
    echo ""

    run_preflight_checks 0 || return 1
    configure_networking

    local upstream_tag
    upstream_tag="$(fetch_upstream_version)"
    log_info "Актуальная версия upstream: ${upstream_tag}"

    local tmp_bin="/tmp/csqtt.install.$$"
    build_upstream_server "${upstream_tag}" "${tmp_bin}" || {
        log_err "Сборка не удалась. Установка прервана."
        return 1
    }

    mkdir -p "${BIN_DIR}" "${CONFIG_DIR}" "${DATA_DIR}" "${LOG_DIR}" "${SYSTEM_BACKUP_DIR}"
    chmod 755 "${CONFIG_DIR}" "${DATA_DIR}" "${LOG_DIR}"

    if [ -f "${BIN_PATH}" ]; then
        cp -a "${BIN_PATH}" "${BIN_BACKUP}"
        log_ok "Резервная копия старого бинарника: ${BIN_BACKUP}"
    fi

    mv "${tmp_bin}" "${BIN_PATH}"
    chmod 755 "${BIN_PATH}"
    log_ok "Бинарный файл установлен в ${BIN_PATH}"

    # Query binary --help for transparency
    echo ""
    log_info "Параметры запуска установленного бинарника (${BIN_PATH} --help):"
    local help_txt
    help_txt="$("${BIN_PATH}" --help 2>&1 || "${BIN_PATH}" -h 2>&1 || echo "")"
    if [ -n "${help_txt}" ]; then
        echo "----------------------------------------------------"
        echo "${help_txt}" | head -n 15
        echo "----------------------------------------------------"
    fi

    local port="3478"
    if [ -t 0 ]; then
        read -r -p "  Укажите порт для CSQTT Server [по умолчанию 3478]: " user_port
        port="${user_port:-3478}"
    fi

    configure_firewall "${port}"

    # Save version info
    cat <<EOF > "${VERSION_FILE}"
CSQTT_VERSION=${upstream_tag}
RUST_VERSION=$(rustc --version 2>/dev/null || echo "unknown")
ARCH=$(detect_arch)
INSTALLED_AT=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
UPSTREAM=${UPSTREAM_URL}
EOF
    chmod 644 "${VERSION_FILE}"

    # Save config file
    if [ ! -f "${CONFIG_FILE}" ]; then
        cat <<EOF > "${CONFIG_FILE}"
# CSQTT Server Configuration
PORT=${port}
DATA_DIR=${DATA_DIR}
LOG_DIR=${LOG_DIR}
CREATED_AT=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
EOF
        chmod 600 "${CONFIG_FILE}"
        log_ok "Конфигурация создана: ${CONFIG_FILE}"
    fi

    create_or_update_systemd_service

    log_info "Запуск службы ${SERVICE_NAME}..."
    systemctl restart "${SERVICE_NAME}"
    sleep 2

    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        log_ok "Служба ${SERVICE_NAME} успешно активна и работает!"
        show_connection_card
        return 0
    else
        log_warn "Служба зарегистрирована, но ожидает параметры или хэш звонка."
        journalctl -u "${SERVICE_NAME}" -n 10 --no-pager
        return 0
    fi
}

# --- Dynamic Update Command ---
update_csqtt() {
    echo ""
    echo -e "${C_BOLD}=== ОБНОВЛЕНИЕ CSQTT SERVER ===${C_RESET}"
    echo ""

    if [ ! -f "${BIN_PATH}" ]; then
        log_err "CSQTT не установлен. Используйте пункт установки."
        return 1
    fi

    local cur_csqtt="неизвестно"
    local cur_rust="неизвестно"
    if [ -f "${VERSION_FILE}" ]; then
        cur_csqtt="$(grep -E '^CSQTT_VERSION=' "${VERSION_FILE}" 2>/dev/null | cut -d= -f2-)"
        cur_rust="$(grep -E '^RUST_VERSION=' "${VERSION_FILE}" 2>/dev/null | cut -d= -f2-)"
    fi

    echo "Текущее состояние сервера:"
    echo "  CSQTT : ${cur_csqtt}"
    echo "  Rust  : ${cur_rust}"
    echo ""
    log_info "Проверка актуального состояния в ${UPSTREAM_REPO}..."

    local upstream_tag
    upstream_tag="$(fetch_upstream_version)"
    echo "Доступный upstream: ${upstream_tag}"
    echo ""

    if [ "${cur_csqtt}" != "неизвестно" ] && [ "${cur_csqtt}" = "${upstream_tag}" ]; then
        log_ok "На сервере уже установлена последняя версия upstream (${upstream_tag})."
        if [ -t 0 ]; then
            read -r -p "Пересобрать и принудительно обновить? [y/N]: " force_ans
            force_ans=$(echo "${force_ans:-n}" | tr '[:upper:]' '[:lower:]')
            if [[ ! "${force_ans}" =~ ^(y|yes)$ ]]; then
                echo "Обновление отменено."
                return 0
            fi
        else
            return 0
        fi
    fi

    if [ -t 0 ]; then
        read -r -p "Запустить процедуру обновления до ${upstream_tag}? [Y/n]: " do_update
        do_update=$(echo "${do_update:-y}" | tr '[:upper:]' '[:lower:]')
        if [[ "${do_update}" =~ ^(n|no)$ ]]; then
            echo "Обновление отменено."
            return 0
        fi
    fi

    echo ""
    log_step "1/7" "Создание страховочных бэкапов бинарника и конфигурации..."
    rotate_config_backups
    cp -a "${BIN_PATH}" "${BIN_BACKUP}"

    log_step "2/7" "Клонирование актуального исходного кода..."
    local tmp_bin="/tmp/csqtt.update.$$"

    log_step "3/7" "Определение требований Rust и проверка тулчейна..."
    log_step "4/7" "Проверка официального сборочного окружения (Zig/build_linux)..."
    log_step "5/7" "Сборка нового серверного бинарника..."
    build_upstream_server "${upstream_tag}" "${tmp_bin}" || {
        log_err "Сборка новой версии завершилась ошибкой. Текущая версия сохранена."
        return 1
    }

    log_step "6/7" "Атомарная замена бинарника на ${BIN_PATH}..."
    mv "${tmp_bin}" "${BIN_PATH}"
    chmod 755 "${BIN_PATH}"

    # Update version info
    cat <<EOF > "${VERSION_FILE}"
CSQTT_VERSION=${upstream_tag}
RUST_VERSION=$(rustc --version 2>/dev/null || echo "unknown")
ARCH=$(detect_arch)
UPDATED_AT=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
UPSTREAM=${UPSTREAM_URL}
EOF

    log_step "7/7" "Перезапуск службы и Health Check..."
    systemctl restart "${SERVICE_NAME}"
    sleep 2

    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        log_ok "CSQTT Server успешно обновлён до версии ${upstream_tag}!"
        return 0
    else
        log_err "Служба не запустилась после обновления!"
        journalctl -u "${SERVICE_NAME}" -n 15 --no-pager
        log_warn "Выполняется автоматический откат на предыдущий рабочий бинарник..."
        if [ -f "${BIN_BACKUP}" ]; then
            cp -a "${BIN_BACKUP}" "${BIN_PATH}"
            systemctl restart "${SERVICE_NAME}"
            sleep 1
            if systemctl is-active --quiet "${SERVICE_NAME}"; then
                log_ok "Откат успешен: предыдущая версия восстановлена и работает."
            fi
        fi
        return 1
    fi
}

# --- Service Management Functions ---
check_status() {
    echo ""
    echo -e "${C_BOLD}=== СТАТУС CSQTT SERVICE ===${C_RESET}"
    echo ""
    if [ ! -f "${SERVICE_FILE}" ]; then
        log_warn "Служба ${SERVICE_NAME}.service не установлена."
        return 1
    fi
    systemctl status "${SERVICE_NAME}" --no-pager
}

restart_service() {
    echo ""
    log_info "Перезапуск службы ${SERVICE_NAME}..."
    if systemctl restart "${SERVICE_NAME}"; then
        sleep 1
        if systemctl is-active --quiet "${SERVICE_NAME}"; then
            log_ok "Служба ${SERVICE_NAME} успешно перезапущена и активна."
        else
            log_err "Служба ${SERVICE_NAME} не смогла запуститься."
            journalctl -u "${SERVICE_NAME}" -n 10 --no-pager
        fi
    else
        log_err "Не удалось отправить команду перезапуска в systemd."
    fi
}

stop_service() {
    echo ""
    log_info "Остановка службы ${SERVICE_NAME}..."
    if systemctl stop "${SERVICE_NAME}"; then
        log_ok "Служба ${SERVICE_NAME} остановлена."
    else
        log_err "Не удалось остановить службу ${SERVICE_NAME}."
    fi
}

show_logs() {
    echo ""
    echo -e "${C_BOLD}=== ПОСЛЕДНИЕ ЛОГИ CSQTT (Ctrl+C для выхода) ===${C_RESET}"
    echo ""
    journalctl -u "${SERVICE_NAME}" -n 50 --no-pager -f
}

show_config() {
    echo ""
    echo -e "${C_BOLD}=== КОНФИГУРАЦИЯ CSQTT ===${C_RESET}"
    echo ""
    if [ -f "${CONFIG_FILE}" ]; then
        echo -e "Файл: ${C_CYAN}${CONFIG_FILE}${C_RESET}"
        echo "----------------------------------------------------"
        cat "${CONFIG_FILE}"
        echo ""
        echo "----------------------------------------------------"
    fi
    if [ -f "${VERSION_FILE}" ]; then
        echo -e "Версия: ${C_CYAN}${VERSION_FILE}${C_RESET}"
        echo "----------------------------------------------------"
        cat "${VERSION_FILE}"
        echo "----------------------------------------------------"
    fi
}

show_android_info() {
    echo ""
    echo -e "╔══════════════════════════════════════════════════════════════╗"
    echo -e "║                 ${C_BOLD}=== CSQTT ANDROID CLIENT ===${C_RESET}                 ║"
    echo -e "╠══════════════════════════════════════════════════════════════╣"
    echo -e "║  Android-клиент устанавливается на телефон, а не на VPS.     ║"
    echo -e "║                                                              ║"
    echo -e "║  Официальный репозиторий:                                    ║"
    echo -e "║  ${C_CYAN}https://github.com/amurcanov/csqtt${C_RESET}                          ║"
    echo -e "║                                                              ║"
    echo -e "║  APK в разделе Releases:                                     ║"
    echo -e "║    • CSQTT-arm64-v8a.apk  (для большинства современных тел.) ║"
    echo -e "║    • CSQTT-armeabi-v7a.apk (для старых устройств)            ║"
    echo -e "║    • CSQTT-universal.apk   (универсальный)                   ║"
    echo -e "║    • CSQTT-x86_64.apk      (для эмуляторов)                  ║"
    echo -e "║                                                              ║"
    echo -e "║  Схема подключения: csqtt://connect                          ║"
    echo -e "║  Протокол: TURN / RTP (маскировка под медиатрафик VK)        ║"
    echo -e "╚══════════════════════════════════════════════════════════════╝"
    echo ""
}

show_connection_card() {
    local ip
    ip="$(get_public_ip)"
    local status="INACTIVE"
    local autostart="DISABLED"

    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        status="ACTIVE"
    fi
    if systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
        autostart="ENABLED"
    fi

    echo ""
    echo "===================================================="
    echo "         CSQTT LINUX SERVER УСТАНОВЛЕН             "
    echo "===================================================="
    echo ""
    echo -e "  Статус:       ${C_GREEN}${status}${C_RESET}"
    echo -e "  Автозапуск:   ${C_GREEN}${autostart}${C_RESET}"
    echo -e "  Лицензия:     PolyForm Noncommercial 1.0.0"
    echo ""
    echo "  SERVER:"
    echo -e "    IP:         ${C_CYAN}${ip}${C_RESET}"
    echo -e "    Binary:     ${BIN_PATH}"
    echo -e "    Config:     ${CONFIG_FILE}"
    echo ""
    echo "  ANDROID CLIENT:"
    echo "    Клиент:     Официальное приложение CSQTT (на телефон)"
    echo -e "    Releases:   ${C_CYAN}https://github.com/${UPSTREAM_REPO}/releases${C_RESET}"
    echo ""
    echo "===================================================="
    echo ""
}

run_diagnostics() {
    echo ""
    echo -e "${C_BOLD}CSQTT DIAGNOSTICS${C_RESET}"
    echo "────────────────────────────────────────────────────"

    local ver="Not installed"
    if [ -f "${VERSION_FILE}" ]; then
        ver="$(grep -E '^CSQTT_VERSION=' "${VERSION_FILE}" 2>/dev/null | cut -d= -f2-)"
    elif [ -f "${BIN_PATH}" ]; then
        ver="Installed"
    fi
    printf "  %-14s: %s\n" "CSQTT Version" "${ver}"

    local rust_ver="N/A"
    if command -v rustc >/dev/null 2>&1; then
        rust_ver="$(rustc --version)"
    fi
    printf "  %-14s: %s\n" "Rust Toolchain" "${rust_ver}"

    local status_str="NOT INSTALLED"
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        status_str="${C_GREEN}ACTIVE${C_RESET}"
    elif [ -f "${SERVICE_FILE}" ]; then
        status_str="${C_YELLOW}STOPPED${C_RESET}"
    fi
    printf "  %-14s: %b\n" "Status" "${status_str}"

    local auto_str="DISABLED"
    if systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
        auto_str="${C_GREEN}ENABLED${C_RESET}"
    fi
    printf "  %-14s: %b\n" "Autostart" "${auto_str}"

    printf "  %-14s: %s\n" "Architecture" "$(detect_arch) ($(uname -m))"

    local bin_status="MISSING"
    if [ -x "${BIN_PATH}" ]; then
        bin_status="${C_GREEN}OK${C_RESET} (${BIN_PATH})"
    fi
    printf "  %-14s: %b\n" "Binary" "${bin_status}"

    local conf_status="MISSING"
    if [ -f "${CONFIG_FILE}" ]; then
        conf_status="${C_GREEN}OK${C_RESET} (${CONFIG_FILE})"
    fi
    printf "  %-14s: %b\n" "Config" "${conf_status}"

    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        local pid
        pid=$(systemctl show --property MainPID --value "${SERVICE_NAME}" 2>/dev/null || echo 0)
        if [ -n "${pid}" ] && [ "${pid}" -gt 0 ]; then
            local uptime
            uptime=$(ps -p "${pid}" -o etime= 2>/dev/null | tr -d ' ' || echo "N/A")
            local mem
            mem=$(ps -p "${pid}" -o rss= 2>/dev/null | awk '{printf "%.1f MB", $1/1024}' || echo "N/A")
            local cpu
            cpu=$(ps -p "${pid}" -o %cpu= 2>/dev/null | tr -d ' ' || echo "N/A")
            
            printf "  %-14s: %s\n" "PID" "${pid}"
            printf "  %-14s: %s\n" "Uptime" "${uptime}"
            printf "  %-14s: %s\n" "Memory" "${mem}"
            printf "  %-14s: %s%%\n" "CPU" "${cpu}"
        fi
    fi

    echo "────────────────────────────────────────────────────"
    echo ""
}

uninstall_csqtt() {
    echo ""
    echo -e "${C_BOLD}${C_RED}ВНИМАНИЕ! УДАЛЕНИЕ CSQTT SERVER${C_RESET}"
    echo ""
    echo "  Будет удалено:"
    echo "    • CSQTT binary (${BIN_PATH})"
    echo "    • systemd service (${SERVICE_FILE})"
    echo ""

    local keep_config="y"
    if [ -t 0 ]; then
        read -r -p "  Сохранить конфигурацию и данные? [Y/n]: " ans
        ans=$(echo "${ans:-y}" | tr '[:upper:]' '[:lower:]')
        if [[ "${ans}" =~ ^(n|no)$ ]]; then
            keep_config="n"
        fi
    fi

    log_info "Остановка и отключение службы ${SERVICE_NAME}..."
    systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
    systemctl disable "${SERVICE_NAME}" >/dev/null 2>&1 || true
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload

    rm -f "${BIN_PATH}" "${BIN_BACKUP}"
    log_ok "Бинарный файл удален."

    if [ "${keep_config}" = "y" ]; then
        local backup_dest="/etc/csqtt.backup-$(date +'%Y-%m-%d-%H%M%S')"
        if [ -d "${CONFIG_DIR}" ]; then
            cp -a "${CONFIG_DIR}" "${backup_dest}"
            log_ok "Конфигурация сохранена в: ${backup_dest}"
        fi
    else
        rm -rf "${CONFIG_DIR}" "${DATA_DIR}" "${LOG_DIR}"
        log_ok "Конфигурация и рабочие данные удалены."
    fi

    echo ""
    log_ok "CSQTT успешно удален с сервера."
    echo ""
}

# --- Interactive Main Menu ---
show_menu() {
    clear 2>/dev/null || true
    echo -e "${C_CYAN}╔════════════════════════════════════════════╗
║             CSQTT INSTALLER                ║
║        CSQTT Server Management             ║
╠════════════════════════════════════════════╣
║                                            ║
║  1. Установить CSQTT                       ║
║  2. Обновить CSQTT                         ║
║  3. Проверить статус                       ║
║  4. Перезапустить                          ║
║  5. Остановить                             ║
║  6. Показать логи                          ║
║  7. Показать конфигурацию                  ║
║  8. Данные для Android                     ║
║  9. Удалить CSQTT                          ║
║ 10. Диагностика                            ║
║                                            ║
║  0. Выход                                  ║
╚════════════════════════════════════════════╝${C_RESET}"

    local choice
    read -r -p "Выберите вариант [0-10]: " choice
    case "${choice}" in
        1)
            install_csqtt
            ;;
        2)
            update_csqtt
            ;;
        3)
            check_status
            ;;
        4)
            restart_service
            ;;
        5)
            stop_service
            ;;
        6)
            show_logs
            ;;
        7)
            show_config
            ;;
        8)
            show_android_info
            ;;
        9)
            uninstall_csqtt
            ;;
        10)
            run_diagnostics
            ;;
        0|q|Q)
            echo "Выход."
            exit 0
            ;;
        *)
            log_err "Неверный выбор."
            ;;
    esac

    echo ""
    read -r -p "Нажмите Enter для продолжения..." _
}

main() {
    local cmd="${1:-}"

    case "${cmd}" in
        install)
            install_csqtt
            ;;
        update)
            update_csqtt
            ;;
        status)
            check_status
            ;;
        restart)
            restart_service
            ;;
        stop)
            stop_service
            ;;
        logs)
            show_logs
            ;;
        config)
            show_config
            ;;
        android)
            show_android_info
            ;;
        diag|diagnostic|diagnostics)
            run_diagnostics
            ;;
        uninstall|remove)
            uninstall_csqtt
            ;;
        help|--help|-h)
            echo "Использование: bash $0 [команда]"
            echo ""
            echo "Команды:"
            echo "  install      - Установить CSQTT Server (динамический upstream build)"
            echo "  update       - Обновить CSQTT Server с автооткатом"
            echo "  status       - Проверить статус службы"
            echo "  restart      - Перезапустить службу"
            echo "  stop         - Остановить службу"
            echo "  logs         - Показать логи (journalctl)"
            echo "  config       - Показать файл конфигурации"
            echo "  android      - Показать информацию о клиентах Android"
            echo "  diag         - Запустить сводную диагностику"
            echo "  uninstall    - Удалить CSQTT Server с сервера"
            echo ""
            echo "Запуск без параметров открывает интерактивное меню."
            ;;
        "")
            while true; do
                show_menu
            done
            ;;
        *)
            log_err "Неизвестная команда: ${cmd}"
            echo "Используйте '$0 help' для справки."
            exit 1
            ;;
    esac
}

main "$@"
