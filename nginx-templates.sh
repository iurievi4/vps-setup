#!/usr/bin/env bash
###############################################################################
# NGINX TEMPLATE & SECURITY MANAGER
#
# Ключевые возможности:
#   1. 6 готовых нейтральных шаблонов сайтов-маскировок (архив, медиа,
#      новости, документация, корпоративный, минимальный).
#   2. Изоляция сайта и прокси:
#      - Сайт управляется через: /etc/nginx/sites-available/00-site.conf
#      - Прокси управляются через: /etc/nginx/sites-available/proxy-*.conf
#      - Смена шаблона сайта НИКОГДА не затирает и не сбрасывает proxy Xray/3x-ui!
#   3. Автоматический backup перед каждым изменением (/etc/nginx/backups/).
#   4. Предварительная проверка 'nginx -t' ДО применения кандидатов.
#   5. Безопасный reload (systemctl reload nginx) без обрыва соединений.
#   6. Стандартные robots.txt, favicon.ico/svg, страницы 404/50x для всех шаблонов.
#   7. Поддержка указания персонального домена или универсального _.
#   8. Отдельные режимы Reverse Proxy (HTTP и WebSocket/3x-ui).
#   9. Глобальные Security Headers и ACME webroot для Let's Encrypt.
#  10. Просмотр текущей конфигурации и быстрое восстановление последнего бэкапа.
###############################################################################

set -Eeuo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "❌ Этот скрипт необходимо запускать от root (sudo)." >&2
    exit 1
fi

NGINX_CONF_DIR="/etc/nginx"
SITES_AVAIL="${NGINX_CONF_DIR}/sites-available"
SITES_ENABL="${NGINX_CONF_DIR}/sites-enabled"
CONF_D="${NGINX_CONF_DIR}/conf.d"
SNIPPETS_D="${NGINX_CONF_DIR}/snippets"
BACKUP_DIR="${NGINX_CONF_DIR}/backups"
WWW_ROOT="/var/www"
ACME_DIR="${WWW_ROOT}/acme"
DEFAULT_HTML_DIR="${WWW_ROOT}/html"

# GitHub-репозиторий с готовыми HTML-шаблонами
TEMPLATE_REPO="${TEMPLATE_REPO:-https://github.com/iurievi4/vps-setup.git}"
TEMPLATE_ROOT="nginx/templates"
TEMPLATE_CACHE="/tmp/nginx-template-repo"

# Реальные каталоги шаблонов в GitHub (nginx/templates/)
TEMPLATE_503="503 error pages"
TEMPLATE_CLOUD="filecloud"
TEMPLATE_DOWNLOAD="downloader"
TEMPLATE_FILE_CONVERTER="converter"
TEMPLATE_GAMES="games-site"
TEMPLATE_MEMES="10gag"
TEMPLATE_MOD_MANAGER="modmanager"
TEMPLATE_SPEEDTEST="speedtest"
TEMPLATE_VIDEO_CONVERTER="convertit"
TEMPLATE_YOUTUBE_CAPTCHA="YouTube endless captcha"

mkdir -p "$SITES_AVAIL" "$SITES_ENABL" "$CONF_D" "$SNIPPETS_D" "$BACKUP_DIR" "$ACME_DIR" "$DEFAULT_HTML_DIR"
chmod 755 "$ACME_DIR" "$DEFAULT_HTML_DIR"
chown -R www-data:www-data "$ACME_DIR" 2>/dev/null || true

