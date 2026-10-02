# 🚀 VPS Setup & Security Management Toolkit

Комплекс Bash-инструментов для автоматической установки, настройки, защиты и администрирования VPS на **Debian 11/12** и **Ubuntu 20.04/22.04/24.04**.

Проект построен модульно: всеми компонентами можно управлять через единый `install.sh` или запускать каждый скрипт отдельно.

---

## 📑 Содержание

* [Быстрый старт](#-быстрый-старт)
* [Структура проекта](#-структура-проекта)
* [Компоненты](#️-компоненты)
* [Nginx и сайты по IP](#-nginx-и-сайты-по-ip)
* [SSH и ключи](#-ssh-и-ключи)
* [Сетевая безопасность](#️-сетевая-безопасность)
* [Бэкапы и восстановление](#-бэкапы-и-восстановление)
* [Безопасная установка](#-безопасная-установка)
* [Лицензия](#-лицензия)

---

# ⚡ Быстрый старт

Главная точка входа — **`install.sh`**.

Он показывает единое меню и при необходимости загружает актуальные версии остальных скриптов непосредственно из GitHub.

### Запуск

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/iurievi4/vps-setup/main/install.sh)"
```

Или сначала скачать файл:

```bash
curl -fsSL https://raw.githubusercontent.com/iurievi4/vps-setup/main/install.sh \
  -o /root/install.sh

chmod +x /root/install.sh
/root/install.sh
```

### Меню

```text
╔══════════════════════════════════════════════════════════╗
║                      VPS INSTALLER                       ║
╚══════════════════════════════════════════════════════════╝

  [●] Состояние: СЕРВЕР УЖЕ НАСТРОЕН
  [●] База 3x-ui: ОБНАРУЖЕНА

  1) Полная автоматическая установка
  2) Ручной запуск setup.sh
  3) Установка безопасности
  4) Управление SSH-ключами
  5) Шаблоны сайтов и прокси
  6) Сбросить маркер настройки
  0) Выход
```

### CLI-режим

Все основные операции можно запускать без интерактивного меню:

```bash
bash /root/install.sh 1   # Полная автоматическая установка
bash /root/install.sh 2   # Ручной запуск setup.sh
bash /root/install.sh 3   # Security Installer
bash /root/install.sh 4   # SSH Key Manager
bash /root/install.sh 5   # Nginx Manager
bash /root/install.sh 6   # Сброс маркера
```

Поддерживаются также алиасы:

```bash
bash /root/install.sh ssh
bash /root/install.sh ssh-manager

bash /root/install.sh nginx
bash /root/install.sh templates

bash /root/install.sh reset
```

---

# 📁 Структура проекта

```text
vps-setup/
│
├── install.sh
├── setup.sh
├── nginx-templates.sh
├── ssh-key-manager.sh
├── vps-security-installer.sh
│
├── nginx/
│   └── templates/
│       ├── filecloud/
│       ├── downloader/
│       ├── converter/
│       ├── games-site/
│       ├── 10gag/
│       ├── modmanager/
│       ├── speedtest/
│       ├── convertit/
│       ├── 503 error pages/
│       └── YouTube endless captcha/
│
└── README.md
```

---

# 🛠️ Компоненты

| Файл                        | Назначение                                                      |
| --------------------------- | --------------------------------------------------------------- |
| `install.sh`                | Центральный диспетчер проекта                                   |
| `setup.sh`                  | Первичная настройка VPS и системного окружения                  |
| `nginx-templates.sh`        | Nginx, HTML-шаблоны, Reverse Proxy, SSL и Security Headers      |
| `ssh-key-manager.sh`        | SSH-ключи, `authorized_keys`, парольная аутентификация и backup |
| `vps-security-installer.sh` | Fail2ban, AntiScanner, WARP и системный MOTD                    |
| `nginx/templates/`          | Исходники готовых HTML5-шаблонов                                |

---

# 1. `install.sh` — главный диспетчер

`install.sh` объединяет остальные компоненты проекта в одном меню.

### Режим 1 — полная автоматическая установка

Запускает `setup.sh` в автоматическом режиме.

Используемые параметры:

* 3x-ui — включён
* Cloudflare WARP — включён
* PostgreSQL — отключён
* MS SQL Server — отключён
* TorrServer — отключён

Перед запуском проверяется наличие:

```text
/etc/x-ui/x-ui.db
```

Если база существует, создаётся резервная копия:

```text
/root/xui_backups/x-ui-before-setup-<дата>.db
```

При повторном запуске автоматически используется:

```text
FORCE_BOOTSTRAP=1
```

что позволяет повторно запускать `setup.sh` на уже настроенном сервере.

### Режим 2 — ручной `setup.sh`

Запускает `setup.sh` в интерактивном режиме.

### Режим 3 — Security Installer

Запускает:

```text
vps-security-installer.sh
```

### Режим 4 — SSH Manager

Запускает:

```text
ssh-key-manager.sh
```

### Режим 5 — Nginx Manager

Запускает:

```text
nginx-templates.sh
```

### Режим 6 — сброс маркера

Удаляет:

```text
/etc/vps-bootstrap-complete
```

Маркер используется для определения состояния первоначальной настройки VPS.

---

# 2. `setup.sh` — базовая настройка VPS

Основной скрипт подготовки системы.

### Устанавливает

* Nginx
* Git
* curl
* cron
* iproute2
* iputils-ping
* lm-sensors
* nvme-cli
* iptables
* iptables-persistent
* UFW
* socat
* SQLite3

### Настраивает

* TCP BBR
* TCP Fast Open
* системные параметры `sysctl`
* Swap
* `vm.swappiness`
* базовую структуру Nginx
* cron
* MOTD
* SSH
* firewall

Также создаётся базовая Nginx-заглушка `cloud-node`.

---

# 3. `nginx-templates.sh` — Nginx Manager

Интерактивный менеджер сайтов, шаблонов и Reverse Proxy.

## Возможности

```text
🌐 САЙТЫ

1)  Файловый архив
2)  Медиаархив
3)  Новостной портал
4)  Техническая документация
5)  Корпоративный сайт
6)  Нейтральная заглушка

