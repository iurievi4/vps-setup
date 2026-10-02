#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# VPS SETUP INSTALLER
#
# Режимы работы:
#   1) Полная автоматическая установка (тихий режим, сохранение текущей БД)
#   2) Ручной запуск setup.sh (интерактивный режим, FORCE_BOOTSTRAP=1)
#   3) Установка безопасности (vps-security-installer.sh)
#   4) Сброс маркера завершения (/etc/vps-bootstrap-complete)
#   0) Выход
#
# Повторный запуск на уже настроенном сервере:
#   - Автоматически передаётся FORCE_BOOTSTRAP=1
#   - Создаётся страховочный бэкап существующей базы /etc/x-ui/x-ui.db
###############################################################################

REPO_RAW="https://raw.githubusercontent.com/iurievi4/vps-setup/main"
BOOTSTRAP_MARKER="/etc/vps-bootstrap-complete"
XUI_DB_FILE="/etc/x-ui/x-ui.db"

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
    echo "❌ Скрипт необходимо запускать с правами root (sudo)." >&2
    echo >&2
    exit 1
fi

# Проверка и надежная установка curl без игнорирования ошибок
if ! command -v curl >/dev/null 2>&1; then
    echo ">>> Установка curl и ca-certificates..." >&2
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates >/dev/null 2>&1

    if ! command -v curl >/dev/null 2>&1; then
        echo "❌ Не удалось установить curl. Проверьте сеть и репозитории apt." >&2
        exit 1
    fi
fi

###############################################################################
# ФУНКЦИЯ РЕЗЕРВНОГО КОПИРОВАНИЯ БАЗЫ 3X-UI
###############################################################################

backup_existing_db() {
    if [[ -f "$XUI_DB_FILE" ]]; then
        mkdir -p /root/xui_backups
        local backup_path="/root/xui_backups/x-ui-before-setup-$(date +%Y%m%d-%H%M%S).db"
        cp -a "$XUI_DB_FILE" "$backup_path"
        echo "  [i] Создана страховочная копия базы: $backup_path" >&2
        echo "  [i] Существующая база 3x-ui и ваши клиенты будут сохранены." >&2
    fi
}

###############################################################################
# DOWNLOAD HELPER (с выводом логов строго в stderr)
###############################################################################

download_script() {
    local script_name="$1"
    local target="${TMP_DIR}/${script_name}"

    # Сообщения пишем в stderr, чтобы в переменную $() попадал ТОЛЬКО путь к файлу
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

    # Единственный вывод в stdout — путь к скачанному скрипту
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

    # Индикация состояния системы
    if [[ -f "$BOOTSTRAP_MARKER" ]]; then
        echo "  [●] Состояние: СЕРВЕР УЖЕ НАСТРОЕН ($BOOTSTRAP_MARKER)"
    else
        echo "  [○] Состояние: ПЕРВИЧНАЯ УСТАНОВКА"
    fi

    if [[ -f "$XUI_DB_FILE" ]]; then
        echo "  [●] База 3x-ui: ОБНАРУЖЕНА ($XUI_DB_FILE)"
    else
        echo "  [○] База 3x-ui: НЕ НАЙДЕНА (будет создана новая)"
    fi
    echo

    echo "  1) Полная автоматическая установка"
    echo "     └─ setup.sh в тихом режиме (БД сохраняется, без вопросов)"
    echo
    echo "  2) Ручной запуск setup.sh"
    echo "     └─ интерактивные вопросы (FORCE_BOOTSTRAP=1 включён)"
    echo
    echo "  3) Установка безопасности"
    echo "     └─ vps-security-installer.sh (Fail2ban, AntiScanner, WARP)"
    echo
    if [[ -f "$BOOTSTRAP_MARKER" ]]; then
        echo "  4) Сбросить маркер настройки (/etc/vps-bootstrap-complete)"
        echo "     └─ удалить маркер, чтобы любой скрипт считал сервер 'чистым'"
        echo
    fi
    echo "  0) Выход"
    echo
}

###############################################################################
# MAIN
###############################################################################

# Поддержка CLI-аргументов (например: bash vps-installer.sh 2)
CHOICE="${1:-}"

if [[ -z "$CHOICE" ]]; then
    if [[ ! -r /dev/tty ]]; then
        echo "❌ Не найден интерактивный терминал /dev/tty." >&2
        echo "   Для автоматического запуска передайте номер аргументом: bash $0 [1|2|3|4]" >&2
        exit 1
    fi
    show_menu
    read -r -p "Выберите вариант [0-4]: " CHOICE </dev/tty
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

        echo "Параметры автоматической установки:"
        echo "  PostgreSQL        : НЕТ"
        echo "  MS SQL Server     : НЕТ"
        echo "  TorrServer        : НЕТ"
        echo "  Cloudflare WARP   : ДА"
        echo "  3x-ui             : ДА"

        backup_existing_db
        echo

        # Переменные для автоматического тихого запуска
        export DEBIAN_FRONTEND=noninteractive
        export XUI_NONINTERACTIVE=1

        export INSTALL_POSTGRES=0
        export INSTALL_MSSQL=0
        export INSTALL_TORRSERVER=0

        export INSTALL_WARP=1
        export WARP_MANDATORY=1

        # Гарантирует повторный запуск setup.sh без блокировки маркером
        export FORCE_BOOTSTRAP=1
        export REG_CHOICE=0

        echo ">>> Запуск setup.sh в автоматическом режиме..."
        echo
        bash "$SETUP_SCRIPT"

        echo
        echo "======================================================================"
        echo "  ✓ SETUP.SH ЗАВЕРШЁН"
        echo "======================================================================"
        echo
        ;;

    ###########################################################################
    # 2. MANUAL SETUP (ИНТЕРАКТИВНЫЙ ПОВТОРНЫЙ ЗАПУСК)
    ###########################################################################
    2)
        echo "======================================================================"
        echo "  РУЧНОЙ ЗАПУСК SETUP.SH"
        echo "======================================================================"
        echo

        SETUP_SCRIPT="$(download_script "setup.sh")"

        if [[ -f "$BOOTSTRAP_MARKER" ]]; then
            echo "ℹ️ Обнаружен существующий маркер: $BOOTSTRAP_MARKER"
            echo "ℹ️ Активирован режим повторного запуска (FORCE_BOOTSTRAP=1)."
        fi

        backup_existing_db
        echo

        # КЛЮЧЕВОЕ ИСПРАВЛЕНИЕ: передаём FORCE_BOOTSTRAP=1, чтобы старый setup.sh
        # не выходил с ошибкой "Сервер уже настроен", а переходил к вопросам!
        export FORCE_BOOTSTRAP=1

        echo ">>> Запуск setup.sh в интерактивном режиме..."
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
    # 4. RESET BOOTSTRAP MARKER
    ###########################################################################
    4)
        echo "======================================================================"
        echo "  СБРОС МАРКЕРА УСТАНОВКИ"
        echo "======================================================================"
        echo

        if [[ -f "$BOOTSTRAP_MARKER" ]]; then
            rm -f "$BOOTSTRAP_MARKER"
            echo "✓ Маркер $BOOTSTRAP_MARKER успешно удалён."
            echo "  Теперь любая (даже самая старая) версия setup.sh запустится"
            echo "  без требования флага FORCE_BOOTSTRAP=1."
        else
            echo "ℹ️ Маркер $BOOTSTRAP_MARKER отсутствует (сервер и так считается чистым)."
        fi
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
