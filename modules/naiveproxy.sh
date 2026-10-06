#!/usr/bin/env bash
# ==============================================================================
# NaïveProxy Manager — Модуль NaïveProxy и управление клиентами (naiveproxy.sh)
# ==============================================================================

install_golang() {
    info "Проверка и установка Go (Golang)..."

    local go_arch=""
    case "$(uname -m)" in
        x86_64|amd64)  go_arch="amd64" ;;
        aarch64|arm64) go_arch="arm64" ;;
        armv7l)        go_arch="armv6l" ;;
        *)
            error "Неподдерживаемая архитектура Go: $(uname -m)"
            return 1
            ;;
    esac

    local go_version=""
    local json=""

    # 1. Запрос актуальной стабильной версии через JSON API go.dev
    if json="$(curl -fsSL --connect-timeout 10 --max-time 30 "https://go.dev/dl/?mode=json" 2>/dev/null)"; then
        if command -v jq &>/dev/null; then
            go_version="$(printf '%s' "$json" | jq -r '[ .[] | select(.stable == true) ] | .[0].version // empty' 2>/dev/null || true)"
        fi
    fi

    # 2. Запасной текстовый эндпоинт go.dev/VERSION?m=text
    if [[ ! "$go_version" =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        local text_ver
        text_ver="$(curl -fsSL --connect-timeout 5 --max-time 15 "https://go.dev/VERSION?m=text" 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
        if [[ "$text_ver" =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
            go_version="$text_ver"
        fi
    fi

    # 3. Безопасный статический fallback
    if [[ ! "$go_version" =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        go_version="go${DEFAULT_GO_VERSION:-1.24.1}"
        warn "Не удалось динамически получить список версий Go. Используется проверенный fallback: $go_version"
    fi

    # Проверка существующей версии Go
    if command -v go &>/dev/null; then
        local current_version
        current_version=$(go version 2>/dev/null | awk '{print $3}' || true)
        if [ -n "$current_version" ]; then
            local cv="${current_version#go}"
            local tv="${go_version#go}"
            if version_ge "$cv" "$tv"; then
                success "Go уже установлен актуальной версии ($current_version >= $go_version)."
                return 0
            fi
            info "Текущая версия Go ($current_version) ниже требуемой ($go_version). Обновляем..."
        fi
    fi

    local go_archive="${go_version}.linux-${go_arch}.tar.gz"
    local go_url="https://go.dev/dl/${go_archive}"

    info "Версия Go: ${go_version}"
    info "Архитектура: ${go_arch}"
    info "Загрузка архива: ${go_url}"

    local tmp_dir
    tmp_dir="$(mktemp -d /tmp/go-install.XXXXXX)"
    local tmp_archive="${tmp_dir}/${go_archive}"

    if ! curl -fL \
        --retry 3 \
        --retry-delay 2 \
        --connect-timeout 10 \
        --max-time 180 \
        -o "$tmp_archive" \
        "$go_url"; then
        error "Не удалось загрузить Go из ${go_url}"
        rm -rf "$tmp_dir"
        return 1
    fi

    # Проверка целостности архива (gzip -t отсекает HTML 404/ошибки сети)
    info "Проверка целостности загруженного архива..."
    if ! gzip -t "$tmp_archive" 2>/dev/null; then
        error "Загруженный архив Go повреждён или имеет неверный формат (возможно 404/HTML)."
        rm -rf "$tmp_dir"
        return 1
    fi

    rm -rf "${tmp_dir}/go"
    info "Распаковка Go во временный каталог..."
    if ! tar -xzf "$tmp_archive" -C "$tmp_dir"; then
        error "Не удалось распаковать архив Go."
        rm -rf "$tmp_dir"
        return 1
    fi

    # Предварительная валидация бинарника во временном каталоге
    if ! "${tmp_dir}/go/bin/go" version >/dev/null 2>&1; then
        error "Распакованный бинарник Go во временном каталоге не запускается."
        rm -rf "$tmp_dir"
        return 1
    fi

    # Атомарное обновление с сохранением резервной копии
    local old_dir="${GO_INSTALL_DIR}.old"
    rm -rf "$old_dir"

    if [ -d "$GO_INSTALL_DIR" ]; then
        mv "$GO_INSTALL_DIR" "$old_dir" || {
            error "Не удалось сохранить текущую установку Go."
            rm -rf "$tmp_dir"
            return 1
        }
    fi

    if ! mv "${tmp_dir}/go" "$GO_INSTALL_DIR"; then
        error "Не удалось установить новую версию Go."
        if [ -d "$old_dir" ]; then
            mv "$old_dir" "$GO_INSTALL_DIR" || true
        fi
        rm -rf "$tmp_dir"
        return 1
    fi

    # Проверка работоспособности на целевом месте
    if ! "$GO_INSTALL_DIR/bin/go" version >/dev/null 2>&1; then
        error "Установленный Go в $GO_INSTALL_DIR не запускается."
        if [ -d "$old_dir" ]; then
            rm -rf "$GO_INSTALL_DIR"
            mv "$old_dir" "$GO_INSTALL_DIR" || true
        fi
        rm -rf "$tmp_dir"
        return 1
    fi

    # Успех: очистка резервной копии и временных файлов
    rm -rf "$old_dir" "$tmp_dir"

    cat > /etc/profile.d/golang.sh <<'EOF_PROFILE'
export GOROOT=/usr/local/go
export GOPATH=/root/go
export PATH="/usr/local/go/bin:$GOPATH/bin:$PATH"
EOF_PROFILE
    chmod 644 /etc/profile.d/golang.sh
    export GOROOT=/usr/local/go
    export GOPATH=/root/go
    export PATH="/usr/local/go/bin:$GOPATH/bin:$PATH"

    success "Go успешно установлен: $("$GO_INSTALL_DIR/bin/go" version)"
    return 0
}



is_naiveproxy_installed() {
    [ -f "$CREDS_FILE" ] && \
    [ -f "$CADDY_FILE" ] && \
    [ -f "$CADDY_BIN" ] && \
    grep -q "forward_proxy" "$CADDY_FILE" 2>/dev/null
}

naiveproxy_status() {
    if is_naiveproxy_installed; then
        if systemctl is-active --quiet caddy 2>/dev/null; then
            success "NaïveProxy активен (RUNNING via Caddy :443)."
            return 0
        else
            warn "NaïveProxy установлен, но Caddy остановлен."
            return 1
        fi
    else
        warn "NaïveProxy не установлен."
        return 1
    fi
}

start_naiveproxy() {
    info "Запуск NaïveProxy (caddy.service)..."
    systemctl start caddy
    caddy_status
}

stop_naiveproxy() {
    info "Остановка NaïveProxy (caddy.service)..."
    systemctl stop caddy
    success "NaïveProxy остановлен."
}

restart_naiveproxy() {
    info "Перезапуск NaïveProxy (caddy.service)..."
    systemctl restart caddy
    caddy_status
}

load_users() {
    mkdir -p "$CLIENTS_DIR"
    chown root:naive-web "$CLIENTS_DIR" 2>/dev/null || true
    chmod 775 "$CLIENTS_DIR" 2>/dev/null || true

    # Если users.json еще нет, но есть credentials — мигрируем начального пользователя
    if [ ! -f "$USERS_FILE" ] && [ -f "$CREDS_FILE" ]; then
        load_credentials 2>/dev/null || true
        if [ -n "$USERNAME" ] && [ -n "$PASSWORD" ]; then
            python3 - "$USERS_FILE" "$USERNAME" "$PASSWORD" << 'EOF_PY'
import sys, json, datetime
users_file, username, password = sys.argv[1], sys.argv[2], sys.argv[3]
now_str = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
data = [{
    "username": username,
    "password": password,
    "created_at": now_str,
    "note": "Основной клиент"
}]
with open(users_file, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
EOF_PY
            chmod 664 "$USERS_FILE"
            chown root:naive-web "$USERS_FILE" 2>/dev/null || true
        fi
    fi
}

sync_caddy_users() {
    load_credentials 2>/dev/null || true
    load_users 2>/dev/null || true

    [ ! -f "$USERS_FILE" ] && return 1
    [ ! -f "$CADDY_FILE" ] && return 1

    if [ -x "$HELPER_SCRIPT_FILE" ]; then
        "$HELPER_SCRIPT_FILE" sync_caddy 2>/dev/null || true
        return 0
    fi
    return 0
}

client_add() {
    load_credentials 2>/dev/null || true
    load_users 2>/dev/null || true
    local target_domain="${DOMAIN:-$CHECKED_DOMAIN}"

    local u="$1" p="$2" n="${3:-Клиент}"

    if [ -z "$u" ] || [ -z "$p" ]; then
        echo -e "${BOLD}ДОБАВЛЕНИЕ НОВОГО КЛИЕНТА NAÏVEPROXY${NC}\n"
        local auto_u="user_$(generate_random_string 8)"
        read -r -p "Логин клиента [по умолчанию: $auto_u]: " u
        u="${u:-$auto_u}"
        u=$(echo "$u" | tr -d '[:space:]')
        [[ ! "$u" =~ ^[A-Za-z0-9_-]+$ ]] && { error "Некорректный логин (только латиница, цифры, дефис)."; return 1; }

        local auto_p
        auto_p=$(generate_random_string 16)
        read -r -p "Пароль клиента [по умолчанию: $auto_p]: " p
        p="${p:-$auto_p}"
        p=$(echo "$p" | tr -d '[:space:]')
        [[ ! "$p" =~ ^[A-Za-z0-9._-]+$ ]] && { error "Некорректный пароль."; return 1; }

        read -r -p "Примечание (например, Телефон / Иван) [по умолчанию: Клиент]: " n
        n="${n:-Клиент}"
    fi

    # Проверка на дубликат логина
    local exists
    exists=$(python3 - "$USERS_FILE" "$u" << 'EOF_PY'
import sys, json
users_file, target_user = sys.argv[1], sys.argv[2]
try:
    with open(users_file, "r", encoding="utf-8") as f:
        users = json.load(f)
    print("yes" if any(user.get("username") == target_user for user in users) else "no")
except Exception:
    print("no")
EOF_PY
)
    if [ "$exists" = "yes" ]; then
        error "Пользователь с логином '$u' уже существует!"
        return 1
    fi

    # Добавление в users.json
    python3 - "$USERS_FILE" "$u" "$p" "$n" << 'EOF_PY'
import sys, json, datetime
users_file, u, p, n = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    with open(users_file, "r", encoding="utf-8") as f:
        users = json.load(f)
except Exception:
    users = []

now_str = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
users.append({
    "username": u,
    "password": p,
    "created_at": now_str,
    "note": n
})

with open(users_file, "w", encoding="utf-8") as f:
    json.dump(users, f, indent=2, ensure_ascii=False)
EOF_PY
    chmod 664 "$USERS_FILE"
    chown root:naive-web "$USERS_FILE" 2>/dev/null || true

    sync_caddy_users

    local nekobox_link="naive+https://${u}:${p}@${target_domain}:443#Naive-${u}"
    success "Клиент '$u' успешно добавлен!"
    echo "──────────────────────────────────────────────────────"
    echo -e "  Логин:        ${BOLD}$u${NC}"
    echo -e "  Пароль:       ${BOLD}$p${NC}"
    echo -e "  Примечание:   $n"
    echo -e "  NekoBox URL:  ${YELLOW}${nekobox_link}${NC}"
    echo -e "  Стандарт URL: ${YELLOW}https://${u}:${p}@${target_domain}:443${NC}"
    echo -e "  Файл конфига: $CLIENTS_DIR/${u}.json"
    if command -v qrencode &>/dev/null; then
        echo -e "\n${CYAN}QR-код для импорта в NekoBox / Matsuri / v2rayN:${NC}"
        qrencode -t ANSIUTF8 "${nekobox_link}"
    fi
    echo "──────────────────────────────────────────────────────"
    return 0
}

client_delete() {
    load_users 2>/dev/null || true
    local u="$1"
    if [ -z "$u" ]; then
        echo -e "${BOLD}УДАЛЕНИЕ КЛИЕНТА NAÏVEPROXY${NC}\n"
        read -r -p "Введите логин клиента для удаления: " u
        u=$(echo "$u" | tr -d '[:space:]')
    fi

    [ -z "$u" ] && { error "Логин не указан."; return 1; }

    # Проверка, что не удаляется последний пользователь
    local count
    count=$(python3 - "$USERS_FILE" << 'EOF_PY'
import sys, json
users_file = sys.argv[1]
try:
    with open(users_file, "r", encoding="utf-8") as f:
        users = json.load(f)
    print(len(users))
except Exception:
    print(0)
EOF_PY
)
    if [ "$count" -le 1 ]; then
        error "Нельзя удалить последнего клиента! В системе должен оставаться хотя бы один пользователь."
        return 1
    fi

    local removed
    removed=$(python3 - "$USERS_FILE" "$u" << 'EOF_PY'
import sys, json
users_file, u = sys.argv[1], sys.argv[2]
try:
    with open(users_file, "r", encoding="utf-8") as f:
        users = json.load(f)
    new_users = [user for user in users if user.get("username") != u]
    if len(new_users) < len(users):
        with open(users_file, "w", encoding="utf-8") as f:
            json.dump(new_users, f, indent=2, ensure_ascii=False)
        print("yes")
    else:
        print("no")
except Exception:
    print("no")
EOF_PY
)

    if [ "$removed" = "yes" ]; then
        rm -f "$CLIENTS_DIR/${u}.json" 2>/dev/null || true
        sync_caddy_users
        success "Клиент '$u' успешно удален из системы."
        return 0
    else
        error "Клиент с логином '$u' не найден."
        return 1
    fi
}

client_list() {
    load_credentials 2>/dev/null || true
    load_users 2>/dev/null || true
    local target_domain="${DOMAIN:-$CHECKED_DOMAIN}"

    echo -e "${BOLD}${CYAN}СПИСОК КЛИЕНТОВ NAÏVEPROXY${NC}\n"
    python3 - "$USERS_FILE" "$target_domain" << 'EOF_PY'
import sys, json

users_file = sys.argv[1]
target_domain = sys.argv[2]

try:
    with open(users_file, "r", encoding="utf-8") as f:
        users = json.load(f)
    if not users:
        print("Клиенты отсутствуют.")
    else:
        print(f"Всего клиентов: {len(users)}\n")
        header_fmt = "{:<3} {:<18} {:<18} {:<15} {}"
        print(header_fmt.format("#", "ЛОГИН", "ПАРОЛЬ", "ПРИМЕЧАНИЕ", "СОЗДАН"))
        print("─" * 70)
        for i, u in enumerate(users, 1):
            un = u.get("username", "")
            pw = u.get("password", "")
            nt = u.get("note", "") or ""
            ca = u.get("created_at", "")[:10] if u.get("created_at") else ""
            print(header_fmt.format(i, un, pw, nt, ca))
        print("─" * 70)
        print("\nСсылки подключения (NekoBox & Matsuri format):")
        for u in users:
            un = u.get("username", "")
            pw = u.get("password", "")
            print(f" • {un}: naive+https://{un}:{pw}@{target_domain}:443#Naive-{un}")
except Exception as e:
    print("Ошибка чтения списка пользователей:", e)
EOF_PY
}

manage_clients_menu() {
    while true; do
        print_header
        echo -e "${BOLD}${CYAN}УПРАВЛЕНИЕ КЛИЕНТАМИ NAÏVEPROXY${NC}\n"
        echo "  1) Список всех клиентов и ссылки подключения"
        echo "  2) Добавить нового клиента (+ client.json)"
        echo "  3) Показать / скопировать client.json клиента"
        echo "  4) Удалить клиента"
        echo "  0) Назад в главное меню"
        echo "──────────────────────────────────────────────────────"
        echo ""
        read -r -p "Выберите действие [0-4]: " cchoice
        case "$cchoice" in
            1)
                print_header
                client_list
                echo ""
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            2)
                print_header
                client_add "" "" ""
                echo ""
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            3)
                print_header
                read -r -p "Введите логин клиента: " quser
                quser=$(echo "$quser" | tr -d '[:space:]')
                if [ -f "$CLIENTS_DIR/${quser}.json" ]; then
                    echo -e "\n${BOLD}Конфигурация $CLIENTS_DIR/${quser}.json:${NC}\n"
                    cat "$CLIENTS_DIR/${quser}.json"
                    echo ""
                else
                    error "Конфигурация для пользователя '$quser' не найдена."
                fi
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            4)
                print_header
                client_list
                echo ""
                client_delete ""
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            0) return 0 ;;
            *) error "Неверный выбор."; sleep 1 ;;
        esac
    done
}



