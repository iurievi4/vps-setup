#!/usr/bin/env bash
# ==============================================================================
# NaïveProxy Manager — Главный оркестратор (naiveproxy-manager.sh)
# Версия: 1.0.0-MODULAR
# Архитектура: Модульная система (Nginx :80 Stub + Caddy :443 TLS)
# ==============================================================================

BASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$BASE_DIR/modules"

# Проверка наличия каталога модулей
if [ ! -d "$MODULE_DIR" ]; then
    echo "Критическая ошибка: Каталог модулей '$MODULE_DIR' не найден!" >&2
    exit 1
fi

# Подключение модулей
source "$MODULE_DIR/common.sh"
source "$MODULE_DIR/nginx.sh"
source "$MODULE_DIR/caddy.sh"
source "$MODULE_DIR/naiveproxy.sh"
source "$MODULE_DIR/webui.sh"
source "$MODULE_DIR/maintenance.sh"

require_root() {
    check_root
}

# ------------------------------------------------------------------------------
# Подменю компонентов
# ------------------------------------------------------------------------------

menu_nginx() {
    while true; do
        print_header
        echo -e "${BOLD}${CYAN}УПРАВЛЕНИЕ NGINX (:80 САЙТ-ЗАГЛУШКА)${NC}\n"
        local site_type n_status
        site_type=$(detect_existing_nginx_site)
        n_status=$(nginx_status)

        echo -e "  Статус службы   : $([ "$n_status" = "RUNNING" ] && echo -e "${GREEN}RUNNING (:80)${NC}" || echo -e "${RED}STOPPED${NC}")"
        echo -e "  Текущий сайт    : ${BOLD}$site_type${NC}"
        echo -e "  Каталог заглушки: $NGINX_STUB_ROOT"
        echo "──────────────────────────────────────────────────────"
        echo "  [1] Проверить конфликт порта 80"
        echo "  [2] Развернуть / восстановить безопасный Stub (:80)"
        echo "  [3] Проверить синтаксис конфигурации (nginx -t)"
        echo "  [4] Перезапустить Nginx"
        echo "  [5] Показать статус и логи службы"
        echo "  [0] Назад в главное меню"
        echo "──────────────────────────────────────────────────────"
        echo ""
        read -r -p "Выберите действие [0-5]: " nchoice
        case "$nchoice" in
            1)
                check_port80_conflict
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            2)
                ensure_nginx_stub
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            3)
                if validate_nginx; then
                    success "Конфигурация Nginx корректна (nginx -t OK)."
                else
                    error "Обнаружены ошибки в конфигурации Nginx:"
                    nginx -t
                fi
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            4)
                restart_nginx
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            5)
                systemctl status nginx --no-pager -l
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            0) return 0 ;;
            *) error "Неверный выбор."; sleep 1 ;;
        esac
    done
}

menu_caddy() {
    while true; do
        print_header
        echo -e "${BOLD}${CYAN}УПРАВЛЕНИЕ CADDY WEB SERVER (:443 TLS)${NC}\n"
        local c_status="STOPPED"
        systemctl is-active --quiet caddy 2>/dev/null && c_status="RUNNING"

        echo -e "  Статус службы : $([ "$c_status" = "RUNNING" ] && echo -e "${GREEN}RUNNING (:443)${NC}" || echo -e "${RED}STOPPED${NC}")"
        echo -e "  Бинарник Caddy: $([ -x "$CADDY_BIN" ] && echo -e "${GREEN}$CADDY_BIN${NC}" || echo -e "${RED}НЕ НАЙДЕН${NC}")"
        echo -e "  Caddyfile     : $([ -f "$CADDY_FILE" ] && echo -e "${GREEN}$CADDY_FILE${NC}" || echo -e "${RED}НЕ НАЙДЕН${NC}")"
        echo "──────────────────────────────────────────────────────"
        echo "  [1] Проверить порт 443"
        echo "  [2] Собрать / перекомпилировать Caddy с forwardproxy"
        echo "  [3] Проверить синтаксис Caddyfile"
        echo "  [4] Перезагрузить конфигурацию (zero-downtime reload)"
        echo "  [5] Перезапустить службу caddy.service"
        echo "  [6] Создать резервную копию Caddyfile"
        echo "  [7] Показать логи службы caddy (journalctl)"
        echo "  [0] Назад в главное меню"
        echo "──────────────────────────────────────────────────────"
        echo ""
        read -r -p "Выберите действие [0-7]: " cchoice
        case "$cchoice" in
            1)
                check_port443_conflict
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            2)
                build_caddy
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            3)
                if validate_caddyfile; then
                    success "Конфигурация Caddyfile валидна."
                fi
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            4)
                reload_caddy
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            5)
                restart_caddy
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            6)
                backup_caddy_config
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            7)
                journalctl -u caddy --no-pager -n 30
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            0) return 0 ;;
            *) error "Неверный выбор."; sleep 1 ;;
        esac
    done
}

