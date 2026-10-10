#!/usr/bin/env bash
# modules/mssql/backup.sh — Резервное копирование баз данных SQL Server

manage_backup_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
        echo -e "                   ${C_BOLD}${C_GREEN}💾 РЕЗЕРВНОЕ КОПИРОВАНИЕ (.BAK)${C_RESET}"
        echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
        echo
        echo -e "  Каталог хранения бэкапов на хосте: ${C_BOLD}${MSSQL_BACKUP_DEFAULT}${C_RESET}"
        echo -e "  Целевой сервер                   : ${CURRENT_HOST:-127.0.0.1} [${CURRENT_TYPE:-none}]"
        echo
        echo -e "  ${C_BGREEN}[1]${C_RESET} 📦 Создать резервную копию конкретной базы (.bak)"
        echo -e "  ${C_BGREEN}[2]${C_RESET} 🗄️  Создать резервные копии всех пользовательских баз"
        echo -e "  ${C_BGREEN}[3]${C_RESET} 📋 Список существующих файлов резервных копий"
        echo -e "  ${C_BGREEN}[4]${C_RESET} 🔍 Проверить целостность файла бэкапа (RESTORE VERIFYONLY)"
        echo -e "  ${C_BGREEN}[5]${C_RESET} 🧹 Очистить бэкапы старше N дней (Retention policy)"
        echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
        echo

        local b_act="0"
        read_choice "${C_BOLD}Выберите действие [0-5]: ${C_RESET}" b_act "0"
        echo

        mkdir -p "$MSSQL_BACKUP_DEFAULT"

        case "$b_act" in
            1)
                local db_name=""
                read_choice "Введите имя базы данных для создания бэкапа: " db_name ""
                if [[ -n "$db_name" ]]; then
                    create_backup_for_db "$db_name"
                fi
                pause_prompt
                ;;
            2)
                create_all_user_backups
                pause_prompt
                ;;
            3)
                list_backups_list
                pause_prompt
                ;;
            4)
                verify_backup_file_action
                pause_prompt
                ;;
            5)
                cleanup_old_backups_action
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

create_backup_for_db() {
    local db="$1"
    local stamp
    stamp="$(date +%Y-%m-%d_%H-%M-%S)"
    local s_label="${CURRENT_HOST//./_}"
    local bak_filename="${s_label}_${db}_${stamp}.bak"

    echo ">>> Запуск резервного копирования базы [${db}]..."

    local target_bak_internal="/var/opt/mssql/data/${bak_filename}"
    local host_bak_file="${MSSQL_BACKUP_DEFAULT}/${bak_filename}"

    local q="BACKUP DATABASE [${db}] TO DISK = '${target_bak_internal}' WITH FORMAT, INIT, COMPRESSION, STATS = 10, CHECKSUM;"
    local out
    out="$(run_sql_query "$q" "master")"

    if echo "$out" | grep -qiE 'processed|successfully'; then
        echo -e "${C_GREEN}✓ SQL Server завершил создание копии внутри хранилища.${C_RESET}"

        # Если Docker — копируем файл из контейнера на хост
        if [[ "$CURRENT_TYPE" == "docker" ]]; then
            echo ">>> Копирование резервной копии из контейнера на хост..."
            if docker cp "${CURRENT_CONTAINER}:${target_bak_internal}" "$host_bak_file" 2>/dev/null; then
                chmod 600 "$host_bak_file"
                local sz
                sz="$(du -h "$host_bak_file" | awk '{print $1}')"
                echo -e "${C_GREEN}✓ Файл бэкапа сохранён на хосте: ${host_bak_file} (${sz})${C_RESET}"
            else
                echo -e "${C_YELLOW}Файл создан внутри контейнера: ${target_bak_internal}${C_RESET}"
            fi
        else
            echo -e "${C_GREEN}✓ Файл бэкапа сохранён: ${target_bak_internal}${C_RESET}"
        fi

        # Проверка целостности созданного файла
        echo ">>> Проверка целостности (RESTORE VERIFYONLY)..."
        local v_q="RESTORE VERIFYONLY FROM DISK = '${target_bak_internal}';"
        local v_out
        v_out="$(run_sql_query "$v_q" "master")"
        if echo "$v_out" | grep -qi 'is valid'; then
            echo -e "${C_GREEN}✓ Целостность подтверждена: бэкап валиден.${C_RESET}"
        else
            echo -e "${C_YELLOW}Результат проверки:${C_RESET} ${v_out}"
        fi
    else
        echo -e "${C_RED}❌ Ошибка резервного копирования базы [${db}]:${C_RESET}"
        echo "$out"
    fi
}

