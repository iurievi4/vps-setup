#!/usr/bin/env bash
set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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
    local missing=()
    for cmd in sqlite3 openssl tar; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${YELLOW}>>> Установка недостающих утилит (${missing[*]})...${NC}"
        apt-get update -qq && apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1
        for cmd in "${missing[@]}"; do
            if ! command -v "$cmd" >/dev/null 2>&1; then
                echo -e "${RED}❌ Не удалось автоматически установить: $cmd. Проверьте репозитории apt.${NC}"
                exit 1
            fi
        done
        echo -e "${GREEN}✓ Необходимые утилиты успешно установлены.${NC}"
    fi
}

validate_sqlite() {
    local db_file="$1"
    if ! sqlite3 "$db_file" 'PRAGMA integrity_check;' 2>/dev/null | grep -qx 'ok'; then
        echo -e "${RED}❌ Ошибка: PRAGMA integrity_check не вернул 'ok' для $(basename "$db_file")${NC}"
        return 1
    fi
}

validate_database_schema() {
    local db_file="$1"

    # Проверка обязательных таблиц
    local required_tables=("inbounds" "client_traffics")
    for table in "${required_tables[@]}"; do
        if ! sqlite3 "$db_file" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='$table';" 2>/dev/null | grep -qx '1'; then
            echo -e "${RED}❌ Ошибка структуры: отсутствует таблица '$table'${NC}"
            return 1
        fi
    done

    # Проверка ключевых колонок таблицы inbounds
    local inbound_cols=("port" "protocol" "settings")
    for col in "${inbound_cols[@]}"; do
        if ! sqlite3 "$db_file" "PRAGMA table_info(inbounds);" 2>/dev/null | cut -d'|' -f2 | grep -qx "$col"; then
            echo -e "${RED}❌ Ошибка структуры: в таблице 'inbounds' отсутствует колонка '$col'${NC}"
            return 1
        fi
    done

    # Проверка ключевых колонок таблицы client_traffics
    local traffic_cols=("up" "down")
    for col in "${traffic_cols[@]}"; do
        if ! sqlite3 "$db_file" "PRAGMA table_info(client_traffics);" 2>/dev/null | cut -d'|' -f2 | grep -qx "$col"; then
            echo -e "${RED}❌ Ошибка структуры: в таблице 'client_traffics' отсутствует колонка '$col'${NC}"
            return 1
        fi
    done
}

validate_archive() {
    local tar_file="$1"
    if ! tar -tzf "$tar_file" >/dev/null 2>&1; then
        echo -e "${RED}❌ Ошибка архива: файл не является корректным tar.gz архивом${NC}"
        return 1
    fi
}

decrypt_archive() {
    local enc_file="$1"
    local pass_file="$2"
    local out_tar="$3"

    if ! openssl enc -d -aes-256-cbc -pbkdf2 "${ITER_ARGS[@]}" \
        -in "$enc_file" \
        -out "$out_tar" \
        -pass file:"$pass_file" 2>/dev/null; then
        echo -e "${RED}❌ Ошибка расшифровки OpenSSL: неверный пароль или несовместимый формат KDF/Cipher${NC}"
        return 1
    fi
}

encrypt_database() {
    local db_to_pack="$1"
    local pass_file="$2"
    local out_enc="$3"
    local work_dir="$4"

    local archive="$work_dir/archive.tar.gz"
    tar -czf "$archive" -C "$(dirname "$db_to_pack")" "$(basename "$db_to_pack")"

    if ! validate_archive "$archive"; then
        return 1
    fi

    if ! openssl enc -aes-256-cbc -pbkdf2 "${ITER_ARGS[@]}" \
        -in "$archive" \
        -out "$out_enc" \
        -pass file:"$pass_file"; then
        echo -e "${RED}❌ Ошибка OpenSSL при шифровании${NC}"
        return 1
    fi

    # Проверка размера зашифрованного файла
    if [[ ! -s "$out_enc" ]]; then
        echo -e "${RED}❌ Ошибка: зашифрованный файл пуст${NC}"
        return 1
    fi

    local file_size
    file_size="$(wc -c < "$out_enc" | tr -d ' ')"
    if [[ "$file_size" -lt 512 ]]; then
        echo -e "${RED}❌ Ошибка: размер зашифрованного файла подозрительно мал ($file_size байт)${NC}"
        return 1
    fi
}

