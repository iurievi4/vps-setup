#!/usr/bin/env bash
# ==============================================================================
# VPS Security Installer & Manager
# https://github.com/iurievi4/vps-setup
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="${SCRIPT_DIR}/modules"
IP_GUARD_SCRIPT="${MODULES_DIR}/ip-guard.sh"

C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"
C_BLUE="\033[1;34m"
C_CYAN="\033[1;36m"
C_RESET="\033[0m"

log_info()  { echo -e "${C_GREEN}[INFO]${C_RESET} $*"; }
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

# ------------------------------------------------------------------------------
# Управление IP Guard
# ------------------------------------------------------------------------------
install_or_update_ip_guard() {
    log_title "Установка / Миграция модуля VPS IP Guard"

    # Проверяем наличие файла модуля
    if [[ ! -f "$IP_GUARD_SCRIPT" ]]; then
        # Если запускается не из репозитория, ищем в стандартном пути
        if [[ -f "/usr/local/sbin/ip-guard" ]]; then
            IP_GUARD_SCRIPT="/usr/local/sbin/ip-guard"
        else
            log_error "Модуль ${IP_GUARD_SCRIPT} не найден!"
            return 1
        fi
    fi

    # 1. Установка пакетов-зависимостей
    log_info "Проверка системных зависимостей (ipset, curl, iptables)..."
    apt-get update -qq
    apt-get install -y -qq ipset curl iptables

    # 2. Создание системного симлинка
    chmod +x "$IP_GUARD_SCRIPT"
    mkdir -p /usr/local/sbin
    ln -sf "$IP_GUARD_SCRIPT" /usr/local/sbin/ip-guard
    log_info "Утилита зарегистрирована в системе: /usr/local/sbin/ip-guard"

    # 3. Вызов установки и автоматической миграции со старого AntiScanner
    /usr/local/sbin/ip-guard install

    log_info "✓ VPS IP Guard готов к работе. Защита активна."
}

# ------------------------------------------------------------------------------
# Общий статус безопасности
# ------------------------------------------------------------------------------
show_full_security_status() {
    clear || true
    echo -e "${C_CYAN}==============================================================${C_RESET}"
    echo -e "${C_CYAN}            Сводный статус безопасности VPS                   ${C_RESET}"
    echo -e "${C_CYAN}==============================================================${C_RESET}\n"

    # 1. UFW
    echo -e "${C_BLUE}--- 1. Межсетевой экран (UFW) ---${C_RESET}"
    if command -v ufw &>/dev/null; then
        ufw status verbose 2>/dev/null | head -n 12 || echo "UFW не настроен"
    else
        echo "UFW не установлен."
    fi

    # 2. Fail2ban
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

    # 3. VPS IP Guard
    echo -e "\n${C_BLUE}--- 3. Блокировщик сканеров и ботов (VPS IP Guard) ---${C_RESET}"
    if command -v ip-guard &>/dev/null; then
        ip-guard status
    else
        echo -e "${C_YELLOW}VPS IP Guard не установлен.${C_RESET}"
        if ipset list -n 2>/dev/null | grep -qw "SCANNERS-BLOCK-V4"; then
            echo -e "${C_YELLOW}Обнаружен старый AntiScanner (SCANNERS-BLOCK-V4). Рекомендуется миграция.${C_RESET}"
        fi
    fi

    echo ""
}

# ------------------------------------------------------------------------------
# Интерактивное меню
# ------------------------------------------------------------------------------
show_menu() {
    while true; do
        echo -e "\n${C_CYAN}==============================================================${C_RESET}"
        echo -e "${C_CYAN}                 Менеджер безопасности VPS                   ${C_RESET}"
        echo -e "${C_CYAN}==============================================================${C_RESET}"
        echo "  1) Показать сводный статус безопасности"
        echo "  2) Установить / Мигрировать на VPS IP Guard"
        echo "  3) Обновить списки блокировок IP Guard сейчас"
        echo "  4) Добавить IP / подсеть в чёрный список (ip-guard ban)"
        echo "  5) Удалить IP / подсеть из чёрного списка (ip-guard unban)"
        echo "  6) Установить / перенастроить Fail2ban"
        echo "  7) Проверить правила UFW"
        echo "  0) Выход"
        echo ""
        read -rp "Выберите пункт меню [0-7]: " choice

        case "$choice" in
            1)
                show_full_security_status
                ;;
            2)
                install_or_update_ip_guard
                ;;
            3)
                if command -v ip-guard &>/dev/null; then
                    ip-guard update
                else
                    log_error "IP Guard не установлен. Сначала выберите пункт 2."
                fi
                ;;
            4)
                read -rp "Введите IP или CIDR (например, 1.2.3.4 или 5.6.7.0/24): " target_ip
                if [[ -n "$target_ip" ]] && command -v ip-guard &>/dev/null; then
                    ip-guard ban "$target_ip"
                fi
                ;;
            5)
                read -rp "Введите IP или CIDR для разблокировки: " target_ip
                if [[ -n "$target_ip" ]] && command -v ip-guard &>/dev/null; then
                    ip-guard unban "$target_ip"
                fi
                ;;
            6)
                log_info "Установка / обновление Fail2ban..."
                apt-get update -qq && apt-get install -y -qq fail2ban
                systemctl enable --now fail2ban
                log_info "Fail2ban активен."
                ;;
            7)
                ufw status verbose || true
                ;;
            0)
                echo "Завершение работы."
                exit 0
                ;;
            *)
                log_warn "Неверный выбор. Попробуйте снова."
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Обработка неинтерактивных флагов (для cron / CI / скриптов)
# ------------------------------------------------------------------------------
check_root

case "${1:-}" in
    --ipguard-install|--ip-guard-install)
        install_or_update_ip_guard
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
        show_menu
        ;;
esac
