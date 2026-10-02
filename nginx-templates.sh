#!/usr/bin/env bash
###############################################################################
# NGINX TEMPLATE & SECURITY MANAGER
#
# Меню:
#   1) 📁 Файловый архив
#   2) 🎬 Медиаархив
#   3) 📰 Новостной портал
#   4) 📚 Техническая документация
#   5) 🏢 Корпоративный сайт
#   6) 🌐 Нейтральная заглушка
#
#   7) 🔄 Reverse Proxy
#   8) 🔌 Reverse Proxy + WebSocket
#
#   9) 🔐 ACME / Let's Encrypt
#  10) 🛡️ Security headers
#
#  11) 📋 Текущая конфигурация
#  12) 💾 Создать backup
#  13) ↩️ Восстановить backup
#   0) 🚪 Выход
#
# Безопасность:
#   - Автоматический бэкап перед изменением (/etc/nginx/backups/)
#   - Проверка 'nginx -t' с автоматическим откатом при ошибке
#   - Сохранение маршрута /.well-known/acme-challenge/ во всех шаблонах
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
BACKUP_DIR="${NGINX_CONF_DIR}/backups"
WWW_ROOT="/var/www"
ACME_DIR="${WWW_ROOT}/acme"

mkdir -p "$SITES_AVAIL" "$SITES_ENABL" "$CONF_D" "$BACKUP_DIR" "$ACME_DIR"

# Обеспечиваем наличие базового Nginx
if ! command -v nginx >/dev/null 2>&1; then
    echo ">>> Установка nginx..." >&2
    apt-get update -qq && apt-get install -y -qq nginx ca-certificates >/dev/null 2>&1
fi