add_user() { client_add "$@"; }
remove_user() { client_delete "$@"; }
list_users() { client_list "$@"; }

apply_new_domain() {
    local new_domain="$1"
    step "Быстрая смена домена на '$new_domain' (без перекомпиляции Caddy)"

    load_credentials 2>/dev/null || true
    local old_domain="${DOMAIN:-}"

    if [ "$old_domain" = "$new_domain" ]; then
        info "Домен '$new_domain' уже настроен как текущий."
        return 0
    fi

    # 1. Резервная копия Caddyfile
    cp -a "$CADDY_FILE" "${CADDY_FILE}.bak_domain"

    # 2. Замена домена в Caddyfile
    sed -i "s|:443, $old_domain|:443, $new_domain|g" "$CADDY_FILE"
    sed -i "s|:443, [a-zA-Z0-9.-]*|:443, $new_domain|g" "$CADDY_FILE"

    # 3. Валидация Caddyfile
    if ! "$CADDY_BIN" validate --config "$CADDY_FILE" >/dev/null 2>&1; then
        error "Ошибка валидации Caddyfile при смене домена! Выполняем автоматический откат..."
        cp -a "${CADDY_FILE}.bak_domain" "$CADDY_FILE"
        return 1
    fi

    # 4. Обновление учетных файлов
    DOMAIN="$new_domain"
    sed -i "s|^DOMAIN=.*|DOMAIN=\"$new_domain\"|" "$CREDS_FILE" 2>/dev/null || true
    sed -i "s|^DOMAIN=.*|DOMAIN=\"$new_domain\"|" "$DOMAIN_CHECK_FILE" 2>/dev/null || true

    # 5. Синхронизация клиентов (обновление ссылок в clients/<user>.json)
    sync_caddy_users >/dev/null 2>&1 || true

    # 6. Перезапуск Caddy для выпуска нового ACME сертификата
    info "Перезапуск Caddy для выпуска сертификата Let's Encrypt на $new_domain..."
    systemctl restart caddy
    sleep 4

    # 7. Проверка TLS
    local tls_out tls_stat tls_iss tls_host tls_left tls_exp
    tls_out=$(verify_tls_certificate "$new_domain")
    IFS='|' read -r tls_stat tls_iss tls_host tls_left tls_exp <<< "$tls_out"

    if [ "$tls_stat" = "VALID" ]; then
        success "Новый сертификат для '$new_domain' успешно выпущен!"
    else
        warn "Сертификат для '$new_domain' находится в процессе выпуска ($tls_stat)."
    fi

    setup_motd
    success "Домен успешно переключен на: $new_domain"
    echo ""
    read -r -p "Нажмите Enter для просмотра реквизитов..."
    show_info
}

