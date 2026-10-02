#!/usr/bin/env bash
###############################################################################
# SSH KEY MANAGER — Безопасное управление SSH-ключами и авторизацией
#
# РЕЖИМЫ РАБОТЫ:
#   1. НА СЕРВЕРЕ (VPS Mode):
#      bash ssh-key-manager.sh
#      Интерактивное меню: установка ключей (ручной ввод, приватный/публичный
#      GitHub, локальный файл), аудит, бэкапы, безопасное отключение пароля.
#
#   2. С ЛОКАЛЬНОГО ПК (Client Mode):
#      ./ssh-key-manager.sh root@IP [-p 1241]
#      ./ssh-key-manager.sh root@IP [-p 1241] disable-password
#      Автоматический поиск ~/.ssh/id_ed25519.pub, передача на сервер,
#      тестирование входа без передачи приватного ключа.
#
# БЕЗОПАСНОСТЬ:
#   - Приватный ключ НИКОГДА не покидает ПК и не передаётся по сети.
#   - Защита от lockout: пароль нельзя отключить, если authorized_keys пуст.
#   - Проверка синтаксиса 'sshd -t' перед каждым reload.
#   - Автоматический backup authorized_keys и sshd_config перед изменениями.
#   - Безопасный reload демона SSH без разрыва активных сессий.
###############################################################################

set -Eeuo pipefail

VERSION="2.1.0"
SSH_DIR="${HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"
BACKUP_DIR="${SSH_DIR}/backups"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_D="/etc/ssh/sshd_config.d"

# Установка цветов терминала
if [[ -t 1 ]]; then
    C_RESET='\033[0m'
    C_BOLD='\033[1m'
    C_GREEN='\033[1;32m'
    C_YELLOW='\033[1;33m'
    C_RED='\033[1;31m'
    C_BLUE='\033[1;34m'
    C_CYAN='\033[1;36m'
else
    C_RESET='' C_BOLD='' C_GREEN='' C_YELLOW='' C_RED='' C_BLUE='' C_CYAN=''
fi

log(){ printf "\n${C_CYAN}>>> %s${C_RESET}\n" "$*"; }
ok(){ printf "  ${C_GREEN}[OK]${C_RESET} %s\n" "$*"; }
warn(){ printf "  ${C_YELLOW}[WARN]${C_RESET} %s\n" "$*"; }
die(){ printf "  ${C_RED}[ERROR]${C_RESET} %s\n" "$*" >&2; exit 1; }

ensure_ssh_dir() {
    mkdir -p "$SSH_DIR" "$BACKUP_DIR"
    chmod 700 "$SSH_DIR" "$BACKUP_DIR"
    touch "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
}

backup_authorized_keys() {
    ensure_ssh_dir
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    local bkp_file="${BACKUP_DIR}/authorized_keys-${ts}"
    cp -a "$AUTH_KEYS" "$bkp_file"
    echo "$bkp_file"
}

backup_sshd_config() {
    mkdir -p /etc/ssh/backups 2>/dev/null || true
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    local bkp_file="/etc/ssh/backups/sshd_config-${ts}"
    if [[ -f "$SSHD_CONFIG" ]]; then
        cp -a "$SSHD_CONFIG" "$bkp_file" 2>/dev/null || true
    fi
    echo "$bkp_file"
}

safe_reload_sshd() {
    log "Проверка синтаксиса SSH-сервера (sshd -t)..."
    if ! sshd -t >/tmp/sshd-test.log 2>&1; then
        warn "Ошибка синтаксиса в конфигурации SSH:"
        cat /tmp/sshd-test.log >&2
        rm -f /tmp/sshd-test.log
        return 1
    fi
    rm -f /tmp/sshd-test.log
    ok "Синтаксис sshd корректен."

    log "Перезагрузка службы SSH..."
    local ssh_service="ssh"
    if systemctl list-unit-files | grep -qw "sshd.service"; then
        ssh_service="sshd"
    fi

    if systemctl reload "$ssh_service" 2>/dev/null || systemctl reload-or-restart "$ssh_service" 2>/dev/null; then
        ok "Служба ${ssh_service} успешно перезагружена (активные сессии не прерваны)."
        return 0
    else
        warn "Reload не удался, попытка безопасного перезапуска..."
        systemctl restart "$ssh_service" 2>/dev/null || true
        return 0
    fi
}

