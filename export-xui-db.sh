#!/usr/bin/env bash
set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

OUT_DIR="/root/xui-encrypt/encrypted"
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

PBKDF2_ITER="" 
ITER_ARGS=()
if [[ -n "$PBKDF2_ITER" ]]; then
    ITER_ARGS=("-iter" "$PBKDF2_ITER")
fi

ensure_tools() {
    for cmd in sqlite3 openssl tar; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${RED}❌ Утилита $cmd не найдена. Установите: apt update && apt install -y $cmd${NC}"
            exit 1
        fi
    done
}

# ==============================================================================
# 1. СОЗДАНИЕ И ШИФРОВАНИЕ БАЗЫ
# ==============================================================================
create_and_encrypt() {
    ensure_tools

    local work_dir
    work_dir="$(mktemp -d)"
    trap 'rm -rf "$work_dir"' RETURN
    chmod 700 "$work_dir"

    local source_db="$work_dir/x-ui.db"

    echo
    echo "Выберите источник базы данных:"
    echo "  1) Снять снимок с работающего 3x-ui (/etc/x-ui/x-ui.db)"
    echo "  2) Указать файл базы из папки"
    read -rp "Ваш выбор [1-2]: " src_mode

    case "$src_mode" in
        1)
            local active_db="/etc/x-ui/x-ui.db"
            if [[ ! -s "$active_db" ]]; then
                echo -e "${RED}❌ База активного 3x-ui не найдена: $active_db${NC}"
                return 1
            fi
            echo ">>> Создание снимка базы через SQLite backup API..."
            sqlite3 "$active_db" ".backup '$source_db'"
            ;;
        2)
            read -rp "Введите полный путь к файлу базы [/root/xui-encrypt/x-ui.db]: " input_path
            input_path="${input_path:-/root/xui-encrypt/x-ui.db}"

            if [[ ! -s "$input_path" ]]; then
                echo -e "${RED}❌ Файл не найден или пустой: $input_path${NC}"
                return 1
            fi
            cp -f "$input_path" "$source_db"
            ;;
        *)
            echo -e "${RED}❌ Неверный выбор.${NC}"
            return 1
            ;;
    esac

    # Проверка целостности SQLite
    if ! sqlite3 "$source_db" 'PRAGMA integrity_check;' 2>/dev/null | grep -qx 'ok'; then
        echo -e "${RED}❌ Исходная база повреждена: PRAGMA integrity_check не пройден!${NC}"
        return 1
    fi

    local required_tables=("inbounds" "client_traffics")
    for table in "${required_tables[@]}"; do
        if ! sqlite3 "$source_db" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='$table';" 2>/dev/null | grep -qx '1'; then
            echo -e "${RED}❌ В базе отсутствует обязательная таблица: $table${NC}"
            return 1
        fi
    done

    echo -e "${GREEN}✓ Первичная проверка SQLite OK (integrity_check + inbounds + client_traffics).${NC}"
    echo

    # Сброс счетчиков трафика
    read -rp "Обнулить счетчики трафика клиентов перед упаковкой? [y/N]: " reset_traffic
    if [[ "$reset_traffic" =~ ^[YyДд]$ ]]; then
        echo ">>> Сброс счетчиков трафика..."
        if ! sqlite3 "$source_db" "UPDATE client_traffics SET up = 0, down = 0;"; then
            echo -e "${RED}❌ Ошибка при выполнении UPDATE в таблице client_traffics!${NC}"
            return 1
        fi

        if ! sqlite3 "$source_db" "VACUUM;"; then
            echo -e "${RED}❌ Ошибка при выполнении VACUUM!${NC}"
            return 1
        fi

        if ! sqlite3 "$source_db" 'PRAGMA integrity_check;' 2>/dev/null | grep -qx 'ok'; then
            echo -e "${RED}❌ База повреждена после сброса трафика и VACUUM!${NC}"
            return 1
        fi
        echo -e "${GREEN}✓ Накопленный трафик клиентов сброшен, база сжата и проверена.${NC}"
        echo
    fi

    # Выбор имени файла
    echo "Выберите целевое имя файла для setup.sh:"
    echo "  1) lv-x-ui.db  (Латвия)"
    echo "  2) mw-x-ui.db  (Москва)"
    echo "  3) tr-x-ui.db  (Турция)"
    echo "  4) Ввести своё имя"
    read -rp "Ваш выбор [1-4]: " name_choice

    local target_name=""
    case "$name_choice" in
        1) target_name="lv-x-ui.db" ;;
        2) target_name="mw-x-ui.db" ;;
        3) target_name="tr-x-ui.db" ;;
        4) read -rp "Введите имя файла (например, my-x-ui.db): " target_name ;;
        *) echo -e "${RED}❌ Неверный выбор.${NC}"; return 1 ;;
    esac

    if [[ "$target_name" != "$(basename -- "$target_name")" ]] || [[ ! "$target_name" =~ ^[A-Za-z0-9._-]+\.db$ ]]; then
        echo -e "${RED}❌ Недопустимое имя файла: '$target_name'${NC}"
        return 1
    fi

    local out_file="$OUT_DIR/$target_name"

    # Пароль
    echo
    read -rsp "Введите пароль шифрования: " db_pass
    echo
    read -rsp "Повторите пароль: " db_pass2
    echo

    if [[ "$db_pass" != "$db_pass2" ]]; then
        echo -e "${RED}❌ Пароли не совпадают.${NC}"
        return 1
    fi
    if [[ -z "$db_pass" ]]; then
        echo -e "${RED}❌ Пароль не может быть пустым.${NC}"
        return 1
    fi

    local pass_file="$work_dir/pass.tmp"
    printf '%s' "$db_pass" > "$pass_file"
    chmod 600 "$pass_file"
    unset db_pass db_pass2

    echo
    echo ">>> Упаковка в tar.gz и шифрование (AES-256-CBC + PBKDF2)..."

    local archive="$work_dir/archive.tar.gz"
    local tmp_encrypted="$work_dir/encrypted.tmp"
    local extract_dir="$work_dir/extract"

    tar -czf "$archive" -C "$work_dir" "x-ui.db"

    if ! tar -tzf "$archive" >/dev/null 2>&1; then
        echo -e "${RED}❌ Ошибка создания tar.gz архива.${NC}"
        return 1
    fi

    if ! openssl enc -aes-256-cbc -pbkdf2 "${ITER_ARGS[@]}" \
        -in "$archive" \
        -out "$tmp_encrypted" \
        -pass file:"$pass_file"; then
        echo -e "${RED}❌ Ошибка OpenSSL при шифровании.${NC}"
        return 1
    fi

    echo -e "${GREEN}✓ База зашифрована.${NC}"
    echo ">>> Проверка обратной расшифровки (Round-trip check)..."

    local decrypted="$work_dir/check.tar.gz"
    if ! openssl enc -d -aes-256-cbc -pbkdf2 "${ITER_ARGS[@]}" \
        -in "$tmp_encrypted" \
        -out "$decrypted" \
        -pass file:"$pass_file" 2>/dev/null; then
        echo -e "${RED}❌ Ошибка расшифровки (bad decrypt).${NC}"
        return 1
    fi

    if ! tar -tzf "$decrypted" >/dev/null 2>&1; then
        echo -e "${RED}❌ Расшифрованный tar.gz поврежден.${NC}"
        return 1
    fi

    mkdir -p "$extract_dir"
    tar -xzf "$decrypted" -C "$extract_dir"

    mapfile -t candidates < <(find "$extract_dir" -type f -name '*.db' -size +0c -print)
    if [[ "${#candidates[@]}" -ne 1 ]]; then
        echo -e "${RED}❌ В архиве найдено баз данных: ${#candidates[@]} (должна быть 1).${NC}"
        return 1
    fi

    local candidate="${candidates[0]}"
    if ! sqlite3 "$candidate" 'PRAGMA integrity_check;' 2>/dev/null | grep -qx 'ok'; then
        echo -e "${RED}❌ SQLite integrity_check не прошел в расшифрованной базе.${NC}"
        return 1
    fi

    for table in "${required_tables[@]}"; do
        if ! sqlite3 "$candidate" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='$table';" 2>/dev/null | grep -qx '1'; then
            echo -e "${RED}❌ В расшифрованной базе отсутствует таблица: $table${NC}"
            return 1
        fi
    done

    mv -f "$tmp_encrypted" "$out_file"
    chmod 600 "$out_file"
    rm -f "$pass_file"

    echo
    echo -e "${GREEN}==========================================================${NC}"
    echo -e "${GREEN} ✅ УСПЕШНО ЗАВЕРШЕНО: $out_file${NC}"
    echo -e "${GREEN}==========================================================${NC}"
    ls -lh "$out_file"
    echo
}

