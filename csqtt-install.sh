#!/usr/bin/env bash
# ==============================================================================
# CSQTT Server Installer & Manager (Version-Agnostic v3.1)
# Autonomous management script for official Linux CSQTT Server (amurcanov/csqtt)
# Architecture: amd64, arm64, armv7
# License: PolyForm Noncommercial 1.0.0
# ==============================================================================

set -Eeuo pipefail

# --- Configuration & Paths ---
readonly SCRIPT_VERSION="3.3.0"
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

readonly CACHE_DIR="/var/cache/csqtt"
readonly BIN_CACHE_DIR="${CACHE_DIR}/bin"
readonly CARGO_CACHE_DIR="${CACHE_DIR}/cargo_target"
readonly SRC_CACHE_DIR="${CACHE_DIR}/src"

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
    free_mb=$(df -m /usr/local | awk 'NR==2 {print $4}' || echo "0")
    if [ -n "${free_mb}" ] && [ "${free_mb}" -lt 500 ]; then
        [ "${quiet}" -eq 0 ] && log_warn "Свободно на диске ${free_mb} MB. Рекомендуется минимум 1 GB для компиляции."
    else
        local free_gb
        free_gb=$(df -h /usr/local | awk 'NR==2 {print $4}' || echo "N/A")
        [ "${quiet}" -eq 0 ] && log_ok "Свободно на диске: ${free_gb}"
    fi

    # 6. Existing status
    if [ -f "${BIN_PATH}" ]; then
        local cur_ver="установлен"
        [ -f "${VERSION_FILE}" ] && cur_ver="$(grep -E '^CSQTT_VERSION=' "${VERSION_FILE}" 2>/dev/null | cut -d= -f2- || echo 'установлен')"
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

# --- Dynamic Upstream Version & Release Resolution ---
fetch_upstream_release_info() {
    local arch="$1"
    local tag=""
    local download_url=""

    local api_url="https://api.github.com/repos/${UPSTREAM_REPO}/releases/latest"
    local release_json
    release_json=$(curl -fsSLm 7 "${api_url}" 2>/dev/null || echo "")

    if [ -n "${release_json}" ] && command -v jq >/dev/null 2>&1; then
        tag=$(echo "${release_json}" | jq -r '.tag_name // empty' 2>/dev/null || echo "")

        local arch_regex
        case "${arch}" in
            amd64) arch_regex="(amd64|x86_64)" ;;
            arm64) arch_regex="(arm64|aarch64)" ;;
            armv7) arch_regex="(armv7|armhf)" ;;
            *)     arch_regex="${arch}" ;;
        esac

        # Match Linux server assets in releases (strictly excluding Android .apk)
        download_url=$(echo "${release_json}" | jq -r \
            --arg re "${arch_regex}" \
            '.assets[]? | select((.name | test($re; "i")) and (.name | test("apk$"; "i") | not)) | .browser_download_url' 2>/dev/null | head -n1 || echo "")
    fi

    if [ -z "${tag}" ]; then
        tag=$(git ls-remote --tags --refs "${UPSTREAM_URL}" 2>/dev/null | awk -F/ '{print $NF}' | grep -v '\^{}' | sort -V | tail -n1 || echo "")
    fi

    if [ -z "${tag}" ]; then
        tag="main"
    fi

    echo "${tag}|${download_url}"
}