get_current_ssh_port() {
    local port="22"
    if [[ -f "$SSHD_CONFIG" ]]; then
        port="$(grep -E '^\s*Port\s+[0-9]+' "$SSHD_CONFIG" 2>/dev/null | awk '{print $2}' | tail -n 1 || echo "")"
    fi
    if [[ -z "$port" && -d "$SSHD_CONFIG_D" ]]; then
        port="$(grep -E '^\s*Port\s+[0-9]+' "$SSHD_CONFIG_D"/*.conf 2>/dev/null | awk '{print $2}' | tail -n 1 || echo "")"
    fi
    echo "${port:-22}"
}

# Валидация формата SSH-ключа
validate_public_key() {
    local raw_key="$1"
    raw_key="$(echo "$raw_key" | tr -d '\r' | sed 's/^[ \t]*//;s/[ \t]*$//')"

    if [[ -z "$raw_key" ]]; then
        return 1
    fi

    # Проверка допустимых префиксов
    case "$raw_key" in
        ssh-ed25519*|ssh-rsa*|ecdsa-sha2-*|sk-ssh-ed25519*|sk-ecdsa-*)
            ;;
        *)
            return 1
            ;;
    esac

    # Проверка через ssh-keygen
    local tmp_key="/tmp/test_key_$$"
    echo "$raw_key" > "$tmp_key"
    if ssh-keygen -l -f "$tmp_key" >/dev/null 2>&1; then
        rm -f "$tmp_key"
        return 0
    else
        rm -f "$tmp_key"
        return 1
    fi
}

# Добавление ключа в authorized_keys с дедупликацией
add_key_to_authorized() {
    local key_line="$1"
    local source_desc="${2:-вручную}"

    ensure_ssh_dir

    if ! validate_public_key "$key_line"; then
        warn "Строка не является валидным публичным SSH-ключом."
        return 1
    fi

    # Нормализуем строку (тип + base64 ключ)
    local key_type key_blob key_comment
    read -r key_type key_blob key_comment <<< "$key_line"
    local canonical_key="${key_type} ${key_blob}"

    if grep -Fq "$canonical_key" "$AUTH_KEYS" 2>/dev/null; then
        ok "Этот SSH-ключ УЖЕ установлен в ${AUTH_KEYS} (дубликат пропущен)."
        return 0
    fi

    local bkp
    bkp="$(backup_authorized_keys)"

    printf "\n# Added via ssh-key-manager (%s) on %s\n%s\n" "$source_desc" "$(date)" "$key_line" >> "$AUTH_KEYS"

    # Получаем fingerprint
    local fp
    fp="$(ssh-keygen -l -f <(echo "$key_line") 2>/dev/null | awk '{print $2}' || echo 'N/A')"

    ok "SSH-ключ успешно добавлен в: ${AUTH_KEYS}"
    echo "     Тип         : ${key_type}"
    echo "     Fingerprint : ${fp}"
    [[ -n "$key_comment" ]] && echo "     Комментарий : ${key_comment}"
    echo "     Резервная копия: ${bkp}"
    return 0
}

###############################################################################
# МЕНЮ УСТАНОВКИ КЛЮЧЕЙ НА VPS
###############################################################################
install_from_github_private() {
    local token="${1:-${GITHUB_TOKEN:-}}"
    local repo="iurievi4/my-private-backups"
    local path="ssh/id_ed25519.pub"
    local branch="main"

    echo
    echo "======================================================================"
    echo "  🔒 СКАЧИВАНИЕ SSH-КЛЮЧА ИЗ ПРИВАТНОГО РЕПОЗИТОРИЯ GITHUB"
    echo "======================================================================"
    echo "  Репозиторий : ${repo}"
    echo "  Путь к файлу: ${path} (ветка: ${branch})"
    echo

    if [[ -z "$token" ]]; then
        echo "Введите GitHub Personal Access Token (PAT):"
        echo "(начинается на 'ghp_' или 'github_pat_', ввод скрыт)"
        read -s -rp "Токен: " token </dev/tty || token=""
        echo
    fi

    if [[ -z "$token" ]]; then
        warn "Токен не введён. Загрузка из приватного репозитория отменена."
        return 1
    fi

    log "Загрузка ключа через GitHub REST API..."
    local key_content=""
    local api_url="https://api.github.com/repos/${repo}/contents/${path}?ref=${branch}"

    # Способ 1: GitHub API c raw header (поддерживает classic ghp_ и fine-grained github_pat_ токены)
    if key_content="$(curl -fsSL -H "Authorization: Bearer ${token}" -H "Accept: application/vnd.github.v3.raw" "$api_url" 2>/dev/null)" && [[ -n "$key_content" ]]; then
        ok "Файл успешно получен через GitHub API!"
    else
        # Способ 2: raw.githubusercontent.com с заголовком Authorization: token
        local raw_url="https://raw.githubusercontent.com/${repo}/${branch}/${path}"
        if key_content="$(curl -fsSL -H "Authorization: token ${token}" "$raw_url" 2>/dev/null)" && [[ -n "$key_content" ]]; then
            ok "Файл успешно получен через raw.githubusercontent.com!"
        fi
    fi

    if [[ -z "$key_content" ]] || ! validate_public_key "$key_content"; then
        warn "❌ ОШИБКА: Не удалось получить валидный SSH-ключ!"
        echo "  Возможные причины:"
        echo "    1. Токен не имеет прав на репозиторий (для Classic нужен scope 'repo', для Fine-grained — 'Contents: Read')."
        echo "    2. Опечатка в токене или срок его действия истёк."
        echo "    3. Файл '${path}' отсутствует в ветке '${branch}' репозитория '${repo}'."
        return 1
    fi

    add_key_to_authorized "$key_content" "GitHub: ${repo}/${path}"
    echo
    echo "──────────────────────────────────────────────────────────────────────"
    echo -e "  [1;32m✔ Публичный ключ из приватного репозитория успешно установлен![0m"
    echo "  Теперь вы можете входить на сервер по вашему приватному ключу:"
    local current_port
    current_port="$(get_current_ssh_port)"
    echo "    ssh -i ~/.ssh/id_ed25519 -p ${current_port} root@IP_СЕРВЕРА"
    echo "──────────────────────────────────────────────────────────────────────"
    return 0
}

