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
#   [11] ♻️  Перезагрузка VPS (reboot)
#   [12] 🛠  Полная панель (запуск install.sh)
#   [0]  🚪 Выход
###############################################################################

REPO_RAW="https://raw.githubusercontent.com/iurievi4/vps-setup/main"

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
    echo
    echo -e "  ${C_BGREEN}[11]${C_RESET} ♻️  Перезагрузка VPS"
    echo
    echo -e "  ${C_BCYAN}[12]${C_RESET} 🛠  ${C_BOLD}Полная панель (install.sh)${C_RESET}"
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

        12)
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
        echo "    Для автоматического запуска передайте номер аргументом: bash $0 [1-12]" >&2
        exit 1
    fi

    while true; do
        show_lite_menu
        local choice="0"
        read_choice "${C_BOLD}Выберите действие [0-12]: ${C_RESET}" choice "0"
        echo
        run_action "$choice"
    done
}

main "${1:-}"
