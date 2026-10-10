#!/usr/bin/env bash
# modules/mssql/security.sh — Аудит безопасности SQL Server

manage_security_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
        echo -e "                   ${C_BOLD}${C_GREEN}🛡️  АУДИТ БЕЗОПАСНОСТИ SQL SERVER${C_RESET}"
        echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
        echo
        echo -e "  Целевой сервер: ${C_BOLD}${CURRENT_HOST:-127.0.0.1}:${CURRENT_PORT:-1433}${C_RESET}"
        echo
        echo -e "  ${C_BGREEN}[1]${C_RESET} 🔍 Провести экспресс-аудит безопасности"
        echo -e "  ${C_BGREEN}[2]${C_RESET} 👤 Статус встроенной учётной записи 'sa'"
        echo -e "  ${C_BGREEN}[3]${C_RESET} 🔑 Проверка режима аутентификации (Mixed vs Windows)"
        echo -e "  ${C_BGREEN}[4]${C_RESET} 🌐 Сетевая безопасность и открытость порта"
        echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
        echo

        local s_act="0"
        read_choice "${C_BOLD}Выберите действие [0-4]: ${C_RESET}" s_act "0"
        echo

        case "$s_act" in
            1)
                run_security_audit
                pause_prompt
                ;;
            2)
                check_sa_status
                pause_prompt
                ;;
            3)
                check_auth_mode
                pause_prompt
                ;;
            4)
                manage_network_menu
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

run_security_audit() {
    echo -e "${C_BOLD}${C_CYAN}Результаты аудита безопасности:${C_RESET}"
    echo
    check_sa_status
    echo
    check_auth_mode
    echo
    echo -e "${C_BOLD}Проверка потенциально опасных расширенных процедур (xp_cmdshell):${C_RESET}"
    local q_xp="SET NOCOUNT ON; SELECT CAST(value_in_use AS INT) FROM sys.configurations WHERE name = 'xp_cmdshell';"
    local xp_val
    xp_val="$(run_sql_query "$q_xp" "master" | tr -d '\r\n ' || echo "0")"
    if [[ "$xp_val" == "1" ]]; then
        echo -e "  ${C_RED}⚠️  ВНИМАНИЕ: xp_cmdshell включен в конфигурации сервера!${C_RESET}"
    else
        echo -e "  ${C_GREEN}✓ xp_cmdshell отключен (норма).${C_RESET}"
    fi
}

check_sa_status() {
    echo -e "${C_BOLD}Статус учётной записи 'sa':${C_RESET}"
    local q="SET NOCOUNT ON; SELECT name, is_disabled FROM sys.server_principals WHERE sid = 0x01;"
    local out
    out="$(run_sql_query "$q" "master")"
    echo "$out"
}

check_auth_mode() {
    echo -e "${C_BOLD}Режим аутентификации сервера:${C_RESET}"
    local q="SET NOCOUNT ON; SELECT CASE SERVERPROPERTY('IsIntegratedSecurityOnly') WHEN 1 THEN 'Windows Authentication Only' WHEN 0 THEN 'Mixed Mode (SQL Server and Windows Authentication)' END AS [AuthMode];"
    local out
    out="$(run_sql_query "$q" "master")"
    echo "$out"
}