🎨 HTML-ШАБЛОНЫ

7)  Cloud Storage
8)  Download Manager
9)  File Converter
10) Games Site
11) Memes Site
12) Mod Manager
13) Speed Test
14) Video Converter
15) 503 Error Pages
16) YouTube Captcha

🔄 ПРОКСИ

17) Reverse Proxy
18) Reverse Proxy + WebSocket
19) Управление / удаление Proxy

🔐 SSL И БЕЗОПАСНОСТЬ

20) ACME / Let's Encrypt
21) Security Headers

📋 УПРАВЛЕНИЕ

22) Текущая конфигурация
23) Создать backup
24) Восстановить backup
```

---

# 🌐 Nginx и сайты по IP

Менеджер рассчитан в том числе на VPS, у которого **есть только IP-адрес и нет домена**.

Для обычного HTML-сайта домен не требуется.

Активный сайт работает как:

```nginx
listen 80 default_server;
listen [::]:80 default_server;
server_name _;
```

Поэтому сайт открывается напрямую:

```text
http://SERVER_IP
```

Например:

```text
http://94.xxx.xxx.xxx
```

## Переключение шаблонов

На порту `80` используется один активный HTML-сайт.

При выборе нового шаблона:

```text
Games Site
     ↓
Speed Test
     ↓
