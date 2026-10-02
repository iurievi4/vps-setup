#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# VPS SETUP INSTALLER
#
# 1) Полная автоматическая установка
#    -> setup.sh в тихом режиме
#    -> Первая установка: чистая SQLite-база 3x-ui
#    -> Повторный запуск: СОХРАНЕНИЕ существующей базы без затирания
#    -> PostgreSQL: NO | MSSQL: NO | TorrServer: NO | WARP: YES
#
# 2) Ручной запуск setup.sh
#    -> штатные интерактивные вопросы setup.sh (выбор баз/компонентов)
#
# 3) Только vps-security-installer.sh
#    -> Fail2ban + AntiScanner + Cloudflare WARP
#
# Повторный запуск:
#    -> FORCE_BOOTSTRAP=1 (существующая установка не блокирует выполнение)
#    -> REG_CHOICE=0 (восстановление сторонних баз не вызывается)
#
###############################################################################

REPO_RAW="https://raw.githubusercontent.com/iurievi4/vps-setup/main"

TMP_DIR="$(mktemp -d /tmp/vps-installer.XXXXXX)"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

###############################################################################
# ПРОВЕРКА ПРАВ ROOT И ЗАВИСИМОСТЕЙ
###############################################################################

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo >&2
    echo "❌ Скрипт необходимо запускать от root (sudo)." >&2
    echo >&2
    exit 1
fi

# Убеждаемся, что curl установлен корректно (без игнорирования ошибок)
if ! command -v curl >/dev/null 2>&1; then
    echo ">>> Установка curl и ca-certificates..." >&2

    apt-get update -qq
    apt-get install -y -qq curl ca-certificates >/dev/null 2>&1

    if ! command -v curl >/dev/null 2>&1; then
        echo "❌ Не удалось установить curl. Проверьте сетевое подключение и репозитории apt." >&2
        exit 1
    fi
fi

###############################################################################
# DOWNLOAD HELPER
###############################################################################

download_script() {
    local script_name="$1"
    local target="${TMP_DIR}/${script_name}"

    # Все сообщения пишем строго в stderr (>&2), чтобы в stdout попадал ТОЛЬКО путь к файлу
    echo ">>> Загрузка ${script_name}..." >&2

    curl -4 -fL \
        --retry 3 \
        --connect-timeout 15 \
        --max-time 300 \
        -H "Cache-Control: no-cache" \
        -H "Pragma: no-cache" \
        "${REPO_RAW}/${script_name}" \
        -o "$target"

    if [[ ! -s "$target" ]]; then
        echo "❌ Файл ${script_name} пустой или не был загружен." >&2
        exit 1
    fi

    if ! head -n 1 "$target" | grep -qE '^#!.*bash'; then
        echo "❌ ${script_name}: файл не является корректным Bash-скриптом." >&2
        exit 1
    fi

    chmod 700 "$target"

    # Единственный вывод в stdout — путь к скачанному файлу
    printf '%s\n' "$target"
}

###############################################################################
# MENU
###############################################################################

show_menu() {
    clear 2>/dev/null || true

    echo
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                      VPS INSTALLER                       ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo
    echo "  1) Полная автоматическая установка"
    echo "     └─ setup.sh в тихом режиме"
    if [[ -f /etc/x-ui/x-ui.db ]]; then
        echo "        • Существующая база 3x-ui: СОХРАНЯЕТСЯ (не затирается)"
    else
        echo "        • Чистая SQLite-база 3x-ui"
    fi
    echo "        • PostgreSQL: НЕТ | MS SQL: НЕТ | TorrServer: НЕТ"
    echo "        • Cloudflare WARP: ДА"
    echo "        • без интерактивных вопросов"
    echo
    echo "  2) Ручной запуск setup.sh"
    echo "     └─ штатные интерактивные вопросы setup.sh (базы/компоненты)"
    echo
    echo "  3) Установка безопасности"
    echo "     └─ vps-security-installer.sh (Fail2ban, AntiScanner, WARP)"
    echo
    echo "  0) Выход"
    echo
}

###############################################################################
# MAIN
###############################################################################

