#!/usr/bin/env bash
# ==============================================================================
# Менеджер безопасности и обслуживания VPS
# https://github.com/iurievi4/vps-setup
# ==============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "/tmp")"
MODULES_DIR="${SCRIPT_DIR}/modules"

# Базовый URL вашего репозитория для автозагрузки модулей
REPO_RAW_URL="https://raw.githubusercontent.com/iurievi4/vps-setup/main"

C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"
C_BLUE="\033[1;34m"
C_CYAN="\033[1;36m"
C_RESET="\033[0m"

log_info()  { echo -e "${C_BLUE}[INFO]${C_RESET} $*"; }
log_ok()    { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
log_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
log_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*"; }
log_title() { echo -e "${C_CYAN}=== $* ===${C_RESET}"; }

# Проверка прав суперпользователя
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        log_error "Этот скрипт должен быть запущен с правами root (sudo)."
        exit 1
    fi
}

pause() {
    echo ""
    read -rp "Нажмите [Enter] для возврата..." _
}

# ------------------------------------------------------------------------------
# Подготовка и скачивание модуля IP Guard и конфигурации
# ------------------------------------------------------------------------------
ensure_ip_guard_installed() {
    local target_bin="/usr/local/sbin/ip-guard"
    local conf_dir="/etc/vps-ip-guard"
    local conf_file="${conf_dir}/ip-guard.conf"

    mkdir -p "$conf_dir" /usr/local/sbin

    # 1. Поиск / Загрузка скрипта модуля ip-guard.sh
    if [[ -f "${MODULES_DIR}/ip-guard.sh" ]]; then
        cp -f "${MODULES_DIR}/ip-guard.sh" "$target_bin"
    elif [[ -f "${SCRIPT_DIR}/ip-guard.sh" ]]; then
        cp -f "${SCRIPT_DIR}/ip-guard.sh" "$target_bin"
    else
        log_info "Локальный модуль не найден. Загрузка из GitHub (${REPO_RAW_URL}/modules/ip-guard.sh)..."
        local downloaded=false

        if curl -fsSL --connect-timeout 10 "${REPO_RAW_URL}/modules/ip-guard.sh" -o "$target_bin" 2>/dev/null && grep -q 'VPS IP Guard' "$target_bin"; then
            downloaded=true
            log_ok "Модуль загружен из ${REPO_RAW_URL}/modules/ip-guard.sh"
        elif curl -fsSL --connect-timeout 10 "${REPO_RAW_URL}/ip-guard.sh" -o "$target_bin" 2>/dev/null && grep -q 'VPS IP Guard' "$target_bin"; then
            downloaded=true
            log_ok "Модуль загружен из ${REPO_RAW_URL}/ip-guard.sh"
        fi

        if [[ "$downloaded" != "true" ]]; then
            log_error "Не удалось скачать ip-guard.sh из GitHub!"
            log_error "Убедитесь, что файл лежит в репозитории: ${REPO_RAW_URL}/modules/ip-guard.sh"
            return 1
        fi
    fi

    chmod +x "$target_bin"

    # 2. Поиск / Загрузка конфигурации ip-guard.conf
    if [[ -f "${MODULES_DIR}/ip-guard.conf" ]]; then
        cp -f "${MODULES_DIR}/ip-guard.conf" "$conf_file"
    elif [[ -f "${SCRIPT_DIR}/ip-guard.conf" ]]; then
        cp -f "${SCRIPT_DIR}/ip-guard.conf" "$conf_file"
    elif [[ ! -f "$conf_file" ]]; then
        log_info "Загрузка конфигурации из GitHub..."
        if curl -fsSL --connect-timeout 10 "${REPO_RAW_URL}/modules/ip-guard.conf" -o "$conf_file" 2>/dev/null && grep -q 'SET_V4' "$conf_file"; then
            log_ok "Конфигурация загружена из ${REPO_RAW_URL}/modules/ip-guard.conf"
        elif curl -fsSL --connect-timeout 10 "${REPO_RAW_URL}/ip-guard.conf" -o "$conf_file" 2>/dev/null && grep -q 'SET_V4' "$conf_file"; then
            log_ok "Конфигурация загружена из ${REPO_RAW_URL}/ip-guard.conf"
        else
            log_info "Создание стандартного ${conf_file}..."
            cat << 'EOF' > "$conf_file"
# /etc/vps-ip-guard/ip-guard.conf
ENABLE_IPV4=true
ENABLE_IPV6="auto"
SET_V4="VPS-IP-GUARD-V4"
SET_V6="VPS-IP-GUARD-V6"
CHAIN_NAME="VPS-IP-GUARD"
IPSET_HASHSIZE=16384
IPSET_MAXELEM=262144

# Эталонные источники списков (shadow-netlab/traffic-guard-lists)
RKN_GOV_URL="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/government_networks.list"
ANTISCANNER_URL="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list"
SKIPA_URL="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/skipa.list"

CURL_CONNECT_TIMEOUT=10
CURL_MAX_TIME=60
MIN_REQUIRED_ENTRIES=50
EOF
        fi
    fi

    return 0
}

