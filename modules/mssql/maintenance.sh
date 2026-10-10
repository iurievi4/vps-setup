#!/usr/bin/env bash
# modules/mssql/maintenance.sh — Обслуживание и целостность баз данных

manage_maintenance_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
        echo -e "                   ${C_BOLD}${C_GREEN}🔧 ОБСЛУЖИВАНИЕ БАЗ ДАННЫХ SQL SERVER${C_RESET}"
        echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
        echo
        echo -e "  Целевой сервер: ${C_BOLD}${CURRENT_HOST:-127.0.0.1}:${CURRENT_PORT:-1433}${C_RESET}"
        echo
        echo -e "  ${C_BGREEN}[1]${C_RESET} 🩺 Проверка целостности базы (DBCC CHECKDB)"
        echo -e "  ${C_BGREEN}[2]${C_RESET} 📊 Обновить статистику индексов (sp_updatestats)"
        echo -e "  ${C_BGREEN}[3]${C_RESET} 🔍 Просмотр активных блокировок и ожиданий"
        echo -e "  ${C_BGREEN}[4]${C_RESET} 🧹 Очистить процедурный кэш (DBCC FREEPROCCACHE)"
        echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
        echo

        local m_act="0"
        read_choice "${C_BOLD}Выберите действие [0-4]: ${C_RESET}" m_act "0"
        echo

        case "$m_act" in
            1)
                run_dbcc_checkdb_action
                pause_prompt
                ;;
            2)
                update_stats_action
                pause_prompt
                ;;
            3)
                show_locks_and_blocks
                pause_prompt
                ;;
            4)
                confirm_action 2 "Сброс процедурного кэша SQL Server" && {
                    echo ">>> Выполнение DBCC FREEPROCCACHE..."
                    run_sql_query "DBCC FREEPROCCACHE;" "master"
                    echo -e "${C_GREEN}✓ Кэш планов выполнения сброшен.${C_RESET}"
                }
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

run_dbcc_checkdb_action() {
    local target_db=""
    read_choice "Введите имя базы данных для проверки: " target_db "master"
    if [[ -z "$target_db" ]]; then
        echo "Отмена."
        return 1
    fi

    echo ">>> Запуск DBCC CHECKDB('${target_db}') с флагом NO_INFOMSGS..."
    local q="DBCC CHECKDB('${target_db}') WITH NO_INFOMSGS;"
    local out
    out="$(run_sql_query "$q" "master")"
    if [[ -z "$out" || "$out" == *"0 errors"* ]]; then
        echo -e "${C_GREEN}✓ Проверка завершена: повреждений и ошибок в базе '${target_db}' не обнаружено!${C_RESET}"
    else
        echo -e "${C_YELLOW}Результат проверки:${C_RESET}"
        echo "$out"
    fi
}

update_stats_action() {
    local target_db=""
    read_choice "Введите имя базы данных для обновления статистики: " target_db "master"
    if [[ -z "$target_db" ]]; then
        echo "Отмена."
        return 1
    fi

    echo ">>> Обновление статистики в базе [${target_db}] (sp_updatestats)..."
    local q="EXEC sp_updatestats;"
    local out
    out="$(run_sql_query "$q" "$target_db")"
    echo "$out"
    echo -e "${C_GREEN}✓ Статистика обновлена.${C_RESET}"
}

show_locks_and_blocks() {
    echo -e "${C_BOLD}${C_CYAN}Текущие блокировки процессов:${C_RESET}"
    echo
    local q="SET NOCOUNT ON;
    SELECT 
        r.session_id AS [BlockedSession],
        r.blocking_session_id AS [BlockingSession],
        r.wait_type AS [WaitType],
        r.wait_time AS [WaitTimeMs],
        r.wait_resource AS [WaitResource]
    FROM sys.dm_exec_requests r
    WHERE r.blocking_session_id <> 0;"

    local out
    out="$(run_sql_query "$q" "master")"
    if [[ -z "$out" || "$out" == *"0 rows"* ]]; then
        echo -e "${C_GREEN}✓ Блокировок между процессами нет.${C_RESET}"
    else
        echo "$out"
    fi
}