menu_naiveproxy() {
    while true; do
        print_header
        echo -e "${BOLD}${CYAN}УПРАВЛЕНИЕ ДВИЖКОМ NAÏVEPROXY${NC}\n"
        load_credentials 2>/dev/null || true
        local cur_dom="${DOMAIN:-не настроен}"

        echo -e "  Текущий домен : ${BOLD}$cur_dom${NC}"
        echo -e "  Пользователь  : ${BOLD}${USERNAME:-не настроен}${NC}"
        echo -e "  Порт прокси   : ${BOLD}${PORT:-443}${NC}"
        echo "──────────────────────────────────────────────────────"
        echo "  [1] Мастер подготовки и проверки домена"
        echo "  [2] Быстро переключить домен (без перекомпиляции)"
        echo "  [3] Управление пользователями и клиентами"
        echo "  [4] Показать реквизиты и client.json"
        echo "  [5] Перезапустить NaïveProxy"
        echo "  [6] Остановить NaïveProxy"
        echo "  [0] Назад в главное меню"
        echo "──────────────────────────────────────────────────────"
        echo ""
        read -r -p "Выберите действие [0-6]: " pchoice
        case "$pchoice" in
            1) domain_wizard ;;
            2)
                read -r -p "Введите новый домен: " ndom
                ndom=$(echo "$ndom" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
                [ -n "$ndom" ] && apply_new_domain "$ndom"
                ;;
            3) manage_clients_menu ;;
            4)
                show_info
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            5)
                restart_naiveproxy
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            6)
                stop_naiveproxy
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            0) return 0 ;;
            *) error "Неверный выбор."; sleep 1 ;;
        esac
    done
}

menu_backup_restore() {
    while true; do
        print_header
        echo -e "${BOLD}${CYAN}РЕЗЕРВНОЕ КОПИРОВАНИЕ И ВОССТАНОВЛЕНИЕ${NC}\n"
        echo "  [1] Создать резервную копию конфигураций (/etc/naiveproxy, /etc/caddy)"
        echo "  [2] Восстановить конфигурации из существующей копии"
        echo "  [0] Назад в главное меню"
        echo "──────────────────────────────────────────────────────"
        echo ""
        read -r -p "Выберите действие [0-2]: " bchoice
        case "$bchoice" in
            1)
                backup_config
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            2)
                restore_config
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            0) return 0 ;;
            *) error "Неверный выбор."; sleep 1 ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Главное меню Orchestrator
# ------------------------------------------------------------------------------