# ------------------------------------------------------------------------------
# Установка / Миграция модуля
# ------------------------------------------------------------------------------
install_or_migrate_ip_guard() {
    log_title "Установка / Миграция VPS IP Guard"
    apt-get update -qq && apt-get install -y -qq ipset curl iptables
    if ! ensure_ip_guard_installed; then
        return 1
    fi
    if /usr/local/sbin/ip-guard install; then
        log_ok "VPS IP Guard успешно установлен и активен!"
    else
        log_error "Ошибка установки/миграции. Проверьте вывод выше."
        return 1
    fi
}

is_ip_guard_installed() {
    command -v ip-guard &>/dev/null && ipset list -n 2>/dev/null | grep -qw "VPS-IP-GUARD-V4"
}

# ==============================================================================
# 1. Сводный статус безопасности
# ==============================================================================
show_full_security_status() {
    clear || true
    echo -e "${C_CYAN}==============================================================${C_RESET}"
    echo -e "${C_CYAN}            Сводный статус безопасности VPS                   ${C_RESET}"
    echo -e "${C_CYAN}==============================================================${C_RESET}\n"

    # UFW
    echo -e "${C_BLUE}--- 1. Межсетевой экран (UFW) ---${C_RESET}"
    if command -v ufw &>/dev/null; then
        ufw status verbose 2>/dev/null | head -n 12 || echo "UFW не настроен"
    else
        echo "UFW не установлен."
    fi

    # Fail2ban
    echo -e "\n${C_BLUE}--- 2. Защита от подбора паролей (Fail2ban) ---${C_RESET}"
    if command -v fail2ban-client &>/dev/null; then
        if systemctl is-active fail2ban &>/dev/null; then
            echo -e "Служба fail2ban: ${C_GREEN}Активна${C_RESET}"
            fail2ban-client status 2>/dev/null || true
        else
            echo -e "Служба fail2ban: ${C_YELLOW}Установлена, но не запущена${C_RESET}"
        fi
    else
        echo "Fail2ban не установлен."
    fi

    # VPS IP Guard
    echo -e "\n${C_BLUE}--- 3. Блокировщик сканеров и ботов (VPS IP Guard) ---${C_RESET}"
    if command -v ip-guard &>/dev/null; then
        ip-guard status
    else
        echo -e "${C_YELLOW}VPS IP Guard не установлен.${C_RESET}"
        if ipset list -n 2>/dev/null | grep -qw "SCANNERS-BLOCK-V4"; then
            echo -e "${C_YELLOW}Обнаружен старый AntiScanner (SCANNERS-BLOCK-V4). Рекомендуется миграция.${C_RESET}"
        fi
    fi

    pause
}