Cloud Storage
```

предыдущий сайт отключается, а выбранный становится новым `default_server`.

Файл предыдущей конфигурации при этом сохраняется в:

```text
/etc/nginx/sites-available/
```

## Proxy изолирован

Reverse Proxy и WebSocket-конфигурации хранятся отдельно и не должны удаляться при смене HTML-шаблона.

Типовая структура:

```text
/etc/nginx/sites-enabled/
├── active-site.conf
├── proxy-*.conf
└── ...
```

Перед применением изменений выполняется:

```bash
nginx -t
```

и только после успешной проверки выполняется reload.

---

# 🎨 HTML-шаблоны

Шаблоны находятся в:

```text
nginx/templates/
```

| Меню | Каталог                   | Назначение            |
| ---: | ------------------------- | --------------------- |
|    7 | `filecloud`               | Cloud Storage         |
|    8 | `downloader`              | Download Manager      |
|    9 | `converter`               | File Converter        |
|   10 | `games-site`              | Games Site            |
|   11 | `10gag`                   | Memes Site            |
|   12 | `modmanager`              | Mod Manager           |
|   13 | `speedtest`               | Speed Test            |
|   14 | `convertit`               | Video Converter       |
|   15 | `503 error pages`         | 503 Error Pages       |
|   16 | `YouTube endless captcha` | YouTube-style Captcha |

Шаблоны автоматически копируются в соответствующие каталоги `/var/www/`.

---

# 🔄 Reverse Proxy

Менеджер поддерживает стандартный HTTP Reverse Proxy:

```text
Client
   │
   ▼
 Nginx
   │
   ▼
Backend
127.0.0.1:PORT
```

Также предусмотрен отдельный режим:

```text
Reverse Proxy + WebSocket
```

для сервисов, использующих WebSocket, включая:

* 3x-ui
* Xray
* VLESS

---

# 🔐 ACME / Let's Encrypt

Для получения сертификатов используется ACME / Let's Encrypt.

HTML-сайт может работать по IP без SSL-сертификата.

Для стандартного сертификата Let's Encrypt используется домен, направленный на VPS.

Пример:

```text
example.com
     │
     ▼
VPS IP
     │
     ▼
Nginx
     │
     ▼
Let's Encrypt
```

Для ACME challenge используется:

```text
/.well-known/acme-challenge/
```

---

# 🛡️ Security Headers

Nginx Manager поддерживает добавление HTTP Security Headers, включая:

* `Strict-Transport-Security`
* `Content-Security-Policy`
* `X-Frame-Options`
* `X-Content-Type-Options`
* `Referrer-Policy`
* `Permissions-Policy`

Набор заголовков должен соответствовать конкретному сайту и его функциональности.

---

# 4. `ssh-key-manager.sh` — SSH Manager

Интерактивное управление SSH-ключами и безопасностью SSH.

## Возможности

```text
1) Установить SSH-ключ
2) Показать установленные ключи
3) Удалить SSH-ключ

4) Отключить вход по паролю
5) Включить вход по паролю

6) Создать backup authorized_keys & sshd
7) Восстановить authorized_keys
8) Проверить sshd -t
9) Показать SSH-порт и статус службы
```

### Источники SSH-ключа

Поддерживаются:

* приватный GitHub-репозиторий
* ручной ввод public key
* локальный файл
* генерация новой пары Ed25519

В `authorized_keys` устанавливается только **публичный ключ**.

---

# 🔐 Безопасная настройка SSH

Рекомендуемый порядок:

```text
1. Установить SSH public key
        ↓
2. Проверить вход новым ключом
        ↓
3. Создать backup
        ↓
4. Проверить sshd -t
        ↓
5. Отключить PasswordAuthentication
        ↓
6. Повторно проверить sshd -t
        ↓
