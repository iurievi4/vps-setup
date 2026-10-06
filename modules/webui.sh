#!/usr/bin/env bash
# ==============================================================================
# NaïveProxy Manager — Модуль веб-панели управления (webui.sh)
# ==============================================================================

webui_status() {
    if is_webui_ready; then
        echo "RUNNING"
        return 0
    elif [ -f "$WEB_SCRIPT_FILE" ]; then
        echo "STOPPED"
        return 1
    else
        echo "NOT_INSTALLED"
        return 1
    fi
}

restart_webui() {
    info "Перезапуск службы naiveproxy-webui..."
    systemctl restart naiveproxy-webui
    if is_webui_ready; then
        success "Web UI успешно перезапущен (127.0.0.1:$WEB_PORT)."
        return 0
    else
        error "Не удалось перезапустить Web UI. Проверьте: journalctl -u naiveproxy-webui -n 30"
        return 1
    fi
}

is_webui_ready() {
    [ ! -x "$WEB_SCRIPT_FILE" ] && return 1
    [ ! -f "$WEB_SERVICE_FILE" ] && return 1
    systemctl is-active --quiet naiveproxy-webui 2>/dev/null || return 1
    local check_port="${WEB_PORT:-18080}"
    if [ -f "$WEB_CREDS_FILE" ]; then
        local sp
        sp=$(grep -E '^WEB_PORT=' "$WEB_CREDS_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
        [ -n "$sp" ] && check_port="$sp"
    fi
    is_port_listening "$check_port" || return 1
    [ -f "$CADDY_FILE" ] && grep -q '/admin' "$CADDY_FILE" 2>/dev/null || return 1
    return 0
}


install_web_ui() {
    step "Настройка встроенной панели управления (Web UI)"

    if ! command -v qrencode &>/dev/null; then
        info "Установка пакета qrencode для генерации QR-кодов NekoBox..."
        apt-get update -qq && apt-get install -y -qq qrencode >/dev/null 2>&1 || true
    fi

    local chosen_port="${WEB_PORT:-18080}"
    if [ -f "$WEB_CREDS_FILE" ]; then
        local saved_port
        saved_port=$(grep -E '^WEB_PORT=' "$WEB_CREDS_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
        [ -n "$saved_port" ] && chosen_port="$saved_port"
    fi

    # Запрос порта у пользователя
    if [ -t 0 ]; then
        echo ""
        read -r -p "Введите порт для Web UI [по умолчанию: $chosen_port]: " in_port
        in_port=$(echo "$in_port" | tr -d '[:space:]')
        if [[ "$in_port" =~ ^[0-9]+$ ]] && [ "$in_port" -ge 1024 ] && [ "$in_port" -le 65535 ]; then
            if [ "$in_port" -eq 80 ] || [ "$in_port" -eq 443 ]; then
                warn "Порты 80 и 443 зарезервированы под Nginx и Caddy. Используется порт $chosen_port."
            else
                chosen_port="$in_port"
            fi
        elif [ -n "$in_port" ]; then
            warn "Некорректный номер порта '$in_port' (допустимо 1024-65535). Используется $chosen_port."
        fi
    fi
    WEB_PORT="$chosen_port"

    info "Развертывание панели NaïveProxy Manager (порт $WEB_PORT)..."

    # Создание системного пользователя naive-web
    if ! id -u naive-web &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin naive-web 2>/dev/null || true
    fi

    # Настройка прав на каталог /etc/naiveproxy (доступ для группы naive-web)
    mkdir -p "$NAIVE_DIR"
    chown root:naive-web "$NAIVE_DIR" 2>/dev/null || true
    chmod 775 "$NAIVE_DIR" 2>/dev/null || true

    # Идемпотентное сохранение/обновление реквизитов Web UI
    local web_user="admin"
    local web_pass=""
    local web_created=""
    if [ -f "$WEB_CREDS_FILE" ]; then
        web_user=$(grep -E '^WEB_USER=' "$WEB_CREDS_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
        [ -z "$web_user" ] && web_user="admin"
        web_pass=$(grep -E '^WEB_PASS=' "$WEB_CREDS_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
        web_created=$(grep -E '^CREATED_AT=' "$WEB_CREDS_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
    fi
    if [ -z "$web_pass" ]; then
        web_pass=$(generate_random_string 20)
    fi
    [ -z "$web_created" ] && web_created="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"

    cat << EOF > "$WEB_CREDS_FILE"
WEB_USER="$web_user"
WEB_PASS="$web_pass"
WEB_PORT="$WEB_PORT"
CREATED_AT="$web_created"
EOF
    chown root:naive-web "$WEB_CREDS_FILE" 2>/dev/null || true
    chmod 640 "$WEB_CREDS_FILE" 2>/dev/null || true

    [ -f "$CLIENT_CONFIG" ] && { chown root:naive-web "$CLIENT_CONFIG" 2>/dev/null || true; chmod 640 "$CLIENT_CONFIG" 2>/dev/null || true; }
    [ -f "$CREDS_FILE" ] && { chown root:naive-web "$CREDS_FILE" 2>/dev/null || true; chmod 640 "$CREDS_FILE" 2>/dev/null || true; }
    [ -f "$DOMAIN_CHECK_FILE" ] && { chown root:naive-web "$DOMAIN_CHECK_FILE" 2>/dev/null || true; chmod 640 "$DOMAIN_CHECK_FILE" 2>/dev/null || true; }

    # Создание изолированного вспомогательного скрипта управления (без зависимостей от install.sh)
    cat << 'EOF_HELPER' > "$HELPER_SCRIPT_FILE"
#!/bin/bash
set -euo pipefail
case "${1:-}" in
    check_services)
        c_stat=$(systemctl is-active caddy 2>/dev/null || echo "inactive")
        n_stat=$(systemctl is-active nginx 2>/dev/null || echo "inactive")
        echo "$c_stat $n_stat"
        ;;
    reload_caddy)
        /usr/local/bin/caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null || true
        ;;
    restart_caddy)
        systemctl restart caddy
        ;;
    diagnose)
        c_stat=$(systemctl is-active caddy 2>/dev/null || echo "inactive")
        n_stat=$(systemctl is-active nginx 2>/dev/null || echo "inactive")
        w_stat=$(systemctl is-active naiveproxy-webui 2>/dev/null || echo "inactive")
        echo "Caddy: $c_stat | Nginx: $n_stat | WebUI: $w_stat"
        ;;
    user_add)
        PAYLOAD="$(cat)"
        /usr/bin/python3 - "$PAYLOAD" << 'EOF_PYADD'
import sys, json, os, time, re, subprocess

try:
    payload = json.loads(sys.argv[1])
except Exception as e:
    print(json.dumps({'ok': False, 'error': f'Invalid JSON payload: {e}'}))
    sys.exit(1)

un = payload.get('username', '').strip()
pw = payload.get('password', '').strip()
note = payload.get('note', '').strip() or 'Клиент'

if not un or not pw:
    print(json.dumps({'ok': False, 'error': 'Логин и пароль обязательны'}))
    sys.exit(1)

users_file = '/etc/naiveproxy/users.json'
creds_file = '/etc/naiveproxy/credentials'
caddy_file = '/etc/caddy/Caddyfile'
clients_dir = '/etc/naiveproxy/clients'

users = []
if os.path.exists(users_file):
    try:
        with open(users_file, 'r', encoding='utf-8') as f:
            users = json.load(f)
    except Exception:
        users = []

if any(x.get('username') == un for x in users):
    print(json.dumps({'ok': False, 'error': f'Пользователь "{un}" уже существует'}))
    sys.exit(1)

now_str = time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())
users.append({'username': un, 'password': pw, 'note': note, 'created_at': now_str})

target_domain = ''
if os.path.exists(creds_file):
    try:
        with open(creds_file, 'r', encoding='utf-8') as f:
            for line in f:
                if line.startswith('DOMAIN='):
                    target_domain = line.split('=', 1)[1].strip().replace('"', '').replace("'", '')
    except Exception:
        pass