# ==============================================================================
# Диагностика и восстановление IP Guard
# ==============================================================================
menu_ip_guard_diagnostics() {
    while true; do
        clear || true
        echo -e "${C_CYAN}==============================================================${C_RESET}"
        echo -e "${C_CYAN}              🛠️   ДИАГНОСТИКА И ВОССТАНОВЛЕНИЕ IP GUARD       ${C_RESET}"
        echo -e "${C_CYAN}==============================================================${C_RESET}"
        echo "  1) 🔄 Перезапустить firewall rule (iptables reinit)"
        echo "  2) 💾 Восстановить список из локального кэша"
        echo "  3) 🔍 Проверить состояние ipset"
        echo "  4) 🔍 Проверить правила iptables"
        echo "  5) 📜 Показать последние логи автообновления"
        echo "  0) ⬅️  Назад"
        echo ""
        read -rp "Выберите пункт [0-5]: " d_choice

        case "$d_choice" in
            1)
                echo ""
                ip-guard reinit
                pause
                ;;
            2)
                echo ""
                ip-guard reload
                pause
                ;;
            3)
                echo ""
                ip-guard check-ipset
                pause
                ;;
            4)
                echo ""
                ip-guard check-firewall
                pause
                ;;
            5)
                clear || true
                echo -e "${C_CYAN}--- Журнал службы vps-ip-guard-update ---${C_RESET}"
                journalctl -u vps-ip-guard-update.service -n 30 --no-pager 2>/dev/null || echo "Логов пока нет."
                pause
                ;;
            0)
                return 0
                ;;
            *)
                log_warn "Неверный выбор."
                sleep 1
                ;;
        esac
    done
}

# ==============================================================================
# 2. Подменю: VPS IP Guard
# ==============================================================================
menu_ip_guard() {
    while true; do
        clear || true
        echo -e "${C_CYAN}==============================================================${C_RESET}"
        echo -e "${C_CYAN}                    🛡️  VPS IP GUARD                          ${C_RESET}"
        echo -e "${C_CYAN}==============================================================${C_RESET}"

        if ! is_ip_guard_installed; then
            echo -e "\n  ${C_YELLOW}[!] VPS IP Guard ещё не установлен на этом сервере.${C_RESET}"
            if ipset list -n 2>/dev/null | grep -qw "SCANNERS-BLOCK-V4"; then
                echo -e "  ${C_BLUE}[i] Обнаружен старый AntiScanner. Доступна бесшовная миграция.${C_RESET}"
            fi
            echo ""
            echo "  1) 🚀 Установить / Мигрировать на VPS IP Guard"
            echo "  0) ⬅️  Назад в главное меню"
            echo ""
            read -rp "Выберите пункт [0-1]: " choice
            case "$choice" in
                1) install_or_migrate_ip_guard; pause ;;
                0) return 0 ;;
                *) log_warn "Неверный выбор." ; sleep 1 ;;
            esac
            continue
        fi

        echo "  1) 📊 Статус IP Guard"
        echo "  2) 🔄 Обновить списки сейчас"
        echo "  3) 🚫 Заблокировать IP / подсеть"
        echo "  4) ✅ Разблокировать IP / подсеть"
        echo "  5) 📋 Показать ручной чёрный список"
        echo "  6) 📈 Статистика заблокированных пакетов"
        echo "  7) ⏱️  Автообновление / Таймер systemd"
        echo "  8) ⚙️  Настройки"
        echo "  9) 🛠️  Диагностика / восстановление"
        echo "  0) ⬅️  Назад"
        echo ""
        read -rp "Выберите пункт [0-9]: " choice

        case "$choice" in
            1)
                clear || true
                ip-guard status
                pause
                ;;
            2)
                echo ""
                ip-guard update
                pause
                ;;
            3)
                echo ""
                read -rp "Введите IP или CIDR (например, 1.2.3.4 или 10.0.0.0/24): " target_ip
                if [[ -n "$target_ip" ]]; then
                    ip-guard ban "$target_ip"
                fi
                pause
                ;;
            4)
                echo ""
                read -rp "Введите IP или CIDR для разблокировки: " target_ip
                if [[ -n "$target_ip" ]]; then
                    ip-guard unban "$target_ip"
                fi
                pause
                ;;
            5)
                clear || true
                ip-guard list
                pause
                ;;
            6)
                clear || true
                echo -e "${C_CYAN}--- Статистика сброшенных пакетов (iptables) ---${C_RESET}"
                iptables -L VPS-IP-GUARD -v -n 2>/dev/null || echo "Цепочка не найдена"
                pause
                ;;
            7)
                clear || true
                echo -e "${C_CYAN}--- Состояние таймера автообновления ---${C_RESET}"
                systemctl status vps-ip-guard-update.timer --no-pager 2>/dev/null || true
                echo ""
                systemctl list-timers vps-ip-guard-update.timer --no-pager 2>/dev/null || true
                pause
                ;;
            8)
                clear || true
                echo -e "${C_CYAN}--- Конфигурация /etc/vps-ip-guard/ip-guard.conf ---${C_RESET}"
                if [[ -f /etc/vps-ip-guard/ip-guard.conf ]]; then
                    cat -n /etc/vps-ip-guard/ip-guard.conf
                else
                    echo "Конфигурационный файл отсутствует."
                fi
                pause
                ;;
            9)
                menu_ip_guard_diagnostics
                ;;
            0)
                return 0
                ;;
            *)
                log_warn "Неверный выбор."
                sleep 1
                ;;
        esac
    done
}

