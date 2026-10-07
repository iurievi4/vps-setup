#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# VPS MANAGEMENT - ГЛАВНЫЙ ЦЕНТР УПРАВЛЕНИЯ И ОБСЛУЖИВАНИЯ
#
# Единая точка входа:
#   [1] ⚡ VPS LITE (быстрое ежедневное обслуживание, экспресс-диагностика)
#   [2] 🛠  VPS FULL (полная панель настройки, безопасность, сервисы, ЛЭРС)
#   [0] 🚪 Выход
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

progress_bar() {
    local percent="$1"
    local width=10
    local filled=$(( percent * width / 100 ))
    local empty=$(( width - filled ))
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="■"; done
    for ((i=0; i<empty; i++)); do bar+="□"; done
    printf "%s" "$bar"
}

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

get_primary_ip() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7}' | head -n 1 || true)
    if [[ -z "$ip" ]]; then
        ip=$(ip -br addr show scope global 2>/dev/null | awk '{print $3}' | awk -F'/' '{print $1}' | head -n 1 || true)
    fi
    if [[ -z "$ip" ]]; then
        ip="127.0.0.1"
    fi
    echo "$ip"
}

show_management_dashboard() {
    clear 2>/dev/null || true

    # Сбор быстрых системных метрик (<20 мс, локальный опрос /proc)
    local hostname_str os_name kernel_str uptime_str load_str ip_str
    hostname_str=$(hostname 2>/dev/null || uname -n)
    os_name=$(grep -oP '(?<=^PRETTY_NAME=).+' /etc/os-release 2>/dev/null | tr -d '"' || uname -s)
    kernel_str=$(uname -r)
    uptime_str=$(uptime -p 2>/dev/null | sed 's/^up //' || uptime 2>/dev/null | awk -F'up ' '{print $2}' | awk -F',' '{print $1}' || echo "N/A")
    load_str=$(awk '{print $1"  "$2"  "$3}' /proc/loadavg 2>/dev/null || echo "N/A")
    ip_str=$(get_primary_ip)

    # RAM
    local ram_used ram_total ram_pct
    ram_total=$(free -m 2>/dev/null | awk '/Mem:/ {print $2}' || echo 1024)
    ram_used=$(free -m 2>/dev/null | awk '/Mem:/ {print $3}' || echo 0)
    ram_pct=$(( ram_used * 100 / (ram_total > 0 ? ram_total : 1) ))

    # Disk
    local disk_used disk_total disk_pct
    disk_total=$(df -h / 2>/dev/null | awk 'NR==2 {print $2}' || echo "N/A")
    disk_used=$(df -h / 2>/dev/null | awk 'NR==2 {print $3}' || echo "N/A")
    disk_pct=$(df / 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%' || echo 0)

    # Службы: быстрый опрос systemctl is-active и прослушиваемых сокетов
    local ssh_st ssh_port
    ssh_port=$(ss -tlpn 2>/dev/null | grep -E 'sshd|/ssh' | awk '{print $4}' | awk -F':' '{print $NF}' | head -n 1 || true)
    if [[ -z "$ssh_port" ]]; then ssh_port="22"; fi
    if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
        ssh_st="${C_GREEN}● RUNNING${C_RESET}  ${C_GRAY}:${ssh_port}${C_RESET}"
    else
        ssh_st="${C_YELLOW}○ STOPPED${C_RESET}"
    fi

    local ufw_st
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi 'active'; then
        ufw_st="${C_GREEN}● ACTIVE${C_RESET}"
    else
        ufw_st="${C_YELLOW}○ INACTIVE${C_RESET}"
    fi

    local f2b_st
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        f2b_st="${C_GREEN}● ACTIVE${C_RESET}"
    else
        f2b_st="${C_YELLOW}○ INACTIVE${C_RESET}"
    fi

    local ipguard_st
    if iptables -C INPUT -j VPS-IP-GUARD >/dev/null 2>&1 || systemctl is-active --quiet vps-ip-guard.service 2>/dev/null; then
        ipguard_st="${C_GREEN}● ACTIVE${C_RESET}"
    elif systemctl is-active --quiet vps-ip-guard-update.timer 2>/dev/null; then
        ipguard_st="${C_YELLOW}○ TIMER${C_RESET}"
    elif ipset list VPS-IP-GUARD-V4 >/dev/null 2>&1; then
        ipguard_st="${C_YELLOW}○ IDLE${C_RESET}"
    else
        ipguard_st="${C_GRAY}○ INACTIVE${C_RESET}"
    fi

    local nginx_st nginx_p
    nginx_p=$(ss -tlpn 2>/dev/null | grep -E 'nginx' | awk '{print $4}' | awk -F':' '{print $NF}' | head -n 1 || true)
    if [[ -z "$nginx_p" ]]; then nginx_p="80"; fi
    if systemctl is-active --quiet nginx 2>/dev/null; then
        nginx_st="${C_GREEN}● RUNNING${C_RESET}  ${C_GRAY}:${nginx_p}${C_RESET}"
    else
        nginx_st="${C_GRAY}○ INACTIVE${C_RESET}"
    fi

    local xui_st xui_p
    xui_p=$(ss -tlpn 2>/dev/null | grep -E 'x-ui' | awk '{print $4}' | awk -F':' '{print $NF}' | head -n 1 || true)
    if [[ -z "$xui_p" ]]; then xui_p="8784"; fi
    if systemctl is-active --quiet x-ui 2>/dev/null; then
        xui_st="${C_GREEN}● RUNNING${C_RESET}  ${C_GRAY}:${xui_p}${C_RESET}"
    else
        xui_st="${C_GRAY}○ INACTIVE${C_RESET}"
    fi

    local warp_st
    if ss -lnt 2>/dev/null | grep -qE ':40000\b'; then
        warp_st="${C_GREEN}● RUNNING${C_RESET}  ${C_GRAY}:40000${C_RESET}"
    elif command -v warp-cli >/dev/null 2>&1 && warp-cli status 2>/dev/null | grep -qiE 'Connected|Status.*Connected'; then
        warp_st="${C_GREEN}● RUNNING${C_RESET}"
    elif systemctl is-active --quiet warp-svc 2>/dev/null; then
        warp_st="${C_YELLOW}○ STANDBY${C_RESET}"
    else
        warp_st="${C_GRAY}○ INACTIVE${C_RESET}"
    fi

    echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
    echo -e "                          ${C_BOLD}${C_GREEN}⚡ VPS MANAGEMENT ⚡${C_RESET}"
    echo -e "                  ${C_GRAY}Управление и обслуживание VPS${C_RESET}"
    echo -e "                         ${C_BOLD}${C_CYAN}created by IURIEVI4${C_RESET}"
    echo -e "${C_BCYAN}══════════════════════════════════════════════════════════════════════${C_RESET}"
    echo
    echo -e "${C_BOLD}${C_YELLOW}📊 VPS STATUS${C_RESET}"
    echo -e "  ${C_GRAY}├─${C_RESET} Hostname : ${C_BOLD}${hostname_str}${C_RESET}"
    echo -e "  ${C_GRAY}├─${C_RESET} OS       : ${C_CYAN}${os_name}${C_RESET}"
    echo -e "  ${C_GRAY}├─${C_RESET} Kernel   : ${kernel_str}"
    echo -e "  ${C_GRAY}├─${C_RESET} IP       : ${C_GREEN}${ip_str}${C_RESET}"
    echo -e "  ${C_GRAY}├─${C_RESET} Uptime   : ${uptime_str}"
    echo -e "  ${C_GRAY}├─${C_RESET} Load     : ${load_str}"
    echo -e "  ${C_GRAY}├─${C_RESET} RAM      : ${ram_used} / ${ram_total} MB  [${C_GREEN}$(progress_bar "$ram_pct")${C_RESET}] ${ram_pct}%"
    echo -e "  ${C_GRAY}└─${C_RESET} Disk     : ${disk_used} / ${disk_total}    [${C_GREEN}$(progress_bar "$disk_pct")${C_RESET}] ${disk_pct}%"
    echo
    echo -e "${C_BOLD}${C_YELLOW}🛡️  SECURITY & SERVICES${C_RESET}"
    echo -e "  ${C_GRAY}├─${C_RESET} SSH          : ${ssh_st}"
    echo -e "  ${C_GRAY}├─${C_RESET} UFW          : ${ufw_st}"
    echo -e "  ${C_GRAY}├─${C_RESET} Fail2ban     : ${f2b_st}"
    echo -e "  ${C_GRAY}├─${C_RESET} IP Guard     : ${ipguard_st}"
    echo -e "  ${C_GRAY}├─${C_RESET} Nginx        : ${nginx_st}"
    echo -e "  ${C_GRAY}├─${C_RESET} 3x-ui        : ${xui_st}"
    echo -e "  ${C_GRAY}└─${C_RESET} WARP         : ${warp_st}"
    echo
    echo -e "${C_GRAY}──────────────────────────────────────────────────────────────────────${C_RESET}"
    echo
    echo -e "                      ${C_BOLD}${C_CYAN}ЧТО ВЫ ХОТИТЕ СДЕЛАТЬ?${C_RESET}"
    echo
    echo -e "┌──────────────────────────────────────────────────────────────────┐"
    echo -e "│ ${C_BGREEN}[1] ⚡ VPS LITE${C_RESET}                                                   │"
    echo -e "│     ${C_GRAY}Быстрое ежедневное обслуживание уже настроенного VPS.${C_RESET}        │"
    echo -e "│                                                                  │"
    echo -e "│     ${C_CYAN}Обновление • очистка • диагностика • сеть • логи${C_RESET}             │"
    echo -e "│     ${C_CYAN}проверка служб • исправление • перезагрузка${C_RESET}                  │"
    echo -e "└──────────────────────────────────────────────────────────────────┘"
    echo
    echo -e "┌──────────────────────────────────────────────────────────────────┐"
    echo -e "│ ${C_BGREEN}[2] 🛠  VPS FULL${C_RESET}                                                   │"
    echo -e "│     ${C_GRAY}Полное администрирование и настройка VPS.${C_RESET}                    │"
    echo -e "│                                                                  │"
    echo -e "│     ${C_CYAN}Установка • безопасность • SSH • Nginx • 3x-ui${C_RESET}               │"
    echo -e "│     ${C_CYAN}NaïveProxy • Caddy • Docker • БД • WARP • ЛЭРС и другое${C_RESET}      │"
    echo -e "└──────────────────────────────────────────────────────────────────┘"
    echo
    echo -e "  ${C_RED}[0]${C_RESET} 🚪 Выход"
    echo
}

run_lite() {
    local script_path=""
    if [[ -f "/root/vps-lite.sh" ]]; then
        script_path="/root/vps-lite.sh"
    elif [[ -f "./vps-lite.sh" ]]; then
        script_path="./vps-lite.sh"
    elif [[ -f "$(dirname "$0")/vps-lite.sh" ]]; then
        script_path="$(dirname "$0")/vps-lite.sh"
    else
        echo ">>> Загрузка vps-lite.sh с GitHub..."
        curl -fsSL "${REPO_RAW}/vps-lite.sh" -o /root/vps-lite.sh
        chmod +x /root/vps-lite.sh
        script_path="/root/vps-lite.sh"
    fi
    bash "$script_path"
}

run_full() {
    local script_path=""
    if [[ -f "/root/install.sh" ]]; then
        script_path="/root/install.sh"
    elif [[ -f "./install.sh" ]]; then
        script_path="./install.sh"
    elif [[ -f "$(dirname "$0")/install.sh" ]]; then
        script_path="$(dirname "$0")/install.sh"
    else
        echo ">>> Загрузка install.sh с GitHub..."
        curl -fsSL "${REPO_RAW}/install.sh" -o /root/install.sh
        chmod +x /root/install.sh
        script_path="/root/install.sh"
    fi
    bash "$script_path"
}

main() {
    local cli_arg="${1:-}"

    if [[ "$cli_arg" == "1" || "$cli_arg" == "lite" ]]; then
        run_lite
        return 0
    elif [[ "$cli_arg" == "2" || "$cli_arg" == "full" ]]; then
        run_full
        return 0
    fi

    if [[ ! -r /dev/tty ]]; then
        echo -e "${C_RED}❌ Не найден интерактивный терминал /dev/tty.${C_RESET}" >&2
        echo "    Для запуска укажите режим аргументом: bash $0 [1|2] (1=Lite, 2=Full)" >&2
        exit 1
    fi

    while true; do
        show_management_dashboard
        local choice="0"
        read_choice "${C_BOLD}Выберите режим [0-2]: ${C_RESET}" choice "0"
        echo

        case "$choice" in
            1|lite|Lite)
                run_lite
                ;;
            2|full|Full)
                run_full
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
    done
}

main "${1:-}"
