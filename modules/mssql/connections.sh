#!/usr/bin/env bash
# modules/mssql/connections.sh — Управление подключениями и профилями

manage_connections_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
        echo -e "                 ${C_BOLD}${C_GREEN}🔌 УПРАВЛЕНИЕ ПОДКЛЮЧЕНИЯМИ SQL SERVER${C_RESET}"
        echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
        echo
        echo -e "  Активный целевой экземпляр: ${C_BOLD}${CURRENT_TYPE:-none}${C_RESET} (${CURRENT_HOST:-127.0.0.1}:${CURRENT_PORT:-1433})"
        echo -e "  Пользователь               : ${C_CYAN}${CURRENT_USER:-sa}${C_RESET}"
        echo -e "  Статус соединения          : ${CURRENT_STATUS:-N/A}"
        echo
        echo -e "  ${C_BGREEN}[1]${C_RESET} 📋 Список сохранённых профилей"
        echo -e "  ${C_BGREEN}[2]${C_RESET} ➕ Добавить новое подключение (Remote / Docker / Native)"
        echo -e "  ${C_BGREEN}[3]${C_RESET} 🔄 Выбрать активный профиль подключения"
        echo -e "  ${C_BGREEN}[4]${C_RESET} 🔍 Проверить текущее соединение (Test Connection)"
        echo -e "  ${C_BGREEN}[5]${C_RESET} 🔑 Изменить пароль / учётные данные текущего профиля"
        echo -e "  ${C_BRED}[6]${C_RESET} 🗑️  Удалить профиль подключения"
        echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад в главное меню"
        echo

        local c_choice="0"
        read_choice "${C_BOLD}Выберите действие [0-6]: ${C_RESET}" c_choice "0"
        echo

        case "$c_choice" in
            1)
                list_profiles
                pause_prompt
                ;;
            2)
                add_connection_profile
                pause_prompt
                ;;
            3)
                select_active_profile
                pause_prompt
                ;;
            4)
                echo ">>> Проверка подключения к ${CURRENT_HOST}:${CURRENT_PORT}..."
                test_current_instance
                echo -e "Результат: ${CURRENT_STATUS}"
                [[ -n "${CURRENT_VERSION:-}" && "$CURRENT_VERSION" != "N/A" ]] && echo -e "Версия: ${C_BCYAN}${CURRENT_VERSION}${C_RESET}"
                pause_prompt
                ;;
            5)
                echo -e "${C_BOLD}Обновление учетных данных для ${CURRENT_TYPE}:${C_RESET}"
                local new_u="" new_p=""
                read_choice "Логин [${CURRENT_USER:-sa}]: " new_u "${CURRENT_USER:-sa}"
                read_password_secret "Новый пароль: " new_p
                CURRENT_USER="$new_u"
                CURRENT_PASS="$new_p"
                save_active_profile
                echo -e "${C_GREEN}✓ Учетные данные обновлены.${C_RESET}"
                test_current_instance
                pause_prompt
                ;;
            6)
                delete_profile
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