# --- Dynamic Rust Version Resolution ---
detect_and_prepare_rust() {
    local src_dir="$1"

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

    # Check toolchain requirement in order:
    # 1. rust-toolchain.toml
    # 2. rust-toolchain
    # 3. Cargo.toml (rust-version)
    local required_rust=""

    if [ -f "${src_dir}/rust-toolchain.toml" ]; then
        required_rust=$(grep -E '^\s*channel\s*=' "${src_dir}/rust-toolchain.toml" 2>/dev/null | head -n1 | sed -E 's/.*"([^"]+)".*/\1/' || echo "")
    elif [ -f "${src_dir}/rust-server/rust-toolchain.toml" ]; then
        required_rust=$(grep -E '^\s*channel\s*=' "${src_dir}/rust-server/rust-toolchain.toml" 2>/dev/null | head -n1 | sed -E 's/.*"([^"]+)".*/\1/' || echo "")
    elif [ -f "${src_dir}/rust-toolchain" ]; then
        required_rust=$(tr -d ' \r\n' < "${src_dir}/rust-toolchain" || echo "")
    elif [ -f "${src_dir}/rust-server/rust-toolchain" ]; then
        required_rust=$(tr -d ' \r\n' < "${src_dir}/rust-server/rust-toolchain" || echo "")
    fi

    if [ -z "${required_rust}" ]; then
        local cargo_toml="${src_dir}/rust-server/Cargo.toml"
        [ ! -f "${cargo_toml}" ] && cargo_toml="${src_dir}/Cargo.toml"
        if [ -f "${cargo_toml}" ]; then
            required_rust=$(grep -E '^\s*rust-version\s*=' "${cargo_toml}" 2>/dev/null | head -n1 | sed -E 's/.*"([^"]+)".*/\1/' || echo "")
        fi
    fi

    if [ -n "${required_rust}" ]; then
        log_info "Обнаружено требование к версии Rust: ${required_rust}"
        if rustup toolchain install "${required_rust}" >/dev/null 2>&1; then
            rustup default "${required_rust}" >/dev/null 2>&1
            log_ok "Активирован требуемый тулчейн: $(rustc --version 2>/dev/null || echo "${required_rust}")"
        else
            log_warn "Версия ${required_rust} недоступна напрямую, установка стабильного Rust..."
            rustup toolchain install stable >/dev/null 2>&1
            rustup default stable >/dev/null 2>&1
            log_ok "Активирован стабильный тулчейн: $(rustc --version 2>/dev/null || echo 'ok')"
        fi
    else
        log_info "Требование к версии Rust не зафиксировано. Проверка стабильного тулчейна..."
        rustup toolchain install stable >/dev/null 2>&1
        rustup default stable >/dev/null 2>&1
        log_ok "Активирован стабильный тулчейн: $(rustc --version 2>/dev/null || echo 'ok')"
    fi

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
    local arch
    arch="$(detect_arch)"

    # 1. Zig
    if ! command -v zig >/dev/null 2>&1; then
        log_info "Проверка наличия компилятора Zig для сборки..."
        if apt-get install -y -qq zig >/dev/null 2>&1; then
            log_ok "Zig установлен через apt: $(zig version 2>/dev/null || echo 'ok')"
        elif command -v snap >/dev/null 2>&1 && snap install zig --classic --beta >/dev/null 2>&1; then
            log_ok "Zig установлен через snap"
        else
            case "${arch}" in
                amd64|arm64)
                    local zig_tmp="/tmp/zig_dl_$$"
                    mkdir -p "${zig_tmp}"
                    local zig_url="https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz"
                    [ "${arch}" = "arm64" ] && zig_url="https://ziglang.org/download/0.13.0/zig-linux-aarch64-0.13.0.tar.xz"
                    if curl -fsSL -o "${zig_tmp}/zig.tar.xz" "${zig_url}" 2>/dev/null; then
                        tar -xf "${zig_tmp}/zig.tar.xz" -C "${zig_tmp}" 2>/dev/null || true
                        local zig_bin
                        zig_bin=$(find "${zig_tmp}" -type f -name "zig" | head -n1)
                        if [ -n "${zig_bin}" ]; then
                            cp -a "${zig_bin}" /usr/local/bin/zig
                            chmod +x /usr/local/bin/zig
                            log_ok "Zig установлен в /usr/local/bin/zig"
                        fi
                    fi
                    rm -rf "${zig_tmp}"
                    ;;
                armv7)
                    log_warn "Для armv7 компилятор Zig не найден в бинарных архивах. Сборка будет выполнена стандартным cargo."
                    ;;
            esac
        fi
    fi

    # 2. cargo-zigbuild
    if ! command -v cargo-zigbuild >/dev/null 2>&1; then
        if pip3 install cargo-zigbuild --break-system-packages >/dev/null 2>&1 || pip3 install cargo-zigbuild >/dev/null 2>&1; then
            log_ok "cargo-zigbuild готов к использованию"
        elif cargo install cargo-zigbuild --locked >/dev/null 2>&1; then
            log_ok "cargo-zigbuild установлен через cargo"
        fi
    fi
    return 0
}

