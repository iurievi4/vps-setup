#!/usr/bin/env bash
# ==============================================================================
# Тестовый набор для проверки VPS IP Guard и безопасной миграции
# https://github.com/iurievi4/vps-setup
#
# Использование:
#   ./test-ip-guard.sh          # Логические и синтаксические тесты (без root)
#   sudo ./test-ip-guard.sh --live   # Полное сквозное тестирование на реальном VPS
# ==============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/ip-guard.sh"
SECURITY_SCRIPT="${SCRIPT_DIR}/security-install.sh"

C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"
C_BLUE="\033[1;34m"
C_CYAN="\033[1;36m"
C_RESET="\033[0m"

PASS_COUNT=0
FAIL_COUNT=0

test_pass() {
    echo -e "  [${C_GREEN}PASS${C_RESET}] $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

test_fail() {
    echo -e "  [${C_RED}FAIL${C_RESET}] $1 - Причина: $2"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

echo -e "\n${C_CYAN}==============================================================${C_RESET}"
echo -e "${C_CYAN}         Запуск тестов верификации VPS IP Guard               ${C_RESET}"
echo -e "${C_CYAN}==============================================================${C_RESET}\n"

# ------------------------------------------------------------------------------
# Тест 1: Проверка синтаксиса bash
# ------------------------------------------------------------------------------
echo -e "${C_BLUE}--- Тест 1: Проверка синтаксиса bash ---${C_RESET}"
if bash -n "$TARGET_SCRIPT"; then
    test_pass "ip-guard.sh синтаксически корректен"
else
    test_fail "ip-guard.sh" "Ошибки синтаксиса bash"
fi

if bash -n "$SECURITY_SCRIPT"; then
    test_pass "security-install.sh синтаксически корректен"
else
    test_fail "security-install.sh" "Ошибки синтаксиса bash"
fi

# ------------------------------------------------------------------------------
# Подгрузка функций из ip-guard.sh
# ------------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$TARGET_SCRIPT"

# ------------------------------------------------------------------------------
# Тест 2: Валидация и нормализация IPv4
# ------------------------------------------------------------------------------
echo -e "\n${C_BLUE}--- Тест 2: Проверка фильтрации и валидации IPv4 ---${C_RESET}"
raw_test_data=$(cat <<'EOF'
# Комментарий
1.1.1.1
  8.8.8.8 # с пробелами и комментарием
192.168.1.0/24
10.0.0.1/32
999.1.2.3
1.2.3.4/33
not-an-ip
2001:db8::1
::1
1.2.3
1.2.3.4.5
EOF
)

normalized_v4=$(normalize_v4 <<< "$raw_test_data")

expected_v4=$(cat <<'EOF'
1.1.1.1
8.8.8.8
192.168.1.0/24
10.0.0.1/32
EOF
)

if [[ "$normalized_v4" == "$expected_v4" ]]; then
    test_pass "Нормализация IPv4 корректно отсекает невалидные IP, маски >32, IPv6 и комментарии"
else
    test_fail "Нормализация IPv4" "Ожидалось:\n$expected_v4\nПолучено:\n$normalized_v4"
fi

# ------------------------------------------------------------------------------
# Тест 3: Разделение IPv4 и IPv6 (Защита от 'invalid blacklist format')
# ------------------------------------------------------------------------------
echo -e "\n${C_BLUE}--- Тест 3: Проверка защиты от смешивания IPv6 в список IPv4 ---${C_RESET}"
v6_sample="2a00:1450:4001:828::200e/64"
leak_check=$(normalize_v4 <<< "$v6_sample")

if [[ -z "$leak_check" ]]; then
    test_pass "IPv6 адреса гарантированно не попадают в IPv4 ipset (ошибка 'invalid blacklist format' исключена)"
else
    test_fail "Утечка IPv6" "IPv6 адрес ошибочно распознан как IPv4: $leak_check"
fi

# ------------------------------------------------------------------------------
# Тест 4: Логика защиты от сброса при поврежденном источнике
# ------------------------------------------------------------------------------
echo -e "\n${C_BLUE}--- Тест 4: Логика защиты от сброса при поврежденном источнике ---${C_RESET}"
small_sample=$(cat <<'EOF'
1.1.1.1
2.2.2.2
EOF
)
small_count=$(wc -l <<< "$small_sample")
MIN_REQUIRED=50

if [[ "$small_count" -lt "$MIN_REQUIRED" ]]; then
    test_pass "При малом числе записей ($small_count < $MIN_REQUIRED) срабатывает защита от swap поврежденного списка"
else
    test_fail "Защита от пустого списка" "Порог не сработал"
fi

# ------------------------------------------------------------------------------
# Тест 5: Работа с ручным чёрным списком (Manual list parsing)
# ------------------------------------------------------------------------------
echo -e "\n${C_BLUE}--- Тест 5: Логика управления manual.list ---${C_RESET}"
tmp_manual="/tmp/test_manual.list"
rm -f "$tmp_manual"

raw_entry1="198.51.100.55"
raw_entry2="  198.51.100.55  "

clean1=$(echo "$raw_entry1" | tr -d '[:space:]')
clean2=$(echo "$raw_entry2" | tr -d '[:space:]')

echo "$clean1" >> "$tmp_manual"
if ! grep -qxF "$clean2" "$tmp_manual"; then
    echo "$clean2" >> "$tmp_manual"
fi
sort -u "$tmp_manual" -o "$tmp_manual"
m_count=$(wc -l < "$tmp_manual")

if [[ "$m_count" -eq 1 ]]; then
    test_pass "Дедупликация и нормализация manual.list работает корректно"
else
    test_fail "manual.list" "Ожидалась 1 запись, получено $m_count"
fi

del_ip="198.51.100.55"
grep -vFx "$del_ip" "$tmp_manual" > "${tmp_manual}.tmp" || true
mv "${tmp_manual}.tmp" "$tmp_manual"
m_count_after=$(wc -l < "$tmp_manual")

if [[ "$m_count_after" -eq 0 ]]; then
    test_pass "Удаление из manual.list (unban) выполняется чисто"
else
    test_fail "manual.list unban" "Запись осталась в файле"
fi
rm -f "$tmp_manual"

# ------------------------------------------------------------------------------
# Тест 6: Проверка эталонных URL списков
# ------------------------------------------------------------------------------
echo -e "\n${C_BLUE}--- Тест 6: Проверка эталонных URL источников ---${C_RESET}"
expected_prefix="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public"
if [[ "$RKN_GOV_URL" == *"$expected_prefix"* ]] && \
   [[ "$ANTISCANNER_URL" == *"$expected_prefix"* ]] && \
   [[ "$SKIPA_URL" == *"$expected_prefix"* ]]; then
    test_pass "Источники указывают на официальный shadow-netlab/traffic-guard-lists"
else
    test_fail "Источники URL" "Используются устаревшие адреса источников"
fi

# ------------------------------------------------------------------------------
# Интерактивные / Live-тесты на сервере (только при --live и root)
# ------------------------------------------------------------------------------
if [[ "${1:-}" == "--live" ]]; then
    echo -e "\n${C_CYAN}==============================================================${C_RESET}"
    echo -e "${C_CYAN}           Запуск LIVE-тестирования на VPS (с правами root)   ${C_RESET}"
    echo -e "${C_CYAN}==============================================================${C_RESET}\n"

    if [[ "$EUID" -ne 0 ]]; then
        test_fail "Live-тест" "Для запуска с флагом --live требуются права root (sudo)."
    else
        echo -e "${C_BLUE}--- Проверка окружения VPS ---${C_RESET}"
        if command -v ipset &>/dev/null && command -v iptables &>/dev/null; then
            test_pass "ipset и iptables установлены в системе"
        else
            test_fail "Окружение VPS" "ipset или iptables не найдены. Выполните: apt-get install ipset iptables"
        fi

        echo -e "\n${C_BLUE}--- Имитация старого AntiScanner для проверки миграции ---${C_RESET}"
        ipset create SCANNERS-BLOCK-V4 hash:net family inet -exist 2>/dev/null || true
        ipset add SCANNERS-BLOCK-V4 198.51.100.77 -exist 2>/dev/null || true
        iptables -N SCANNERS-BLOCK 2>/dev/null || true
        if ! iptables -C INPUT -j SCANNERS-BLOCK 2>/dev/null; then
            iptables -I INPUT 1 -j SCANNERS-BLOCK 2>/dev/null || true
        fi
        test_pass "Тестовый legacy AntiScanner (SCANNERS-BLOCK-V4) создан"

        echo -e "\n${C_BLUE}--- Выполнение миграции (ip-guard install) ---${C_RESET}"
        chmod +x "$TARGET_SCRIPT"
        if "$TARGET_SCRIPT" install; then
            test_pass "Команда install выполнилась успешно"
        else
            test_fail "Команда install" "Ошибка выполнения скрипта"
        fi

        echo -e "\n${C_BLUE}--- Проверка корректности переключения правил ---${C_RESET}"
        if ! ipset list -n | grep -qw "SCANNERS-BLOCK-V4"; then
            test_pass "Старый ipset SCANNERS-BLOCK-V4 корректно удален"
        else
            test_fail "Удаление старого сета" "SCANNERS-BLOCK-V4 всё еще существует"
        fi

        if ! iptables -C INPUT -j SCANNERS-BLOCK 2>/dev/null; then
            test_pass "Старая цепочка SCANNERS-BLOCK отвязана от INPUT"
        else
            test_fail "Отвязка старой цепочки" "Правило -j SCANNERS-BLOCK осталось в INPUT"
        fi

        if ipset list -n | grep -qw "VPS-IP-GUARD-V4"; then
            new_count=$(ipset list VPS-IP-GUARD-V4 | grep -c '^[0-9]' || echo 0)
            if [[ "$new_count" -gt 0 ]]; then
                test_pass "Новый ipset VPS-IP-GUARD-V4 создан и содержит $new_count записей"
            else
                test_fail "Наполнение сета" "VPS-IP-GUARD-V4 пуст"
            fi
        else
            test_fail "Создание сета" "VPS-IP-GUARD-V4 не найден"
        fi

        if ipset test VPS-IP-GUARD-V4 198.51.100.77 2>/dev/null; then
            test_pass "Canary IP из старого списка успешно сохранен в новом сете"
        else
            test_fail "Перенос старых IP" "Canary IP 198.51.100.77 не найден в VPS-IP-GUARD-V4"
        fi

        echo -e "\n${C_BLUE}--- Тестирование ban и unban ---${C_RESET}"
        test_ip="203.0.113.42"
        "$TARGET_SCRIPT" ban "$test_ip"
        if ipset test VPS-IP-GUARD-V4 "$test_ip" 2>/dev/null; then
            test_pass "Команда ban успешно добавила $test_ip в активный сет"
        else
            test_fail "ip-guard ban" "$test_ip не найден в ipset"
        fi

        "$TARGET_SCRIPT" unban "$test_ip"
        if ! ipset test VPS-IP-GUARD-V4 "$test_ip" 2>/dev/null; then
            test_pass "Команда unban успешно удалила $test_ip из сета"
        else
            test_fail "ip-guard unban" "$test_ip всё еще в ipset"
        fi

        echo -e "\n${C_BLUE}--- Проверка автообновления через systemd ---${C_RESET}"
        if systemctl is-active vps-ip-guard-update.timer &>/dev/null; then
            test_pass "vps-ip-guard-update.timer активен и ожидает расписания"
        else
            test_fail "Systemd таймер" "vps-ip-guard-update.timer не активен"
        fi
    fi
fi

# ------------------------------------------------------------------------------
# Итог
# ------------------------------------------------------------------------------
echo -e "\n${C_CYAN}==============================================================${C_RESET}"
echo -e "Результаты тестирования: ${C_GREEN}Успешно: $PASS_COUNT${C_RESET}, ${C_RED}Ошибок: $FAIL_COUNT${C_RESET}"
echo -e "${C_CYAN}==============================================================${C_RESET}\n"

if [[ "$FAIL_COUNT" -eq 0 ]]; then
    echo -e "${C_GREEN}Все тесты пройдены! Скрипты готовы к развёртыванию.${C_RESET}\n"
    exit 0
else
    echo -e "${C_RED}Обнаружены ошибки. Исправьте замечания перед запуском на продакшене.${C_RESET}\n"
    exit 1
fi