list_profiles() {
    echo -e "${C_BOLD}${C_CYAN}Сохранённые профили подключений (${MSSQL_CONN_DIR}):${C_RESET}"
    echo
    local found=0
    for p in "${MSSQL_CONN_DIR}"/*.conf; do
        if [[ -f "$p" ]]; then
            local p_name p_type p_host p_port p_user
            p_name="$(basename "$p" .conf)"
            p_type="$(grep -E '^CURRENT_TYPE=' "$p" | awk -F'=' '{print $2}' | tr -d '"' || echo "N/A")"
            p_host="$(grep -E '^CURRENT_HOST=' "$p" | awk -F'=' '{print $2}' | tr -d '"' || echo "N/A")"
            p_port="$(grep -E '^CURRENT_PORT=' "$p" | awk -F'=' '{print $2}' | tr -d '"' || echo "1433")"
            p_user="$(grep -E '^CURRENT_USER=' "$p" | awk -F'=' '{print $2}' | tr -d '"' || echo "sa")"
            echo -e "  • ${C_BOLD}${p_name}${C_RESET} [Тип: ${p_type}, Сервер: ${p_host}:${p_port}, User: ${p_user}]"
            found=1
        fi
    done

    if [[ "$found" -eq 0 ]]; then
        echo -e "  ${C_GRAY}Сохранённых профилей пока нет.${C_RESET}"
    fi
}

add_connection_profile() {
    echo -e "${C_BOLD}Добавление нового профиля подключения:${C_RESET}"
    echo
    echo "  [1] Локальный Docker-контейнер"
    echo "  [2] Локальная служба (Native systemd)"
    echo "  [3] Удалённый сервер (Remote MSSQL Server по TCP)"
    echo
    local t_choice="3"
    read_choice "Выберите тип [1-3]: " t_choice "3"

    local p_name="" p_type="remote" p_host="127.0.0.1" p_port="1433" p_user="sa" p_pass="" p_cont=""

    case "$t_choice" in
        1)
            p_type="docker"
            read_choice "Имя контейнера [${MSSQL_DOCKER_CONTAINER:-mssql_server}]: " p_cont "${MSSQL_DOCKER_CONTAINER:-mssql_server}"
            read_choice "Порт хоста [${MSSQL_DOCKER_PORT:-1433}]: " p_port "${MSSQL_DOCKER_PORT:-1433}"
            ;;
        2)
            p_type="native"
            read_choice "Порт службы [1433]: " p_port "1433"
            ;;
        3)
            p_type="remote"
            read_choice "Адрес сервера (IP или домен): " p_host ""
            if [[ -z "$p_host" ]]; then
                echo "Адрес сервера обязателен. Отмена."
                return 1
            fi
            read_choice "Порт [1433]: " p_port "1433"
            ;;
    esac

    read_choice "Имя профиля: " p_name "sql_${p_type}"
    read_choice "Имя пользователя SQL [sa]: " p_user "sa"
    read_password_secret "Пароль: " p_pass

    local prof_file="${MSSQL_CONN_DIR}/${p_name}.conf"
    (
        umask 077
        cat > "$prof_file" <<EOF_P
CURRENT_TYPE="${p_type}"
CURRENT_HOST="${p_host}"
CURRENT_PORT="${p_port}"
CURRENT_USER="${p_user}"
CURRENT_PASS="${p_pass}"
CURRENT_CONTAINER="${p_cont}"
EOF_P
        chmod 600 "$prof_file"
    )

    echo -e "${C_GREEN}✓ Профиль '${p_name}' успешно сохранён (права 600).${C_RESET}"
    
    local set_act="y"
    read_choice "Сделать этот профиль активным прямо сейчас? [Y/n]: " set_act "y"
    if [[ "$set_act" =~ ^[YyДд]$ || -z "$set_act" ]]; then
        CURRENT_TYPE="$p_type"
        CURRENT_HOST="$p_host"
        CURRENT_PORT="$p_port"
        CURRENT_USER="$p_user"
        CURRENT_PASS="$p_pass"
        CURRENT_CONTAINER="$p_cont"
        save_active_profile
        test_current_instance
        echo -e "${C_GREEN}✓ Профиль активирован.${C_RESET}"
    fi
}

select_active_profile() {
    local profiles=()
    for p in "${MSSQL_CONN_DIR}"/*.conf; do
        [[ -f "$p" ]] && profiles+=("$p")
    done

    if [[ ${#profiles[@]} -eq 0 ]]; then
        echo -e "${C_YELLOW}Нет сохранённых профилей. Создайте профиль через пункт [2].${C_RESET}"
        return 0
    fi

    echo "Доступные профили:"
    local i=1
    for p in "${profiles[@]}"; do
        echo "  [$i] $(basename "$p" .conf)"
        ((i++))
    done
    echo "  [0] Отмена"
    echo

    local sel="0"
    read_choice "Выберите номер [1-${#profiles[@]}]: " sel "0"
    if [[ "$sel" =~ ^[0-9]+$ && "$sel" -ge 1 && "$sel" -le "${#profiles[@]}" ]]; then
        local chosen="${profiles[$((sel - 1))]}"
        source "$chosen"
        save_active_profile
        test_current_instance
        echo -e "${C_GREEN}✓ Активирован профиль: $(basename "$chosen" .conf)${C_RESET}"
    fi
}

delete_profile() {
    list_profiles
    echo
    local del_name=""
    read_choice "Введите имя профиля для удаления: " del_name ""
    if [[ -f "${MSSQL_CONN_DIR}/${del_name}.conf" ]]; then
        rm -f "${MSSQL_CONN_DIR}/${del_name}.conf"
        echo -e "${C_GREEN}✓ Профиль '${del_name}' удалён.${C_RESET}"
    else
        echo "Профиль не найден."
    fi
}

save_active_profile() {
    (
        umask 077
        cat > "${MSSQL_CONF_DIR}/active_profile.conf" <<EOF_ACT
CURRENT_TYPE="${CURRENT_TYPE:-none}"
CURRENT_HOST="${CURRENT_HOST:-127.0.0.1}"
CURRENT_PORT="${CURRENT_PORT:-1433}"
CURRENT_USER="${CURRENT_USER:-sa}"
CURRENT_PASS="${CURRENT_PASS:-}"
CURRENT_CONTAINER="${CURRENT_CONTAINER:-}"
EOF_ACT
        chmod 600 "${MSSQL_CONF_DIR}/active_profile.conf"
    )
}
