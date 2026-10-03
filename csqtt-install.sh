#!/usr/bin/env bash
# ==============================================================================
# CSQTT Server Installer & Manager
# Autonomous management script for CSQTT Server on Debian / Ubuntu
# Architecture: AMD64, ARM64, ARMV7
# ==============================================================================

set -u

# --- Configuration & Paths ---
readonly SCRIPT_VERSION="1.0.1"
readonly GITHUB_REPO="amurcanov/csqtt"
readonly ANDROID_REPO="SpaceNeuroX/proxy-turn-vk-android"

readonly BIN_DIR="/usr/local/bin"
readonly BIN_PATH="${BIN_DIR}/csqtt"
readonly BIN_BACKUP="${BIN_DIR}/csqtt.backup"

readonly CONFIG_DIR="/etc/csqtt"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly CONFIG_BACKUP_DIR="${CONFIG_DIR}/backup"

readonly DATA_DIR="/var/lib/csqtt"
readonly LOG_DIR="/var/log/csqtt"
readonly SYSTEM_BACKUP_DIR="/var/backups/csqtt"

readonly SERVICE_NAME="csqtt"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# --- Styling & Colors ---
if [ -t 1 ]; then
    readonly C_RESET='\033[0m'
    readonly C_RED='\033[0;31m'
    readonly C_GREEN='\033[0;32m'
    readonly C_YELLOW='\033[1;33m'
    readonly C_BLUE='\033[0;34m'
    readonly C_CYAN='\033[0;36m'
    readonly C_BOLD='\033[1m'
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

    # 2. OS check (Debian / Ubuntu)
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
        [ "${quiet}" -eq 0 ] && log_err "Не удалось определить операционную систему (/etc/os-release отсутствует)."
        failed=1
    fi

    # 3. Architecture check
    local arch
    arch="$(detect_arch)"
    if [ "${arch}" = "unsupported" ]; then
        [ "${quiet}" -eq 0 ] && log_err "Архитектура $(uname -m) не поддерживается CSQTT."
        return 1
    fi
    [ "${quiet}" -eq 0 ] && log_ok "Architecture: ${arch} ($(uname -m))"

    # 4. systemd check
    if pidof systemd >/dev/null 2>&1 || [ -d /run/systemd/system ]; then
        [ "${quiet}" -eq 0 ] && log_ok "systemd"
    else
        [ "${quiet}" -eq 0 ] && log_err "systemd не обнаружен. CSQTT требует systemd для управления службой."
        return 1
    fi

    # 5. Disk space check (need at least 200MB)
    local free_mb
    free_mb=$(df -m /usr/local | awk 'NR==2 {print $4}')
    if [ -n "${free_mb}" ] && [ "${free_mb}" -lt 200 ]; then
        [ "${quiet}" -eq 0 ] && log_err "Недостаточно свободного места на диске (${free_mb} MB). Требуется минимум 200 MB."
        return 1
    else
        local free_gb
        free_gb=$(df -h /usr/local | awk 'NR==2 {print $4}')
        [ "${quiet}" -eq 0 ] && log_ok "Свободно на диске: ${free_gb}"
    fi

    # 6. Existing CSQTT status
    if [ -f "${BIN_PATH}" ]; then
        local cur_ver="неизвестно"
        if "${BIN_PATH}" --version >/dev/null 2>&1; then
            cur_ver="$("${BIN_PATH}" --version 2>&1 | head -n1)"
        fi
        [ "${quiet}" -eq 0 ] && log_info "CSQTT уже установлен (${cur_ver})"
        
        if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
            [ "${quiet}" -eq 0 ] && log_info "Сервис: active (running)"
        else
            [ "${quiet}" -eq 0 ] && log_info "Сервис: не активен или остановлен"
        fi
    else
        [ "${quiet}" -eq 0 ] && echo -e "  [${C_BLUE}INFO${C_RESET}] CSQTT: не установлен"
    fi

    return "${failed}"
}