# --- Upstream Build Process with Cache & SSH Resilience ---
build_upstream_server() {
    local target_tag="$1"
    local dest_bin="$2"
    local build_mode="${3:-fast}"
    local arch
    arch="$(detect_arch)"

    ensure_base_tools || return 1
    mkdir -p "${SRC_CACHE_DIR}" "${CARGO_CACHE_DIR}" "${LOG_DIR}"

    local src_dir="${SRC_CACHE_DIR}/csqtt-${target_tag}"
    if [ ! -d "${src_dir}/.git" ]; then
        log_info "Клонирование ${UPSTREAM_REPO} (метка: ${target_tag}) в кэш исходников..."
        rm -rf "${src_dir}"
        if ! git clone --depth 1 --branch "${target_tag}" "${UPSTREAM_URL}" "${src_dir}" 2>/dev/null; then
            log_warn "Ветка/тег ${target_tag} не найдены напрямую. Клонирование HEAD..."
            if ! git clone --depth 1 "${UPSTREAM_URL}" "${src_dir}"; then
                log_err "Не удалось клонировать ${UPSTREAM_URL}"
                rm -rf "${src_dir}"
                return 1
            fi
        fi
    else
        log_ok "Используются кэшированные исходники: ${src_dir}"
        ( cd "${src_dir}" && git fetch --depth 1 origin "${target_tag}" 2>/dev/null && git reset --hard "origin/${target_tag}" 2>/dev/null ) || true
    fi

    detect_and_prepare_rust "${src_dir}" || return 1

    local build_log="${LOG_DIR}/build-${target_tag}-${build_mode}.log"
    log_info "Режим сборки: ${C_CYAN}${build_mode}${C_RESET} (логирование: ${build_log})"
    log_info "Защита от обрыва SSH активна (игнорирование SIGHUP на время компиляции)..."

    export CARGO_TARGET_DIR="${CARGO_CACHE_DIR}/target"
    mkdir -p "${CARGO_TARGET_DIR}"

    local server_dir="${src_dir}/rust-server"
    [ ! -d "${server_dir}" ] && server_dir="${src_dir}"

    local target_bin_name="csqtt-linux-${arch}"

    # Execution inside subshell with SIGHUP trap protection
    local build_err=0
    (
        trap '' HUP
        cd "${server_dir}" || exit 1

        if [ "${build_mode}" = "full" ]; then
            log_info "Запуск полной оптимизированной сборки (upstream, LTO=fat, musl)..."
            ensure_zig_and_zigbuild

            local build_script
            build_script=$(find "${src_dir}" -maxdepth 2 -type f -name "build_linux.sh" | head -n1 || echo "")
            if [ -n "${build_script}" ] && [ -f "${build_script}" ]; then
                log_ok "Обнаружен официальный сборочный скрипт: ${build_script}"
                chmod +x "${build_script}"
                ( cd "$(dirname "${build_script}")" && bash "$(basename "${build_script}")" )
            else
                local musl_target
                musl_target="$(get_musl_target "${arch}")"
                if command -v cargo-zigbuild >/dev/null 2>&1 && [ -n "${musl_target}" ]; then
                    cargo zigbuild --release --target "${musl_target}"
                else
                    cargo build --release
                fi
            fi
        else
            # Fast build mode: standard release without heavy fat LTO bottleneck
            log_ok "Запуск быстрой release-сборки Cargo (без fat LTO)..."
            export RUSTFLAGS="-C lto=off -C codegen-units=16"
            cargo build --release
        fi
    ) 2>&1 | tee -a "${build_log}" || build_err=1

    if [ "${build_err}" -ne 0 ]; then
        log_warn "Процесс сборки завершился с предупреждениями или кодом ошибки. Проверка бинарника..."
    fi

    # Locate generated executable
    local found_bin=""
    found_bin=$(find "${src_dir}" -type f -name "${target_bin_name}" | head -n1 || echo "")
    if [ -z "${found_bin}" ] || [ ! -f "${found_bin}" ]; then
        found_bin=$(find "${CARGO_TARGET_DIR}" "${server_dir}/target" -type f -executable ! -name "*.so" ! -name "*.d" 2>/dev/null | grep -E "release/(csqtt|rust-server|server)$" | head -n1 || echo "")
        if [ -z "${found_bin}" ]; then
            found_bin=$(find "${CARGO_TARGET_DIR}" "${server_dir}/target" -type f -executable ! -name "*.so" ! -name "*.d" 2>/dev/null | head -n1 || echo "")
        fi
    fi

    if [ -n "${found_bin}" ] && [ -f "${found_bin}" ] && head -c 4 "${found_bin}" | grep -q "ELF"; then
        cp -a "${found_bin}" "${dest_bin}"
        chmod 755 "${dest_bin}"
        log_ok "Серверный бинарник успешно получен: $(basename "${dest_bin}")"
        return 0
    else
        log_err "Не удалось получить скомпилированный бинарный файл CSQTT Server. См. подробности в ${build_log}"
        return 1
    fi
}