create_all_user_backups() {
    echo ">>> Получение списка пользовательских баз данных..."
    local q="SET NOCOUNT ON; SELECT name FROM sys.databases WHERE database_id > 4 AND state_desc = 'ONLINE';"
    local dbs_out
    dbs_out="$(run_sql_query "$q" "master")"

    local dbs=()
    while IFS= read -r line; do
        line="$(echo "$line" | tr -d '\r ')"
        [[ -n "$line" && "$line" != "name" && "$line" != "---"* ]] && dbs+=("$line")
    done <<< "$dbs_out"

    if [[ ${#dbs[@]} -eq 0 ]]; then
        echo -e "${C_YELLOW}Пользовательские базы данных не найдены.${C_RESET}"
        return 0
    fi

    echo -e "Найдено баз данных: ${C_BOLD}${#dbs[@]}${C_RESET} (${dbs[*]})"
    for db in "${dbs[@]}"; do
        echo "--------------------------------------------------------"
        create_backup_for_db "$db"
    done
    echo "--------------------------------------------------------"
    echo -e "${C_GREEN}✓ Пакетное резервное копирование завершено.${C_RESET}"
}

list_backups_list() {
    echo -e "${C_BOLD}${C_CYAN}Резервные копии в ${MSSQL_BACKUP_DEFAULT}:${C_RESET}"
    echo
    local baks
    baks="$(find "$MSSQL_BACKUP_DEFAULT" -maxdepth 1 -name "*.bak" 2>/dev/null | sort -r || true)"
    if [[ -z "$baks" ]]; then
        echo -e "  ${C_GRAY}Файлы *.bak не найдены.${C_RESET}"
    else
        for f in $baks; do
            local sz dt
            sz="$(du -h "$f" | awk '{print $1}')"
            dt="$(date -r "$f" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "N/A")"
            echo -e "  • ${C_BOLD}$(basename "$f")${C_RESET} [${sz}, ${dt}]"
        done
    fi
}

verify_backup_file_action() {
    list_backups_list
    echo
    local bak_file=""
    read_choice "Введите имя файла .bak для проверки: " bak_file ""
    local full_path="${MSSQL_BACKUP_DEFAULT}/${bak_file}"
    if [[ ! -f "$full_path" && -f "$bak_file" ]]; then
        full_path="$bak_file"
    fi

    if [[ ! -f "$full_path" ]]; then
        echo "Файл не найден."
        return 1
    fi

    echo ">>> Проверка заголовков и целостности файла $(basename "$full_path")..."
    # Если Docker, копируем файл внутрь контейнера во временный каталог для проверки
    local target_in_sql="/var/opt/mssql/data/$(basename "$full_path")"
    if [[ "$CURRENT_TYPE" == "docker" ]]; then
        docker cp "$full_path" "${CURRENT_CONTAINER}:${target_in_sql}" 2>/dev/null || true
    else
        target_in_sql="$full_path"
    fi

    local q="RESTORE HEADERONLY FROM DISK = '${target_in_sql}'; RESTORE VERIFYONLY FROM DISK = '${target_in_sql}';"
    local out
    out="$(run_sql_query "$q" "master")"
    echo "$out"
}

cleanup_old_backups_action() {
    local days="14"
    read_choice "Удалить бэкапы старше скольких дней? [14]: " days "14"
    if ! [[ "$days" =~ ^[0-9]+$ ]]; then
        echo "Некорректное число дней."
        return 1
    fi

    confirm_action 2 "Удаление резервных копий старше ${days} дней в ${MSSQL_BACKUP_DEFAULT}" && {
        find "$MSSQL_BACKUP_DEFAULT" -maxdepth 1 -name "*.bak" -mtime +"$days" -delete 2>/dev/null || true
        echo -e "${C_GREEN}✓ Старые резервные копии очищены.${C_RESET}"
    }
}