# Если номер варианта передан аргументом командной строки (например, bash installer.sh 1)
CHOICE="${1:-}"

if [[ -z "$CHOICE" ]]; then
    if [[ ! -r /dev/tty ]]; then
        echo "❌ Не найден интерактивный терминал /dev/tty." >&2
        echo "   Для автоматического запуска передайте номер аргументом: bash $0 1" >&2
        exit 1
    fi
    show_menu
    read -r -p "Выберите вариант [0-3]: " CHOICE </dev/tty
fi

echo

case "$CHOICE" in

    ###########################################################################
    # 1. FULL AUTO
    ###########################################################################
    1)
        echo "======================================================================"
        echo "  ПОЛНАЯ АВТОМАТИЧЕСКАЯ УСТАНОВКА"
        echo "======================================================================"
        echo

        SETUP_SCRIPT="$(download_script "setup.sh")"

        echo
        echo "Параметры автоматической установки:"
        echo "  PostgreSQL        : НЕТ"
        echo "  MS SQL Server     : НЕТ"
        echo "  TorrServer        : НЕТ"
        echo "  Cloudflare WARP   : ДА"
        echo "  3x-ui             : ДА"

        # Защита существующей базы при повторном запуске
        if [[ -f /etc/x-ui/x-ui.db ]]; then
            mkdir -p /root/xui_backups
            PRE_SETUP_BACKUP="/root/xui_backups/x-ui-before-setup-$(date +%Y%m%d-%H%M%S).db"
            cp -a /etc/x-ui/x-ui.db "$PRE_SETUP_BACKUP"
            echo "  База 3x-ui        : СОХРАНЕНИЕ СУЩЕСТВУЮЩЕЙ (бэкап: $(basename "$PRE_SETUP_BACKUP"))"
            echo "  Восстановление    : ПРОПУСК (текущие ключи и клиенты остаются)"
        else
            echo "  База 3x-ui        : SQLite (новая чистая база)"
            echo "  Восстановление    : НЕТ"
        fi
        echo

        # Переменные для автоматического запуска
        export DEBIAN_FRONTEND=noninteractive

        export INSTALL_POSTGRES=0
        export INSTALL_MSSQL=0
        export INSTALL_TORRSERVER=0

        export INSTALL_WARP=1
        export WARP_MANDATORY=1

        export FORCE_BOOTSTRAP=1
        # REG_CHOICE=0 инструктирует restore_custom_database пропустить накатывание бэкапов с GitHub
        export REG_CHOICE=0

        echo ">>> Запуск setup.sh..."
        echo
        bash "$SETUP_SCRIPT"

        echo
        echo "======================================================================"
        echo "  ✓ SETUP.SH ЗАВЕРШЁН"
        echo "======================================================================"
        echo
        ;;

    ###########################################################################
    # 2. MANUAL SETUP
    ###########################################################################
    2)
        echo "======================================================================"
        echo "  РУЧНОЙ ЗАПУСК SETUP.SH"
        echo "======================================================================"
        echo

        SETUP_SCRIPT="$(download_script "setup.sh")"

        echo ">>> Запуск setup.sh в штатном интерактивном режиме..."
        echo
        bash "$SETUP_SCRIPT"

        echo
        echo "======================================================================"
        echo "  ✓ SETUP.SH ЗАВЕРШЁН"
        echo "======================================================================"
        echo
        ;;

    ###########################################################################
    # 3. SECURITY
    ###########################################################################
    3)
        echo "======================================================================"
        echo "  VPS SECURITY INSTALLER"
        echo "======================================================================"
        echo

        SECURITY_SCRIPT="$(download_script "vps-security-installer.sh")"

        echo ">>> Запуск vps-security-installer.sh..."
        echo
        bash "$SECURITY_SCRIPT"

        echo
        echo "======================================================================"
        echo "  ✓ SECURITY INSTALLER ЗАВЕРШЁН"
        echo "======================================================================"
        echo
        ;;

    ###########################################################################
    # 0. EXIT
    ###########################################################################
    0)
        echo "Выход."
        exit 0
        ;;

    *)
        echo "❌ Некорректный выбор: ${CHOICE}" >&2
        exit 1
        ;;
esac