menu_install_key() {
    clear 2>/dev/null || true
    echo "╔══════════════════════════════════════════════╗"
    echo "║          ВЫБОР ИСТОЧНИКА SSH-КЛЮЧА           ║"
    echo "╚══════════════════════════════════════════════╝"
    echo "  1) 🔒 Скачать из приватного репозитория GitHub (iurievi4/my-private-backups)"
    echo "  2) 📋 Вставить публичный ключ вручную (консоль)"
    echo "  3) 🌐 Скачать из публичного профиля GitHub (https://github.com/iurievi4.keys)"
    echo "  4) 📁 Прочитать из локального файла на сервере"
    echo
    echo "  0) ↩️  Назад в главное меню"
    echo "══════════════════════════════════════════════"

    local choice=""
    read -rp "Выберите вариант [0-4]: " choice </dev/tty || choice="0"

    case "$choice" in
        1)
            install_from_github_private
            ;;
        2)
            echo
            echo "Вставьте одну строку публичного ключа (например, ssh-ed25519 AAAAC3...):"
            local user_key=""
            read -r user_key </dev/tty || user_key=""
            if [[ -z "$user_key" ]]; then
                warn "Ключ не введён."
                return 0
            fi
            add_key_to_authorized "$user_key" "консольный ввод"
            ;;
        3)
            echo
            echo "── Загрузка из публичного профиля GitHub ──"
            echo "GitHub автоматически отдаёт все публичные ключи пользователя"
            echo "по адресу https://github.com/<username>.keys (без токенов!)"
            echo
            local gh_user="iurievi4"
            read -rp "Имя пользователя GitHub [Enter для '${gh_user}']: " gh_user </dev/tty || gh_user="iurievi4"
            gh_user="${gh_user:-iurievi4}"

            log "Запрос https://github.com/${gh_user}.keys..."
            local keys_fetched=""
            if keys_fetched="$(curl -fsSL "https://github.com/${gh_user}.keys" 2>/dev/null)" && [[ -n "$keys_fetched" ]]; then
                echo "Получены ключи:"
                local count=0
                while IFS= read -r k; do
                    [[ -z "$k" ]] && continue
                    count=$((count+1))
                    local fp
                    fp="$(ssh-keygen -l -f <(echo "$k") 2>/dev/null | awk '{print $2}' || echo 'N/A')"
                    echo "  [$count] ${fp} (${k:0:30}...)"
                    add_key_to_authorized "$k" "GitHub: ${gh_user}.keys"
                done <<< "$keys_fetched"
            else
                warn "Не удалось получить ключи для пользователя '${gh_user}' или у него нет привязанных SSH-ключей."
            fi
            ;;
        4)
            echo
            local filepath=""
            read -rp "Укажите абсолютный путь к файлу ключа на сервере: " filepath </dev/tty || filepath=""
            if [[ -f "$filepath" ]]; then
                local kcontent
                kcontent="$(cat "$filepath")"
                add_key_to_authorized "$kcontent" "файл: ${filepath}"
            else
                warn "Файл '${filepath}' не найден."
            fi
            ;;
        0)
            return 0
            ;;
        *)
            warn "Некорректный выбор."
            ;;
    esac

    echo
    read -rp "Нажмите Enter для продолжения..." </dev/tty || true
}

