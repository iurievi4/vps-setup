#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# VPS LITE - БЫСТРОЕ ОБСЛУЖИВАНИЕ И ДИАГНОСТИКА
#
# Легковесный автономный скрипт быстрого реагирования:
#   [1]  🔄 Обновить систему (apt update + upgrade)
#   [2]  🧹 Очистить систему (autoremove + autoclean + clean + journal)
#   [3]  🔧 Исправить пакеты (dpkg configure, broken install)
#   [4]  📊 Состояние VPS (CPU, RAM, Диск, Swap, Uptime, LA)
#   [5]  🔍 Быстрая диагностика (ресурсы, топ-процессы, failed units)
#   [6]  🌐 Проверка сети (шлюз, пинг, DNS, открытые порты)
#   [7]  🚀 Проверка скорости (тест пропускной способности, CDN)
#   [8]  🔄 Сервисы (упавшие службы, сброс ошибок)
#   [9]  📜 Логи (journalctl, ssh, fail2ban)
#   [10] 🕐 Cron / Timers (системные таймеры и cron-задачи)
#   [11] ⏱️  Crontab (управление /etc/cron.d/vps-maintenance и скриптами)
#   [12] ♻️  Перезагрузка VPS (reboot)
#   [13] 🛠  Полная панель (запуск install.sh)
#   [0]  🚪 Выход
###############################################################################

REPO_RAW="https://raw.githubusercontent.com/iurievi4/vps-setup/main"
CRON_MAINT_FILE="/etc/cron.d/vps-maintenance"

# Цветовая палитра для терминала
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_CYAN='\033[0;36m'
C_BCYAN='\033[1;36m'
C_GREEN='\033[0;32m'
C_BGREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_GRAY='\033[0;90m'

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo >&2
    echo -e "${C_RED}❌ Скрипт необходимо запускать с правами root (sudo).${C_RESET}" >&2
    echo >&2
    exit 1
fi

# Универсальное чтение ввода пользователя с поддержкой терминала и цветов
read_choice() {
    local prompt="$1"
    local var_name="$2"
    local default_val="${3:-0}"
    local val=""

    echo -ne "$prompt"

    if [[ -t 0 ]]; then
        read -r val || val="$default_val"
    elif { exec 3</dev/tty; } 2>/dev/null; then
        read -r val <&3 || val="$default_val"
        exec 3<&-
    else
        read -r val || val="$default_val"
    fi

    if [[ -z "$val" ]]; then
        val="$default_val"
    fi
    printf -v "$var_name" "%s" "$val"
}

pause_prompt() {
    echo
    echo -ne "${C_GRAY}Нажмите Enter для продолжения...${C_RESET}"
    if [[ -t 0 ]]; then
        read -r _ || true
    elif { exec 3</dev/tty; } 2>/dev/null; then
        read -r _ <&3 || true
        exec 3<&-
    else
        read -r _ || true
    fi
    echo
}

pick_editor() {
    if [[ -n "${EDITOR:-}" ]] && command -v "$EDITOR" >/dev/null 2>&1; then
        echo "$EDITOR"
    elif command -v nano >/dev/null 2>&1; then
        echo "nano"
    elif command -v vim >/dev/null 2>&1; then
        echo "vim"
    elif command -v vi >/dev/null 2>&1; then
        echo "vi"
    else
        echo ""
    fi
}

cron_task_state_badge() {
    local pattern="$1"
    if [[ ! -f "$CRON_MAINT_FILE" ]]; then
        echo -e "${C_GRAY}нет файла${C_RESET}"
        return 0
    fi
    if grep -qE "^[[:space:]]*[^#].*${pattern}" "$CRON_MAINT_FILE" 2>/dev/null; then
        echo -e "${C_GREEN}ВКЛ${C_RESET}"
    elif grep -qE "^[[:space:]]*#[[:space:]]*[0-9*].*${pattern}" "$CRON_MAINT_FILE" 2>/dev/null; then
        echo -e "${C_YELLOW}ВЫКЛ${C_RESET}"
    else
        echo -e "${C_GRAY}—${C_RESET}"
    fi
}

cron_script_badge() {
    local path="$1"
    if [[ -x "$path" ]]; then
        echo -e "${C_GREEN}●${C_RESET}"
    elif [[ -f "$path" ]]; then
        echo -e "${C_YELLOW}●${C_RESET}"
    else
        echo -e "${C_RED}○${C_RESET}"
    fi
}

reload_cron_maintenance() {
    if [[ -f "$CRON_MAINT_FILE" ]]; then
        chmod 644 "$CRON_MAINT_FILE" 2>/dev/null || true
        chown root:root "$CRON_MAINT_FILE" 2>/dev/null || true
    fi
    systemctl reload cron 2>/dev/null || systemctl restart cron 2>/dev/null || service cron reload 2>/dev/null || true
}

write_default_cron_maintenance() {
    mkdir -p /etc/cron.d
    cat <<'EOF' > "$CRON_MAINT_FILE"
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 1. SSL ACME (ежедневно)
16 10 * * * root /usr/local/bin/renew-ssl.sh

# 2. Бэкап x-ui (ежедневно)
0 3 * * * root /usr/local/sbin/xui-backup.sh

# 3. Обновление APT с умным ребутом (среда 03:30)
30 3 * * 3 root /usr/local/sbin/system-update.sh

# 4. Обновление 3x-ui с rollback (пятница 04:30)
30 4 * * 5 root /usr/local/sbin/xui-update-safe.sh

# 5. Гео-базы v2fly / runetfreedom (понедельник 05:00)
0 5 * * 1 root /usr/local/sbin/update-geo.sh

# 5.1. Обновление VPS IP Guard (ежедневно 04:15)
15 4 * * * root /usr/local/sbin/ip-guard update >> /var/log/vps-ip-guard.log 2>&1

# 6. Мониторинг healthcheck с анти-лупом (каждые 30 мин)
*/30 * * * * root /usr/local/sbin/xui-health.sh

# 7. Ротация журналов journalctl (суббота 04:15)
15 4 * * 6 root /usr/bin/journalctl --vacuum-time=7d --vacuum-size=200M > /dev/null 2>&1
EOF
    reload_cron_maintenance
}

