#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# VPS MANAGEMENT · MODULE
# MSSQL Manager — Универсальный менеджер Microsoft SQL Server для Linux VPS
# Репозиторий: vps-setup
#
# Режимы работы:
#   - Локальный SQL Server в Docker (контейнер mssql_server)
#   - Нативная служба systemd (mssql-server)
#   - Удалённый SQL Server по TCP
#
# Created by iurievi4 using Gemini Spark and GPT.
###############################################################################

REPO_RAW="https://raw.githubusercontent.com/iurievi4/vps-setup/main"

# Определение каталога расположения скрипта и модулей
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "/root")"
if [[ "$SCRIPT_DIR" == "/tmp"* || "$SCRIPT_DIR" == "/proc"* || -z "$SCRIPT_DIR" ]]; then
    SCRIPT_DIR="/root"
fi
MODULES_DIR="${SCRIPT_DIR}/modules/mssql"
mkdir -p "$MODULES_DIR" 2>/dev/null || true

# Проверка прав суперпользователя (root)
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo >&2
    echo -e "\033[0;31m❌ Скрипт необходимо запускать с правами root (sudo).\033[0m" >&2
    echo >&2
    exit 1
fi

ALL_MODULES=(
    common.sh
    detect.sh
    connections.sh
    docker.sh
    native.sh
    databases.sh
    users.sh
    backup.sh
    restore.sh
    security.sh
    network.sh
    maintenance.sh
    performance.sh
    diagnostics.sh
    config.sh
)

# Проверка и автоматическая дозагрузка модулей с GitHub при их отсутствии
for mod in "${ALL_MODULES[@]}"; do
    mod_path="${MODULES_DIR}/${mod}"
    if [[ ! -s "$mod_path" ]]; then
        echo -e "\033[0;90m>>> Загрузка модуля ${mod} с GitHub (${REPO_RAW}/modules/mssql/${mod})...\033[0m" >&2
        curl -4 -fsSL --retry 3 --connect-timeout 10 --max-time 60 \
            "${REPO_RAW}/modules/mssql/${mod}" -o "$mod_path" 2>/dev/null || true
        chmod +x "$mod_path" 2>/dev/null || true
    fi

    if [[ -s "$mod_path" ]]; then
        source "$mod_path"
    else
        echo -e "\033[0;31m❌ Ошибка: не удалось найти или загрузить модуль ${mod} (${mod_path})\033[0m" >&2
        echo -e "   Убедитесь в наличии интернет-соединения или клонируйте репозиторий полностью." >&2
        exit 1
    fi
done

# Инициализация каталогов конфигурации и логов
init_directories

# Первичное автообнаружение окружения
detect_all_instances