validate_restore_payload() {
    local extract_dir="$1"

    mapfile -t candidates < <(find "$extract_dir" -type f -name '*.db' -size +0c -print)

    # Строго ровно один файл БД в архиве
    if [[ "${#candidates[@]}" -ne 1 ]]; then
        echo -e "${RED}❌ Ошибка формата: в архиве найдено баз данных: ${#candidates[@]} (требуется строго 1)${NC}"
        return 1
    fi

    local candidate="${candidates[0]}"
    local candidate_name
    candidate_name="$(basename "$candidate")"

    # Предупреждение, если имя не x-ui.db
    if [[ "$candidate_name" != "x-ui.db" ]]; then
        echo -e "${YELLOW}⚠️ Предупреждение: файл базы внутри архива назван '$candidate_name' (рекомендуется 'x-ui.db')${NC}"
    fi

    validate_sqlite "$candidate"
    validate_database_schema "$candidate"
}

create_and_encrypt() {
    echo -e "${BLUE}=== Создание и шифрование базы для setup.sh ===${NC}"
    ensure_tools

    local work_dir
    work_dir="$(mktemp -d)"
    trap 'rm -rf "$work_dir"' RETURN
    chmod 700 "$work_dir"

    local source_db="$work_dir/x-ui.db"

    echo
    echo "Выберите источник базы данных:"
    echo "  1) Снять дамп с активной 3x-ui (/etc/x-ui/x-ui.db)"
    echo "  2) Указать файл базы из каталога"
    read -rp "Ваш выбор [1-2]: " src_mode

    case "$src_mode" in
        1)
            local active_db="/etc/x-ui/x-ui.db"
            if [[ ! -s "$active_db" ]]; then
                echo -e "${RED}❌ Активная база 3x-ui не найдена: $active_db${NC}"
                return 1
            fi
            echo ">>> Создание консистентного снимка SQLite backup API..."
            sqlite3 "$active_db" ".backup '$source_db'"
            ;;
        2)
            read -rp "Введите путь к исходному файлу базы [/root/xui-encrypt/x-ui.db]: " input_path
            input_path="${input_path:-/root/xui-encrypt/x-ui.db}"

            if [[ ! -s "$input_path" ]]; then
                echo -e "${RED}❌ Исходный файл не найден или пустой: $input_path${NC}"
                return 1
            fi
            cp -f "$input_path" "$source_db"
            ;;
        *)
            echo -e "${RED}❌ Неверный выбор.${NC}"
            return 1
            ;;
    esac

    # 1. Первичная валидация
    if ! validate_sqlite "$source_db" || ! validate_database_schema "$source_db"; then
        echo -e "${RED}❌ Исходная база не прошла валидацию структуры или целостности.${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ Исходная база проверена: SQLite integrity OK, таблицы и поля валидны.${NC}"
    echo

    # 2. Опциональный сброс трафика с повторной валидацией
    read -rp "Обнулить счетчики трафика клиентов перед упаковкой? [y/N]: " reset_traffic
    if [[ "$reset_traffic" =~ ^[YyДд]$ ]]; then
        echo ">>> Сброс счетчиков трафика..."
        if ! sqlite3 "$source_db" "UPDATE client_traffics SET up = 0, down = 0;"; then
            echo -e "${RED}❌ Ошибка выполнения UPDATE в client_traffics!${NC}"
            return 1
        fi

        if ! sqlite3 "$source_db" "VACUUM;"; then
            echo -e "${RED}❌ Ошибка выполнения VACUUM!${NC}"
            return 1
        fi

        if ! validate_sqlite "$source_db"; then
            echo -e "${RED}❌ Целостность базы нарушена после VACUUM!${NC}"
            return 1
        fi
        echo -e "${GREEN}✓ Трафик клиентов сброшен, база сжата (VACUUM) и повторно валидирована.${NC}"
        echo
    fi

    # 3. Выбор целевого имени с защитой от Path Traversal
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

    # Строгая проверка имени
    if [[ "$target_name" != "$(basename -- "$target_name")" ]] || [[ ! "$target_name" =~ ^[A-Za-z0-9._-]+\.db$ ]]; then
        echo -e "${RED}❌ Недопустимое имя файла: '$target_name'. Разрешены только простые имена c .db${NC}"
        return 1
    fi

    local out_file="$OUT_DIR/$target_name"

    # 4. Пароль через изолированный файл
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

    echo ">>> Упаковка в tar.gz и шифрование (AES-256-CBC + PBKDF2)..."
    local tmp_encrypted="$work_dir/encrypted.tmp"

    if ! encrypt_database "$source_db" "$pass_file" "$tmp_encrypted" "$work_dir"; then
        return 1
    fi

    echo -e "${GREEN}✓ Шифрование завершено.${NC}"
    echo ">>> Контрольная проверка по алгоритму восстановления setup.sh..."

    # 5. Сквозной тест расшифровки и восстановления
    local check_tar="$work_dir/check.tar.gz"
    local extract_dir="$work_dir/extract"

    if ! decrypt_archive "$tmp_encrypted" "$pass_file" "$check_tar"; then
        return 1
    fi

    if ! validate_archive "$check_tar"; then
        return 1
    fi

    mkdir -p "$extract_dir"
    tar -xzf "$check_tar" -C "$extract_dir"

    if ! validate_restore_payload "$extract_dir"; then
        return 1
    fi

    # 6. Атомарная замена целевого файла только после всех проверок
    mv -f "$tmp_encrypted" "$out_file"
    chmod 600 "$out_file"
    rm -f "$pass_file"

    local checksum
    checksum="$(sha256sum "$out_file" | awk '{print $1}')"
    local final_size
    final_size="$(ls -lh "$out_file" | awk '{print $5}')"

    echo
    echo -e "${CYAN}==================================================================${NC}"
    echo -e "${GREEN} ✅ ФАЙЛ УСПЕШНО СОЗДАН И ВАЛИДИРОВАН ПО СХЕМЕ SETUP.SH${NC}"
    echo -e "${CYAN}==================================================================${NC}"
    echo -e " Путь файла      : ${YELLOW}$out_file${NC}"
    echo -e " Размер          : ${final_size}"
    echo -e " Алгоритм        : AES-256-CBC (PBKDF2${PBKDF2_ITER:+, iter $PBKDF2_ITER})"
    echo -e " Контейнер       : tar.gz (x-ui.db)"
    echo -e " Проверка SQLite : integrity OK, inbounds OK, client_traffics OK"
    echo -e " SHA-256         : ${CYAN}${checksum}${NC}"
    echo -e "${CYAN}==================================================================${NC}"
    echo
}