# ==============================================================================
# 3. Подменю: Fail2ban
# ==============================================================================
menu_fail2ban() {
    while true; do
        clear || true
        echo -e "${C_CYAN}==============================================================${C_RESET}"
        echo -e "${C_CYAN}                       🔐  FAIL2BAN                           ${C_RESET}"
        echo -e "${C_CYAN}==============================================================${C_RESET}"
        echo "  1) 📊 Общий статус Fail2ban"
        echo "  2) 🔐 Статус SSH jail (sshd)"
        echo "  3) 🚫 Показать все заблокированные IP"
        echo "  4) 🔓 Разблокировать IP (unban)"
        echo "  5) ⚙️  Установить / перезапустить Fail2ban"
        echo "  6) 📋 Показать активную конфигурацию jails"
        echo "  0) ⬅️  Назад в главное меню"
        echo ""
        read -rp "Выберите пункт [0-6]: " choice

        case "$choice" in
            1)
                clear || true
                if command -v fail2ban-client &>/dev/null; then
                    fail2ban-client status
                else
                    log_warn "Fail2ban не установлен."
                fi
                pause
                ;;
            2)
                clear || true
                if command -v fail2ban-client &>/dev/null; then
                    fail2ban-client status sshd 2>/dev/null || fail2ban-client status
                else
                    log_warn "Fail2ban не установлен."
                fi
                pause
                ;;
            3)
                clear || true
                echo -e "${C_CYAN}--- Заблокированные адреса по активным jails ---${C_RESET}"
                if command -v fail2ban-client &>/dev/null; then
                    for jail in $(fail2ban-client status 2>/dev/null | grep 'Jail list:' | sed 's/.*://;s/,//g'); do
                        echo -e "\n${C_BLUE}Jail [${jail}]:${C_RESET}"
                        fail2ban-client status "$jail" | grep "Banned IP list:"
                    done
                else
                    log_warn "Fail2ban не установлен."
                fi
                pause
                ;;
            4)
                echo ""
                read -rp "Введите IP для снятия бана: " unban_ip
                if [[ -n "$unban_ip" ]]; then
                    for jail in $(fail2ban-client status 2>/dev/null | grep 'Jail list:' | sed 's/.*://;s/,//g'); do
                        fail2ban-client set "$jail" unbanip "$unban_ip" 2>/dev/null && log_ok "Разблокирован в $jail" || true
                    done
                fi
                pause
                ;;
            5)
                log_info "Установка / перезапуск Fail2ban..."
                apt-get update -qq && apt-get install -y -qq fail2ban
                systemctl enable --now fail2ban
                systemctl restart fail2ban
                log_ok "Fail2ban перезапущен и работает."
                pause
                ;;
            6)
                clear || true
                echo -e "${C_CYAN}--- Конфигурация /etc/fail2ban/jail.local ---${C_RESET}"
                if [[ -f /etc/fail2ban/jail.local ]]; then
                    cat /etc/fail2ban/jail.local
                elif [[ -f /etc/fail2ban/jail.conf ]]; then
                    head -n 40 /etc/fail2ban/jail.conf
                else
                    echo "Конфигурация не найдена."
                fi
                pause
                ;;
            0) return 0 ;;
            *) log_warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}