# ==============================================================================
# 2. ПРОВЕРКА ЗАШИФРОВАННОГО ФАЙЛА НА СОВМЕСТИМОСТЬ С SETUP.SH
# ==============================================================================
verify_existing_file() {
    ensure_tools

    echo
    read -rp "Укажите путь к зашифрованному файлу: " enc_file
    if [[ ! -s "$enc_file" ]]; then
        echo -e "${RED}❌ Файл не найден или пустой: $enc_file${NC}"
        return 1
    fi

    read -rsp "Введите пароль для расшифровки: " test_pass
    echo
    echo

    local work_dir
    work_dir="$(mktemp -d)"
    trap 'rm -rf "$work_dir"' RETURN
    chmod 700 "$work_dir"

    local pass_file="$work_dir/pass_test.tmp"
    printf '%s' "$test_pass" > "$pass_file"
    chmod 600 "$pass_file"
    unset test_pass

    local decrypted_archive="$work_dir/decrypted.tar.gz"
    local extract_dir="$work_dir/extract"

    echo ">>> [1/5] Расшифровка через OpenSSL (-aes-256-cbc -pbkdf2)..."
    if ! openssl enc -d -aes-256-cbc -pbkdf2 "${ITER_ARGS[@]}" \
        -in "$enc_file" \
        -out "$decrypted_archive" \
        -pass file:"$pass_file" 2>/dev/null; then
        echo -e "${RED}❌ ОШИБКА: Расшифровка не удалась (неверный пароль или неверный алгоритм).${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ Успешно расшифровано.${NC}"

    echo ">>> [2/5] Проверка архива (tar -tzf)..."
    if ! tar -tzf "$decrypted_archive" >/dev/null 2>&1; then
        echo -e "${RED}❌ ОШИБКА: Файл не является корректным tar.gz архивом.${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ Архив tar.gz корректен.${NC}"

    echo ">>> [3/5] Распаковка и поиск файлов *.db..."
    mkdir -p "$extract_dir"
    tar -xzf "$decrypted_archive" -C "$extract_dir"

    mapfile -t candidates < <(find "$extract_dir" -type f -name '*.db' -size +0c -print)
    if [[ ${#candidates[@]} -eq 0 ]]; then
        echo -e "${RED}❌ ОШИБКА: В архиве нет файлов с расширением *.db!${NC}"
        return 1
    fi
    local candidate="${candidates[0]}"
    echo -e "${GREEN}✓ Найдена база: $(basename "$candidate")${NC}"

    echo ">>> [4/5] Проверка целостности SQLite (PRAGMA integrity_check)..."
    if ! sqlite3 "$candidate" 'PRAGMA integrity_check;' 2>/dev/null | grep -qx 'ok'; then
        echo -e "${RED}❌ ОШИБКА: Целостность базы нарушена.${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ Целостность SQLite: OK.${NC}"

    echo ">>> [5/5] Поиск обязательных таблиц (inbounds, client_traffics)..."
    local req=("inbounds" "client_traffics")
    for t in "${req[@]}"; do
        if ! sqlite3 "$candidate" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='$t';" 2>/dev/null | grep -qx '1'; then
            echo -e "${RED}❌ ОШИБКА: Таблица $t отсутствует! setup.sh отклонит эту базу.${NC}"
            return 1
        fi
    done
    local inbounds_count
    inbounds_count=$(sqlite3 "$candidate" "SELECT count(*) FROM inbounds;" 2>/dev/null || echo "0")
    echo -e "${GREEN}✓ Обязательные таблицы найдены (инбаундов: $inbounds_count).${NC}"

    echo
    echo -e "${GREEN}==================================================================${NC}"
    echo -e "${GREEN} 🎯 ВЕРДИКТ: База на 100% валидна и подходит для setup.sh!${NC}"
    echo -e "${GREEN}==================================================================${NC}"
}

# Меню выбора действий
echo "=========================================================="
echo " 🎛 Управление зашифрованными базами 3x-ui для setup.sh"
echo "=========================================================="
echo "  1) Создать зашифрованную базу (из активной 3x-ui или файла)"
echo "  2) Проверить зашифрованный файл на совместимость с setup.sh"
echo "  0) Выход"
echo "----------------------------------------------------------"
read -rp "Выберите действие [0-2]: " action_choice

case "$action_choice" in
    1) create_and_encrypt ;;
    2) verify_existing_file ;;
    0) exit 0 ;;
    *) echo -e "${RED}Неверный выбор.${NC}" ;;
esac