# --- Obtain Binary Strategy: Cache First, Asset Second, Build Fallback ---
obtain_server_binary() {
    local target_tag="$1"
    local asset_url="$2"
    local dest_bin="$3"
    local build_mode="${4:-fast}"
    local arch
    arch="$(detect_arch)"

    mkdir -p "${BIN_CACHE_DIR}" "${CARGO_CACHE_DIR}" "${SRC_CACHE_DIR}"
    rm -f "${dest_bin}"

    local cached_bin="${BIN_CACHE_DIR}/csqtt-${target_tag}-${arch}-${build_mode}"
    local generic_cached_bin="${BIN_CACHE_DIR}/csqtt-${target_tag}-${arch}"

    # Strategy 1: Local Binary Cache
    if [ -f "${cached_bin}" ] && [ -x "${cached_bin}" ] && head -c 4 "${cached_bin}" | grep -q "ELF"; then
        log_ok "Обнаружен готовый бинарник в локальном кэше: ${cached_bin}"
        log_info "Использование кэшированного бинарника без повторной сборки!"
        cp -a "${cached_bin}" "${dest_bin}"
        chmod 755 "${dest_bin}"
        return 0
    elif [ -f "${generic_cached_bin}" ] && [ -x "${generic_cached_bin}" ] && head -c 4 "${generic_cached_bin}" | grep -q "ELF"; then
        log_ok "Обнаружен готовый бинарник в локальном кэше: ${generic_cached_bin}"
        log_info "Использование кэшированного бинарника без повторной сборки!"
        cp -a "${generic_cached_bin}" "${dest_bin}"
        chmod 755 "${dest_bin}"
        return 0
    fi

    # Strategy 2: If official Linux release asset exists, download directly
    if [ -n "${asset_url}" ]; then
        log_info "Обнаружен официальный Linux-бинарник в релизе: ${asset_url}"
        log_info "Загрузка готового серверного файла..."
        local tmp_file="/tmp/csqtt.download.$$"
        rm -f "${tmp_file}"
        if curl -fsSL -o "${tmp_file}" "${asset_url}" 2>/dev/null; then
            local file_type
            file_type=$(file -b "${tmp_file}" 2>/dev/null || echo "")
            if [[ "${file_type}" =~ "gzip" ]] || [[ "${asset_url}" =~ \.tar\.gz$ ]]; then
                local extract_dir="/tmp/csqtt_extract_$$"
                mkdir -p "${extract_dir}"
                tar -xzf "${tmp_file}" -C "${extract_dir}" 2>/dev/null || true
                local extracted_bin
                extracted_bin=$(find "${extract_dir}" -type f -name "csqtt*" | head -n1 || echo "")
                if [ -n "${extracted_bin}" ] && [ -f "${extracted_bin}" ]; then
                    mv "${extracted_bin}" "${tmp_file}"
                fi
                rm -rf "${extract_dir}"
            fi

            chmod +x "${tmp_file}"
            if head -c 4 "${tmp_file}" | grep -q "ELF"; then
                mv "${tmp_file}" "${dest_bin}"
                cp -a "${dest_bin}" "${cached_bin}" 2>/dev/null || true
                log_ok "Официальный Linux-бинарник успешно получен из Releases и сохранён в кэш."
                return 0
            fi
            rm -f "${tmp_file}"
        fi
    fi

    # Strategy 3: Fallback to dynamic upstream build
    log_info "В Releases нет готового Linux-ассета (только Android APK). Переход к сборке [режим: ${build_mode}]..."
    build_upstream_server "${target_tag}" "${dest_bin}" "${build_mode}" || return 1

    # Cache successful build
    if [ -f "${dest_bin}" ] && head -c 4 "${dest_bin}" | grep -q "ELF"; then
        cp -a "${dest_bin}" "${cached_bin}" 2>/dev/null || true
        log_ok "Скомпилированный бинарник сохранён в локальный кэш: ${cached_bin}"
    fi

    return 0
}

# --- Networking & System Config ---
configure_networking() {
    local current_fwd
    current_fwd="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
    if [ "${current_fwd}" != "1" ]; then
        log_info "Включение IP Forwarding (net.ipv4.ip_forward=1)..."
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
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
         ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7}' | tr -d ' \n' || echo "127.0.0.1")
    echo "${ip:-127.0.0.1}"
}

# --- Full Multi-Version Snapshot & Rotation ---
create_system_snapshot() {
    local ver_label="${1:-unknown}"
    local ts
    ts="$(date +'%Y%m%d_%H%M%S')"
    local snapshot_dir="${SYSTEM_BACKUP_DIR}/backup-${ver_label}-${ts}"

    mkdir -p "${snapshot_dir}" "${CONFIG_BACKUP_DIR}"

    [ -f "${BIN_PATH}" ] && cp -a "${BIN_PATH}" "${snapshot_dir}/csqtt"
    [ -f "${CONFIG_FILE}" ] && cp -a "${CONFIG_FILE}" "${snapshot_dir}/csqtt.conf"
    [ -f "${VERSION_FILE}" ] && cp -a "${VERSION_FILE}" "${snapshot_dir}/version.info"

    # Also keep immediate rollback copy
    [ -f "${BIN_PATH}" ] && cp -a "${BIN_PATH}" "${BIN_BACKUP}"
    [ -f "${CONFIG_FILE}" ] && cp -a "${CONFIG_FILE}" "${CONFIG_FILE}.backup"
    [ -f "${VERSION_FILE}" ] && cp -a "${VERSION_FILE}" "${VERSION_FILE}.backup"

    # Rotate old snapshots (keep up to 10)
    local count
    count=$(find "${SYSTEM_BACKUP_DIR}" -maxdepth 1 -type d -name 'backup-*' | wc -l)
    if [ "${count}" -gt 10 ]; then
        find "${SYSTEM_BACKUP_DIR}" -maxdepth 1 -type d -name 'backup-*' -printf '%T+ %p\n' | \
            sort | head -n "$((count - 10))" | awk '{print $2}' | xargs -r rm -rf
    fi

    log_ok "Полный снимок системы сохранён: ${snapshot_dir}"
}

restore_system_snapshot() {
    log_warn "Восстановление предыдущего состояния из резервной копии..."
    if [ -f "${BIN_BACKUP}" ]; then
        cp -a "${BIN_BACKUP}" "${BIN_PATH}"
        chmod 755 "${BIN_PATH}"
    fi
    if [ -f "${CONFIG_FILE}.backup" ]; then
        cp -a "${CONFIG_FILE}.backup" "${CONFIG_FILE}"
    fi
    if [ -f "${VERSION_FILE}.backup" ]; then
        cp -a "${VERSION_FILE}.backup" "${VERSION_FILE}"
    fi
    systemctl restart "${SERVICE_NAME}" 2>/dev/null || true
}