domain_wizard() {
    check_root
    check_os
    check_arch
    install_dependencies
    resolve_server_ips

    while true; do
        print_header
        echo -e "${BOLD}ЭТАП 1: МАСТЕР ПОДГОТОВКИ ДОМЕНА${NC}\n"
        echo -e "Архитектура:  ${CYAN}:80 Nginx Stub${NC}  +  ${GREEN}:443 Caddy NaïveProxy${NC}"
        echo -e "IP вашего VPS: ${BOLD}${GREEN}$SERVER_IPV4${NC}"
        [ -n "$SERVER_IPV6" ] && echo -e "IPv6 сервера:  ${BOLD}${GREEN}$SERVER_IPV6${NC}"
        echo ""
        echo "──────────────────────────────────────────────────────"
        echo "  1) У меня есть собственный домен"
        echo "  2) У меня есть домен, хочу настроить субдомен"
        echo "  3) Получить бесплатный домен (DuckDNS / FreeDNS / др.)"
        echo "  4) Проверить уже привязанный домен"
        echo "  0) Назад в главное меню"
        echo "──────────────────────────────────────────────────────"
        echo ""
        read -r -p "Выберите вариант [0-4]: " wchoice
        case "$wchoice" in
            1) wizard_own_domain ;;
            2) wizard_subdomain ;;
            3) wizard_free_domain ;;
            4) wizard_manual_check ;;
            0) return 0 ;;
            *) error "Неверный выбор."; sleep 1 ;;
        esac
    done
}

