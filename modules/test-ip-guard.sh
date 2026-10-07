#!/usr/bin/env bash
# ==============================================================================
# Тестовый набор для проверки VPS IP Guard
# https://github.com/iurievi4/vps-setup
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
# Тест 6: Проверка эталонных URL источников
# ------------------------------------------------------------------------------
echo -e "\n${C_BLUE}--- Тест 6: Проверка эталонных URL источников ---${C_RESET}"
expected_prefix="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public"
if [[ "$SOURCE_GOVERNMENT_URL" == *"$expected_prefix"* ]] && \
   [[ "$SOURCE_SCANNER_URL" == *"$expected_prefix"* ]] && \
   [[ "$SOURCE_SKIPA_URL" == *"$expected_prefix"* ]]; then
    test_pass "Источники указывают на официальный shadow-netlab/traffic-guard-lists"
else
    test_fail "Источники URL" "Используются устаревшие адреса источников"
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
