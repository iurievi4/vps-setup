#!/usr/bin/env bash
# modules/mssql/network.sh — Сетевые настройки и брандмауэр UFW

manage_network_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
        echo -e "                   ${C_BOLD}${C_GREEN}🌐 СЕТЕВЫЕ НАСТРОЙКИ И ФАЕРВОЛ UFW${C_RESET}"
        echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
        echo
        local port="${CURRENT_PORT:-1433}"
        echo -e "  Порт SQL Server : ${C_BOLD}${port}${C_RESET}"
        echo

        local sock_status="${C_RED}○ Не слушается${C_RESET}"
        if command -v ss >/dev/null 2>&1; then
            if ss -tulpn 2>/dev/null | grep -E ":${port}\b" >/dev/null 2>&1; then
                sock_status="${C_GREEN}● Слушается в системе${C_RESET}"
            fi
        fi
        echo -e "  Сокет порта     : ${sock_status}"

        local ufw_status="${C_GRAY}UFW не установлен / выключен${C_RESET}"
        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw "Status: active"; then
            if ufw status | grep -qE "^${port}(/tcp)?[[:space:]]+ALLOW"; then
                ufw_status="${C_GREEN}✓ Открыт в UFW${C_RESET}"
            else
                ufw_status="${C_RED}⚠️ Закрыт в UFW (внешний доступ заблокирован)${C_RESET}"
            fi
        fi
        echo -e "  Статус в UFW    : ${ufw_status}"
        echo
        echo -e "  ${C_BGREEN}[1]${C_RESET} 🔍 Проверить сетевые сокеты (:1433)"
        echo -e "  ${C_BGREEN}[2]${C_RESET} 🧱 Разрешить порт ${port}/tcp в UFW"
        echo -e "  ${C_BGREEN}[3]${C_RESET} 🔒 Закрыть (удалить) правило для порта ${port}/tcp в UFW"
        echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
        echo

        local nw_act="0"
        read_choice "${C_BOLD}Выберите действие [0-3]: ${C_RESET}" nw_act "0"
        echo

        case "$nw_act" in
            1)
                echo -e "${C_BOLD}Сетевые сокеты порта ${port}:${C_RESET}"
                ss -tulpn 2>/dev/null | grep -E "Netid|:${port}\b" || echo "Сокеты не найдены"
                pause_prompt
                ;;
            2)
                if ! command -v ufw >/dev/null 2>&1; then
                    echo "UFW не установлен."
                else
                    echo -e "${C_YELLOW}Внимание: открытие порта 1433 для всего интернета повышает риск атак перебором!${C_RESET}"
                    echo -e "Рекомендуется ограничивать доступ конкретными доверенными IP-адресами."
                    local conf_allow="n"
                    read_choice "Разрешить порт ${port}/tcp в UFW? [y/N]: " conf_allow "n"
                    if [[ "$conf_allow" =~ ^[YyДд]$ ]]; then
                        ufw allow "${port}/tcp" comment 'MSSQL Server' 2>/dev/null || true
                        echo -e "${C_GREEN}✓ Правило для порта ${port}/tcp добавлено в UFW.${C_RESET}"
                    else
                        echo "Отменено."
                    fi
                fi
                pause_prompt
                ;;
            3)
                if ! command -v ufw >/dev/null 2>&1; then
                    echo "UFW не установлен."
                else
                    local conf_del="n"
                    read_choice "Удалить разрешающее правило для ${port}/tcp в UFW? [y/N]: " conf_del "n"
                    if [[ "$conf_del" =~ ^[YyДд]$ ]]; then
                        ufw delete allow "${port}/tcp" 2>/dev/null || true
                        echo -e "${C_GREEN}✓ Правило для порта ${port}/tcp удалено из UFW.${C_RESET}"
                    else
                        echo "Отменено."
                    fi
                fi
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