show_main_menu() {
    while true; do
        print_header

        local display_domain="не настроен"
        local naive_badge="${YELLOW}не установлен${NC}"
        local caddy_badge="${RED}STOPPED${NC}"
        local nginx_badge="${RED}STOPPED${NC}"
        local web_badge="${YELLOW}не установлен${NC}"

        load_credentials 2>/dev/null || true
        load_domain_check 2>/dev/null || true

        if is_naiveproxy_installed; then
            display_domain="${DOMAIN:-$CHECKED_DOMAIN}"
            naive_badge="${GREEN}✓ INSTALLED${NC}"
        elif [ -n "$CHECKED_DOMAIN" ]; then
            display_domain="$CHECKED_DOMAIN"
        fi

        systemctl is-active --quiet caddy 2>/dev/null && caddy_badge="${GREEN}✓ RUNNING (:443)${NC}"
        systemctl is-active --quiet nginx 2>/dev/null && nginx_badge="${GREEN}✓ RUNNING (:80)${NC}"

        if is_webui_ready; then
            web_badge="${GREEN}✓ RUNNING (:18080 -> /admin/)${NC}"
        elif [ -f "$WEB_SCRIPT_FILE" ]; then
            web_badge="${RED}STOPPED${NC}"
        fi

        echo "──────────────────────────────────────────────────────"
        echo -e "  VPS IPv4:     ${BOLD}${GREEN}${SERVER_IPV4:-не определён}${NC}"
        echo -e "  Домен:        ${BOLD}$display_domain${NC}"
        echo -e "  NaïveProxy:   $naive_badge"
        echo -e "  Caddy :443:   $caddy_badge"
        echo -e "  Nginx :80:    $nginx_badge"
        echo -e "  Web Manager:  $web_badge"
        echo "──────────────────────────────────────────────────────"
        echo ""
        echo -e "${BOLD}  УСТАНОВКА И КОМПОНЕНТЫ${NC}"
        echo "  [1]  Полная установка (Full installation)"
        echo "  [2]  Nginx (:80 сайт-заглушка)"
        echo "  [3]  Caddy (:443 TLS веб-сервер)"
        echo "  [4]  NaïveProxy (домен и движок)"
        echo "  [5]  Web UI (панель управления)"
        echo ""
        echo -e "${BOLD}  УПРАВЛЕНИЕ И ОБСЛУЖИВАНИЕ${NC}"
        echo "  [6]  Диагностика и статус (Status)"
        echo "  [7]  Пользователи и клиенты (Users)"
        echo "  [8]  Перезапуск служб (Restart services)"
        echo "  [9]  Безопасное обновление Caddy (Update)"
        echo "  [10] Резервное копирование и откат (Backup / Restore)"
        echo "  [11] Переустановка / Удаление комплекса"
        echo ""
        echo "  [0]  Выход"
        echo "──────────────────────────────────────────────────────"
        echo ""
        read -r -p "Выберите действие [0-11]: " opt
        case "$opt" in
            1) run_installation ;;
            2) menu_nginx ;;
            3) menu_caddy ;;
            4) menu_naiveproxy ;;
            5) manage_web_ui ;;
            6)
                show_status
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            7) manage_clients_menu ;;
            8)
                restart_all
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            9)
                update_caddy
                read -r -p "Нажмите Enter для продолжения..."
                ;;
            10) menu_backup_restore ;;
            11)
                echo ""
                echo "1) Переустановить NaïveProxy"
                echo "2) Полностью удалить NaïveProxy и Caddy"
                echo "0) Отмена"
                read -r -p "Выберите вариант [0-2]: " ropt
                case "$ropt" in
                    1) run_reinstall ;;
                    2) uninstall_all ;;
                esac
                ;;
            0) exit 0 ;;
            *) error "Неверный ввод."; sleep 1 ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Точка входа / CLI диспетчер
# ------------------------------------------------------------------------------

main() {
    local action="${1:-}"

    case "$action" in
        help|--help|-h)
            echo "Использование: $0 [команда] [параметры]"
            echo ""
            echo "Команды:"
            echo "  install [домен] - Полная пошаговая установка комплекса"
            echo "  nginx           - Меню управления Nginx (:80 сайт-заглушка)"
            echo "  caddy           - Меню управления Caddy (:443 TLS)"
            echo "  domain          - Мастер подготовки и проверки домена"
            echo "  status|diagnose - Комплексная диагностика всех компонентов"
            echo "  config|info     - Реквизиты подключения и клиентский client.json"
            echo "  clients         - Интерактивное управление клиентами"
            echo "  client-list     - Вывести список клиентов в консоль"
            echo "  client-add      - Добавить нового клиента (логин, пароль, примечание)"
            echo "  client-del      - Удалить клиента по логину"
            echo "  web|webui       - Меню управления Web UI"
            echo "  web-install     - Развернуть Web UI без переустановки Caddy"
            echo "  web-restart     - Перезапустить службу Web UI"
            echo "  restart         - Перезапустить все службы комплекса"
            echo "  update          - Безопасное обновление Caddy с авто-откатом"
            echo "  backup          - Создать резервную копию конфигураций"
            echo "  restore         - Восстановить конфигурации из копии"
            echo "  reinstall       - Переустановка с сохранением реквизитов"
            echo "  uninstall       - Полное удаление с восстановлением системы"
            exit 0
            ;;
    esac

    require_root
    check_os
    check_arch
    install_dependencies
    resolve_server_ips
    load_users 2>/dev/null || true

    case "$action" in
        install) run_installation "${2:-}" "${3:-}" ;;
        nginx) menu_nginx ;;
        caddy) menu_caddy ;;
        domain|check) domain_wizard ;;
        status|diagnose) show_status ;;
        config|info) show_info ;;
        clients) manage_clients_menu ;;
        client-list) client_list ;;
        client-list-json) cat "$USERS_FILE" 2>/dev/null || echo "[]" ;;
        client-add) client_add "${2:-}" "${3:-}" "${4:-}" ;;
        client-del|client-delete) client_delete "${2:-}" ;;
        web|webui) manage_web_ui ;;
        web-install) install_web_ui ;;
        web-restart) restart_webui ;;
        restart) restart_all ;;
        update) update_caddy ;;
        backup) backup_config ;;
        restore) restore_config ;;
        reinstall) run_reinstall ;;
        uninstall|remove) uninstall_all ;;
        "") show_main_menu ;;
        *) error "Неизвестная команда: '$action'. Используйте: $0 help"; exit 1 ;;
    esac
}

main "$@"