# Функция универсальной проверки и безопасной инициализации Nginx
ensure_nginx() {
    echo
    log "Проверка состояния Nginx..."

    if command -v nginx >/dev/null 2>&1; then
        local ver
        ver="$(nginx -v 2>&1 | sed 's#nginx version: nginx/##' || echo "установлен")"
        ok "Nginx уже установлен: ${ver}"

        if command -v systemctl >/dev/null 2>&1; then
            if systemctl is-active --quiet nginx 2>/dev/null; then
                ok "Служба Nginx активна и запущена"
            else
                warn "Nginx установлен, но служба не запущена. Запуск..."
                systemctl start nginx 2>/dev/null || true
            fi
        fi

        # Если в sites-enabled есть и cloud-node, и 00-site.conf (или другой шаблон),
        # отключаем заглушку cloud-node в пользу активного шаблона-маскировки
        if [[ -L "${SITES_ENABL}/cloud-node" ]]; then
            if [[ -L "${SITES_ENABL}/00-site.conf" ]] || ls "${SITES_ENABL}"/*.conf 2>/dev/null | grep -vq "/proxy-"; then
                warn "Обнаружена заглушка cloud-node вместе с активным шаблоном сайта."
                warn "Отключение симлинка cloud-node в пользу активного сайта-маскировки..."
                rm -f "${SITES_ENABL}/cloud-node" "${SITES_ENABL}/default" 2>/dev/null || true
            fi
        fi

        # Если всё ещё есть ошибка duplicate default server, устраняем её
        if ! nginx -t >/dev/null 2>&1; then
            local test_out
            test_out="$(nginx -t 2>&1 || true)"
            if echo "$test_out" | grep -q "duplicate default server"; then
                warn "Обнаружен дубликат default_server в sites-enabled. Оставляем только один активный сайт..."
                rm -f "${SITES_ENABL}/cloud-node" "${SITES_ENABL}/default" 2>/dev/null || true
            fi
        fi

        if nginx -t >/tmp/nginx-init-check.log 2>&1; then
            ok "Существующая конфигурация Nginx корректна"
            rm -f /tmp/nginx-init-check.log
        else
            warn "❌ Существующая конфигурация Nginx содержит ошибки:"
            cat /tmp/nginx-init-check.log >&2
            rm -f /tmp/nginx-init-check.log
            warn "⛔ Новые изменения применяться не будут во избежание сбоя."
            return 1
        fi

        return 0
    fi

    log "Nginx не установлен на сервере. Выполняется чистая установка..."

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq nginx ca-certificates curl >/dev/null 2>&1 || {
        die "Не удалось установить пакет Nginx через apt-get."
    }

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable nginx 2>/dev/null || true
        systemctl start nginx 2>/dev/null || true
    fi

    mkdir -p /var/www/acme/.well-known/acme-challenge
    mkdir -p "${SITES_AVAIL}" "${SITES_ENABL}"

    if [[ ! -f /var/www/acme/index.html ]]; then
        cat > /var/www/acme/index.html <<'EOF_ACME_INDEX'
<!DOCTYPE html>
<html>
<head><title>Cloud Node</title><meta charset="utf-8"></head>
<body style="font-family:sans-serif;background:#0f172a;color:#94a3b8;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;">
<div style="text-align:center;">
<h1 style="color:#e2e8f0;font-size:2rem;margin-bottom:0.5rem;">Cloud Edge Node</h1>
<p style="color:#64748b;font-size:0.95rem;">Status: Active / 200 OK</p>
</div>
</body>
</html>
EOF_ACME_INDEX
    fi

    cat > "${SITES_AVAIL}/cloud-node" <<'EOF_CLOUD_NODE'
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    server_name _;

    root /var/www/acme;
    index index.html index.htm;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/acme;
        default_type "text/plain";
        allow all;
    }

    location / {
        try_files $uri $uri/ =404;
    }
}
EOF_CLOUD_NODE

    rm -f "${SITES_ENABL}/default" 2>/dev/null || true
    ln -sf "${SITES_AVAIL}/cloud-node" "${SITES_ENABL}/cloud-node"

    if nginx -t >/dev/null 2>&1; then
        safe_reload_nginx || true
        ok "Nginx успешно установлен и настроена базовая заглушка cloud-node."
    else
        warn "Предупреждение: Nginx установлен, но проверка конфигурации вернула ошибку."
    fi

    return 0
}
# Цвета и вспомогательные функции
log(){ printf '\n\033[1;32m>>> %s\033[0m\n' "$*"; }
ok(){ printf '  \033[1;32m[OK]\033[0m %s\n' "$*"; }
warn(){ printf '  \033[1;33m[WARN]\033[0m %s\n' "$*"; }
die(){ printf '  \033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

safe_reload_nginx() {
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet nginx; then
            if systemctl reload nginx 2>/dev/null; then
                ok "Nginx успешно перезагружен (systemctl reload — активные соединения сохранены)."
                return 0
            else
                warn "Команда reload вернула ошибку, попытка перезапуска службы..."
                systemctl restart nginx 2>/dev/null || true
                return 0
            fi
        else
            ok "Служба Nginx была остановлена, запуск..."
            systemctl start nginx 2>/dev/null || true
            return 0
        fi
    else
        nginx -s reload 2>/dev/null || nginx 2>/dev/null || true
        return 0
    fi
}

backup_current_config() {
    local timestamp
    timestamp="$(date +%Y%m%d-%H%M%S)"
    local bkp_path="${BACKUP_DIR}/nginx-backup-${timestamp}"
    local root_bkp="/root/nginx-backups/nginx-backup-${timestamp}"
    mkdir -p "$bkp_path" "$root_bkp" 2>/dev/null || true

    for target in "$bkp_path" "$root_bkp"; do
        [[ -d "$target" ]] || continue
        if [[ -d "$SITES_AVAIL" ]]; then cp -a "$SITES_AVAIL" "$target/" 2>/dev/null || true; fi
        if [[ -d "$SITES_ENABL" ]]; then cp -a "$SITES_ENABL" "$target/" 2>/dev/null || true; fi
        if [[ -d "$CONF_D" ]]; then cp -a "$CONF_D" "$target/" 2>/dev/null || true; fi
        if [[ -d "$SNIPPETS_D" ]]; then cp -a "$SNIPPETS_D" "$target/" 2>/dev/null || true; fi
        if [[ -f "${NGINX_CONF_DIR}/nginx.conf" ]]; then cp -a "${NGINX_CONF_DIR}/nginx.conf" "$target/" 2>/dev/null || true; fi
    done
    echo "$bkp_path"
}

# Предварительная проверка сайта или прокси в изолированной песочнице
pretest_candidate_config() {
    local candidate_file="$1"
    local target_filename="${2:-00-site.conf}"

    if ! command -v nginx >/dev/null 2>&1; then
        warn "nginx не найден в PATH, предварительная проверка синтаксиса пропущена."
        return 0
    fi

    local sandbox_dir="/tmp/nginx_pretest_$$"
    mkdir -p "${sandbox_dir}/sites-enabled"

    # В песочницу копируем ТОЛЬКО активные прокси-сервисы (proxy-*.conf)
    # Старый сайт (00-site.conf, cloud-node и др.) заменяется кандидатом!
    if [[ -d "$SITES_ENABL" ]]; then
        for f in "$SITES_ENABL"/proxy-*.conf; do
            [[ -e "$f" ]] || continue
            cp -P "$f" "${sandbox_dir}/sites-enabled/" 2>/dev/null || true
        done
    fi

    # Добавляем тестируемый сайт в песочницу
    cp "$candidate_file" "${sandbox_dir}/sites-enabled/${target_filename}"

    local temp_nginx_conf="${sandbox_dir}/nginx.conf"
    local log_file="${sandbox_dir}/test.log"
    local ret=0

    if [[ -f "${NGINX_CONF_DIR}/nginx.conf" ]]; then
        if grep -q "sites-enabled" "${NGINX_CONF_DIR}/nginx.conf"; then
            sed -E "s|include[[:space:]]+.*sites-enabled.*|include ${sandbox_dir}/sites-enabled/*;|g" "${NGINX_CONF_DIR}/nginx.conf" > "$temp_nginx_conf"
        elif grep -q "conf\.d" "${NGINX_CONF_DIR}/nginx.conf"; then
            sed -E "s|include[[:space:]]+.*conf\.d.*|include ${sandbox_dir}/sites-enabled/*;
    include ${CONF_D}/*.conf;|g" "${NGINX_CONF_DIR}/nginx.conf" > "$temp_nginx_conf"
        else
            awk -v inc="    include ${sandbox_dir}/sites-enabled/*;" '/http[[:space:]]*\{/ {print; print inc; next} 1' "${NGINX_CONF_DIR}/nginx.conf" > "$temp_nginx_conf"
        fi
    else
        cat > "$temp_nginx_conf" <<EOF_TEST_MAIN
events { worker_connections 1024; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    include ${sandbox_dir}/sites-enabled/*;
}
EOF_TEST_MAIN
    fi

    if nginx -p "${NGINX_CONF_DIR}" -t -c "$temp_nginx_conf" > "$log_file" 2>&1; then
        rm -rf "$sandbox_dir"
        return 0
    else
        warn "Ошибка синтаксиса в конфигурации кандидата:"
        cat "$log_file" >&2
        rm -rf "$sandbox_dir"
        return 1
    fi
}

deploy_site_template() {
    local tpl_title="$1"
    local candidate_conf="$2"
    local site_name="${3:-00-site}"

    echo
    echo "======================================================================"
    echo "  🚀 АКТИВАЦИЯ САЙТА-МАСКИРОВКИ: ${tpl_title}"
    echo "======================================================================"
    echo

    # 1. ПРЕДВАРИТЕЛЬНАЯ ПРОВЕРКА В ПЕСОЧНИЦЕ (nginx -t ДО применения)
    log "[1/4] 🔍 Проверка совместимости с активными proxy (nginx -t в sandbox)..."
    if ! pretest_candidate_config "$candidate_conf" "00-site.conf"; then
        rm -f "$candidate_conf"
        echo
        warn "❌ [ERROR] Шаблон '${tpl_title}' не прошёл синтаксическую проверку!"
        warn "🛡️ [ROLLBACK] Рабочая конфигурация Nginx не изменена, proxy работают в штатном режиме."
        return 1
    fi
    ok "Предварительная проверка пройдена (nginx -t: syntax is ok, test is successful)"

    # 2. BACKUP
    log "[2/4] 💾 Создание полной резервной копии конфигурации Nginx..."
    local bkp_path
    bkp_path="$(backup_current_config)"
    ok "Резервная копия создана: ${bkp_path}"

    # 3. ПРИМЕНЕНИЕ (активирует сайт как default_server, отключая старый сайт / cloud-node)
    log "[3/4] ⚙️  Активация сайта на :80 как default_server (прокси НЕ затрагиваются)..."
    local target_avail="${SITES_AVAIL}/00-site.conf"
    local target_enabl="${SITES_ENABL}/00-site.conf"

    # Сохраняем именованную копию в sites-available для удобства
    if [[ -n "$site_name" && "$site_name" != "00-site" ]]; then
        local named_avail="${SITES_AVAIL}/${site_name}.conf"
        cp "$candidate_conf" "$named_avail" 2>/dev/null || true
    fi

    # Сохраняем в 00-site.conf
    cp "$candidate_conf" "$target_avail"
    rm -f "$candidate_conf"

    # Отключаем старый сайт и cloud-node из sites-enabled (ТОЛЬКО сайты, proxy-*.conf НЕ трогаем!)
    if [[ -d "$SITES_ENABL" ]]; then
        for f in "$SITES_ENABL"/*; do
            [[ -e "$f" || -L "$f" ]] || continue
            local bname="$(basename "$f")"
            if [[ "$bname" != proxy-* ]]; then
                rm -f "$f"
            fi
        done
    fi

    # Активируем новый сайт
    ln -sf "$target_avail" "$target_enabl"
    ok "Сайт активирован: ${target_enabl} (порт 80 default_server)"

    # 4. ФИНАЛЬНАЯ ПРОВЕРКА И АВТОМАТИЧЕСКИЙ ОТКАТ
    log "[4/4] 🔍 Финальная проверка боевой конфигурации (nginx -t)..."
    if command -v nginx >/dev/null 2>&1; then
        if ! nginx -t >/tmp/nginx-post-test.log 2>&1; then
            warn "❌ [ERROR] Финальная проверка 'nginx -t' не прошла!"
            cat /tmp/nginx-post-test.log >&2
            rm -f /tmp/nginx-post-test.log

            warn "🛡️ [ROLLBACK] Выполняется автоматический откат к исходной конфигурации..."
            rm -rf "$SITES_AVAIL" "$SITES_ENABL"
            cp -a "${bkp_path}/sites-available" "$SITES_AVAIL"
            cp -a "${bkp_path}/sites-enabled" "$SITES_ENABL"

            safe_reload_nginx || true
            die "[ROLLBACK] Исходная конфигурация восстановлена. Изменения отменены."
        fi
        rm -f /tmp/nginx-post-test.log
        ok "Финальная проверка Nginx пройдена успешно."
    fi

    # 5. SAFE RELOAD БЕЗ ОБРЫВА СОЕДИНЕНИЙ
    log "🔄 Безопасная перезагрузка Nginx (systemctl reload)..."
    safe_reload_nginx

    echo
    echo "──────────────────────────────────────────────────────────────────────"
    echo -e "  [1;32m✔ УСПЕШНО![0m Активный сайт-маскировка заменён на: ${tpl_title}."
    echo "  🌐 Доступен прямо по IP: http://IP_СЕРВЕРА/ (порт 80 default_server)"
    echo "  📁 Конфигурация: ${target_enabl}"
    echo "  🛡️ Все proxy-сервисы (sites-enabled/proxy-*.conf) работают без изменений."
    echo "──────────────────────────────────────────────────────────────────────"
    return 0
}

deploy_proxy_config() {
    local proxy_name="$1"
    local proxy_title="$2"
    local candidate_conf="$3"
    local conf_filename="proxy-${proxy_name}.conf"

    echo
    echo "======================================================================"
    echo "  🔌 НАСТРОЙКА PROXY: ${proxy_title}"
    echo "======================================================================"
    echo

    # 1. ПРОВЕРКА
    log "[1/4] 🔍 Проверка синтаксиса proxy (nginx -t) ДО применения..."
    if ! pretest_candidate_config "$candidate_conf" "$conf_filename"; then
        rm -f "$candidate_conf"
        warn "❌ ОШИБКА: Proxy-конфигурация НЕ прошла проверку синтаксиса!"
        warn "🛡️  Рабочая конфигурация НЕ изменена, сайт и proxy не затронуты."
        return 1
    fi
    ok "Синтаксис проверен (nginx -t: ok)"

    # 2. BACKUP
    log "[2/4] 💾 Автоматическое резервное копирование..."
    local bkp_path
    bkp_path="$(backup_current_config)"
    ok "Резервная копия создана: ${bkp_path}"

    # 3. ПРИМЕНЕНИЕ
    log "[3/4] ⚙️  Активация proxy-конфигурации ${conf_filename}..."
    cp "$candidate_conf" "${SITES_AVAIL}/${conf_filename}"
    rm -f "$candidate_conf"
    ln -sf "${SITES_AVAIL}/${conf_filename}" "${SITES_ENABL}/${conf_filename}"
    ok "Символическая ссылка создана: ${SITES_ENABL}/${conf_filename}"

    if command -v nginx >/dev/null 2>&1; then
        if ! nginx -t >/tmp/nginx-proxy-post.log 2>&1; then
            warn "Ошибка при финальной проверке proxy! Автооткат..."
            cat /tmp/nginx-proxy-post.log >&2
            rm -f /tmp/nginx-proxy-post.log "${SITES_ENABL}/${conf_filename}" "${SITES_AVAIL}/${conf_filename}"
            safe_reload_nginx || true
            die "Proxy не применён из-за ошибки синтаксиса."
        fi
        rm -f /tmp/nginx-proxy-post.log
    fi
    ok "Финальная проверка Nginx пройдена"

    # 4. SAFE RELOAD
    log "[4/4] 🔄 Безопасная перезагрузка Nginx..."
    safe_reload_nginx

    echo
    echo "──────────────────────────────────────────────────────────────────────"
    echo -e "  \033[1;32m✔ УСПЕШНО!\033[0m Proxy '${proxy_title}' активирован."
    echo "  📁 Файл proxy      : ${SITES_AVAIL}/${conf_filename}"
    echo "  🌐 Сайт-маскировка : НЕ затронут (продолжает работать)"
    echo "  💾 Резервная копия : ${bkp_path}"
    echo "──────────────────────────────────────────────────────────────────────"
    echo
    return 0
}

# Запрос домена у пользователя
ask_domain() {
    local def="${1:-_}"
    local dom=""
    if [[ -r /dev/tty ]]; then
        read -rp "Введите домен для сайта [Enter для '${def}']: " dom </dev/tty || dom=""
    fi
    dom="$(echo "$dom" | tr -d ' ')"
    echo "${dom:-$def}"
}

# Генерация стандартных robots.txt, favicon, 404.html, 50x.html
generate_common_assets() {
    local site_dir="$1"
    local domain="$2"
    local site_title="${3:-System Service}"

    mkdir -p "$site_dir"
    local domain_header="${domain}"
    if [[ "$domain_header" == "_" ]]; then
        domain_header="localhost"
    fi

    # robots.txt (создаём только если нет в шаблоне)
    if [[ ! -f "${site_dir}/robots.txt" ]]; then
        cat > "${site_dir}/robots.txt" <<EOF_ROBOTS
User-agent: *
Allow: /
Disallow: /api/
Disallow: /admin/
Disallow: /private/
Disallow: /internal/
Sitemap: http://${domain_header}/sitemap.xml
EOF_ROBOTS
    fi

    # favicon.svg (векторный значок)
    if [[ ! -f "${site_dir}/favicon.svg" ]]; then
        cat > "${site_dir}/favicon.svg" <<'EOF_FAVICON'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">
  <rect width="32" height="32" rx="6" fill="#0284c7"/>
  <circle cx="16" cy="16" r="8" fill="none" stroke="#ffffff" stroke-width="2.5"/>
  <path d="M8 16h16M16 8a14 14 0 0 1 0 16M16 8a14 14 0 0 0 0 16" fill="none" stroke="#ffffff" stroke-width="1.8"/>
</svg>
EOF_FAVICON
    fi

    # favicon.ico (бинарный ICO)
    if [[ ! -f "${site_dir}/favicon.ico" ]]; then
        printf '\x00\x00\x01\x00\x01\x00\x10\x10\x00\x00\x01\x00\x20\x00\x68\x04\x00\x00\x16\x00\x00\x00' > "${site_dir}/favicon.ico" 2>/dev/null || true
    fi

    # 404.html (страница не найдена)
    if [[ ! -f "${site_dir}/404.html" ]]; then
        cat > "${site_dir}/404.html" <<EOF_404
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>404 - Page Not Found | ${site_title}</title>
    <link rel="icon" type="image/svg+xml" href="/favicon.svg">
    <style>
        :root { --bg: #0f172a; --card: #1e293b; --text: #f8fafc; --muted: #94a3b8; --accent: #38bdf8; }
        body { margin: 0; background: var(--bg); color: var(--text); font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; display: flex; align-items: center; justify-content: center; min-height: 100vh; text-align: center; padding: 1.5rem; box-sizing: border-box; }
        .card { background: var(--card); padding: 3rem 2.5rem; border-radius: 16px; border: 1px solid #334155; max-width: 480px; width: 100%; box-shadow: 0 10px 30px rgba(0,0,0,0.5); }
        h1 { font-size: 4.5rem; margin: 0 0 0.5rem; color: var(--accent); font-weight: 800; line-height: 1; }
        h2 { font-size: 1.4rem; margin: 0 0 1rem; color: var(--text); font-weight: 600; }
        p { color: var(--muted); margin: 0 0 2rem; font-size: 1rem; line-height: 1.6; }
        a { display: inline-block; background: #0284c7; color: white; text-decoration: none; padding: 0.8rem 1.8rem; border-radius: 8px; font-weight: 600; transition: background 0.2s, transform 0.1s; }
        a:hover { background: #0369a1; transform: translateY(-1px); }
    </style>
</head>
<body>
    <div class="card">
        <h1>404</h1>
        <h2>Page Not Found</h2>
        <p>The requested file or resource could not be found on this mirror node.</p>
        <a href="/">Return to Index</a>
    </div>
</body>
</html>
EOF_404
    fi

    # 50x.html (ошибка сервера / техработы)
    if [[ ! -f "${site_dir}/50x.html" && ! -f "${site_dir}/503.html" ]]; then
        cat > "${site_dir}/50x.html" <<EOF_50X
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Server Maintenance | ${site_title}</title>
    <link rel="icon" type="image/svg+xml" href="/favicon.svg">
    <style>
        :root { --bg: #0f172a; --card: #1e293b; --text: #f8fafc; --muted: #94a3b8; --warn: #f59e0b; }
        body { margin: 0; background: var(--bg); color: var(--text); font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; display: flex; align-items: center; justify-content: center; min-height: 100vh; text-align: center; padding: 1.5rem; box-sizing: border-box; }
        .card { background: var(--card); padding: 3rem 2.5rem; border-radius: 16px; border: 1px solid #334155; max-width: 480px; width: 100%; box-shadow: 0 10px 30px rgba(0,0,0,0.5); }
        h1 { font-size: 3.5rem; margin: 0 0 0.5rem; color: var(--warn); font-weight: 800; line-height: 1; }
        h2 { font-size: 1.4rem; margin: 0 0 1rem; color: var(--text); font-weight: 600; }
        p { color: var(--muted); margin: 0 0 2rem; font-size: 1rem; line-height: 1.6; }
        a { display: inline-block; background: #334155; color: white; text-decoration: none; padding: 0.8rem 1.8rem; border-radius: 8px; font-weight: 600; }
        a:hover { background: #475569; }
    </style>
</head>
<body>
    <div class="card">
        <h1>503</h1>
        <h2>Service Temporarily Unavailable</h2>
        <p>The service is undergoing routine maintenance or updates. Please try again in a few moments.</p>
        <a href="/">Refresh</a>
    </div>
</body>
</html>
EOF_50X
    fi

    chmod -R 755 "$site_dir"
}

generate_site_nginx_conf() {
    local domain="$1"
    local site_dir="$2"
    local extra_directives="${3:-}"
    local tpl_title="${4:-Site Template}"

    local server_name_directive=""
    if [[ "$domain" != "_" && -n "$domain" ]]; then
        server_name_directive="server_name ${domain} www.${domain} _;"
    else
        server_name_directive="server_name _;"
    fi

    cat <<EOF_GEN_CONF
# Title: ${tpl_title}
# Auto-generated by Nginx Template & Security Manager
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    ${server_name_directive}

    root ${site_dir};
    index index.html index.htm;

    # Стандартные файлы и системные страницы ошибок
    error_page 404 /404.html;
    location = /404.html {
        root ${site_dir};
        internal;
    }

    error_page 500 502 503 504 /50x.html;
    location = /50x.html {
        root ${site_dir};
        internal;
    }

    location = /favicon.ico {
        root ${site_dir};
        access_log off;
        log_not_found off;
        expires 30d;
    }

    location = /favicon.svg {
        root ${site_dir};
        access_log off;
        log_not_found off;
        expires 30d;
    }

    location = /robots.txt {
        root ${site_dir};
        access_log off;
        log_not_found off;
        expires 30d;
    }

    # Поддержка Let's Encrypt / ACME HTTP-01 challenge
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/acme;
        default_type "text/plain";
        allow all;
    }

    ${extra_directives}

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF_GEN_CONF
}

# 1) 📁 ФАЙЛОВЫЙ АРХИВ (Open Source Mirror & Repository)
###############################################################################
tpl_file_archive() {
    log "Установка шаблона: Файловый архив / Репозиторий"
    local domain
    domain="_"

    local site_dir="${WWW_ROOT}/archive"
    mkdir -p "${site_dir}/packages"

    # Создаём демонстрационные архивные файлы
    truncate -s 12M "${site_dir}/packages/core-runtime-v3.8.tar.gz" 2>/dev/null || true
    truncate -s 4M "${site_dir}/packages/edge-node-x86_64.deb" 2>/dev/null || true
    truncate -s 8M "${site_dir}/packages/database-connector-v1.4.zip" 2>/dev/null || true
    echo "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  core-runtime-v3.8.tar.gz" > "${site_dir}/packages/SHA256SUMS"

    cat > "${site_dir}/index.html" <<'EOF_HTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Open Infrastructure Mirror & File Archive</title>
    <link rel="icon" type="image/svg+xml" href="/favicon.svg">
    <style>
        :root { --bg: #0f172a; --card: #1e293b; --text: #e2e8f0; --accent: #38bdf8; --border: #334155; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, monospace; margin: 0; background: var(--bg); color: var(--text); line-height: 1.5; padding: 2rem; }
        header { border-bottom: 1px solid var(--border); padding-bottom: 1rem; margin-bottom: 2rem; display: flex; justify-content: space-between; align-items: center; }
        .title { font-size: 1.4rem; font-weight: 700; color: var(--accent); }
        .path { color: #94a3b8; font-size: 0.95rem; margin-bottom: 1.5rem; }
        table { width: 100%; border-collapse: collapse; background: var(--card); border-radius: 8px; overflow: hidden; border: 1px solid var(--border); }
        th, td { padding: 0.85rem 1.25rem; text-align: left; }
        th { background: #0b1329; color: #94a3b8; font-weight: 600; border-bottom: 1px solid var(--border); font-size: 0.85rem; }
        tr:not(:last-child) td { border-bottom: 1px solid var(--border); }
        tr:hover td { background: rgba(56, 189, 248, 0.05); }
        a { color: var(--accent); text-decoration: none; font-weight: 500; }
        a:hover { text-decoration: underline; }
        .size { color: #94a3b8; font-family: monospace; }
        .date { color: #64748b; font-size: 0.9rem; }
        footer { margin-top: 3rem; color: #64748b; font-size: 0.85rem; text-align: center; border-top: 1px solid var(--border); padding-top: 1.5rem; }
    </style>
</head>
<body>
    <header>
        <div class="title">📦 Global Mirror Network</div>
        <div style="color: #10b981; font-size: 0.9rem;">● Status: Synced</div>
    </header>
    <div class="path">Index of /packages/public/releases/</div>
    <table>
        <thead>
            <tr><th>File Name</th><th>Size</th><th>Last Modified</th><th>Checksum</th></tr>
        </thead>
        <tbody>
            <tr><td><a href="/packages/core-runtime-v3.8.tar.gz">core-runtime-v3.8.tar.gz</a></td><td class="size">12.4 MB</td><td class="date">2026-09-15 10:24</td><td><a href="/packages/SHA256SUMS">SHA256</a></td></tr>
            <tr><td><a href="/packages/edge-node-x86_64.deb">edge-node-x86_64.deb</a></td><td class="size">4.2 MB</td><td class="date">2026-09-12 18:40</td><td><a href="/packages/SHA256SUMS">SHA256</a></td></tr>
            <tr><td><a href="/packages/database-connector-v1.4.zip">database-connector-v1.4.zip</a></td><td class="size">8.1 MB</td><td class="date">2026-08-30 09:12</td><td><a href="/packages/SHA256SUMS">SHA256</a></td></tr>
            <tr><td><a href="/packages/SHA256SUMS">SHA256SUMS</a></td><td class="size">1.2 KB</td><td class="date">2026-09-15 10:25</td><td>—</td></tr>
        </tbody>
    </table>
    <footer>Public Community Package Distribution Mirror. Bandwidth provided by Tier-1 Transit.</footer>
</body>
</html>
EOF_HTML

    generate_common_assets "$site_dir" "$domain" "Global Mirror Network"

    local extra="
    # Оптимизация для скачивания больших файлов (Range requests)
    max_ranges 512;
    location ~* \.(tar\.gz|zip|deb|rpm|iso|bin|sha256)$ {
        expires 30d;
        add_header Cache-Control \"public, no-transform\";
    }
    "

    local cand_conf="/tmp/cand_site_$$.conf"
    generate_site_nginx_conf "$domain" "$site_dir" "$extra" "archive.conf" > "$cand_conf"
    deploy_site_template "📁 Файловый архив (Open Source Mirror)" "$cand_conf" "archive.conf"
}

###############################################################################
# 2) 🎬 МЕДИААРХИВ (Video/Audio Stream Archive)
###############################################################################
tpl_media_archive() {
    log "Установка шаблона: Медиаархив / Стриминг"
    local domain
    domain="_"

    local site_dir="${WWW_ROOT}/stream"
    mkdir -p "${site_dir}/media"

    cat > "${site_dir}/index.html" <<'EOF_HTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>StreamVault Media Archive</title>
    <link rel="icon" type="image/svg+xml" href="/favicon.svg">
    <style>
        :root { --bg: #090d16; --card: #131b2e; --text: #f1f5f9; --accent: #6366f1; --muted: #94a3b8; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; background: var(--bg); color: var(--text); }
        nav { background: #0f172a; padding: 1rem 2rem; display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #1e293b; }
        .logo { font-size: 1.3rem; font-weight: 700; color: var(--accent); }
        .container { max-width: 1200px; margin: 2rem auto; padding: 0 1.5rem; }
        .hero { background: linear-gradient(135deg, #1e1b4b 0%, #0f172a 100%); border-radius: 16px; padding: 3rem; margin-bottom: 2.5rem; border: 1px solid #312e81; }
        .hero h1 { margin: 0 0 1rem; font-size: 2.2rem; }
        .hero p { color: var(--muted); font-size: 1.1rem; max-width: 600px; margin: 0; }
        .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 1.5rem; }
        .card { background: var(--card); border-radius: 12px; overflow: hidden; border: 1px solid #1e293b; transition: transform 0.2s; }
        .card:hover { transform: translateY(-4px); }
        .thumb { background: #1e293b; height: 160px; display: flex; align-items: center; justify-content: center; font-size: 2.5rem; color: #475569; position: relative; }
        .badge { position: absolute; bottom: 8px; right: 8px; background: rgba(0,0,0,0.75); padding: 2px 6px; border-radius: 4px; font-size: 0.75rem; color: #fff; }
        .info { padding: 1rem; }
        .info h3 { margin: 0 0 0.5rem; font-size: 1rem; font-weight: 600; }
        .info p { margin: 0; font-size: 0.85rem; color: var(--muted); }
        footer { border-top: 1px solid #1e293b; text-align: center; padding: 2rem; color: #475569; font-size: 0.85rem; margin-top: 4rem; }
    </style>
</head>
<body>
    <nav>
        <div class="logo">🎬 StreamVault Studio</div>
        <div style="color: var(--muted); font-size: 0.9rem;">Library Node #412</div>
    </nav>
    <div class="container">
        <div class="hero">
            <h1>Curated Audio & Video Archive</h1>
            <p>High-bitrate digital assets, open recordings, and master media archives for independent creators.</p>
        </div>
        <h2 style="font-size: 1.3rem; margin-bottom: 1rem;">Recent Broadcasts</h2>
        <div class="grid">
            <div class="card">
                <div class="thumb">🎧<span class="badge">48:12</span></div>
                <div class="info">
                    <h3>Deep Tech Podcast — Ep. 104</h3>
                    <p>FLAC Audio Master • 96kHz / 24-bit</p>
                </div>
            </div>
            <div class="card">
                <div class="thumb">🎥<span class="badge">1:24:00</span></div>
                <div class="info">
                    <h3>Keynote Session: Cloud Scaling</h3>
                    <p>H.264 / 1080p60 • Stream Ready</p>
                </div>
            </div>
            <div class="card">
                <div class="thumb">🎙️<span class="badge">32:45</span></div>
                <div class="info">
                    <h3>DevOps Roundtable Discussion</h3>
                    <p>Stereo Master • Opus 160kbps</p>
                </div>
            </div>
            <div class="card">
                <div class="thumb">📡<span class="badge">LIVE</span></div>
                <div class="info">
                    <h3>Global Network Ops Feed</h3>
                    <p>Low Latency Stream Relay</p>
                </div>
            </div>
        </div>
    </div>
    <footer>StreamVault Content Delivery Node • Powered by Nginx Edge Acceleration</footer>
</body>
</html>
EOF_HTML

    generate_common_assets "$site_dir" "$domain" "StreamVault Media"

    local extra="
    # Псевдостриминг видео и аудио (mp4, flac, opus)
    mp4;
    mp4_buffer_size      1m;
    mp4_max_buffer_size  5m;
    location ~* \.(mp4|m4v|mp3|flac|ogg|webm)$ {
        expires 7d;
        add_header Accept-Ranges bytes;
        add_header Cache-Control \"public, no-transform\";
    }
    "

    local cand_conf="/tmp/cand_site_$$.conf"
    generate_site_nginx_conf "$domain" "$site_dir" "$extra" > "$cand_conf"
    deploy_site_template "🎬 Медиаархив (Video / Audio Vault)" "$cand_conf"
}

###############################################################################
# 3) 📰 НОВОСТНОЙ ПОРТАЛ (The TechPulse Journal)
###############################################################################
tpl_news_portal() {
    log "Установка шаблона: Новостной портал"
    local domain
    domain="_"

    local site_dir="${WWW_ROOT}/news"
    mkdir -p "$site_dir"

    cat > "${site_dir}/index.html" <<'EOF_HTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>The TechPulse Journal — Today's Engineering & Global Insights</title>
    <link rel="icon" type="image/svg+xml" href="/favicon.svg">
    <style>
        :root { --bg: #ffffff; --text: #111827; --muted: #4b5563; --border: #e5e7eb; --accent: #dc2626; }
        body { font-family: "Georgia", serif; margin: 0; background: var(--bg); color: var(--text); line-height: 1.6; }
        header { border-bottom: 3px double #111827; padding: 1.5rem 1rem 0.5rem; text-align: center; }
        .brand { font-size: 2.8rem; font-weight: 900; letter-spacing: -1px; text-transform: uppercase; margin: 0; font-family: "Times New Roman", serif; }
        .meta-bar { font-family: sans-serif; font-size: 0.85rem; color: var(--muted); border-top: 1px solid var(--border); border-bottom: 1px solid var(--border); padding: 0.5rem; margin-top: 1rem; display: flex; justify-content: space-between; }
        .container { max-width: 1100px; margin: 2rem auto; padding: 0 1rem; display: grid; grid-template-columns: 2fr 1fr; gap: 2.5rem; }
        article h2 { font-size: 1.8rem; margin: 0 0 0.5rem; line-height: 1.25; }
        article h2 a { color: inherit; text-decoration: none; }
        article h2 a:hover { color: var(--accent); }
        .byline { font-family: sans-serif; font-size: 0.8rem; color: #6b7280; text-transform: uppercase; margin-bottom: 1rem; }
        .lead { font-size: 1.15rem; color: #374151; }
        aside { border-left: 1px solid var(--border); padding-left: 2rem; font-family: sans-serif; }
        aside h3 { font-size: 1rem; text-transform: uppercase; letter-spacing: 1px; border-bottom: 2px solid #111827; padding-bottom: 0.3rem; margin-top: 0; }
        .sidebar-item { margin-bottom: 1.5rem; }
        .sidebar-item h4 { margin: 0 0 0.3rem; font-size: 0.95rem; }
        .sidebar-item time { font-size: 0.75rem; color: #9ca3af; }
        .breaking { background: #fef2f2; border: 1px solid #fee2e2; padding: 0.75rem 1rem; font-family: sans-serif; font-size: 0.9rem; margin-bottom: 1.5rem; border-left: 4px solid var(--accent); }
        footer { border-top: 1px solid var(--border); text-align: center; padding: 2rem; font-family: sans-serif; font-size: 0.8rem; color: var(--muted); margin-top: 3rem; }
    </style>
</head>
<body>
    <header>
        <h1 class="brand">The TechPulse Journal</h1>
        <div class="meta-bar">
            <span>Vol. XLVIII No. 248</span>
            <span>Worldwide Edition • Updated Every Hour</span>
            <span>Editorial Desk: ONLINE</span>
        </div>
    </header>
    <div class="container">
        <main>
            <div class="breaking"><strong>BREAKING:</strong> Global Distributed Networks Report 99.999% Core Routing Stability Amid High-Traffic Season.</div>
            <article>
                <h2><a href="#">The Evolution of Global Routing Protocols in Next-Gen Micro-Datacenters</a></h2>
                <div class="byline">By Julian Vance, Senior Tech Editor • Published 2 Hours Ago</div>
                <p class="lead">As autonomous edge servers handle petabytes of localized telemetry, infrastructure architects are rethinking classic BGP peering models in favor of dynamic overlay networks.</p>
                <p>Telemetry nodes stationed worldwide now process encrypted real-time workloads with sub-millisecond local latencies. This architectural shift significantly alleviates long-haul transit congestion while preserving fault tolerance across multi-regional clusters.</p>
            </article>
        </main>
        <aside>
            <h3>Trending Headlines</h3>
            <div class="sidebar-item">
                <h4>Open Source Cryptographic Framework Reaches Milestone 4.0</h4>
                <time>35 MIN AGO</time>
            </div>
            <div class="sidebar-item">
                <h4>Low-Earth Satellite Constellations Expand Real-Time Coverage</h4>
                <time>1 HOUR AGO</time>
            </div>
            <div class="sidebar-item">
                <h4>Semiconductor Packaging Innovations Boost Compute Efficiency by 40%</h4>
                <time>3 HOURS AGO</time>
            </div>
        </aside>
    </div>
    <footer>© The TechPulse Journal Media Group. All rights reserved. ISSN 2490-8812.</footer>
</body>
</html>
EOF_HTML

    generate_common_assets "$site_dir" "$domain" "The TechPulse Journal"

    local extra="
    # Сжатие текста для новостного портала
    gzip on;
    gzip_types text/plain text/css application/javascript application/json text/xml;
    gzip_min_length 1000;
    "

    local cand_conf="/tmp/cand_site_$$.conf"
    generate_site_nginx_conf "$domain" "$site_dir" "$extra" "news.conf" > "$cand_conf"
    deploy_site_template "📰 Новостной портал (The TechPulse Journal)" "$cand_conf" "news.conf"
}

###############################################################################
# 4) 📚 ТЕХНИЧЕСКАЯ ДОКУМЕНТАЦИЯ (API & Knowledge Base)
###############################################################################
tpl_tech_docs() {
    log "Установка шаблона: Техническая документация"
    local domain
    domain="_"

    local site_dir="${WWW_ROOT}/docs"
    mkdir -p "$site_dir"

    cat > "${site_dir}/index.html" <<'EOF_HTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Core System Architecture — Developer Documentation</title>
    <link rel="icon" type="image/svg+xml" href="/favicon.svg">
    <style>
        :root { --bg: #0d1117; --sidebar: #161b22; --border: #30363d; --text: #c9d1d9; --accent: #58a6ff; --code-bg: #1f242c; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; margin: 0; background: var(--bg); color: var(--text); line-height: 1.6; display: flex; min-height: 100vh; }
        nav { width: 260px; background: var(--sidebar); border-right: 1px solid var(--border); padding: 1.5rem 1rem; box-sizing: border-box; flex-shrink: 0; }
        nav h2 { font-size: 1rem; color: #f0f6fc; margin: 0 0 1rem; }
        nav ul { list-style: none; padding: 0; margin: 0; }
        nav li { margin-bottom: 0.5rem; }
        nav a { color: #8b949e; text-decoration: none; font-size: 0.9rem; }
        nav a:hover, nav a.active { color: var(--accent); }
        main { flex: 1; padding: 3rem 4rem; max-width: 850px; }
        h1 { font-size: 2rem; color: #f0f6fc; border-bottom: 1px solid var(--border); padding-bottom: 0.5rem; margin-top: 0; }
        h2 { font-size: 1.4rem; color: #f0f6fc; margin-top: 2rem; }
        code { background: var(--code-bg); padding: 0.2rem 0.4rem; border-radius: 6px; font-family: monospace; font-size: 0.9em; }
        pre { background: var(--code-bg); border: 1px solid var(--border); border-radius: 8px; padding: 1rem; overflow-x: auto; font-family: monospace; font-size: 0.9rem; }
        .badge { background: #238636; color: white; padding: 0.2rem 0.6rem; border-radius: 12px; font-size: 0.75rem; vertical-align: middle; }
        .callout { border-left: 4px solid var(--accent); background: rgba(88, 166, 255, 0.1); padding: 1rem; border-radius: 0 8px 8px 0; margin: 1.5rem 0; }
    </style>
</head>
<body>
    <nav>
        <h2>Documentation</h2>
        <ul>
            <li><a href="#" class="active">Getting Started</a></li>
            <li><a href="#">Architecture Overview</a></li>
            <li><a href="#">Authentication & Tokens</a></li>
            <li><a href="#">REST API Reference</a></li>
            <li><a href="#">WebSocket Handshake</a></li>
            <li><a href="#">Deployment Guide</a></li>
        </ul>
    </nav>
    <main>
        <h1>System Gateway API <span class="badge">v2.4.0</span></h1>
        <p>Welcome to the core platform technical reference. The gateway coordinates microservice routing, ingress load balancing, and secure telemetry exchange.</p>
        
        <div class="callout">
            <strong>Note:</strong> All requests must authenticate via Bearer token or mutually trusted TLS certificates over port 443.
        </div>

        <h2>Health Check Endpoint</h2>
        <p>To verify node responsiveness and latency:</p>
        <pre><code>GET /api/v2/health HTTP/1.1
Host: api.internal.network
Accept: application/json</code></pre>

        <h3>Sample Response</h3>
        <pre><code>{
  "status": "healthy",
  "node_id": "eu-central-04",
  "uptime_seconds": 184920,
  "load_average": [0.12, 0.08, 0.05]
}</code></pre>
    </main>
</body>
</html>
EOF_HTML

    generate_common_assets "$site_dir" "$domain" "Developer Docs"

    local cand_conf="/tmp/cand_site_$$.conf"
    generate_site_nginx_conf "$domain" "$site_dir" "" > "$cand_conf"
    deploy_site_template "📚 Техническая документация (API & Docs)" "$cand_conf"
}

###############################################################################
# 5) 🏢 КОРПОРАТИВНЫЙ САЙТ (Enterprise B2B Cloud)
###############################################################################
tpl_corporate_site() {
    log "Установка шаблона: Корпоративный B2B-сайт"
    local domain
    domain="_"

    local site_dir="${WWW_ROOT}/corp"
    mkdir -p "$site_dir"

    cat > "${site_dir}/index.html" <<'EOF_HTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>CloudSphere Systems — Resilient Enterprise Cloud Infrastructure</title>
    <link rel="icon" type="image/svg+xml" href="/favicon.svg">
    <style>
        :root { --primary: #2563eb; --dark: #0f172a; --gray: #64748b; --light: #f8fafc; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; color: #1e293b; line-height: 1.5; }
        header { background: #ffffff; border-bottom: 1px solid #e2e8f0; position: sticky; top: 0; z-index: 100; }
        .nav-wrap { max-width: 1200px; margin: 0 auto; display: flex; justify-content: space-between; align-items: center; padding: 1rem 1.5rem; }
        .brand { font-size: 1.4rem; font-weight: 800; color: var(--dark); text-decoration: none; }
        .hero { background: radial-gradient(circle at top right, #1e3a8a, var(--dark)); color: white; padding: 5rem 1.5rem; text-align: center; }
        .hero h1 { font-size: 3rem; max-width: 800px; margin: 0 auto 1.5rem; font-weight: 800; letter-spacing: -0.02em; }
        .hero p { font-size: 1.25rem; color: #94a3b8; max-width: 600px; margin: 0 auto 2rem; }
        .btn { background: var(--primary); color: white; padding: 0.85rem 1.75rem; border-radius: 8px; font-weight: 600; text-decoration: none; display: inline-block; }
        .features { max-width: 1200px; margin: 5rem auto; padding: 0 1.5rem; display: grid; grid-template-columns: repeat(3, 1fr); gap: 2rem; }
        .feat-card { background: #ffffff; border: 1px solid #e2e8f0; border-radius: 12px; padding: 2rem; }
        .feat-card h3 { font-size: 1.25rem; margin-top: 0; color: var(--dark); }
        .feat-card p { color: var(--gray); margin-bottom: 0; }
        .stats { background: #f1f5f9; padding: 3rem 1.5rem; text-align: center; }
        .stats-grid { max-width: 900px; margin: 0 auto; display: grid; grid-template-columns: repeat(3, 1fr); }
        .stat-val { font-size: 2.5rem; font-weight: 800; color: var(--primary); }
        .stat-lbl { color: var(--gray); font-size: 0.9rem; margin-top: 0.25rem; }
        footer { background: var(--dark); color: #94a3b8; padding: 3rem 1.5rem; text-align: center; font-size: 0.9rem; }
    </style>
</head>
<body>
    <header>
        <div class="nav-wrap">
            <a href="#" class="brand">CloudSphere Global</a>
            <div style="font-size: 0.95rem; color: var(--gray);">Enterprise Node Status: Operational</div>
        </div>
    </header>
    <div class="hero">
        <h1>Autonomous Edge Infrastructure for Mission-Critical Data</h1>
        <p>Engineered for high-availability enterprise clusters, encrypted transport layer routing, and seamless global failover.</p>
        <a href="#solutions" class="btn">Explore Solutions</a>
    </div>
    <div class="stats">
        <div class="stats-grid">
            <div><div class="stat-val">99.999%</div><div class="stat-lbl">Uptime SLA Guaranteed</div></div>
            <div><div class="stat-val">&lt; 10ms</div><div class="stat-lbl">Global Edge Latency</div></div>
            <div><div class="stat-val">256-bit</div><div class="stat-lbl">Zero-Trust Encryption</div></div>
        </div>
    </div>
    <div class="features" id="solutions">
        <div class="feat-card">
            <h3>Enterprise Anycast Routing</h3>
            <p>Direct low-latency packets over global tier-1 backbones with dynamic congestion avoidance.</p>
        </div>
        <div class="feat-card">
            <h3>Edge Threat Mitigation</h3>
            <p>Integrated Layer 3/4/7 DDoS mitigation scrubbing centers protect mission-critical operations.</p>
        </div>
        <div class="feat-card">
            <h3>Compliance & Auditing</h3>
            <p>Full SOC2, ISO27001, and HIPAA compatible data transport pipelines for corporate peace of mind.</p>
        </div>
    </div>
    <footer>© CloudSphere Global Networks Inc. All rights reserved.</footer>
</body>
</html>
EOF_HTML

    generate_common_assets "$site_dir" "$domain" "CloudSphere Systems"

    local cand_conf="/tmp/cand_site_$$.conf"
    generate_site_nginx_conf "$domain" "$site_dir" "" > "$cand_conf"
    deploy_site_template "🏢 Корпоративный сайт (Enterprise B2B Cloud)" "$cand_conf"
}

###############################################################################
# 6) 🌐 МИНИМАЛЬНАЯ ЗАГЛУШКА (Clean Cloud Node 200 OK)
###############################################################################
tpl_neutral_stub() {
    log "Установка шаблона: Минимальная заглушка (Clean Cloud Node)"
    local domain
    domain="_"

    local site_dir="${DEFAULT_HTML_DIR}"
    mkdir -p "$site_dir"

    cat > "${site_dir}/index.html" <<'EOF_HTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Cloud Node Active</title>
    <link rel="icon" type="image/svg+xml" href="/favicon.svg">
    <style>
        body { font-family: monospace; background: #000; color: #00ff66; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; }
        .node { border: 1px solid #00ff66; padding: 2rem 3rem; border-radius: 6px; }
    </style>
</head>
<body>
    <div class="node">
        <div>[ NODE SYSTEM READY ]</div>
        <div style="color: #888; font-size: 0.85em; margin-top: 0.5rem;">STATUS: 200 OK • ALL_SYSTEMS_OPERATIONAL</div>
    </div>
</body>
</html>
EOF_HTML

    generate_common_assets "$site_dir" "$domain" "Cloud Node"

    local cand_conf="/tmp/cand_site_$$.conf"
    generate_site_nginx_conf "$domain" "$site_dir" "" > "$cand_conf"
    deploy_site_template "🌐 Минимальная заглушка (Cloud Node 200 OK)" "$cand_conf"
}

###############################################################################
# 7) 🔄 REVERSE PROXY (HTTP Backend) - Изолированный файл
###############################################################################
tpl_reverse_proxy() {
    log "Настройка Reverse Proxy (HTTP backend)"
    echo "  Этот режим создаёт отдельный файл конфигурации в /etc/nginx/sites-available/,"
    echo "  НЕ затрагивая активный сайт-маскировку (00-site.conf)."
    echo

    local p_name="backend"
    local p_domain="_"
    local p_port="80"
    local p_upstream="127.0.0.1:8080"

    if [[ -r /dev/tty ]]; then
        read -rp "Имя proxy-конфигурации [по умолчанию 'backend']: " p_name </dev/tty || p_name="backend"
        p_name="$(echo "$p_name" | tr -d ' ')"
        p_name="${p_name:-backend}"

        read -rp "Домен (server_name) для proxy [по умолчанию '_']: " p_domain </dev/tty || p_domain="_"
        p_domain="$(echo "$p_domain" | tr -d ' ')"
        p_domain="${p_domain:-_}"

        read -rp "Порт Nginx для приёма запросов [по умолчанию '80']: " p_port </dev/tty || p_port="80"
        p_port="${p_port:-80}"

        read -rp "Адрес бэкенда (host:port) [по умолчанию '127.0.0.1:8080']: " p_upstream </dev/tty || p_upstream="127.0.0.1:8080"
        p_upstream="${p_upstream:-127.0.0.1:8080}"
    fi

    local cand_conf="/tmp/cand_proxy_${p_name}_$$.conf"
    cat > "$cand_conf" <<EOF_PROXY
# Auto-generated Reverse Proxy for ${p_name}
server {
    listen ${p_port};
    listen [::]:${p_port};
    server_name ${p_domain};

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/acme;
        default_type "text/plain";
        allow all;
    }

    location / {
        proxy_pass http://${p_upstream};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
EOF_PROXY

    deploy_proxy_config "$p_name" "Reverse Proxy (HTTP -> ${p_upstream})" "$cand_conf"
}

###############################################################################
# 8) 🔌 WEBSOCKET PROXY (3x-ui / Xray / VLESS) - Изолированный файл
###############################################################################
tpl_proxy_websocket() {
    log "Настройка Reverse Proxy + WebSocket (3x-ui / Xray)"
    echo "  Этот режим создаёт отдельный изолированный файл конфигурации,"
    echo "  гарантируя, что proxy не будет удалён при смене шаблона сайта."
    echo

    local p_name="xui"
    local p_domain="_"
    local p_port="8080"
    local p_path="/ws"
    local p_upstream="127.0.0.1:2053"

    if [[ -r /dev/tty ]]; then
        read -rp "Имя proxy-конфигурации [по умолчанию 'xui']: " p_name </dev/tty || p_name="xui"
        p_name="$(echo "$p_name" | tr -d ' ')"
        p_name="${p_name:-xui}"

        read -rp "Домен (server_name) [по умолчанию '_']: " p_domain </dev/tty || p_domain="_"
        p_domain="$(echo "$p_domain" | tr -d ' ')"
        p_domain="${p_domain:-_}"

        read -rp "Порт Nginx [по умолчанию '8080']: " p_port </dev/tty || p_port="8080"
        p_port="${p_port:-8080}"

        read -rp "WebSocket Path [по умолчанию '/ws']: " p_path </dev/tty || p_path="/ws"
        p_path="${p_path:-/ws}"
        [[ "$p_path" != /* ]] && p_path="/${p_path}"

        read -rp "Локальный порт панели/Xray [по умолчанию '127.0.0.1:2053']: " p_upstream </dev/tty || p_upstream="127.0.0.1:2053"
        p_upstream="${p_upstream:-127.0.0.1:2053}"
    fi

    local cand_conf="/tmp/cand_proxy_${p_name}_$$.conf"
    cat > "$cand_conf" <<EOF_WS
# Auto-generated WebSocket Proxy for ${p_name}
server {
    listen ${p_port};
    listen [::]:${p_port};
    server_name ${p_domain};

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/acme;
        default_type "text/plain";
        allow all;
    }

    # Проброс WebSocket соединений для 3x-ui / Xray
    location ${p_path} {
        proxy_pass http://${p_upstream};
        proxy_redirect off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

        # Длительные таймауты против разрыва туннелей
        proxy_connect_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_read_timeout 86400s;
    }

    location / {
        return 404;
    }
}
EOF_WS

    deploy_proxy_config "$p_name" "WebSocket Proxy (${p_path} -> ${p_upstream})" "$cand_conf"
}

###############################################################################
# 9) ❌ УДАЛИТЬ / ОТКЛЮЧИТЬ PROXY-КОНФИГУРАЦИЮ
###############################################################################
remove_proxy_config() {
    log "Управление proxy-конфигурациями"

    local proxy_files=()
    while IFS= read -r f; do
        [[ -n "$f" ]] && proxy_files+=("$f")
    done < <(find "$SITES_AVAIL" -maxdepth 1 -name "proxy-*.conf" 2>/dev/null | sort)

    if [[ "${#proxy_files[@]}" -eq 0 ]]; then
        warn "В ${SITES_AVAIL} не найдено ни одной proxy-конфигурации."
        return 0
    fi

    echo "Найденные proxy-конфигурации:"
    for i in "${!proxy_files[@]}"; do
        local f="${proxy_files[$i]}"
        local bname
        bname="$(basename "$f")"
        local status="[ОТКЛЮЧЕН]"
        if [[ -L "${SITES_ENABL}/${bname}" ]]; then
            status="[АКТИВЕН]"
        fi
        printf "  %d) %-25s %s\n" "$((i+1))" "$bname" "$status"
    done
    echo

    local choice=""
    if [[ -r /dev/tty ]]; then
        read -rp "Выберите номер для отключения/удаления [1-${#proxy_files[@]}]: " choice </dev/tty || choice=""
    fi

    if [[ -z "$choice" || ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#proxy_files[@]} )); then
        die "Некорректный номер."
    fi

    local selected="${proxy_files[$((choice-1))]}"
    local bname
    bname="$(basename "$selected")"

    log "Создание бэкапа перед удалением proxy..."
    backup_current_config >/dev/null

    rm -f "${SITES_ENABL}/${bname}" "${SITES_AVAIL}/${bname}"
    ok "Файл ${bname} удалён из sites-available и sites-enabled."

    if nginx -t >/tmp/nginx-rem-test.log 2>&1; then
        safe_reload_nginx
        ok "Nginx успешно перезагружен после удаления proxy."
    else
        warn "Ошибка при проверке после удаления!"
        cat /tmp/nginx-rem-test.log >&2
    fi
    rm -f /tmp/nginx-rem-test.log
}

###############################################################################
# 10) 🔐 ACME / LET'S ENCRYPT (WEBROOT CHALLENGE)
###############################################################################
tpl_acme_setup() {
    echo
    echo "======================================================================"
    echo "  🔐 НАСТРОЙКА ACME / LET'S ENCRYPT (WEBROOT CHALLENGE)"
    echo "======================================================================"
    echo

    mkdir -p "$SNIPPETS_D" "$ACME_DIR"
    chmod 755 "$ACME_DIR"
    chown -R www-data:www-data "$ACME_DIR" 2>/dev/null || true

    local cand_snippet="/tmp/cand_acme_$$.conf"
    cat > "$cand_snippet" <<'EOF_ACME'
# Let's Encrypt / ACME HTTP-01 webroot challenge snippet
location ^~ /.well-known/acme-challenge/ {
    default_type "text/plain";
    root /var/www/acme;
    allow all;
}
EOF_ACME

    log "[1/4] 🔍 Проверка директории ACME..."
    echo "acme-verify-token-ok" > "${ACME_DIR}/test-challenge.txt"
    ok "Директория ${ACME_DIR} готова и доступна"

    log "[2/4] 💾 Автоматическое резервное копирование..."
    local bkp_path
    bkp_path="$(backup_current_config)"
    ok "Резервная копия создана: ${bkp_path}"

    log "[3/4] ⚙️  Установка сниппета в ${SNIPPETS_D}/acme-challenge.conf..."
    cp "$cand_snippet" "${SNIPPETS_D}/acme-challenge.conf"
    rm -f "$cand_snippet"

    if command -v nginx >/dev/null 2>&1; then
        if ! nginx -t >/tmp/nginx-acme-test.log 2>&1; then
            warn "Ошибка синтаксиса при проверке ACME:"
            cat /tmp/nginx-acme-test.log >&2
            rm -f /tmp/nginx-acme-test.log "${SNIPPETS_D}/acme-challenge.conf"
            die "Отмена настройки ACME."
        fi
        rm -f /tmp/nginx-acme-test.log
    fi
    ok "Сниппет ACME успешно установлен и проверен"

    log "[4/4] 🔄 Безопасная перезагрузка Nginx..."
    safe_reload_nginx
    ok "Nginx перезагружен. Модуль ACME активен во всех шаблонах."
    echo
    echo "  Для выпуска SSL-сертификата выполните:"
    echo "    certbot certonly --webroot -w ${ACME_DIR} -d yourdomain.com"
    echo "  или через acme.sh:"
    echo "    acme.sh --issue -d yourdomain.com -w ${ACME_DIR}"
    echo
}

###############################################################################
# 11) 🛡️ SECURITY HEADERS (Глобальные защитные заголовки)
###############################################################################
tpl_security_headers() {
    echo
    echo "======================================================================"
    echo "  🛡️ АКТИВАЦИЯ ЗАГОЛОВКОВ БЕЗОПАСНОСТИ (SECURITY HEADERS)"
    echo "======================================================================"
    echo

    local cand_headers="/tmp/cand_security_headers_$$.conf"
    cat > "$cand_headers" <<'EOF_SEC'
# Глобальные защитные HTTP-заголовки
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "geolocation=(), camera=(), microphone=()" always;
EOF_SEC

    log "[1/4] 🔍 Проверка синтаксиса заголовков безопасности..."
    # Тестируем заголовок во временном конфиге
    local test_conf="/tmp/sec_test_$$.conf"
    cat > "$test_conf" <<EOF_TEST_SEC
events { worker_connections 1024; }
http {
    include ${cand_headers};
}
EOF_TEST_SEC

    if ! nginx -t -c "$test_conf" >/tmp/sec_test.log 2>&1; then
        warn "Ошибка в заголовках безопасности:"
        cat /tmp/sec_test.log >&2
        rm -f "$cand_headers" "$test_conf" /tmp/sec_test.log
        die "Отмена применения заголовков."
    fi
    rm -f "$test_conf" /tmp/sec_test.log
    ok "Синтаксис заголовков проверен"

    log "[2/4] 💾 Автоматическое резервное копирование..."
    local bkp_path
    bkp_path="$(backup_current_config)"
    ok "Резервная копия создана: ${bkp_path}"

    log "[3/4] ⚙️  Применение в ${CONF_D}/security-headers.conf..."
    cp "$cand_headers" "${CONF_D}/security-headers.conf"
    rm -f "$cand_headers"

    log "[4/4] 🔄 Безопасная перезагрузка Nginx..."
    safe_reload_nginx
    ok "Заголовки безопасности активированы и Nginx перезагружен."
    echo
}

###############################################################################
# 12) 📋 ТЕКУЩАЯ КОНФИГУРАЦИЯ И СТАТУС
###############################################################################
show_current_config() {
    echo
    echo "======================================================================"
    echo "  📋 ТЕКУЩАЯ КОНФИГУРАЦИЯ И СТАТУС NGINX"
    echo "======================================================================"
    echo

    echo "▶ Статус службы Nginx:"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl status nginx --no-pager -l 2>&1 | head -n 8 || true
    else
        ps aux | grep "[n]ginx" || echo "  Процесс Nginx не обнаружен."
    fi
    echo

    echo "▶ Активный сайт-маскировка (порт 80 default_server):"
    if [[ -L "${SITES_ENABL}/00-site.conf" && -e "${SITES_ENABL}/00-site.conf" ]]; then
        local site_target="$(readlink -f "${SITES_ENABL}/00-site.conf" || echo "00-site.conf")"
        local title="$(grep -E '^# Title:' "$site_target" 2>/dev/null | head -n 1 | cut -d: -f2- | sed 's/^[ 	]*//')"
        local root_dir="$(grep -E '^\s*root' "$site_target" 2>/dev/null | head -n 1 | sed 's/^[ 	]*//' || echo "")"
        local s_names="$(grep -E '^\s*server_name' "$site_target" 2>/dev/null | head -n 1 | sed 's/^[ 	]*//' || echo "")"
        echo "  Сайт     : ${title:-00-site.conf}"
        echo "  Симлинк  : ${SITES_ENABL}/00-site.conf -> ${site_target}"
        echo "  Каталог  : ${root_dir}"
        echo "  Домены   : ${s_names}"
    elif [[ -L "${SITES_ENABL}/cloud-node" && -e "${SITES_ENABL}/cloud-node" ]]; then
        echo "  Сайт     : Cloud Node (/var/www/acme)"
        echo "  Симлинк  : ${SITES_ENABL}/cloud-node"
    else
        echo "  [НЕТ] Активный сайт не настроен."
    fi
    echo
    echo "▶ Активные proxy-сервисы (sites-enabled/proxy-*.conf):"
    local proxy_found=0
    for p in "${SITES_ENABL}"/proxy-*.conf; do
        if [[ -e "$p" ]]; then
            proxy_found=1
            local p_target
            p_target="$(readlink -f "$p" || echo "$p")"
            local p_listen
            p_listen="$(grep -E '^\s*listen' "$p_target" | head -n 1 | sed 's/^[ \t]*//' || echo "listen ?;")"
            local p_pass
            p_pass="$(grep -E '^\s*proxy_pass' "$p_target" | head -n 1 | sed 's/^[ \t]*//' || echo "proxy_pass ?;")"
            echo "  • $(basename "$p"): ${p_listen} | ${p_pass}"
        fi
    done
    if [[ $proxy_found -eq 0 ]]; then
        echo "  Нет активных отдельных proxy-конфигураций."
    fi
    echo

    echo "▶ Слушающие порты Nginx:"
    if command -v ss >/dev/null 2>&1; then
        ss -tulpn 2>/dev/null | grep -i nginx || echo "  Порты Nginx не определены через ss."
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tulpn 2>/dev/null | grep -i nginx || echo "  Порты Nginx не определены через netstat."
    fi
    echo

    echo "▶ Проверка синтаксиса (nginx -t):"
    nginx -t 2>&1 || true
    echo
}

