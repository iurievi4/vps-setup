#!/usr/bin/env bash
# modules/mssql/databases.sh — Управление базами данных SQL Server

manage_databases_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
        echo -e "                   ${C_BOLD}${C_GREEN}🗄️  УПРАВЛЕНИЕ БАЗАМИ ДАННЫХ${C_RESET}"
        echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
        echo
        echo -e "  Целевой сервер: ${C_BOLD}${CURRENT_HOST:-127.0.0.1}:${CURRENT_PORT:-1433}${C_RESET} [${CURRENT_TYPE:-none}]"
        echo
        echo -e "  ${C_BGREEN}[1]${C_RESET} 📋 Список всех баз данных (состояние, размер, модель)"
        echo -e "  ${C_BGREEN}[2]${C_RESET} 📁 Файловая структура БД (пути .mdf и .ldf файлов)"
        echo -e "  ${C_BGREEN}[3]${C_RESET} 👥 Активные подключения к базам данных"
        echo -e "  ${C_BGREEN}[4]${C_RESET} ➕ Создать новую базу данных"
        echo -e "  ${C_BRED}[5]${C_RESET} 🗑️  Удалить базу данных (с защитой и резервным копированием)"
        echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
        echo

        local db_act="0"
        read_choice "${C_BOLD}Выберите действие [0-5]: ${C_RESET}" db_act "0"
        echo

        case "$db_act" in
            1)
                list_databases
                pause_prompt
                ;;
            2)
                list_database_files
                pause_prompt
                ;;
            3)
                show_active_db_connections
                pause_prompt
                ;;
            4)
                create_database_action
                pause_prompt
                ;;
            5)
                delete_database_action
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

list_databases() {
    echo -e "${C_BOLD}${C_CYAN}Список баз данных на сервере:${C_RESET}"
    echo
    local q="SET NOCOUNT ON;
    SELECT 
        d.name AS [DatabaseName],
        d.state_desc AS [State],
        d.recovery_model_desc AS [RecoveryModel],
        CAST(SUM(mf.size) * 8.0 / 1024 AS DECIMAL(10,2)) AS [SizeMB]
    FROM sys.databases d
    JOIN sys.master_files mf ON d.database_id = mf.database_id
    GROUP BY d.name, d.state_desc, d.recovery_model_desc
    ORDER BY d.name;"

    local out
    out="$(run_sql_query "$q" "master")"
    echo "$out"
}

list_database_files() {
    local target_db=""
    read_choice "Введите имя базы данных (или Enter для master): " target_db "master"
    echo
    local q="SET NOCOUNT ON;
    SELECT 
        name AS [LogicalName],
        physical_name AS [PhysicalPath],
        type_desc AS [Type],
        CAST(size * 8.0 / 1024 AS DECIMAL(10,2)) AS [SizeMB]
    FROM sys.master_files
    WHERE database_id = DB_ID('${target_db}');"

    local out
    out="$(run_sql_query "$q" "master")"
    echo "$out"
}

show_active_db_connections() {
    echo -e "${C_BOLD}${C_CYAN}Активные сессии и подключения по базам:${C_RESET}"
    echo
    local q="SET NOCOUNT ON;
    SELECT 
        DB_NAME(dbid) AS [Database],
        COUNT(spid) AS [Connections]
    FROM sys.sysprocesses
    WHERE dbid > 0
    GROUP BY DB_NAME(dbid)
    ORDER BY [Connections] DESC;"

    local out
    out="$(run_sql_query "$q" "master")"
    echo "$out"
}

create_database_action() {
    local new_db=""
    read_choice "Введите имя создаваемой базы данных: " new_db ""
    if [[ -z "$new_db" ]]; then
        echo "Отмена."
        return 1
    fi

    # Валидация имени (только буквы, цифры, подчёркивания)
    if ! [[ "$new_db" =~ ^[a-zA-Z0-9_]+$ ]]; then
        echo -e "${C_RED}❌ Некорректное имя базы данных. Используйте латинские буквы, цифры и знак _${C_RESET}"
        return 1
    fi

    echo ">>> Создание базы данных [${new_db}]..."
    local q="CREATE DATABASE [${new_db}];"
    local out
    if out="$(run_sql_query "$q" "master")"; then
        echo -e "${C_GREEN}✓ База данных [${new_db}] успешно создана.${C_RESET}"
    else
        echo -e "${C_RED}❌ Ошибка создания базы:${C_RESET}"
        echo "$out"
    fi
}

delete_database_action() {
    list_databases
    echo
    local del_db=""
    read_choice "Введите имя базы данных для удаления: " del_db ""
    if [[ -z "$del_db" ]]; then
        echo "Отмена."
        return 1
    fi

    # Защита системных баз
    case "${del_db,,}" in
        master|tempdb|model|msdb)
            echo -e "${C_BRED}⛔ ЗАПРЕЩЕНО: База '${del_db}' является системной базой данных SQL Server!${C_RESET}"
            return 1
            ;;
    esac

    # Предложение создать резервную копию
    local bak_ans="y"
    read_choice "Создать резервную копию перед удалением? [Y/n]: " bak_ans "y"
    if [[ "$bak_ans" =~ ^[YyДд]$ || -z "$bak_ans" ]]; then
        create_backup_for_db "$del_db"
    fi

    # Уровень риска 3: подтверждение вводом точного имени
    if confirm_action 3 "Удаление базы данных приведет к БЕЗВОЗВРАТНОЙ потере всех таблиц и данных!" "$del_db"; then
        echo ">>> Принудительное закрытие подключений и удаление [${del_db}]..."
        local q="ALTER DATABASE [${del_db}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [${del_db}];"
        local out
        if out="$(run_sql_query "$q" "master")"; then
            echo -e "${C_GREEN}✓ База данных [${del_db}] успешно удалена.${C_RESET}"
        else
            echo -e "${C_RED}❌ Ошибка удаления базы:${C_RESET}"
            echo "$out"
        fi
    fi
}