show_main_menu() {
    clear 2>/dev/null || true
    echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
    echo -e "                          ${C_BOLD}${C_GREEN}MSSQL MANAGER${C_RESET}"
    echo -e "                  ${C_GRAY}Управление Microsoft SQL Server${C_RESET}"
    echo -e "           ${C_BOLD}${C_CYAN}Created by iurievi4 using Gemini Spark and GPT.${C_RESET}"
    echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
    echo
    echo -e "${C_BOLD}${C_YELLOW}  ТЕКУЩИЙ ЭКЗЕМПЛЯР${C_RESET}"
    echo -e "  ${C_GRAY}──────────────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_GRAY}├─${C_RESET} Тип        : ${C_BOLD}${CURRENT_TYPE:-none}${C_RESET}"
    echo -e "  ${C_GRAY}├─${C_RESET} Сервер     : ${C_BOLD}${CURRENT_HOST:-127.0.0.1}:${CURRENT_PORT:-1433}${C_RESET} ${CURRENT_CONTAINER:+[контейнер: $CURRENT_CONTAINER]}"
    echo -e "  ${C_GRAY}├─${C_RESET} Версия     : ${C_BCYAN}${CURRENT_VERSION:-N/A}${C_RESET}"
    echo -e "  ${C_GRAY}└─${C_RESET} Состояние  : ${CURRENT_STATUS:-N/A}"
    echo
    echo -e "${C_BOLD}${C_CYAN}  УПРАВЛЕНИЕ${C_RESET}"
    echo -e "  ${C_GRAY}──────────────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_BGREEN}[1]${C_RESET}  📊 Обзор и экспресс-диагностика"
    echo -e "  ${C_BGREEN}[2]${C_RESET}  🔌 Выбор и управление подключениями (Docker / Native / Remote)"
    echo -e "  ${C_BGREEN}[3]${C_RESET}  ⚙️  Управление службой / контейнером SQL Server"
    echo -e "  ${C_BGREEN}[4]${C_RESET}  🗄️  Управление базами данных (список, создание, удаление)"
    echo -e "  ${C_BGREEN}[5]${C_RESET}  👤 Пользователи, логины и права (Logins & Roles)"
    echo -e "  ${C_BGREEN}[6]${C_RESET}  💾 Резервное копирование (.bak)"
    echo -e "  ${C_BGREEN}[7]${C_RESET}  ⏪ Восстановление баз данных"
    echo -e "  ${C_BGREEN}[8]${C_RESET}  🛡️  Сетевые настройки и безопасность (UFW & Security Audit)"
    echo -e "  ${C_BGREEN}[9]${C_RESET}  🔧 Обслуживание баз данных (DBCC CHECKDB & Статистика)"
    echo -e "  ${C_BGREEN}[10]${C_RESET} 📈 Производительность и ресурсы (Память, CPU, кэш)"
    echo -e "  ${C_BGREEN}[11]${C_RESET} ⚙️  Конфигурация менеджера"
    echo -e "  ${C_BGREEN}[12]${C_RESET} 📜 Журналы и отчёты"
    echo
    echo -e "  ${C_RED}[0]${C_RESET}  🚪 Выход"
    echo -e "${C_GRAY}──────────────────────────────────────────────────────────────────────${C_RESET}"
}

manage_service_dispatch() {
    if [[ "$CURRENT_TYPE" == "docker" ]]; then
        manage_docker_menu
    elif [[ "$CURRENT_TYPE" == "native" ]]; then
        manage_native_menu
    elif [[ "$CURRENT_TYPE" == "remote" ]]; then
        echo -e "${C_YELLOW}ℹ️  Текущее подключение является удалённым (${CURRENT_HOST}:${CURRENT_PORT}).${C_RESET}"
        echo -e "   Управление службой удалённого сервера на уровне ОС недоступно через SQL-протокол."
        echo -e "   Вы можете администрировать базы данных, пользователей и бэкапы через пункты [4-10]."
        pause_prompt
    else
        echo -e "${C_YELLOW}Экземпляр SQL Server не выбран. Перейдите в пункт [2].${C_RESET}"
        pause_prompt
    fi
}

main() {
    local cli_cmd="${1:-}"

    case "$cli_cmd" in
        status)
            test_current_instance
            echo "Тип: ${CURRENT_TYPE}, Сервер: ${CURRENT_HOST}:${CURRENT_PORT}, Статус: ${CURRENT_STATUS}"
            exit 0
            ;;
        list-dbs)
            list_databases
            exit 0
            ;;
        backup)
            local b_target="${2:-}"
            if [[ -n "$b_target" ]]; then
                create_backup_for_db "$b_target"
            else
                create_all_user_backups
            fi
            exit 0
            ;;
    esac

    while true; do
        show_main_menu
        local choice="0"
        read_choice "${C_BOLD}Выберите действие [0-12]: ${C_RESET}" choice "0"
        echo

        case "$choice" in
            1)
                generate_diagnostic_report
                pause_prompt
                ;;
            2)
                manage_connections_menu
                ;;
            3)
                manage_service_dispatch
                ;;
            4)
                manage_databases_menu
                ;;
            5)
                manage_users_menu
                ;;
            6)
                manage_backup_menu
                ;;
            7)
                manage_restore_menu
                ;;
            8)
                manage_security_menu
                ;;
            9)
                manage_maintenance_menu
                ;;
            10)
                manage_performance_menu
                ;;
            11)
                manage_config_menu
                ;;
            12)
                manage_diagnostics_menu
                ;;
            0|q|exit)
                echo "Выход из MSSQL Manager."
                exit 0
                ;;
            *)
                echo -e "${C_RED}❌ Некорректный выбор: ${choice}${C_RESET}" >&2
                sleep 1
                ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "${1:-}"
fi