# --- Dependencies Installation ---
ensure_dependencies() {
    local missing_pkgs=()
    for pkg in curl jq iptables iproute2 git; do
        if ! command -v "${pkg}" >/dev/null 2>&1; then
            missing_pkgs+=("${pkg}")
        fi
    done

    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        log_info "Установка недостающих зависимостей: ${missing_pkgs[*]}..."
        apt-get update -qq >/dev/null 2>&1 || true
        # shellcheck disable=SC2068
        apt-get install -y -qq ${missing_pkgs[@]} >/dev/null 2>&1 || {
            log_err "Не удалось установить зависимости: ${missing_pkgs[*]}"
            return 1
        }
        log_ok "Зависимости успешно установлены"
    fi
    return 0
}

# --- Public IP Discovery ---
get_public_ip() {
    local ip
    ip=$(curl -fs4m 3 https://api.ipify.org 2>/dev/null || \
         curl -fs4m 3 https://icanhazip.com 2>/dev/null || \
         ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7}' | tr -d ' \n')
    echo "${ip:-127.0.0.1}"
}

# --- Config Management & Rotation ---
rotate_config_backups() {
    mkdir -p "${CONFIG_BACKUP_DIR}"
    if [ -f "${CONFIG_FILE}" ]; then
        local ts
        ts="$(date +'%Y%m%d_%H%M%S')"
        cp -a "${CONFIG_FILE}" "${CONFIG_BACKUP_DIR}/config_${ts}.json"
        log_ok "Резервная копия конфигурации сохранена: ${CONFIG_BACKUP_DIR}/config_${ts}.json"
        
        # Keep only the latest 10 backups
        local count
        count=$(find "${CONFIG_BACKUP_DIR}" -maxdepth 1 -name 'config_*.json' | wc -l)
        if [ "${count}" -gt 10 ]; then
            find "${CONFIG_BACKUP_DIR}" -maxdepth 1 -name 'config_*.json' -type f -printf '%T+ %p\n' | \
                sort | head -n "$((count - 10))" | awk '{print $2}' | xargs -r rm -f
        fi
    fi
}

# --- Read Config Fields ---
read_config_value() {
    local key="$1"
    local default_val="$2"
    if [ -f "${CONFIG_FILE}" ] && command -v jq >/dev/null 2>&1; then
        local val
        val=$(jq -r ".${key} // empty" "${CONFIG_FILE}" 2>/dev/null)
        if [ -n "${val}" ] && [ "${val}" != "null" ]; then
            echo "${val}"
            return
        fi
    fi
    echo "${default_val}"
}

# --- Firewall Check & Configuration ---
configure_firewall() {
    local port="$1"
    if command -v ufw >/dev/null 2>&1; then
        if ufw status | grep -q "Status: active"; then
            log_info "Обнаружен активный UFW Firewall"
            log_info "Для CSQTT требуется входящий UDP порт: ${port}"
            
            local do_ufw="y"
            if [ -t 0 ]; then
                read -r -p "  Добавить правило UFW allow ${port}/udp? [Y/n]: " ans
                ans=$(echo "${ans:-y}" | tr '[:upper:]' '[:lower:]')
                if [[ "${ans}" =~ ^(n|no)$ ]]; then
                    do_ufw="n"
                fi
            fi

            if [ "${do_ufw}" = "y" ]; then
                ufw allow "${port}/udp" comment "CSQTT Server" >/dev/null 2>&1
                log_ok "Правило добавлено: UFW allow ${port}/udp"
            else
                log_warn "Правило UFW пропущено по запросу пользователя. Не забудьте открыть порт ${port}/udp вручную."
            fi
        fi
    fi
}

# --- IP Forwarding & NAT Check ---
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

# --- GitHub Release Asset Resolution ---
get_latest_version_and_url() {
    local arch="$1"
    local api_url="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
    local release_json
    release_json=$(curl -fsSLm 10 "${api_url}" 2>/dev/null)

    local tag=""
    local download_url=""

    if [ -n "${release_json}" ] && command -v jq >/dev/null 2>&1; then
        tag=$(echo "${release_json}" | jq -r '.tag_name // empty')
        # Search asset matching arch and linux
        download_url=$(echo "${release_json}" | jq -r \
            --arg a "${arch}" \
            '.assets[] | select(.name | test("csqtt.*" + $a + ".*(linux|musl|gnu)?"; "i")) | .browser_download_url' | head -n1)
    fi

    if [ -z "${tag}" ]; then
        tag="latest"
    fi

    echo "${tag}|${download_url}"
}

