#!/usr/bin/env bash
# modules/mssql/detect.sh — Обнаружение окружения и экземпляров SQL Server

detect_all_instances() {
    MSSQL_DOCKER_FOUND=0
    MSSQL_DOCKER_CONTAINER=""
    MSSQL_DOCKER_IMAGE=""
    MSSQL_DOCKER_STATUS=""
    MSSQL_DOCKER_PORT="1433"

    MSSQL_NATIVE_FOUND=0
    MSSQL_NATIVE_STATUS=""
    MSSQL_NATIVE_VERSION=""

    # 1. Проверка Docker
    if command -v docker >/dev/null 2>&1; then
        local c_info
        c_info="$(docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null | grep -iE 'mssql|sqlserver' | head -n 1 || true)"
        if [[ -n "$c_info" ]]; then
            MSSQL_DOCKER_FOUND=1
            MSSQL_DOCKER_CONTAINER="$(echo "$c_info" | awk '{print $1}')"
            MSSQL_DOCKER_IMAGE="$(echo "$c_info" | awk '{print $2}')"
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$MSSQL_DOCKER_CONTAINER"; then
                MSSQL_DOCKER_STATUS="running"
            else
                MSSQL_DOCKER_STATUS="stopped"
            fi

            local d_p
            d_p="$(docker port "$MSSQL_DOCKER_CONTAINER" 2>/dev/null | grep -oE ':[0-9]+' | head -n 1 | tr -d ':' || true)"
            if [[ -n "$d_p" ]]; then
                MSSQL_DOCKER_PORT="$d_p"
            fi
        fi
    fi

    # 2. Проверка нативной службы systemd
    if systemctl list-unit-files 2>/dev/null | grep -q '^mssql-server\.service' || [[ -d "/opt/mssql" ]]; then
        MSSQL_NATIVE_FOUND=1
        if systemctl is-active --quiet mssql-server 2>/dev/null; then
            MSSQL_NATIVE_STATUS="running"
        else
            MSSQL_NATIVE_STATUS="stopped"
        fi
    fi

    # 3. Инициализация текущего экземпляра по умолчанию
    if [[ -z "${CURRENT_TYPE:-}" ]]; then
        if [[ -f "${MSSQL_CONF_DIR}/active_profile.conf" ]]; then
            # Загрузка сохраненного активного профиля
            source "${MSSQL_CONF_DIR}/active_profile.conf" 2>/dev/null || true
        elif [[ "$MSSQL_DOCKER_FOUND" -eq 1 ]]; then
            CURRENT_TYPE="docker"
            CURRENT_CONTAINER="$MSSQL_DOCKER_CONTAINER"
            CURRENT_HOST="127.0.0.1"
            CURRENT_PORT="$MSSQL_DOCKER_PORT"
            CURRENT_USER="sa"
            # Пробуем считать MSSQL_SA_PASSWORD из окружения контейнера, если доступен
            if [[ -z "${CURRENT_PASS:-}" ]] && command -v docker >/dev/null 2>&1; then
                CURRENT_PASS="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$MSSQL_DOCKER_CONTAINER" 2>/dev/null | awk -F'MSSQL_SA_PASSWORD=' '/MSSQL_SA_PASSWORD=/{print $2}' | head -n 1 || true)"
            fi
        elif [[ "$MSSQL_NATIVE_FOUND" -eq 1 ]]; then
            CURRENT_TYPE="native"
            CURRENT_HOST="127.0.0.1"
            CURRENT_PORT="1433"
            CURRENT_USER="sa"
            CURRENT_CONTAINER=""
        else
            CURRENT_TYPE="none"
            CURRENT_HOST="127.0.0.1"
            CURRENT_PORT="1433"
            CURRENT_USER="sa"
            CURRENT_CONTAINER=""
        fi
    fi

    # 4. Проверка доступности текущего экземпляра
    test_current_instance
}

test_current_instance() {
    CURRENT_STATUS="${C_GRAY}Не проверен${C_RESET}"
    CURRENT_VERSION="N/A"

    if [[ "${CURRENT_TYPE:-none}" == "none" ]]; then
        CURRENT_STATUS="${C_YELLOW}Не настроен${C_RESET}"
        return 0
    fi

    if [[ "$CURRENT_TYPE" == "docker" ]]; then
        if [[ "$MSSQL_DOCKER_STATUS" != "running" ]]; then
            CURRENT_STATUS="${C_RED}Контейнер остановлен${C_RESET}"
            return 0
        fi
    elif [[ "$CURRENT_TYPE" == "native" ]]; then
        if [[ "$MSSQL_NATIVE_STATUS" != "running" ]]; then
            CURRENT_STATUS="${C_RED}Служба остановлена${C_RESET}"
            return 0
        fi
    fi

    # Выполняем тестовый запрос @@VERSION
    local ver_query="SET NOCOUNT ON; SELECT @@VERSION;"
    local q_res
    if q_res="$(run_sql_query "$ver_query" "master" 2>/dev/null)"; then
        if echo "$q_res" | grep -qi 'Microsoft SQL Server'; then
            CURRENT_STATUS="${C_GREEN}● Доступен (OK)${C_RESET}"
            CURRENT_VERSION="$(echo "$q_res" | grep -i 'Microsoft SQL Server' | head -n 1 | awk '{print $1" "$2" "$3" "$4}' | tr -d '\r')"
        else
            CURRENT_STATUS="${C_GREEN}● Порт открыт${C_RESET} ${C_GRAY}(требуется авторизация)${C_RESET}"
        fi
    else
        CURRENT_STATUS="${C_RED}❌ Ошибка подключения / авторизации${C_RESET}"
    fi
}
