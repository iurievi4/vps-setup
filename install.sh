#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# VPS SETUP INSTALLER
#
# 1) Полная автоматическая установка
#    -> только setup.sh
#    -> PostgreSQL: NO
#    -> MSSQL: NO
#    -> TorrServer: NO
#    -> WARP: YES
#    -> 3x-ui: SQLite
#    -> база: чистая установка / без восстановления
#
# 2) Ручной запуск setup.sh
#    -> интерактивные вопросы setup.sh
#
# 3) Только vps-security-installer.sh
#    -> Fail2ban + AntiScanner + Cloudflare WARP
#
# Повторный запуск:
#    -> FORCE_BOOTSTRAP=1
#    -> существующая установка не блокирует запуск
#    -> REG_CHOICE=0, восстановление базы не выполняется
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

# Убеждаемся, что curl установлен до первой попытки скачивания
if ! command -v curl >/dev/null 2>&1; then
    echo ">>> Установка curl и ca-certificates..." >&2
    apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null 2>&1 || true
fi

###############################################################################
# DOWNLOAD HELPER
###############################################################################

download_script() {
    local script_name="$1"
    local target="${TMP_DIR}/${script_name}"

    # Все сообщения пишем в stderr (>&2), чтобы в stdout попадал ТОЛЬКО путь к файлу
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
    echo "     └─ только setup.sh"
    echo "        • чистая SQLite-база 3x-ui"
    echo "        • PostgreSQL: НЕТ"
    echo "        • MS SQL: НЕТ"
    echo "        • TorrServer: НЕТ"
    echo "        • Cloudflare WARP: ДА"
    echo "        • без лишних вопросов"
    echo
    echo "  2) Ручной запуск setup.sh"
    echo "     └─ штатные интерактивные вопросы setup.sh"
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
        echo "  База 3x-ui        : SQLite"
        echo "  Восстановление    : НЕТ"
        echo

        if [[ -f /etc/vps-bootstrap-complete ]]; then
            echo "ℹ️ Обнаружен существующий VPS bootstrap."
            echo "ℹ️ Разрешён повторный запуск setup.sh."
            echo "ℹ️ Существующая база 3x-ui не восстанавливается."
        else
            echo "ℹ️ Первая установка."
            echo "ℹ️ 3x-ui будет установлен с новой пустой SQLite-базой."
        fi
        echo

        # Переменные для автоматического запуска
        export DEBIAN_FRONTEND=noninteractive
        export XUI_NONINTERACTIVE=1

        export INSTALL_POSTGRES=0
        export INSTALL_MSSQL=0
        export INSTALL_TORRSERVER=0

        export INSTALL_WARP=1
        export WARP_MANDATORY=1

        export FORCE_BOOTSTRAP=1
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