auth_lines = [f"        basic_auth {u['username']} {u['password']}" for u in users if u.get('username') and u.get('password')]
auth_block = chr(10).join(auth_lines) + chr(10) + '        hide_ip' + chr(10) + '        hide_via' + chr(10) + '        probe_resistance'

tmp_caddy = '/etc/caddy/Caddyfile.tmp'
try:
    with open(caddy_file, 'r', encoding='utf-8') as f:
        caddy_content = f.read()
    new_fp = 'forward_proxy {' + chr(10) + auth_block + chr(10) + '    }'
    new_content = re.sub(r'forward_proxy\s*\{[\s\S]*?\}', new_fp, caddy_content)
    with open(tmp_caddy, 'w', encoding='utf-8') as f:
        f.write(new_content)
except Exception as e:
    print(json.dumps({'ok': False, 'error': f'Ошибка подготовки Caddyfile: {e}'}))
    sys.exit(1)

val = subprocess.run(['/usr/local/bin/caddy', 'validate', '--config', tmp_caddy],
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
if val.returncode != 0:
    try: os.remove(tmp_caddy)
    except Exception: pass
    err = val.stderr.strip() or val.stdout.strip() or 'Ошибка валидации Caddyfile'
    print(json.dumps({'ok': False, 'error': f'Валидация Caddyfile отклонена: {err}'}))
    sys.exit(1)

try:
    os.replace(tmp_caddy, caddy_file)
except Exception as e:
    try: os.remove(tmp_caddy)
    except Exception: pass
    print(json.dumps({'ok': False, 'error': f'Не удалось сохранить Caddyfile: {e}'}))
    sys.exit(1)

try:
    with open(users_file, 'w', encoding='utf-8') as f:
        json.dump(users, f, indent=2, ensure_ascii=False)
    os.chmod(users_file, 0o664)
except Exception as e:
    print(json.dumps({'ok': False, 'error': f'Ошибка записи users.json: {e}'}))
    sys.exit(1)

try:
    os.makedirs(clients_dir, exist_ok=True)
    cfg = {'listen': 'socks://127.0.0.1:1080', 'proxy': f'https://{un}:{pw}@{target_domain}'}
    cfg_path = os.path.join(clients_dir, f'{un}.json')
    with open(cfg_path, 'w', encoding='utf-8') as out:
        json.dump(cfg, out, indent=2)
    os.chmod(cfg_path, 0o640)
except Exception:
    pass

subprocess.run(['/usr/local/bin/caddy', 'reload', '--config', caddy_file],
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

print(json.dumps({'ok': True}))
EOF_PYADD
        ;;
    user_del)
        PAYLOAD="$(cat)"
        /usr/bin/python3 - "$PAYLOAD" << 'EOF_PYDEL'
import sys, json, os, re, subprocess

try:
    payload = json.loads(sys.argv[1])
except Exception as e:
    print(json.dumps({'ok': False, 'error': f'Invalid JSON payload: {e}'}))
    sys.exit(1)

un = payload.get('username', '').strip()
if not un:
    print(json.dumps({'ok': False, 'error': 'Логин не указан'}))
    sys.exit(1)

users_file = '/etc/naiveproxy/users.json'
creds_file = '/etc/naiveproxy/credentials'
caddy_file = '/etc/caddy/Caddyfile'
clients_dir = '/etc/naiveproxy/clients'

users = []
if os.path.exists(users_file):
    try:
        with open(users_file, 'r', encoding='utf-8') as f:
            users = json.load(f)
    except Exception:
        users = []

if len(users) <= 1:
    print(json.dumps({'ok': False, 'error': 'Нельзя удалить последнего клиента'}))
    sys.exit(1)

new_users = [x for x in users if x.get('username') != un]
if len(new_users) == len(users):
    print(json.dumps({'ok': False, 'error': f'Пользователь "{un}" не найден'}))
    sys.exit(1)

auth_lines = [f"        basic_auth {u['username']} {u['password']}" for u in new_users if u.get('username') and u.get('password')]
auth_block = chr(10).join(auth_lines) + chr(10) + '        hide_ip' + chr(10) + '        hide_via' + chr(10) + '        probe_resistance'

tmp_caddy = '/etc/caddy/Caddyfile.tmp'
try:
    with open(caddy_file, 'r', encoding='utf-8') as f:
        caddy_content = f.read()
    new_fp = 'forward_proxy {' + chr(10) + auth_block + chr(10) + '    }'
    new_content = re.sub(r'forward_proxy\s*\{[\s\S]*?\}', new_fp, caddy_content)
    with open(tmp_caddy, 'w', encoding='utf-8') as f:
        f.write(new_content)
except Exception as e:
    print(json.dumps({'ok': False, 'error': f'Ошибка подготовки Caddyfile: {e}'}))
    sys.exit(1)

val = subprocess.run(['/usr/local/bin/caddy', 'validate', '--config', tmp_caddy],
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
if val.returncode != 0:
    try: os.remove(tmp_caddy)
    except Exception: pass
    err = val.stderr.strip() or val.stdout.strip() or 'Ошибка валидации Caddyfile'
    print(json.dumps({'ok': False, 'error': f'Валидация Caddyfile отклонена: {err}'}))
    sys.exit(1)

try:
    os.replace(tmp_caddy, caddy_file)
except Exception as e:
    try: os.remove(tmp_caddy)
    except Exception: pass
    print(json.dumps({'ok': False, 'error': f'Не удалось сохранить Caddyfile: {e}'}))
    sys.exit(1)

try:
    with open(users_file, 'w', encoding='utf-8') as f:
        json.dump(new_users, f, indent=2, ensure_ascii=False)
    os.chmod(users_file, 0o664)
except Exception as e:
    print(json.dumps({'ok': False, 'error': f'Ошибка записи users.json: {e}'}))
    sys.exit(1)

try:
    cfg_path = os.path.join(clients_dir, f'{un}.json')
    if os.path.exists(cfg_path):
        os.remove(cfg_path)
except Exception:
    pass

subprocess.run(['/usr/local/bin/caddy', 'reload', '--config', caddy_file],
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

print(json.dumps({'ok': True}))
EOF_PYDEL
        ;;
    sync_caddy)
        /usr/bin/python3 - << 'EOF_PYSYNC'
import os, json, re, subprocess
creds_file = '/etc/naiveproxy/credentials'
users_file = '/etc/naiveproxy/users.json'
caddy_file = '/etc/caddy/Caddyfile'
clients_dir = '/etc/naiveproxy/clients'
target_domain = ''
if os.path.exists(creds_file):
    try:
        with open(creds_file, 'r', encoding='utf-8') as f:
            for line in f:
                if line.startswith('DOMAIN='):
                    target_domain = line.split('=', 1)[1].strip().replace('"', '').replace("'", '')
    except Exception: pass
users = []
if os.path.exists(users_file):
    try:
        with open(users_file, 'r', encoding='utf-8') as f:
            users = json.load(f)
    except Exception: pass
if not users:
    sys.exit(1)

auth_lines = [f"        basic_auth {u['username']} {u['password']}" for u in users if u.get('username') and u.get('password')]
auth_block = chr(10).join(auth_lines) + chr(10) + '        hide_ip' + chr(10) + '        hide_via' + chr(10) + '        probe_resistance'

tmp_caddy = '/etc/caddy/Caddyfile.tmp'
if os.path.exists(caddy_file):
    try:
        with open(caddy_file, 'r', encoding='utf-8') as f:
            content = f.read()
        new_fp = 'forward_proxy {' + chr(10) + auth_block + chr(10) + '    }'
        new_content = re.sub(r'forward_proxy\s*\{[\s\S]*?\}', new_fp, content)
        with open(tmp_caddy, 'w', encoding='utf-8') as f:
            f.write(new_content)
        val = subprocess.run(['/usr/local/bin/caddy', 'validate', '--config', tmp_caddy],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if val.returncode == 0:
            os.replace(tmp_caddy, caddy_file)
            subprocess.run(['/usr/local/bin/caddy', 'reload', '--config', caddy_file],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            if os.path.exists(tmp_caddy): os.remove(tmp_caddy)
    except Exception:
        if os.path.exists(tmp_caddy): os.remove(tmp_caddy)

try:
    os.makedirs(clients_dir, exist_ok=True)
    for u in users:
        un = u.get('username')
        pw = u.get('password')
        if not un: continue
        cfg = {'listen': 'socks://127.0.0.1:1080', 'proxy': f'https://{un}:{pw}@{target_domain}'}
        cfg_path = os.path.join(clients_dir, f'{un}.json')
        with open(cfg_path, 'w', encoding='utf-8') as out:
            json.dump(cfg, out, indent=2)
        os.chmod(cfg_path, 0o640)
except Exception: pass
EOF_PYSYNC
        ;;
    *)
        echo "Unknown action" >&2
        exit 1
        ;;
esac
EOF_HELPER
    chmod 755 "$HELPER_SCRIPT_FILE"
    chown root:root "$HELPER_SCRIPT_FILE"

    # Sudoers для пользователя naive-web
    if [ -d /etc/sudoers.d ]; then
        cat << EOF > /etc/sudoers.d/naive-web
naive-web ALL=(ALL) NOPASSWD: $HELPER_SCRIPT_FILE
EOF
        chmod 440 /etc/sudoers.d/naive-web
    fi

    # Развертывание исполняемого скрипта Web UI
    cat << 'EOF_WEBUI' > "$WEB_SCRIPT_FILE"
#!/usr/bin/env python3
import os
import sys
import json
import secrets
import hashlib
import time
import subprocess
import urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler
from http.cookies import SimpleCookie

CREDS_FILE = '/etc/naiveproxy/credentials'
CLIENT_CONFIG = '/etc/naiveproxy/client.json'
WEB_CREDS_FILE = '/etc/naiveproxy/web_credentials'
USERS_FILE = '/etc/naiveproxy/users.json'
CLIENTS_DIR = '/etc/naiveproxy/clients'
CADDY_FILE = '/etc/caddy/Caddyfile'
HELPER_BIN = '/usr/local/bin/naiveproxy-helper'

def get_web_port():
    try:
        data = read_kv_file(WEB_CREDS_FILE)
        p = data.get('WEB_PORT')
        if p and p.isdigit():
            return int(p)
    except Exception:
        pass
    p_env = os.environ.get('WEB_PORT', '18080')
    return int(p_env) if p_env.isdigit() else 18080

HOST = os.environ.get('WEB_HOST', '127.0.0.1')

active_sessions = {} # token: (username, expiry_timestamp)
login_attempts = {} # ip: [timestamp1, timestamp2, ...]

def read_kv_file(filepath):
    data = {}
    if not os.path.exists(filepath):
        return data
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#') or '=' not in line:
                    continue
                k, v = line.split('=', 1)
                data[k.strip()] = v.strip().strip('"').strip("'").strip()
    except Exception:
        pass
    return data

def get_web_credentials():
    data = read_kv_file(WEB_CREDS_FILE)
    return data.get('WEB_USER', 'admin'), data.get('WEB_PASS', '')

def verify_session(cookie_str, auth_header=None):
    # 1. Check Bearer token from Authorization header
    if auth_header and "Bearer " in auth_header:
        token = auth_header.split("Bearer ", 1)[1].strip()
        if token in active_sessions:
            user, exp = active_sessions[token]
            if time.time() < exp:
                return True
            else:
                del active_sessions[token]

    # 2. Check session_id cookie
    if cookie_str:
        cookie = SimpleCookie()
        try:
            cookie.load(cookie_str)
            token = cookie.get('session_id')
            if token and token.value in active_sessions:
                user, exp = active_sessions[token.value]
                if time.time() < exp:
                    return True
                else:
                    del active_sessions[token.value]
        except Exception:
            pass
    return False

import re

def sync_users_to_caddy():
    try:
        res = subprocess.run(['sudo', HELPER_BIN, 'sync_caddy'],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=10)
        if res.returncode == 0:
            return True, 'OK'
        err = res.stderr.strip() or res.stdout.strip() or 'Ошибка выполнения'
        return False, err
    except Exception as e:
        return False, str(e)

HTML_DASHBOARD = r"""<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>NaïveProxy + Caddy Manager</title>
    <style>
        :root {
            --bg: #0d1117; --card-bg: #161b22; --border: #30363d;
            --text: #f0f6fc; --muted: #8b949e; --accent: #58a6ff;
            --green: #238636; --green-txt: #3fb950; --red-txt: #f85149;
            --yellow: #d29922; --code: #090d13;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: var(--bg); color: var(--text); min-height: 100vh; display: flex; flex-direction: column; align-items: center; padding: 24px 16px; }
        .container { width: 100%; max-width: 860px; }
        .header { text-align: center; margin-bottom: 24px; }
        .header h1 { font-size: 22px; font-weight: 700; margin-bottom: 6px; }
        .header p { color: var(--muted); font-size: 14px; }
        .card { background: var(--card-bg); border: 1px solid var(--border); border-radius: 10px; padding: 20px; margin-bottom: 18px; box-shadow: 0 4px 12px rgba(0,0,0,0.3); }
        .card-title { font-size: 15px; font-weight: 600; margin-bottom: 14px; display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid var(--border); padding-bottom: 10px; }
        .grid-status { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 12px; margin-bottom: 16px; }
        .status-item { background: var(--code); border: 1px solid var(--border); padding: 12px 14px; border-radius: 8px; display: flex; flex-direction: column; gap: 4px; }
        .status-label { font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.5px; }
        .status-val { font-size: 14px; font-weight: 600; display: flex; align-items: center; gap: 6px; }
        .dot { width: 9px; height: 9px; border-radius: 50%; display: inline-block; }
        .dot-green { background: var(--green-txt); box-shadow: 0 0 8px var(--green-txt); }
        .dot-red { background: var(--red-txt); box-shadow: 0 0 8px var(--red-txt); }
        .dot-yellow { background: var(--yellow); box-shadow: 0 0 8px var(--yellow); }
        .meta-table { width: 100%; border-collapse: collapse; font-size: 13px; margin-bottom: 16px; }
        .meta-table td { padding: 8px 6px; border-bottom: 1px solid #21262d; }
        .meta-table td:first-child { color: var(--muted); width: 35%; }
        .meta-table td:last-child { font-family: monospace; font-weight: 600; }
        .btn-group { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 10px; }
        button, .btn { background: var(--border); color: var(--text); border: 1px solid var(--border); padding: 9px 14px; font-size: 13px; font-weight: 600; border-radius: 6px; cursor: pointer; display: inline-flex; align-items: center; justify-content: center; gap: 6px; text-decoration: none; transition: background 0.15s; }
        button:hover, .btn:hover { background: #38424d; }
        button.btn-accent { background: #1f6feb; color: #fff; }
        button.btn-accent:hover { background: #388bfd; }
        button.btn-primary { background: var(--green); color: #fff; }
        button.btn-primary:hover { background: #2ea043; }
        button.btn-danger { background: #b62324; color: #fff; }
        button.btn-danger:hover { background: #d03535; }
        pre.code-block { background: var(--code); border: 1px solid var(--border); border-radius: 8px; padding: 14px; font-family: monospace; font-size: 13px; color: #7ee787; overflow-x: auto; white-space: pre-wrap; word-break: break-all; }
        .console-output { background: #000; border: 1px solid var(--border); border-radius: 8px; padding: 14px; font-family: monospace; font-size: 12px; color: #58a6ff; max-height: 320px; overflow-y: auto; white-space: pre-wrap; display: none; margin-top: 14px; }
        .login-box { max-width: 360px; margin: 60px auto; background: var(--card-bg); border: 1px solid var(--border); padding: 30px; border-radius: 10px; box-shadow: 0 8px 24px rgba(0,0,0,0.5); }
        .input-group { margin-bottom: 16px; }
        .input-group label { display: block; font-size: 13px; margin-bottom: 6px; color: var(--muted); }
        .input-group input { width: 100%; padding: 10px 12px; background: var(--code); border: 1px solid var(--border); border-radius: 6px; color: #fff; font-size: 14px; }
        .input-group input:focus { outline: none; border-color: var(--accent); }
        .toast { position: fixed; bottom: 24px; right: 24px; background: var(--green); color: #fff; padding: 10px 20px; border-radius: 6px; font-size: 13px; font-weight: 600; display: none; box-shadow: 0 4px 12px rgba(0,0,0,0.4); z-index: 3000; }
        .user-card { background: var(--code); border: 1px solid var(--border); border-radius: 8px; padding: 14px 16px; margin-bottom: 10px; display: flex; flex-direction: column; gap: 8px; }
        .user-card-header { display: flex; justify-content: space-between; align-items: center; }
        .user-name { font-weight: 700; font-size: 15px; color: var(--accent); display: flex; align-items: center; gap: 8px; }
        .user-badge { font-size: 11px; background: #21262d; border: 1px solid var(--border); color: var(--muted); padding: 2px 8px; border-radius: 12px; font-weight: normal; }
        .user-pass-row { font-size: 12px; color: var(--muted); font-family: monospace; display: flex; align-items: center; gap: 8px; word-break: break-all; }
        .modal-overlay { display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.7); z-index: 2000; align-items: center; justify-content: center; }
    </style>
</head>
<body>
    <div id="toast" class="toast">Готово!</div>
    
    <!-- Modal Add User -->
    <div id="addUserModal" class="modal-overlay">
        <div class="card" style="width:100%; max-width:440px; margin:20px;">
            <div class="card-title">
                <span>Добавление клиента NaïveProxy</span>
                <button onclick="closeAddUserModal()" style="padding:2px 8px;">✕</button>
            </div>
            <form action="javascript:void(0);" method="POST" onsubmit="return submitAddUser(event);">
                <div class="input-group">
                    <label>Логин клиента</label>
                    <div style="display:flex; gap:8px;">
                        <input type="text" id="newClientUser" required autocomplete="off">
                        <button type="button" onclick="genClientUser()" style="white-space:nowrap;">🎲 Авто</button>
                    </div>
                </div>
                <div class="input-group">
                    <label>Пароль клиента</label>
                    <div style="display:flex; gap:8px;">
                        <input type="text" id="newClientPass" required autocomplete="off">
                        <button type="button" onclick="genClientPass()" style="white-space:nowrap;">🎲 Авто</button>
                    </div>
                </div>
                <div class="input-group">
                    <label>Примечание / Устройство (необязательно)</label>
                    <input type="text" id="newClientNote" placeholder="например, Телефон / Иван">
                </div>
                <div style="display:flex; gap:10px; margin-top:14px;">
                    <button type="submit" class="btn-primary" style="flex:1;">Создать клиента</button>
                    <button type="button" onclick="closeAddUserModal()">Отмена</button>
                </div>
            </form>
        </div>
    </div>

    <!-- Modal QR Code for NekoBox -->
    <div id="qrModal" class="modal-overlay">
        <div class="card" style="width:100%; max-width:440px; margin:20px; text-align:center;">
            <div class="card-title">
                <span id="qrModalTitle">📱 QR-код для NekoBox</span>
                <button onclick="closeQrModal()" style="padding:2px 8px;">✕</button>
            </div>
            <div style="background:#ffffff; padding:14px; border-radius:10px; display:inline-block; margin:12px auto 8px; box-shadow:0 4px 16px rgba(0,0,0,0.4);">
                <img id="qrImg" src="" alt="QR Code" style="width:230px; height:230px; display:block;" />
            </div>
            <p style="font-size:12px; color:var(--muted); margin-bottom:12px; line-height:1.4;">
                Отсканируйте камерой в <b>NekoBox</b> / <b>v2rayN</b> / <b>Matsuri</b> или скопируйте ссылку:
            </p>
            <div class="input-group" style="margin-bottom:12px;">
                <input type="text" id="qrNekoboxLink" readonly style="font-size:11px; font-family:monospace; text-align:center; background:var(--code); color:#7ee787;" onclick="this.select()" />
            </div>
            <div style="display:flex; gap:10px;">
                <button onclick="copyQrLink()" class="btn-accent" style="flex:1;">📋 Скопировать ссылку</button>
                <button onclick="closeQrModal()">Закрыть</button>
            </div>
        </div>
    </div>

    <div class="container" id="app">
        <div class="login-box">
            <div class="header">
                <h1>NaïveProxy Manager</h1>
                <p>Вход в панель управления</p>
            </div>
            <div id="loginError" style="background:rgba(248,81,73,0.15); border:1px solid var(--red-txt); color:var(--red-txt); padding:8px 12px; border-radius:6px; font-size:13px; margin-bottom:14px; text-align:center; display:none;"></div>
            <form action="javascript:void(0);" method="POST" onsubmit="return handleLogin(event);">
                <div class="input-group">
                    <label>Логин администратора</label>
                    <input type="text" id="username" required autofocus autocomplete="username" value="admin">
                </div>
                <div class="input-group">
                    <label>Пароль</label>
                    <input type="password" id="password" required autocomplete="current-password">
                </div>
                <button type="submit" id="loginSubmitBtn" class="btn-primary" style="width: 100%; padding: 12px;">Войти</button>
            </form>
        </div>
    </div>

    <script>
        const API_BASE = window.location.pathname.startsWith('/admin') ? '/admin' : '';
        function apiUrl(endpoint) {
            return API_BASE + '/' + endpoint.replace(/^[/]+/, '');
        }

        function showToast(msg) {
            const t = document.getElementById('toast');
            t.innerText = msg;
            t.style.display = 'block';
            setTimeout(() => { t.style.display = 'none'; }, 2500);
        }

        function renderError(msg) {
            document.getElementById('app').innerHTML = `
                <div class="card" style="max-width: 520px; margin: 60px auto; text-align: center;">
                    <div style="font-size: 36px; margin-bottom: 12px;">⚠️</div>
                    <h2 style="font-size: 18px; margin-bottom: 8px; color: var(--red-txt);">Ошибка загрузки панели</h2>
                    <p style="font-size: 13px; color: var(--muted); margin-bottom: 18px; line-height: 1.5;">${msg}</p>
                    <div style="display:flex; gap:10px; justify-content:center;">
                        <button onclick="renderLogin()" class="btn-primary">Форма входа</button>
                        <button onclick="fetchStatus()">Повторить попытку</button>
                    </div>
                </div>
            `;
        }

        function getAuthHeaders(extra = {}) {
            const h = { ...extra };
            const tok = sessionStorage.getItem('np_auth_token');
            if (tok) {
                h['Authorization'] = 'Bearer ' + tok;
            }
            return h;
        }

        async function fetchWithAuth(endpoint, options = {}) {
            options.headers = getAuthHeaders(options.headers || {});
            options.credentials = 'same-origin';
            return fetch(apiUrl(endpoint), options);
        }

        async function fetchStatus() {
            try {
                const res = await fetchWithAuth('api/status');
                if (res.status === 401) {
                    sessionStorage.removeItem('np_auth_token');
                    renderLogin();
                    return;
                }
                if (!res.ok) {
                    renderError('Сервер вернул статус HTTP ' + res.status + ' (' + res.statusText + '). Убедитесь, что служба naiveproxy-webui запущена.');
                    return;
                }
                const data = await res.json();
                renderDashboard(data);
                fetchUsers();
            } catch (e) {
                console.error(e);
                const app = document.getElementById('app');
                if (!app.innerHTML || !app.querySelector('.login-box')) {
                    renderError('Ошибка подключения к API: ' + e + '<br><small style="color:var(--muted)">Если вы открыли страницу без слэша в конце, перейдите по адресу <a href="/admin/" style="color:var(--accent)">/admin/</a></small>');
                }
            }
        }

        function showLoginError(msg, savedUser = 'admin') {
            const errEl = document.getElementById('loginError');
            if (errEl) {
                errEl.innerText = msg;
                errEl.style.display = 'block';
            } else {
                renderLogin(msg, savedUser);
            }
        }

        function renderLogin(errorMsg = '', savedUser = 'admin') {
            document.getElementById('app').innerHTML = `
                <div class="login-box">
                    <div class="header">
                        <h1>NaïveProxy Manager</h1>
                        <p>Вход в панель управления</p>
                    </div>
                    <div id="loginError" style="background:rgba(248,81,73,0.15); border:1px solid var(--red-txt); color:var(--red-txt); padding:8px 12px; border-radius:6px; font-size:13px; margin-bottom:14px; text-align:center; display:${errorMsg ? 'block' : 'none'};">${errorMsg || ''}</div>
                    <form action="javascript:void(0);" method="POST" onsubmit="return handleLogin(event);">
                        <div class="input-group">
                            <label>Логин администратора</label>
                            <input type="text" id="username" required autofocus autocomplete="username" value="${savedUser}">
                        </div>
                        <div class="input-group">
                            <label>Пароль</label>
                            <input type="password" id="password" required autocomplete="current-password">
                        </div>
                        <button type="submit" id="loginSubmitBtn" class="btn-primary" style="width: 100%; padding: 12px;">Войти</button>
                    </form>
                </div>
            `;
        }

        function handleLogin(e) {
            if (e) {
                if (e.preventDefault) e.preventDefault();
                if (e.stopPropagation) e.stopPropagation();
            }
            doLogin();
            return false;
        }

        async function doLogin() {
            const uEl = document.getElementById('username');
            const pEl = document.getElementById('password');
            if (!uEl || !pEl) return;
            const u = uEl.value.trim();
            const p = pEl.value.trim();
            if (!p) {
                showLoginError('Введите пароль', u);
                return;
            }
            const btn = document.getElementById('loginSubmitBtn');
            if (btn) { btn.disabled = true; btn.innerText = 'Проверка...'; }

            try {
                const res = await fetch(apiUrl('api/login'), {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ username: u, password: p })
                });
                const data = await res.json();
                if (data.ok) {
                    if (data.token) {
                        sessionStorage.setItem('np_auth_token', data.token);
                    }
                    showToast('Вход выполнен успешно!');
                    await fetchStatus();
                } else {
                    showLoginError(data.error || 'Неверный логин или пароль', u);
                    if (btn) { btn.disabled = false; btn.innerText = 'Войти'; }
                }
            } catch (err) {
                showLoginError('Ошибка связи с сервером: ' + err, u);
                if (btn) { btn.disabled = false; btn.innerText = 'Войти'; }
            }
        }

        async function handleLogout() {
            sessionStorage.removeItem('np_auth_token');
            await fetchWithAuth('api/logout', { method: 'POST' }).catch(() => {});
            renderLogin();
        }

        async function restartCaddy() {
            showToast('Перезапуск службы Caddy...');
            try {
                const res = await fetchWithAuth('api/action/restart_caddy', { method: 'POST' });
                const d = await res.json();
                showToast(d.msg || 'Caddy перезапущен!');
                setTimeout(fetchStatus, 1500);
            } catch (e) {
                alert('Ошибка: ' + e);
            }
        }

        async function runDiagnose() {
            const outBox = document.getElementById('consoleBox');
            outBox.style.display = 'block';
            outBox.innerText = 'Запуск аудита системы... Пожалуйста, подождите 3-5 секунд...';
            try {
                const res = await fetchWithAuth('api/action/diagnose', { method: 'POST' });
                const d = await res.json();
                outBox.innerText = d.output || 'Диагностика завершена.';
            } catch (e) {
                outBox.innerText = 'Ошибка выполнения: ' + e;
            }
        }

        function copyText(txt) {
            navigator.clipboard.writeText(txt).then(() => {
                showToast('Скопировано в буфер обмена!');
            });
        }

        function openAddUserModal() {
            document.getElementById('newClientUser').value = 'user_' + Math.random().toString(36).substring(2, 8);
            document.getElementById('newClientPass').value = Math.random().toString(36).substring(2, 10) + Math.random().toString(36).substring(2, 10);
            document.getElementById('newClientNote').value = '';
            document.getElementById('addUserModal').style.display = 'flex';
        }

        function closeAddUserModal() {
            document.getElementById('addUserModal').style.display = 'none';
        }

        function showQrModal(username, nekoboxLink) {
            document.getElementById('qrModalTitle').innerText = '📱 QR-код для NekoBox (' + username + ')';
            document.getElementById('qrNekoboxLink').value = nekoboxLink;
            document.getElementById('qrImg').src = apiUrl('api/qr/' + encodeURIComponent(username)) + '?t=' + Date.now();
            document.getElementById('qrModal').style.display = 'flex';
        }

        function closeQrModal() {
            document.getElementById('qrModal').style.display = 'none';
        }

        function copyQrLink() {
            const link = document.getElementById('qrNekoboxLink').value;
            copyText(link);
        }

        function genClientUser() {
            document.getElementById('newClientUser').value = 'user_' + Math.random().toString(36).substring(2, 8);
        }

        function genClientPass() {
            document.getElementById('newClientPass').value = Math.random().toString(36).substring(2, 10) + Math.random().toString(36).substring(2, 10);
        }

        function submitAddUser(e) {
            if (e) {
                if (e.preventDefault) e.preventDefault();
                if (e.stopPropagation) e.stopPropagation();
            }
            doAddUser();
            return false;
        }

        async function doAddUser() {
            const u = document.getElementById('newClientUser').value.trim();
            const p = document.getElementById('newClientPass').value.trim();
            const n = document.getElementById('newClientNote').value.trim() || 'Клиент';
            try {
                const res = await fetchWithAuth('api/users/add', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ username: u, password: p, note: n })
                });
                const d = await res.json();
                if (d.ok) {
                    closeAddUserModal();
                    showToast('Клиент ' + u + ' успешно создан!');
                    fetchUsers();
                } else {
                    alert('Ошибка создания: ' + (d.error || 'неизвестная ошибка'));
                }
            } catch (err) {
                alert('Сбой связи: ' + err);
            }
        }

        async function deleteUser(username) {
            if (!confirm('Вы уверены, что хотите удалить клиента ' + username + '? Доступ для него будет заблокирован.')) {
                return;
            }
            try {
                const res = await fetchWithAuth('api/users/delete', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ username: username })
                });
                const d = await res.json();
                if (d.ok) {
                    showToast('Клиент ' + username + ' удален.');
                    fetchUsers();
                } else {
                    alert('Ошибка: ' + (d.error || 'Нельзя удалить последнего клиента'));
                }
            } catch (err) {
                alert('Сбой связи: ' + err);
            }
        }

        async function fetchUsers() {
            const listEl = document.getElementById('usersList');
            if (!listEl) return;
            try {
                const res = await fetchWithAuth('api/users');
                const users = await res.json();
                if (!users || users.length === 0) {
                    listEl.innerHTML = '<p style="color:var(--muted); font-size:13px;">Клиенты не настроены.</p>';
                    return;
                }
                let html = '';
                users.forEach((u, i) => {
                    html += `
                        <div class="user-card">
                            <div class="user-card-header">
                                <div class="user-name">
                                    <span>👤 ${u.username}</span>
                                    <span class="user-badge">${u.note || 'Клиент'}</span>
                                </div>
                                <div style="display:flex; gap:6px; flex-wrap:wrap;">
                                    <button onclick="showQrModal('${u.username}', '${u.nekobox_link || u.link}')" style="padding:4px 8px; font-size:12px; background:#1f6feb; color:#fff;">📱 QR (NekoBox)</button>
                                    <button onclick="copyText('${u.nekobox_link || u.link}')" style="padding:4px 8px; font-size:12px;">📋 Ссылка</button>
                                    <a href="${apiUrl('download/client/' + u.username)}" download="client-${u.username}.json" class="btn" style="padding:4px 8px; font-size:12px;">💾 .json</a>
                                    ${users.length > 1 ? `<button onclick="deleteUser('${u.username}')" class="btn-danger" style="padding:4px 8px; font-size:12px;">🗑</button>` : ''}
                                </div>
                            </div>
                            <div class="user-pass-row">
                                <span>Пароль: <b>${u.password}</b></span>
                                <span style="margin-left:auto; color:var(--muted); font-size:11px;">${u.created_at ? u.created_at.substring(0, 10) : ''}</span>
                            </div>
                        </div>
                    `;
                });
                listEl.innerHTML = html;
            } catch (e) {
                listEl.innerHTML = '<p style="color:var(--red-txt); font-size:13px;">Ошибка загрузки клиентов.</p>';
            }
        }

        function renderDashboard(data) {
            const caddyDot = data.caddy_active ? 'dot-green' : 'dot-red';
            const caddyText = data.caddy_active ? 'RUNNING (:443)' : 'STOPPED';
            const nginxDot = data.nginx_active ? 'dot-green' : 'dot-red';
            const nginxText = data.nginx_active ? 'RUNNING (:80)' : 'STOPPED';
            const naiveDot = data.naive_installed ? 'dot-green' : 'dot-yellow';
            const naiveText = data.naive_installed ? 'INSTALLED' : 'NOT DETECTED';
            const tlsDot = data.tls_status === 'VALID' ? 'dot-green' : 'dot-yellow';

            document.getElementById('app').innerHTML = `
                <div class="header">
                    <h1>NAÏVEPROXY + CADDY MANAGER</h1>
                    <p>Панель мониторинга и управления прокси-сервером</p>
                </div>

                <div class="card">
                    <div class="card-title">
                        <span>Состояние сервисов</span>
                        <button onclick="handleLogout()" style="padding: 4px 10px; font-size: 12px;">Выйти</button>
                    </div>
                    <div class="grid-status">
                        <div class="status-item">
                            <span class="status-label">Caddy Server</span>
                            <span class="status-val"><span class="dot ${caddyDot}"></span>${caddyText}</span>
                        </div>
                        <div class="status-item">
                            <span class="status-label">NaïveProxy Module</span>
                            <span class="status-val"><span class="dot ${naiveDot}"></span>${naiveText}</span>
                        </div>
                        <div class="status-item">
                            <span class="status-label">Nginx Stub</span>
                            <span class="status-val"><span class="dot ${nginxDot}"></span>${nginxText}</span>
                        </div>
                        <div class="status-item">
                            <span class="status-label">HTTPS (TLS-ALPN)</span>
                            <span class="status-val"><span class="dot ${tlsDot}"></span>${data.tls_status}</span>
                        </div>
                    </div>

                    <table class="meta-table">
                        <tr><td>Домен:</td><td>${data.domain || 'N/A'}</td></tr>
                        <tr><td>VPS IPv4:</td><td>${data.server_ip || 'N/A'}</td></tr>
                        <tr><td>Порт Web UI:</td><td>${data.web_port || '18080'} (открыт в UFW)</td></tr>
                        <tr><td>TLS эмитент:</td><td>${data.tls_issuer || 'Let\'s Encrypt'}</td></tr>
                    </table>

                    <div class="btn-group">
                        <button onclick="restartCaddy()" class="btn-accent">🔄 Перезапустить Caddy</button>
                        <button onclick="runDiagnose()">🔍 Диагностика</button>
                        <button onclick="fetchStatus()">⚡ Обновить статус</button>
                    </div>

                    <pre id="consoleBox" class="console-output"></pre>
                </div>

                <div class="card">
                    <div class="card-title">
                        <span>👥 Пользователи NaïveProxy (Клиенты)</span>
                        <button onclick="openAddUserModal()" class="btn-primary" style="padding: 4px 12px; font-size: 12px;">+ Создать клиента</button>
                    </div>
                    <div id="usersList">
                        <p style="color:var(--muted); font-size:13px;">Загрузка списка клиентов...</p>
                    </div>
                </div>
            `;
        }

        fetchStatus();
    </script>
</body>
</html>
"""

class RequestHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def send_json(self, data, code=200, headers=None):
        payload = json.dumps(data).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(payload)))
        if headers:
            for k, v in headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if path == '/' or path == '/index.html':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.end_headers()
            self.wfile.write(HTML_DASHBOARD.encode('utf-8'))
            return

        is_auth = verify_session(self.headers.get('Cookie'), self.headers.get('Authorization'))

        if path == '/api/status':
            if not is_auth:
                self.send_json({"error": "Unauthorized"}, code=401)
                return

            creds = read_kv_file(CREDS_FILE)
            dcheck = read_kv_file('/etc/naiveproxy/domain-check')
            wcreds = read_kv_file(WEB_CREDS_FILE)
            
            caddy_active = False
            nginx_active = False
            try:
                res = subprocess.run(['sudo', HELPER_BIN, 'check_services'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=5)
                out = res.stdout.strip().split()
                if len(out) >= 2:
                    caddy_active = (out[0] == 'active')
                    nginx_active = (out[1] == 'active')
            except Exception:
                pass

            resp = {
                "caddy_active": caddy_active,
                "nginx_active": nginx_active,
                "naive_installed": os.path.exists(CREDS_FILE),
                "domain": creds.get('DOMAIN', dcheck.get('DOMAIN', '')),
                "server_ip": creds.get('SERVER_IPV4', dcheck.get('SERVER_IPV4', '')),
                "web_port": wcreds.get('WEB_PORT', str(get_web_port())),
                "tls_status": "VALID" if caddy_active else "PENDING",
                "tls_issuer": "Let's Encrypt (TLS-ALPN-01)"
            }
            self.send_json(resp)
            return

        if path == '/api/users':
            if not is_auth:
                self.send_json({"error": "Unauthorized"}, code=401)
                return

            creds = read_kv_file(CREDS_FILE)
            target_domain = creds.get('DOMAIN', '')
            users_list = []
            if os.path.exists(USERS_FILE):
                try:
                    with open(USERS_FILE, 'r', encoding='utf-8') as f:
                        users_list = json.load(f)
                except Exception:
                    pass
            elif os.path.exists(CREDS_FILE):
                # Fallback to single user in credentials
                u = creds.get('USERNAME')
                p = creds.get('PASSWORD')
                if u and p:
                    users_list = [{
                        'username': u,
                        'password': p,
                        'created_at': creds.get('CREATED_AT', ''),
                        'note': 'Основной'
                    }]

            for u in users_list:
                u['link'] = f"https://{u['username']}:{u['password']}@{target_domain}:443"
                u['nekobox_link'] = f"naive+https://{u['username']}:{u['password']}@{target_domain}:443#Naive-{u['username']}"

            self.send_json(users_list)
            return

        if path.startswith('/api/qr/'):
            if not is_auth:
                self.send_response(401)
                self.end_headers()
                return

            username = path.replace('/api/qr/', '').split('?')[0].strip()
            creds = read_kv_file(CREDS_FILE)
            target_domain = creds.get('DOMAIN', '')
            found_user = None
            if os.path.exists(USERS_FILE):
                try:
                    with open(USERS_FILE, 'r', encoding='utf-8') as f:
                        for u in json.load(f):
                            if u.get('username') == username:
                                found_user = u
                                break
                except Exception:
                    pass
            if not found_user and os.path.exists(CREDS_FILE):
                if creds.get('USERNAME') == username:
                    found_user = {'username': username, 'password': creds.get('PASSWORD')}

            if not found_user:
                self.send_response(404)
                self.end_headers()
                return

            u_name = found_user['username']
            u_pass = found_user['password']
            nekobox_link = f"naive+https://{u_name}:{u_pass}@{target_domain}:443#Naive-{u_name}"

            try:
                res = subprocess.run(['qrencode', '-s', '6', '-m', '2', '-l', 'M', '-t', 'SVG', '-o', '-', nekobox_link],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=5)
                if res.returncode == 0 and res.stdout:
                    svg_data = res.stdout.encode('utf-8')
                    self.send_response(200)
                    self.send_header('Content-Type', 'image/svg+xml')
                    self.send_header('Cache-Control', 'no-cache')
                    self.send_header('Content-Length', str(len(svg_data)))
                    self.end_headers()
                    self.wfile.write(svg_data)
                    return
            except Exception:
                pass

            svg_err = ('<svg xmlns="http://www.w3.org/2000/svg" width="230" height="230" viewBox="0 0 230 230">'
                       '<rect width="100%" height="100%" fill="#161b22"/>'
                       '<text x="50%" y="45%" text-anchor="middle" fill="#f85149" font-size="12" font-family="sans-serif">qrencode не установлен</text>'
                       '<text x="50%" y="60%" text-anchor="middle" fill="#8b949e" font-size="11" font-family="sans-serif">apt install qrencode</text>'
                       '</svg>').encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'image/svg+xml')
            self.send_header('Content-Length', str(len(svg_err)))
            self.end_headers()
            self.wfile.write(svg_err)
            return

        if path.startswith('/download/client/'):
            if not is_auth:
                self.send_response(401)
                self.end_headers()
                return

            username = path.replace('/download/client/', '').replace('.json', '').strip()
            user_cfg_path = os.path.join(CLIENTS_DIR, f"{username}.json")
            if not os.path.exists(user_cfg_path) and os.path.exists(CLIENT_CONFIG):
                user_cfg_path = CLIENT_CONFIG

            if os.path.exists(user_cfg_path):
                with open(user_cfg_path, 'rb') as f:
                    content = f.read()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Disposition', f'attachment; filename="client-{username}.json"')
                self.send_header('Content-Length', str(len(content)))
                self.end_headers()
                self.wfile.write(content)
            else:
                self.send_response(404)
                self.end_headers()
            return

        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length) if length > 0 else b'{}'
        try:
            req_data = json.loads(body.decode('utf-8'))
        except Exception:
            req_data = {}

        if path == '/api/login':
            client_ip = self.client_address[0] if self.client_address else '127.0.0.1'
            now = time.time()
            attempts = [t for t in login_attempts.get(client_ip, []) if now - t < 60]
            login_attempts[client_ip] = attempts
            if len(attempts) >= 5:
                self.send_json({"ok": False, "error": "Слишком много неудачных попыток. Подождите 1 минуту."}, code=429)
                return

            u_input = req_data.get('username', '').strip()
            p_input = req_data.get('password', '').strip()

            expected_u, expected_p = get_web_credentials()

            expected_u = expected_u.strip()
            expected_p = expected_p.strip()

            if expected_p and secrets.compare_digest(u_input, expected_u) and secrets.compare_digest(p_input, expected_p):
                token = secrets.token_hex(24)
                active_sessions[token] = (u_input, time.time() + 86400 * 7) # 7 days
                cookie_header = f'session_id={token}; Path=/; HttpOnly; SameSite=Lax'
                self.send_json({"ok": True, "token": token}, headers={"Set-Cookie": cookie_header})
            else:
                login_attempts.setdefault(client_ip, []).append(time.time())
                self.send_json({"ok": False, "error": "Неверный логин или пароль"}, code=401)
            return

        if path == '/api/logout':
            cookie_str = self.headers.get('Cookie')
            if cookie_str:
                cookie = SimpleCookie()
                try:
                    cookie.load(cookie_str)
                    token = cookie.get('session_id')
                    if token and token.value in active_sessions:
                        del active_sessions[token.value]
                except Exception:
                    pass
            self.send_json({"ok": True}, headers={"Set-Cookie": "session_id=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT"})
            return

        # Защищенные операции
        if not verify_session(self.headers.get('Cookie'), self.headers.get('Authorization')):
            self.send_json({"error": "Unauthorized"}, code=401)
            return

        if path == '/api/action/restart_caddy':
            try:
                subprocess.run(['sudo', HELPER_BIN, 'restart_caddy'], check=True, timeout=10)
                self.send_json({"ok": True, "msg": "Служба Caddy успешно перезапущена."})
            except Exception as e:
                self.send_json({"ok": False, "error": str(e)}, code=500)
            return

        if path == '/api/action/diagnose':
            try:
                res = subprocess.run(['sudo', HELPER_BIN, 'diagnose'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=20)
                self.send_json({"ok": True, "output": res.stdout or res.stderr})
            except Exception as e:
                self.send_json({"ok": False, "output": f"Ошибка: {e}"}, code=500)
            return

        if path == '/api/users/add':
            u = req_data.get('username', '').strip()
            p = req_data.get('password', '').strip()
            n = req_data.get('note', '').strip() or 'Клиент'
            if not u or not p:
                self.send_json({"ok": False, "error": "Логин и пароль обязательны"}, code=400)
                return

            try:
                payload = json.dumps({'username': u, 'password': p, 'note': n})
                p_sub = subprocess.Popen(['sudo', HELPER_BIN, 'user_add'],
                                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                out, err = p_sub.communicate(input=payload, timeout=10)
                out = (out or '').strip()
                try:
                    result = json.loads(out)
                    if result.get('ok'):
                        self.send_json({"ok": True})
                    else:
                        self.send_json({"ok": False, "error": result.get('error', 'Ошибка добавления')}, code=400)
                except Exception:
                    err_msg = (err or '').strip() or out or 'Ошибка выполнения'
                    self.send_json({"ok": False, "error": f"Ошибка добавления: {err_msg}"}, code=500)
            except Exception as e:
                self.send_json({"ok": False, "error": f"Ошибка вызова helper: {e}"}, code=500)
            return

        if path == '/api/users/delete':
            u = req_data.get('username', '').strip()
            if not u:
                self.send_json({"ok": False, "error": "Логин не указан"}, code=400)
                return

            try:
                payload = json.dumps({'username': u})
                p_sub = subprocess.Popen(['sudo', HELPER_BIN, 'user_del'],
                                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                out, err = p_sub.communicate(input=payload, timeout=10)
                out = (out or '').strip()
                try:
                    result = json.loads(out)
                    if result.get('ok'):
                        self.send_json({"ok": True})
                    else:
                        self.send_json({"ok": False, "error": result.get('error', 'Ошибка удаления')}, code=400)
                except Exception:
                    err_msg = (err or '').strip() or out or 'Ошибка выполнения'
                    self.send_json({"ok": False, "error": f"Ошибка удаления: {err_msg}"}, code=500)
            except Exception as e:
                self.send_json({"ok": False, "error": f"Ошибка вызова helper: {e}"}, code=500)
            return

        self.send_json({"error": "Endpoint not found"}, code=404)

def run():
    PORT = get_web_port()
    server = HTTPServer((HOST, PORT), RequestHandler)
    print(f"NaïveProxy Web UI running on http://{HOST}:{PORT}")
    server.serve_forever()

if __name__ == '__main__':
    run()
EOF_WEBUI
    chmod 755 "$WEB_SCRIPT_FILE"
    chown root:root "$WEB_SCRIPT_FILE"

    # Проверка и изоляция маршрута @admin в Caddyfile
    if [ -f "$CADDY_FILE" ]; then
        chown root:naive-web "$CADDY_FILE" 2>/dev/null || true
        chmod 664 "$CADDY_FILE" 2>/dev/null || true

        python3 - "$CADDY_FILE" "$WEB_PORT" "$WEB_ROOT" << 'EOF_PY'
import sys, re
caddy_file = sys.argv[1]
web_port = sys.argv[2]
web_root = sys.argv[3]

with open(caddy_file, "r", encoding="utf-8") as f:
    content = f.read()

# Если блок @admin еще не добавлен в новом формате
if "@admin path /admin /admin/*" not in content:
    m = re.search(r"(forward_proxy\s*\{[\s\S]*?\})", content)
    if m:
        fp_block = m.group(1)
        clean = re.sub(r"redir\s+/admin\s+/admin/?\n?", "", content)
        clean = re.sub(r"handle_path\s+/admin/\*[\s\S]*?\}\n?", "", clean)
        clean = re.sub(r"file_server\s*\{[\s\S]*?\}\n?", "", clean)
        clean = re.sub(r"forward_proxy\s*\{[\s\S]*?\}\n?", "", clean)

        new_routes = f"""    @admin path /admin /admin/*
    handle @admin {{
        uri strip_prefix /admin
        reverse_proxy 127.0.0.1:{web_port}
    }}

    handle {{
        {fp_block}

        file_server {{
            root {web_root}
        }}
    }}"""
        idx = clean.rfind("}")
        if idx != -1:
            clean = clean[:idx].rstrip() + "\n\n" + new_routes + "\n}\n"
            with open(caddy_file, "w", encoding="utf-8") as out:
                out.write(clean)
EOF_PY

        if /usr/local/bin/caddy validate --config "$CADDY_FILE" >/dev/null 2>&1; then
            systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null || true
            success "Маршрут @admin (/admin/* -> 127.0.0.1:$WEB_PORT) успешно изолирован в Caddyfile."
        else
            warn "Ошибка валидации Caddyfile при проверке маршрута @admin."
        fi
    fi

    # Systemd служба для Web UI
    cat << EOF > "$WEB_SERVICE_FILE"
[Unit]
Description=NaïveProxy + Caddy Web Manager
After=network.target
Wants=network.target

[Service]
Type=simple
User=naive-web
Group=naive-web
Environment=WEB_PORT=$WEB_PORT
Environment=WEB_HOST=127.0.0.1
ExecStart=/usr/bin/python3 $WEB_SCRIPT_FILE
Restart=always
RestartSec=3s
LimitNOFILE=65536
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/etc/naiveproxy /etc/caddy

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$WEB_SERVICE_FILE"
    ln -sf "$WEB_SERVICE_FILE" "$WEB_SERVICE_ALIAS" 2>/dev/null || true
    # Финальная фиксация прав доступа перед стартом службы
    load_users 2>/dev/null || true
    mkdir -p "$CLIENTS_DIR"
    chown -R root:naive-web "$NAIVE_DIR" 2>/dev/null || true
    chmod 775 "$NAIVE_DIR" "$CLIENTS_DIR" 2>/dev/null || true
    [ -f "$USERS_FILE" ] && { chown root:naive-web "$USERS_FILE" 2>/dev/null || true; chmod 664 "$USERS_FILE" 2>/dev/null || true; }
    [ -f "$CADDY_FILE" ] && { chown root:naive-web "$CADDY_FILE" 2>/dev/null || true; chmod 664 "$CADDY_FILE" 2>/dev/null || true; }
    systemctl daemon-reload
    systemctl enable naiveproxy-webui >/dev/null 2>&1 || true
    systemctl restart naiveproxy-webui

    # Строгая проверка запуска службы и порта
    local started=false
    for _ in {1..8}; do
        if systemctl is-active --quiet naiveproxy-webui 2>/dev/null && is_port_listening "$WEB_PORT"; then
            started=true
            break
        fi
        sleep 0.5
    done

    if [ "$started" = true ]; then
        success "Панель управления успешно запущена: naiveproxy-webui.service (порт $WEB_PORT)"

        # Закрытие прямого внешнего порта Web UI в UFW (доступ строго через Caddy :443 /admin/)
        if command -v ufw &>/dev/null; then
            ufw delete allow "${WEB_PORT}/tcp" >/dev/null 2>&1 || true
            success "UFW: внешний порт ${WEB_PORT}/tcp закрыт (безопасный доступ строго через Caddy :443)."
        fi
        return 0
    else
        error "Служба Web UI не запустилась. Логи:"
        journalctl -u naiveproxy-webui --no-pager -n 20
        return 1
    fi
}


manage_web_ui() {
    print_header
    echo -e "${BOLD}${CYAN}УПРАВЛЕНИЕ ПАНЕЛЬЮ NAÏVEPROXY WEB UI${NC}\n"

    load_credentials 2>/dev/null || true
    local cur_dom="${DOMAIN:-$CHECKED_DOMAIN}"

    local status_line="${RED}NOT INSTALLED / STOPPED${NC}"
    if is_webui_ready; then
        status_line="${GREEN}RUNNING (127.0.0.1:$WEB_PORT -> /admin/)${NC}"
    elif [ -f "$WEB_SCRIPT_FILE" ]; then
        status_line="${RED}FAILED / STOPPED (проверьте логи journalctl)${NC}"
    fi

    local web_user="admin" web_pass=""
    if [ -f "$WEB_CREDS_FILE" ]; then
        web_user=$(grep -E '^WEB_USER=' "$WEB_CREDS_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
        web_pass=$(grep -E '^WEB_PASS=' "$WEB_CREDS_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
    fi

    echo -e "  Статус службы : $status_line"
    if is_webui_ready; then
        echo -e "  URL панели    : ${BOLD}${GREEN}https://${cur_dom}/admin/${NC}"
    else
        echo -e "  URL панели    : ${YELLOW}https://${cur_dom}/admin/ (служба не активна)${NC}"
    fi
    echo -e "  Логин         : ${BOLD}$web_user${NC}"
    echo -e "  Пароль        : ${BOLD}${YELLOW}${web_pass:-не установлен}${NC}\n"

    if ! is_webui_ready; then
        echo "1) Установить и запустить Web UI сейчас"
        echo "2) Показать логи службы (journalctl)"
        echo "0) Назад в главное меню"
        echo ""
        read -r -p "Выберите действие [0-2]: " wopt
        case "$wopt" in
            1)
                install_web_ui
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            2)
                journalctl -u naiveproxy-webui --no-pager -n 30
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            0) return 0 ;;
        esac
    else
        echo "1) Сгенерировать новый случайный пароль"
        echo "2) Задать пароль вручную"
        echo "3) Перезапустить службу Web UI"
        echo "4) Показать логи службы"
        echo "5) Переустановить / обновить компоненты Web UI (QR NekoBox, etc.)"
        echo "0) Назад в главное меню"
        echo ""
        read -r -p "Выберите действие [0-5]: " wopt
        case "$wopt" in
            1)
                local np
                np=$(generate_random_string 20)
                cat << EOF > "$WEB_CREDS_FILE"
WEB_USER="$web_user"
WEB_PASS="$np"
WEB_PORT="${WEB_PORT:-18080}"
CREATED_AT="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
EOF
                chown root:naive-web "$WEB_CREDS_FILE" 2>/dev/null || true
                chmod 640 "$WEB_CREDS_FILE" 2>/dev/null || true
                systemctl restart naiveproxy-webui 2>/dev/null || true
                success "Новый пароль сгенерирован: $np"
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            2)
                read -r -p "Введите новый пароль: " np
                np=$(echo "$np" | tr -d '[:space:]')
                if [ -n "$np" ]; then
                    cat << EOF > "$WEB_CREDS_FILE"
WEB_USER="$web_user"
WEB_PASS="$np"
WEB_PORT="${WEB_PORT:-18080}"
CREATED_AT="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
EOF
                    chown root:naive-web "$WEB_CREDS_FILE" 2>/dev/null || true
                    chmod 640 "$WEB_CREDS_FILE" 2>/dev/null || true
                    systemctl restart naiveproxy-webui 2>/dev/null || true
                    success "Пароль успешно обновлен."
                fi
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            3)
                systemctl restart naiveproxy-webui
                if is_webui_ready; then
                    success "Служба naiveproxy-webui активна (RUNNING :$WEB_PORT)."
                else
                    error "Служба не запустилась. Логи:"
                    journalctl -u naiveproxy-webui --no-pager -n 20
                fi
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            4)
                journalctl -u naiveproxy-webui --no-pager -n 30
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            5)
                install_web_ui
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            0) return 0 ;;
        esac
    fi
}

