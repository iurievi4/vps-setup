#!/usr/bin/env bash
# modules/mssql/diagnostics.sh — Диагностика, системные отчёты и сбор логов

manage_diagnostics_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
        echo -e "                   ${C_BOLD}${C_GREEN}🔍 ДИАГНОСТИКА И ЖУРНАЛЫ ОШИБОК${C_RESET}"
        echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
        echo
        echo -e "  Целевой сервер: ${C_BOLD}${CURRENT_HOST:-127.0.0.1}:${CURRENT_PORT:-1433}${C_RESET} [${CURRENT_TYPE:-none}]"
        echo
        echo -e "  ${C_BGREEN}[1]${C_RESET} 📑 Сформировать полный диагностический отчёт (без секретов)"
        echo -e "  ${C_BGREEN}[2]${C_RESET} 📜 Просмотр последних записей SQL Server ErrorLog"
        echo -e "  ${C_BGREEN}[3]${C_RESET} 📂 Список сохранённых отчётов в ${MSSQL_LOG_DIR}"
        echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
        echo

        local d_act="0"
        read_choice "${C_BOLD}Выберите действие [0-3]: ${C_RESET}" d_act "0"
        echo

        case "$d_act" in
            1)
                generate_diagnostic_report
                pause_prompt
                ;;
            2)
                show_sql_errorlog
                pause_prompt
                ;;
            3)
                list_reports
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

generate_diagnostic_report() {
    mkdir -p "$MSSQL_LOG_DIR"
    local stamp
    stamp="$(date +%Y-%m-%d_%H-%M-%S)"
    local report_file="${MSSQL_LOG_DIR}/diagnostic_report_${stamp}.txt"

    echo ">>> Сбор диагностической информации в ${report_file}..."
    (
        umask 077
        echo "==========================================================" > "$report_file"
        echo "MSSQL MANAGER — ДИАГНОСТИЧЕСКИЙ ОТЧЁТ" >> "$report_file"
        echo "Дата формирования: $(date)" >> "$report_file"
        echo "Хост: $(hostname) | Ядро: $(uname -r)" >> "$report_file"
        echo "==========================================================" >> "$report_file"
        echo "" >> "$report_file"

        echo "1. ЦЕЛЕВОЙ ЭКЗЕМПЛЯР:" >> "$report_file"
        echo "Тип: ${CURRENT_TYPE:-none}" >> "$report_file"
        echo "Сервер: ${CURRENT_HOST:-127.0.0.1}:${CURRENT_PORT:-1433}" >> "$report_file"
        echo "Пользователь: ${CURRENT_USER:-sa}" >> "$report_file"
        echo "Статус: ${CURRENT_STATUS:-N/A}" >> "$report_file"
        echo "" >> "$report_file"

        echo "2. ДИСКОВОЕ ПРОСТРАНСТВО:" >> "$report_file"
        df -h / >> "$report_file" 2>&1 || true
        echo "" >> "$report_file"

        echo "3. СЕТЕВЫЕ СОКЕТЫ (:1433):" >> "$report_file"
        ss -tulpn 2>/dev/null | grep -E "Netid|:1433\b" >> "$report_file" || true
        echo "" >> "$report_file"

        echo "4. БАЗЫ ДАННЫХ:" >> "$report_file"
        local q_dbs="SET NOCOUNT ON; SELECT name, state_desc, recovery_model_desc FROM sys.databases;"
        run_sql_query "$q_dbs" "master" >> "$report_file" 2>&1 || true
        echo "" >> "$report_file"

        echo "5. СЕРВЕРНЫЕ ЛОГИНЫ:" >> "$report_file"
        local q_logins="SET NOCOUNT ON; SELECT name, type_desc, is_disabled FROM sys.server_principals WHERE type IN ('S','U');"
        run_sql_query "$q_logins" "master" >> "$report_file" 2>&1 || true

        chmod 600 "$report_file"
    )

    echo -e "${C_GREEN}✓ Диагностический отчёт успешно сохранён:${C_RESET}"
    echo -e "  ${C_BOLD}${report_file}${C_RESET} (права 600)"
}

show_sql_errorlog() {
    echo -e "${C_BOLD}${C_CYAN}Последние записи журнала ошибок SQL Server:${C_RESET}"
    echo
    local q="SET NOCOUNT ON; EXEC sp_readerrorlog 0, 1;"
    local out
    out="$(run_sql_query "$q" "master" 2>/dev/null | tail -n 40 || true)"
    if [[ -z "$out" ]]; then
        if [[ "$CURRENT_TYPE" == "docker" ]]; then
            docker logs --tail 40 "${CURRENT_CONTAINER:-mssql_server}" 2>&1 || echo "Логи недоступны"
        else
            journalctl -u mssql-server -n 40 --no-pager 2>/dev/null || echo "Логи недоступны"
        fi
    else
        echo "$out"
    fi
}

list_reports() {
    echo -e "${C_BOLD}Сохранённые отчёты в ${MSSQL_LOG_DIR}:${C_RESET}"
    echo
    local files
    files="$(find "$MSSQL_LOG_DIR" -maxdepth 1 -name "diagnostic_report_*.txt" 2>/dev/null | sort -r || true)"
    if [[ -z "$files" ]]; then
        echo "  Отчётов пока нет."
    else
        for f in $files; do
            echo "  • $(basename "$f") ($(du -h "$f" | awk '{print $1}'))"
        done
    fi
}
