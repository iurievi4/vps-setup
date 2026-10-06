#!/usr/bin/env bash
# ==============================================================================
# NaïveProxy Manager — Модуль обслуживания и диагностики (maintenance.sh)
# ==============================================================================

restart_all() {
    info "Перезапуск всех служб комплекса NaïveProxy..."
    if systemctl is-active --quiet nginx 2>/dev/null; then
        systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
        success "Nginx перезапущен."
    fi
    if systemctl is-active --quiet caddy 2>/dev/null; then
        systemctl restart caddy 2>/dev/null || true
        success "Caddy перезапущен."
    fi
    if systemctl is-active --quiet naiveproxy-webui 2>/dev/null; then
        systemctl restart naiveproxy-webui 2>/dev/null || true
        success "Web UI перезапущен."
    fi
    show_status
}

restart_caddy() {
    info "Перезапуск caddy.service..."
    systemctl restart caddy
    caddy_status
}

restart_nginx() {
    info "Перезапуск nginx.service..."
    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null
    if systemctl is-active --quiet nginx 2>/dev/null; then
        success "Nginx активен."
    else
        error "Nginx не активен."
    fi
}

check_services() {
    echo -e "${BOLD}${CYAN}СТАТУС СИСТЕМНЫХ СЛУЖБ:${NC}"
    for s in nginx caddy naiveproxy-webui; do
        if systemctl is-active --quiet "$s" 2>/dev/null; then
            echo -e "  • $s: ${GREEN}RUNNING${NC}"
        else
            echo -e "  • $s: ${RED}STOPPED / INACTIVE${NC}"
        fi
    done
}

check_ports() {
    echo -e "${BOLD}${CYAN}ЗАНЯТОСТЬ ПОРТОВ:${NC}"
    for p in 80 443 "${WEB_PORT:-18080}"; do
        local owner
        owner=$(get_port_owner "$p")
        if [ -n "$owner" ]; then
            echo -e "  • Порт $p: ${GREEN}Занят $owner${NC}"
        else
            echo -e "  • Порт $p: ${YELLOW}Свободен${NC}"
        fi
    done
}

backup_config() {
    local bdir="/var/backups/naiveproxy"
    mkdir -p "$bdir"
    local bfile="$bdir/naiveproxy-backup-$(date +%Y%m%d_%H%M%S).tar.gz"
    info "Создание резервной копии конфигураций в $bfile..."
    tar -czf "$bfile" -C / etc/naiveproxy etc/caddy 2>/dev/null || true
    if [ -f "$bfile" ]; then
        chmod 600 "$bfile"
        success "Резервная копия создана: $bfile"
    else
        error "Не удалось создать резервную копию."
        return 1
    fi
}