# --- Source Compilation via Rust/Cargo Fallback ---
build_from_source() {
    echo ""
    log_info "В официальных релизах ${GITHUB_REPO} нет готовых Linux-бинарников (релизы содержат только Android APK)."
    log_info "Запуск автоматической сборки rust-server из официального репозитория через Cargo..."
    echo ""

    # Ensure build tools
    local build_deps=()
    for p in build-essential pkg-config libssl-dev; do
        if ! dpkg -s "$p" >/dev/null 2>&1; then
            build_deps+=("$p")
        fi
    done

    if [ ${#build_deps[@]} -gt 0 ]; then
        log_info "Установка сборочных пакетов: ${build_deps[*]}..."
        apt-get update -qq >/dev/null 2>&1 || true
        # shellcheck disable=SC2068
        apt-get install -y -qq ${build_deps[@]} >/dev/null 2>&1 || {
            log_err "Не удалось установить сборочные пакеты."
            return 1
        }
    fi

    # Ensure Rust / Cargo
    if ! command -v cargo >/dev/null 2>&1 || ! command -v rustc >/dev/null 2>&1; then
        log_info "Установка компилятора Rust (cargo / rustc)..."
        if apt-get install -y -qq cargo rustc >/dev/null 2>&1; then
            log_ok "Компилятор Rust успешно установлен через apt"
        else
            log_info "Установка через официальный скрипт rustup..."
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y >/dev/null 2>&1
            # shellcheck disable=SC1091
            [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
        fi
    fi

    if ! command -v cargo >/dev/null 2>&1; then
        # Try loading cargo env if rustup was used
        if [ -f "$HOME/.cargo/env" ]; then
            # shellcheck disable=SC1091
            . "$HOME/.cargo/env"
        fi
    fi

    if ! command -v cargo >/dev/null 2>&1; then
        log_err "Не удалось обнаружить Cargo в системе. Сборка невозможна."
        return 1
    fi

    # Clone source code
    local src_dir="/tmp/csqtt_src_$$"
    rm -rf "${src_dir}"
    log_info "Клонирование репозитория https://github.com/${GITHUB_REPO}.git..."
    if ! git clone --depth 1 "https://github.com/${GITHUB_REPO}.git" "${src_dir}" >/dev/null 2>&1; then
        log_err "Ошибка при клонировании репозитория."
        rm -rf "${src_dir}"
        return 1
    fi

    local server_dir="${src_dir}/rust-server"
    if [ ! -d "${server_dir}" ]; then
        if [ -f "${src_dir}/Cargo.toml" ]; then
            server_dir="${src_dir}"
        else
            log_err "Каталог rust-server не найден в репозитории."
            rm -rf "${src_dir}"
            return 1
        fi
    fi

    log_info "Компиляция rust-server в режиме release (это займет 1-3 минуты)..."
    (
        cd "${server_dir}" || exit 1
        cargo build --release
    ) >/tmp/csqtt-build-$$.log 2>&1 || {
        log_err "Ошибка компиляции Cargo. Подробности в логе /tmp/csqtt-build-$$.log"
        tail -n 25 "/tmp/csqtt-build-$$.log"
        rm -rf "${src_dir}"
        return 1
    }

    # Locate compiled executable
    local compiled_bin
    compiled_bin=$(find "${server_dir}/target/release" -maxdepth 1 -type f -executable ! -name "*.so" ! -name "*.d" | head -n1)

    if [ -n "${compiled_bin}" ] && [ -f "${compiled_bin}" ]; then
        local out_bin="/tmp/csqtt.built.$$"
        cp -a "${compiled_bin}" "${out_bin}"
        rm -rf "${src_dir}" "/tmp/csqtt-build-$$.log"
        log_ok "Сборка успешно завершена: $(basename "${compiled_bin}")"
        echo "${out_bin}"
        return 0
    else
        log_err "Не удалось найти скомпилированный файл в target/release/"
        rm -rf "${src_dir}"
        return 1
    fi
}

# --- Obtain Binary (Download or Build) ---
obtain_csqtt_binary() {
    local target_url="$1"
    local tmp_file="/tmp/csqtt.download.$$"

    # 1. Try download if URL was found in releases
    if [ -n "${target_url}" ]; then
        rm -f "${tmp_file}"
        log_info "Проверка и загрузка бинарника по URL: ${target_url}..."
        if curl -fsSL -o "${tmp_file}" "${target_url}" 2>/dev/null; then
            local file_type
            file_type=$(file -b "${tmp_file}" 2>/dev/null || echo "")
            if [[ "${file_type}" =~ "gzip" ]] || [[ "${target_url}" =~ \.tar\.gz$ ]]; then
                local extract_dir="/tmp/csqtt_extract_$$"
                mkdir -p "${extract_dir}"
                tar -xzf "${tmp_file}" -C "${extract_dir}" 2>/dev/null
                local extracted_bin
                extracted_bin=$(find "${extract_dir}" -type f -name "csqtt*" | head -n1)
                if [ -n "${extracted_bin}" ] && [ -f "${extracted_bin}" ]; then
                    mv "${extracted_bin}" "${tmp_file}"
                    rm -rf "${extract_dir}"
                fi
            fi

            chmod +x "${tmp_file}"
            if head -c 4 "${tmp_file}" | grep -q "ELF"; then
                echo "${tmp_file}"
                return 0
            fi
            rm -f "${tmp_file}"
        fi
    fi

    # 2. If release download was empty or returned 404, build from source
    local built_bin
    built_bin="$(build_from_source)" || return 1
    echo "${built_bin}"
    return 0
}

# --- Systemd Service Creation ---
create_or_update_systemd_service() {
    cat <<EOF > "${SERVICE_FILE}"
[Unit]
Description=CSQTT Server
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${CONFIG_DIR}
ExecStart=${BIN_PATH} run --config ${CONFIG_FILE}
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

# --- Installation Logic ---
install_csqtt() {
    echo ""
    echo -e "${C_BOLD}=== УСТАНОВКА CSQTT SERVER ===${C_RESET}"
    echo ""

    run_preflight_checks 0 || return 1
    ensure_dependencies || return 1
    configure_networking

    local arch
    arch="$(detect_arch)"

    local release_info
    release_info="$(get_latest_version_and_url "${arch}")"
    local tag="${release_info%%|*}"
    local url="${release_info##*|}"

    log_info "Целевая версия: ${tag}"

    local final_bin
    final_bin="$(obtain_csqtt_binary "${url}")" || {
        log_err "Не удалось получить рабочий бинарный файл CSQTT."
        return 1
    }

    mkdir -p "${BIN_DIR}" "${CONFIG_DIR}" "${DATA_DIR}" "${LOG_DIR}" "${SYSTEM_BACKUP_DIR}"
    chmod 755 "${CONFIG_DIR}" "${DATA_DIR}" "${LOG_DIR}"

    local port="3478"
    local secret=""

    if [ -f "${CONFIG_FILE}" ]; then
        log_info "Найдена существующая конфигурация: ${CONFIG_FILE}"
        rotate_config_backups
        port="$(read_config_value "port" "3478")"
        secret="$(read_config_value "secret" "")"
    else
        echo ""
        if [ -t 0 ]; then
            read -r -p "  Укажите порт для CSQTT Server [по умолчанию 3478]: " user_port
            port="${user_port:-3478}"
        else
            port="3478"
        fi

        secret="$(head -c 16 /dev/urandom | xxd -p 2>/dev/null || tr -dc 'a-f0-9' < /dev/urandom | head -c 32)"

        cat <<EOF > "${CONFIG_FILE}"
{
  "server_name": "CSQTT-Node",
  "port": ${port},
  "secret": "${secret}",
  "tun_name": "csqtt0",
  "tun_ipv4": "10.8.0.1/24",
  "data_dir": "${DATA_DIR}",
  "log_dir": "${LOG_DIR}",
  "created_at": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
}
EOF
        chmod 600 "${CONFIG_FILE}"
        log_ok "Создана новая конфигурация: ${CONFIG_FILE}"
    fi

    if [ -f "${BIN_PATH}" ]; then
        cp -a "${BIN_PATH}" "${BIN_BACKUP}"
        log_ok "Резервная копия старого бинарника сохранена в ${BIN_BACKUP}"
    fi

    mv "${final_bin}" "${BIN_PATH}"
    chmod 755 "${BIN_PATH}"
    log_ok "Бинарный файл установлен в ${BIN_PATH}"

    configure_firewall "${port}"
    create_or_update_systemd_service

    log_info "Запуск сервиса ${SERVICE_NAME}..."
    systemctl restart "${SERVICE_NAME}"
    sleep 2

    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        log_ok "Сервис ${SERVICE_NAME} успешно запущен и работает!"
        show_connection_card
        return 0
    else
        log_err "Сервис ${SERVICE_NAME} не запустился после установки!"
        journalctl -u "${SERVICE_NAME}" -n 15 --no-pager
        
        if [ -f "${BIN_BACKUP}" ]; then
            log_warn "Выполняется откат на предыдущий бинарник..."
            mv "${BIN_BACKUP}" "${BIN_PATH}"
            systemctl restart "${SERVICE_NAME}" 2>/dev/null || true
            if systemctl is-active --quiet "${SERVICE_NAME}"; then
                log_ok "Откат успешен: предыдущая версия активна."
            fi
        fi
        return 1
    fi
}

# --- Update Logic with Rollback ---
update_csqtt() {
    echo ""
    echo -e "${C_BOLD}=== ОБНОВЛЕНИЕ CSQTT SERVER ===${C_RESET}"
    echo ""

    if [ ! -f "${BIN_PATH}" ]; then
        log_err "CSQTT не установлен на сервере. Используйте пункт установки."
        return 1
    fi

    local arch
    arch="$(detect_arch)"
    local cur_ver="неизвестно"
    if "${BIN_PATH}" --version >/dev/null 2>&1; then
        cur_ver="$("${BIN_PATH}" --version 2>&1 | head -n1)"
    fi
    log_info "Текущая установленная версия: ${cur_ver}"

    log_info "Проверка наличия обновлений на GitHub..."
    local release_info
    release_info="$(get_latest_version_and_url "${arch}")"
    local tag="${release_info%%|*}"
    local url="${release_info##*|}"

    log_info "Последняя доступная версия: ${tag}"

    rotate_config_backups

    local final_bin
    final_bin="$(obtain_csqtt_binary "${url}")" || return 1

    cp -a "${BIN_PATH}" "${BIN_BACKUP}"
    log_ok "Резервная копия текущего бинарника сохранена в ${BIN_BACKUP}"

    mv "${final_bin}" "${BIN_PATH}"
    chmod 755 "${BIN_PATH}"
    log_ok "Бинарный файл обновлен: ${BIN_PATH}"

    log_info "Перезапуск службы ${SERVICE_NAME}..."
    systemctl restart "${SERVICE_NAME}"
    sleep 2

    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        log_ok "CSQTT успешно обновлен и активен!"
        return 0
    else
        log_err "CSQTT не запустился после обновления!"
        journalctl -u "${SERVICE_NAME}" -n 15 --no-pager
        log_warn "Выполняется автоматический откат на предыдущую версию..."
        
        if [ -f "${BIN_BACKUP}" ]; then
            cp -a "${BIN_BACKUP}" "${BIN_PATH}"
            systemctl restart "${SERVICE_NAME}"
            sleep 2
            if systemctl is-active --quiet "${SERVICE_NAME}"; then
                log_ok "Откат успешно завершен: восстановлена предыдущая рабочая версия."
            else
                log_err "Критическая ошибка: сервис не поднялся даже после отката."
            fi
        else
            log_err "Файл отката ${BIN_BACKUP} отсутствует."
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
            log_ok "Служба ${SERVICE_NAME} успешно перезапущена и работает."
        else
            log_err "Служба ${SERVICE_NAME} не смогла запуститься после перезапуска."
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

# --- Show Configuration ---
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
    else
        log_warn "Конфигурационный файл ${CONFIG_FILE} не найден."
    fi
}

# --- Show Android Client Info ---
show_android_info() {
    echo ""
    echo -e "╔══════════════════════════════════════════════════════════════╗"
    echo -e "║                      ${C_BOLD}ANDROID CLIENT${C_RESET}                          ║"
    echo -e "╠══════════════════════════════════════════════════════════════╣"
    echo -e "║  Для подключения к серверу с Android используются клиенты:   ║"
    echo -e "║                                                              ║"
    echo -e "║  1) ${C_BOLD}qWDTT Client${C_RESET} (SpaceNeuroX)                                ║"
    echo -e "║     ${C_CYAN}https://github.com/SpaceNeuroX/proxy-turn-vk-android${C_RESET}     ║"
    echo -e "║                                                              ║"
    echo -e "║  2) ${C_BOLD}CSQTT Official APK${C_RESET} (amurcanov)                           ║"
    echo -e "║     ${C_CYAN}https://github.com/amurcanov/csqtt${C_RESET}                       ║"
    echo -e "║                                                              ║"
    echo -e "║  Скачайте свежий APK из раздела Releases любого репозитория  ║"
    echo -e "║  и импортируйте параметры подключения вашего сервера.        ║"
    echo -e "╚══════════════════════════════════════════════════════════════╝"
    echo ""
}

# --- Show Connection Summary Card ---
show_connection_card() {
    local ip
    ip="$(get_public_ip)"
    local port
    port="$(read_config_value "port" "3478")"
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
    echo "            CSQTT SERVER УСТАНОВЛЕН                "
    echo "===================================================="
    echo ""
    echo -e "  Статус:       ${C_GREEN}${status}${C_RESET}"
    echo -e "  Автозапуск:   ${C_GREEN}${autostart}${C_RESET}"
    echo ""
    echo "  SERVER:"
    echo -e "    IP:         ${C_CYAN}${ip}${C_RESET}"
    echo -e "    Port:       ${C_CYAN}${port}${C_RESET} (UDP/TCP)"
    echo -e "    Config:     ${CONFIG_FILE}"
    echo ""
    echo "  ANDROID:"
    echo "    Клиент:     qWDTT / CSQTT"
    echo -e "    APK:        ${C_CYAN}https://github.com/${ANDROID_REPO}${C_RESET}"
    echo ""
    echo "===================================================="
    echo ""
}

# --- Diagnostics View ---
run_diagnostics() {
    echo ""
    echo -e "${C_BOLD}CSQTT DIAGNOSTICS${C_RESET}"
    echo "────────────────────────────────────────────────────"

    local ver="Not installed"
    if [ -f "${BIN_PATH}" ]; then
        if "${BIN_PATH}" --version >/dev/null 2>&1; then
            ver="$("${BIN_PATH}" --version 2>&1 | head -n1)"
        else
            ver="Installed (binary present)"
        fi
    fi
    printf "  %-14s: %s\n" "Version" "${ver}"

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

    local port
    port="$(read_config_value "port" "N/A")"
    printf "  %-14s: %s\n" "Port" "${port}"

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

# --- Uninstallation Logic ---
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
    cat <<EOF
${C_CYAN}╔════════════════════════════════════════════╗
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
╚════════════════════════════════════════════╝${C_RESET}
EOF

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

# --- Main Entry Point (CLI & Menu) ---
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
            echo "  install      - Установить CSQTT Server"
            echo "  update       - Обновить CSQTT Server с автооткатом"
            echo "  status       - Проверить статус службы"
            echo "  restart      - Перезапустить службу"
            echo "  stop         - Остановить службу"
            echo "  logs         - Показать логи (journalctl)"
            echo "  config       - Показать файл конфигурации"
            echo "  android      - Показать информацию и ссылки для клиентов Android"
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