###############################################################################
# 13) 💾 СОЗДАТЬ BACKUP ВРУЧНУЮ
###############################################################################
manual_backup() {
    log "Создание резервной копии конфигурации Nginx..."
    local bkp
    bkp="$(backup_current_config)"
    ok "Резервная копия успешно создана: $bkp"
}

###############################################################################
# 14) ↩️ БЫСТРОЕ ВОССТАНОВЛЕНИЕ ПОСЛЕДНЕГО BACKUP
###############################################################################
restore_latest_backup() {
    log "Быстрое восстановление ПОСЛЕДНЕГО бэкапа Nginx"

    local latest_backup
    latest_backup="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r | head -n 1)"

    if [[ -z "$latest_backup" || ! -d "$latest_backup" ]]; then
        warn "В каталоге $BACKUP_DIR не найдено резервных копий."
        return 0
    fi

    echo "  Найден последний бэкап: $(basename "$latest_backup")"
    local confirm="y"
    if [[ -r /dev/tty ]]; then
        read -rp "Восстановить этот бэкап? [Y/n]: " confirm </dev/tty || confirm="y"
    fi
    if [[ "$confirm" =~ ^[Nn] ]]; then
        echo "Восстановление отменено."
        return 0
    fi

    # Создаём снимок безопасности текущего состояния
    local safety_bkp
    safety_bkp="$(backup_current_config)"
    ok "Текущее состояние сохранено в: ${safety_bkp}"

    rm -rf "$SITES_AVAIL" "$SITES_ENABL"
    cp -a "${latest_backup}/sites-available" "$SITES_AVAIL"
    cp -a "${latest_backup}/sites-enabled" "$SITES_ENABL"
    if [[ -d "${latest_backup}/conf.d" ]]; then
        rm -rf "$CONF_D"
        cp -a "${latest_backup}/conf.d" "$CONF_D"
    fi
    if [[ -d "${latest_backup}/snippets" ]]; then
        rm -rf "$SNIPPETS_D"
        cp -a "${latest_backup}/snippets" "$SNIPPETS_D"
    fi
    if [[ -f "${latest_backup}/nginx.conf" ]]; then
        cp -a "${latest_backup}/nginx.conf" "${NGINX_CONF_DIR}/nginx.conf"
    fi

    if nginx -t >/tmp/nginx-rest-test.log 2>&1; then
        safe_reload_nginx
        rm -f /tmp/nginx-rest-test.log
        ok "Конфигурация успешно восстановлена из $(basename "$latest_backup")."
    else
        warn "Восстановленный бэкап содержит ошибки! Откат к исходному состоянию..."
        cat /tmp/nginx-rest-test.log >&2
        rm -f /tmp/nginx-rest-test.log
        rm -rf "$SITES_AVAIL" "$SITES_ENABL"
        cp -a "${safety_bkp}/sites-available" "$SITES_AVAIL"
        cp -a "${safety_bkp}/sites-enabled" "$SITES_ENABL"
        safe_reload_nginx || true
        die "Откат отменён из-за синтаксической ошибки в архивной копии."
    fi
}