wizard_own_domain() {
    print_header
    echo -e "${BOLD}НАСТРОЙКА СОБСТВЕННОГО ДОМЕНА${NC}\n"
    read -r -p "Введите имя домена (например, example.com): " raw_domain
    raw_domain=$(echo "$raw_domain" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

    local chk
    chk=$(validate_domain_format "$raw_domain" || true)
    [ "$chk" != "VALID" ] && { handle_format_error "$chk" "$raw_domain"; return; }

    echo -e "\nСоздайте в панели DNS запись:"
    echo "  Тип: A | Имя: @ (или пусто) | Значение: $SERVER_IPV4 | TTL: 300"
    echo ""
    read -r -p "Нажмите Enter для запуска диагностики..."
    run_domain_diagnostics "$raw_domain"
}

wizard_subdomain() {
    print_header
    echo -e "${BOLD}НАСТРОЙКА СУБДОМЕНА ДЛЯ NAÏVEPROXY${NC}\n"
    echo "Субдомен позволяет сохранить основной сайт нетронутым."
    echo "Популярные имена: proxy, vpn, cdn, node, secure"
    echo ""
    read -r -p "Введите субдомен полностью (например, proxy.example.com): " raw_sub
    raw_sub=$(echo "$raw_sub" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

    local chk
    chk=$(validate_domain_format "$raw_sub" || true)
    [ "$chk" != "VALID" ] && { handle_format_error "$chk" "$raw_sub"; return; }

    local sub_name="${raw_sub%%.*}"
    echo -e "\nСоздайте в панели DNS запись:"
    echo "  Тип: A | Имя: $sub_name | Значение: $SERVER_IPV4 | TTL: 300"
    echo ""
    read -r -p "Нажмите Enter для запуска диагностики..."
    run_domain_diagnostics "$raw_sub"
}

wizard_free_domain() {
    print_header
    echo -e "${BOLD}БЕСПЛАТНЫЕ ДОМЕНЫ И ХОСТНЕЙМЫ${NC}\n"
    echo "1) DuckDNS       БЕСПЛАТНО  (поддомен *.duckdns.org, готов за 1 мин)"
    echo "2) FreeDNS       БЕСПЛАТНО  (поддомен *.afraid.org и др.)"
    echo "3) EU.org        БЕСПЛАТНО  (делегирование занимает дни/недели)"
    echo "0) Назад"
    echo ""
    read -r -p "Выберите вариант [0-3]: " fchoice
    case "$fchoice" in
        1)
            print_header
            echo -e "${BOLD}НАСТРОЙКА DUCKDNS${NC}\n"
            echo "1. Зайдите на https://www.duckdns.org"
            echo "2. Создайте домен и укажите IP: $SERVER_IPV4"
            echo ""
            read -r -p "Введите созданный домен (например, test.duckdns.org): " ddom
            ddom=$(echo "$ddom" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            run_domain_diagnostics "$ddom"
            ;;
        2)
            print_header
            echo -e "${BOLD}НАСТРОЙКА FREEDNS (AFRAID.ORG)${NC}\n"
            echo "1. Зайдите на https://freedns.afraid.org"
            echo "2. Добавьте субдомен и направьте на IP: $SERVER_IPV4"
            echo ""
            read -r -p "Введите субдомен (например, test.afraid.org): " fdom
            fdom=$(echo "$fdom" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            run_domain_diagnostics "$fdom"
            ;;
        3)
            info "EU.org требует ручного одобрения заявки администратором (дни/недели)."
            read -r -p "Если у вас уже есть одобренный eu.org домен, введите его (иначе Enter): " edom
            edom=$(echo "$edom" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            [ -n "$edom" ] && run_domain_diagnostics "$edom"
            ;;
        0) return 0 ;;
    esac
}

wizard_manual_check() {
    print_header
    local def_dom=""
    load_domain_check 2>/dev/null && def_dom="${CHECKED_DOMAIN:-}"

    if [ -n "$def_dom" ]; then
        read -r -p "Введите домен для проверки [по умолчанию: $def_dom]: " target
        target="${target:-$def_dom}"
    else
        read -r -p "Введите домен для проверки: " target
    fi
    target=$(echo "$target" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    run_domain_diagnostics "$target"
}

handle_format_error() {
    local code="$1" dom="$2"
    echo ""
    case "$code" in
        BLOCKED_PAGES_DEV)
            error "Домены *.pages.dev не поддерживают прямую A-запись на VPS!"
            echo "Используйте DuckDNS, FreeDNS или собственный домен."
            ;;
        BLOCKED_STATIC_HOST)
            error "Домен '$dom' является адресом облачного хостинга и не может указывать на VPS."
            ;;
        *) error "Некорректный синтаксис доменного имени: '$dom'." ;;
    esac
    echo ""
    read -r -p "Нажмите Enter для возврата..."
}

