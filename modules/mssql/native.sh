#!/usr/bin/env bash
# modules/mssql/native.sh — Управление нативной службой SQL Server

manage_native_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
        echo -e "                 ${C_BOLD}${C_GREEN}🖥️  УПРАВЛЕНИЕ НАТИВНОЙ СЛУЖБОЙ MSSQL${C_RESET}"
        echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
        echo

        local s_active="${C_RED}⏹️  Остановлена${C_RESET}"
        systemctl is-active --quiet mssql-server 2>/dev/null && s_active="${C_GREEN}● Запущена (active/running)${C_RESET}"
        
        local s_enabled="${C_RED}Отключен${C_RESET}"
        systemctl is-enabled --quiet mssql-server 2>/dev/null && s_enabled="${C_GREEN}Включен${C_RESET}"

        echo -e "  Состояние службы : ${s_active}"
        echo -e "  Автозапуск       : ${s_enabled}"
        echo
        echo -e "  ${C_BGREEN}[1]${C_RESET} ▶️  Запустить службу (systemctl start mssql-server)"
        echo -e "  ${C_BGREEN}[2]${C_RESET} ⏹️  Остановить службу (systemctl stop mssql-server)"
        echo -e "  ${C_BGREEN}[3]${C_RESET} 🔄 Перезапустить службу (systemctl restart mssql-server)"
        echo -e "  ${C_BGREEN}[4]${C_RESET} ⚙️  Включить / отключить автозапуск (enable/disable)"
        echo -e "  ${C_BGREEN}[5]${C_RESET} 📜 Журнал службы (journalctl -u mssql-server)"
        echo -e "  ${C_BGREEN}[6]${C_RESET} 🔍 Проверить статус службы (systemctl status)"
        echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
        echo

        local n_act="0"
        read_choice "${C_BOLD}Выберите действие [0-6]: ${C_RESET}" n_act "0"
        echo

        case "$n_act" in
            1)
                echo ">>> Запуск mssql-server..."
                systemctl start mssql-server 2>/dev/null || true
                sleep 2
                test_current_instance
                pause_prompt
                ;;
            2)
                confirm_action 2 "Остановка службы mssql-server" && {
                    systemctl stop mssql-server 2>/dev/null || true
                    test_current_instance
                }
                pause_prompt
                ;;
            3)
                confirm_action 2 "Перезапуск службы mssql-server" && {
                    systemctl restart mssql-server 2>/dev/null || true
                    sleep 2
                    test_current_instance
                }
                pause_prompt
                ;;
            4)
                if systemctl is-enabled --quiet mssql-server 2>/dev/null; then
                    systemctl disable mssql-server 2>/dev/null || true
                    echo -e "${C_YELLOW}Автозапуск отключен.${C_RESET}"
                else
                    systemctl enable mssql-server 2>/dev/null || true
                    echo -e "${C_GREEN}Автозапуск включен.${C_RESET}"
                fi
                pause_prompt
                ;;
            5)
                echo -e "${C_BOLD}Журнал mssql-server (последние 50 записей):${C_RESET}"
                journalctl -u mssql-server -n 50 --no-pager 2>/dev/null || echo "Логи недоступны"
                pause_prompt
                ;;
            6)
                systemctl status mssql-server --no-pager 2>/dev/null || true
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