configure_firewall() {
    local port="$1"
    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -q "Status: active"; then
            log_info "Обнаружен активный UFW Firewall"
            log_info "Для CSQTT требуется входящий UDP/TCP порт: ${port}"
            
            local do_ufw="y"
            if [ -t 0 ]; then
                read -r -p "  Добавить правило UFW allow ${port}/udp и ${port}/tcp? [Y/n]: " ans || ans="y"
                ans=$(echo "${ans:-y}" | tr '[:upper:]' '[:lower:]')
                if [[ "${ans}" =~ ^(n|no)$ ]]; then
                    do_ufw="n"
                fi
            fi

            if [ "${do_ufw}" = "y" ]; then
                ufw allow "${port}/udp" comment "CSQTT Server UDP" >/dev/null 2>&1 || true
                ufw allow "${port}/tcp" comment "CSQTT Server TCP" >/dev/null 2>&1 || true
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
EnvironmentFile=-${CONFIG_FILE}
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
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
    log_ok "Сервис systemd настроен: ${SERVICE_FILE}"
}

# --- Deep Service Health Check ---
verify_service_health() {
    local port="${1:-3478}"
    local max_wait=5
    local elapsed=0

    log_info "Выполняется расширенный Health Check службы ${SERVICE_NAME}..."

    while [ "${elapsed}" -lt "${max_wait}" ]; do
        sleep 1
        elapsed=$((elapsed + 1))

        if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
            local pid
            pid=$(systemctl show --property MainPID --value "${SERVICE_NAME}" 2>/dev/null || echo 0)
            if [ -n "${pid}" ] && [ "${pid}" -gt 0 ] && kill -0 "${pid}" 2>/dev/null; then
                # Process is alive and running
                log_ok "Процесс активен (PID: ${pid})"

                # Check if listening on port (UDP/TCP)
                if command -v ss >/dev/null 2>&1; then
                    if ss -lunp 2>/dev/null | grep -q ":${port} " || ss -ltnp 2>/dev/null | grep -q ":${port} "; then
                        log_ok "Порт ${port} успешно слушается процессом"
                    fi
                fi
                return 0
            fi
        fi
    done

    # Check if failed
    if systemctl is-failed --quiet "${SERVICE_NAME}" 2>/dev/null; then
        log_err "Служба перешла в состояние failed."
        return 1
    fi

    # If still active after wait
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        return 0
    fi

    return 1
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

    local arch
    arch="$(detect_arch)"
    local release_info
    release_info="$(fetch_upstream_release_info "${arch}")"
    local upstream_tag="${release_info%%|*}"
    local asset_url="${release_info##*|}"

    log_info "Актуальная версия upstream: ${upstream_tag}"

    # 1. Проверка уже установленного CSQTT
    if [ -f "${BIN_PATH}" ]; then
        local cur_ver="неизвестно"
        [ -f "${VERSION_FILE}" ] && cur_ver="$(grep -E '^CSQTT_VERSION=' "${VERSION_FILE}" 2>/dev/null | cut -d= -f2- || echo 'неизвестно')"
        log_info "CSQTT Server уже установлен на сервере (текущая версия: ${cur_ver})."
        mkdir -p "${BIN_CACHE_DIR}"
        if [ ! -f "${BIN_CACHE_DIR}/csqtt-${cur_ver}-${arch}-installed" ] && head -c 4 "${BIN_PATH}" 2>/dev/null | grep -q "ELF"; then
            cp -a "${BIN_PATH}" "${BIN_CACHE_DIR}/csqtt-${cur_ver}-${arch}-installed" 2>/dev/null || true
        fi
        if [ -n "${upstream_tag}" ] && [ "${cur_ver}" = "${upstream_tag}" ]; then
            log_ok "На сервере уже установлена актуальная версия (${upstream_tag})."
            if [ -t 0 ]; then
                read -r -p "Переустановить / обновить бинарник? [y/N]: " reinstall_ans || reinstall_ans="n"
                reinstall_ans=$(echo "${reinstall_ans:-n}" | tr '[:upper:]' '[:lower:]')
                if [[ ! "${reinstall_ans}" =~ ^(y|yes)$ ]]; then
                    echo "Установка отменена (актуальная версия уже активна)."
                    return 0
                fi
            else
                log_info "Пропуск установки: актуальная версия уже присутствует."
                return 0
            fi
        fi
    fi

    # 2. Выбор режима сборки
    local build_mode="${BUILD_MODE:-}"
    if [ -z "${build_mode}" ]; then
        if [ -t 0 ]; then
            echo ""
            echo -e "${C_BOLD}Выберите режим сборки (если бинарник отсутствует в кэше):${C_RESET}"
            echo "  1) Быстрая release-сборка [по умолчанию] (без LTO=fat, быстрая компиляция, экономит RAM)"
            echo "  2) Полная оптимизированная сборка (официальный build_linux.sh, musl, LTO=fat, codegen-units=1)"
            read -r -p "  Ваш выбор [1/2, default 1]: " bm_choice || bm_choice="1"
            case "${bm_choice}" in
                2) build_mode="full" ;;
                *) build_mode="fast" ;;
            esac
        else
            build_mode="fast"
        fi
    fi

    local tmp_bin="/tmp/csqtt.install.$$"
    obtain_server_binary "${upstream_tag}" "${asset_url}" "${tmp_bin}" "${build_mode}" || {
        log_err "Не удалось получить серверный бинарник. Установка прервана."
        return 1
    }

    mkdir -p "${BIN_DIR}" "${CONFIG_DIR}" "${DATA_DIR}" "${LOG_DIR}" "${SYSTEM_BACKUP_DIR}"
    chmod 755 "${CONFIG_DIR}" "${DATA_DIR}" "${LOG_DIR}"

    if [ -f "${BIN_PATH}" ]; then
        create_system_snapshot "pre-install"
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
        read -r -p "  Укажите порт для CSQTT Server [по умолчанию 3478]: " user_port || user_port="3478"
        port="${user_port:-3478}"
    fi

    configure_firewall "${port}"

    cat <<EOF > "${VERSION_FILE}"
