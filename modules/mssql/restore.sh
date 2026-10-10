#!/usr/bin/env bash
# modules/mssql/restore.sh — Восстановление баз данных из резервных копий

manage_restore_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
        echo -e "                   ${C_BOLD}${C_GREEN}⏪ ВОССТАНОВЛЕНИЕ БАЗ ДАННЫХ (.BAK)${C_RESET}"
        echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
        echo
        echo -e "  Каталог хранения бэкапов : ${C_BOLD}${MSSQL_BACKUP_DEFAULT}${C_RESET}"
        echo -e "  Целевой сервер           : ${CURRENT_HOST:-127.0.0.1} [${CURRENT_TYPE:-none}]"
        echo
        echo -e "  ${C_BGREEN}[1]${C_RESET} 🔍 Проверить состав файла бэкапа (HEADERONLY & FILELISTONLY)"
        echo -e "  ${C_BGREEN}[2]${C_RESET} 🆕 Восстановить бэкап в НОВУЮ базу данных (безопасный режим)"
        echo -e "  ${C_BRED}[3]${C_RESET} ⚠️  Восстановить поверх СУЩЕСТВУЮЩЕЙ базы (с перезаписью)"
        echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
        echo

        local r_act="0"
        read_choice "${C_BOLD}Выберите действие [0-3]: ${C_RESET}" r_act "0"
        echo

        case "$r_act" in
            1)
                inspect_backup_files_action
                pause_prompt
                ;;
            2)
                restore_to_new_db_action
                pause_prompt
                ;;
            3)
                restore_overwrite_db_action
                pause_prompt
                ;;
            0|q|exit|back|назад)
                return 0
                ;;
            *)
                echo -e "${C_RED}Некорректный выбор.${C_RESET}"
                sleep 1
                ;;
        esac
    done
}

inspect_backup_files_action() {
    list_backups_list
    echo
    local bak_file=""
    read_choice "Введите имя файла .bak: " bak_file ""
    local full_path="${MSSQL_BACKUP_DEFAULT}/${bak_file}"
    [[ ! -f "$full_path" && -f "$bak_file" ]] && full_path="$bak_file"

    if [[ ! -f "$full_path" ]]; then
        echo "Файл не найден."
        return 1
    fi

    local target_in_sql="/var/opt/mssql/data/$(basename "$full_path")"
    if [[ "$CURRENT_TYPE" == "docker" ]]; then
        docker cp "$full_path" "${CURRENT_CONTAINER}:${target_in_sql}" 2>/dev/null || true
    else
        target_in_sql="$full_path"
    fi

    echo -e "${C_BOLD}${C_CYAN}=== Метаданные резервной копии ===${C_RESET}"
    local q_header="RESTORE HEADERONLY FROM DISK = '${target_in_sql}';"
    run_sql_query "$q_header" "master"
    echo
    echo -e "${C_BOLD}${C_CYAN}=== Логические файлы данных и журналов ===${C_RESET}"
    local q_files="RESTORE FILELISTONLY FROM DISK = '${target_in_sql}';"
    run_sql_query "$q_files" "master"
}

