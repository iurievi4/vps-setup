#!/usr/bin/env bash
# modules/mssql/config.sh — Конфигурация менеджера и безопасность каталогов

manage_config_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
        echo -e "                   ${C_BOLD}${C_GREEN}⚙️  КОНФИГУРАЦИЯ MSSQL MANAGER${C_RESET}"
        echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
        echo
        echo -e "  Каталог конфигурации : ${C_BOLD}${MSSQL_CONF_DIR}${C_RESET}"
        echo -e "  Каталог резервных копий: ${C_BOLD}${MSSQL_BACKUP_DEFAULT}${C_RESET}"
        echo -e "  Каталог журналов     : ${C_BOLD}${MSSQL_LOG_DIR}${C_RESET}"
        echo
        echo -e "  ${C_BGREEN}[1]${C_RESET} 📁 Изменить каталог резервных копий по умолчанию"
        echo -e "  ${C_BGREEN}[2]${C_RESET} 🛡️  Проверить и исправить права доступа (chmod 700 / 600)"
        echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
        echo

        local cfg_act="0"
        read_choice "${C_BOLD}Выберите действие [0-2]: ${C_RESET}" cfg_act "0"
        echo

        case "$cfg_act" in
            1)
                local new_dir=""
                read_choice "Введите новый путь для хранения бэкапов: " new_dir "$MSSQL_BACKUP_DEFAULT"
                if [[ -n "$new_dir" ]]; then
                    mkdir -p "$new_dir" 2>/dev/null || true
                    chmod 700 "$new_dir" 2>/dev/null || true
                    MSSQL_BACKUP_DEFAULT="$new_dir"
                    echo -e "${C_GREEN}✓ Путь каталога бэкапов обновлён.${C_RESET}"
                fi
                pause_prompt
                ;;
            2)
                echo ">>> Проверка и фиксация прав доступа..."
                chmod 700 "$MSSQL_CONF_DIR" "$MSSQL_CONN_DIR" "$MSSQL_LOG_DIR" "$MSSQL_BACKUP_DEFAULT" 2>/dev/null || true
                find "$MSSQL_CONN_DIR" -type f -exec chmod 600 {} + 2>/dev/null || true
                echo -e "${C_GREEN}✓ Права доступа защищены (каталоги 700, файлы профилей 600).${C_RESET}"
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