CSQTT_VERSION=${upstream_tag}
RUST_VERSION=$(rustc --version 2>/dev/null || echo "unknown")
ARCH=$(detect_arch)
INSTALLED_AT=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
UPSTREAM=${UPSTREAM_URL}
EOF
    chmod 644 "${VERSION_FILE}"

    if [ ! -f "${CONFIG_FILE}" ]; then
        cat <<EOF > "${CONFIG_FILE}"
# CSQTT Server Configuration
PORT=${port}
LISTEN_PORT=${port}
CSQTT_PORT=${port}
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

    if verify_service_health "${port}"; then
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
        cur_csqtt="$(grep -E '^CSQTT_VERSION=' "${VERSION_FILE}" 2>/dev/null | cut -d= -f2- || echo 'неизвестно')"
        cur_rust="$(grep -E '^RUST_VERSION=' "${VERSION_FILE}" 2>/dev/null | cut -d= -f2- || echo 'неизвестно')"
    fi

    echo "Текущее состояние сервера:"
    echo "  CSQTT : ${cur_csqtt}"
    echo "  Rust  : ${cur_rust}"
    echo ""
    log_info "Проверка актуального состояния в ${UPSTREAM_REPO}..."

    local arch
    arch="$(detect_arch)"
    local release_info
    release_info="$(fetch_upstream_release_info "${arch}")"
    local upstream_tag="${release_info%%|*}"
    local asset_url="${release_info##*|}"

    echo "Доступный upstream: ${upstream_tag}"
    echo ""

    if [ "${cur_csqtt}" != "неизвестно" ] && [ "${cur_csqtt}" = "${upstream_tag}" ]; then
        log_ok "На сервере уже установлена последняя версия upstream (${upstream_tag})."
        if [ -t 0 ]; then
            read -r -p "Пересобрать и принудительно обновить? [y/N]: " force_ans || force_ans="n"
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
        read -r -p "Запустить процедуру обновления до ${upstream_tag}? [Y/n]: " do_update || do_update="y"
        do_update=$(echo "${do_update:-y}" | tr '[:upper:]' '[:lower:]')
        if [[ "${do_update}" =~ ^(n|no)$ ]]; then
            echo "Обновление отменено."
            return 0
        fi
    fi

    echo ""
    log_step "1/7" "Создание полного синхронизированного снимка состояния..."
    create_system_snapshot "${cur_csqtt}"

    local build_mode="${BUILD_MODE:-fast}"
    log_step "2/7" "Получение новой версии [кэш / релизы / сборка: ${build_mode}]..."
    local tmp_bin="/tmp/csqtt.update.$$"
    obtain_server_binary "${upstream_tag}" "${asset_url}" "${tmp_bin}" "${build_mode}" || {
        log_err "Получение новой версии не удалось. Текущее состояние полностью сохранено."
        return 1
    }

    log_step "3/7" "Проверка валидности полученного бинарника..."
    if ! head -c 4 "${tmp_bin}" | grep -q "ELF"; then
        log_err "Полученный файл не является корректным ELF-бинарником."
        rm -f "${tmp_bin}"
        return 1
    fi

    log_step "4/7" "Атомарная замена бинарника на ${BIN_PATH}..."
    mv "${tmp_bin}" "${BIN_PATH}"
    chmod 755 "${BIN_PATH}"

    log_step "5/7" "Обновление метаданных версии..."
    cat <<EOF > "${VERSION_FILE}"
CSQTT_VERSION=${upstream_tag}
RUST_VERSION=$(rustc --version 2>/dev/null || echo "unknown")
ARCH=$(detect_arch)
UPDATED_AT=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
UPSTREAM=${UPSTREAM_URL}
EOF

    log_step "6/7" "Перезапуск службы ${SERVICE_NAME}..."
    systemctl restart "${SERVICE_NAME}"

    local port="3478"
    if [ -f "${CONFIG_FILE}" ]; then
        port="$(grep -E '^PORT=' "${CONFIG_FILE}" 2>/dev/null | cut -d= -f2- || echo '3478')"
    fi

    log_step "7/7" "Глубокий Health Check..."
    if verify_service_health "${port}"; then
        log_ok "CSQTT Server успешно обновлён до версии ${upstream_tag}!"
        return 0
    else
        log_err "Служба не прошла Health Check после обновления!"
        journalctl -u "${SERVICE_NAME}" -n 15 --no-pager
        restore_system_snapshot
        if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
            log_ok "Откат успешен: предыдущее рабочее состояние восстановлено."
        fi
        return 1
    fi
}

