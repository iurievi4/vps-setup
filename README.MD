VPS Setup & Manager (`vps-manager.sh`) 🚀
![OS: Ubuntu & Debian](https://img.shields.io/badge/OS-Ubuntu%20%7C%20Debian-E95420?logo=linux&logoColor=white)
![Shell: Bash](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnu-bash&logoColor=white)
![Security: UFW + Fail2ban](https://img.shields.io/badge/Security-UFW%20%2B%20Fail2ban-blue)
![Proxy: NaïveProxy + Caddy](https://img.shields.io/badge/Proxy-NaïveProxy%20%2B%20Caddy-00ADD8?logo=caddy&logoColor=white)
![Web: Nginx Camouflage](https://img.shields.io/badge/Web-Nginx%20Decoy%20Templates-009639?logo=nginx&logoColor=white)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)
Единый модульный инструментарий для комплексного администрирования Linux VPS: первичная инициализация системы, усиление безопасности (hardening), развертывание высокоскоростного прокси NaïveProxy, подключение маскировочных сайтов Nginx и резервное копирование.

Центральной точкой входа и главным оркестратором проекта является интерактивное меню `vps-manager.sh` (также доступно через `vps.sh` и `install.sh`).

---

## 📌 Оглавление

1. [Архитектура и дерево вызовов](#-архитектура-и-дерево-вызовов)
2. [Быстрый старт](#-быстрый-старт)
3. [Системные требования](#-системные-требования)
4. [Модули и компоненты системы](#-модули-и-компоненты-системы)
   * [1. Базовая настройка VPS (setup.sh, vps.sh, vps-lite.sh)](#1-базовая-настройка-vps-setupsh-vpssh-vps-litesh)
   * [2. Безопасность и VPS IP Guard (security-install+.sh, modules/ip-guard.sh, vps-security-installer.sh)](#2-безопасность-и-vps-ip-guard)
   * [3. Прокси NaïveProxy & Caddy (naiveproxy-manager.sh и modules/)](#3-прокси-naïveproxy--caddy-naiveproxy-managersh-и-modules)
   * [4. Камуфляжные сайты Nginx (nginx-templates.sh, nginx/templates/)](#4-камуфляжные-сайты-nginx-nginx-templatessh-nginxtemplates)
   * [5. Сервисные утилиты (export-xui-db.sh, lers-manager.sh, install.sh)](#5-сервисные-утилиты)
5. [Настройка клиентов NaïveProxy](#-настройка-клиентов-naïveproxy)
6. [Диагностика и команды проверки](#-диагностика-и-команды-проверки)
7. [Лицензия](#-лицензия)

---

## 🌳 Архитектура и дерево вызовов

Скрипт `vps-manager.sh` объединяет задачи системного администрирования в единое иерархическое дерево:

```text
vps-manager.sh / vps.sh (ГЛАВНЫЙ ДИСПЕТЧЕР / ЕДИНАЯ ТОЧКА ВХОДА)
 │
 ├── [1] ⚡ VPS LITE ──> vps-lite.sh (Быстрое обслуживание и мониторинг)
 │     ├── Обновление: apt update && apt upgrade
 │     ├── Очистка: autoremove, autoclean, vacuum journalctl
 │     ├── Исправление: dpkg --configure -a, apt --fix-broken install
 │     ├── Диагностика: ресурсы, нагрузка, сеть, порты, пинг
 │     ├── Логи: journalctl, SSH auth.log, Fail2ban
 │     └── [12] ──> Переход в install.sh
 │
 └── [2] 🛠 VPS FULL ──> install.sh (Полный установщик и менеджер сервисов)
       │
       ├── 1. ОСНОВНАЯ НАСТРОЙКА VPS
       │     ├── [1] Полная автоустановка ──> setup.sh (тихий режим)
       │     └── [2] Ручная настройка     ──> setup.sh (интерактивный режим)
       │           ├── SWAP (2 GB), оптимизация ядра и TCP BBR
       │           ├── Настройка SSH-порта 1241, UFW и Fail2ban
       │           ├── Развертывание VPS IP Guard
       │           ├── Cloudflare WARP (SOCKS5 127.0.0.1:40000)
       │           ├── Nginx (:80) + панель 3x-ui / Xray
       │           ├── Автоматическое восстановление баз из my-private-backups
       │           └── Службы обслуживания и единый MOTD
       │
       ├── 2. БЕЗОПАСНОСТЬ И ДОСТУП
       │     ├── [3] Безопасность VPS ──> vps-security-installer.sh (Fail2ban + IP Guard + WARP)
       │     └── [4] SSH-ключи        ──> ssh-key-manager.sh (Ed25519, защита от lockout)
       │
       ├── 3. СЕРВИСЫ И СЕТЬ
       │     ├── [5] Шаблоны Nginx        ──> nginx-templates.sh (маскировка, reverse proxy)
       │     ├── [6] 3x-ui базы           ──> export-xui-db.sh (шифрование и проверка баз)
       │     ├── [7] Установка NaïveProxy ──> naiveproxy-install.sh (Caddy + forwardproxy)
       │     └── [8] Менеджер NaïveProxy  ──> naiveproxy-manager.sh
       │
       ├── 4. ОБСЛУЖИВАНИЕ VPS
       │     └── [9] Комплекс аудита      ──> системный аудит, таймеры, маркеры
       │
       ├── 5. УПРАВЛЕНИЕ ФУНКЦИЯМИ VPS
       │     └── [10] Службы и сервисы:
       │           ├── [1] Cloudflare WARP ──> подключение / socks5
       │           ├── [2] VPS IP Guard    ──> manage_ipguard (статус, reload, update, ban/unban)
       │           ├── [3] Fail2ban        ──> статус, jails, unban IP
       │           ├── [4] Файрвол UFW     ──> правила, открытие/закрытие портов
       │           ├── [5] Docker          ──> контейнеры, образы, prune
       │           └── [6-9] PostgreSQL, MS SQL, TorrServer, ЛЭРС УЧЁТ
       │
       └── 6. СИСТЕМА ДИСПЕТЧЕРИЗАЦИИ
             └── [11] ЛЭРС УЧЁТ ──> lers-manager.sh

Специализированный центр безопасности:
 security-install+.sh (Многоуровневый аудит и управление защитой)
  ├── 1) Сводный статус безопасности (UFW + Fail2ban + IP Guard)
  ├── 2) VPS IP Guard (управление, списки, ручной blacklist, таймеры, переустановка)
  ├── 3) Fail2ban
  ├── 4) UFW / Firewall
  └── 5) Системное обслуживание

Ядро сетевой фильтрации:
 modules/ip-guard.sh & ip-guard.conf (Автономный модуль /usr/local/sbin/ip-guard)
  ├── Наборы ipset: VPS-IP-GUARD-V4 и VPS-IP-GUARD-V6
  ├── Цепочка iptables: VPS-IP-GUARD
  ├── Systemd сервис: vps-ip-guard.service (без ExecStop, безопасный)
  └── Systemd таймер: vps-ip-guard-update.timer (24h) + cron в /etc/cron.d/vps-maintenance
```

---

## 🚀 Быстрый старт

### Способ 1. Запуск через Центр безопасности (Рекомендуется)

Запуск менеджера безопасности и фильтрации трафика:

```bash
curl -sSL "https://raw.githubusercontent.com/iurievi4/vps-setup/main/security-install%2B.sh" -o security-install+.sh
chmod +x security-install+.sh
sudo ./security-install+.sh
```

### Способ 2. Запуск Главного Диспетчера VPS

Запуск интерактивного меню администрирования:

```bash
curl -fsSL "https://raw.githubusercontent.com/iurievi4/vps-setup/main/vps-manager.sh" -o /root/vps-manager.sh
chmod +x /root/vps-manager.sh
sudo /root/vps-manager.sh
```

### Способ 3. Клонирование репозитория

```bash
# Обновление пакетов и установка базовых утилит
apt update && apt install -y git curl ipset iptables

# Клонирование репозитория
git clone https://github.com/iurievi4/vps-setup.git /root/vps-setup
cd /root/vps-setup

# Выдача прав на исполнение
chmod +x *.sh modules/*.sh
```

---

## 💻 Системные требования

| Компонент | Требование |
| :--- | :--- |
| **Поддерживаемые ОС** | Ubuntu 20.04, 22.04, 24.04 LTS &nbsp;/&nbsp; Debian 11, 12 |
| **Архитектура** | amd64 (x86_64), arm64 (aarch64) |
| **Права доступа** | root или пользователь с привилегиями sudo |
| **Аппаратные ресурсы** | От 512 МБ RAM (рекомендуется 1 ГБ+ при установке Docker), 5+ ГБ диска |
| **Сетевые порты** | 1241/tcp (или кастомный SSH), 80/tcp (HTTP), 443/tcp (HTTPS/NaïveProxy/Xray) |
| **Сетевые пакеты** | `ipset`, `iptables`, `curl`, `awk`, `grep`, `systemd` |

---

## 🛠 Модули и компоненты системы

### 1. Базовая настройка VPS (`setup.sh`, `vps.sh`, `vps-lite.sh`)

Служит надежным фундаментом системы:
* **Обновление пакетов:** актуализация системы через `apt update && apt upgrade` с подавлением интерактивных зависаний (`needrestart`).
* **Файл подкачки (Swap):** генерация swap 2 GB с параметром ядра `vm.swappiness=10`, предотвращающим падения служб по OOM (*Out Of Memory*).
* **Сетевой тюнинг (TCP BBR):** автоматическая проверка поддержки BBR ядром Linux, включение очереди `fq` и алгоритма `bbr` для минимизации задержек и потерь пакетов.
* **Кастомный порт SSH (1241):** безопасная смена порта SSH с предварительным открытием правил в UFW и защитой от потери доступа (*lockout protection*).
* **Cloudflare WARP:** развертывание официального клиента `cloudflare-warp` в изолированном режиме локального SOCKS5-прокси (`127.0.0.1:40000`).

---

### 2. Безопасность и VPS IP Guard

Проект полностью перешёл с устаревшего AntiScanner на автономный высокопроизводительный модуль **VPS IP Guard**:

#### Ключевые возможности VPS IP Guard:
1. **Ядро фильтрации на базе `ipset` и `iptables`:**
   * Входящий трафик фильтруется через наборы `hash:net`: `VPS-IP-GUARD-V4` и `VPS-IP-GUARD-V6`.
   * Создаётся отдельная цепочка `VPS-IP-GUARD` с правилом `DROP`, не вмешивающаяся в таблицы UFW и правила других сервисов.
2. **Официальные источники списков (`shadow-netlab/traffic-guard-lists`):**
   * Правительственные сети и регуляторы (`government_networks.list`);
   * Сети автоматических сетевых сканеров (`antiscanner.list`);
   * Хостинг-провайдеры и ботнеты (`skipa.list`).
3. **Безопасный systemd unit (Архитектурная защита):**
   * В службе `vps-ip-guard.service` **полностью отсутствует `ExecStop`**.
   * Остановка или перезапуск сервиса (`systemctl stop`) не снимает правила фильтрации из ядра — сервер всегда защищён.
4. **Атомарное обновление и защита от сбоев сети:**
   * Скачивание списков → строгая валидация CIDR → слияние → наполнение временного набора `VPS-IP-GUARD-V4-TMP` → атомарный `swap`.
   * Если любой из источников недоступен, текущий активный набор `ipset` **не сбрасывается**.
   * Порог `MIN_TOTAL_NETWORKS=50` защищает от применения пустых баз.
5. **Офлайн-восстановление (`reload`):**
   * При старте ОС списки загружаются из локального кэша `/etc/vps-ip-guard/cache/` мгновенно, без обращения к интернету.
6. **Ручной чёрный список (Manual Blacklist):**
   * Быстрое добавление и снятие блокировок (`ip-guard ban <IP/CIDR>` / `ip-guard unban <IP/CIDR>`) через файл `/etc/vps-ip-guard/manual.list`.
   * Ручные блокировки не затираются при автоматических обновлениях из сети.
7. **Подробная аналитика дедупликации (`ip-guard status`):**
   * Отображение количества сырых записей по каждому источнику, числа схлопнутых пересечений и уникальных сетей в `ipset`.
8. **Автоматическое расписание:**
   * Системный таймер `vps-ip-guard-update.timer` (каждые 24 часа).
   * Запись в планировщике `/etc/cron.d/vps-maintenance` (ежедневно в 04:15).

#### Управление IP Guard из консоли:
```bash
ip-guard status         # Полная диагностика, статистика источников и правила
ip-guard update         # Атомарное обновление баз из сети
ip-guard reload         # Восстановление правил из локального кэша (офлайн)
ip-guard ban 1.2.3.4    # Добавить IP или подсеть в ручной blacklist
ip-guard unban 1.2.3.4  # Разблокировать IP или подсеть
ip-guard list           # Просмотр ручного чёрного списка
```

---

### 3. Прокси NaïveProxy & Caddy (`naiveproxy-manager.sh` и `modules/`)

Современное решение для безопасного обхода сетевых ограничений и блокировок DPI:
* **Сетевой стек Chromium:** трафик NaïveProxy маскируется под обычный защищённый HTTP/2 или HTTP/3 трафик браузера Google Chrome.
* **Модульная структура (`modules/`):**
  * `modules/caddy.sh`: автоматическая сборка веб-сервера Caddy со встроенным плагином `forwardproxy`.
  * `modules/naiveproxy.sh`: генерация защищённого файла `Caddyfile`, создание пользователей (`basic_auth`) и экспорт клиентских ссылок.
  * `modules/nginx.sh`: связка с веб-сервером Nginx на порту 80 для камуфлирования.
  * `modules/webui.sh`: локальная веб-панель для просмотра параметров и QR-кодов.

---

### 4. Камуфляжные сайты Nginx (`nginx-templates.sh`, `nginx/templates/`)

Защита от активного зондирования: цензоры проверяют, какой контент отдаёт сервер при обращении по IP-адресу или домену в браузере.

Менеджер `nginx-templates.sh` позволяет в 1 клик развернуть маскировочный сайт на порт 80 (и обратный прокси для неавторизованных запросов на 443):
* **Speedtest:** страница HTML5-замера скорости сети.
* **Games Site:** портал с работающими браузерными мини-играми.
* **Converter / Convertit:** сервисы конвертации единиц измерения и файлов.
* **Filecloud / Downloader:** камуфляж под облачное хранилище данных.
* **YouTube endless captcha:** страница имитации капчи в стиле YouTube.

---

### 5. Сервисные утилиты

* **`setup.sh`:** первоначальный развертыватель с интерактивным восстановлением зашифрованных баз SQLite (Латвия, Москва, Турция или пользовательский файл из `databases/`).
* **`export-xui-db.sh`:** создание зашифрованных AES-256-CBC архивов баз SQLite для панелей 3X-UI / X-UI с автоматической проверкой целостности.
* **`lers-manager.sh`:** специализированный инструмент для управления компонентами LERS, доменными записями и SSL-сертификатами.
* **`install.sh`:** единая панель управления сервером с информативным дашбордом состояния системы и служб.

---

## 📱 Настройка клиентов NaïveProxy

Формат строки подключения, генерируемой скриптом:
```text
naive+https://USERNAME:PASSWORD@YOUR_DOMAIN:443
```

* **v2rayN (Windows):** меню *Серверы* → *Импортировать ссылку* или ручное создание сервера типа *NaïveProxy* с указанием пути к `naive.exe`.
* **Nekoray / Matsuri (Windows, Android):** добавление профиля типа *Naïve*, указание домена, порта 443 и учётных данных.
* **Sing-box / Clash Meta (Mihomo):** стандартный outbound-блок типа `naive` с указанием сервера, порта 443 и реквизитов авторизации.

---

## 🔍 Диагностика и команды проверки

### Проверка безопасности и IP Guard:
```bash
# Проверка статуса службы и правил фильтрации
ip-guard status

# Проверка загруженных в ядро сетей ipset
ipset list VPS-IP-GUARD-V4 -terse

# Проверка цепочки iptables
iptables -L VPS-IP-GUARD -n -v

# Проверка таймера автообновления
systemctl list-timers vps-ip-guard-update.timer --no-pager
```

### Проверка прокси и веб-серверов:
```bash
# Проверка службы Caddy (NaïveProxy)
systemctl status caddy --no-pager
journalctl -u caddy -n 50 --no-pager

# Проверка веб-сервера Nginx
systemctl status nginx --no-pager
tail -n 50 /var/log/nginx/error.log

# Проверка открытых портов (LISTEN)
ss -tulpn | grep -E ':(80|443|1241|40000)'
```

---

## 📄 Лицензия

Проект распространяется под лицензией [MIT](LICENSE).
