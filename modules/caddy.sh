#!/usr/bin/env bash
# ==============================================================================
# NaïveProxy Manager — Модуль Caddy Web Server (:443 TLS) (caddy.sh)
# ==============================================================================

check_port443_conflict() {
    step "3/7" "Проверка порта 443 (резерв под Caddy NaïveProxy)"
    local p443_info
    p443_info=$(get_port_owner 443)

    if [ -z "$p443_info" ]; then
        success "Порт 443 свободен для Caddy / NaïveProxy."
        return 0
    fi

    local proc="${p443_info%% *}" pid="${p443_info##* }"
    if [ "$proc" = "caddy" ]; then
        success "Порт 443 занят текущим экземпляром Caddy (NaïveProxy)."
        return 0
    fi

    if [ "$proc" = "nginx" ]; then
        warn "Порт 443 занят Nginx (PID $pid). Для работы NaïveProxy порт 443 должен принадлежать Caddy."
        info "Поиск конфигураций Nginx с директивой 'listen 443'..."
        local n443_sites=()
        if [ -d /etc/nginx/sites-enabled ]; then
            for f in /etc/nginx/sites-enabled/*; do
                [ -e "$f" ] || continue
                if grep -qiE 'listen[[:space:]]+.*443' "$f" 2>/dev/null; then
                    n443_sites+=("$f")
                fi
            done
        fi

        if [ "${#n443_sites[@]}" -gt 0 ]; then
            echo -e "${YELLOW}Обнаружены активные сайты Nginx на порту 443:${NC}"
            for s in "${n443_sites[@]}"; do echo "  • $s"; done
            read -r -p "Временно отключить эти конфигурации Nginx на порту 443? [y/N]: " confirm_dis
            case "$confirm_dis" in
                y|Y)
                    for s in "${n443_sites[@]}"; do
                        local orig_tgt
                        orig_tgt=$(readlink -f "$s" 2>/dev/null || true)
                        [ -n "$orig_tgt" ] && echo "$s|$orig_tgt" >> /etc/naiveproxy/nginx_443_disabled.list
                        rm -f "$s"
                    done
                    if nginx -t >/dev/null 2>&1; then
                        systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
                    fi
                    ;;
                *)
                    error "Установка прервана: порт 443 остаётся занят Nginx."
                    return 1
                    ;;
            esac
        fi
    fi

    # Повторная проверка владельца 443
    local p443_check
    p443_check=$(get_port_owner 443)
    if [ -n "$p443_check" ] && [[ "${p443_check%% *}" != "caddy" ]]; then
        error "Порт 443 занят сторонним процессом '${p443_check%% *}' (PID ${p443_check##* })!"
        return 1
    fi
    success "Порт 443 готов для Caddy."
    return 0
}



backup_caddy_config() {
    if [ -f "$CADDY_FILE" ]; then
        cp -a "$CADDY_FILE" "${CADDY_FILE}.bak"
        success "Резервная копия Caddyfile сохранена в ${CADDY_FILE}.bak"
    fi
}

validate_caddyfile() {
    local config_file="${1:-$CADDY_FILE}"
    if [ ! -x "$CADDY_BIN" ]; then
        error "Бинарник Caddy ($CADDY_BIN) не найден."
        return 1
    fi
    "$CADDY_BIN" validate --config "$config_file"
}

reload_caddy() {
    info "Перезагрузка конфигурации Caddy (zero-downtime)..."
    if [ ! -x "$CADDY_BIN" ] || [ ! -f "$CADDY_FILE" ]; then
        error "Caddy не установлен или отсутствует Caddyfile."
        return 1
    fi
    if ! "$CADDY_BIN" validate --config "$CADDY_FILE" >/dev/null 2>&1; then
        error "Ошибка валидации Caddyfile! Перезагрузка отменена."
        "$CADDY_BIN" validate --config "$CADDY_FILE"
        return 1
    fi
    systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null
    if systemctl is-active --quiet caddy; then
        success "Caddy успешно перезагружен."
        return 0
    else
        error "Caddy не активен после перезагрузки! Проверьте логи: journalctl -u caddy -n 50"
        return 1
    fi
}

caddy_status() {
    if systemctl is-active --quiet caddy 2>/dev/null; then
        success "Caddy активен (RUNNING :443)."
        return 0
    else
        warn "Caddy не запущен или не установлен."
        return 1
    fi
}

save_build_info() {
    local target_file="${BUILD_INFO_FILE:-/etc/naiveproxy/build-info}"
    mkdir -p /etc/naiveproxy
    local caddy_ver="" go_ver="" xcaddy_ver="" fp_ver=""
    [ -x "$CADDY_BIN" ] && caddy_ver=$("$CADDY_BIN" version 2>/dev/null | tr -d '\n' || true)
    command -v go &>/dev/null && go_ver=$(go version 2>/dev/null | tr -d '\n' || true)
    local xcaddy_bin="${GOPATH}/bin/xcaddy"
    [ ! -x "$xcaddy_bin" ] && xcaddy_bin=$(command -v xcaddy || true)
    [ -x "$xcaddy_bin" ] && xcaddy_ver=$("$xcaddy_bin" version 2>/dev/null | tr -d '\n' || true)

    if [ -x "$CADDY_BIN" ] && command -v go &>/dev/null; then
        local m_out
        m_out=$(go version -m "$CADDY_BIN" 2>/dev/null || true)
        fp_ver=$(echo "$m_out" | grep -A1 'github.com/caddyserver/forwardproxy' | grep -E '=>' | awk '{print $NF}' || true)
        if [ -z "$fp_ver" ]; then
            fp_ver=$(echo "$m_out" | grep 'github.com/klzgrad/forwardproxy' | awk '{for(i=1;i<=NF;i++) if($i ~ /^v[0-9]/) print $i}' | head -n1 || true)
        fi
    fi

    cat << EOF > "$target_file"
# NaïveProxy + Caddy Build Metadata
CADDY_BUILD_TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
CADDY_VERSION="${caddy_ver:-unknown}"
GO_VERSION="${go_ver:-unknown}"
XCADDY_VERSION="${xcaddy_ver:-unknown}"
FORWARDPROXY_MODULE="github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@naive"
FORWARDPROXY_VERSION="${fp_ver:-naive-master}"
EOF
    chmod 644 "$target_file"
}

rollback_caddy() {
    warn "Выполняем транзакционный откат Caddy..."
    local rolled_back=false
    if [ -f "$CADDY_BAK" ]; then
        mv -f "$CADDY_BAK" "$CADDY_BIN"
        rolled_back=true
    else
        rm -f "$CADDY_BIN"
    fi

    if [ -f "${CADDY_FILE}.bak" ]; then
        mv -f "${CADDY_FILE}.bak" "$CADDY_FILE"
    else
        rm -f "$CADDY_FILE"
    fi

    if [ -f "${BUILD_INFO_FILE}.bak" ]; then
        mv -f "${BUILD_INFO_FILE}.bak" "$BUILD_INFO_FILE"
    else
        rm -f "$BUILD_INFO_FILE"
    fi

    if [ "$rolled_back" = true ]; then
        systemctl restart caddy 2>/dev/null || true
        if systemctl is-active --quiet caddy; then
            success "Откат к предыдущей версии выполнен успешно. Предыдущая служба активна."
        else
            error "Предыдущая служба не запустилась после отката. Проверьте: journalctl -u caddy -n 50"
        fi
    else
        systemctl stop caddy 2>/dev/null || true
        info "Откат завершён: нерабочая установка очищена, система возвращена в исходное состояние."
    fi
}

commit_caddy() {
    rm -f "$CADDY_BAK" "${CADDY_FILE}.bak" "${BUILD_INFO_FILE}.bak"
    rm -rf "$BUILD_ROOT/caddy"
}

build_caddy() {
    step "4/7" "Сборка Caddy с модулем forwardproxy@naive"
    if ! install_golang; then
        error "Сбой установки Go."
        return 1
    fi

    info "Установка / обновление xcaddy (pinned version: ${XCADDY_VERSION})..."
    go install "github.com/caddyserver/xcaddy/cmd/xcaddy@${XCADDY_VERSION}" || {
        warn "Ошибка установки pinned xcaddy, пробуем latest..."
        go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest || { error "Ошибка установки xcaddy."; return 1; }
    }

    local xcaddy_bin="${GOPATH}/bin/xcaddy"
    [ ! -x "$xcaddy_bin" ] && xcaddy_bin=$(command -v xcaddy || true)
    [ ! -x "$xcaddy_bin" ] && { error "xcaddy не найден."; return 1; }

    # Проверка оперативной памяти и Swap перед сборкой
    local mem_total_mb=0 swap_total_mb=0
    if command -v free &>/dev/null; then
        mem_total_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || true)
        swap_total_mb=$(free -m 2>/dev/null | awk '/^Swap:/{print $2}' || true)
        if [ "${mem_total_mb:-0}" -gt 0 ] && [ "${mem_total_mb:-0}" -lt 1500 ] && [ "${swap_total_mb:-0}" -lt 512 ]; then
            info "На VPS мало RAM (${mem_total_mb} MB). Автоматически создаем 2 ГБ Swap для защиты компилятора Go..."
            if fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 2>/dev/null; then
                chmod 600 /swapfile
                mkswap /swapfile >/dev/null 2>&1 || true
                swapon /swapfile >/dev/null 2>&1 || true
                if ! grep -q '/swapfile' /etc/fstab 2>/dev/null; then
                    echo '/swapfile none swap sw 0 0' >> /etc/fstab 2>/dev/null || true
                fi
                success "Swap 2 ГБ успешно создан и активирован."
            fi
        fi
    fi

    local build_dir="$BUILD_ROOT/caddy"
    rm -rf "$build_dir"; mkdir -p "$build_dir"; cd "$build_dir"

    info "Компиляция Caddy с модулем klzgrad/forwardproxy@naive..."
    echo -e "${BLUE}[INFO]${NC} Первая сборка на VPS занимает обычно от 3 до 10 минут (загрузка AST, компиляция зависимостей и статическая линковка)."
    echo -e "${BLUE}[INFO]${NC} Пожалуйста, не закрывайте терминал и не прерывайте процесс (timeout=0s — без принудительного ограничения времени).\n"

    local build_log="$build_dir/build.log"
    "$xcaddy_bin" build \
        --with github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@naive \
        --output "$build_dir/caddy.new" > "$build_log" 2>&1 &
    local build_pid=$!

    local start_time=$(date +%s)
    local spinner=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local spin_idx=0

    while kill -0 "$build_pid" 2>/dev/null; do
        local cur_time=$(date +%s)
        local elapsed=$((cur_time - start_time))
        local mins=$((elapsed / 60))
        local secs=$((elapsed % 60))
        local time_str=$(printf "%02d:%02d" "$mins" "$secs")

        local res_info=""
        local go_pid
        go_pid=$(pgrep -P "$build_pid" -f 'go build' 2>/dev/null | head -n1 || true)
        if [ -n "$go_pid" ]; then
            res_info=$(ps -o %cpu,%mem,rss -p "$go_pid" 2>/dev/null | tail -n1 | awk '{printf "CPU: %s%%, RAM: %s%% (%d MB)", $1, $2, $3/1024}' || true)
        fi
        [ -z "$res_info" ] && res_info="компиляция исходного кода..."

        local spin_char="${spinner[$spin_idx]}"
        spin_idx=$(( (spin_idx + 1) % ${#spinner[@]} ))

        printf "\r${CYAN}%s${NC} ${BOLD}[СБОРКА CADDY]${NC} Прошло: ${BOLD}%s${NC} [%s]   " "$spin_char" "$time_str" "$res_info"
        sleep 2
    done

    wait "$build_pid"
    local build_exit_code=$?
    printf "\r\033[K" # Очистка строки индикатора

    if [ "$build_exit_code" -ne 0 ] || [ ! -f "$build_dir/caddy.new" ]; then
        echo ""
        error "Ошибка компиляции xcaddy (код завершения: $build_exit_code)!"
        echo "──────────────── Последние 25 строк лога сборки ────────────────"
        tail -n 25 "$build_log" 2>/dev/null || true
        echo "─────────────────────────────────────────────────────────────────"
        rm -f "$build_dir/caddy.new"
        return 1
    fi
    chmod 755 "$build_dir/caddy.new"

    info "Проверка наличия модуля forward_proxy в скомпилированном бинарнике..."
    if ! "$build_dir/caddy.new" list-modules 2>/dev/null | grep -q 'http.handlers.forward_proxy'; then
        error "КРИТИЧЕСКАЯ ОШИБКА: Модуль http.handlers.forward_proxy не найден в собранном бинарнике!"
        rm -f "$build_dir/caddy.new"
        return 1
    fi
    success "Модуль http.handlers.forward_proxy успешно подтвержден."
    success "Бинарник Caddy готов к валидации и установке."
    return 0
}

configure_system() {
    step "5/7" "Формирование конфигураций Caddyfile, Systemd и прав доступа"
    local target_domain="$1" user_email="$2" user_login="$3" user_pass="$4"
    local build_dir="$BUILD_ROOT/caddy"

    [ ! -f "$build_dir/caddy.new" ] && { error "Скомпилированный бинарник Caddy не найден ($build_dir/caddy.new)."; return 1; }

    # Пользователь caddy
    if ! id -u caddy &>/dev/null; then
        info "Создание системного пользователя 'caddy'..."
        useradd --system --home-dir /var/lib/caddy --create-home --shell /usr/sbin/nologin --user-group caddy 2>/dev/null || true
    fi

    mkdir -p /var/lib/caddy /var/log/caddy
    chown -R caddy:caddy /var/lib/caddy /var/log/caddy
    chmod 750 /var/lib/caddy /var/log/caddy

    # Fallback-страница для probe_resistance на порту 443
    mkdir -p "$WEB_ROOT"
    cat << 'EOF' > "$WEB_ROOT/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Service Status</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0f172a; color: #94a3b8; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
        .card { text-align: center; padding: 48px; background: #1e293b; border-radius: 12px; border: 1px solid #334155; max-width: 440px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.1); }
        .badge { display: inline-flex; align-items: center; gap: 8px; color: #10b981; font-weight: 500; font-size: 14px; margin-bottom: 16px; background: rgba(16,185,129,0.1); padding: 4px 12px; border-radius: 9999px; }
        .badge-dot { width: 8px; height: 8px; background: #10b981; border-radius: 50%; }
        h1 { font-size: 22px; color: #f8fafc; margin: 0 0 8px 0; font-weight: 600; }
        p { font-size: 14px; line-height: 1.5; margin: 0; }
    </style>
</head>
<body>
    <div class="card">
        <div class="badge"><span class="badge-dot"></span>Secure Gateway</div>
        <h1>Service Operational</h1>
        <p>This endpoint is active and operating normally.</p>
    </div>
</body>
</html>
EOF
    chown -R caddy:caddy "$WEB_ROOT"
    chmod 755 "$WEB_ROOT"
    chmod 644 "$WEB_ROOT/index.html"

    # Права на /etc/caddy
    mkdir -p "$CADDY_CONF_DIR"
    chown root:caddy "$CADDY_CONF_DIR"
    chmod 750 "$CADDY_CONF_DIR"

    # 1. Генерация нового Caddyfile во временном файле для предварительной валидации
    local test_caddyfile="$build_dir/Caddyfile.test"
    cat << EOF > "$test_caddyfile"
{
    order forward_proxy before file_server
    auto_https disable_redirects
    email $user_email

    log {
        exclude http.log.error
    }
}

:443, $target_domain {
    tls $user_email

    @admin path /admin /admin/*
    handle @admin {
        uri strip_prefix /admin
        reverse_proxy 127.0.0.1:$WEB_PORT
    }

    handle {
        forward_proxy {
            basic_auth $user_login $user_pass
            hide_ip
            hide_via
            probe_resistance
        }

        file_server {
            root $WEB_ROOT
        }
    }
}
EOF

    info "Валидация нового Caddyfile новым бинарником ДО применения в систему..."
    if ! "$build_dir/caddy.new" validate --config "$test_caddyfile" >/dev/null 2>&1; then
        error "Ошибка валидации сформированного Caddyfile!"
        "$build_dir/caddy.new" validate --config "$test_caddyfile"
        rm -f "$test_caddyfile"
        return 1
    fi
    success "Новый Caddyfile успешно прошёл валидацию синтаксиса."

    # 2. Атомарное сохранение резервных копий текущей рабочей установки
    if [ -f "$CADDY_BIN" ]; then
        cp -a "$CADDY_BIN" "$CADDY_BAK"
    fi
    if [ -f "$CADDY_FILE" ]; then
        cp -a "$CADDY_FILE" "${CADDY_FILE}.bak"
    fi
    if [ -f "$BUILD_INFO_FILE" ]; then
        cp -a "$BUILD_INFO_FILE" "${BUILD_INFO_FILE}.bak"
    fi

    # 3. Атомарное применение нового бинарника и конфигурации
    info "Установка бинарника в $CADDY_BIN..."
    cp -a "$build_dir/caddy.new" "$CADDY_BIN"
    chmod 755 "$CADDY_BIN"

    info "Установка конфигурации в $CADDY_FILE..."
    cp -a "$test_caddyfile" "$CADDY_FILE"
    chown root:caddy "$CADDY_FILE"
    chmod 640 "$CADDY_FILE"
    rm -f "$test_caddyfile"
    save_build_info
    success "Caddyfile сформирован: $CADDY_FILE (права 640 root:caddy)"

    # 4. Защищенный systemd-юнит (без зависимости от nginx)
    cat << EOF > "$CADDY_SERVICE"
[Unit]
Description=Caddy Web Server with NaïveProxy
Documentation=https://caddyserver.com/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
Environment=XDG_DATA_HOME=/var/lib/caddy
Environment=XDG_CONFIG_HOME=/etc/caddy
ExecStart=$CADDY_BIN run --environ --config $CADDY_FILE
ExecReload=$CADDY_BIN reload --config $CADDY_FILE --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$CADDY_SERVICE"
    systemctl daemon-reload
    success "Systemd служба зарегистрирована: caddy.service"

    # Сохранение реквизитов (права 600)
    mkdir -p "$NAIVE_DIR"
    cat << EOF > "$CREDS_FILE"
DOMAIN="$target_domain"
EMAIL="$user_email"
USERNAME="$user_login"
PASSWORD="$user_pass"
PORT="443"
CREATED_AT="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
EOF
    chmod 600 "$CREDS_FILE"

    # Инициализация базы пользователей users.json
    python3 - "$USERS_FILE" "$user_login" "$user_pass" << 'EOF_PY'
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
    sync_caddy_users 2>/dev/null || true

    cat << EOF > "$CLIENT_CONFIG"
{
  "listen": "socks://127.0.0.1:1080",
  "proxy": "https://${user_login}:${user_pass}@${target_domain}"
}
EOF
    chmod 600 "$CLIENT_CONFIG"
    chmod 775 "$NAIVE_DIR" 2>/dev/null || true; chown root:naive-web "$NAIVE_DIR" 2>/dev/null || true
    setup_motd

    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow 80/tcp comment 'Nginx HTTP Stub' >/dev/null || true
        ufw allow 443/tcp comment 'Caddy NaiveProxy' >/dev/null || true
        success "UFW правила 80/tcp и 443/tcp добавлены."
    fi

    return 0
}

start_and_verify() {
    step "6/7" "Многоступенчатая верификация Caddy, TLS и NaïveProxy"
    local target_domain="$1" user_login="${2:-}" user_pass="${3:-}"

    info "1. Валидация Caddyfile..."
    if ! "$CADDY_BIN" validate --config "$CADDY_FILE" >/dev/null 2>&1; then
        error "Ошибка валидации Caddyfile!"
        "$CADDY_BIN" validate --config "$CADDY_FILE"
        return 1
    fi
    success "Конфигурация валидна."

    info "2. Запуск caddy.service..."
    systemctl enable caddy >/dev/null 2>&1
    systemctl restart caddy
    sleep 3

    if ! systemctl is-active --quiet caddy; then
        error "Служба Caddy не запустилась. Логи:"
        journalctl -u caddy --no-pager -n 25
        return 1
    fi
    success "Caddy активен (RUNNING)."

    info "3. Проверка сокета порта 443..."
    local p443_check
    p443_check=$(get_port_owner 443)
    if [[ "${p443_check%% *}" == "caddy" ]]; then
        success "Порт 443 слушается Caddy (PID ${p443_check##* })."
    else
        error "Порт 443 не принадлежит Caddy! Текущий владелец: '${p443_check:-none}'."
        return 1
    fi

    info "4. Проверка модуля forward_proxy в запущенном процессе..."
    if "$CADDY_BIN" list-modules 2>/dev/null | grep -q 'http.handlers.forward_proxy'; then
        success "Модуль forward_proxy активен."
    else
        error "Модуль forward_proxy отсутствует в установленном Caddy!"
        return 1
    fi

    info "5. Проверка probe_resistance (fallback-страница для $target_domain на порту 443)..."
    local probe_ok=false
    local hcode
    hcode=$(curl -sk -m 4 --resolve "${target_domain}:443:127.0.0.1"         -o /tmp/naiveprobe.html -w '%{http_code}' "https://${target_domain}" 2>/dev/null || true)
    if [ "$hcode" = "200" ] && grep -qiE "Service Operational|Service Status" /tmp/naiveprobe.html 2>/dev/null; then
        probe_ok=true
    fi
    rm -f /tmp/naiveprobe.html
    [ "$probe_ok" = true ] && success "Fallback-страница probe_resistance отвечает (HTTP 200, Service Operational)." || warn "Fallback-страница пока не ответила HTTP 200."

    info "6. Проверка выпуска и валидности TLS сертификата..."
    local tls_out tls_stat tls_iss tls_host tls_left tls_exp
    tls_out=$(verify_tls_certificate "$target_domain")
    IFS='|' read -r tls_stat tls_iss tls_host tls_left tls_exp <<< "$tls_out"

    if [ "$tls_stat" = "VALID" ]; then
        success "TLS сертификат проверен системным хранилищем CA ($tls_iss, осталось $tls_left дн.)!"
    elif [ "$tls_stat" = "PENDING" ]; then
        warn "Сертификат Let's Encrypt в процессе выпуска (ACME TLS-ALPN-01)."
    else
        warn "TLS сертификат: $tls_stat ($tls_iss, host: $tls_host)."
    fi

    # 7. Информационный тест сквозного туннелирования (не блокирует установку)
    info "7. Проверка туннелирования NaïveProxy (локальный end-to-end тест)..."
    PROXY_TUNNEL_STATUS="NOT_VERIFIED"
    if [ -n "$user_login" ] && [ -n "$user_pass" ]; then
        local pcode
        pcode=$(curl -s -m 8 -x "https://${user_login}:${user_pass}@${target_domain}:443"             --resolve "${target_domain}:443:127.0.0.1" -k             -o /dev/null -w "%{http_code}" "http://connectivitycheck.gstatic.com/generate_204" 2>/dev/null || true)
        if [[ "$pcode" =~ ^(204|200)$ ]]; then
            PROXY_TUNNEL_STATUS="VERIFIED"
            success "Сквозной туннель подтверждён локально (код $pcode)!"
        fi
    fi

    if [ "$PROXY_TUNNEL_STATUS" = "VERIFIED" ]; then
        info "Статус NaïveProxy CONNECT: VERIFIED (local)"
    else
        info "Статус NaïveProxy CONNECT: NOT VERIFIED (проверьте с клиентского устройства)."
    fi

    # Сохраняем актуальный PROXY_TUNNEL_STATUS в CREDS_FILE
    if [ -f "$CREDS_FILE" ]; then
        if grep -q '^PROXY_TUNNEL_STATUS=' "$CREDS_FILE"; then
            sed -i "s/^PROXY_TUNNEL_STATUS=.*/PROXY_TUNNEL_STATUS="$PROXY_TUNNEL_STATUS"/" "$CREDS_FILE"
        else
            echo "PROXY_TUNNEL_STATUS="$PROXY_TUNNEL_STATUS"" >> "$CREDS_FILE"
        fi
    fi

    chmod 600 "$CREDS_FILE" 2>/dev/null || true
    chmod 600 "$CLIENT_CONFIG" 2>/dev/null || true
    return 0
}