###############################################################################
# 15) 🗄️ ВОССТАНОВЛЕНИЕ ИЗ АРХИВА BACKUP (Выбор из списка)
###############################################################################
restore_backup_menu() {
    log "Восстановление конфигурации из архива резервных копий"

    local backups=()
    while IFS= read -r b; do
        [[ -n "$b" ]] && backups+=("$b")
    done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r)

    if [[ "${#backups[@]}" -eq 0 ]]; then
        warn "В каталоге $BACKUP_DIR нет резервных копий."
        return 0
    fi

    echo
    echo "Доступные резервные копии:"
    for i in "${!backups[@]}"; do
        printf "  %d) %s\n" "$((i+1))" "$(basename "${backups[$i]}")"
    done
    echo

    local choice=""
    if [[ -r /dev/tty ]]; then
        read -rp "Выберите номер бэкапа для восстановления [1-${#backups[@]}]: " choice </dev/tty || choice=""
    fi

    if [[ -z "$choice" || ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#backups[@]} )); then
        die "Некорректный номер бэкапа."
    fi

    local selected="${backups[$((choice-1))]}"
    log "Восстановление из $(basename "$selected")..."

    local safety_bkp
    safety_bkp="$(backup_current_config)"
    ok "Текущее состояние сохранено в ${safety_bkp}"

    rm -rf "$SITES_AVAIL" "$SITES_ENABL"
    cp -a "${selected}/sites-available" "$SITES_AVAIL"
    cp -a "${selected}/sites-enabled" "$SITES_ENABL"
    if [[ -d "${selected}/conf.d" ]]; then
        rm -rf "$CONF_D"
        cp -a "${selected}/conf.d" "$CONF_D"
    fi
    if [[ -d "${selected}/snippets" ]]; then
        rm -rf "$SNIPPETS_D"
        cp -a "${selected}/snippets" "$SNIPPETS_D"
    fi
    if [[ -f "${selected}/nginx.conf" ]]; then
        cp -a "${selected}/nginx.conf" "${NGINX_CONF_DIR}/nginx.conf"
    fi

    if nginx -t; then
        safe_reload_nginx
        ok "Конфигурация успешно восстановлена и Nginx перезапущен."
    else
        warn "Восстановленный бэкап содержит синтаксические ошибки! Откат..."
        rm -rf "$SITES_AVAIL" "$SITES_ENABL"
        cp -a "${safety_bkp}/sites-available" "$SITES_AVAIL"
        cp -a "${safety_bkp}/sites-enabled" "$SITES_ENABL"
        safe_reload_nginx || true
        die "Откат отменён. Возвращено исходное состояние."
    fi
}

###############################################################################
# MENU
###############################################################################
###############################################################################
# ГОТОВЫЕ HTML-ШАБЛОНЫ ИЗ GITHUB (nginx/templates/)
###############################################################################

prepare_template_repo() {
    log "Загрузка коллекции HTML-шаблонов из ${TEMPLATE_REPO}..."

    if ! command -v git >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq git ca-certificates >/dev/null 2>&1 || true
    fi

    if [[ -d "${TEMPLATE_CACHE}/.git" ]]; then
        log "Обновление локального кэша шаблонов..."
        if git -C "$TEMPLATE_CACHE" pull --quiet --ff-only 2>/dev/null; then
            ok "Кэш шаблонов обновлён."
            return 0
        fi
        rm -rf "$TEMPLATE_CACHE"
    fi

    mkdir -p "$(dirname "$TEMPLATE_CACHE")"
    if git clone --depth 1 --quiet "$TEMPLATE_REPO" "$TEMPLATE_CACHE"; then
        ok "Коллекция шаблонов успешно загружена."
    else
        die "Не удалось загрузить репозиторий шаблонов с ${TEMPLATE_REPO}."
    fi

    if [[ ! -d "${TEMPLATE_CACHE}/${TEMPLATE_ROOT}" ]]; then
        die "Каталог '${TEMPLATE_ROOT}' не найден в репозитории ${TEMPLATE_REPO}."
    fi
}

find_template_dir_robust() {
    local target="$1"
    local search_base="$TEMPLATE_CACHE"

    # 1. Прямой поиск в nginx/templates, templates или корне репозитория
    for prefix in "${TEMPLATE_ROOT}" "nginx/templates" "templates" "Templates" ""; do
        local cand="${search_base}/${prefix}/${target}"
        cand="${cand%/}"
        if [[ -d "$cand" ]]; then
            echo "$cand"
            return 0
        fi
    done

    # 2. Поиск с дефисами, подчёркиваниями, без пробелов, регистронезависимо
    local with_dashes="${target// /-}"
    local with_under="${target// /_}"
    local no_spaces="${target// /}"

    for var in "$target" "$with_dashes" "$with_under" "$no_spaces"; do
        local found
        found="$(find "$search_base" -maxdepth 4 -type d -iname "$var" -print -quit 2>/dev/null || true)"
        if [[ -n "$found" && -d "$found" ]]; then
            echo "$found"
            return 0
        fi
    done

    # 3. Поиск по ключевым словам
    local first_word="${target%% *}"
    if [[ -n "$first_word" ]]; then
        local found_partial
        found_partial="$(find "$search_base" -maxdepth 4 -type d -iname "*${first_word}*" -print -quit 2>/dev/null || true)"
        if [[ -n "$found_partial" && -d "$found_partial" ]]; then
            echo "$found_partial"
            return 0
        fi
    fi

    return 1
}

find_template_root() {
    local template_name="$1"
    local root

    if ! root="$(find_template_dir_robust "$template_name")"; then
        return 1
    fi

    # 1. Если index.html прямо в корне найденной папки
    if [[ -f "${root}/index.html" || -f "${root}/index.htm" ]]; then
        printf '%s\n' "$root"
        return 0
    fi

    # 2. Ищем первый подкаталог с index.html / index.htm (например v1, dist, build, public)
    local found
    found="$(find "$root" -mindepth 1 -maxdepth 4 -type f \( -name 'index.html' -o -name 'index.htm' \) -print -quit 2>/dev/null || true)"

    if [[ -n "$found" ]]; then
        dirname "$found"
        return 0
    fi

    # 3. Fallback на сам каталог
    printf '%s\n' "$root"
    return 0
}

install_repo_template() {
    local template_dir="$1"
    local display_name="$2"
    local site_name="$3"

    log "Установка готового HTML-шаблона: ${display_name}"
    local domain
    domain="_"

    prepare_template_repo

    local source_dir=""
    if ! source_dir="$(find_template_root "$template_dir")"; then
        warn "Каталог для шаблона '${template_dir}' не найден автоматическим поиском."
        echo
        echo "Сканирование репозитория на наличие всех доступных шаблонов..."
        local all_templates=()
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            all_templates+=("$(dirname "$f")")
        done < <(find "$TEMPLATE_CACHE" -maxdepth 5 -type f \( -name "index.html" -o -name "index.htm" \) 2>/dev/null | sort -u)

        if [[ "${#all_templates[@]}" -eq 0 ]]; then
            die "В репозитории ${TEMPLATE_REPO} не найдено ни одного HTML-шаблона с index.html."
        fi

        echo "Доступные шаблоны в вашем репозитории:"
        for i in "${!all_templates[@]}"; do
            local rel_path="${all_templates[$i]#$TEMPLATE_CACHE/}"
            printf "  %2d) %s\n" "$((i+1))" "$rel_path"
        done
        echo

        local pick=""
        if [[ -r /dev/tty ]]; then
            read -rp "Выберите номер шаблона для установки [1-${#all_templates[@]}]: " pick </dev/tty || pick=""
        fi

        if [[ -z "$pick" || ! "$pick" =~ ^[0-9]+$ ]] || (( pick < 1 || pick > ${#all_templates[@]} )); then
            die "Выбор отменён."
        fi

        source_dir="${all_templates[$((pick-1))]}"
    fi

    ok "Используется каталог шаблона: ${source_dir}"

    local site_dir="${WWW_ROOT}/${site_name}"
    mkdir -p "$site_dir"

    # Очищаем старые файлы сайта перед копированием новой версии
    rm -rf "${site_dir:?}"/*

    cp -a "${source_dir}/." "$site_dir/"
    ok "Файлы шаблона скопированы в ${site_dir}"

    # Дополняем стандартными файлами (robots.txt, favicon, 404, 50x), если их нет
    generate_common_assets "$site_dir" "$domain" "$display_name"

    # Генерируем Nginx конфиг (root указывает строго на $site_dir)
    local conf_name="${site_name}.conf"
    local cand_conf="/tmp/cand_site_$$.conf"
    generate_site_nginx_conf "$domain" "$site_dir" "" "$conf_name" > "$cand_conf"

    deploy_site_template "${display_name}" "$cand_conf" "$conf_name"

    ok "Шаблон '${display_name}' успешно активирован."
}

###############################################################################
# 7) ☁️ CLOUD STORAGE
###############################################################################
tpl_repo_cloud() {
    install_repo_template "$TEMPLATE_CLOUD" "Cloud Storage" "cloud-storage"
}

###############################################################################
# 8) ⬇️ DOWNLOAD MANAGER
###############################################################################
tpl_repo_download() {
    install_repo_template "$TEMPLATE_DOWNLOAD" "Download Manager" "download-manager"
}

###############################################################################
# 9) 📁 FILE CONVERTER
###############################################################################
tpl_repo_file_converter() {
    install_repo_template "$TEMPLATE_FILE_CONVERTER" "File Converter" "file-converter"
}

###############################################################################
# 10) 🎮 GAMES SITE
###############################################################################
tpl_repo_games() {
    install_repo_template "$TEMPLATE_GAMES" "Games Site" "games-site"
}

###############################################################################
# 11) 😂 MEMES SITE
###############################################################################
tpl_repo_memes() {
    install_repo_template "$TEMPLATE_MEMES" "Memes Site" "memes-site"
}

###############################################################################
# 12) 🛠️ MOD MANAGER
###############################################################################
tpl_repo_mod_manager() {
    install_repo_template "$TEMPLATE_MOD_MANAGER" "Mod Manager" "mod-manager"
}

###############################################################################
# 13) 🚀 SPEED TEST
###############################################################################
tpl_repo_speedtest() {
    install_repo_template "$TEMPLATE_SPEEDTEST" "Speed Test" "speed-test"
}

###############################################################################
# 14) 🎬 VIDEO CONVERTER
###############################################################################
tpl_repo_video_converter() {
    install_repo_template "$TEMPLATE_VIDEO_CONVERTER" "Video Converter" "video-converter"
}

###############################################################################
# 15) ⚠️ 503 ERROR PAGES (v1 / v2)
###############################################################################
tpl_repo_503() {
    echo
    echo "======================================================================"
    echo "  ⚠️  ВЫБОР ВЕРСИИ 503 ERROR PAGES"
    echo "======================================================================"
    echo "  1) ⚠️  503 Error Page v1"
    echo "  2) ⚠️  503 Error Page v2"
    echo "  0) ↩️  Назад"
    echo

    local choice=""
    if [[ -r /dev/tty ]]; then
        read -rp "Выберите вариант [0-2]: " choice </dev/tty || choice="0"
    fi

    case "$choice" in
        1)
            install_repo_template                 "${TEMPLATE_503}/v1"                 "503 Error Page v1"                 "error-503"
            ;;
        2)
            install_repo_template                 "${TEMPLATE_503}/v2"                 "503 Error Page v2"                 "error-503"
            ;;
        0)
            return 0
            ;;
        *)
            warn "Неверный выбор."
            return 1
            ;;
    esac
}

###############################################################################
# 16) 🤖 YOUTUBE-STYLE CAPTCHA
###############################################################################
tpl_repo_youtube_captcha() {
    install_repo_template "$TEMPLATE_YOUTUBE_CAPTCHA" "YouTube-style Captcha" "youtube-captcha"
}

restore_backup_combined() {
    echo
    echo "======================================================================"
    echo "  ↩️  ВОССТАНОВЛЕНИЕ КОНФИГУРАЦИИ NGINX ИЗ BACKUP"
    echo "======================================================================"
    echo
    echo "  1) ⚡ Быстрое восстановление ПОСЛЕДНЕГО бэкапа (в 1 клик)"
    echo "  2) 🗄️  Выбрать конкретный бэкап из списка архива"
    echo "  0) ↩️  Назад"
    echo
    local choice=""
    if [[ -r /dev/tty ]]; then
        read -rp "Выберите вариант [0-2]: " choice </dev/tty || choice="0"
    fi
    case "$choice" in
        1) restore_latest_backup ;;
        2) restore_backup_menu ;;
        *) return 0 ;;
    esac
}
show_menu() {
    clear 2>/dev/null || true

    local active_site="НЕТ"
    if [[ -L "${SITES_ENABL}/00-site.conf" && -e "${SITES_ENABL}/00-site.conf" ]]; then
        local t_name="$(grep -E '^# Title:' "${SITES_ENABL}/00-site.conf" 2>/dev/null | head -n 1 | cut -d: -f2- | sed 's/^[ 	]*//')"
        local r_dir="$(grep -E '^\s*root' "${SITES_ENABL}/00-site.conf" 2>/dev/null | head -n 1 | awk '{print $2}' | tr -d ';')"
        active_site="${t_name:-00-site.conf} (${r_dir:-/var/www})"
    elif [[ -L "${SITES_ENABL}/cloud-node" && -e "${SITES_ENABL}/cloud-node" ]]; then
        active_site="Cloud Node (/var/www/acme)"
    else
        for s in "${SITES_ENABL}"/*; do
            [[ -e "$s" ]] || continue
            local bname="$(basename "$s")"
            if [[ "$bname" != proxy-* ]]; then
                local r_dir="$(grep -E '^\s*root' "$s" 2>/dev/null | head -n 1 | awk '{print $2}' | tr -d ';')"
                active_site="${bname} (${r_dir:-/var/www})"
                break
            fi
        done
    fi

    local active_proxies=""
    for p in "${SITES_ENABL}"/proxy-*.conf; do
        if [[ -e "$p" ]]; then
            active_proxies="${active_proxies} $(basename "$p")"
        fi
    done
    active_proxies="$(echo "$active_proxies" | sed 's/^ //')"
    [[ -z "$active_proxies" ]] && active_proxies="нет"

    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║               NGINX TEMPLATE & SECURITY MANAGER                      ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    echo "  Активный сайт-маскировка : ${active_site}"
    echo "  Активные proxy-сервисы   : ${active_proxies}"
    echo
    echo "  🌐 САЙТЫ (ВСТРОЕННЫЕ):"
    echo "    1) 📁 Файловый архив"
    echo "    2) 🎬 Медиаархив"
    echo "    3) 📰 Новостной портал"
    echo "    4) 📚 Техническая документация"
    echo "    5) 🏢 Корпоративный сайт"
    echo "    6) 🌐 Нейтральная заглушка"
    echo
    echo "  🎨 ГОТОВЫЕ HTML-ШАБЛОНЫ (из GitHub: iurievi4/vps-setup):"
    echo "    7) ☁️  Cloud Storage"
    echo "    8) ⬇️  Download Manager"
    echo "    9) 📁 File Converter"
    echo "   10) 🎮 Games Site"
    echo "   11) 😂 Memes Site"
    echo "   12) 🛠️ Mod Manager"
    echo "   13) 🚀 Speed Test"
    echo "   14) 🎬 Video Converter"
    echo "   15) ⚠️ 503 Error Pages"
    echo "   16) 🤖 YouTube Captcha"
    echo
    echo "  🔄 ПРОКСИРОВАНИЕ (изолированные конфигурации, не затрагивают сайт):"
    echo "   17) 🔄 Reverse Proxy"
    echo "   18) 🔌 Reverse Proxy + WebSocket (3x-ui / Xray / VLESS)"
    echo "   19) 🗑️ Управление / удаление Proxy"
    echo
    echo "  🔐 SSL И БЕЗОПАСНОСТЬ:"
    echo "   20) 🔐 ACME / Let's Encrypt"
    echo "   21) 🛡️ Security Headers"
    echo
    echo "  📋 УПРАВЛЕНИЕ:"
    echo "   22) 📋 Текущая конфигурация"
    echo "   23) 💾 Создать backup"
    echo "   24) ↩️ Восстановить backup"
    echo
    echo "    0) 🚪 Выход"
    echo "══════════════════════════════════════════════════════════════════════"
}

# Проверка состояния Nginx перед выполнением операций (кроме восстановления бэкапа)
if [[ "${1:-}" != "24" && "${1:-}" != "restore" && "${1:-}" != "rollback" ]]; then
    ensure_nginx || {
        warn "Конфигурация Nginx содержит ошибки. Для отката используйте: $0 24 (или $0 restore)"
        exit 1
    }
fi

ACTION="${1:-}"

case "$ACTION" in
    1|archive)           tpl_file_archive ;;
    2|media)             tpl_media_archive ;;
    3|news)              tpl_news_portal ;;
    4|docs)              tpl_tech_docs ;;
    5|corp)              tpl_corporate_site ;;
    6|stub)              tpl_neutral_stub ;;
    7|cloud)             tpl_repo_cloud ;;
    8|download)          tpl_repo_download ;;
    9|file-converter)    tpl_repo_file_converter ;;
    10|games)            tpl_repo_games ;;
    11|memes)            tpl_repo_memes ;;
    12|mod-manager)      tpl_repo_mod_manager ;;
    13|speedtest)        tpl_repo_speedtest ;;
    14|video-converter)  tpl_repo_video_converter ;;
    15|503)              tpl_repo_503 ;;
    16|youtube|captcha)  tpl_repo_youtube_captcha ;;
    17|proxy)            tpl_reverse_proxy ;;
    18|ws)               tpl_proxy_websocket ;;
    19|delproxy)         remove_proxy_config ;;
    20|acme)             tpl_acme_setup ;;
    21|headers)          tpl_security_headers ;;
    22|status)           show_current_config ;;
    23|backup)           manual_backup ;;
    24|restore|rollback) restore_backup_combined ;;
    "")
        show_menu
        read -r -p "Выберите вариант [0-24]: " choice </dev/tty || choice="0"
        case "$choice" in
            1)  tpl_file_archive ;;
            2)  tpl_media_archive ;;
            3)  tpl_news_portal ;;
            4)  tpl_tech_docs ;;
            5)  tpl_corporate_site ;;
            6)  tpl_neutral_stub ;;
            7)  tpl_repo_cloud ;;
            8)  tpl_repo_download ;;
            9)  tpl_repo_file_converter ;;
            10) tpl_repo_games ;;
            11) tpl_repo_memes ;;
            12) tpl_repo_mod_manager ;;
            13) tpl_repo_speedtest ;;
            14) tpl_repo_video_converter ;;
            15) tpl_repo_503 ;;
            16) tpl_repo_youtube_captcha ;;
            17) tpl_reverse_proxy ;;
            18) tpl_proxy_websocket ;;
            19) remove_proxy_config ;;
            20) tpl_acme_setup ;;
            21) tpl_security_headers ;;
            22) show_current_config ;;
            23) manual_backup ;;
            24) restore_backup_combined ;;
            0)  echo "Выход."; exit 0 ;;
            *)  die "Некорректный выбор." ;;
        esac
        ;;
    *)
        echo "Использование: $0 [1-24] или интерактивно без аргументов."
        exit 1
        ;;
esac
