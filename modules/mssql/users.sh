#!/usr/bin/env bash
# modules/mssql/users.sh — Управление пользователями, логинами и правами

manage_users_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
        echo -e "               ${C_BOLD}${C_GREEN}👤 ПОЛЬЗОВАТЕЛИ, ЛОГИНЫ И ПРАВА ДОСТУПА${C_RESET}"
        echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
        echo
        echo -e "  Целевой сервер: ${C_BOLD}${CURRENT_HOST:-127.0.0.1}:${CURRENT_PORT:-1433}${C_RESET}"
        echo
        echo -e "  ${C_BGREEN}[1]${C_RESET} 📋 Список всех серверных логинов (Server Logins & Roles)"
        echo -e "  ${C_BGREEN}[2]${C_RESET} 👥 Пользователи конкретной базы данных"
        echo -e "  ${C_BGREEN}[3]${C_RESET} ➕ Создать новый SQL-логин"
        echo -e "  ${C_BGREEN}[4]${C_RESET} 🔑 Сменить пароль логина"
        echo -e "  ${C_BGREEN}[5]${C_RESET} 🛡️  Аудит привилегированных ролей (sysadmin и др.)"
        echo -e "  ${C_RED}[0]${C_RESET} ◀️  Назад"
        echo

        local u_act="0"
        read_choice "${C_BOLD}Выберите действие [0-5]: ${C_RESET}" u_act "0"
        echo

        case "$u_act" in
            1)
                list_server_logins
                pause_prompt
                ;;
            2)
                list_db_users
                pause_prompt
                ;;
            3)
                create_login_action
                pause_prompt
                ;;
            4)
                change_login_password_action
                pause_prompt
                ;;
            5)
                audit_privileged_roles
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

list_server_logins() {
    echo -e "${C_BOLD}${C_CYAN}Серверные логины (SQL Server Logins):${C_RESET}"
    echo
    local q="SET NOCOUNT ON;
    SELECT 
        sp.name AS [LoginName],
        sp.type_desc AS [Type],
        sp.is_disabled AS [Disabled],
        sp.default_database_name AS [DefaultDB],
        ISNULL(STUFF((SELECT ', ' + r.name FROM sys.server_role_members rm JOIN sys.server_principals r ON rm.role_principal_id = r.principal_id WHERE rm.member_principal_id = sp.principal_id FOR XML PATH('')), 1, 2, ''), '') AS [ServerRoles]
    FROM sys.server_principals sp
    WHERE sp.type IN ('S', 'U', 'G') AND sp.name NOT LIKE '##%'
    ORDER BY sp.name;"

    local out
    out="$(run_sql_query "$q" "master")"
    echo "$out"
}

list_db_users() {
    local target_db=""
    read_choice "Введите имя базы данных: " target_db "master"
    echo
    local q="SET NOCOUNT ON;
    SELECT 
        dp.name AS [UserName],
        dp.type_desc AS [Type],
        sp.name AS [MappedLogin],
        dp.default_schema_name AS [DefaultSchema]
    FROM sys.database_principals dp
    LEFT JOIN sys.server_principals sp ON dp.sid = sp.sid
    WHERE dp.type IN ('S', 'U', 'G') AND dp.name NOT IN ('guest', 'INFORMATION_SCHEMA', 'sys')
    ORDER BY dp.name;"

    local out
    out="$(run_sql_query "$q" "$target_db")"
    echo "$out"
}

create_login_action() {
    local new_login="" new_pass="" def_db=""
    read_choice "Имя нового SQL логина: " new_login ""
    if [[ -z "$new_login" ]] || ! [[ "$new_login" =~ ^[a-zA-Z0-9_]+$ ]]; then
        echo -e "${C_RED}❌ Некорректное имя логина.${C_RESET}"
        return 1
    fi

    read_password_secret "Пароль: " new_pass
    if [[ -z "$new_pass" ]]; then
        echo -e "${C_RED}❌ Пароль не может быть пустым.${C_RESET}"
        return 1
    fi

    read_choice "База данных по умолчанию [master]: " def_db "master"

    echo ">>> Создание логина [${new_login}]..."
    local q="CREATE LOGIN [${new_login}] WITH PASSWORD = '${new_pass}', DEFAULT_DATABASE = [${def_db}], CHECK_POLICY = ON;"
    local out
    if out="$(run_sql_query "$q" "master")"; then
        echo -e "${C_GREEN}✓ Логин [${new_login}] успешно создан.${C_RESET}"
    else
        echo -e "${C_RED}❌ Ошибка создания логина:${C_RESET}"
        echo "$out"
    fi
}

change_login_password_action() {
    list_server_logins
    echo
    local target_login="" target_pass=""
    read_choice "Введите логин для смены пароля: " target_login ""
    if [[ -z "$target_login" ]]; then
        echo "Отмена."
        return 1
    fi

    read_password_secret "Введите новый пароль: " target_pass
    if [[ -z "$target_pass" ]]; then
        echo -e "${C_RED}❌ Пароль не может быть пустым.${C_RESET}"
        return 1
    fi

    echo ">>> Смена пароля для [${target_login}]..."
    local q="ALTER LOGIN [${target_login}] WITH PASSWORD = '${target_pass}';"
    local out
    if out="$(run_sql_query "$q" "master")"; then
        echo -e "${C_GREEN}✓ Пароль для логина [${target_login}] успешно изменён.${C_RESET}"
    else
        echo -e "${C_RED}❌ Ошибка изменения пароля:${C_RESET}"
        echo "$out"
    fi
}

audit_privileged_roles() {
    echo -e "${C_BOLD}${C_CYAN}Аудит участников роли sysadmin:${C_RESET}"
    echo
    local q="SET NOCOUNT ON;
    SELECT 
        m.name AS [SysadminMember],
        m.type_desc AS [Type],
        m.is_disabled AS [Disabled]
    FROM sys.server_role_members rm
    JOIN sys.server_principals r ON rm.role_principal_id = r.principal_id
    JOIN sys.server_principals m ON rm.member_principal_id = m.principal_id
    WHERE r.name = 'sysadmin'
    ORDER BY m.name;"

    local out
    out="$(run_sql_query "$q" "master")"
    echo "$out"
}