toggle_cron_task_line() {
    local pattern="$1"
    local label="$2"

    if [[ ! -f "$CRON_MAINT_FILE" ]]; then
        echo -e "${C_RED}❌ Файл ${CRON_MAINT_FILE} не найден. Сначала создайте его (пункт 8).${C_RESET}"
        return 0
    fi

    local tmp_file
    tmp_file=$(mktemp)
    if grep -qE "^[[:space:]]*[^#].*${pattern}" "$CRON_MAINT_FILE" 2>/dev/null; then
        awk -v pat="$pattern" '
            !done && $0 !~ /^[[:space:]]*#/ && $0 ~ pat { print "# " $0; done=1; next }
            { print }
        ' "$CRON_MAINT_FILE" > "$tmp_file"
        mv "$tmp_file" "$CRON_MAINT_FILE"
        reload_cron_maintenance
        echo -e "${C_YELLOW}⏸ Задача отключена (закомментирована): ${label}${C_RESET}"
    elif grep -qE "^[[:space:]]*#[[:space:]]*[0-9*].*${pattern}" "$CRON_MAINT_FILE" 2>/dev/null; then
        awk -v pat="$pattern" '
            !done && $0 ~ /^[[:space:]]*#[[:space:]]*[0-9*]/ && $0 ~ pat { sub(/^[[:space:]]*#[[:space:]]*/, ""); done=1 }
            { print }
        ' "$CRON_MAINT_FILE" > "$tmp_file"
        mv "$tmp_file" "$CRON_MAINT_FILE"
        reload_cron_maintenance
        echo -e "${C_GREEN}▶ Задача включена: ${label}${C_RESET}"
    else
        rm -f "$tmp_file"
        echo -e "${C_RED}❌ Строка для «${label}» не найдена в ${CRON_MAINT_FILE}.${C_RESET}"
    fi
}