###############################################################################
# ПРОСМОТР И УДАЛЕНИЕ КЛЮЧЕЙ
###############################################################################
show_installed_keys() {
    ensure_ssh_dir
    echo
    echo "======================================================================"
    echo "  📋 УСТАНОВЛЕННЫЕ SSH-КЛЮЧИ В ${AUTH_KEYS}"
    echo "======================================================================"
    echo

    if [[ ! -s "$AUTH_KEYS" ]]; then
        warn "Файл ${AUTH_KEYS} пуст. Вход по ключам не настроен!"
        return 0
    fi

    local idx=0
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        idx=$((idx+1))
        local fp type comment
        read -r type _ comment <<< "$line"
        fp="$(ssh-keygen -l -f <(echo "$line") 2>/dev/null | awk '{print $1,$2}' || echo 'Не удалось прочитать fingerprint')"
        printf "  %2d) %-15s %s\n" "$idx" "$type" "$fp"
        if [[ -n "$comment" ]]; then
            printf "      Комментарий: %s\n" "$comment"
        fi
        printf "      Ключ       : %s...%s\n\n" "${line:0:25}" "${line: -20}"
    done < "$AUTH_KEYS"

    if [[ $idx -eq 0 ]]; then
        warn "В файле присутствуют только комментарии, активных ключей нет."
    else
        ok "Всего активных ключей: $idx"
    fi
    echo
    read -rp "Нажмите Enter для продолжения..." </dev/tty || true
}