# --- Service Management Functions ---
start_service() {
    echo ""
    log_info "Запуск службы ${SERVICE_NAME}..."
    if [ ! -f "${SERVICE_FILE}" ]; then
        log_err "Служба ${SERVICE_NAME}.service не установлена на сервере."
        log_info "Используйте официальный деплой через Android APK (пункт 1) или тестовую сборку (пункт 10)."
        return 1
    fi
    if systemctl start "${SERVICE_NAME}"; then
        sleep 1
        if systemctl is-active --quiet "${SERVICE_NAME}"; then
            log_ok "Служба ${SERVICE_NAME} успешно запущена и активна!"
        else
            log_err "Служба ${SERVICE_NAME} не смогла запуститься."
            journalctl -u "${SERVICE_NAME}" -n 10 --no-pager
        fi
    else
        log_err "Не удалось отправить команду запуска в systemd."
    fi
}

check_status() {
    run_diagnostics
    if [ -f "${SERVICE_FILE}" ]; then
        echo -e "${C_BOLD}systemctl status ${SERVICE_NAME}:${C_RESET}"
        systemctl status "${SERVICE_NAME}" --no-pager || true
    fi
}

restart_service() {
    echo ""
    log_info "Перезапуск службы ${SERVICE_NAME}..."
    if [ ! -f "${SERVICE_FILE}" ]; then
        log_err "Служба ${SERVICE_NAME}.service не установлена на сервере."
        return 1
    fi
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
    echo -e "${C_BOLD}╔══════════════════════════════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BOLD}║              ОФИЦИАЛЬНАЯ УСТАНОВКА И ANDROID КЛИЕНТ CSQTT                    ║${C_RESET}"
    echo -e "╠══════════════════════════════════════════════════════════════════════════════╣"
    echo -e "║ ${C_YELLOW}ВАЖНО:${C_RESET} Установка CSQTT Server на VPS выполняется через официальный        ║"
    echo -e "║ способ распространения CSQTT. Этот скрипт не навязывает тяжёлую             ║"
    echo -e "║ компиляцию сервера из исходников на VPS.                                     ║"
    echo -e "║                                                                              ║"
    echo -e "║ ${C_CYAN}Официальный способ развертывания через Android APK:${C_RESET}                        ║"
    echo -e "║  1. Скачайте официальный APK клиента на телефон:                             ║"
    echo -e "║     ${C_BLUE}https://github.com/${UPSTREAM_REPO}/releases${C_RESET}                       ║"
    echo -e "║  2. В приложении перейдите на вкладку «Серверы» -> «Добавить VPS».           ║"
    echo -e "║  3. Укажите IP вашего VPS, порт SSH (22) и логин root с паролем или ключом. ║"
    echo -e "║  4. APK подключается по SSH и разворачивает готовый Linux-бинарник           ║"
    echo -e "║     (pre-built) без тяжелой нагрузки на 1 GB RAM вашего VPS.                 ║"
    echo -e "║  5. Скрипт csqtt-install.sh на VPS служит менеджером для управления:         ║"
    echo -e "║     статус, запуск/остановка, логи, автозапуск, обновление.                  ║"
    echo -e "║                                                                              ║"
    echo -e "║ Официальный репозиторий:                                                     ║"
    echo -e "║   ${C_CYAN}https://github.com/${UPSTREAM_REPO}${C_RESET}                                      ║"
    echo -e "║ Кроссплатформенные клиенты:                                                  ║"
    echo -e "║   • Windows & Linux: ${C_CYAN}https://github.com/luminescq/focsq${C_RESET}                  ║"
    echo -e "║   • iOS:             ${C_CYAN}https://github.com/anton48/vk-turn-proxy-ios${C_RESET}            ║"
    echo -e "╚══════════════════════════════════════════════════════════════════════════════╝"
    echo ""
}