manage_vps_maintenance_cron() {
    while true; do
        clear 2>/dev/null || true

        local cron_svc_badge file_badge
        if systemctl is-active --quiet cron 2>/dev/null || systemctl is-active --quiet crond 2>/dev/null; then
            cron_svc_badge="${C_GREEN}● active${C_RESET}"
        else
            cron_svc_badge="${C_RED}○ inactive${C_RESET}"
        fi

        if [[ -f "$CRON_MAINT_FILE" ]]; then
            local f_perm
            f_perm=$(stat -c '%a' "$CRON_MAINT_FILE" 2>/dev/null || echo "???")
            file_badge="${C_GREEN}есть${C_RESET} (права ${f_perm})"
        else
            file_badge="${C_RED}отсутствует${C_RESET}"
        fi

        echo -e "${C_BOLD}${C_BCYAN}==============================================================${C_RESET}"
        echo -e "  ⏱️  ${C_BOLD}УПРАВЛЕНИЕ CRONTAB (/etc/cron.d/vps-maintenance)${C_RESET}"
        echo -e "${C_BOLD}${C_BCYAN}==============================================================${C_RESET}"
        echo -e "  Служба cron: ${cron_svc_badge} | Файл: ${file_badge}"
        echo
        echo -e "  ${C_BOLD}Статус задач (скрипт | расписание):${C_RESET}"
        echo -e "   1) $(cron_script_badge /usr/local/bin/renew-ssl.sh)  SSL ACME (10:16 ежедневно)       [$(cron_task_state_badge '/usr/local/bin/renew-ssl\.sh')]"
        echo -e "   2) $(cron_script_badge /usr/local/sbin/xui-backup.sh)  Бэкап 3x-ui (03:00 ежедневно)    [$(cron_task_state_badge '/usr/local/sbin/xui-backup\.sh')]"
        echo -e "   3) $(cron_script_badge /usr/local/sbin/system-update.sh)  Обновление APT (ср 03:30)        [$(cron_task_state_badge '/usr/local/sbin/system-update\.sh')]"
        echo -e "   4) $(cron_script_badge /usr/local/sbin/xui-update-safe.sh)  Обновление 3x-ui (пт 04:30)      [$(cron_task_state_badge '/usr/local/sbin/xui-update-safe\.sh')]"
        echo -e "   5) $(cron_script_badge /usr/local/sbin/update-geo.sh)  Гео-базы Xray (пн 05:00)         [$(cron_task_state_badge '/usr/local/sbin/update-geo\.sh')]"
        echo -e "   6) $(cron_script_badge /usr/local/sbin/ip-guard)  VPS IP Guard (04:15 ежедневно)   [$(cron_task_state_badge '/usr/local/sbin/ip-guard')]"
        echo -e "   7) $(cron_script_badge /usr/local/sbin/xui-health.sh)  Healthcheck 3x-ui (кажд. 30 мин) [$(cron_task_state_badge '/usr/local/sbin/xui-health\.sh')]"
        echo -e "   8) ${C_GREEN}●${C_RESET}  Ротация journalctl (сб 04:15)    [$(cron_task_state_badge 'journalctl --vacuum')]"
        echo
        echo -e "  ${C_BGREEN}[1]${C_RESET} 📄 Показать /etc/cron.d/vps-maintenance"
        echo -e "  ${C_BGREEN}[2]${C_RESET} ✏️  Редактировать /etc/cron.d/vps-maintenance"
        echo -e "  ${C_BGREEN}[3]${C_RESET} 🔀 Включить / отключить задачу в расписании"
        echo -e "  ${C_BGREEN}[4]${C_RESET} ▶️  Запустить задачу вручную"
        echo -e "  ${C_BGREEN}[5]${C_RESET} 📝 Редактировать скрипт или конфиг"
        echo -e "  ${C_BGREEN}[6]${C_RESET} 📜 Логи cron-задач"
        echo -e "  ${C_BGREEN}[7]${C_RESET} 🛡️  Быстрое управление VPS IP Guard"
        echo -e "  ${C_BGREEN}[8]${C_RESET} 🔧 Создать / восстановить стандартный vps-maintenance"
        echo -e "  ${C_RED}[0]${C_RESET} ⬅️  Назад в главное меню"
        echo

        local c_choice="0"
        read_choice "${C_BOLD}Выберите действие [0-8]: ${C_RESET}" c_choice "0"
        echo

        case "$c_choice" in
            1)
                if [[ -f "$CRON_MAINT_FILE" ]]; then
                    echo -e "${C_BOLD}Содержимое ${CRON_MAINT_FILE}:${C_RESET}"
                    echo -e "${C_GRAY}--------------------------------------------------------------${C_RESET}"
                    cat "$CRON_MAINT_FILE"
                    echo -e "${C_GRAY}--------------------------------------------------------------${C_RESET}"
                else
                    echo -e "${C_RED}❌ Файл ${CRON_MAINT_FILE} не найден.${C_RESET}"
                fi
                pause_prompt
                ;;

            2)
                local ed
                ed=$(pick_editor)
                if [[ -z "$ed" ]]; then
                    echo -e "${C_RED}❌ Не найден текстовый редактор (nano/vim/vi).${C_RESET}"
                    pause_prompt
                    continue
                fi
                "$ed" "$CRON_MAINT_FILE" || true
                reload_cron_maintenance
                echo -e "${C_GREEN}✓ Права 644 применены и служба cron перезагружена.${C_RESET}"
                pause_prompt
                ;;

            3)
                echo -e "${C_BOLD}Какую задачу переключить (ВКЛ ↔ ВЫКЛ)?${C_RESET}"
                echo "  1) SSL ACME (/usr/local/bin/renew-ssl.sh)"
                echo "  2) Бэкап 3x-ui (/usr/local/sbin/xui-backup.sh)"
                echo "  3) Обновление APT (/usr/local/sbin/system-update.sh)"
                echo "  4) Обновление 3x-ui (/usr/local/sbin/xui-update-safe.sh)"
                echo "  5) Гео-базы Xray (/usr/local/sbin/update-geo.sh)"
                echo "  6) VPS IP Guard (/usr/local/sbin/ip-guard update)"
                echo "  7) Healthcheck 3x-ui (/usr/local/sbin/xui-health.sh)"
                echo "  8) Ротация journalctl"
                echo "  0) Отмена"
                echo
                local t_choice="0"
                read_choice "${C_BOLD}Номер задачи [0-8]: ${C_RESET}" t_choice "0"
                echo
                case "$t_choice" in
                    1) toggle_cron_task_line '/usr/local/bin/renew-ssl\.sh' 'SSL ACME' ;;
                    2) toggle_cron_task_line '/usr/local/sbin/xui-backup\.sh' 'Бэкап 3x-ui' ;;
                    3) toggle_cron_task_line '/usr/local/sbin/system-update\.sh' 'Обновление APT' ;;
                    4) toggle_cron_task_line '/usr/local/sbin/xui-update-safe\.sh' 'Обновление 3x-ui' ;;
                    5) toggle_cron_task_line '/usr/local/sbin/update-geo\.sh' 'Гео-базы Xray' ;;
                    6) toggle_cron_task_line '/usr/local/sbin/ip-guard' 'VPS IP Guard' ;;
                    7) toggle_cron_task_line '/usr/local/sbin/xui-health\.sh' 'Healthcheck 3x-ui' ;;
                    8) toggle_cron_task_line 'journalctl --vacuum' 'Ротация journalctl' ;;
                    0) continue ;;
                    *) echo -e "${C_RED}❌ Некорректный выбор.${C_RESET}" ;;
                esac
                pause_prompt
                ;;

            4)
                echo -e "${C_BOLD}Какую задачу запустить вручную?${C_RESET}"
                echo "  1) SSL ACME (/usr/local/bin/renew-ssl.sh)"
                echo "  2) Бэкап 3x-ui (/usr/local/sbin/xui-backup.sh)"
                echo "  3) Обновление APT (/usr/local/sbin/system-update.sh)"
                echo "  4) Безопасное обновление 3x-ui (/usr/local/sbin/xui-update-safe.sh)"
                echo "  5) Обновление гео-баз (/usr/local/sbin/update-geo.sh)"
                echo "  6) Обновление VPS IP Guard (/usr/local/sbin/ip-guard update)"
                echo "  7) Healthcheck 3x-ui (/usr/local/sbin/xui-health.sh)"
                echo "  8) Ротация journalctl (7d / 200M)"
                echo "  0) Отмена"
                echo
                local r_task="0"
                read_choice "${C_BOLD}Номер задачи [0-8]: ${C_RESET}" r_task "0"
                echo
                case "$r_task" in
                    1)
                        if [[ -f /usr/local/bin/renew-ssl.sh ]]; then
                            bash /usr/local/bin/renew-ssl.sh || echo -e "${C_RED}⚠️ Скрипт завершился с ошибкой.${C_RESET}"
                        else
                            echo -e "${C_RED}❌ Файл /usr/local/bin/renew-ssl.sh не найден.${C_RESET}"
                        fi
                        ;;
                    2)
                        if [[ -f /usr/local/sbin/xui-backup.sh ]]; then
                            bash /usr/local/sbin/xui-backup.sh || echo -e "${C_RED}⚠️ Скрипт завершился с ошибкой.${C_RESET}"
                            ls -lh /root/xui_backups/ 2>/dev/null | tail -n 10 || true
                        else
                            echo -e "${C_RED}❌ Файл /usr/local/sbin/xui-backup.sh не найден.${C_RESET}"
                        fi
                        ;;
                    3)
                        if [[ -f /usr/local/sbin/system-update.sh ]]; then
                            echo ">>> Запуск /usr/local/sbin/system-update.sh (лог: /var/log/vps-system-update.log)..."
                            bash /usr/local/sbin/system-update.sh || echo -e "${C_RED}⚠️ Скрипт завершился с ошибкой.${C_RESET}"
                            tail -n 15 /var/log/vps-system-update.log 2>/dev/null || true
                        else
                            echo -e "${C_RED}❌ Файл /usr/local/sbin/system-update.sh не найден.${C_RESET}"
                        fi
                        ;;
                    4)
                        if [[ -f /usr/local/sbin/xui-update-safe.sh ]]; then
                            echo ">>> Запуск /usr/local/sbin/xui-update-safe.sh (лог: /var/log/xui-auto-update.log)..."
                            bash /usr/local/sbin/xui-update-safe.sh || echo -e "${C_RED}⚠️ Скрипт завершился с ошибкой.${C_RESET}"
                            tail -n 15 /var/log/xui-auto-update.log 2>/dev/null || true
                        else
                            echo -e "${C_RED}❌ Файл /usr/local/sbin/xui-update-safe.sh не найден.${C_RESET}"
                        fi
                        ;;
                    5)
                        if [[ -f /usr/local/sbin/update-geo.sh ]]; then
                            echo ">>> Запуск /usr/local/sbin/update-geo.sh (лог: /var/log/xui-geo-update.log)..."
                            bash /usr/local/sbin/update-geo.sh || echo -e "${C_RED}⚠️ Скрипт завершился с ошибкой.${C_RESET}"
                            tail -n 10 /var/log/xui-geo-update.log 2>/dev/null || true
                        else
                            echo -e "${C_RED}❌ Файл /usr/local/sbin/update-geo.sh не найден.${C_RESET}"
                        fi
                        ;;
                    6)
                        if [[ -f /usr/local/sbin/ip-guard ]]; then
                            bash /usr/local/sbin/ip-guard update || echo -e "${C_RED}⚠️ Скрипт завершился с ошибкой.${C_RESET}"
                        else
                            echo -e "${C_RED}❌ Файл /usr/local/sbin/ip-guard не найден.${C_RESET}"
                        fi
                        ;;
                    7)
                        if [[ -f /usr/local/sbin/xui-health.sh ]]; then
                            bash /usr/local/sbin/xui-health.sh || echo -e "${C_RED}⚠️ Скрипт завершился с ошибкой.${C_RESET}"
                            tail -n 10 /var/log/xui-health.log 2>/dev/null || true
                        else
                            echo -e "${C_RED}❌ Файл /usr/local/sbin/xui-health.sh не найден.${C_RESET}"
                        fi
                        ;;
                    8)
                        /usr/bin/journalctl --vacuum-time=7d --vacuum-size=200M || true
                        journalctl --disk-usage 2>/dev/null || true
                        ;;
                    0) continue ;;
                    *) echo -e "${C_RED}❌ Некорректный выбор.${C_RESET}" ;;
                esac
                pause_prompt
                ;;

            5)
                local ed
                ed=$(pick_editor)
                if [[ -z "$ed" ]]; then
                    echo -e "${C_RED}❌ Не найден текстовый редактор (nano/vim/vi).${C_RESET}"
                    pause_prompt
                    continue
                fi
                echo -e "${C_BOLD}Выберите файл для редактирования (${ed}):${C_RESET}"
                echo "  1) /usr/local/bin/renew-ssl.sh"
                echo "  2) /usr/local/sbin/xui-backup.sh"
                echo "  3) /usr/local/sbin/system-update.sh"
                echo "  4) /usr/local/sbin/xui-update-safe.sh"
                echo "  5) /usr/local/sbin/update-geo.sh"
                echo "  6) /usr/local/sbin/ip-guard"
                echo "  7) /usr/local/sbin/xui-health.sh"
                echo "  8) /etc/vps-ip-guard/ip-guard.conf"
                echo "  9) /etc/vps-ip-guard/manual.list"
                echo "  0) Отмена"
                echo
                local e_choice="0"
                read_choice "${C_BOLD}Номер файла [0-9]: ${C_RESET}" e_choice "0"
                local target_edit=""
                case "$e_choice" in
                    1) target_edit="/usr/local/bin/renew-ssl.sh" ;;
                    2) target_edit="/usr/local/sbin/xui-backup.sh" ;;
                    3) target_edit="/usr/local/sbin/system-update.sh" ;;
                    4) target_edit="/usr/local/sbin/xui-update-safe.sh" ;;
                    5) target_edit="/usr/local/sbin/update-geo.sh" ;;
                    6) target_edit="/usr/local/sbin/ip-guard" ;;
                    7) target_edit="/usr/local/sbin/xui-health.sh" ;;
                    8) target_edit="/etc/vps-ip-guard/ip-guard.conf" ;;
                    9) target_edit="/etc/vps-ip-guard/manual.list" ;;
                    0) continue ;;
                    *) echo -e "${C_RED}❌ Некорректный выбор.${C_RESET}"; pause_prompt; continue ;;
                esac
                "$ed" "$target_edit" || true
                if [[ "$target_edit" == /usr/local/* && -f "$target_edit" ]]; then
                    chmod +x "$target_edit" 2>/dev/null || true
                    if bash -n "$target_edit" 2>/dev/null; then
                        echo -e "${C_GREEN}✓ Синтаксис ${target_edit} проверен (OK).${C_RESET}"
                    else
                        echo -e "${C_RED}⚠️ Обнаружена ошибка синтаксиса в ${target_edit}!${C_RESET}"
                        bash -n "$target_edit" || true
                    fi
                fi
                pause_prompt
                ;;

            6)
                echo -e "${C_BOLD}Выберите лог для просмотра:${C_RESET}"
                echo "  1) Сводка всех логов обслуживания (последние 5 строк каждого)"
                echo "  2) Healthcheck 3x-ui (/var/log/xui-health.log)"
                echo "  3) VPS IP Guard (/var/log/vps-ip-guard.log)"
                echo "  4) Гео-базы Xray (/var/log/xui-geo-update.log)"
                echo "  5) Автообновление 3x-ui (/var/log/xui-auto-update.log)"
                echo "  6) Обновление APT (/var/log/vps-system-update.log)"
                echo "  7) Последние запуски CRON из syslog / journalctl"
                echo "  0) Отмена"
                echo
                local l_choice="0"
                read_choice "${C_BOLD}Выберите лог [0-7]: ${C_RESET}" l_choice "0"
                echo
                case "$l_choice" in
                    1)
                        local lf
                        for lf in /var/log/xui-health.log /var/log/vps-ip-guard.log /var/log/xui-geo-update.log /var/log/xui-auto-update.log /var/log/vps-system-update.log; do
                            echo -e "${C_CYAN}=== ${lf} ===${C_RESET}"
                            if [[ -f "$lf" ]]; then
                                tail -n 5 "$lf"
                            else
                                echo "(файл ещё не создан)"
                            fi
                        done
                        ;;
                    2) tail -n 50 /var/log/xui-health.log 2>/dev/null || echo "Файл /var/log/xui-health.log не найден" ;;
                    3) tail -n 50 /var/log/vps-ip-guard.log 2>/dev/null || echo "Файл /var/log/vps-ip-guard.log не найден" ;;
                    4) tail -n 50 /var/log/xui-geo-update.log 2>/dev/null || echo "Файл /var/log/xui-geo-update.log не найден" ;;
                    5) tail -n 50 /var/log/xui-auto-update.log 2>/dev/null || echo "Файл /var/log/xui-auto-update.log не найден" ;;
                    6) tail -n 50 /var/log/vps-system-update.log 2>/dev/null || echo "Файл /var/log/vps-system-update.log не найден" ;;
                    7)
                        if [[ -f /var/log/syslog ]]; then
                            grep -iE 'CRON|vps-maintenance|xui-|system-update|update-geo|ip-guard|renew-ssl' /var/log/syslog 2>/dev/null | tail -n 30 || true
                        else
                            journalctl -u cron -n 30 --no-pager 2>/dev/null || echo "Логи cron не найдены"
                        fi
                        ;;
                    0) continue ;;
                    *) echo -e "${C_RED}❌ Некорректный выбор.${C_RESET}" ;;
                esac
                pause_prompt
                ;;

            7)
                if [[ ! -f /usr/local/sbin/ip-guard ]]; then
                    echo -e "${C_RED}❌ Скрипт /usr/local/sbin/ip-guard не найден.${C_RESET}"
                    pause_prompt
                    continue
                fi
                echo -e "${C_BOLD}VPS IP Guard — быстрые действия:${C_RESET}"
                echo "  1) Статус (ip-guard status)"
                echo "  2) Обновить списки (ip-guard update)"
                echo "  3) Проверить iptables и ipset"
                echo "  4) Показать ручной бан-лист (ip-guard list)"
                echo "  5) Забанить IP / CIDR (ip-guard ban)"
                echo "  6) Разбанить IP / CIDR (ip-guard unban)"
                echo "  0) Назад"
                echo
                local g_choice="0"
                read_choice "${C_BOLD}Выберите действие [0-6]: ${C_RESET}" g_choice "0"
                echo
                case "$g_choice" in
                    1) bash /usr/local/sbin/ip-guard status || true ;;
                    2) bash /usr/local/sbin/ip-guard update || true ;;
                    3)
                        bash /usr/local/sbin/ip-guard check-firewall || true
                        echo
                        bash /usr/local/sbin/ip-guard check-ipset || true
                        ;;
                    4) bash /usr/local/sbin/ip-guard list || true ;;
                    5)
                        local ban_target=""
                        read_choice "${C_BOLD}Введите IP или CIDR для бана: ${C_RESET}" ban_target ""
                        if [[ -n "$ban_target" ]]; then
                            bash /usr/local/sbin/ip-guard ban "$ban_target" || true
                        fi
                        ;;
                    6)
                        local unban_target=""
                        read_choice "${C_BOLD}Введите IP или CIDR для разбана: ${C_RESET}" unban_target ""
                        if [[ -n "$unban_target" ]]; then
                            bash /usr/local/sbin/ip-guard unban "$unban_target" || true
                        fi
                        ;;
                    0) continue ;;
                    *) echo -e "${C_RED}❌ Некорректный выбор.${C_RESET}" ;;
                esac
                pause_prompt
                ;;

            8)
                if [[ -f "$CRON_MAINT_FILE" ]]; then
                    local confirm_restore="N"
                    read_choice "${C_BOLD}Перезаписать существующий ${CRON_MAINT_FILE} стандартным шаблоном? [y/N]: ${C_RESET}" confirm_restore "N"
                    if [[ ! "$confirm_restore" =~ ^[YyДд]$ ]]; then
                        echo "Отменено."
                        pause_prompt
                        continue
                    fi
                fi
                write_default_cron_maintenance
                echo -e "${C_GREEN}✓ Файл ${CRON_MAINT_FILE} создан/восстановлен (644, root:root), cron перезагружен.${C_RESET}"
                pause_prompt
                ;;

            0|q|exit)
                return 0
                ;;

            *)
                echo -e "${C_RED}❌ Некорректный выбор: ${c_choice}${C_RESET}"
                sleep 1
                ;;
        esac
    done
}

show_lite_menu() {
    clear 2>/dev/null || true

    # Сверхбыстрый сбор базовых метрик (<15 мс)
    local h_name ip_str up_str ld_str r_used r_total r_pct d_used d_total d_pct
    h_name=$(hostname 2>/dev/null || uname -n)
    ip_str=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7}' | head -n 1 || true)
    if [[ -z "$ip_str" ]]; then ip_str=$(ip -br addr show scope global 2>/dev/null | awk '{print $3}' | awk -F'/' '{print $1}' | head -n 1 || echo "127.0.0.1"); fi
    up_str=$(uptime -p 2>/dev/null | sed 's/^up //' || uptime 2>/dev/null | awk -F'up ' '{print $2}' | awk -F',' '{print $1}' || echo "N/A")
    ld_str=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0.00")

    r_total=$(free -m 2>/dev/null | awk '/Mem:/ {print $2}' || echo 1024)
    r_used=$(free -m 2>/dev/null | awk '/Mem:/ {print $3}' || echo 0)
    r_pct=$(( r_used * 100 / (r_total > 0 ? r_total : 1) ))

    d_total=$(df -h / 2>/dev/null | awk 'NR==2 {print $2}' || echo "N/A")
    d_used=$(df -h / 2>/dev/null | awk 'NR==2 {print $3}' || echo "N/A")
    d_pct=$(df / 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%' || echo 0)

    local s_ssh s_ufw s_f2b s_ipg
    if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then s_ssh="${C_GREEN}●${C_RESET}"; else s_ssh="${C_RED}○${C_RESET}"; fi
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi 'active'; then s_ufw="${C_GREEN}●${C_RESET}"; else s_ufw="${C_GRAY}○${C_RESET}"; fi
    if systemctl is-active --quiet fail2ban 2>/dev/null; then s_f2b="${C_GREEN}●${C_RESET}"; else s_f2b="${C_GRAY}○${C_RESET}"; fi
    if iptables -C INPUT -j VPS-IP-GUARD >/dev/null 2>&1 || systemctl is-active --quiet vps-ip-guard.service 2>/dev/null; then s_ipg="${C_GREEN}●${C_RESET}"; elif systemctl is-active --quiet vps-ip-guard-update.timer 2>/dev/null; then s_ipg="${C_YELLOW}●${C_RESET}"; else s_ipg="${C_GRAY}○${C_RESET}"; fi

    echo
    echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════${C_RESET}"
    echo -e "                         ${C_BOLD}${C_GREEN}⚡ VPS LITE${C_RESET}"
    echo -e "                  ${C_GRAY}БЫСТРОЕ ОБСЛУЖИВАНИЕ${C_RESET}"
    echo -e "       ${C_BOLD}${C_CYAN}Created by iurievi4 using Gemini Spark and GPT.${C_RESET}"
    echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════${C_RESET}"
    echo
    echo -e "  ${C_BOLD}📊 VPS:${C_RESET} ${C_BOLD}${h_name}${C_RESET} | ${C_GREEN}${ip_str}${C_RESET} | Uptime: ${up_str}"
    echo -e "     RAM: ${r_used}/${r_total} MB (${r_pct}%) | Диск: ${d_used}/${d_total} (${d_pct}%) | Load: ${ld_str}"
    echo -e "     Службы: SSH ${s_ssh} | UFW ${s_ufw} | Fail2ban ${s_f2b} | IP Guard ${s_ipg}"
    echo
    echo -e "  ${C_BGREEN}[1]${C_RESET}  🔄 Обновить систему"
    echo -e "  ${C_BGREEN}[2]${C_RESET}  🧹 Очистить систему"
    echo -e "  ${C_BGREEN}[3]${C_RESET}  🔧 Исправить пакеты"
    echo
    echo -e "  ${C_BGREEN}[4]${C_RESET}  📊 Состояние VPS"
    echo -e "  ${C_BGREEN}[5]${C_RESET}  🔍 Быстрая диагностика"
    echo -e "  ${C_BGREEN}[6]${C_RESET}  🌐 Проверка сети"
    echo -e "  ${C_BGREEN}[7]${C_RESET}  🚀 Проверка скорости"
    echo
    echo -e "  ${C_BGREEN}[8]${C_RESET}  🔄 Сервисы"
    echo -e "  ${C_BGREEN}[9]${C_RESET}  📜 Логи"
    echo -e "  ${C_BGREEN}[10]${C_RESET} 🕐 Cron / Timers"
    echo -e "  ${C_BGREEN}[11]${C_RESET} ⏱️  Crontab (vps-maintenance)"
    echo
    echo -e "  ${C_BGREEN}[12]${C_RESET} ♻️  Перезагрузка VPS"
    echo
    echo -e "  ${C_BCYAN}[13]${C_RESET} 🛠  ${C_BOLD}Полная панель (install.sh)${C_RESET}"
    echo
    echo -e "  ${C_RED}[0]${C_RESET}  🚪 Выход"
    echo
}

run_action() {
    local choice="$1"

    case "$choice" in
        1)
            echo -e "${C_BOLD}${C_GREEN}==============================================================${C_RESET}"
            echo -e "  🔄 ${C_BOLD}ОБНОВЛЕНИЕ СИСТЕМЫ (apt update + upgrade)${C_RESET}"
            echo -e "${C_BOLD}${C_GREEN}==============================================================${C_RESET}"
            echo
            echo ">>> [1/2] apt-get update..."
            apt-get update
            echo
            echo ">>> [2/2] apt-get upgrade..."
            DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
            echo
            echo -e "${C_GREEN}✓ Обновление пакетов успешно завершено.${C_RESET}"
            pause_prompt
            ;;

        2)
            echo -e "${C_BOLD}${C_GREEN}==============================================================${C_RESET}"
            echo -e "  🧹 ${C_BOLD}ОЧИСТКА СИСТЕМЫ И ЖУРНАЛОВ${C_RESET}"
            echo -e "${C_BOLD}${C_GREEN}==============================================================${C_RESET}"
            echo
            echo ">>> [1/4] autoremove (удаление неиспользуемых зависимостей)..."
            apt-get autoremove -y
            echo ">>> [2/4] autoclean (очистка устаревших архивов)..."
            apt-get autoclean
            echo ">>> [3/4] clean (очистка кэша APT)..."
            apt-get clean
            echo ">>> [4/4] journalctl vacuum (сжатие логов старше 3 дней)..."
            journalctl --vacuum-time=3d 2>/dev/null || true
            echo
            echo -e "${C_GREEN}✓ Очистка системы успешно завершена.${C_RESET}"
            pause_prompt
            ;;

        3)
            echo -e "${C_BOLD}${C_GREEN}==============================================================${C_RESET}"
            echo -e "  🔧 ${C_BOLD}ИСПРАВЛЕНИЕ ПАКЕТОВ И ЗАВИСИМОСТЕЙ${C_RESET}"
            echo -e "${C_BOLD}${C_GREEN}==============================================================${C_RESET}"
            echo
            echo ">>> [1/3] dpkg --configure -a (настройка незавершённых пакетов)..."
            dpkg --configure -a
            echo ">>> [2/3] apt-get --fix-broken install (исправление зависимостей)..."
            apt-get --fix-broken install -y
            echo ">>> [3/3] apt-get check (проверка целостности базы)..."
            apt-get check
            echo
            echo -e "${C_GREEN}✓ Пакеты и зависимости проверены и исправлены.${C_RESET}"
            pause_prompt
            ;;

        4)
            echo -e "${C_BOLD}${C_CYAN}==============================================================${C_RESET}"
            echo -e "  📊 ${C_BOLD}ТЕКУЩЕЕ СОСТОЯНИЕ VPS${C_RESET}"
            echo -e "${C_BOLD}${C_CYAN}==============================================================${C_RESET}"
            echo
            echo -e "${C_BOLD}1. Аптайм и средняя загрузка (Load Average):${C_RESET}"
            uptime
            echo
            echo -e "${C_BOLD}2. Процессор:${C_RESET}"
            echo "Ядер CPU: $(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)"
            echo "Load Avg: $(awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null || echo 'N/A')"
            echo
            echo -e "${C_BOLD}3. Оперативная память и Swap:${C_RESET}"
            free -h 2>/dev/null || free -m
            echo
            echo -e "${C_BOLD}4. Дисковые накопители:${C_RESET}"
            df -h -x tmpfs -x devtmpfs -x squashfs 2>/dev/null || df -h
            pause_prompt
            ;;

        5)
            echo -e "${C_BOLD}${C_CYAN}==============================================================${C_RESET}"
            echo -e "  🔍 ${C_BOLD}БЫСТРАЯ ДИАГНОСТИКА СИСТЕМЫ${C_RESET}"
            echo -e "${C_BOLD}${C_CYAN}==============================================================${C_RESET}"
            echo
            echo -e "${C_BOLD}1. Топ-5 процессов по памяти (RAM):${C_RESET}"
            ps aux --sort=-%mem 2>/dev/null | head -n 6 || true
            echo
            echo -e "${C_BOLD}2. Топ-5 процессов по процессору (CPU):${C_RESET}"
            ps aux --sort=-%cpu 2>/dev/null | head -n 6 || true
            echo
            echo -e "${C_BOLD}3. Занятость inode на корневом разделе (/):${C_RESET}"
            df -i / 2>/dev/null || true
            echo
            echo -e "${C_BOLD}4. Упавшие системные службы (failed units):${C_RESET}"
            local failed_list
            failed_list=$(systemctl --failed --no-legend 2>/dev/null || true)
            if [[ -n "$failed_list" ]]; then
                echo -e "${C_RED}⚠️ Обнаружены службы с ошибками:${C_RESET}"
                echo "$failed_list"
            else
                echo -e "${C_GREEN}✓ Все службы работают штатно (0 failed units).${C_RESET}"
            fi
            pause_prompt
            ;;

        6)
            echo -e "${C_BOLD}${C_CYAN}==============================================================${C_RESET}"
            echo -e "  🌐 ${C_BOLD}ПРОВЕРКА СЕТИ И СОЕДИНЕНИЯ${C_RESET}"
            echo -e "${C_BOLD}${C_CYAN}==============================================================${C_RESET}"
            echo
            echo -e "${C_BOLD}1. Пинг шлюза по умолчанию:${C_RESET}"
            local gw
            gw=$(ip route 2>/dev/null | awk '/default/ {print $3}' | head -n 1)
            if [[ -n "$gw" ]]; then
                echo "Шлюз: $gw"
                ping -c 3 -W 2 "$gw" 2>/dev/null || echo "Шлюз не отвечает на ICMP ping"
            else
                echo "Шлюз по умолчанию не найден."
            fi
            echo
            echo -e "${C_BOLD}2. Пинг публичных DNS-серверов:${C_RESET}"
            echo -n "Cloudflare (1.1.1.1): "
            if ping -c 2 -W 2 1.1.1.1 >/dev/null 2>&1; then echo -e "${C_GREEN}OK${C_RESET}"; else echo -e "${C_RED}FAIL${C_RESET}"; fi
            echo -n "Yandex (77.88.8.8)  : "
            if ping -c 2 -W 2 77.88.8.8 >/dev/null 2>&1; then echo -e "${C_GREEN}OK${C_RESET}"; else echo -e "${C_RED}FAIL${C_RESET}"; fi
            echo
            echo -e "${C_BOLD}3. Проверка разрешения DNS (getent):${C_RESET}"
            if getent ahosts yandex.ru >/dev/null 2>&1; then
                echo -e "${C_GREEN}✓ yandex.ru разрешается:${C_RESET} $(getent ahosts yandex.ru | awk '{print $1}' | head -n 1)"
            else
                echo -e "${C_RED}❌ Ошибка разрешения yandex.ru${C_RESET}"
            fi
            if getent ahosts google.com >/dev/null 2>&1; then
                echo -e "${C_GREEN}✓ google.com разрешается:${C_RESET} $(getent ahosts google.com | awk '{print $1}' | head -n 1)"
            else
                echo -e "${C_RED}❌ Ошибка разрешения google.com${C_RESET}"
            fi
            echo
            echo -e "${C_BOLD}4. Открытые порты (LISTEN TCP/UDP):${C_RESET}"
            ss -tulpn 2>/dev/null | grep -E 'Netid|LISTEN' || netstat -tulpn 2>/dev/null || echo "Команда ss недоступна"
            pause_prompt
            ;;

        7)
            echo -e "${C_BOLD}${C_CYAN}==============================================================${C_RESET}"
            echo -e "  🚀 ${C_BOLD}ПРОВЕРКА СКОРОСТИ СОЕДИНЕНИЯ${C_RESET}"
            echo -e "${C_BOLD}${C_CYAN}==============================================================${C_RESET}"
            echo
            echo "1) Замер через российские CDN (Yandex & Selectel)"
            echo "2) Классический Ookla Speedtest"
            echo "3) Пинг и геолокация через 2ip.ru"
            echo "0) Назад"
            echo
            local s_choice="0"
            read_choice "${C_BOLD}Выберите тест [0-3]: ${C_RESET}" s_choice "0"
            case "$s_choice" in
                1)
                    echo
                    echo -e "${C_BOLD}1. Yandex CDN (mirror.yandex.ru):${C_RESET}"
                    local sp_ya
                    sp_ya=$(curl -4 -s -w "%{speed_download}" -o /dev/null --max-time 10 "https://mirror.yandex.ru/debian/ls-lR.gz" 2>/dev/null || echo 0)
                    if [[ -n "$sp_ya" && "$sp_ya" != "0" ]]; then
                        local mbps_y
                        mbps_y=$(awk -v s="$sp_ya" 'BEGIN { printf "%.2f", (s * 8) / 1000000 }')
                        echo -e "   Скорость загрузки: ${C_GREEN}${mbps_y} Мбит/с${C_RESET}"
                    else
                        echo -e "   ${C_RED}❌ Не удалось подключиться к mirror.yandex.ru${C_RESET}"
                    fi
                    echo
                    echo -e "${C_BOLD}2. Selectel CDN (mirror.selectel.ru):${C_RESET}"
                    local sp_sel
                    sp_sel=$(curl -4 -s -w "%{speed_download}" -o /dev/null --max-time 10 "https://mirror.selectel.ru/debian/ls-lR.gz" 2>/dev/null || echo 0)
                    if [[ -n "$sp_sel" && "$sp_sel" != "0" ]]; then
                        local mbps_s
                        mbps_s=$(awk -v s="$sp_sel" 'BEGIN { printf "%.2f", (s * 8) / 1000000 }')
                        echo -e "   Скорость загрузки: ${C_GREEN}${mbps_s} Мбит/с${C_RESET}"
                    else
                        echo -e "   ${C_RED}❌ Не удалось подключиться к mirror.selectel.ru${C_RESET}"
                    fi
                    ;;
                2)
                    if ! command -v speedtest-cli >/dev/null 2>&1 && ! command -v speedtest >/dev/null 2>&1; then
                        echo ">>> Установка speedtest-cli..."
                        apt-get update -qq && apt-get install -y -qq speedtest-cli >/dev/null 2>&1 || true
                    fi
                    if command -v speedtest >/dev/null 2>&1; then
                        speedtest --accept-license --accept-gdpr || speedtest
                    elif command -v speedtest-cli >/dev/null 2>&1; then
                        speedtest-cli --secure || speedtest-cli
                    else
                        echo -e "${C_RED}❌ speedtest-cli недоступен в репозитории.${C_RESET}"
                    fi
                    ;;
                3)
                    echo
                    local ext_ip
                    ext_ip=$(curl -s --max-time 3 https://2ip.ru 2>/dev/null | grep -oP '\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}' | head -n 1 || echo "N/A")
                    echo -e "Внешний IP: ${C_GREEN}${ext_ip}${C_RESET}"
                    echo "Пинг до 2ip.ru:"
                    ping -c 3 -W 2 2ip.ru 2>/dev/null || echo "2ip.ru не отвечает"
                    ;;
            esac
            pause_prompt
            ;;

        8)
            echo -e "${C_BOLD}${C_CYAN}==============================================================${C_RESET}"
            echo -e "  🔄 ${C_BOLD}СОСТОЯНИЕ И СБРОС СЛУЖБ${C_RESET}"
            echo -e "${C_BOLD}${C_CYAN}==============================================================${C_RESET}"
            echo
            local f_units
            f_units=$(systemctl --failed --no-legend 2>/dev/null || true)
            if [[ -n "$f_units" ]]; then
                echo -e "${C_RED}Упавшие службы:${C_RESET}"
                echo "$f_units"
                echo
                local r_choice="N"
                read_choice "${C_BOLD}Выполнить сброс счетчиков сбоев (systemctl reset-failed)? [y/N]: ${C_RESET}" r_choice "N"
                if [[ "$r_choice" =~ ^[YyДд]$ ]]; then
                    systemctl reset-failed 2>/dev/null || true
                    echo -e "${C_GREEN}✓ Сброс выполнен.${C_RESET}"
                fi
            else
                echo -e "${C_GREEN}✓ Упавших служб нет (0 failed units).${C_RESET}"
            fi
            pause_prompt
            ;;

        9)
            echo -e "${C_BOLD}${C_CYAN}==============================================================${C_RESET}"
            echo -e "  📜 ${C_BOLD}ПРОСМОТР ЖУРНАЛОВ (ЛОГИ)${C_RESET}"
            echo -e "${C_BOLD}${C_CYAN}==============================================================${C_RESET}"
            echo
            echo "1) Системный журнал (journalctl -n 50)"
            echo "2) Журнал авторизации SSH (auth.log)"
            echo "3) Журнал Fail2ban (fail2ban.log)"
            echo "0) Назад"
            echo
            local log_choice="0"
            read_choice "${C_BOLD}Выберите журнал [0-3]: ${C_RESET}" log_choice "0"
            case "$log_choice" in
                1)
                    journalctl -n 50 --no-pager 2>/dev/null || true
                    ;;
                2)
                    if [[ -f "/var/log/auth.log" ]]; then
                        tail -n 50 /var/log/auth.log
                    else
                        journalctl -u ssh -u sshd -n 50 --no-pager 2>/dev/null || echo "Логи SSH не найдены"
                    fi
                    ;;
                3)
                    if [[ -f "/var/log/fail2ban.log" ]]; then
                        tail -n 40 /var/log/fail2ban.log
                    else
                        echo "Файл /var/log/fail2ban.log не найден"
                    fi
                    ;;
            esac
            pause_prompt
            ;;

        10)
            echo -e "${C_BOLD}${C_CYAN}==============================================================${C_RESET}"
            echo -e "  🕐 ${C_BOLD}СИСТЕМНЫЕ ТАЙМЕРЫ И ПЛАНИРОВЩИК CRON${C_RESET}"
            echo -e "${C_BOLD}${C_CYAN}==============================================================${C_RESET}"
            echo
            echo -e "${C_BOLD}1. Активные системные таймеры (systemd timers):${C_RESET}"
            systemctl list-timers --no-pager 2>/dev/null || true
            echo
            echo -e "${C_BOLD}2. Задачи cron пользователя root:${C_RESET}"
            crontab -l 2>/dev/null || echo "Cron-задачи для root не настроены"
            pause_prompt
            ;;

        11)
            manage_vps_maintenance_cron
            ;;

        12)
            local confirm_reboot="N"
            read_choice "${C_BOLD}Вы действительно хотите ПЕРЕЗАГРУЗИТЬ сервер? [y/N]: ${C_RESET}" confirm_reboot "N"
            if [[ "$confirm_reboot" =~ ^[YyДд]$ ]]; then
                echo ">>> Перезагрузка сервера..."
                reboot
            else
                echo "Перезагрузка отменена."
                pause_prompt
            fi
            ;;

        13)
            echo -e "${C_BOLD}${C_CYAN}>>> Запуск полной панели VPS (install.sh)...${C_RESET}"
            echo
            local full_script=""
            if [[ -f "/root/install.sh" ]]; then
                full_script="/root/install.sh"
            elif [[ -f "./install.sh" ]]; then
                full_script="./install.sh"
            else
                echo ">>> Загрузка актуального install.sh..."
                curl -fsSL "${REPO_RAW}/install.sh" -o /root/install.sh
                chmod +x /root/install.sh
                full_script="/root/install.sh"
            fi
            bash "$full_script"
            ;;

        0|q|exit)
            echo "Выход."
            exit 0
            ;;

        *)
            echo -e "${C_RED}❌ Некорректный выбор: ${choice}${C_RESET}" >&2
            sleep 1
            ;;
    esac
}

main() {
    local cli_arg="${1:-}"

    if [[ -n "$cli_arg" ]]; then
        run_action "$cli_arg"
        return 0
    fi

    if [[ ! -r /dev/tty ]]; then
        echo -e "${C_RED}❌ Не найден интерактивный терминал /dev/tty.${C_RESET}" >&2
        echo "    Для автоматического запуска передайте номер аргументом: bash $0 [1-13]" >&2
        exit 1
    fi

    while true; do
        show_lite_menu
        local choice="0"
        read_choice "${C_BOLD}Выберите действие [0-13]: ${C_RESET}" choice "0"
        echo
        run_action "$choice"
    done
}

main "${1:-}"