run_domain_diagnostics() {
    local target_domain="$1"
    target_domain=$(echo "$target_domain" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

    local format_check
    format_check=$(validate_domain_format "$target_domain" || true)
    [ "$format_check" != "VALID" ] && { handle_format_error "$format_check" "$target_domain"; return 1; }

    # Единый источник истины: обязательная проверка/определение IP перед диагностикой
    if [[ ! "$SERVER_IPV4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        resolve_server_ips
    fi

    if [[ ! "$SERVER_IPV4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        error "Не удалось определить публичный IPv4 VPS."
        echo ""
        echo "Проверьте вручную: curl -4 https://api.ipify.org"
        echo ""
        read -r -p "Введите внешний IPv4 вашего VPS вручную: " SERVER_IPV4
        SERVER_IPV4=$(echo "$SERVER_IPV4" | tr -d '[:space:]')
        if [[ ! "$SERVER_IPV4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            error "Некорректный формат IPv4 адреса. Диагностика отменена."
            return 1
        fi
    fi

    # Явная гарантия наличия ключевых диагностических утилит
    require_command dig dnsutils
    require_command jq jq
    require_command curl curl
    require_command openssl openssl

    print_header
    echo -e "${BOLD}ДИАГНОСТИКА ДОМЕНА ПЕРЕД УСТАНОВКОЙ${NC}\n"
    echo -e "Домен:    ${BOLD}$target_domain${NC}"
    echo -e "VPS IPv4: ${BOLD}${GREEN}$SERVER_IPV4${NC}\n"
    info "Опрос DNS-резолверов (системный DNS, Cloudflare, Google, Quad9, DoH)..."

    local ip_sys="" ip_cf="" ip_google="" ip_quad9="" ip_yandex="" ip_authoritative="" ip_doh=""

    # Гарантируем наличие dnsutils (dig)
    if ! command -v dig &>/dev/null; then
        install_dependencies
    fi

    # 1. Системный локальный резолвер из /etc/resolv.conf (разрешён всеми хостерами)
    if command -v dig &>/dev/null; then
        ip_sys=$(dig +short +time=2 +tries=1 A "$target_domain" 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)
    fi
    if [ -z "$ip_sys" ] && command -v getent &>/dev/null; then
        ip_sys=$(getent ahostsv4 "$target_domain" 2>/dev/null | awk '{print $1}' | grep -E '^[0-9.]+$' | head -n1 || true)
    fi
    if [ -z "$ip_sys" ] && command -v host &>/dev/null; then
        ip_sys=$(host -W 2 -t A "$target_domain" 2>/dev/null | awk '/has address/ {print $4}' | grep -E '^[0-9.]+$' | head -n1 || true)
    fi
    # Встроенный резолвер Python 3 через системный libc gethostbyname (работает без внешних утилит)
    if [ -z "$ip_sys" ] && command -v python3 &>/dev/null; then
        ip_sys=$(python3 -c "import socket; print(socket.gethostbyname('$target_domain'))" 2>/dev/null | grep -E '^[0-9.]+$' || true)
    fi

    # 2. Авторитативный сервер DuckDNS (для доменов *.duckdns.org)
    if [[ "$target_domain" == *.duckdns.org ]] && command -v dig &>/dev/null; then
        ip_authoritative=$(dig +short +time=3 +tries=1 A "$target_domain" @ns1.duckdns.org 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)
        [ -z "$ip_authoritative" ] && ip_authoritative=$(dig +tcp +short +time=3 +tries=1 A "$target_domain" @ns1.duckdns.org 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)
    fi

    # 3. Публичные резолверы (UDP + TCP fallback на случай блокировки UDP 53)
    if command -v dig &>/dev/null; then
        ip_cf=$(dig +short +time=2 +tries=1 A "$target_domain" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)
        [ -z "$ip_cf" ] && ip_cf=$(dig +tcp +short +time=3 +tries=1 A "$target_domain" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)

        ip_google=$(dig +short +time=2 +tries=1 A "$target_domain" @8.8.8.8 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)
        [ -z "$ip_google" ] && ip_google=$(dig +tcp +short +time=3 +tries=1 A "$target_domain" @8.8.8.8 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)

        ip_quad9=$(dig +short +time=2 +tries=1 A "$target_domain" @9.9.9.9 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)
        [ -z "$ip_quad9" ] && ip_quad9=$(dig +tcp +short +time=3 +tries=1 A "$target_domain" @9.9.9.9 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)

        ip_yandex=$(dig +short +time=2 +tries=1 A "$target_domain" @77.88.8.8 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)
    fi

    # 4. DNS-over-HTTPS (DoH по IP и доменам, обход блокировки порта 53)
    if [ -z "$ip_cf" ] && [ -z "$ip_google" ] && [ -z "$ip_sys" ]; then
        ip_doh=$(curl -s -m 4 -H 'accept: application/dns-json' "https://1.1.1.1/dns-query?name=${target_domain}&type=A" 2>/dev/null | jq -r '.Answer[]? | select(.type==1) | .data' 2>/dev/null | head -n1 || true)
        if [ -z "$ip_doh" ]; then
            ip_doh=$(curl -s -m 4 "https://dns.google/resolve?name=${target_domain}&type=A" 2>/dev/null | jq -r '.Answer[]? | select(.type==1) | .data' 2>/dev/null | head -n1 || true)
        fi
        if [ -z "$ip_doh" ]; then
            ip_doh=$(curl -s -m 4 -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=${target_domain}&type=A" 2>/dev/null | jq -r '.Answer[]? | select(.type==1) | .data' 2>/dev/null | head -n1 || true)
        fi
    fi

    # Выбираем обнаруженный адрес (приоритет совпадению с IP VPS)
    local detected_ip=""
    for cand in "$ip_authoritative" "$ip_sys" "$ip_cf" "$ip_google" "$ip_quad9" "$ip_yandex" "$ip_doh"; do
        if [ -n "$cand" ]; then
            detected_ip="$cand"
            [ "$cand" = "$SERVER_IPV4" ] && break
        fi
    done

    local dns_a_status=false
    [ "$detected_ip" = "$SERVER_IPV4" ] && dns_a_status=true

    # IPv6 согласованность: проверка всех AAAA по всем адресам VPS
    local aaaa_records=()
    while IFS= read -r arec; do
        arec=$(echo "$arec" | tr -d '[:space:]')
        [ -n "$arec" ] && aaaa_records+=("$arec")
    done < <(dig +short +time=2 +tries=1 AAAA "$target_domain" 2>/dev/null | grep -E ':' || true)

    local aaaa_diagnostic="" aaaa_severity="OK"
    if [ "${#aaaa_records[@]}" -eq 0 ]; then
        aaaa_diagnostic="отсутствует (только IPv4 — оптимально для TLS-ALPN-01)"
    else
        local all_aaaa_str="${aaaa_records[*]}"
        if [ -z "$SERVER_IPV6_OUTBOUND" ] && [ "${#SERVER_IPV6_LIST[@]}" -eq 0 ]; then
            aaaa_diagnostic="${YELLOW}обнаружены AAAA: $all_aaaa_str (на VPS нет IPv6. Let's Encrypt отдаст приоритет IPv6. Удалите AAAA-запись, если сертификат не будет выпускаться)${NC}"
            aaaa_severity="WARNING"
        else
            local match_found=false
            local mismatch_list=()
            for rec in "${aaaa_records[@]}"; do
                local rec_matched=false
                for v_ip in "${SERVER_IPV6_LIST[@]}" "$SERVER_IPV6_OUTBOUND"; do
                    [ -n "$v_ip" ] && [ "$rec" = "$v_ip" ] && { rec_matched=true; break; }
                done
                [ "$rec_matched" = true ] && match_found=true || mismatch_list+=("$rec")
            done

            if [ "$match_found" = true ] && [ "${#mismatch_list[@]}" -eq 0 ]; then
                aaaa_diagnostic="$all_aaaa_str (все AAAA соответствуют IPv6 VPS)"
            elif [ "$match_found" = true ]; then
                aaaa_diagnostic="${YELLOW}частичное совпадение: IP VPS присутствует, но есть сторонние (${mismatch_list[*]}).${NC}"
                aaaa_severity="WARNING"
            else
                aaaa_diagnostic="${YELLOW}не совпадают с локальным IPv6 VPS (${SERVER_IPV6_LIST[*]}). Проверьте маршрутизацию.${NC}"
                aaaa_severity="WARNING"
            fi
        fi
    fi

    # CAA проверка
    local caa_state caa_diagnostic="" caa_severity="OK"
    caa_state=$(check_caa_record "$target_domain")
    case "$caa_state" in
        ABSENT) caa_diagnostic="отсутствует (Let's Encrypt разрешён по умолчанию)" ;;
        ALLOWED) caa_diagnostic="присутствует (letsencrypt.org разрешён)" ;;
        RESTRICTED) caa_diagnostic="${RED}ограничивает выпуск (letsencrypt.org отсутствует в issue!)${NC}"; caa_severity="FATAL" ;;
        QUERY_FAILED) caa_diagnostic="${YELLOW}DNS-таймаут запроса CAA (проверка Let's Encrypt выполнится в рантайме)${NC}"; caa_severity="WARNING" ;;
    esac

    # Статусы локальных портов через единый get_port_owner
    local p80_owner p443_owner
    p80_owner=$(get_port_owner 80)
    p443_owner=$(get_port_owner 443)

    local port80_stat="${GREEN}свободен (будет настроен Nginx)${NC}"
    local port443_stat="${GREEN}свободен (готов для Caddy)${NC}"

    if [ -n "$p80_owner" ]; then
        local p80_proc="${p80_owner%% *}" p80_pid="${p80_owner##* }"
        [ "$p80_proc" = "nginx" ] && port80_stat="${GREEN}занят Nginx (сайт-заглушка :80 — штатно)${NC}"
        [ "$p80_proc" != "nginx" ] && port80_stat="${RED}занят $p80_proc (PID $p80_pid) — конфликт!${NC}"
    fi

    if [ -n "$p443_owner" ]; then
        local p443_proc="${p443_owner%% *}" p443_pid="${p443_owner##* }"
        [ "$p443_proc" = "caddy" ] && port443_stat="${GREEN}занят текущим Caddy (NaïveProxy)${NC}"
        [ "$p443_proc" = "nginx" ] && port443_stat="${YELLOW}занят Nginx (потребуется освободить :443)${NC}"
        [ "$p443_proc" != "caddy" ] && [ "$p443_proc" != "nginx" ] && port443_stat="${RED}занят $p443_proc (PID $p443_pid)${NC}"
    fi

    echo "──────────────────────────────────────────────────────"
    echo -e "${BOLD}РЕЗУЛЬТАТЫ ПРОВЕРКИ:${NC}\n"
    echo -e "1. Формат домена:      ${GREEN}✓ Корректный${NC}"
    if [ "$dns_a_status" = true ]; then
        echo -e "2. DNS A → VPS:        ${GREEN}✓ $target_domain → $SERVER_IPV4${NC}"
    else
        echo -e "2. DNS A → VPS:        ${RED}✗ $target_domain → ${detected_ip:-не найдена} (ожидался $SERVER_IPV4)${NC}"
    fi

    local badges=()
    [ -n "$ip_sys" ] && badges+=("Системный DNS: $([ "$ip_sys" = "$SERVER_IPV4" ] && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗ ($ip_sys)${NC}")")
    [ -n "$ip_authoritative" ] && badges+=("DuckDNS NS: $([ "$ip_authoritative" = "$SERVER_IPV4" ] && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗ ($ip_authoritative)${NC}")")
    [ -n "$ip_cf" ] && badges+=("Cloudflare: $([ "$ip_cf" = "$SERVER_IPV4" ] && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗ ($ip_cf)${NC}")")
    [ -n "$ip_google" ] && badges+=("Google: $([ "$ip_google" = "$SERVER_IPV4" ] && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗ ($ip_google)${NC}")")
    [ -n "$ip_doh" ] && badges+=("DoH: $([ "$ip_doh" = "$SERVER_IPV4" ] && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗ ($ip_doh)${NC}")")

    if [ "${#badges[@]}" -gt 0 ]; then
        local IFS_BAK="$IFS"
        IFS=" | "
        echo -e "   • ${badges[*]}"
        IFS="$IFS_BAK"
    else
        echo -e "   • ${YELLOW}Внешние DNS-запросы завершились таймаутом (проверьте доступ к порту 53)${NC}"
    fi

    echo -e "3. AAAA (IPv6):        $([ "$aaaa_severity" = "OK" ] && echo -e "${GREEN}✓${NC}" || echo -e "${YELLOW}!${NC}") $aaaa_diagnostic"
    echo -e "4. CAA (SSL):          $([ "$caa_severity" = "OK" ] && echo -e "${GREEN}✓${NC}" || ([ "$caa_severity" = "WARNING" ] && echo -e "${YELLOW}!${NC}" || echo -e "${RED}✗${NC}")) $caa_diagnostic"
    echo -e "5. Порт 80 (Nginx):    $port80_stat"
    echo -e "6. Порт 443 (Caddy):   $port443_stat"
    echo "──────────────────────────────────────────────────────"

    local final_status="NOT_READY"
    if [ "$dns_a_status" = true ] && [ "$caa_severity" != "FATAL" ]; then
        if [ "$aaaa_severity" = "OK" ] && [ "$caa_severity" = "OK" ]; then
            final_status="READY"
        else
            final_status="READY_WITH_WARNINGS"
        fi
    fi

    mkdir -p "$NAIVE_DIR"
    local now_epoch now_str
    now_epoch=$(date +%s); now_str="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"

    cat << EOF > "$DOMAIN_CHECK_FILE"
DOMAIN="$target_domain"
SERVER_IPV4="$SERVER_IPV4"
DNS_IPV4="${detected_ip:-NONE}"
DNS_STATUS="$([ "$dns_a_status" = true ] && echo "OK" || echo "FAILED")"
CAA_STATUS="$caa_state"
CHECK_TIMESTAMP="$now_str"
CHECK_TIMESTAMP_EPOCH="$now_epoch"
DOMAIN_STATUS="$final_status"
EOF
    chmod 600 "$DOMAIN_CHECK_FILE"
    chmod 775 "$NAIVE_DIR" 2>/dev/null || true; chown root:naive-web "$NAIVE_DIR" 2>/dev/null || true

    if [ "$final_status" = "READY" ]; then
        echo -e "\n${GREEN}██████████████████████████████████████████████████████${NC}"
        echo -e "${BOLD}${GREEN}               ✓ ДОМЕН ПОЛНОСТЬЮ ГОТОВ                ${NC}"
        echo -e "${GREEN}██████████████████████████████████████████████████████${NC}\n"
        if is_naiveproxy_installed; then
            echo "NaïveProxy уже установлен в системе."
            echo "  1) Переключить Caddy на новый домен '$target_domain' (быстро, без пересборки)"
            echo "  2) Полная переустановка с новым доменом"
            echo "  0) Назад в главное меню"
            echo ""
            read -r -p "Выберите действие [0-2, по умолчанию 1]: " sw_choice
            sw_choice="${sw_choice:-1}"
            case "$sw_choice" in
                1) apply_new_domain "$target_domain" ;;
                2) run_installation ;;
                *) return 0 ;;
            esac
        else
            read -r -p "Запустить установку NaïveProxy прямо сейчас? [Y/n]: " proceed
            case "$proceed" in
                n|N) return 0 ;;
                *) run_installation ;;
            esac
        fi
    elif [ "$final_status" = "READY_WITH_WARNINGS" ]; then
        echo -e "\n${YELLOW}██████████████████████████████████████████████████████${NC}"
        echo -e "${BOLD}${YELLOW}         ! ДОМЕН ГОТОВ С ПРЕДУПРЕЖДЕНИЯМИ            ${NC}"
        echo -e "${YELLOW}██████████████████████████████████████████████████████${NC}\n"
        echo "A-запись указывает на VPS, но присутствуют предупреждения (AAAA или CAA таймаут)."
        read -r -p "Продолжить установку, несмотря на предупреждения? [y/N]: " proceed
        case "$proceed" in
            y|Y) run_installation ;;
            *) return 0 ;;
        esac
    else
        echo -e "\n${YELLOW}██████████████████████████████████████████████████████${NC}"
        echo -e "${BOLD}${YELLOW}       ! АВТОМАТИЧЕСКАЯ ПРОВЕРКА DNS НЕ ПОДТВЕРЖДЕНА    ${NC}"
        echo -e "${YELLOW}██████████████████████████████████████████████████████${NC}\n"
        echo -e "• A-запись домена '$target_domain' не обнаружена резолверами или не совпадает с IP сервера ($SERVER_IPV4)."
        echo ""
        echo -e "${BOLD}Возможные причины:${NC}"
        echo "  1. Запись была обновлена недавно на DuckDNS и ещё распространяется по мировым DNS-кэшам."
        echo "  2. Хостинг-провайдер фильтрует исходящие DNS-запросы (порт 53 UDP/TCP) к внешним серверам."
        echo ""
        echo "Если вы уверены, что домен привязан к IP $SERVER_IPV4 на сайте DuckDNS,"
        echo "вы можете подтвердить его принудительно и сразу перейти к установке."
        echo ""
        echo "  1) Подтвердить домен принудительно и продолжить установку"
        echo "  2) Повторить проверку DNS"
        echo "  0) Вернуться в главное меню"
        echo ""
        read -r -p "Выберите действие [0-2]: " fail_choice
        case "$fail_choice" in
            1)
                final_status="READY"
                cat << EOF > "$DOMAIN_CHECK_FILE"
DOMAIN="$target_domain"
SERVER_IPV4="$SERVER_IPV4"
DNS_IPV4="MANUAL_CONFIRMED"
DNS_STATUS="CONFIRMED_BY_USER"
CAA_STATUS="$caa_state"
CHECK_TIMESTAMP="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
CHECK_TIMESTAMP_EPOCH="$(date +%s)"
DOMAIN_STATUS="READY"
EOF
                chmod 600 "$DOMAIN_CHECK_FILE"
                success "Домен '$target_domain' подтверждён принудительно."
                echo ""
                read -r -p "Запустить установку NaïveProxy прямо сейчас? [Y/n]: " proceed
                case "$proceed" in
                    n|N) return 0 ;;
                    *) run_installation ;;
                esac
                ;;
            2)
                run_domain_diagnostics "$target_domain"
                ;;
            *)
                return 1
                ;;
        esac
    fi
}