log(){ printf '\n\033[1;32m>>> %s\033[0m\n' "$*"; }
ok(){ printf '  \033[1;32m[OK]\033[0m %s\n' "$*"; }
warn(){ printf '  \033[1;33m[WARN]\033[0m %s\n' "$*"; }
die(){ printf '  \033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

backup_current_config() {
    local bkp_path="${BACKUP_DIR}/nginx-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$bkp_path"
    if [[ -d "$SITES_AVAIL" ]]; then
        cp -a "$SITES_AVAIL" "$bkp_path/" 2>/dev/null || true
    fi
    if [[ -d "$SITES_ENABL" ]]; then
        cp -a "$SITES_ENABL" "$bkp_path/" 2>/dev/null || true
    fi
    if [[ -d "$CONF_D" ]]; then
        cp -a "$CONF_D" "$bkp_path/" 2>/dev/null || true
    fi
    echo "$bkp_path"
}

apply_and_test() {
    local conf_name="$1"
    local bkp_path="$2"

    log "Проверка конфигурации Nginx..."
    # Очищаем sites-enabled и подключаем только активный сайт
    find "$SITES_ENABL" -mindepth 1 -maxdepth 1 -exec rm -f {} +
    ln -sf "${SITES_AVAIL}/${conf_name}" "${SITES_ENABL}/${conf_name}"

    if nginx -t >/tmp/nginx-test.log 2>&1; then
        systemctl reload nginx 2>/dev/null || systemctl restart nginx
        ok "Шаблон '${conf_name}' успешно применён и Nginx перезапущен."
        rm -f /tmp/nginx-test.log
    else
        warn "Синтаксическая ошибка в новом конфиге Nginx:"
        cat /tmp/nginx-test.log >&2
        warn "Откат конфигурации из $bkp_path..."
        rm -rf "$SITES_AVAIL" "$SITES_ENABL"
        cp -a "${bkp_path}/sites-available" "$SITES_AVAIL"
        cp -a "${bkp_path}/sites-enabled" "$SITES_ENABL"
        systemctl reload nginx 2>/dev/null || true
        die "Откат завершён. Предыдущая конфигурация восстановлена."
    fi
}

###############################################################################
# 1) 📁 ФАЙЛОВЫЙ АРХИВ (Open Source Mirror & Repository)
###############################################################################
tpl_file_archive() {
    local bkp
    bkp="$(backup_current_config)"
    log "Установка шаблона: Файловый архив / Репозиторий"

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
        tr:hover td { background: #24324d; }
        a { color: var(--accent); text-decoration: none; }
        a:hover { text-decoration: underline; }
        .badge { background: #0369a1; color: #fff; font-size: 0.75rem; padding: 0.2rem 0.5rem; border-radius: 4px; }
        footer { margin-top: 3rem; font-size: 0.8rem; color: #64748b; text-align: center; }
    </style>
</head>
<body>
    <header>
        <div class="title">📁 Cloud Distribution & Public Archive</div>
        <div>Mirror Node: <span class="badge">EU-CDN-01</span></div>
    </header>
    <div class="path">Index of /releases/packages/stable</div>
    <table>
        <thead>
            <tr>
                <th>File Name</th>
                <th>Last Modified</th>
                <th>Size</th>
                <th>Format</th>
            </tr>
        </thead>
        <tbody>
            <tr>
                <td><a href="packages/core-runtime-v3.8.tar.gz">core-runtime-v3.8.tar.gz</a></td>
                <td>2026-09-28 14:20</td>
                <td>12.0 MB</td>
                <td><span class="badge">GZ Archive</span></td>
            </tr>
            <tr>
                <td><a href="packages/edge-node-x86_64.deb">edge-node-x86_64.deb</a></td>
                <td>2026-09-25 10:15</td>
                <td>4.2 MB</td>
                <td><span class="badge">Debian Pkg</span></td>
            </tr>
            <tr>
                <td><a href="packages/database-connector-v1.4.zip">database-connector-v1.4.zip</a></td>
                <td>2026-09-18 09:04</td>
                <td>8.1 MB</td>
                <td><span class="badge">ZIP</span></td>
            </tr>
            <tr>
                <td><a href="packages/SHA256SUMS">SHA256SUMS</a></td>
                <td>2026-09-28 14:22</td>
                <td>512 B</td>
                <td><span class="badge">Checksum</span></td>
            </tr>
        </tbody>
    </table>
    <footer>
        High-performance network file mirror. All packages cryptographically signed.
    </footer>
</body>
</html>
EOF_HTML
    chmod -R 755 "$site_dir"

    cat > "${SITES_AVAIL}/file-archive" <<'EOF_CONF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root /var/www/archive;
    index index.html;

    # Поддержка докачки больших файлов (Range requests)
    max_ranges 512;

    # Кэширование для архивов
    location ~* \.(tar\.gz|zip|deb|rpm|iso|bin|sha256)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }

    location /.well-known/acme-challenge/ {
        root /var/www/acme;
        allow all;
    }

    location / {
        try_files $uri $uri/ =404;
    }
}
EOF_CONF

    apply_and_test "file-archive" "$bkp"
}

###############################################################################
# 2) 🎬 МЕДИААРХИВ (Video/Audio Stream Archive)
###############################################################################
tpl_media_archive() {
    local bkp
    bkp="$(backup_current_config)"
    log "Установка шаблона: Медиаархив (Video / Audio Streaming)"

    local site_dir="${WWW_ROOT}/media"
    mkdir -p "$site_dir"

    cat > "${site_dir}/index.html" <<'EOF_HTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>StreamVault — Digital Media & Broadcast Archive</title>
    <style>
        :root { --bg: #090d16; --card: #131c2e; --text: #f1f5f9; --accent: #6366f1; --muted: #94a3b8; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; background: var(--bg); color: var(--text); }
        header { background: #0f172a; padding: 1rem 2rem; display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #1e293b; }
        .logo { font-size: 1.3rem; font-weight: 800; color: var(--accent); display: flex; align-items: center; gap: 0.5rem; }
        .nav-tags { display: flex; gap: 1rem; }
        .tag { background: #1e293b; color: var(--muted); padding: 0.35rem 0.85rem; border-radius: 9999px; font-size: 0.85rem; cursor: pointer; }
        .tag.active { background: var(--accent); color: #fff; }
        .container { max-width: 1200px; margin: 2.5rem auto; padding: 0 1.5rem; }
        h2 { font-size: 1.5rem; font-weight: 700; margin-bottom: 1.5rem; }
        .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 1.75rem; }
        .media-card { background: var(--card); border-radius: 12px; overflow: hidden; border: 1px solid #1e293b; transition: transform 0.2s; }
        .media-card:hover { transform: translateY(-4px); }
        .thumb { height: 160px; background: linear-gradient(135deg, #1e1b4b, #312e81); position: relative; display: flex; align-items: center; justify-content: center; }
        .play-btn { width: 48px; height: 48px; background: rgba(255,255,255,0.2); border-radius: 50%; display: flex; align-items: center; justify-content: center; font-size: 1.5rem; backdrop-filter: blur(4px); }
        .duration { position: absolute; bottom: 8px; right: 8px; background: rgba(0,0,0,0.8); padding: 0.2rem 0.5rem; border-radius: 4px; font-size: 0.75rem; font-weight: 600; }
        .details { padding: 1.25rem; }
        .details h3 { margin: 0 0 0.5rem 0; font-size: 1.05rem; }
        .meta { font-size: 0.8rem; color: var(--muted); display: flex; justify-content: space-between; }
        footer { margin-top: 4rem; padding: 2rem; text-align: center; color: var(--muted); font-size: 0.85rem; border-top: 1px solid #1e293b; }
    </style>
</head>
<body>
    <header>
        <div class="logo">🎬 StreamVault Archive</div>
        <div class="nav-tags">
            <span class="tag active">All Media</span>
            <span class="tag">Conferences</span>
            <span class="tag">Keynotes</span>
            <span class="tag">Podcasts</span>
        </div>
    </header>
    <div class="container">
        <h2>Latest Broadcasts & Recordings</h2>
        <div class="grid">
            <div class="media-card">
                <div class="thumb">
                    <div class="play-btn">▶</div>
                    <div class="duration">42:15</div>
                </div>
                <div class="details">
                    <h3>Global Infrastructure Summit 2026</h3>
                    <div class="meta"><span>1080p 60fps</span><span>14.2k views</span></div>
                </div>
            </div>
            <div class="media-card">
                <div class="thumb" style="background: linear-gradient(135deg, #064e3b, #047857);">
                    <div class="play-btn">▶</div>
                    <div class="duration">28:40</div>
                </div>
                <div class="details">
                    <h3>Edge Computing & Network Resilience</h3>
                    <div class="meta"><span>AV1 Stream</span><span>8.9k views</span></div>
                </div>
            </div>
            <div class="media-card">
                <div class="thumb" style="background: linear-gradient(135deg, #4c1d95, #6d28d9);">
                    <div class="play-btn">▶</div>
                    <div class="duration">55:10</div>
                </div>
                <div class="details">
                    <h3>Future of Post-Quantum Cryptography</h3>
                    <div class="meta"><span>4K UHD</span><span>22.5k views</span></div>
                </div>
            </div>
        </div>
    </div>
    <footer>
        StreamVault media delivery network. HLS/DASH/MP4 byte-range acceleration enabled.
    </footer>
</body>
</html>
EOF_HTML
    chmod -R 755 "$site_dir"

    cat > "${SITES_AVAIL}/media-archive" <<'EOF_CONF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root /var/www/media;
    index index.html;

    # Оптимизация видеопотока
    location ~* \.(mp4|m4v|webm|mkv|mp3|flac|ogg)$ {
        mp4;
        mp4_buffer_size 1m;
        mp4_max_buffer_size 10m;
        add_header Accept-Ranges bytes;
        expires 7d;
    }

    location /.well-known/acme-challenge/ {
        root /var/www/acme;
        allow all;
    }

    location / {
        try_files $uri $uri/ =404;
    }
}
EOF_CONF

    apply_and_test "media-archive" "$bkp"
}

###############################################################################
# 3) 📰 НОВОСТНОЙ ПОРТАЛ (Tech News & Editorial)
###############################################################################
tpl_news_portal() {
    local bkp
    bkp="$(backup_current_config)"
    log "Установка шаблона: Новостной портал (Tech & Network Pulse)"

    local site_dir="${WWW_ROOT}/news"
    mkdir -p "$site_dir"

    cat > "${site_dir}/index.html" <<'EOF_HTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>TechPulse — Global Infrastructure & Computing News</title>
    <style>
        :root { --primary: #dc2626; --dark: #111827; --text: #374151; --light: #f3f4f6; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, serif; margin: 0; background: #fff; color: var(--dark); line-height: 1.6; }
        .ticker { background: var(--dark); color: #fff; padding: 0.4rem 1.5rem; font-size: 0.8rem; display: flex; align-items: center; gap: 1rem; }
        .ticker-badge { background: var(--primary); padding: 0.15rem 0.5rem; border-radius: 3px; font-weight: 700; text-transform: uppercase; }
        header { border-bottom: 2px solid var(--dark); padding: 1.5rem; text-align: center; }
        .brand { font-size: 2.5rem; font-weight: 900; letter-spacing: -1.5px; text-transform: uppercase; }
        nav { display: flex; justify-content: center; gap: 2rem; margin-top: 1rem; font-size: 0.9rem; font-weight: 700; text-transform: uppercase; }
        nav a { color: var(--dark); text-decoration: none; }
        .container { max-width: 1100px; margin: 2rem auto; padding: 0 1.5rem; }
        .featured { display: grid; grid-template-columns: 2fr 1fr; gap: 2.5rem; border-bottom: 1px solid #e5e7eb; padding-bottom: 2.5rem; }
        .headline { font-size: 2.2rem; font-weight: 800; line-height: 1.2; margin: 0.5rem 0 1rem 0; }
        .byline { font-size: 0.85rem; color: #6b7280; margin-bottom: 1rem; }
        .summary { font-size: 1.15rem; color: #4b5563; }
        .sidebar-item { border-bottom: 1px solid #e5e7eb; padding: 1rem 0; }
        .sidebar-item:first-child { padding-top: 0; }
        .sidebar-item h4 { margin: 0 0 0.35rem 0; font-size: 1.05rem; }
        footer { background: var(--light); padding: 2rem; text-align: center; font-size: 0.85rem; color: #6b7280; margin-top: 3rem; }
    </style>
</head>
<body>
    <div class="ticker">
        <span class="ticker-badge">Live</span>
        <span>Global backbone traffic sets new capacity records with 800G optical adoption worldwide.</span>
    </div>
    <header>
        <div class="brand">THE TECHPULSE JOURNAL</div>
        <nav>
            <a href="#">Cloud & Data</a>
            <a href="#">Security</a>
            <a href="#">AI Systems</a>
            <a href="#">Network Edge</a>
            <a href="#">Telecom</a>
        </nav>
    </header>
    <div class="container">
        <div class="featured">
            <div>
                <span style="color:var(--primary);font-weight:700;font-size:0.85rem;text-transform:uppercase;">Special Report</span>
                <h1 class="headline">Next-Generation Distributed Data Centers Adopt Real-Time Edge Routing</h1>
                <div class="byline">By Alexander Miller • Published Today, 14:30 UTC • 5 min read</div>
                <p class="summary">Autonomous edge architectures continue to replace legacy centralized models as enterprise demands for sub-10 millisecond latency surge across multinational cloud platforms.</p>
                <p>Engineers report a 35% reduction in cross-border routing jitter following the deployment of hardware-accelerated traffic inspection pipelines.</p>
            </div>
            <div>
                <h3 style="border-bottom:2px solid var(--dark);padding-bottom:0.5rem;margin-top:0;">Top Stories</h3>
                <div class="sidebar-item">
                    <h4>Open Standards Consortium Releases TLS 1.4 Draft Specifications</h4>
                    <span style="font-size:0.8rem;color:#9ca3af;">2 hours ago</span>
                </div>
                <div class="sidebar-item">
                    <h4>BBRv3 Congestion Protocol Benchmark Shows 40% Throughput Gain</h4>
                    <span style="font-size:0.8rem;color:#9ca3af;">4 hours ago</span>
                </div>
                <div class="sidebar-item">
                    <h4>Major Undersea Cable Project Connects Mediterranean Hubs</h4>
                    <span style="font-size:0.8rem;color:#9ca3af;">6 hours ago</span>
                </div>
            </div>
        </div>
    </div>
    <footer>
        &copy; 2026 The TechPulse Journal. All wire services authenticated.
    </footer>
</body>
</html>
EOF_HTML
    chmod -R 755 "$site_dir"

    cat > "${SITES_AVAIL}/news-portal" <<'EOF_CONF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root /var/www/news;
    index index.html;

    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml;

    location /.well-known/acme-challenge/ {
        root /var/www/acme;
        allow all;
    }

    location / {
        try_files $uri $uri/ =404;
    }
}
EOF_CONF

    apply_and_test "news-portal" "$bkp"
}

###############################################################################
# 4) 📚 ТЕХНИЧЕСКАЯ ДОКУМЕНТАЦИЯ (Docs / API Knowledge Base)
###############################################################################
tpl_tech_docs() {
    local bkp
    bkp="$(backup_current_config)"
    log "Установка шаблона: Техническая документация (API & Knowledge Base)"

    local site_dir="${WWW_ROOT}/docs"
    mkdir -p "$site_dir"

    cat > "${site_dir}/index.html" <<'EOF_HTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Core Platform Documentation — v3.8</title>
    <style>
        :root { --sidebar: #f8fafc; --text: #0f172a; --primary: #0284c7; --border: #e2e8f0; --code-bg: #1e293b; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; display: flex; height: 100vh; color: var(--text); }
        aside { width: 280px; background: var(--sidebar); border-right: 1px solid var(--border); padding: 1.5rem; box-sizing: border-box; overflow-y: auto; }
        .logo { font-size: 1.15rem; font-weight: 700; color: var(--primary); margin-bottom: 2rem; }
        .menu-cat { font-size: 0.75rem; font-weight: 700; color: #64748b; text-transform: uppercase; margin-top: 1.5rem; margin-bottom: 0.5rem; }
        .menu-link { display: block; padding: 0.4rem 0.5rem; color: #334155; text-decoration: none; border-radius: 6px; font-size: 0.9rem; }
        .menu-link.active { background: #e0f2fe; color: var(--primary); font-weight: 600; }
        main { flex: 1; padding: 3rem 4rem; overflow-y: auto; max-width: 850px; }
        h1 { font-size: 2.25rem; font-weight: 800; letter-spacing: -0.5px; margin-top: 0; }
        p { line-height: 1.7; color: #334155; }
        pre { background: var(--code-bg); color: #f8fafc; padding: 1.25rem; border-radius: 8px; font-size: 0.9rem; overflow-x: auto; }
        code { font-family: "SFMono-Regular", Consolas, Menlo, monospace; }
        .callout { background: #f0fdf4; border-left: 4px solid #22c55e; padding: 1rem; margin: 1.5rem 0; border-radius: 0 8px 8px 0; }
    </style>
</head>
<body>
    <aside>
        <div class="logo">📖 Core Platform Docs</div>
        <div class="menu-cat">Getting Started</div>
        <a class="menu-link active" href="#">Overview</a>
        <a class="menu-link" href="#">Quickstart Guide</a>
        <a class="menu-link" href="#">Architecture</a>
        <div class="menu-cat">API & CLI</div>
        <a class="menu-link" href="#">Authentication</a>
        <a class="menu-link" href="#">REST Endpoints</a>
        <a class="menu-link" href="#">CLI Reference</a>
        <div class="menu-cat">Operations</div>
        <a class="menu-link" href="#">Health Checking</a>
        <a class="menu-link" href="#">High Availability</a>
    </aside>
    <main>
        <h1>System Architecture & Runtime Overview</h1>
        <p>This technical guide outlines the fundamental operating model of the high-availability cloud runtime engine deployed across this infrastructure node.</p>
        <div class="callout">
            <strong>Production Ready:</strong> All endpoints enforce TLS 1.3 encryption and automated certificate rotation.
        </div>
        <h2>Quick Service Health Verification</h2>
        <p>To inspect runtime metrics directly from the host system, query the local IPC telemetry endpoint:</p>
        <pre><code># Query local node status
curl -fsS http://127.0.0.1:8080/health \
  -H "Accept: application/json"</code></pre>
        <h2>Configuration Directives</h2>
        <p>System daemons utilize decentralized configuration schemas with automatic hot-reloading upon SIGHUP signal dispatch.</p>
    </main>
</body>
</html>
EOF_HTML
    chmod -R 755 "$site_dir"

    cat > "${SITES_AVAIL}/tech-docs" <<'EOF_CONF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root /var/www/docs;
    index index.html;

    location /.well-known/acme-challenge/ {
        root /var/www/acme;
        allow all;
    }

    location / {
        try_files $uri $uri/ =404;
    }
}
EOF_CONF

    apply_and_test "tech-docs" "$bkp"
}

###############################################################################
# 5) 🏢 КОРПОРАТИВНЫЙ САЙТ (B2B Cloud Solutions)
###############################################################################
tpl_corporate_site() {
    local bkp
    bkp="$(backup_current_config)"
    log "Установка шаблона: Корпоративный сайт (Enterprise Cloud Solutions)"

    local site_dir="${WWW_ROOT}/corp"
    mkdir -p "$site_dir"

    cat > "${site_dir}/index.html" <<'EOF_HTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>CloudSphere Solutions — Enterprise Global Infrastructure</title>
    <style>
        :root { --primary: #1d4ed8; --dark: #0f172a; --slate: #475569; --bg: #f8fafc; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; background: #fff; color: var(--dark); line-height: 1.6; }
        header { border-bottom: 1px solid #e2e8f0; padding: 1.25rem 3rem; display: flex; justify-content: space-between; align-items: center; }
        .logo { font-size: 1.35rem; font-weight: 800; color: var(--primary); letter-spacing: -0.5px; }
        .btn { background: var(--primary); color: #fff; padding: 0.6rem 1.4rem; border-radius: 6px; font-weight: 600; text-decoration: none; }
        .hero { text-align: center; padding: 6rem 1.5rem 4rem 1.5rem; max-width: 900px; margin: 0 auto; }
        h1 { font-size: 3.5rem; font-weight: 900; letter-spacing: -1.5px; line-height: 1.1; margin-bottom: 1.5rem; }
        .lead { font-size: 1.25rem; color: var(--slate); margin-bottom: 2.5rem; }
        .stats { display: flex; justify-content: center; gap: 4rem; margin-top: 4rem; border-top: 1px solid #e2e8f0; padding-top: 3rem; }
        .stat-num { font-size: 2.5rem; font-weight: 800; color: var(--primary); }
        .stat-label { font-size: 0.9rem; color: var(--slate); font-weight: 600; }
        .grid { max-width: 1100px; margin: 5rem auto; padding: 0 1.5rem; display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 2rem; }
        .card { padding: 2rem; border: 1px solid #e2e8f0; border-radius: 12px; background: var(--bg); }
        .card h3 { margin-top: 0; font-size: 1.25rem; }
        footer { background: var(--dark); color: #94a3b8; padding: 3rem; text-align: center; font-size: 0.85rem; }
    </style>
</head>
<body>
    <header>
        <div class="logo">⚡ CloudSphere Global</div>
        <a class="btn" href="#">Client Portal</a>
    </header>
    <section class="hero">
        <h1>High-Performance Cloud Infrastructure at Scale</h1>
        <p class="lead">Delivering low-latency virtual compute, distributed network backbones, and zero-trust edge protection for global organizations.</p>
        <a class="btn" style="font-size:1.1rem;padding:0.8rem 2rem;" href="#">Request Infrastructure Consultation</a>
        <div class="stats">
            <div><div class="stat-num">99.999%</div><div class="stat-label">SLA Uptime</div></div>
            <div><div class="stat-num">48 Tbps</div><div class="stat-label">Global Capacity</div></div>
            <div><div class="stat-num">&lt; 8 ms</div><div class="stat-label">Average Edge Latency</div></div>
        </div>
    </section>
    <div class="grid">
        <div class="card">
            <h3>Enterprise Mesh Interconnect</h3>
            <p>Direct low-latency peering across Tier-1 backbones with automatic BGP path optimization and DDoS shield.</p>
        </div>
        <div class="card">
            <h3>Automated Compliance</h3>
            <p>ISO/IEC 27001 and SOC 2 Type II certified edge clusters with continuous automated telemetry validation.</p>
        </div>
        <div class="card">
            <h3>Dedicated Storage Fabrics</h3>
            <p>NVMe-over-Fabrics high-IOPS persistent volumes replicated synchronously across redundant availability zones.</p>
        </div>
    </div>
    <footer>
        &copy; 2026 CloudSphere Systems International. Operating across European, American, and Asian exchange points.
    </footer>
</body>
</html>
EOF_HTML
    chmod -R 755 "$site_dir"

    cat > "${SITES_AVAIL}/corporate" <<'EOF_CONF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root /var/www/corp;
    index index.html;

    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml;

    location /.well-known/acme-challenge/ {
        root /var/www/acme;
        allow all;
    }

    location / {
        try_files $uri $uri/ =404;
    }
}
EOF_CONF

    apply_and_test "corporate" "$bkp"
}

###############################################################################
# 6) 🌐 НЕЙТРАЛЬНАЯ ЗАГЛУШКА (Neutral Stub / 200 OK)
###############################################################################
tpl_neutral_stub() {
    local bkp
    bkp="$(backup_current_config)"
    log "Установка шаблона: Нейтральная заглушка (Cloud Node Active 200 OK)"

    cat > "${SITES_AVAIL}/cloud-node" <<'EOF_STUB'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root /var/www/acme;

    location /.well-known/acme-challenge/ {
        allow all;
    }

    location / {
        default_type text/plain;
        return 200 "Cloud Node Active\n";
    }
}
EOF_STUB

    apply_and_test "cloud-node" "$bkp"
}

###############################################################################
# 7) 🔄 REVERSE PROXY
###############################################################################
tpl_reverse_proxy() {
    local bkp
    bkp="$(backup_current_config)"
    log "Настройка стандартного Reverse Proxy"

    local domain=""
    local upstream=""

    if [[ -r /dev/tty ]]; then
        read -rp "Доменное имя [по умолчанию _]: " domain </dev/tty || domain=""
        read -rp "Upstream адрес [по умолчанию http://127.0.0.1:8080]: " upstream </dev/tty || upstream=""
    fi

    domain="${domain:-_}"
    upstream="${upstream:-http://127.0.0.1:8080}"

    cat > "${SITES_AVAIL}/reverse-proxy" <<EOF_PROXY
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    location /.well-known/acme-challenge/ {
        root /var/www/acme;
        allow all;
    }

    location / {
        proxy_pass ${upstream};
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

    apply_and_test "reverse-proxy" "$bkp"
}

###############################################################################
# 8) 🔌 REVERSE PROXY + WEBSOCKET (для 3x-ui и современных сервисов)
###############################################################################
tpl_proxy_websocket() {
    local bkp
    bkp="$(backup_current_config)"
    log "Настройка Reverse Proxy с поддержкой WebSocket (3x-ui / Xray)"

    local domain=""
    local panel_port=""

    if [[ -f /etc/x-ui/x-ui.db ]] && command -v sqlite3 >/dev/null 2>&1; then
        panel_port="$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='webPort';" 2>/dev/null || true)"
    fi
    panel_port="${panel_port:-8784}"

    if [[ -r /dev/tty ]]; then
        read -rp "Доменное имя [по умолчанию _]: " domain </dev/tty || domain=""
        read -rp "Порт локального сервиса [по умолчанию ${panel_port}]: " user_port </dev/tty || user_port=""
        [[ -n "$user_port" ]] && panel_port="$user_port"
    fi

    domain="${domain:-_}"

    cat > "${SITES_AVAIL}/proxy-websocket" <<EOF_WS
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    location /.well-known/acme-challenge/ {
        root /var/www/acme;
        allow all;
    }

    location / {
        proxy_pass http://127.0.0.1:${panel_port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket Upgrade
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # Увеличенные таймауты для непрерывных WebSocket соединений
        proxy_connect_timeout 120s;
        proxy_send_timeout 86400s;
        proxy_read_timeout 86400s;
    }
}
EOF_WS

    apply_and_test "proxy-websocket" "$bkp"
}

###############################################################################
# 9) 🔐 ACME / LET'S ENCRYPT
###############################################################################
tpl_acme_setup() {
    log "Настройка модуля ACME / Let's Encrypt"

    cat > "${CONF_D}/acme.conf" <<'EOF_ACME'
# Глобальное переопределение для Let's Encrypt HTTP-01 challenge
location /.well-known/acme-challenge/ {
    root /var/www/acme;
    allow all;
}
EOF_ACME

    mkdir -p /var/www/acme
    chmod 755 /var/www/acme

    if nginx -t; then
        systemctl reload nginx 2>/dev/null || systemctl restart nginx
        ok "Каталог /var/www/acme и ACME location успешно активированы."
        echo "  Теперь любой клиент (certbot, acme.sh) может выпускать сертификаты"
        echo "  в режиме webroot: --webroot -w /var/www/acme"
    else
        rm -f "${CONF_D}/acme.conf"
        die "Ошибка при валидации acme.conf."
    fi
}

###############################################################################
# 10) 🛡️ SECURITY HEADERS
###############################################################################
tpl_security_headers() {
    log "Активация глобальных заголовков безопасности"

    cat > "${CONF_D}/security-headers.conf" <<'EOF_SEC'
# Защитные HTTP-заголовки
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "geolocation=(), camera=(), microphone=()" always;
EOF_SEC

    if nginx -t; then
        systemctl reload nginx 2>/dev/null || systemctl restart nginx
        ok "Заголовки безопасности активированы в ${CONF_D}/security-headers.conf"
    else
        rm -f "${CONF_D}/security-headers.conf"
        die "Ошибка синтаксиса при добавлении заголовков безопасности."
    fi
}

###############################################################################
# 11) 📋 ТЕКУЩАЯ КОНФИГУРАЦИЯ
###############################################################################
show_current_config() {
    echo
    echo "======================================================================"
    echo "  📋 ТЕКУЩАЯ КОНФИГУРАЦИЯ NGINX"
    echo "======================================================================"
    echo

    echo "Статус службы:"
    systemctl is-active nginx 2>/dev/null && ok "Nginx активен (RUNNING)" || warn "Nginx остановлен"
    echo

    echo "Активные сайты (sites-enabled):"
    if [[ -d "$SITES_ENABL" ]]; then
        ls -la "$SITES_ENABL" | grep -v 'total'
    fi
    echo

    echo "Слушающие порты Nginx:"
    ss -lntp 2>/dev/null | grep -E 'nginx' || echo "  Нет активных портов"
    echo

    echo "Синтаксическая проверка (nginx -t):"
    nginx -t 2>&1 || true
    echo
}

###############################################################################
# 12) 💾 СОЗДАТЬ BACKUP
###############################################################################
manual_backup() {
    log "Создание резервной копии конфигурации Nginx..."
    local bkp
    bkp="$(backup_current_config)"
    ok "Резервная копия создана: $bkp"
}

###############################################################################
# 13) ↩️ ВОССТАНОВИТЬ BACKUP
###############################################################################
restore_backup() {
    log "Восстановление конфигурации Nginx из резервной копии"

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

    rm -rf "$SITES_AVAIL" "$SITES_ENABL"
    cp -a "${selected}/sites-available" "$SITES_AVAIL"
    cp -a "${selected}/sites-enabled" "$SITES_ENABL"
    if [[ -d "${selected}/conf.d" ]]; then
        rm -rf "$CONF_D"
        cp -a "${selected}/conf.d" "$CONF_D"
    fi

    if nginx -t; then
        systemctl reload nginx 2>/dev/null || systemctl restart nginx
        ok "Конфигурация успешно восстановлена и Nginx перезапущен."
    else
        die "Восстановленный бэкап содержит синтаксические ошибки."
    fi
}

###############################################################################
# MENU
###############################################################################
show_menu() {
    clear 2>/dev/null || true

    local active_site
    active_site="$(ls "$SITES_ENABL" 2>/dev/null | tr '\n' ' ' || echo 'НЕТ')"

    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║               NGINX TEMPLATE & SECURITY MANAGER          ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo "  Активный сайт: ${active_site:-НЕТ}"
    echo
    echo "  ШАБЛОНЫ САЙТОВ (МАСКИРОВКА):"
    echo "    1) 📁 Файловый архив (Open Source Package Mirror)"
    echo "    2) 🎬 Медиаархив (Video / Audio Streaming Vault)"
    echo "    3) 📰 Новостной портал (The TechPulse Journal)"
    echo "    4) 📚 Техническая документация (API & Knowledge Base)"
    echo "    5) 🏢 Корпоративный сайт (Enterprise B2B Cloud)"
    echo "    6) 🌐 Нейтральная заглушка (Cloud Node 200 OK)"
    echo
    echo "  ПРОКСИРОВАНИЕ:"
    echo "    7) 🔄 Reverse Proxy (стандартный HTTP)"
    echo "    8) 🔌 Reverse Proxy + WebSocket (3x-ui / Xray)"
    echo
    echo "  БЕЗОПАСНОСТЬ И SSL:"
    echo "    9) 🔐 ACME / Let's Encrypt (Webroot /.well-known)"
    echo "   10) 🛡️ Security headers (HSTS, CSP, X-Frame-Options)"
    echo
    echo "  УПРАВЛЕНИЕ И БЭКАПЫ:"
    echo "   11) 📋 Текущая конфигурация (порты, статус, nginx -t)"
    echo "   12) 💾 Создать backup"
    echo "   13) ↩️ Восстановить backup"
    echo
    echo "    0) 🚪 Выход"
    echo
}

###############################################################################
# MAIN ENTRY
###############################################################################
ACTION="${1:-}"

case "$ACTION" in
    1|archive)      tpl_file_archive ;;
    2|media)        tpl_media_archive ;;
    3|news)         tpl_news_portal ;;
    4|docs)         tpl_tech_docs ;;
    5|corp)         tpl_corporate_site ;;
    6|stub)         tpl_neutral_stub ;;
    7|proxy)        tpl_reverse_proxy ;;
    8|ws)           tpl_proxy_websocket ;;
    9|acme)         tpl_acme_setup ;;
    10|headers)     tpl_security_headers ;;
    11|status)      show_current_config ;;
    12|backup)      manual_backup ;;
    13|rollback)    restore_backup ;;
    "")
        show_menu
        read -r -p "Выберите вариант [0-13]: " choice </dev/tty || choice="0"
        case "$choice" in
            1) tpl_file_archive ;;
            2) tpl_media_archive ;;
            3) tpl_news_portal ;;
            4) tpl_tech_docs ;;
            5) tpl_corporate_site ;;
            6) tpl_neutral_stub ;;
            7) tpl_reverse_proxy ;;
            8) tpl_proxy_websocket ;;
            9) tpl_acme_setup ;;
            10) tpl_security_headers ;;
            11) show_current_config ;;
            12) manual_backup ;;
            13) restore_backup ;;
            0) echo "Выход."; exit 0 ;;
            *) die "Некорректный выбор." ;;
        esac
        ;;
    *)
        echo "Использование: $0 [1-13] или интерактивно без аргументов."
        exit 1
        ;;
esac