7. Выполнить reload SSH
```

Не закрывайте текущую SSH-сессию, пока новый способ входа не проверен.

### Важно

**Приватный SSH-ключ никогда не должен загружаться в GitHub.**

В репозитории должен находиться только public key:

```text
id_ed25519.pub
```

---

# 5. `vps-security-installer.sh`

Модуль дополнительной защиты VPS.

## Fail2ban

Настраивается SSH jail и защита от повторных попыток входа.

Конфигурация проекта:

```text
/etc/fail2ban/jail.d/vps-setup.local
```

Проверка:

```bash
systemctl status fail2ban --no-pager
```

```bash
fail2ban-client status
```

---

## AntiScanner

Модуль блокировки известных сетевых сканеров и нежелательной автоматизированной активности.

Используется `ipset`.

Основной набор:

```text
SCANNERS-BLOCK-V4
```

Проверка:

```bash
systemctl status antiscan --no-pager
```

---

## Cloudflare WARP

В конфигурации проекта WARP может использоваться как локальный outbound SOCKS5-прокси.

Порт:

```text
127.0.0.1:40000
```

---

# 🛡️ Сетевая безопасность

Базовая конфигурация использует нестандартный SSH-порт:

```text
1241/TCP
```

Типовые порты:

|    Порт | Протокол | Назначение            |
| ------: | -------- | --------------------- |
|  `1241` | TCP      | SSH                   |
|    `80` | TCP      | HTTP / Nginx          |
|   `443` | TCP      | HTTPS / Proxy         |
| `40000` | TCP      | Локальный WARP SOCKS5 |

Проверка UFW:

```bash
ufw status verbose
```

Проверка открытых портов:

```bash
ss -lntup
```

---

# 💾 Бэкапы и восстановление

Проект предусматривает резервное копирование нескольких компонентов.

## База 3x-ui

При запуске `install.sh` существующая база может быть сохранена в:

```text
/root/xui_backups/
```

Пример:

```text
x-ui-before-setup-20261003-120000.db
```

---

## Nginx

Backup конфигурации:

```text
/etc/nginx/backups/
```

и:

```text
/root/nginx-backups/
```

В `nginx-templates.sh` предусмотрено восстановление через меню:

```text
24) Восстановить backup
```

---

## SSH

Резервные копии:

```text
/root/.ssh/backups/
```

и:

```text
/etc/ssh/backups/
```

Восстановление выполняется через `ssh-key-manager.sh`.

---

# 🔍 Проверка конфигурации

Перед применением изменений рекомендуется проверять:

### Nginx

```bash
nginx -t
```

### SSH

```bash
sshd -t
```

### Firewall

```bash
ufw status verbose
```

### Слушающие порты

```bash
ss -lntup
```

---

# ⚠️ Безопасность

Перед запуском любого скрипта от `root` рекомендуется ознакомиться с его содержимым.

Для безопасной проверки можно сначала скачать файл:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/iurievi4/vps-setup/main/install.sh \
  -o /root/install.sh
```

Просмотреть:

```bash
less /root/install.sh
```

И только после проверки запустить:

```bash
bash /root/install.sh
```

Не передавайте приватные SSH-ключи, пароли и токены в публичные репозитории.

---

# 📦 Прямой запуск компонентов

Каждый модуль можно запускать отдельно.

### Основная установка

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/iurievi4/vps-setup/main/setup.sh)"
```

### Nginx Manager

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/iurievi4/vps-setup/main/nginx-templates.sh)"
```

### SSH Manager

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/iurievi4/vps-setup/main/ssh-key-manager.sh)"
```

### Security Installer

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/iurievi4/vps-setup/main/vps-security-installer.sh)"
```

---

# 🧩 Пример последовательной настройки VPS

Типовой сценарий:

```text
install.sh
    │
    ├── 1. Полная установка
    │       │
    │       └── setup.sh
    │
    ├── 3. Security Installer
    │       ├── Fail2ban
    │       ├── AntiScanner
    │       └── WARP
    │
    ├── 4. SSH Manager
    │       └── SSH key / PasswordAuthentication
    │
    └── 5. Nginx Manager
            ├── HTML template
            ├── Reverse Proxy
            ├── WebSocket
            ├── SSL
            └── Security Headers
```

---

# 📌 Требования

* Debian 11 / 12
* Ubuntu 20.04 / 22.04 / 24.04
* root-доступ
* рабочее интернет-соединение
* `curl`
  *(при необходимости `install.sh` устанавливает его автоматически)*

---

# 📄 Лицензия

Проект распространяется под лицензией **MIT**.

Используйте, изменяйте и адаптируйте скрипты под собственную инфраструктуру.

---

## 🔗 Репозиторий

**GitHub:**
https://github.com/iurievi4/vps-setup