verify_existing_file() {
    echo -e "${BLUE}=== Проверка зашифрованного файла по алгоритму setup.sh ===${NC}"
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

    local decrypted_tar="$work_dir/decrypted.tar.gz"
    local extract_dir="$work_dir/extract"

    echo ">>> [1/4] Расшифровка через OpenSSL (-aes-256-cbc -pbkdf2)..."
    if ! decrypt_archive "$enc_file" "$pass_file" "$decrypted_tar"; then
        return 1
    fi
    echo -e "${GREEN}✓ Расшифровка успешна.${NC}"

    echo ">>> [2/4] Проверка целостности архива (tar -tzf)..."
    if ! validate_archive "$decrypted_tar"; then
        return 1
    fi
    echo -e "${GREEN}✓ Архив tar.gz валиден.${NC}"

    echo ">>> [3/4] Распаковка и поиск файлов базы..."
    mkdir -p "$extract_dir"
    tar -xzf "$decrypted_tar" -C "$extract_dir"

    echo ">>> [4/4] Валидация SQLite, таблиц и колонок..."
    if ! validate_restore_payload "$extract_dir"; then
        return 1
    fi

    local checksum
    checksum="$(sha256sum "$enc_file" | awk '{print $1}')"

    echo
    echo -e "${CYAN}==================================================================${NC}"
    echo -e "${GREEN} 🎯 РЕЗУЛЬТАТ: Проверка по алгоритму восстановления setup.sh ПРОЙДЕНА${NC}"
    echo -e "${CYAN}==================================================================${NC}"
    echo -e " Файл    : $enc_file"
    echo -e " Статус  : Полностью совместим с процедурой восстановления setup.sh"
    echo -e " SHA-256 : ${CYAN}${checksum}${NC}"
    echo -e "${CYAN}==================================================================${NC}"
    echo
}

ACTION="${1:-}"

case "$ACTION" in
    create)
        create_and_encrypt
        ;;
    verify)
        verify_existing_file
        ;;
    *)
        echo "=========================================================="
        echo " 🎛 Управление зашифрованными базами 3x-ui для setup.sh"
        echo "=========================================================="
        echo "  1) Создать зашифрованную базу"
        echo "  2) Проверить зашифрованный файл по алгоритму setup.sh"
        echo "  0) Выход"
        echo "----------------------------------------------------------"
        read -rp "Выберите действие [0-2]: " action_choice

        case "$action_choice" in
            1) create_and_encrypt ;;
            2) verify_existing_file ;;
            0) exit 0 ;;
            *) echo -e "${RED}Неверный выбор.${NC}" ;;
        esac
        ;;
esac
