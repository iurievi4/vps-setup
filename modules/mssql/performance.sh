#!/usr/bin/env bash
# modules/mssql/performance.sh — Мониторинг производительности и ресурсов

manage_performance_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
        echo -e "                 ${C_BOLD}${C_GREEN}📈 ПРОИЗВОДИТЕЛЬНОСТЬ И РЕСУРСЫ SQL SERVER${C_RESET}"
        echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
        echo
        echo -e "  Целевой сервер: ${C_BOLD}${CURRENT_HOST:-127.0.0.1}:${CURRENT_PORT:-1433}${C_RESET}"
        echo
        echo -e "  ${C_BGREEN}[1]${C_RESET} 🧠 Настройки памяти SQL Server (max server memory)"
        echo -e "  ${C_BGREEN}[2]${C_RESET} 🔥 Топ-10 ресурсоёмких запросов по CPU"
        echo -e "  ${C_BGREEN}[3]${C_RESET} 📊 Статистика буферного пула и кэша страниц"
        echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
        echo

        local p_act="0"
        read_choice "${C_BOLD}Выберите действие [0-3]: ${C_RESET}" p_act "0"
        echo

        case "$p_act" in
            1)
                show_memory_settings
                pause_prompt
                ;;
            2)
                show_top_cpu_queries
                pause_prompt
                ;;
            3)
                show_buffer_cache_stats
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

show_memory_settings() {
    echo -e "${C_BOLD}${C_CYAN}Конфигурация оперативной памяти SQL Server:${C_RESET}"
    echo
    local q="SET NOCOUNT ON;
    SELECT name, value, value_in_use, description 
    FROM sys.configurations 
    WHERE name IN ('min server memory (MB)', 'max server memory (MB)');"

    run_sql_query "$q" "master"
}

show_top_cpu_queries() {
    echo -e "${C_BOLD}${C_CYAN}Топ запросов по времени CPU:${C_RESET}"
    echo
    local q="SET NOCOUNT ON;
    SELECT TOP 5 
        total_worker_time/execution_count AS [AvgCPUTimeMs],
        execution_count AS [ExecCount],
        SUBSTRING(st.text, (qs.statement_start_offset/2)+1, 
            ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text) ELSE qs.statement_end_offset END - qs.statement_start_offset)/2) + 1) AS [QueryText]
    FROM sys.dm_exec_query_stats qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
    ORDER BY total_worker_time DESC;"

    run_sql_query "$q" "master"
}

show_buffer_cache_stats() {
    echo -e "${C_BOLD}${C_CYAN}Распределение кэша страниц по базам данных:${C_RESET}"
    echo
    local q="SET NOCOUNT ON;
    SELECT 
        DB_NAME(database_id) AS [Database],
        COUNT(*) * 8 / 1024 AS [CachedSizeMB]
    FROM sys.dm_os_buffer_descriptors
    WHERE database_id > 0
    GROUP BY DB_NAME(database_id)
    ORDER BY [CachedSizeMB] DESC;"

    run_sql_query "$q" "master"
}