# ==============================================================================
# 4. Подменю: UFW / Firewall
# ==============================================================================
menu_ufw() {
    while true; do
        clear || true
        echo -e "${C_CYAN}==============================================================${C_RESET}"
        echo -e "${C_CYAN}                    🔥  UFW / FIREWALL                        ${C_RESET}"
        echo -e "${C_CYAN}==============================================================${C_RESET}"
        echo "  1) 📊 Статус UFW (подробный)"
        echo "  2) 📋 Показать правила с номерами (status numbered)"
        echo "  3) ➕ Добавить разрешающее правило (allow port/proto)"
        echo "  4) ➖ Удалить правило по номеру (delete number)"
        echo "  5) 🔍 Проверить безопасность конфигурации"
        echo "  0) ⬅️  Назад в главное меню"
        echo ""
        read -rp "Выберите пункт [0-5]: " choice

        case "$choice" in
            1) clear || true; ufw status verbose; pause ;;
            2) clear || true; ufw status numbered; pause ;;
            3)
                echo ""
                read -rp "Введите порт или службу (например, 2222/tcp или 443): " rule_input
                if [[ -n "$rule_input" ]]; then
                    ufw allow "$rule_input"
                    log_ok "Правило добавлено."
                fi
                pause
                ;;
            4)
                echo ""
                ufw status numbered
                echo ""
                read -rp "Введите номер правила для удаления: " rule_num
                if [[ -n "$rule_num" ]]; then
                    ufw delete "$rule_num"
                fi
                pause
                ;;
            5)
                clear || true
                echo -e "${C_CYAN}--- Экспресс-аудит UFW ---${C_RESET}"
                local default_in
                default_in=$(ufw status verbose | grep "Default:" | awk '{print $2}' || echo "unknown")
                if [[ "$default_in" == "deny" || "$default_in" == "reject" ]]; then
                    log_ok "Политика по умолчанию для входящего трафика: $default_in (Безопасно)"
                else
                    log_warn "Политика по умолчанию: $default_in (Рекомендуется deny)"
                fi
                echo -e "\nОткрытые порты:"
                ufw status | grep ALLOW || echo "Нет разрешающих правил"
                pause
                ;;
            0) return 0 ;;
            *) log_warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}

