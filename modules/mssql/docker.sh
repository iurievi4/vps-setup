#!/usr/bin/env bash
# modules/mssql/docker.sh — Управление SQL Server в Docker

manage_docker_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
        echo -e "                   ${C_BOLD}${C_GREEN}🐳 УПРАВЛЕНИЕ SQL SERVER В DOCKER${C_RESET}"
        echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
        echo

        if ! command -v docker >/dev/null 2>&1; then
            echo -e "${C_RED}❌ Docker не установлен в системе.${C_RESET}"
            pause_prompt
            return 0
        fi

        local c_name="${CURRENT_CONTAINER:-${MSSQL_DOCKER_CONTAINER:-mssql_server}}"
        local c_exists=0 c_running=0
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$c_name"; then
            c_exists=1
            docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$c_name" && c_running=1
        fi

        local st_str="${C_RED}⏹️  Остановлен${C_RESET}"
        [[ "$c_running" -eq 1 ]] && st_str="${C_GREEN}● Запущен (Up)${C_RESET}"
        [[ "$c_exists" -eq 0 ]] && st_str="${C_YELLOW}○ Контейнер '${c_name}' не найден${C_RESET}"

        echo -e "  Целевой контейнер : ${C_BOLD}${c_name}${C_RESET}"
        echo -e "  Состояние         : ${st_str}"
        echo
        echo -e "  ${C_BGREEN}[1]${C_RESET} ▶️  Запустить контейнер (docker start)"
        echo -e "  ${C_BGREEN}[2]${C_RESET} ⏹️  Остановить контейнер (docker stop)"
        echo -e "  ${C_BGREEN}[3]${C_RESET} 🔄 Перезапустить контейнер (docker restart)"
        echo -e "  ${C_BGREEN}[4]${C_RESET} 📜 Просмотр логов контейнера (docker logs)"
        echo -e "  ${C_BGREEN}[5]${C_RESET} 📊 Подробные сведения (порты, тома, переменные)"
        echo -e "  ${C_BGREEN}[6]${C_RESET} 🔍 Проверить статус процесса sqlservr внутри контейнера"
        echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
        echo

        local d_act="0"
        read_choice "${C_BOLD}Выберите действие [0-6]: ${C_RESET}" d_act "0"
        echo

        case "$d_act" in
            1)
                echo ">>> Запуск контейнера ${c_name}..."
                docker start "$c_name" 2>/dev/null || true
                sleep 2
                test_current_instance
                pause_prompt
                ;;
            2)
                confirm_action 2 "Остановка SQL Server прервёт активные соединения клиентов (LERS и др.)" && {
                    echo ">>> Остановка контейнера ${c_name}..."
                    docker stop "$c_name" 2>/dev/null || true
                    test_current_instance
                }
                pause_prompt
                ;;
            3)
                confirm_action 2 "Перезапуск контейнера ${c_name}" && {
                    echo ">>> Перезапуск контейнера ${c_name}..."
                    docker restart "$c_name" 2>/dev/null || true
                    sleep 2
                    test_current_instance
                }
                pause_prompt
                ;;
            4)
                echo -e "${C_BOLD}Последние 50 строк журнала контейнера ${c_name}:${C_RESET}"
                echo
                docker logs --tail 50 "$c_name" 2>&1 || echo "Логи недоступны"
                pause_prompt
                ;;
            5)
                echo -e "${C_BOLD}${C_CYAN}=== Параметры контейнера ${c_name} ===${C_RESET}"
                echo "Образ: $(docker inspect --format '{{.Config.Image}}' "$c_name" 2>/dev/null || echo "N/A")"
                echo "Создан: $(docker inspect --format '{{.Created}}' "$c_name" 2>/dev/null || echo "N/A")"
                echo "Порты: $(docker port "$c_name" 2>/dev/null || echo "N/A")"
                echo
                echo -e "${C_BOLD}Подключённые тома (Mounts):${C_RESET}"
                docker inspect --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} ({{.Type}}){{println}}{{end}}' "$c_name" 2>/dev/null || echo "Нет данных"
                pause_prompt
                ;;
            6)
                echo -e "${C_BOLD}Процессы внутри контейнера:${C_RESET}"
                docker top "$c_name" 2>/dev/null || echo "Контейнер не запущен"
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