restore_to_new_db_action() {
    list_backups_list
    echo
    local bak_file="" new_db=""
    read_choice "Введите имя файла .bak для восстановления: " bak_file ""
    local full_path="${MSSQL_BACKUP_DEFAULT}/${bak_file}"
    [[ ! -f "$full_path" && -f "$bak_file" ]] && full_path="$bak_file"

    if [[ ! -f "$full_path" ]]; then
        echo "Файл не найден."
        return 1
    fi

    read_choice "Введите имя НОВОЙ базы данных: " new_db ""
    if [[ -z "$new_db" ]] || ! [[ "$new_db" =~ ^[a-zA-Z0-9_]+$ ]]; then
        echo -e "${C_RED}❌ Некорректное имя базы данных.${C_RESET}"
        return 1
    fi

    local target_in_sql="/var/opt/mssql/data/$(basename "$full_path")"
    if [[ "$CURRENT_TYPE" == "docker" ]]; then
        docker cp "$full_path" "${CURRENT_CONTAINER}:${target_in_sql}" 2>/dev/null || true
    else
        target_in_sql="$full_path"
    fi

    echo ">>> Определение логических имен файлов внутри бэкапа..."
    local q_files="SET NOCOUNT ON; RESTORE FILELISTONLY FROM DISK = '${target_in_sql}';"
    local fl_out
    fl_out="$(run_sql_query "$q_files" "master")"

    local data_logical="" log_logical=""
    data_logical="$(echo "$fl_out" | awk '$3=="D" {print $1}' | head -n 1 || true)"
    log_logical="$(echo "$fl_out" | awk '$3=="L" {print $1}' | head -n 1 || true)"

    if [[ -z "$data_logical" ]]; then
        data_logical="$(echo "$fl_out" | grep -i 'mdf' | awk '{print $1}' | head -n 1 || true)"
        log_logical="$(echo "$fl_out" | grep -i 'ldf' | awk '{print $1}' | head -n 1 || true)"
    fi

    echo "Логический файл данных : ${data_logical:-[авто]}"
    echo "Логический файл журнала: ${log_logical:-[авто]}"

    local move_clause=""
    if [[ -n "$data_logical" && -n "$log_logical" ]]; then
        move_clause="MOVE '${data_logical}' TO '/var/opt/mssql/data/${new_db}.mdf', MOVE '${log_logical}' TO '/var/opt/mssql/data/${new_db}_log.ldf'"
    fi

    local q_restore="RESTORE DATABASE [${new_db}] FROM DISK = '${target_in_sql}'"
    [[ -n "$move_clause" ]] && q_restore="${q_restore} WITH ${move_clause}, STATS = 10;" || q_restore="${q_restore} WITH STATS = 10;"

    echo ">>> Запуск восстановления в базу [${new_db}]..."
    local out
    out="$(run_sql_query "$q_restore" "master")"
    if echo "$out" | grep -qiE 'processed|successfully'; then
        echo -e "${C_GREEN}✓ База данных [${new_db}] успешно восстановлена!${C_RESET}"
    else
        echo -e "${C_RED}❌ Ошибка восстановления базы:${C_RESET}"
        echo "$out"
    fi
}

restore_overwrite_db_action() {
    list_backups_list
    echo
    local bak_file="" target_db=""
    read_choice "Введите имя файла .bak: " bak_file ""
    local full_path="${MSSQL_BACKUP_DEFAULT}/${bak_file}"
    [[ ! -f "$full_path" && -f "$bak_file" ]] && full_path="$bak_file"

    if [[ ! -f "$full_path" ]]; then
        echo "Файл не найден."
        return 1
    fi

    read_choice "Введите имя СУЩЕСТВУЮЩЕЙ базы данных для перезаписи: " target_db ""
    if [[ -z "$target_db" ]]; then
        echo "Отмена."
        return 1
    fi

    # Защита системных баз
    case "${target_db,,}" in
        master|tempdb|model|msdb)
            echo -e "${C_BRED}⛔ ЗАПРЕЩЕНО: Перезапись системных баз данных недопустима!${C_RESET}"
            return 1
            ;;
    esac

    # Автоматическое создание страховочной копии текущей базы
    echo -e "${C_YELLOW}>>> Создание обязательной страховочной копии текущей базы [${target_db}]...${C_RESET}"
    create_backup_for_db "$target_db"

    # Уровень риска 3: подтверждение вводом точного имени
    if confirm_action 3 "Перезапись базы [${target_db}] уничтожит её текущие данные!" "$target_db"; then
        local target_in_sql="/var/opt/mssql/data/$(basename "$full_path")"
        if [[ "$CURRENT_TYPE" == "docker" ]]; then
            docker cp "$full_path" "${CURRENT_CONTAINER}:${target_in_sql}" 2>/dev/null || true
        else
            target_in_sql="$full_path"
        fi

        echo ">>> Принудительное закрытие сессий и восстановление с параметром REPLACE..."
        local q_restore="ALTER DATABASE [${target_db}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
        RESTORE DATABASE [${target_db}] FROM DISK = '${target_in_sql}' WITH REPLACE, STATS = 10;
        ALTER DATABASE [${target_db}] SET MULTI_USER;"

        local out
        out="$(run_sql_query "$q_restore" "master")"
        if echo "$out" | grep -qiE 'processed|successfully'; then
            echo -e "${C_GREEN}✓ База данных [${target_db}] успешно перезаписана из резервной копии!${C_RESET}"
        else
            echo -e "${C_RED}❌ Ошибка восстановления базы:${C_RESET}"
            echo "$out"
        fi
    fi
}
