#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_URL="https://raw.githubusercontent.com/iurievi4/vps-setup/main/setup2.sh"
TMP_ORIGINAL="/tmp/setup2-original.sh"
TMP_FIXED="/tmp/setup2-fixed.sh"

cleanup() {
    rm -f "$TMP_ORIGINAL" "$TMP_FIXED"
}
trap cleanup EXIT

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "❌ Запустите скрипт от root."
    exit 1
fi

command -v curl >/dev/null 2>&1 || { echo "❌ Не найден curl."; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "❌ Не найден python3."; exit 1; }

echo
echo "======================================================================"
echo " 🛠️ VPS BOOTSTRAP 3x-ui — FIXED"
echo "======================================================================"
echo ">>> Загружаю актуальный setup2.sh..."

curl -4 -fsSL --retry 3 --connect-timeout 15 --max-time 300 \
    "$SOURCE_URL" -o "$TMP_ORIGINAL"

[[ -s "$TMP_ORIGINAL" ]] || { echo "❌ Не удалось скачать setup2.sh."; exit 1; }

grep -q 'restore_custom_database' "$TMP_ORIGINAL" || {
    echo "❌ Скачанный файл не похож на ожидаемый setup2.sh."
    exit 1
}

python3 - "$TMP_ORIGINAL" "$TMP_FIXED" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text(encoding="utf-8")
out = Path(sys.argv[2])

start_marker = "restore_custom_database() {"
end_marker = "# 9. СКРИПТЫ ОБСЛУЖИВАНИЯ"

start = src.find(start_marker)
end = src.find(end_marker, start)

if start < 0 or end < 0:
    raise SystemExit("Не найден ожидаемый блок restore_custom_database().")

