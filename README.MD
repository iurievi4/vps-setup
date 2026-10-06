# VPS Setup & Manager (`vps-manager.sh`) 🚀

[![OS: Ubuntu & Debian](https://img.shields.io/badge/OS-Ubuntu%20%7C%20Debian-E95420?logo=linux&logoColor=white)](https://github.com/iurievi4/vps-setup)
[![Shell: Bash](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnu-bash&logoColor=white)](https://github.com/iurievi4/vps-setup)
[![Security: UFW + Fail2ban](https://img.shields.io/badge/Security-UFW%20%2B%20Fail2ban-blue)](https://github.com/iurievi4/vps-setup)
[![Proxy: NaïveProxy + Caddy](https://img.shields.io/badge/Proxy-NaïveProxy%20%2B%20Caddy-00ADD8?logo=caddy&logoColor=white)](https://github.com/klzgrad/naiveproxy)
[![Web: Nginx Camouflage](https://img.shields.io/badge/Web-Nginx%20Decoy%20Templates-009639?logo=nginx&logoColor=white)](https://github.com/iurievi4/vps-setup)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Единый модульный инструментарий для комплексного администрирования Linux VPS: **первичная инициализация системы**, **усиление безопасности (hardening)**, **развертывание высокоскоростного прокси NaïveProxy**, **подключение маскировочных сайтов Nginx** и **резервное копирование**.

Центральной точкой входа и главным оркестратором проекта является интерактивное меню **`vps-manager.sh`** (дублируется через `setup.sh`).

---

## 📌 Оглавление
- [Архитектура и дерево путей `vps-manager.sh`](#-архитектура-и-дерево-путей-vps-managersh)
- [Быстрый старт](#-быстрый-старт)
- [Системные требования](#-системные-требования)
- [Модули и компоненты системы](#-модули-и-компоненты-системы)
  - [1. Базовая настройка VPS (`setup.sh`, `vps.sh`, `vps-lite.sh`)](#1-базовая-настройка-vps-setupsh-vpssh-vps-litesh)
  - [2. Безопасность и SSH (`vps-security-installer.sh`, `ssh-key-manager.sh`)](#2-безопасность-и-ssh-vps-security-installersh-ssh-key-managersh)
  - [3. Прокси NaïveProxy (`naiveproxy-manager.sh` и `modules/`)](#3-прокси-naïveproxy-naiveproxy-managersh-и-modules)
  - [4. Камуфляжные сайты Nginx (`nginx-templates.sh`, `nginx/templates/`)](#4-камуфляжные-сайты-nginx-nginx-templatessh-nginxtemplates)
  - [5. Сервисные утилиты (`export-xui-db.sh`, `lers-manager.sh`)](#5-сервисные-утилиты-export-xui-dbsh-lers-managersh)
- [Настройка клиентов NaïveProxy](#-настройка-клиентов-naïveproxy)
- [Диагностика и устранение неполадок](#-диагностика-и-устранение-неполадок)
- [Лицензия](#-лицензия)

---

## 🌳 Архитектура и дерево путей `vps-manager.sh`

Скрипт **`vps-manager.sh`** объединяет разрозненные задачи системного администрирования в единое древовидное меню:

```text
vps-manager.sh (ГЛАВНЫЙ ОРКЕСТРАТОР / ДИСПЕТЧЕР)
│
├── 1. БАЗОВАЯ НАСТРОЙКА СЕРВЕРА
│   ├── setup.sh / vps.sh           # Полная интерактивная конфигурация VPS
│   └── vps-lite.sh                 # Облегченная быстрая настройка (минимальный набор)
│       ├── Обновление системы: apt update && apt upgrade
│       ├── Системное окружение: Hostname, часовой пояс (Timezone)
│       ├── Управление памятью: генерация файла подкачки (Swap 1G / 2G / 4G)
│       ├── Сетевой стек: оптимизация ядра и включение TCP BBR
│       ├── Базовые утилиты: curl, wget, htop, iftop, net-tools, git, ufw
│       └── Контейнеризация: автоматическая установка Docker и Docker Compose
│
├── 2. БЕЗОПАСНОСТЬ И КОНТРОЛЬ ДОСТУПА (HARDENING)
│   ├── vps-security-installer.sh   # Межсетевой экран UFW, Fail2ban, защита SSH
│   │   ├── Брандмауэр UFW: блокировка всех портов, открытие только SSH, 80, 443
│   │   ├── Защита от брутфорса: Fail2ban (настройка jails для SSH)
│   │   └── SSH Hardening: смена стандартного порта 22, запрет входа root по паролю
│   └── ssh-key-manager.sh          # Управление открытыми ключами SSH
│       ├── Импорт и валидация публичных ключей (Ed25519 / RSA)
│       ├── Настройка прав доступа на ~/.ssh и authorized_keys
│       └── Отключение PasswordAuthentication после проверки ключа
│
├── 3. СЕРВЕР ПРОКСИ (NAÏVEPROXY & CADDY)
│   ├── naiveproxy-manager.sh       # Модульный оркестратор NaïveProxy (v1.0.0-MODULAR)
│   │   ├── modules/common.sh       # Валидация ОС (Debian/Ubuntu), портов (80/443), логи
│   │   ├── modules/caddy.sh        # Сборка/установка бинарника Caddy с forwardproxy
│   │   ├── modules/naiveproxy.sh   # Генерация Caddyfile, учетных записей и ссылок
│   │   ├── modules/nginx.sh        # Связка Nginx на порту 80 с Caddy на порту 443
│   │   ├── modules/webui.sh        # Развертывание локальной Web UI панели управления
│   │   └── modules/maintenance.sh  # Логи (journalctl), проверка статуса, перезапуск служб
│   └── naiveproxy-install.sh       # Автономный монолитный установщик (Legacy v2.9-STABLE)
│
├── 4. САЙТЫ-ЗАГЛУШКИ И МАСКИРОВКА (NGINX CAMOUFLAGE)
│   ├── nginx-templates.sh          # Мастер выбора и установки маскировочных веб-сайтов
│   └── nginx/templates/            # Локальная библиотека готовых веб-шаблонов:
│       ├── speedtest/              # Тестирование скорости интернета (HTML5 Speedtest)
│       ├── games-site/             # Портал браузерных мини-игр
│       ├── converter/              # Онлайн-конвертер единиц и данных
│       ├── convertit/              # Инструмент веб-конвертации файлов
│       ├── filecloud/              # Интерфейс облачного хранилища данных
│       ├── downloader/             # Страница сервиса загрузки файлов
│       ├── modmanager/             # Каталог и менеджер игровых модификаций
│       ├── 10gag/                  # Развлекательный медиа-портал
│       ├── YouTube endless captcha/# Страница проверки капчи в стиле YouTube
│       └── 503 error pages/        # Страницы регламентных технических работ
│
└── 5. РЕЗЕРВНОЕ КОПИРОВАНИЕ И ДОПОЛНИТЕЛЬНЫЕ СЕРВИСЫ
    ├── export-xui-db.sh            # Создание архива базы данных SQLite для панелей 3X-UI / X-UI
    ├── lers-manager.sh             # Инструмент администрирования LERS и доменных имен
    └── install.sh                  # Вспомогательный инсталлятор и загрузчик скриптов
```

---

## 🚀 Быстрый старт

### Шаг 1. Клонирование репозитория

Подключитесь к вашему VPS по SSH с правами `root` и выполните:

```bash
# Обновляем список пакетов и устанавливаем git
apt update && apt install -y git curl

# Клонируем проект в рабочую директорию
git clone https://github.com/iurievi4/vps-setup.git /root/vps-setup
cd /root/vps-setup

# Выдаем права на исполнение всем скриптам и модулям
chmod +x *.sh modules/*.sh
```

### Шаг 2. Запуск диспетчера

Запустите главное меню управления:

```bash
bash vps-manager.sh
# или через синоним:
bash setup.sh
```

В появившемся интерактивном интерфейсе выберите нужный пункт: от начальной конфигурации сервера до установки NaïveProxy и настройки брандмауэра.

---

## 💻 Системные требования

| Компонент | Требование |
| :--- | :--- |
| **Поддерживаемые ОС** | Ubuntu 20.04, 22.04, 24.04 LTS / Debian 11, 12 |
| **Учетная запись** | `root` или пользователь с полными правами `sudo` |
| **Аппаратные ресурсы** | От 512 МБ RAM (рекомендуется 1 ГБ+ при установке Docker), 5+ ГБ диска |
| **Сетевые порты** | `22/tcp` (или кастомный SSH), `80/tcp` (HTTP/ACME), `443/tcp` (HTTPS/NaïveProxy) |
| **Доменное имя** | Для выпуска TLS-сертификата требуется домен с A-записью, направленной на IP сервера (режим Cloudflare: **DNS Only**) |

---

## 🛠 Модули и компоненты системы

### 1. Базовая настройка VPS (`setup.sh`, `vps.sh`, `vps-lite.sh`)

Служит фундаментом перед развертыванием сервисов:
- **Обновление и утилиты**: ставит свежие версии системных пакетов и незаменимые инструменты администратора (`htop`, `iftop`, `iotop`, `net-tools`, `curl`, `wget`).
- **Файл подкачки (Swap)**: создает swap-файл нужного размера (1–4 ГБ), предотвращая аварийное завершение процессов из-за OOM (Out Of Memory).
- **Сетевой тюнинг (TCP BBR)**: активирует современный алгоритм контроля перегрузки BBR в ядре Linux, увеличивая реальную скорость соединения и снижая потерю пакетов.
- **Docker**: развертывает официальный Docker Engine и плагин Docker Compose для запуска контейнеризированных приложений.

### 2. Безопасность и SSH (`vps-security-installer.sh`, `ssh-key-manager.sh`)

Формирует защиту периметра сервера от автоматических атак:
- **`vps-security-installer.sh`**:
  - Активирует фаервол **UFW** по модели "запрещено все, что не разрешено явно".
  - Устанавливает и настраивает **Fail2ban** с автоматической блокировкой атакующих IP-адресов.
  - Предлагает изменить стандартный порт SSH (например, на 2222 или любой свободный порт).
- **`ssh-key-manager.sh`**:
  - Интерактивно добавляет публичный ключ клиента в `~/.ssh/authorized_keys`.
  - После подтверждения успешного входа отключает парольную аутентификацию (`PasswordAuthentication no`) и доступ по паролю для пользователя `root`.

### 3. Прокси NaïveProxy (`naiveproxy-manager.sh` и `modules/`)

Современное решение для безопасного обхода сетевых ограничений и блокировок DPI:
- **Сетевой стек Chromium**: трафик NaïveProxy неотличим от обычного серфинга в Google Chrome.
- **Модульная структура (`modules/`)**:
  - `modules/common.sh`: проверка корректности ОС, портов и системных утилит.
  - `modules/caddy.sh`: загрузка/сборка веб-сервера Caddy со встроенным плагином `forwardproxy`.
  - `modules/naiveproxy.sh`: автоматическая генерация конфигурации `Caddyfile`, поддержка аутентификации пользователей (`basic_auth`), создание клиентских ссылок.
  - `modules/nginx.sh`: связка с Nginx на 80 порту для создания идеального камуфляжа.
  - `modules/webui.sh`: удобная панель управления для просмотра параметров и QR-кодов.
  - `modules/maintenance.sh`: быстрый просмотр логов Caddy, перезапуск и проверка здоровья сервисов.

### 4. Камуфляжные сайты Nginx (`nginx-templates.sh`, `nginx/templates/`)

Активное зондирование со стороны цензоров проверяет, что находится на сервере при открытии его IP или домена в браузере:
- Менеджер `nginx-templates.sh` позволяет в 1 клик установить реалистичный сайт на порт 80 (и обратный прокси для неавторизованных запросов на 443):
  - **Speedtest**: страница замера скорости сети.
  - **Games Site**: портал с работающими мини-играми.
  - **Converter / Convertit**: утилиты онлайн-конвертации.
  - **Filecloud / Downloader**: камуфляж под облачные сервисы.
  - **YouTube endless captcha**: страница имитации проверки браузера.

### 5. Сервисные утилиты (`export-xui-db.sh`, `lers-manager.sh`)

- **`export-xui-db.sh`**: поиск и безопасное резервное копирование рабочей базы данных `/etc/x-ui/x-ui.db` с формированием архива с временным штампом для удобной загрузки на локальную машину.
- **`lers-manager.sh`**: специализированное меню для администрирования доменных записей, сертификатов и компонентов сервиса LERS.

---

## 📱 Настройка клиентов NaïveProxy

Формат строки подключения, генерируемой скриптом:
```text
naive+https://USERNAME:PASSWORD@YOUR_DOMAIN:443
```

- **v2rayN (Windows)**: меню *Серверы* -> *Импортировать ссылку* или ручное создание сервера типа NaïveProxy с указанием пути к `naive.exe`.
- **Nekoray / Matsuri (Windows, Android)**: добавление профиля типа **Naïve**, указание домена, порта 443 и учетных данных.
- **Sing-box / Clash Meta (Mihomo)**: поддержка стандартного outbound-блока типа `"naive"` с указанием `server`, `server_port: 443`, `username`, `password`.

---

## 🔍 Диагностика и устранение неполадок

```bash
# Проверка работы Caddy (NaïveProxy)
systemctl status caddy
journalctl -u caddy -n 50 --no-pager

# Проверка работы веб-сервера Nginx
systemctl status nginx
tail -n 50 /var/log/nginx/error.log

# Проверка состояния фаервола
ufw status verbose

# Проверка занятости сетевых портов
ss -tulpn | grep -E ':(80|443)'
```

---

## 📄 Лицензия

Проект распространяется под лицензией [MIT](LICENSE).