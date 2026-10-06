#!/usr/bin/env bash
# ==============================================================================
# NaïveProxy Manager — Модуль Nginx (:80 сайт-заглушка) (nginx.sh)
# ==============================================================================

check_port80_conflict() {
    step "1/7" "Проверка доступности порта 80 (TCP :80)"
    local p80_info
    p80_info=$(get_port_owner 80)
    if [ -n "$p80_info" ]; then
        local proc="${p80_info%% *}" pid="${p80_info##* }"
        if [ "$proc" = "nginx" ]; then
            success "Порт 80 уже используется Nginx (PID $pid) — штатно для сайта-заглушки."
            return 0
        else
            error "Порт 80 занят процессом '$proc' (PID $pid)!"
            error "Служба не является Nginx. NaïveProxy требует освободить порт 80 перед продолжением."
            return 1
        fi
    fi
    success "Порт 80 свободен для Nginx."
    return 0
}

detect_existing_nginx_site() {
    local custom_site_found=false
    local active_sites=()
    if [ -d /etc/nginx/sites-enabled ]; then
        for f in /etc/nginx/sites-enabled/*; do
            [ -e "$f" ] || continue
            local bname
            bname=$(basename "$f")
            active_sites+=("$bname")
            if [ "$bname" != "default" ] && [ "$bname" != "naiveproxy-stub" ]; then
                custom_site_found=true
            fi
        done
    fi
    if [ "$custom_site_found" = true ]; then
        echo "CUSTOM:${active_sites[*]}"
    elif [ -e /etc/nginx/sites-enabled/naiveproxy-stub ]; then
        echo "STUB"
    elif [ -e /etc/nginx/sites-enabled/default ]; then
        echo "DEFAULT"
    else
        echo "NONE"
    fi
}

validate_nginx() {
    if nginx -t >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

nginx_status() {
    if systemctl is-active --quiet nginx 2>/dev/null; then
        echo "RUNNING"
    else
        echo "INACTIVE"
    fi
}

ensure_nginx() {
    if ! command -v nginx &>/dev/null; then
        info "Установка Nginx..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq || true
        apt-get install -y -qq nginx >/dev/null || { error "Ошибка установки Nginx."; return 1; }
        success "Nginx успешно установлен."
    fi
}

ensure_nginx_stub() {
    step "2/7" "Обеспечение работы Nginx на порту 80 (:80 — существующий сайт или изолированный Stub)"

    ensure_nginx || return 1
    mkdir -p "$NAIVE_DIR"

    # 1. Проверяем наличие активных пользовательских конфигураций на порту 80
    local site_type
    site_type=$(detect_existing_nginx_site)

    if [[ "$site_type" == CUSTOM:* ]]; then
        local custom_names="${site_type#CUSTOM:}"
        info "Обнаружен активный пользовательский сайт в Nginx ($custom_names)."
        info "Пользовательская конфигурация сохранена без изменений."
        if ! validate_nginx; then
            warn "Обнаружены ошибки синтаксиса в существующей конфигурации Nginx!"
            nginx -t || true
        else
            systemctl is-active --quiet nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
            success "Существующий сайт Nginx активен и обслуживает порт 80."
        fi
        return 0
    fi

    # 2. Если уже активен наш naiveproxy-stub и Nginx работает — не перезаписываем
    if [ "$site_type" = "STUB" ] && systemctl is-active --quiet nginx 2>/dev/null; then
        info "Сайт-заглушка NaïveProxy уже активен на порту 80."
        return 0
    fi

    # 3. Если на чистом сервере активен только дефолтный default или нет сайтов вообще:
    info "Настройка безопасного сайта-заглушки NaïveProxy на порту 80..."
    mkdir -p "$NGINX_STUB_ROOT"
    if [ ! -f "$NGINX_STUB_ROOT/index.html" ]; then
        cat << 'EOF' > "$NGINX_STUB_ROOT/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0d1117; color: #c9d1d9; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
        .box { text-align: center; padding: 40px; background: #161b22; border-radius: 8px; border: 1px solid #30363d; max-width: 480px; }
        .dot { display: inline-block; width: 12px; height: 12px; background: #238636; border-radius: 50%; margin-right: 8px; }
        h1 { font-size: 24px; color: #f0f6fc; margin: 0 0 8px 0; }
        p { font-size: 14px; color: #8b949e; margin: 0; }
    </style>
</head>
<body>
    <div class="box">
        <h1><span class="dot"></span>Welcome</h1>
        <p>Web server is operational.</p>
    </div>
</body>
</html>
EOF
        chmod 644 "$NGINX_STUB_ROOT/index.html"
    fi

    local has_def_srv=false
    if nginx -T 2>/dev/null | grep -Eq 'listen[[:space:]]+.*default_server'; then
        has_def_srv=true
    fi
    local def_listen="listen 80; listen [::]:80;"
    [ "$has_def_srv" = false ] && def_listen="listen 80 default_server; listen [::]:80 default_server;"

    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    cat << EOF > "$NGINX_STUB_CONF"
server {
    $def_listen
    server_name _;
    root $NGINX_STUB_ROOT;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

    # Отключаем дефолтный шаблон, НЕ удаляя сам файл /var/www/html или sites-available/default
    if [ -e /etc/nginx/sites-enabled/default ]; then
        rm -f /etc/nginx/sites-enabled/default
        info "Стандартный sites-enabled/default переключен на naiveproxy-stub."
    fi

    ln -sf "$NGINX_STUB_CONF" "$NGINX_STUB_ENABLED"

    if ! validate_nginx; then
        error "Ошибка валидации конфигурации Nginx! Выполняем откат на default..."
        nginx -t || true
        rm -f "$NGINX_STUB_ENABLED" "$NGINX_STUB_CONF"
        [ -f /etc/nginx/sites-available/default ] && ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
        return 1
    fi

    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || {
        error "Не удалось перезапустить службу Nginx."; return 1;
    }

    success "Сайт-заглушка Nginx успешно развернут и слушает :80."
    return 0
}