restore_config() {
    local bdir="/var/backups/naiveproxy"
    if [ ! -d "$bdir" ]; then
        error "Каталог резервных копий $bdir не найден."
        return 1
    fi
    local backups=($(ls -t "$bdir"/*.tar.gz 2>/dev/null || true))
    if [ "${#backups[@]}" -eq 0 ]; then
        error "В $bdir нет резервных копий."
        return 1
    fi
    echo -e "${BOLD}Доступные резервные копии:${NC}"
    for i in "${!backups[@]}"; do
        echo "  $((i+1))) ${backups[$i]}"
    done
    read -r -p "Выберите номер архива для восстановления: " bnum
    if [[ "$bnum" =~ ^[0-9]+$ ]] && [ "$bnum" -ge 1 ] && [ "$bnum" -le "${#backups[@]}" ]; then
        local target_bak="${backups[$((bnum-1))]}"
        info "Восстановление из $target_bak..."
        tar -xzf "$target_bak" -C /
        success "Конфигурация восстановлена. Рекомендуется перезапустить службы: restart_all"
    else
        error "Неверный выбор."
        return 1
    fi
}

setup_motd() {
    # Если на сервере уже активен кастомный sysinfo (например, 99-custom-sysinfo),
    # удаляем отдельный 98-naiveproxy, чтобы не нарушать вывод рамки
    if [ -f "/etc/update-motd.d/99-custom-sysinfo" ]; then
        rm -f "$MOTD_FILE" 2>/dev/null || true
        return 0
    fi

    if [ -d "/etc/update-motd.d" ]; then
        cat << 'EOF' > "$MOTD_FILE"
#!/bin/sh
if systemctl is-active --quiet caddy 2>/dev/null && [ -f /etc/naiveproxy/credentials ]; then
    dom=$(grep -E '^DOMAIN=' /etc/naiveproxy/credentials 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
    printf " NaïveProxy : \033[1;32mRUNNING\033[0m (port 443, %s)\n" "$dom"
elif [ -f /etc/naiveproxy/credentials ]; then
    printf " NaïveProxy : \033[1;31mSTOPPED\033[0m\n"
fi
if systemctl is-active --quiet nginx 2>/dev/null; then
    printf " Nginx Stub : \033[1;32mRUNNING\033[0m (port 80)\n"
fi
EOF
        chmod +x "$MOTD_FILE" 2>/dev/null || true
    fi
}

remove_motd() {
    rm -f "$MOTD_FILE" 2>/dev/null || true
}


show_info() {
    if ! load_credentials; then
        error "Файл учетных данных $CREDS_FILE не найден."
        return 1
    fi

    step "7/7" "Результаты установки"
    echo ""

    local tls_out tls_stat tls_iss tls_host tls_left tls_exp
    tls_out=$(verify_tls_certificate "$DOMAIN")
    IFS='|' read -r tls_stat tls_iss tls_host tls_left tls_exp <<< "$tls_out"

    if [ "$tls_stat" = "VALID" ]; then
        echo -e "${GREEN}==========================================================${NC}"
        echo -e "${BOLD}${GREEN}        NAÏVEPROXY И CADDY УСПЕШНО РАЗВЕРНУТЫ            ${NC}"
        echo -e "${GREEN}==========================================================${NC}"
    else
        echo -e "${YELLOW}==========================================================${NC}"
        echo -e "${BOLD}${YELLOW}   УСТАНОВКА ЗАВЕРШЕНА С ПРЕДУПРЕЖДЕНИЕМ (TLS PENDING)   ${NC}"
        echo -e "${YELLOW}==========================================================${NC}"
    fi
    echo -e "  Caddy (443) :      ${GREEN}RUNNING (:443)${NC}"
    echo -e "  Nginx (80)  :      ${GREEN}RUNNING (:80)${NC}"

    if [ "$tls_stat" = "VALID" ]; then
        echo -e "  TLS сертификат  :  ${GREEN}VALID ($tls_iss, осталось $tls_left дн.)${NC}"
    else
        echo -e "  TLS сертификат  :  ${YELLOW}PENDING (выпуск ACME TLS-ALPN-01)${NC}"
    fi

    if [ "$PROXY_TUNNEL_STATUS" = "VERIFIED" ]; then
        echo -e "  CONNECT туннель :  ${GREEN}CONNECT: LOCAL VERIFIED${NC}"
    else
        echo -e "  CONNECT туннель :  ${YELLOW}NOT VERIFIED / TEST FAILED (проверьте с клиента)${NC}"
    fi
    echo -e "${GREEN}==========================================================${NC}"

    echo ""
    echo -e "${YELLOW}──────────────────────────────────────────────────────────${NC}"
    echo -e "${BOLD}${YELLOW}ВНИМАНИЕ:${NC} Конфиденциальные данные. Закройте экран от посторонних."
    echo -e "${YELLOW}──────────────────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Сервер:${NC}       $DOMAIN"
    echo -e "  ${BOLD}Порт:${NC}         $PORT"
    echo -e "  ${BOLD}Логин:${NC}        $USERNAME"
    echo -e "  ${BOLD}Пароль:${NC}       $PASSWORD"
    echo ""
    echo -e "${CYAN}----------------------------------------------------------${NC}"
    echo -e "${BOLD}Строка подключения (URL format):${NC}"
    echo -e "${YELLOW}https://${USERNAME}:${PASSWORD}@${DOMAIN}:${PORT}${NC}"
    echo -e "${BOLD}NekoBox / Sing-box URL:${NC}"
    echo -e "${YELLOW}naive+https://${USERNAME}:${PASSWORD}@${DOMAIN}:${PORT}#Naive-${USERNAME}${NC}"
    if command -v qrencode &>/dev/null; then
        echo -e "\n${CYAN}QR-код для импорта в NekoBox / Matsuri / v2rayN:${NC}"
        qrencode -t ANSIUTF8 "naive+https://${USERNAME}:${PASSWORD}@${DOMAIN}:${PORT}#Naive-${USERNAME}"
    fi
    echo ""
    echo -e "${CYAN}----------------------------------------------------------${NC}"
    echo -e "${BOLD}Конфигурация NaïveProxy (client.json):${NC}"
    echo -e "${CYAN}${BOLD}$(cat "$CLIENT_CONFIG" 2>/dev/null || true)${NC}"
    echo ""
    echo -e "${CYAN}----------------------------------------------------------${NC}"
    echo -e "${BOLD}${GREEN}ВЕБ-ПАНЕЛЬ УПРАВЛЕНИЯ (WEB UI MANAGER):${NC}"
    if [ -f "$WEB_CREDS_FILE" ] && [ -n "$(grep -E '^WEB_PASS=' "$WEB_CREDS_FILE" 2>/dev/null)" ]; then
        local web_user web_pass web_port="18080"
        web_user=$(grep -E '^WEB_USER=' "$WEB_CREDS_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
        web_pass=$(grep -E '^WEB_PASS=' "$WEB_CREDS_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
        local sp
        sp=$(grep -E '^WEB_PORT=' "$WEB_CREDS_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
        [ -n "$sp" ] && web_port="$sp"

        echo -e "  Статус:       ${GREEN}АКТИВНА (:443 -> :${web_port})${NC}"
        echo -e "  HTTPS URL:    ${BOLD}${CYAN}https://${DOMAIN}/admin/${NC}"
        echo -e "  Доступ:       ${GREEN}Локально (127.0.0.1:${web_port}), закрыт снаружи для безопасности${NC}"
        echo -e "  Логин:        ${BOLD}$web_user${NC}"
        echo -e "  Пароль:       ${BOLD}${YELLOW}$web_pass${NC}"
    else
        echo -e "  Статус:       ${YELLOW}НЕ УСТАНОВЛЕНА${NC}"
        echo -e "  Установка:    ${BOLD}${CYAN}bash install.sh web-install${NC}"
    fi
    echo -e "${CYAN}----------------------------------------------------------${NC}"
    echo -e "${BOLD}Клиентские приложения:${NC}"
    echo -e "  • NaïveProxy core: ./naive client.json"
    echo -e "  • NekoBox / NekoRay: Добавить -> Naive -> Хост: $DOMAIN, Порт: $PORT"
    echo -e "  • Sing-box / v2rayN: Протокол naive / http proxy с TLS"
    echo -e "${GREEN}==========================================================${NC}\n"
    return 0
}


run_installation() {
    local target_arg="${1:-}"
    local preset_mode="${2:-}"

    if [ "$target_arg" = "keep" ] || [ "$target_arg" = "random" ]; then
        preset_mode="$target_arg"
        target_arg=""
    fi

    # Прямая передача домена через аргумент CLI (например: bash install.sh install mydomain.com)
    if [ -n "$target_arg" ]; then
        target_arg=$(echo "$target_arg" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        local chk
        chk=$(validate_domain_format "$target_arg" || true)
        if [ "$chk" = "VALID" ]; then
            CHECKED_DOMAIN="$target_arg"
            CHECKED_STATUS="READY"
            mkdir -p "$NAIVE_DIR"
            cat << EOF > "$DOMAIN_CHECK_FILE"
DOMAIN="$CHECKED_DOMAIN"
SERVER_IPV4="$SERVER_IPV4"
DNS_IPV4="CLI_OVERRIDE"
DNS_STATUS="CONFIRMED_BY_USER"
CAA_STATUS="ALLOWED"
CHECK_TIMESTAMP="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
CHECK_TIMESTAMP_EPOCH="$(date +%s)"
DOMAIN_STATUS="READY"
EOF
            chmod 600 "$DOMAIN_CHECK_FILE"
            info "Домен '$CHECKED_DOMAIN' принят из аргумента командной строки."
        fi
    fi

    print_header
    echo -e "${BOLD}ЭТАП 2: УСТАНОВКА NAÏVEPROXY + CADDY (С ЗАГЛУШКОЙ NGINX НА :80)${NC}\n"

    if ! is_domain_ready; then
        local def_dom=""
        load_domain_check 2>/dev/null && def_dom="${CHECKED_DOMAIN:-}"

        if [ -n "$def_dom" ]; then
            read -r -p "Введите домен для установки [по умолчанию: $def_dom]: " input_dom
            input_dom="${input_dom:-$def_dom}"
        else
            read -r -p "Введите домен для установки (например, vpnfotmyvps.duckdns.org): " input_dom
        fi
        input_dom=$(echo "$input_dom" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

        if [ -z "$input_dom" ]; then
            error "Домен не указан. Установка отменена."
            return 1
        fi

        run_domain_diagnostics "$input_dom"
        if ! is_domain_ready; then
            error "Домен не подтверждён. Установка прервана."
            return 1
        fi
    fi

    load_domain_check || true
    resolve_server_ips

    info "Подтверждённый домен: ${BOLD}$CHECKED_DOMAIN${NC} ($CHECKED_TIMESTAMP)"

    if [ -n "$CHECKED_SERVER_IPV4" ] && [ -n "$SERVER_IPV4" ] && [ "$SERVER_IPV4" != "$CHECKED_SERVER_IPV4" ]; then
        warn "IP сервера отличается от зафиксированного при проверке ($CHECKED_SERVER_IPV4 -> $SERVER_IPV4)."
        read -r -p "Продолжить установку с текущим IP ($SERVER_IPV4)? [y/N]: " ip_cont
        case "$ip_cont" in
            y|Y) info "Продолжаем установку..." ;;
            *)
                error "Запустите повторную проверку: $0 domain"
                return 1
                ;;
        esac
    fi

    # 1. Проверка порта 80 ДО установки Nginx
    check_port80_conflict

    # 2. Неразрушающее обеспечение работы Nginx на порту 80
    ensure_nginx_stub

    # 3. Проверка порта 443 для Caddy
    check_port443_conflict

    # 4. Реквизиты
    step "Параметры учетной записи NaïveProxy"
    local EMAIL="" USERNAME="" PASSWORD=""

    if [ "$preset_mode" = "keep" ]; then
        if ! load_credentials; then
            error "Не удалось прочитать существующие реквизиты."
            return 1
        fi
        info "Используются сохраненные параметры: пользователь '$USERNAME', email '$EMAIL'"
    elif [ "$preset_mode" = "random" ]; then
        EMAIL="admin@${CHECKED_DOMAIN}"
        USERNAME="user_$(generate_random_string 8)"
        PASSWORD=$(generate_random_string 16)
        info "Сгенерированы случайные реквизиты: пользователь '$USERNAME'"
    else
        local def_email="admin@${CHECKED_DOMAIN}"
        while true; do
            read -r -p "Введите email для SSL сертификата [по умолчанию: $def_email]: " EMAIL
            EMAIL="${EMAIL:-$def_email}"
            EMAIL=$(echo "$EMAIL" | tr -d '[:space:]')
            if validate_email "$EMAIL"; then
                break
            else
                error "Некорректный email. Пример: admin@example.com"
            fi
        done

        local auto_user="user_$(generate_random_string 8)"
        while true; do
            read -r -p "Введите имя пользователя (логин) [по умолчанию: $auto_user]: " USERNAME
            USERNAME="${USERNAME:-$auto_user}"
            USERNAME=$(echo "$USERNAME" | tr -d '[:space:]')
            [[ "$USERNAME" =~ ^[A-Za-z0-9_-]+$ ]] && break
            error "Только латинские буквы, цифры, дефис и подчёркивание."
        done

        local auto_pass
        auto_pass=$(generate_random_string 16)
        while true; do
            read -r -p "Введите пароль [по умолчанию: $auto_pass]: " PASSWORD
            PASSWORD="${PASSWORD:-$auto_pass}"
            PASSWORD=$(echo "$PASSWORD" | tr -d '[:space:]')
            [[ "$PASSWORD" =~ ^[A-Za-z0-9._-]+$ ]] && break
            error "Только латинские буквы, цифры, точка, дефис и подчёркивание."
        done
    fi

    if [ -x "$CADDY_BIN" ] && "$CADDY_BIN" list-modules 2>/dev/null | grep -q 'http.handlers.forward_proxy'; then
        if [ "$preset_mode" = "keep" ]; then
            info "Обнаружен проверенный рабочий бинарник Caddy. Пропускаем пересборку."
        else
            echo ""
            read -r -p "Бинарник Caddy с forwardproxy уже собран. Использовать его без перекомпиляции? [Y/n]: " use_exist_caddy
            use_exist_caddy="${use_exist_caddy:-y}"
            case "$use_exist_caddy" in
                y|Y) info "Используется существующий бинарник Caddy." ;;
                *)
                    if ! build_caddy; then
                        error "Ошибка сборки Caddy. Установка прервана."
                        return 1
                    fi
                    ;;
            esac
        fi
    else
        if ! build_caddy; then
            error "Ошибка сборки Caddy. Установка прервана."
            return 1
        fi
    fi

    if ! configure_system "$CHECKED_DOMAIN" "$EMAIL" "$USERNAME" "$PASSWORD"; then
        error "Ошибка конфигурации Caddyfile. Установка прервана."
        rollback_caddy
        return 1
    fi

    if ! start_and_verify "$CHECKED_DOMAIN" "$USERNAME" "$PASSWORD"; then
        error "Критическая ошибка запуска или валидации NaïveProxy!"
        rollback_caddy
        return 1
    fi

    commit_caddy
    setup_motd
    install_web_ui
    echo ""
    read -r -p "Установка завершена! Нажмите Enter для просмотра реквизитов подключения..." _
    show_info
    echo ""
    read -r -p "Нажмите Enter для перехода в меню управления..." _
}


show_status() {
    print_header
    load_credentials 2>/dev/null || true

    echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}       NAÏVEPROXY + CADDY — ДИАГНОСТИКА СИСТЕМЫ         ${NC}"
    echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════${NC}\n"

    local cur_dom="${DOMAIN:-не настроен}"
    echo -e "${BOLD}Domain             :${NC} $cur_dom"

    # DNS проверки
    if [ "$cur_dom" != "не настроен" ]; then
        local dns_ip_cf
        dns_ip_cf=$(dig +short A "$cur_dom" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)
        [ "$dns_ip_cf" = "$SERVER_IPV4" ] && echo -e "${BOLD}DNS A              :${NC} ${GREEN}OK${NC}" || echo -e "${BOLD}DNS A              :${NC} ${RED}MISMATCH (${dns_ip_cf:-none} != $SERVER_IPV4)${NC}"

        local aaaa_recs=()
        while IFS= read -r arec; do
            [ -n "$arec" ] && aaaa_recs+=("$arec")
        done < <(dig +short AAAA "$cur_dom" @1.1.1.1 2>/dev/null | grep -E ':' || true)

        if [ "${#aaaa_recs[@]}" -eq 0 ]; then
            echo -e "${BOLD}DNS AAAA           :${NC} ${GREEN}OK / ABSENT${NC}"
        elif [ -n "$SERVER_IPV6_OUTBOUND" ] && [[ "${aaaa_recs[*]}" == *"$SERVER_IPV6_OUTBOUND"* ]]; then
            echo -e "${BOLD}DNS AAAA           :${NC} ${GREEN}OK (совпадает с VPS: ${SERVER_IPV6_OUTBOUND})${NC}"
        else
            echo -e "${BOLD}DNS AAAA           :${NC} ${YELLOW}ВНИМАНИЕ (${aaaa_recs[*]})${NC}"
        fi

        local caa_stat
        caa_stat=$(check_caa_record "$cur_dom")
        [ "$caa_stat" = "RESTRICTED" ] && echo -e "${BOLD}DNS CAA            :${NC} ${RED}RESTRICTED${NC}" || echo -e "${BOLD}DNS CAA            :${NC} ${GREEN}OK ($caa_stat)${NC}"

        echo -e "${BOLD}Server IPv4        :${NC} $SERVER_IPV4"
        echo -e "${BOLD}DNS IPv4           :${NC} ${dns_ip_cf:-не определен}"
    fi

    echo ""
    # Службы через get_port_owner
    local p80_owner p443_owner
    p80_owner=$(get_port_owner 80)
    p443_owner=$(get_port_owner 443)

    if systemctl is-active --quiet nginx 2>/dev/null && [ -n "$p80_owner" ]; then
        echo -e "${BOLD}Nginx :80          :${NC} ${GREEN}RUNNING (PID ${p80_owner##* })${NC}"
    elif systemctl is-active --quiet nginx 2>/dev/null; then
        echo -e "${BOLD}Nginx :80          :${NC} ${YELLOW}RUNNING (порт :80 не привязан)${NC}"
    else
        echo -e "${BOLD}Nginx :80          :${NC} ${RED}STOPPED / FAILED${NC}"
    fi

    if systemctl is-active --quiet caddy 2>/dev/null && [[ "${p443_owner%% *}" == "caddy" ]]; then
        echo -e "${BOLD}Caddy :443         :${NC} ${GREEN}RUNNING (PID ${p443_owner##* })${NC}"
    elif systemctl is-active --quiet caddy 2>/dev/null; then
        echo -e "${BOLD}Caddy :443         :${NC} ${YELLOW}RUNNING (порт :443 не привязан к Caddy)${NC}"
    else
        echo -e "${BOLD}Caddy :443         :${NC} ${RED}STOPPED / FAILED${NC}"
    fi

    if systemctl is-active --quiet naiveproxy-webui 2>/dev/null || systemctl is-active --quiet naiveproxy-web 2>/dev/null; then
        echo -e "${BOLD}Web Manager        :${NC} ${GREEN}RUNNING (127.0.0.1:18080 -> /admin/)${NC}"
    else
        echo -e "${BOLD}Web Manager        :${NC} ${YELLOW}STOPPED / NOT INSTALLED${NC}"
    fi

    # Конфигурация и модули
    local cfile_stat="NOT FOUND"
    if [ -f "$CADDY_FILE" ] && [ -x "$CADDY_BIN" ]; then
        "$CADDY_BIN" validate --config "$CADDY_FILE" >/dev/null 2>&1 && cfile_stat="VALID" || cfile_stat="INVALID"
    fi
    [ "$cfile_stat" = "VALID" ] && echo -e "${BOLD}Caddyfile          :${NC} ${GREEN}VALID${NC}" || echo -e "${BOLD}Caddyfile          :${NC} ${RED}$cfile_stat${NC}"

    local fp_stat="NOT FOUND"
    if [ -x "$CADDY_BIN" ] && "$CADDY_BIN" list-modules 2>/dev/null | grep -q 'http.handlers.forward_proxy'; then
        fp_stat="OK"
    fi
    [ "$fp_stat" = "OK" ] && echo -e "${BOLD}forward_proxy      :${NC} ${GREEN}OK${NC}" || echo -e "${BOLD}forward_proxy      :${NC} ${RED}NOT FOUND${NC}"

    # TLS статус через verify_tls_certificate
    local tls_out tls_stat tls_iss tls_host tls_left tls_exp
    if [ "$cur_dom" != "не настроен" ]; then
        tls_out=$(verify_tls_certificate "$cur_dom")
        IFS='|' read -r tls_stat tls_iss tls_host tls_left tls_exp <<< "$tls_out"
    else
        tls_stat="NOT DETECTED" tls_iss="none" tls_host="UNKNOWN" tls_left=0 tls_exp="UNKNOWN"
    fi

    [ "$tls_stat" = "VALID" ] && echo -e "${BOLD}TLS certificate    :${NC} ${GREEN}VALID${NC}" || echo -e "${BOLD}TLS certificate    :${NC} ${YELLOW}$tls_stat${NC}"
    echo -e "${BOLD}TLS issuer         :${NC} $tls_iss"
    [ "$tls_host" != "UNKNOWN" ] && echo -e "${BOLD}TLS hostname       :${NC} $([ "$tls_host" = "MATCH" ] && echo -e "${GREEN}MATCH ($cur_dom)${NC}" || echo -e "${RED}MISMATCH${NC}")"
    [ "$tls_exp" != "UNKNOWN" ] && echo -e "${BOLD}TLS expiry         :${NC} ${tls_left} дн. (до $tls_exp)"

    # Probe resistance (проверяется после TLS)
    local probe_stat="NOT DETECTED"
    if [ "$cur_dom" != "не настроен" ]; then
        local probe_code
        probe_code=$(curl -sk -m 3 --resolve "${cur_dom}:443:127.0.0.1" -o /tmp/probe_test.html -w '%{http_code}' "https://${cur_dom}" 2>/dev/null || true)
        if [ "$probe_code" = "200" ] && grep -q "Service Online" /tmp/probe_test.html 2>/dev/null; then
            probe_stat="OK"
        fi
        rm -f /tmp/probe_test.html
    fi
    [ "$probe_stat" = "OK" ] && echo -e "${BOLD}probe_resistance   :${NC} ${GREEN}OK (код 200, Service Online)${NC}" || echo -e "${BOLD}probe_resistance   :${NC} ${YELLOW}$probe_stat${NC}"

    # CONNECT tunnel (локальный end-to-end тест)
    local conn_stat="NOT VERIFIED / TEST FAILED"
    if [ -n "$USERNAME" ] && [ -n "$PASSWORD" ] && [ "$cur_dom" != "не настроен" ]; then
        local tcode
        tcode=$(curl -s -m 5 -x "https://${USERNAME}:${PASSWORD}@${cur_dom}:443"             --resolve "${cur_dom}:443:127.0.0.1" -k             -o /dev/null -w "%{http_code}" "http://connectivitycheck.gstatic.com/generate_204" 2>/dev/null || true)
        if [[ "$tcode" =~ ^(204|200)$ ]]; then
            conn_stat="VERIFIED (local)"
        fi
    fi
    [ "$conn_stat" = "VERIFIED (local)" ] && echo -e "${BOLD}NaïveProxy CONNECT :${NC} ${GREEN}VERIFIED (local)${NC}" || echo -e "${BOLD}NaïveProxy CONNECT :${NC} ${YELLOW}$conn_stat${NC}"
    echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════${NC}\n"
}


update_caddy() {
    print_header
    info "Безопасное обновление Caddy и forwardproxy@naive..."
    if ! is_naiveproxy_installed; then
        error "NaïveProxy еще не установлен. Сначала выполните установку."
        return 1
    fi
    load_credentials || true

    # Сборка нового бинарника
    if ! build_caddy; then
        error "Сбой сборки Caddy. Предыдущая версия осталась активной."
        return 1
    fi

    info "Перезапуск caddy.service..."
    systemctl restart caddy
    sleep 3

    # Полная транзакционная верификация
    if start_and_verify "$DOMAIN" "$USERNAME" "$PASSWORD"; then
        commit_caddy
        success "Caddy успешно обновлен, перезапущен и полностью проверен."
        show_status
        return 0
    else
        error "Критическая ошибка после установки нового Caddy! Выполняем транзакционный откат..."
        rollback_caddy
        return 1
    fi
}


run_reinstall() {
    print_header
    info "Повторная установка NaïveProxy..."

    if [ -f "$CREDS_FILE" ]; then
        load_credentials || true
        echo ""
        echo -e "${BOLD}Обнаружены существующие реквизиты:${NC}"
        echo -e "  Домен:        ${CYAN}$DOMAIN${NC}"
        echo -e "  Email:        ${CYAN}$EMAIL${NC}"
        echo -e "  Пользователь: ${CYAN}$USERNAME${NC}"
        echo -e "  Пароль:       ${CYAN}$PASSWORD${NC}\n"
        echo "Выберите режим переустановки:"
        echo "  1) Сохранить текущие логин и пароль"
        echo "  2) Сгенерировать новые случайные реквизиты"
        echo "  3) Ввести все параметры заново вручную"
        echo "  0) Отмена"
        echo ""
        read -r -p "Ваш выбор [1-3, по умолчанию 1]: " rchoice
        rchoice="${rchoice:-1}"

        case "$rchoice" in
            1)
                cp -p "$CREDS_FILE" "${CREDS_FILE}.bak" 2>/dev/null || true
                systemctl stop caddy 2>/dev/null || true
                run_installation "keep"; return 0 ;;
            2)
                cp -p "$CREDS_FILE" "${CREDS_FILE}.bak" 2>/dev/null || true
                systemctl stop caddy 2>/dev/null || true
                run_installation "random"; return 0 ;;
            3)
                cp -p "$CREDS_FILE" "${CREDS_FILE}.bak" 2>/dev/null || true
                systemctl stop caddy 2>/dev/null || true
                run_installation "manual"; return 0 ;;
            0) info "Отменено."; return 0 ;;
        esac
    fi

    systemctl stop caddy 2>/dev/null || true
    run_installation
}


uninstall_all() {
    echo -e "\n${RED}${BOLD}ВНИМАНИЕ! Удаление NaïveProxy и Caddy.${NC}"
    read -r -p "Вы уверены? [y/N]: " confirm
    case "$confirm" in
        y|Y)
            info "Остановка caddy.service..."
            systemctl stop caddy 2>/dev/null || true
            systemctl disable caddy 2>/dev/null || true
            rm -f "$CADDY_SERVICE"
            systemctl daemon-reload

            # 1. СНАЧАЛА полностью восстанавливаем Nginx пока существуют файлы состояния в $NAIVE_DIR!
            info "Восстановление исходного состояния Nginx..."
            rm -f "$NGINX_STUB_CONF" "$NGINX_STUB_ENABLED"
            rm -rf "$NGINX_STUB_ROOT"

            local nginx_was_installed_by_script=false
            if [ -f "$NGINX_STATE_FILE" ]; then
                local orig_existed orig_type orig_tgt orig_bak
                orig_existed=$(grep '^DEFAULT_EXISTED=' "$NGINX_STATE_FILE" | cut -d= -f2 | tr -d '"')
                orig_type=$(grep '^DEFAULT_TYPE=' "$NGINX_STATE_FILE" | cut -d= -f2 | tr -d '"')
                orig_tgt=$(grep '^DEFAULT_SYMLINK_TARGET=' "$NGINX_STATE_FILE" | cut -d= -f2 | tr -d '"')
                orig_bak=$(grep '^DEFAULT_FILE_BACKUP=' "$NGINX_STATE_FILE" | cut -d= -f2 | tr -d '"')
                grep -q '^NGINX_INSTALLED_BY_SCRIPT=true' "$NGINX_STATE_FILE" && nginx_was_installed_by_script=true

                if [ "$orig_existed" = "true" ]; then
                    if [ "$orig_type" = "symlink" ] && [ -n "$orig_tgt" ]; then
                        ln -sf "$orig_tgt" /etc/nginx/sites-enabled/default
                        info "Восстановлена исходная символическая ссылка sites-enabled/default -> $orig_tgt."
                    elif [ "$orig_type" = "file" ] && [ -f "$orig_bak" ]; then
                        cp -a "$orig_bak" /etc/nginx/sites-enabled/default
                        rm -f "$orig_bak"
                        info "Восстановлен исходный файл sites-enabled/default."
                    fi
                fi
            fi

            # Восстановление отключенных сайтов на 443
            if [ -f /etc/naiveproxy/nginx_443_disabled.list ]; then
                info "Восстановление конфигураций Nginx на порту 443..."
                while IFS='|' read -r s_link s_target; do
                    [ -n "$s_link" ] && [ -n "$s_target" ] && ln -sf "$s_target" "$s_link"
                done < /etc/naiveproxy/nginx_443_disabled.list
                rm -f /etc/naiveproxy/nginx_443_disabled.list
            fi

            if nginx -t >/dev/null 2>&1; then
                systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
            fi

            # Остановка и удаление Web UI
            info "Остановка и удаление NaïveProxy Web UI..."
            systemctl stop naiveproxy-webui naiveproxy-web 2>/dev/null || true
            systemctl disable naiveproxy-webui naiveproxy-web 2>/dev/null || true
            rm -f "$WEB_SERVICE_FILE" "$WEB_SERVICE_ALIAS" "$WEB_SCRIPT_FILE" "$HELPER_SCRIPT_FILE" "/etc/sudoers.d/naive-web" "$WEB_CREDS_FILE"
            userdel -r naive-web 2>/dev/null || userdel naive-web 2>/dev/null || true
            systemctl daemon-reload

            # 2. ТЕПЕРЬ удаляем бинарники и каталоги Caddy и NaïveProxy
            info "Удаление бинарников и каталогов Caddy и NaïveProxy..."
            rm -f "$CADDY_BIN" "$CADDY_BAK" "${CADDY_FILE}.bak" "${BUILD_INFO_FILE}.bak"
            rm -rf "$CADDY_CONF_DIR" "$NAIVE_DIR" "$WEB_ROOT" "/var/lib/caddy" "/var/log/caddy" "$BUILD_ROOT"
            remove_motd
            userdel -r caddy 2>/dev/null || userdel caddy 2>/dev/null || true

            echo ""
            if [ "$nginx_was_installed_by_script" = true ]; then
                read -r -p "Nginx был установлен этим скриптом для заглушки. Удалить Nginx (apt purge)? [y/N]: " rm_nginx
            else
                read -r -p "Удалить пакет Nginx целиком? [y/N]: " rm_nginx
            fi
            case "$rm_nginx" in
                y|Y)
                    systemctl stop nginx 2>/dev/null || true
                    systemctl disable nginx 2>/dev/null || true
                    apt-get purge -y nginx nginx-common 2>/dev/null || true
                    info "Nginx полностью удалён." ;;
                *) info "Nginx сохранён в исходном состоянии." ;;
            esac

            if [ -d "$GO_INSTALL_DIR" ] || [ -d "/usr/local/go-versions" ]; then
                echo ""
                read -r -p "Удалить Go и все версии из /usr/local/go-versions? [y/N]: " rm_go
                case "$rm_go" in
                    y|Y)
                        rm -rf "$GO_INSTALL_DIR" /usr/local/go-versions /etc/profile.d/golang.sh
                        info "Go и версионные каталоги удалены." ;;
                esac
            fi

            success "NaïveProxy и Caddy полностью удалены."
            ;;
        *) info "Удаление отменено." ;;
    esac
}