# ==============================================================================
# 5. Подменю: Обслуживание VPS
# ==============================================================================
menu_maintenance() {
    while true; do
        clear || true
        echo -e "${C_CYAN}==============================================================${C_RESET}"
        echo -e "${C_CYAN}                  ⚙️   ОБСЛУЖИВАНИЕ VPS                       ${C_RESET}"
        echo -e "${C_CYAN}==============================================================${C_RESET}"
        echo "  1) 🔄 Обновить списки пакетов (apt update)"
        echo "  2) 📦 Обновить пакеты системы (apt upgrade)"
        echo "  3) 🧹 Очистить ненужные пакеты и кэш (autoremove & clean)"
        echo "  4) 🔍 Проверить состояние ключевых служб"
        echo "  5) 💾 Проверить свободное место на диске (df -h)"
        echo "  6) 🧠 Проверить RAM и Swap (free -h)"
        echo "  7) 📜 Просмотреть системный журнал (journalctl)"
        echo "  8) 🔄 Перезагрузить VPS (reboot)"
        echo "  0) ⬅️  Назад в главное меню"
        echo ""
        read -rp "Выберите пункт [0-8]: " choice

        case "$choice" in
            1)
                log_info "Обновление индексов apt..."
                apt-get update
                pause
                ;;
            2)
                log_info "Обновление установленных пакетов..."
                apt-get update && apt-get upgrade -y
                pause
                ;;
            3)
                log_info "Очистка устаревших пакетов и кэша apt..."
                apt-get autoremove -y && apt-get clean
                log_ok "Система очищена."
                pause
                ;;
            4)
                clear || true
                echo -e "${C_CYAN}--- Состояние ключевых служб ---${C_RESET}"
                for s in ssh sshd ufw fail2ban vps-ip-guard xray x-ui 3x-ui; do
                    if systemctl list-unit-files "$s.service" &>/dev/null; then
                        local st
                        st=$(systemctl is-active "$s" 2>/dev/null || echo "not-found")
                        if [[ "$st" == "active" ]]; then
                            printf "  • %-15s : ${C_GREEN}active${C_RESET}\n" "$s"
                        else
                            printf "  • %-15s : ${C_YELLOW}%s${C_RESET}\n" "$s" "$st"
                        fi
                    fi
                done
                pause
                ;;
            5)
                clear || true
                echo -e "${C_CYAN}--- Использование дискового пространства ---${C_RESET}"
                df -h -x tmpfs -x devtmpfs
                pause
                ;;
            6)
                clear || true
                echo -e "${C_CYAN}--- Оперативная память и Swap ---${C_RESET}"
                free -h
                pause
                ;;
            7)
                clear || true
                echo -e "${C_CYAN}--- Последние 40 строк системного журнала ---${C_RESET}"
                journalctl -n 40 --no-pager
                pause
                ;;
            8)
                echo ""
                read -rp "Вы уверены, что хотите перезагрузить сервер? (y/N): " confirm
                if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                    log_warn "Перезагрузка сервера..."
                    reboot
                fi
                ;;
            0) return 0 ;;
            *) log_warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}

# ==============================================================================
# Главное меню менеджера безопасности
# ==============================================================================
show_main_menu() {
    while true; do
        clear || true
        echo -e "${C_CYAN}==============================================================${C_RESET}"
        echo -e "${C_CYAN}                 МЕНЕДЖЕР БЕЗОПАСНОСТИ VPS                    ${C_RESET}"
        echo -e "${C_CYAN}==============================================================${C_RESET}"
        echo ""
        echo "  1) 📊 Сводный статус безопасности"
        echo ""
        echo "  2) 🛡️  VPS IP Guard"
        echo "  3) 🔐 Fail2ban"
        echo "  4) 🔥 UFW / Firewall"
        echo ""
        echo "  5) ⚙️   Обслуживание VPS"
        echo ""
        echo "  0) 🚪 Выход"
        echo ""
        read -rp "Выберите пункт меню [0-5]: " choice

        case "$choice" in
            1) show_full_security_status ;;
            2) menu_ip_guard ;;
            3) menu_fail2ban ;;
            4) menu_ufw ;;
            5) menu_maintenance ;;
            0)
                echo "Завершение работы."
                exit 0
                ;;
            *)
                log_warn "Неверный выбор. Попробуйте снова."
                sleep 1
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Точка входа скрипта
# ------------------------------------------------------------------------------
check_root

case "${1:-}" in
    --ipguard-install|--ip-guard-install)
        install_or_migrate_ip_guard
        ;;
    --ipguard-update|--ip-guard-update)
        if command -v ip-guard &>/dev/null; then
            ip-guard update
        else
            /usr/local/sbin/ip-guard update
        fi
        ;;
    --status)
        show_full_security_status
        ;;
    *)
        show_main_menu
        ;;
esac