remove_key_interactive() {
    ensure_ssh_dir
    echo
    echo "======================================================================"
    echo "  ❌ УДАЛЕНИЕ SSH-КЛЮЧА"
    echo "======================================================================"
    echo

    local keys=()
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        keys+=("$line")
    done < "$AUTH_KEYS"

    if [[ "${#keys[@]}" -eq 0 ]]; then
        warn "Нет установленных ключей для удаления."
        return 0
    fi

    for i in "${!keys[@]}"; do
        local fp
        fp="$(ssh-keygen -l -f <(echo "${keys[$i]}") 2>/dev/null | awk '{print $2}' || echo 'N/A')"
        printf "  %d) %s (%s)\n" "$((i+1))" "$fp" "${keys[$i]:0:30}..."
    done
    echo

    local choice=""
    read -rp "Выберите номер ключа для удаления [1-${#keys[@]}]: " choice </dev/tty || choice=""

    if [[ -z "$choice" || ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#keys[@]} )); then
        warn "Некорректный выбор."
        return 0
    fi

    local target_key="${keys[$((choice-1))]}"

    # Защита: если ключ единственный и пароли отключены
    if [[ "${#keys[@]}" -eq 1 ]]; then
        local pass_auth
        pass_auth="$(grep -Ei '^\s*PasswordAuthentication\s+no' "$SSHD_CONFIG" 2>/dev/null || true)"
        if [[ -n "$pass_auth" ]]; then
            warn "ВНИМАНИЕ! Это ЕДИНСТВЕННЫЙ ключ на сервере, а вход по паролю ОТКЛЮЧЕН!"
            warn "Удаление этого ключа приведёт к полной потере SSH-доступа к серверу!"
            local confirm=""
            read -rp "Вы АБСОЛЮТНО уверены? Введите 'DELETE': " confirm </dev/tty || confirm=""
            if [[ "$confirm" != "DELETE" ]]; then
                echo "Удаление отменено."
                return 0
            fi
        fi
    fi

    local bkp
    bkp="$(backup_authorized_keys)"

    # Удаляем выбранный ключ
    local tmp_file="/tmp/auth_keys_clean_$$"
    grep -Fv "$target_key" "$AUTH_KEYS" > "$tmp_file" || true
    cat "$tmp_file" > "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
    rm -f "$tmp_file"

    ok "Ключ успешно удалён."
    echo "  Резервная копия сохранена в: ${bkp}"
    echo
    read -rp "Нажмите Enter для продолжения..." </dev/tty || true
}

###############################################################################
# УПРАВЛЕНИЕ АВТОРИЗАЦИЕЙ ПО ПАРОЛЮ
###############################################################################
disable_password_auth() {
    ensure_ssh_dir

    echo
    echo "======================================================================"
    echo "  🔒 ОТКЛЮЧЕНИЕ ПАРОЛЬНОЙ АВТОРИЗАЦИИ SSH"
    echo "======================================================================"
    echo

    # 1. ПРОВЕРКА НАЛИЧИЯ ВАЛИДНЫХ КЛЮЧЕЙ (Lockout Prevention)
    local active_keys=0
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        if validate_public_key "$line"; then
            active_keys=$((active_keys+1))
        fi
    done < "$AUTH_KEYS"

    if [[ $active_keys -eq 0 ]]; then
        warn "❌ ОШИБКА БЕЗОПАСНОСТИ:"
        warn "В ${AUTH_KEYS} нет ни одного валидного SSH-ключа!"
        warn "Отключение парольной авторизации сейчас приведёт к ПОТЕРЕ ДОСТУПА к VPS!"
        warn "Сначала установите ваш публичный SSH-ключ (пункт 1 меню)."
        echo
        read -rp "Нажмите Enter для возврата..." </dev/tty || true
        return 1
    fi

    ok "Проверка пройдена: в authorized_keys обнаружено активных ключей: ${active_keys}"

    echo
    echo "ВНИМАНИЕ: Перед отключением паролей убедитесь, что вы проверили вход по ключу"
    echo "в отдельном окне терминала:"
    local current_port
    current_port="$(get_current_ssh_port)"
    echo "  ssh -i ~/.ssh/id_ed25519 -p ${current_port} root@IP_СЕРВЕРА"
    echo

    local confirm="y"
    read -rp "Отключить вход по паролю? [y/N]: " confirm </dev/tty || confirm="n"
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Отменено пользователем."
        return 0
    fi

    local bkp_sshd
    bkp_sshd="$(backup_sshd_config)"
    ok "Резервная копия sshd_config сохранена: ${bkp_sshd}"

    # Создаём drop-in конфиг в /etc/ssh/sshd_config.d/ (современный стандарт Debian/Ubuntu)
    mkdir -p "$SSHD_CONFIG_D"
    cat > "${SSHD_CONFIG_D}/99-disable-passwords.conf" <<'EOF_SSH_DROPIN'
# Managed by ssh-key-manager: Password Authentication Disabled
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
EOF_SSH_DROPIN

    # Отключаем конфликтующие настройки в 50-cloud-init.conf если они есть
    if [[ -f "${SSHD_CONFIG_D}/50-cloud-init.conf" ]]; then
        sed -i 's/^\s*PasswordAuthentication\s\+yes/PasswordAuthentication no/g' "${SSHD_CONFIG_D}/50-cloud-init.conf" 2>/dev/null || true
    fi

    # Также гарантируем в основном sshd_config
    if [[ -f "$SSHD_CONFIG" ]]; then
        sed -i -E 's/^[#\s]*PasswordAuthentication\s+.*/PasswordAuthentication no/' "$SSHD_CONFIG" 2>/dev/null || true
        sed -i -E 's/^[#\s]*KbdInteractiveAuthentication\s+.*/KbdInteractiveAuthentication no/' "$SSHD_CONFIG" 2>/dev/null || true
    fi

    if safe_reload_sshd; then
        echo
        echo "──────────────────────────────────────────────────────────────────────"
        echo -e "  ${C_GREEN}✔ ВХОД ПО ПАРОЛЮ УСПЕШНО ОТКЛЮЧЕН!${C_RESET}"
        echo "  🔑 Авторизация возможна ТОЛЬКО по SSH-ключам."
        echo "  ⚠️  ВАЖНО: НЕ ЗАКРЫВАЙТЕ ЭТО ОКНО ТЕРМИНАЛА!"
        echo "  Откройте НОВОЕ окно на ПК и проверьте вход:"
        echo "    ssh -i ~/.ssh/id_ed25519 -p ${current_port} root@IP_СЕРВЕРА"
        echo "──────────────────────────────────────────────────────────────────────"
    else
        warn "Сбой при проверке sshd! Восстановление исходной конфигурации..."
        rm -f "${SSHD_CONFIG_D}/99-disable-passwords.conf"
        [[ -f "$bkp_sshd" ]] && cp -a "$bkp_sshd" "$SSHD_CONFIG"
        safe_reload_sshd || true
        die "Откат выполнен. Пароли не отключены."
    fi

    echo
    read -rp "Нажмите Enter для продолжения..." </dev/tty || true
}

enable_password_auth() {
    echo
    echo "======================================================================"
    echo "  🔓 ВКЛЮЧЕНИЕ ПАРОЛЬНОЙ АВТОРИЗАЦИИ SSH"
    echo "======================================================================"
    echo

    backup_sshd_config >/dev/null

    rm -f "${SSHD_CONFIG_D}/99-disable-passwords.conf" 2>/dev/null || true

    if [[ -f "$SSHD_CONFIG" ]]; then
        sed -i -E 's/^[#\s]*PasswordAuthentication\s+.*/PasswordAuthentication yes/' "$SSHD_CONFIG" 2>/dev/null || true
        sed -i -E 's/^[#\s]*KbdInteractiveAuthentication\s+.*/KbdInteractiveAuthentication yes/' "$SSHD_CONFIG" 2>/dev/null || true
    fi

    if [[ -f "${SSHD_CONFIG_D}/50-cloud-init.conf" ]]; then
        sed -i 's/^\s*PasswordAuthentication\s\+no/PasswordAuthentication yes/g' "${SSHD_CONFIG_D}/50-cloud-init.conf" 2>/dev/null || true
    fi

    if safe_reload_sshd; then
        ok "Вход по паролю ВКЛЮЧЕН."
    else
        die "Ошибка при перезагрузке SSH."
    fi

    echo
    read -rp "Нажмите Enter для продолжения..." </dev/tty || true
}

restore_authorized_keys_menu() {
    ensure_ssh_dir
    echo
    echo "======================================================================"
    echo "  ↩️  ВОССТАНОВЛЕНИЕ AUTHORIZED_KEYS ИЗ БЭКАПА"
    echo "======================================================================"
    echo

    local backups=()
    while IFS= read -r b; do
        [[ -n "$b" ]] && backups+=("$b")
    done < <(find "$BACKUP_DIR" -maxdepth 1 -name "authorized_keys-*" 2>/dev/null | sort -r)

    if [[ "${#backups[@]}" -eq 0 ]]; then
        warn "В каталоге ${BACKUP_DIR} нет резервных копий."
        return 0
    fi

    for i in "${!backups[@]}"; do
        printf "  %d) %s (%s)\n" "$((i+1))" "$(basename "${backups[$i]}")" "$(date -r "${backups[$i]}" '+%Y-%m-%d %H:%M:%S')"
    done
    echo

    local choice=""
    read -rp "Выберите номер бэкапа [1-${#backups[@]}]: " choice </dev/tty || choice=""

    if [[ -z "$choice" || ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#backups[@]} )); then
        warn "Некорректный выбор."
        return 0
    fi

    local selected="${backups[$((choice-1))]}"
    local safety
    safety="$(backup_authorized_keys)"
    ok "Текущее состояние сохранено в: ${safety}"

    cp -a "$selected" "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
    ok "Файл authorized_keys успешно восстановлен из $(basename "$selected")."

    echo
    read -rp "Нажмите Enter для продолжения..." </dev/tty || true
}

show_ssh_status() {
    echo
    echo "======================================================================"
    echo "  🌐 ТЕКУЩИЙ SSH-СТАТУС И ПОРТ"
    echo "======================================================================"
    echo
    local port
    port="$(get_current_ssh_port)"
    echo "  Текущий порт SSH  : ${C_BOLD}${port}${C_RESET}"

    local pass_status="ВКЛЮЧЕНА (Пароли разрешены)"
    if grep -Eiq '^\s*PasswordAuthentication\s+no' "$SSHD_CONFIG" "${SSHD_CONFIG_D}"/*.conf 2>/dev/null; then
        pass_status="${C_GREEN}ОТКЛЮЧЕНА (Только по ключам)${C_RESET}"
    else
        pass_status="${C_YELLOW}ВКЛЮЧЕНА (Пароли активны)${C_RESET}"
    fi
    echo -e "  Парольная авторизация : ${pass_status}"

    local keys_count=0
    if [[ -f "$AUTH_KEYS" ]]; then
        keys_count="$(grep -cvE '^\s*(#|$)' "$AUTH_KEYS" 2>/dev/null || echo 0)"
    fi
    echo "  Установлено ключей   : ${keys_count}"

    echo
    echo "  Активные процессы SSH:"
    if command -v ss >/dev/null 2>&1; then
        ss -tulpn 2>/dev/null | grep -E ':(ssh|sshd|[0-9]+)\s+.*sshd' || echo "  (Процесс sshd слушает порты)"
    fi

    echo
    echo "  Проверка конфигурации (sshd -t):"
    if sshd -t 2>&1; then
        ok "Синтаксис sshd_config идеален."
    fi

    echo
    read -rp "Нажмите Enter для продолжения..." </dev/tty || true
}

###############################################################################
# РЕЖИМ КЛИЕНТА (ЗАПУСК С ПК)
###############################################################################
run_client_mode() {
    local target="$1"
    local port="22"
    local action="install"

    # Парсинг аргументов клиента
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--port)
                port="$2"
                shift 2
                ;;
            disable-password)
                action="disable-password"
                shift
                ;;
            *)
                if [[ "$1" =~ ^[0-9]+$ ]]; then
                    port="$1"
                fi
                shift
                ;;
        esac
    done

    echo "╔══════════════════════════════════════════════╗"
    echo "║       SSH KEY MANAGER — CLIENT RUNNER        ║"
    echo "╚══════════════════════════════════════════════╝"
    echo "  Целевой сервер: ${C_BOLD}${target}${C_RESET} (Порт: ${port})"
    echo

    # Поиск ключей на ПК
    local priv_key="${HOME}/.ssh/id_ed25519"
    local pub_key="${HOME}/.ssh/id_ed25519.pub"

    if [[ ! -f "$pub_key" ]]; then
        # Ищем альтернативные ключи
        if [[ -f "${HOME}/.ssh/id_rsa.pub" ]]; then
            priv_key="${HOME}/.ssh/id_rsa"
            pub_key="${HOME}/.ssh/id_rsa.pub"
        fi
    fi

    if [[ ! -f "$pub_key" ]]; then
        warn "На вашем ПК не найден SSH-ключ (~/.ssh/id_ed25519.pub)!"
        echo "Хотите сгенерировать современный стойкий Ed25519-ключ прямо сейчас? [Y/n]: "
        local gen_conf=""
        read -r gen_conf || gen_conf="y"
        if [[ ! "$gen_conf" =~ ^[Nn] ]]; then
            mkdir -p "${HOME}/.ssh"
            chmod 700 "${HOME}/.ssh"
            ssh-keygen -t ed25519 -C "admin-key-$(date +%Y%m%d)" -f "$priv_key"
            ok "Ключ успешно сгенерирован!"
        else
            die "Операция отменена. Ключ не найден."
        fi
    fi

    ok "Найден приватный ключ: ${priv_key} (Остаётся на ПК, никому не передаётся!)"
    ok "Найден публичный ключ : ${pub_key}"

    local key_val
    key_val="$(cat "$pub_key")"
    local fp
    fp="$(ssh-keygen -l -f "$pub_key" | awk '{print $2}')"
    echo "     Fingerprint : ${C_BOLD}${fp}${C_RESET}"
    echo

    if [[ "$action" == "disable-password" ]]; then
        echo "── Отключение входа по паролю на сервере ${target} ──"
        local confirm=""
        read -rp "Вы проверили вход по ключу и уверены в отключении паролей? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Отменено."
            exit 0
        fi

        log "Подключение к серверу для безопасного отключения паролей..."
        ssh -p "$port" -i "$priv_key" "$target" bash -s << 'EOF_REMOTE'
            mkdir -p /etc/ssh/sshd_config.d /etc/ssh/backups
            cp -a /etc/ssh/sshd_config /etc/ssh/backups/sshd_config-$(date +%Y%m%d-%H%M%S) 2>/dev/null || true
            cat > /etc/ssh/sshd_config.d/99-disable-passwords.conf << 'EOF_DROP'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
EOF_DROP
            if [[ -f /etc/ssh/sshd_config.d/50-cloud-init.conf ]]; then
                sed -i 's/^\s*PasswordAuthentication\s\+yes/PasswordAuthentication no/g' /etc/ssh/sshd_config.d/50-cloud-init.conf 2>/dev/null || true
            fi
            sed -i -E 's/^[#\s]*PasswordAuthentication\s+.*/PasswordAuthentication no/' /etc/ssh/sshd_config 2>/dev/null || true
            if sshd -t; then
                systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
                echo "[REMOTE_OK] Парольная авторизация успешно отключена!"
            else
                echo "[REMOTE_ERR] Ошибка синтаксиса sshd! Откат..."
                rm -f /etc/ssh/sshd_config.d/99-disable-passwords.conf
                exit 1
            fi
EOF_REMOTE
        ok "Готово! Парольная авторизация отключена на ${target}."
        exit 0
    fi

    # Стандартный action: установка ключа на сервер
    echo "Установить публичный ключ на ${target} (порт ${port})? [Y/n]: "
    local do_inst=""
    read -r do_inst || do_inst="y"
    if [[ "$do_inst" =~ ^[Nn] ]]; then
        echo "Отменено."
        exit 0
    fi

    log "Копирование публичного ключа на сервер..."
    if command -v ssh-copy-id >/dev/null 2>&1; then
        ssh-copy-id -i "$pub_key" -p "$port" "$target"
    else
        # Fallback если ssh-copy-id не установлен (например, в минимальном Windows PowerShell)
        ssh -p "$port" "$target" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -Fq '${key_val}' ~/.ssh/authorized_keys || echo '${key_val}' >> ~/.ssh/authorized_keys"
    fi

    echo
    ok "Публичный ключ добавлен в authorized_keys на ${target}!"
    echo
    log "Тестирование подключения по ключу..."
    if ssh -i "$priv_key" -p "$port" -o BatchMode=yes -o ConnectTimeout=5 "$target" "echo '[CONNECTION_TEST_OK]'" 2>/dev/null | grep -q "CONNECTION_TEST_OK"; then
        ok "Вход по ключу РАБОТАЕТ БЕЗУПРЕЧНО!"
        echo
        echo "──────────────────────────────────────────────────────────────────────"
        echo -e "  ${C_GREEN}✔ Ключ успешно установлен и протестирован.${C_RESET}"
        echo "  Парольная авторизация пока ОСТАЁТСЯ ВКЛЮЧЕННОЙ для безопасности."
        echo
        echo "  Чтобы отключить пароли, выполните:"
        echo "    $0 ${target} -p ${port} disable-password"
        echo "──────────────────────────────────────────────────────────────────────"
    else
        warn "Вход по ключу не сработал автоматически (возможно, требуется указать порт или пароль)."
        echo "Проверьте вручную:"
        echo "  ssh -i ${priv_key} -p ${port} ${target}"
    fi
}

###############################################################################
# ТОЧКА ВХОДА
###############################################################################
main() {
    # Режим клиента при передаче user@host
    if [[ $# -gt 0 && ("$1" == *"@"* || "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$) ]]; then
        run_client_mode "$@"
        exit 0
    fi

    # Прямые CLI команды на сервере:
    case "${1:-}" in
        github|gh|token)
            install_from_github_private "${2:-}"
            exit 0
            ;;
        disable-password)
            disable_password_auth
            exit 0
            ;;
        enable-password)
            enable_password_auth
            exit 0
            ;;
        list|show)
            show_installed_keys
            exit 0
            ;;
        status)
            show_ssh_status
            exit 0
            ;;
    esac

    # Иначе — режим меню на сервере
    while true; do
        clear 2>/dev/null || true
        local current_port
        current_port="$(get_current_ssh_port)"
        local keys_count=0
        if [[ -f "$AUTH_KEYS" ]]; then
            keys_count="$(grep -cvE '^\s*(#|$)' "$AUTH_KEYS" 2>/dev/null || echo 0)"
        fi

        echo "╔══════════════════════════════════════════════╗"
        echo "║         🔐 SSH KEY & SECURITY MANAGER        ║"
        echo "╚══════════════════════════════════════════════╝"
        echo "  SSH-порт: ${current_port}  |  Активных ключей: ${keys_count}"
        echo
        echo "  УПРАВЛЕНИЕ КЛЮЧАМИ:"
        echo "    1) 🔑 Установить SSH-ключ (ввод / GitHub / файл)"
        echo "    2) 📋 Показать установленные ключи"
        echo "    3) ❌ Удалить SSH-ключ"
        echo
        echo "  ПАРОЛЬНАЯ БЕЗОПАСНОСТЬ:"
        echo "    4) 🔒 Отключить вход по паролю (защита от брутфорса)"
        echo "    5) 🔓 Включить вход по паролю"
        echo
        echo "  СИСТЕМА И БЭКАПЫ:"
        echo "    6) 💾 Создать backup authorized_keys & sshd"
        echo "    7) ↩️  Восстановить authorized_keys из бэкапа"
        echo "    8) 🔍 Проверить SSH-конфигурацию (sshd -t)"
        echo "    9) 🌐 Показать текущий SSH-порт и статус службы"
        echo
        echo "    0) 🚪 Выход"
        echo "══════════════════════════════════════════════"

        local choice=""
        read -rp "Выберите действие [0-9]: " choice </dev/tty || choice="0"

        case "$choice" in
            1) menu_install_key ;;
            2) show_installed_keys ;;
            3) remove_key_interactive ;;
            4) disable_password_auth ;;
            5) enable_password_auth ;;
            6)
                local b1 b2
                b1="$(backup_authorized_keys)"
                b2="$(backup_sshd_config)"
                ok "Бэкапы созданы:"
                echo "  • authorized_keys: $b1"
                echo "  • sshd_config    : $b2"
                read -rp "Нажмите Enter для продолжения..." </dev/tty || true
                ;;
            7) restore_authorized_keys_menu ;;
            8)
                log "Тест синтаксиса sshd..."
                if sshd -t; then
                    ok "Синтаксис sshd_config корректен."
                fi
                read -rp "Нажмите Enter для продолжения..." </dev/tty || true
                ;;
            9) show_ssh_status ;;
            0) echo "Выход."; exit 0 ;;
            *) warn "Некорректный выбор." ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