new_function = r"""restore_custom_database() {
    local reg_choice="${REG_CHOICE:-}"
    local token="${GH_TOKEN:-}"
    local db_pass="${DB_PASS:-}"
    local repo="iurievi4/my-private-backups"
    local db_file=""
    local max_attempts=3
    local attempt=0

    read_masked_password() {
        local prompt="$1"
        local __resultvar="$2"
        local password=""
        local char=""
        local old_stty=""

        if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
            return 1
        fi

        printf "%s" "$prompt" > /dev/tty
        old_stty="$(stty -g < /dev/tty 2>/dev/null)" || return 1

        stty -echo -icanon min 1 time 0 < /dev/tty 2>/dev/null || {
            stty "$old_stty" < /dev/tty 2>/dev/null || true
            return 1
        }

        while IFS= read -r -n 1 char < /dev/tty; do
            case "$char" in
                $'\n'|$'\r')
                    break
                    ;;
                $'\177'|$'\b')
                    if [[ -n "$password" ]]; then
                        password="${password%?}"
                        printf '\b \b' > /dev/tty
                    fi
                    ;;
                *)
                    password+="$char"
                    printf '*' > /dev/tty
                    ;;
            esac
        done

        stty "$old_stty" < /dev/tty 2>/dev/null || true
        printf '\n' > /dev/tty
        printf -v "$__resultvar" '%s' "$password"
        return 0
    }

    if [[ -z "$reg_choice" ]] && [[ -r /dev/tty ]]; then
        echo
        echo "Выберите конфигурацию 3x-ui:"
        echo "  0) Чистая установка [по умолчанию]"
        echo "  1) Латвия  (lv-x-ui.db)"
        echo "  2) Москва  (mw-x-ui.db)"
        echo "  3) Турция  (tr-x-ui.db)"
        echo
        read -rp "Выбор [0-3]: " reg_choice </dev/tty || true
    fi

    reg_choice="${reg_choice:-0}"

    case "$reg_choice" in
        0)
            echo "  [i] Выбрана чистая установка."
            return 0
            ;;
        1) db_file="lv-x-ui.db" ;;
        2) db_file="mw-x-ui.db" ;;
        3) db_file="tr-x-ui.db" ;;
        *)
            echo "❌ Некорректный выбор: '${reg_choice}'."
            echo "   Восстановление базы пропущено."
            return 0
            ;;
    esac

    if [[ -z "$token" ]] && [[ -r /dev/tty ]]; then
        read -rsp "Введите GitHub Token: " token </dev/tty || true
        echo
    fi

    if [[ -z "$token" ]]; then
        echo "❌ GitHub Token не указан."
        echo "   Восстановление базы пропущено. Bootstrap продолжится."
        return 0
    fi

    if [[ -n "$db_pass" ]]; then
        max_attempts=1
    fi

    systemctl stop x-ui 2>/dev/null || true
    /usr/local/sbin/xui-backup.sh 2>/dev/null || true

    local tmp_db="/tmp/${db_file}"
    local decrypted_blob="/tmp/${db_file}.decrypted"
    local decrypted_db="/tmp/x-ui-restored.db"

    rm -f "$tmp_db" "$decrypted_blob" "$decrypted_db"

    local http_code
    http_code="$(curl -4 -sS -w "%{http_code}" \
        -H "Authorization: Bearer ${token}" \
        -H "Accept: application/vnd.github.raw+json" \
        --connect-timeout 15 \
        --max-time 300 \
        -o "$tmp_db" \
        "https://api.github.com/repos/${repo}/contents/${db_file}")"

    if [[ "$http_code" != "200" ]] || [[ ! -s "$tmp_db" ]]; then
        echo "❌ Ошибка скачивания базы (HTTP: ${http_code})."
        rm -f "$tmp_db" "$decrypted_blob" "$decrypted_db"
        systemctl start x-ui 2>/dev/null || true
        echo "   Восстановление пропущено. Bootstrap продолжится."
        return 0
    fi

    while (( attempt < max_attempts )); do
        ((attempt += 1))

        if [[ -z "$db_pass" ]]; then
            echo
            echo "🔐 Ввод пароля отображается маской *. Попытка ${attempt}/${max_attempts}."
            if ! read_masked_password "Введите мастер-пароль базы: " db_pass; then
                echo "❌ Не удалось прочитать пароль из /dev/tty."
                break
            fi
        fi

        if [[ -z "$db_pass" ]]; then
            echo "❌ Пароль не введён."
            db_pass=""
            continue
        fi

        rm -f "$decrypted_blob" "$decrypted_db"

        if openssl enc -d -aes-256-cbc -pbkdf2 \
                -in "$tmp_db" \
                -out "$decrypted_blob" \
                -pass pass:"$db_pass" 2>/dev/null &&
           [[ -s "$decrypted_blob" ]] &&
           tar -xzf "$decrypted_blob" -O > "$decrypted_db" 2>/dev/null &&
           [[ -s "$decrypted_db" ]] &&
           sqlite3 "$decrypted_db" "PRAGMA integrity_check;" 2>/dev/null |
               awk 'BEGIN{ok=0} $0=="ok"{ok=1} END{exit(ok?0:1)}'
        then
            install -o root -g root -m 600 "$decrypted_db" /etc/x-ui/x-ui.db

            sqlite3 /etc/x-ui/x-ui.db \
                "UPDATE client_traffics SET up = 0, down = 0;" 2>/dev/null || true
            sqlite3 /etc/x-ui/x-ui.db \
                "UPDATE inbounds SET up = 0, down = 0;" 2>/dev/null || true
            sqlite3 /etc/x-ui/x-ui.db \
                "DELETE FROM inbound_client_ips;" 2>/dev/null || true

            echo
            echo "✓ База ${db_file} успешно проверена и установлена."
            echo "✓ Integrity check SQLite: OK."
            echo "✓ Счетчики трафика обнулены."

            rm -f "$tmp_db" "$decrypted_blob" "$decrypted_db"

            systemctl restart x-ui 2>/dev/null || true
            sleep 5

            if systemctl is-active --quiet x-ui; then
                echo "✓ x-ui успешно запущен."
            else
                echo "⚠️ База установлена, но x-ui не перешёл в active."
            fi

            return 0
        fi

        rm -f "$decrypted_blob" "$decrypted_db"

        echo
        echo "❌ Неверный пароль или архив не удалось расшифровать."
        db_pass=""

        if (( attempt < max_attempts )); then
            echo "↻ Повторите ввод. Осталось попыток: $((max_attempts - attempt))."
        fi
    done

    rm -f "$tmp_db" "$decrypted_blob" "$decrypted_db"

    echo
    echo "⚠️ Восстановление базы ${db_file} НЕ выполнено."
    echo "   Существующая /etc/x-ui/x-ui.db не изменена."
    echo "   Запускаю x-ui с текущей базой."

    systemctl start x-ui 2>/dev/null || true

    if systemctl is-active --quiet x-ui; then
        echo "✓ x-ui запущен. Bootstrap продолжится."
    else
        echo "⚠️ x-ui не запустился автоматически."
        echo "   Финальная проверка покажет состояние службы."
    fi

    return 0
}
"""

fixed = src[:start] + new_function + "\n" + src[end:]

old = """restore_custom_database

# Восстанавливаем Nginx"""
new = """if ! restore_custom_database; then
    echo "⚠️ Восстановление базы завершилось ошибкой."
    echo "   Продолжаю bootstrap без замены текущей базы."
    systemctl start x-ui 2>/dev/null || true
fi

# Восстанавливаем Nginx"""

if old not in fixed:
    raise SystemExit("Не найден ожидаемый вызов restore_custom_database.")

fixed = fixed.replace(old, new, 1)
out.write_text(fixed, encoding="utf-8")
PY

chmod 700 "$TMP_FIXED"

echo "✓ Исправленная версия подготовлена."
echo ">>> Запускаю исправленный setup2.sh..."
echo

exec bash "$TMP_FIXED" "$@"