compile_csqtt() {
    echo ""
    echo -e "${C_BOLD}${C_YELLOW}=== [10] КОМПИЛЯЦИЯ ИЗ ИСХОДНИКОВ (ТЕСТОВАЯ, НЕТ ГАРАНТИИ) ===${C_RESET}"
    echo ""
    echo -e "  ${C_RED}ВНИМАНИЕ!${C_RESET} Сборка Rust на VPS с 1 GB RAM крайне ресурсоёмка"
    echo -e "  и занимает десятки минут. При нехватке памяти возможен сбой OOM Killer."
    echo -e "  ${C_GREEN}Рекомендуемый способ:${C_RESET} деплой через официальный Android APK (пункт 1)."
    echo ""

    local confirm="n"
    if [ -t 0 ]; then
        read -r -p "Запустить экспериментальную компиляцию? [y/N]: " confirm || confirm="n"
        confirm=$(echo "${confirm:-n}" | tr '[:upper:]' '[:lower:]')
    else
        confirm="y"
    fi

    if [[ "${confirm}" =~ ^(y|yes)$ ]]; then
        install_csqtt
    else
        echo "Компиляция отменена."
    fi
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
        ver="$(grep -E '^CSQTT_VERSION=' "${VERSION_FILE}" 2>/dev/null | cut -d= -f2- || echo 'Installed')"
    elif [ -f "${BIN_PATH}" ]; then
        ver="Installed"
    fi
    printf "  %-14s: %s\n" "CSQTT Version" "${ver}"

    local rust_ver="N/A"
    if command -v rustc >/dev/null 2>&1; then
        rust_ver="$(rustc --version 2>/dev/null || echo 'N/A')"
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
        read -r -p "  Сохранить конфигурацию и данные? [Y/n]: " ans || ans="y"
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

show_menu() {
    clear 2>/dev/null || true
    echo -e "${C_CYAN}╔══════════════════════════════════════════════════════════════╗
║               CSQTT SERVER MANAGER (v3.3.0)                  ║
║          Автономное управление Linux-сервером CSQTT          ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  1. 📱 Официальная установка / Android APK                    ║
║  2. 📊 Статус CSQTT Server                                   ║
║  3. ▶️  Запустить службу                                      ║
║  4. ⏹  Остановить службу                                     ║
║  5. 🔄 Перезапустить службу                                  ║
║  6. ⬆️  Обновить Server                                      ║
║  7. ⚙️  Конфигурация и версия                                 ║
║  8. 📋 Логи службы (journalctl)                              ║
║  9. 🗑️  Удалить CSQTT с сервера                               ║
║ 10. 🧪 Компиляция из исходников (тестовая, нет гарантии)     ║
║                                                              ║
║  0. Выход                                                    ║
╚══════════════════════════════════════════════════════════════╝${C_RESET}"

    local choice
    read -r -p "Выберите вариант [0-10]: " choice || choice="0"
    case "${choice}" in
        1)
            show_android_info
            ;;
        2)
            check_status
            ;;
        3)
            start_service
            ;;
        4)
            stop_service
            ;;
        5)
            restart_service
            ;;
        6)
            update_csqtt
            ;;
        7)
            show_config
            ;;
        8)
            show_logs
            ;;
        9)
            uninstall_csqtt
            ;;
        10)
            compile_csqtt
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
    read -r -p "Нажмите Enter для продолжения..." _ || true
}

main() {
    local cmd="${1:-}"

    case "${cmd}" in
        1|android|apk|client|install-info)
            show_android_info
            ;;
        2|status|diag|diagnostics)
            check_status
            ;;
        3|start)
            start_service
            ;;
        4|stop)
            stop_service
            ;;
        5|restart)
            restart_service
            ;;
        6|update)
            local mode_arg="${2:-}"
            [[ "${mode_arg}" =~ ^(--fast|fast)$ ]] && export BUILD_MODE="fast"
            [[ "${mode_arg}" =~ ^(--full|full)$ ]] && export BUILD_MODE="full"
            update_csqtt
            ;;
        7|config)
            show_config
            ;;
        8|logs)
            show_logs
            ;;
        9|uninstall|remove)
            uninstall_csqtt
            ;;
        10|compile|build)
            local mode_arg="${2:-}"
            [[ "${mode_arg}" =~ ^(--fast|fast)$ ]] && export BUILD_MODE="fast"
            [[ "${mode_arg}" =~ ^(--full|full)$ ]] && export BUILD_MODE="full"
            compile_csqtt
            ;;
        install)
            local mode_arg="${2:-}"
            if [ -n "${mode_arg}" ]; then
                [[ "${mode_arg}" =~ ^(--fast|fast)$ ]] && export BUILD_MODE="fast"
                [[ "${mode_arg}" =~ ^(--full|full)$ ]] && export BUILD_MODE="full"
                compile_csqtt
            else
                show_android_info
                echo ""
                read -r -p "Хотите запустить экспериментальную компиляцию из исходников на этом сервере? [y/N]: " do_c || do_c="n"
                do_c=$(echo "${do_c:-n}" | tr '[:upper:]' '[:lower:]')
                if [[ "${do_c}" =~ ^(y|yes)$ ]]; then
                    compile_csqtt
                fi
            fi
            ;;
        help|--help|-h)
            echo "Использование: bash $0 [команда]"
            echo ""
            echo "Команды менеджера CSQTT Server:"
            echo "  android      - Инструкция по официальной установке через Android APK"
            echo "  status       - Проверить статус службы и сводную диагностику"
            echo "  start        - Запустить службу"
            echo "  stop         - Остановить службу"
            echo "  restart      - Перезапустить службу"
            echo "  update       - Обновить CSQTT Server (кэш / релизы)"
            echo "  config       - Показать файл конфигурации и метаданные версии"
            echo "  logs         - Показать логи службы в реальном времени (journalctl)"
            echo "  uninstall    - Удалить CSQTT с сервера"
            echo "  compile      - Экспериментальная компиляция из исходников (тестовая)"
            echo ""
            echo "Запуск без параметров открывает интерактивное меню [0-10]."
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
