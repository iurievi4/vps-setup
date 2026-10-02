# 🚀 VPS Setup & Security Management Toolkit

Комплексный набор инструментов и Bash-скриптов для автоматического развёртывания, защиты, маскировки и администрирования VPS на базе **Debian 11/12** и **Ubuntu 20.04/22.04/24.04**.

Проект спроектирован по модульному принципу: все компоненты могут запускаться как централизованно через единый диспетчер `install.sh`, так и полностью автономно в виде независимых утилит.

---

## 📑 Содержание

1. [⚡ Быстрый старт (Центральный установщик: install.sh)](#-быстрый-старт-центральный-установщик-installsh)
2. [📁 Структура проекта](#-структура-проекта)
3. [🛠️ Компоненты системы](#️-компоненты-системы)
   - [1. install.sh — Главный менеджер установки](#1-installsh--главный-менеджер-установки)
   - [2. setup.sh — Базовая настройка системы и окружения](#2-setupsh--базовая-настройка-системы-и-окружения)
   - [3. nginx-templates.sh — Сайты-маскировки, HTML-шаблоны и Прокси](#3-nginx-templatessh--сайты-маскировки-html-шаблоны-и-прокси)
   - [4. ssh-key-manager.sh — Управление SSH-ключами и безопасность](#4-ssh-key-managersh--управление-ssh-ключами-и-безопасность)
   - [5. vps-security-installer.sh — Fail2ban, AntiScanner и WARP](#5-vps-security-installersh--fail2ban-antiscanner-и-warp)
4. [🌐 Архитектура Nginx: работа по IP без домена](#-архитектура-nginx-работа-по-ip-без-домена)
5. [🔐 Регламент безопасной настройки SSH](#-регламент-безопасной-настройки-ssh)
6. [🛡️ Сетевая безопасность и UFW Firewall](#️-сетевая-безопасность-и-ufw-firewall)
7. [💾 Бэкапы и сценарии восстановления](#-бэкапы-и-сценарии-восстановления)

---

## ⚡ Быстрый старт (Центральный установщик: `install.sh`)

Главной точкой входа в проект является **`install.sh`**. Скрипт в реальном времени анализирует состояние сервера (наличие маркера первичной настройки, базы данных 3x-ui), выводит интерактивное меню и скачивает актуальные версии компонентов напрямую из репозитория.

### Запуск в интерактивном режиме:

```bash
bash -c "$(curl -fsSL [https://raw.githubusercontent.com/iurievi4/vps-setup/main/install.sh](https://raw.githubusercontent.com/iurievi4/vps-setup/main/install.sh))"
Или с предварительным скачиванием:Bashcurl -fsSL [https://raw.githubusercontent.com/iurievi4/vps-setup/main/install.sh](https://raw.githubusercontent.com/iurievi4/vps-setup/main/install.sh) -o /root/install.sh
chmod +x /root/install.sh
/root/install.sh
Внешний вид меню install.sh:Plaintext╔══════════════════════════════════════════════════════════╗
║                      VPS INSTALLER                       ║
╚══════════════════════════════════════════════════════════╝

  [●] Состояние: СЕРВЕР УЖЕ НАСТРОЕН (/etc/vps-bootstrap-complete)
  [●] База 3x-ui: ОБНАРУЖЕНА (/etc/x-ui/x-ui.db)

  1) Полная автоматическая установка
     └─ setup.sh в тихом режиме (БД сохраняется, без вопросов)

  2) Ручной запуск setup.sh
     └─ интерактивные вопросы (FORCE_BOOTSTRAP=1 включён)

  3) Установка безопасности
     └─ vps-security-installer.sh (Fail2ban, AntiScanner, WARP)

  4) Управление SSH-ключами (SSH Manager)
     └─ ssh-key-manager.sh (генерация Ed25519, GitHub, защита от lockout)

  5) Шаблоны сайтов и прокси (Nginx Manager)
     └─ nginx-templates.sh (HTML-маскировка по IP, готовые шаблоны, Reverse Proxy)

  6) Сбросить маркер настройки (/etc/vps-bootstrap-complete)
     └─ удалить маркер, чтобы любой скрипт считал сервер 'чистым'

  0) Выход

Выберите вариант [0-6]:
Прямой запуск через аргументы командной строки (CLI):Скрипт полностью поддерживает автоматизацию и передачу параметров:Bashbash /root/install.sh 1          # Полный автопилот setup.sh
bash /root/install.sh 2          # Ручной запуск setup.sh
bash /root/install.sh 3          # Установка безопасности
bash /root/install.sh 4          # SSH Key Manager (алиас: bash install.sh ssh)
bash /root/install.sh 5          # Nginx Manager   (алиас: bash install.sh nginx)
bash /root/install.sh 6          # Сброс маркера   (алиас: bash install.sh reset)
📁 Структура проектаPlaintextvps-setup/
├── install.sh                  # Главный диспетчер и установщик проекта
├── setup.sh                    # Базовый скрипт системной подготовки VPS
├── nginx-templates.sh          # Менеджер HTML-сайтов, Nginx и Reverse Proxy
├── ssh-key-manager.sh          # Управление SSH-ключами, Ed25519 и отключение паролей
├── vps-security-installer.sh   # Модуль защиты: Fail2ban, AntiScanner, WARP, MOTD
│
├── nginx/
│   └── templates/              # Коллекция готовых HTML-шаблонов сайтов-маскировок:
│       ├── filecloud/          # ☁️  Cloud Storage
│       ├── downloader/         # ⬇️  Download Manager
│       ├── converter/          # 📁 File Converter
│       ├── games-site/         # 🎮 Games Site
│       ├── 10gag/              # 😂 Memes Site
│       ├── modmanager/         # 🛠️ Mod Manager
│       ├── speedtest/          # 🚀 Speed Test
│       ├── convertit/          # 🎬 Video Converter
│       ├── 503 error pages/    # ⚠️ 503 Service Unavailable (версии v1 и v2)
│       └── YouTube endless captcha/ # 🤖 Интерактивная капча в стиле YouTube
│
└── README.md                   # Документация проекта
Сводная таблица компонентовФайл / КаталогНазначениеБыстрый прямой запускinstall.shЦентральное меню управления установкой и модулямиbash -c "$(curl -fsSL https://raw.githubusercontent.com/iurievi4/vps-setup/main/install.sh)"setup.shПервичная подготовка VPS, ядро, BBR, Swap, 3x-uibash -c "$(curl -fsSL https://raw.githubusercontent.com/iurievi4/vps-setup/main/setup.sh)"nginx-templates.shРазвёртывание сайтов на IP:80, прокси, SSLbash -c "$(curl -fsSL https://raw.githubusercontent.com/iurievi4/vps-setup/main/nginx-templates.sh)"ssh-key-manager.shГенерация Ed25519, аудит authorized_keys, Lockout Preventionbash -c "$(curl -fsSL https://raw.githubusercontent.com/iurievi4/vps-setup/main/ssh-key-manager.sh)"vps-security-installer.shУстановка защиты: Fail2ban, AntiScanner IPset, WARPbash -c "$(curl -fsSL https://raw.githubusercontent.com/iurievi4/vps-setup/main/vps-security-installer.sh)"nginx/templates/Исходные каталоги готовых адаптивных HTML5-шаблоновКлонируются автоматически в /tmp/nginx-template-repo🛠️ Компоненты системы1. install.sh — Главный менеджер установкиinstall.sh обеспечивает безопасный запуск и оркестрацию всех утилит:Режим 1: Полная автоматическая установка (Silent Auto)Запускает setup.sh в фоновом noninteractive-режиме.Перед запуском проверяет наличие существующей базы /etc/x-ui/x-ui.db и делает снимок в /root/xui_backups/x-ui-before-setup-<дата>.db.Предопределяет флаги: INSTALL_WARP=1, 3x-ui=1, базы данных PostgreSQL/MSSQL/TorrServer отключены.Автоматически передаёт FORCE_BOOTSTRAP=1, гарантируя успешный повторный запуск даже на настроенном сервере.Режим 2: Ручной запуск setup.sh (Interactive)Позволяет пройти опросник setup.sh вручную, сохраняя созданный маркер или обновляя параметры.Режим 3: Установка безопасностиЗапускает автономный скрипт vps-security-installer.sh.Режим 4: SSH Key & Security ManagerЗагружает и открывает интерактивное меню ssh-key-manager.sh.Режим 5: Nginx Template & Security ManagerЗагружает и открывает интерактивное меню nginx-templates.sh.Режим 6: Сброс маркера настройкиУдаляет системный файл /etc/vps-bootstrap-complete, позволяя любой версии скриптов считать систему «чистой».2. setup.sh — Базовая настройка системы и окруженияСкрипт выполняет глубокую оптимизацию ОС Linux для высокопроизводительной работы сетевых сервисов:Системные зависимости: Nginx, Git, curl, cron, iproute2, iputils-ping, lm-sensors, nvme-cli, iptables, iptables-persistent, UFW, socat, SQLite3.Сетевой стек ядра Linux (Sysctl):Активация алгоритма управления перегрузками TCP BBR (net.ipv4.tcp_congestion_control = bbr).Включение TCP Fast Open (net.ipv4.tcp_fastopen = 3).Оптимизация буферов сокетов и лимитов открытых файлов (fs.file-max, net.core.somaxconn).Память и виртуализация:Создание Swap-файла нужного размера с расчётом под RAM.Настройка vm.swappiness = 10 и vm.vfs_cache_pressure = 50.Базовый Nginx:Настройка структуры /etc/nginx/sites-available и /etc/nginx/sites-enabled.Создание стартовой заглушки cloud-node в /var/www/acme с обработкой ACME challenge.Системный мониторинг:Установка двухмодульного информативного MOTD-баннера.3. nginx-templates.sh — Сайты-маскировки, HTML-шаблоны и ПроксиСкрипт оптимизирован для работы с VPS, использующим только прямой IP-адрес (без необходимости привязывать домен).24 пункта интерактивного меню:Plaintext  🌐 САЙТЫ (ВСТРОЕННЫЕ):
    1) 📁 Файловый архив (Open Source Mirror & Packages)
    2) 🎬 Медиаархив (Video / Audio Streaming Vault)
    3) 📰 Новостной портал (The TechPulse Journal)
    4) 📚 Техническая документация (API & Docs)
    5) 🏢 Корпоративный сайт (Enterprise B2B Cloud)
    6) 🌐 Нейтральная заглушка (Clean Cloud Node 200 OK)

  🎨 ГОТОВЫЕ HTML-ШАБЛОНЫ (из GitHub: iurievi4/vps-setup):
    7) ☁️  Cloud Storage
    8) ⬇️  Download Manager
    9) 📁 File Converter
   10) 🎮 Games Site
   11) 😂 Memes Site
   12) 🛠️ Mod Manager
   13) 🚀 Speed Test
   14) 🎬 Video Converter
   15) ⚠️ 503 Error Pages (интерактивный выбор v1 или v2)
   16) 🤖 YouTube Captcha (интерактивная страница проверки)

  🔄 ПРОКСИРОВАНИЕ (изолированные конфигурации, не затрагивают сайт):
   17) 🔄 Reverse Proxy (стандартный HTTP backend)
   18) 🔌 Reverse Proxy + WebSocket (3x-ui / Xray / VLESS на порт 443)
   19) 🗑️ Управление / удаление Proxy

  🔐 SSL И БЕЗОПАСНОСТЬ:
   20) 🔐 ACME / Let's Encrypt (Webroot /.well-known)
   21) 🛡️ Security Headers (HSTS, CSP, X-Frame-Options)

  📋 УПРАВЛЕНИЕ:
   22) 📋 Текущая конфигурация (порты, статус, nginx -t)
   23) 💾 Создать backup вручную
   24) ↩️ Восстановить backup (в 1 клик или из архива)
Соответствие каталогов в репозитории:№ в менюОтображаемое имяКаталог в GitHub (nginx/templates/)Целевая папка на сервере7☁️ Cloud Storagefilecloud/var/www/cloud-storage8⬇️ Download Managerdownloader/var/www/download-manager9📁 File Converterconverter/var/www/file-converter10🎮 Games Sitegames-site/var/www/games-site11😂 Memes Site10gag/var/www/memes-site12🛠️ Mod Managermodmanager/var/www/mod-manager13🚀 Speed Testspeedtest/var/www/speed-test14🎬 Video Converterconvertit/var/www/video-converter15⚠️ 503 Error Pages503 error pages/v1 или /v2/var/www/error-50316🤖 YouTube CaptchaYouTube endless captcha/var/www/youtube-captcha4. ssh-key-manager.sh — Управление SSH-ключами и безопасностьУтилита обеспечивает абсолютную защиту от потери доступа (Lockout Prevention) и автоматизирует работу с ключами Ed25519.Главное меню:Plaintext  УПРАВЛЕНИЕ КЛЮЧАМИ:
    1) 🔑 Установить SSH-ключ (GitHub / ввод / файл / генерация)
    2) 📋 Показать установленные ключи
    3) ❌ Удалить SSH-ключ

  ПАРОЛЬНАЯ БЕЗОПАСНОСТЬ:
    4) 🔒 Отключить вход по паролю (защита от брутфорса)
    5) 🔓 Включить вход по паролю

  СИСТЕМА И БЭКАПЫ:
    6) 💾 Создать backup authorized_keys & sshd
    7) ↩️  Восстановить authorized_keys из бэкапа
    8) 🔍 Проверить SSH-конфигурацию (sshd -t)
    9) 🌐 Показать текущий SSH-порт и статус службы

    0) 🚪 Выход
Подменю источников ключа (Пункт 1):🔒 Скачать из приватного репозитория GitHub (iurievi4/my-private-backups/ssh/id_ed25519.pub) через Personal Access Token.📋 Вставить публичный ключ вручную через терминал.📁 Прочитать из локального файла на сервере.🆕 Сгенерировать новую пару и установить ключ (Ed25519, вывод fingerprint, автодобавление .pub в authorized_keys).5. vps-security-installer.sh — Fail2ban, AntiScanner и WARPМодуль комплексной защиты сервера от сетевого сканирования и несанкционированного доступа:Fail2ban (защита SSH и длительная блокировка):Конфигурация в /etc/fail2ban/jail.d/vps-setup.local (не затрагивает системный jail.conf).Автоматическое определение порта SSH (по умолчанию 1241).Jail [sshd]: 3 неудачные попытки за 10 минут = бан на 24 часа.Jail [recidive]: рецидивисты блокируются на 1 неделю через iptables.AntiScanner (блокировка ботов и сканеров):Загрузка черного списка опасных подсетей сканеров (Censys, Shodan и др.).Использование высокопроизводительного ядра ipset (SCANNERS-BLOCK-V4).Ежедневное автообновление базы через systemd timer (antiscan.timer).Cloudflare WARP:Настройка локального SOCKS5 outbound-прокси на порту 40000 (для маршрутизации трафика 3x-ui / Xray).Информативный MOTD:Модули в /etc/update-motd.d/: вывод температуры CPU/NVMe, потребления RAM/Swap, аптайма, статуса Fail2ban и заблокированных IP.🌐 Архитектура Nginx: работа по IP без доменаСкрипт оптимизирован под работу без домена:Plaintext                           NGINX
                             │
            ┌────────────────┴────────────────┐
            │                                 │
       ПОРТ 80 (HTTP)                  ПОРТ 443 (HTTPS)
            │                                 │
     [http://94.xxx.xxx.xxx/](http://94.xxx.xxx.xxx/)             VLESS / Xray / 3x-ui
            │                                 │
  ОДИН активный сайт-маскировка      Изолированные proxy-сервисы
  (listen 80 default_server;)        (sites-enabled/proxy-*.conf)
            │                                 │
  При смене шаблона:                 НИКОГДА не затрагиваются
  Games Site → Speed Test → ...      и не перезаписываются
Принципы работы маскировки:Установка в 1 клик без лишних вопросов: При выборе любого шаблона сайт автоматически становится default_server на порту 80 с server_name _;.Один сайт на порту 80: При установке нового сайта предыдущий симлинк (например, cloud-node или прошлый шаблон) отключается из sites-enabled/. Сам файл в sites-available/ остаётся в сохранности.Прямой переход: Запрос http://ВАШ_IP/ сразу открывает активный сайт.Полная изоляция Proxy: Конфигурации proxy-*.conf лежат отдельно и никогда не удаляются и не перезаписываются при установке сайтов.Сохранение ACME: Все шаблоны имеют встроенный блок location ^~ /.well-known/acme-challenge/ { root /var/www/acme; }, поэтому получение и продление SSL не ломается при смене сайта.🔐 Регламент безопасной настройки SSHЧтобы гарантированно не потерять доступ к VPS, соблюдайте следующую последовательность:Шаг 1. Генерация ключа (в ssh-key-manager.sh пункт 1 → 4)Скрипт сгенерирует пару Ed25519 (/root/.ssh/id_ed25519 и /root/.ssh/id_ed25519.pub).Публичный ключ автоматически добавится в /root/.ssh/authorized_keys.Старые ключи не удаляются.⚠️ КРИТИЧЕСКОЕ ПРАВИЛО: Приватный ключ id_ed25519 НИКОГДА нельзя загружать в GitHub! В репозиторий бэкапов (my-private-backups/ssh/) загружается ТОЛЬКО публичный ключ id_ed25519.pub.Шаг 2. Скачивание ключа на свой ПКЧерез MobaXterm: Откройте SFTP слева, перейдите в /root/.ssh/ и перетащите id_ed25519 на свой компьютер.Через SCP в консоли ПК:Bashscp -P 1241 root@IP_СЕРВЕРА:/root/.ssh/id_ed25519 ~/.ssh/
Шаг 3. Проверка входа по ключуВ MobaXterm: Session settings → SSH → Advanced SSH settings → флажок Use private key → укажите скачанный id_ed25519.Откройте новую вкладку и подключитесь, НЕ закрывая текущую сессию!Шаг 4. Двухступенчатое отключение пароля (Пункт 4 меню)Кнопка 4 запускает строгую проверку:Автоматический аудит: проверка наличия authorized_keys, валидация синтаксиса ключей, тест sshd -t.Запрос подтверждения: скрипт потребует ввести слово YES заглавными буквами:PlaintextВы уже успешно вошли в SSH в новой сессии с помощью ключа?
Введите именно 'YES' (заглавными буквами) для продолжения: YES
Создаётся резервная копия authorized_keys и sshd_config.Вносится директива PasswordAuthentication no.Тестируется sshd -t. При малейшей ошибке происходит автоматический откат.Перезагрузка systemctl reload ssh выполняется без разрыва текущих сессий.🛡️ Сетевая безопасность и UFW FirewallВ базовом шаблоне setup.sh используется нестандартный порт SSH:PlaintextSSH-порт: 1241
Стандартная таблица портов UFW:ПортПротоколНазначение1241TCPSSH (защищён Fail2ban)80TCPHTTP (Nginx сайт-маскировка, ACME Challenge)443TCP/UDPHTTPS / VLESS / Xray / 3x-ui40000TCPЛокальный SOCKS5 WARP (привязан строго к 127.0.0.1)Проверка состояния файрвола:Bashufw status verbose
💾 Бэкапы и сценарии восстановленияРезервные копии базы 3x-ui:При каждом запуске install.sh автоматически создаётся копия базы:Bashls -la /root/xui_backups/
Резервные копии Nginx:При любых операциях в nginx-templates.sh полные снимки сохраняются одновременно в двух местах:/etc/nginx/backups/nginx-backup-<дата>//root/nginx-backups/nginx-backup-<дата>/Восстановление Nginx в 1 клик:В меню nginx-templates.sh выберите пункт 24 → 1 (Быстрое восстановление последнего бэкапа).Резервные копии SSH:Снимки хранятся в:/root/.ssh/backups/authorized_keys-<дата>/etc/ssh/backups/sshd_config-<дата>Восстановление SSH:В меню ssh-key-manager.sh выберите пункт 7 для интерактивного выбора копии authorized_keys.📄 ЛицензияПроект распространяется под лицензией MIT. Используйте на собственных серверах, адаптируйте и дополняйте конфигурации под свои задачи.
---

### Ссылка на сохранённый файл

Файл также сохранён на вашем Google Диске: 📄 **[README.md](https://docs.google.com/document/d/1WHKfA8rNHUy39HBDDgS2Tu1ah-Ql4Nrm90g0ooFJ-tc/edit?usp=drivesdk)**

http://googleusercontent.com/action_card_content/cf364e35-dc8c-4b6e-b18a-7b805c54e3dc
http://googleusercontent.com/action_card_content/8f6b1d59-49ae-4d46-b2c4-0c28c3a92967
