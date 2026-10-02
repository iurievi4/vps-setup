# 🚀 VPS Setup & Security Management Toolkit

Комплексный набор Bash-скриптов для автоматического развёртывания, защиты и администрирования VPS на базе Debian/Ubuntu.

Проект построен по модульному принципу: все основные компоненты можно запускать через единый `install.sh` или использовать независимо.

## Возможности

* ⚙️ автоматическая установка и настройка VPS;
* 🖥️ установка и управление 3x-ui;
* 🛡️ Fail2ban;
* 🚫 AntiScanner;
* 🧦 Cloudflare WARP;
* 🔑 управление SSH-ключами;
* 🔥 UFW;
* 🌐 Nginx;
* 🎨 готовые HTML-шаблоны сайтов;
* 🔄 Reverse Proxy;
* 🔌 Reverse Proxy + WebSocket;
* 🔐 ACME / Let's Encrypt;
* 🛡️ Security Headers;
* 💾 автоматические резервные копии;
* 📊 расширенный MOTD;
* 🔧 системная диагностика и полезные команды.

---

# 📦 Структура проекта

```text
vps-setup/
│
├── install.sh
│
├── setup.sh
│
├── vps-security-installer.sh
│
├── ssh-key-manager.sh
│
├── nginx-templates.sh
│
├── nginx/
│   └── templates/
│       ├── 10gag/
│       ├── 503 error pages/
│       ├── YouTube endless captcha/
│       ├── converter/
│       ├── convertit/
│       ├── downloader/
│       ├── filecloud/
│       ├── games-site/
│       ├── modmanager/
│       └── speedtest/
│
└── README.md
```

---

# ⚡ Быстрый старт

Запуск главного установщика:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/iurievi4/vps-setup/main/install.sh)"
```

После запуска откроется меню:

```text
╔══════════════════════════════════════════════════════════╗
║                      VPS INSTALLER                       ║
╚══════════════════════════════════════════════════════════╝

  1) Полная автоматическая установка
  2) Ручной запуск setup.sh
  3) Установка безопасности
  4) Управление SSH-ключами
  5) Шаблоны сайтов и прокси
  6) Сброс маркера настройки
  0) Выход
```

Также можно сразу передать номер режима:

```bash
bash install.sh 1
```

или:

```bash
bash install.sh 3
```

---

# 🧩 Центральный установщик install.sh

`install.sh` является единым диспетчером проекта.

Он:

* проверяет запуск от `root`;
* при необходимости устанавливает `curl` и `ca-certificates`;
* загружает актуальные скрипты из GitHub;
* проверяет загруженные файлы;
* использует временный каталог;
* удаляет временные файлы после завершения;
* определяет наличие уже настроенного VPS;
* обнаруживает существующую базу 3x-ui;
* перед повторной установкой создаёт страховочную копию базы.

## Режимы

### 1. Полная автоматическая установка

```bash
bash install.sh 1
```

Использует:

```text
setup.sh
```

В автоматическом режиме:

```text
PostgreSQL       : НЕТ
MS SQL Server    : НЕТ
TorrServer       : НЕТ
Cloudflare WARP  : ДА
3x-ui            : ДА
```

При наличии существующей базы 3x-ui она предварительно копируется в:

```text
/root/xui_backups/
```

---

### 2. Ручной запуск setup.sh

```bash
bash install.sh 2
```

В этом режиме `setup.sh` запускается интерактивно.

---

### 3. Установка безопасности

```bash
bash install.sh 3
```

Запускается:

```text
vps-security-installer.sh
```

Компоненты:

* Fail2ban;
* AntiScanner;
* Cloudflare WARP;
* системный MOTD.

---

### 4. SSH Manager

```bash
bash install.sh 4
```

Также доступны:

```bash
bash install.sh ssh
```

```bash
bash install.sh ssh-manager
```

Запускается:

```text
ssh-key-manager.sh
```

---

### 5. Nginx Manager

```bash
bash install.sh 5
```

Также:

```bash
bash install.sh nginx
```

```bash
bash install.sh templates
```

Запускается:

```text
nginx-templates.sh
```

---

### 6. Сброс маркера

```bash
bash install.sh 6
```

Также:

```bash
bash install.sh reset
```

Удаляется:

```text
/etc/vps-bootstrap-complete
```

Само удаление маркера **не удаляет установленные программы и конфигурацию**. Оно только возвращает состояние маркера в первоначальное.

---

# 🖥️ setup.sh

Основной скрипт настройки VPS.

Предназначен для первоначального развёртывания и повторного запуска на уже настроенном сервере.

Перед повторной установкой существующая база:

```text
/etc/x-ui/x-ui.db
```

сохраняется в резервную копию.

---

# 🛡️ vps-security-installer.sh

Отдельный установщик компонентов безопасности.

## Fail2ban

Настраивается защита SSH.

Конфигурация:

```text
/etc/fail2ban/
```

Проверка:

```bash
fail2ban-client status
```

---

## 🚫 AntiScanner

AntiScanner использует `ipset` для блокировки адресов из базы сканеров.

Основные компоненты:

```text
SCANNERS-BLOCK-V4
antiscan.service
antiscan.timer
```

Проверка:

```bash
systemctl status antiscan --no-pager
```

---

## 🧦 Cloudflare WARP

Локальный SOCKS5:

```text
127.0.0.1:40000
```

Он используется локальными сервисами для маршрутизации исходящего трафика.

Проверка:

```bash
curl --socks5 127.0.0.1:40000 https://api.ipify.org
```

---

# 🔑 SSH Key Manager

`ssh-key-manager.sh` предназначен для управления доступом по SSH-ключам.

## Возможности

```text
1) Install SSH key
2) Show keys
3) Delete key
4) Disable password login
5) Enable password login
6) Backup authorized_keys & sshd
7) Restore authorized_keys
8) Check sshd -t
9) Show SSH port/service
0) Exit
```

### Источники SSH-ключа

Можно использовать:

* существующий публичный ключ;
* GitHub;
* файл;
* новый Ed25519-ключ.

Приватный ключ не должен загружаться в GitHub.

На сервер устанавливается только публичная часть:

```text
*.pub
```

---

## 🔐 Отключение входа по паролю

Перед отключением рекомендуется:

1. установить SSH-ключ;
2. проверить вход через вторую SSH-сессию;
3. создать резервную копию;
4. проверить `sshd -t`;
5. только после этого отключать пароль.

Проверка конфигурации:

```bash
sshd -t
```

---

# 🌐 Nginx Manager

`nginx-templates.sh` предназначен для управления сайтами и Reverse Proxy.

Запуск:

```bash
bash install.sh 5
```

## Встроенные сайты

```text
1) 📁 Файловый архив
2) 🎬 Медиаархив
3) 📰 Новостной портал
4) 📚 Техническая документация
5) 🏢 Корпоративный сайт
6) 🌐 Нейтральная заглушка
```

Эти шаблоны рассчитаны на использование непосредственно по IP VPS.

Например:

```text
http://IP_СЕРВЕРА
```

Для таких шаблонов ввод домена не требуется.

---

## 🎨 Готовые HTML-шаблоны

```text
7)  ☁️ Cloud Storage
8)  ⬇️ Download Manager
9)  📁 File Converter
10) 🎮 Games Site
11) 😂 Memes Site
12) 🛠️ Mod Manager
13) 🚀 Speed Test
14) 🎬 Video Converter
15) ⚠️ 503 Error Pages
16) 🤖 YouTube Captcha
```

Соответствие каталогам:

| Шаблон           | Каталог                   |
| ---------------- | ------------------------- |
| Cloud Storage    | `filecloud`               |
| Download Manager | `downloader`              |
| File Converter   | `converter`               |
| Games Site       | `games-site`              |
| Memes Site       | `10gag`                   |
| Mod Manager      | `modmanager`              |
| Speed Test       | `speedtest`               |
| Video Converter  | `convertit`               |
| 503 Error Pages  | `503 error pages`         |
| YouTube Captcha  | `YouTube endless captcha` |

---

# 🔄 Reverse Proxy

Nginx Manager поддерживает:

```text
17) Reverse Proxy
18) Reverse Proxy + WebSocket
19) Управление / удаление Proxy
```

WebSocket-вариант предназначен для сервисов, которым необходим Upgrade/Connection WebSocket, включая соответствующие конфигурации Xray/3x-ui.

Прокси-конфигурации отделены от HTML-сайтов.

---

# 🔐 SSL / Security Headers

В Nginx Manager:

```text
20) ACME / Let's Encrypt
21) Security Headers
```

ACME используется для получения и обновления сертификатов Let's Encrypt.

Security Headers позволяют добавить защитные HTTP-заголовки в конфигурацию сайта.

---

# 💾 Резервные копии

Основной каталог локальных резервных копий 3x-ui:

```text
/root/xui_backups/
```

Посмотреть:

```bash
ls -lah /root/xui_backups/
```

При повторном запуске `install.sh` существующая база:

```text
/etc/x-ui/x-ui.db
```

перед установкой сохраняется в резервную копию.

---

# 🧱 Firewall

Используется UFW.

Основные команды:

```bash
ufw status
```

Подробный статус:

```bash
ufw status verbose
```

Правила с номерами:

```bash
ufw status numbered
```

Удаление правила:

```bash
ufw delete НОМЕР
```

Перезагрузка:

```bash
ufw reload
```

Проверка реально слушающих портов:

```bash
ss -lntup
```

---

# 🚨 ВАЖНО: SSH-порт 666

После настройки VPS SSH-порт используется:

```text
666
```

**Не закрывайте текущую SSH-сессию до проверки нового подключения.**

Откройте вторую параллельную сессию:

```bash
ssh -p 666 root@IP_СЕРВЕРА
```

Только после успешного подключения по `666` можно закрывать старую сессию.

Проверить порт SSH:

```bash
sshd -T | grep '^port '
```

Проверить конфигурацию:

```bash
sshd -t
```

Проверить службу:

```bash
systemctl status ssh --no-pager
```

---

# 🖥️ 3x-ui — полезные команды

Панель:

```text
http://IP_СЕРВЕРА:8784
```

Реквизиты установки:

```bash
cat /etc/x-ui/install-result.env
```

Проверить порт:

```bash
ss -lntp | grep ':8784'
```

Статус:

```bash
systemctl status x-ui --no-pager
```

Быстрая проверка:

```bash
systemctl is-active x-ui
```

Перезапуск:

```bash
systemctl restart x-ui
```

Live-логи:

```bash
journalctl -u x-ui -f
```

Последние 100 строк:

```bash
journalctl -u x-ui -n 100 --no-pager
```

Обновление:

```bash
x-ui update
```

Процессы:

```bash
ps aux | grep -E 'x-ui|xray' | grep -v grep
```

---

# 🧦 Cloudflare WARP — полезные команды

Проверить службу:

```bash
systemctl status warp-svc --no-pager
```

Проверить SOCKS5:

```bash
ss -lntp | grep ':40000'
```

IP через WARP:

```bash
curl --socks5 127.0.0.1:40000 https://api.ipify.org
```

Реальный IPv4 сервера:

```bash
curl -4 https://api.ipify.org
```

---

# 🛡️ Fail2ban — полезные команды

Общий статус:

```bash
fail2ban-client status
```

SSH jail:

```bash
fail2ban-client status sshd
```

Разблокировать IP:

```bash
fail2ban-client set sshd unbanip IP_АДРЕС
```

Статус службы:

```bash
systemctl status fail2ban --no-pager
```

Live-логи:

```bash
journalctl -u fail2ban -f
```

Последние события:

```bash
journalctl -u fail2ban -n 100 --no-pager
```

---

# 🚫 AntiScanner — полезные команды

Статус:

```bash
systemctl status antiscan --no-pager
```

Обновление базы:

```bash
/usr/local/bin/update-antiscan.sh
```

Количество заблокированных IP:

```bash
cat /etc/antiscan/blocked_count
```

Проверка ipset:

```bash
ipset list SCANNERS-BLOCK-V4 | head -n 15
```

Timer:

```bash
systemctl status antiscan.timer --no-pager
```

---

# 🌐 Nginx — полезные команды

Проверка конфигурации:

```bash
nginx -t
```

Проверка + мягкая перезагрузка:

```bash
nginx -t && systemctl reload nginx
```

Статус:

```bash
systemctl status nginx --no-pager
```

Проверка порта:

```bash
ss -lntp | grep ':80'
```

Активные сайты:

```bash
ls -lah /etc/nginx/sites-enabled/
```

Полная конфигурация:

```bash
nginx -T
```

Последние ошибки:

```bash
journalctl -u nginx -n 100 --no-pager
```

Live-логи:

```bash
journalctl -u nginx -f
```

---

# ⚡ BBR / FQ / IPv6 / Swap

## BBR + FQ

```bash
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
```

Ожидается:

```text
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
```

## IPv6

```bash
sysctl net.ipv6.conf.all.disable_ipv6
```

Если IPv6 отключён:

```text
net.ipv6.conf.all.disable_ipv6 = 1
```

## Swap

```bash
swapon --show
```

## Swappiness

```bash
sysctl vm.swappiness
```

---

# 🔄 Cron и обновление ОС

Задания root:

```bash
crontab -l
```

Все systemd timers:

```bash
systemctl list-timers --all
```

Обновление пакетов:

```bash
apt update && apt upgrade -y
```

Очистка ненужных пакетов:

```bash
apt autoremove -y
```

Очистка кэша:

```bash
apt clean
```

---

# 📊 Экспресс-проверка VPS

Проверка основных служб, портов, BBR, IPv6 и UFW:

```bash
echo "=== SERVICES ===" && \
systemctl is-active nginx x-ui cron fail2ban antiscan warp-svc && \
echo "=== PORTS ===" && \
ss -lntp | grep -E ':(666|8784|40000)' && \
echo "=== BBR / IPV6 ===" && \
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv6.conf.all.disable_ipv6 && \
echo "=== UFW ===" && \
ufw status
```

---

# 📋 Расширенная диагностика

Базовый полный отчёт:

```bash
echo "========== HOST ==========" && hostname && uptime && \
echo -e "\n========== OS ==========" && uname -a && \
echo -e "\n========== MEMORY ==========" && free -h && \
echo -e "\n========== DISK ==========" && df -h / && \
echo -e "\n========== SERVICES ==========" && \
systemctl is-active nginx x-ui cron fail2ban antiscan warp-svc && \
echo -e "\n========== PORTS ==========" && \
ss -lntup | grep -E ':(666|8784|40000)' && \
echo -e "\n========== BBR / IPV6 ==========" && \
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv6.conf.all.disable_ipv6 && \
echo -e "\n========== UFW ==========" && \
ufw status && \
echo -e "\n========== WARP ==========" && \
curl --socks5 127.0.0.1:40000 https://api.ipify.org && echo
```

---

# 🧠 Мониторинг VPS

## Оперативная память

```bash
free -h
```

## Топ процессов по RAM

```bash
ps aux --sort=-%mem | head -n 10
```

## Топ процессов по CPU

```bash
ps aux --sort=-%cpu | head -n 10
```

## Диск

```bash
df -h
```

## Крупнейшие каталоги

```bash
du -xhd1 / 2>/dev/null | sort -h
```

## Температура CPU

```bash
sensors 2>/dev/null || true
```

## NVMe

```bash
nvme smart-log /dev/nvme0 2>/dev/null || true
```

---

# 📝 Systemd / журналы

Ошибки:

```bash
journalctl -p err -n 100 --no-pager
```

Ошибки текущей загрузки:

```bash
journalctl -b -p err --no-pager
```

Последние события:

```bash
journalctl -n 100 --no-pager
```

Live-журнал:

```bash
journalctl -f
```

Очистить журналы старше 7 дней:

```bash
journalctl --vacuum-time=7d
```

Ограничить размер журналов:

```bash
journalctl --vacuum-size=200M
```

---

# 📌 Быстрые горячие команды

| Действие         | Команда                                |
| ---------------- | -------------------------------------- |
| Перезапуск 3x-ui | `systemctl restart x-ui`               |
| Статус 3x-ui     | `systemctl status x-ui --no-pager`     |
| Логи 3x-ui       | `journalctl -u x-ui -f`                |
| Тест Nginx       | `nginx -t`                             |
| Reload Nginx     | `systemctl reload nginx`               |
| Все порты        | `ss -lntup`                            |
| SSH-порт         | `sshd -T \| grep '^port '`             |
| Проверка SSH     | `sshd -t`                              |
| SSH jail         | `fail2ban-client status sshd`          |
| UFW правила      | `ufw status numbered`                  |
| WARP             | `systemctl status warp-svc --no-pager` |
| AntiScanner      | `systemctl status antiscan --no-pager` |
| Cron             | `crontab -l`                           |
| RAM              | `free -h`                              |
| Диск             | `df -h`                                |
| Ошибки systemd   | `journalctl -p err -n 100 --no-pager`  |
| Все timers       | `systemctl list-timers --all`          |
| Перезагрузка VPS | `reboot`                               |

---

# 🔧 Прямой запуск отдельных скриптов

Все компоненты можно запускать независимо от `install.sh`.

## Основная настройка

```bash
bash setup.sh
```

## Безопасность

```bash
bash vps-security-installer.sh
```

## SSH Manager

```bash
bash ssh-key-manager.sh
```

## Nginx Manager

```bash
bash nginx-templates.sh
```

---

# 🔍 Проверка после установки

После завершения установки рекомендуется проверить:

### SSH

```bash
ssh -p 666 root@IP_СЕРВЕРА
```

### 3x-ui

```bash
systemctl is-active x-ui
```

### Nginx

```bash
nginx -t
```

### Fail2ban

```bash
fail2ban-client status
```

### AntiScanner

```bash
systemctl status antiscan --no-pager
```

### WARP

```bash
systemctl status warp-svc --no-pager
```

### Firewall

```bash
ufw status verbose
```

### Открытые порты

```bash
ss -lntup
```

### BBR

```bash
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
```

### Swap

```bash
swapon --show
```

---

# 📁 Основные пути

| Назначение                | Путь                           |
| ------------------------- | ------------------------------ |
| Маркер установки          | `/etc/vps-bootstrap-complete`  |
| База 3x-ui                | `/etc/x-ui/x-ui.db`            |
| Результат установки 3x-ui | `/etc/x-ui/install-result.env` |
| Бэкапы 3x-ui              | `/root/xui_backups/`           |
| Nginx                     | `/etc/nginx/`                  |
| Активные Nginx-сайты      | `/etc/nginx/sites-enabled/`    |
| Доступные Nginx-сайты     | `/etc/nginx/sites-available/`  |
| Fail2ban                  | `/etc/fail2ban/`               |
| AntiScanner               | `/etc/antiscan/`               |

---

# ⚠️ Важные замечания

### SSH

Не отключайте текущую SSH-сессию до проверки нового подключения через порт `666`.

### SSH-ключи

Никогда не размещайте приватный SSH-ключ в публичном или приватном GitHub-репозитории.

В GitHub должен находиться только публичный ключ:

```text
id_ed25519.pub
```

### Nginx

После изменения конфигурации всегда выполняйте:

```bash
nginx -t
```

И только при успешной проверке:

```bash
systemctl reload nginx
```

### Firewall

Перед изменением UFW убедитесь, что SSH-порт `666` разрешён.

### Резервные копии

Перед повторной установкой или восстановлением базы желательно проверить наличие актуального файла в:

```text
/root/xui_backups/
```

---

# 📜 Лицензия

Проект распространяется под лицензией MIT.

---

# 🔗 Репозиторий

GitHub:

https://github.com/iurievi4/vps-setup

---

# 👤 Автор

**iurievi4**

Проект предназначен для автоматизации развёртывания и последующего администрирования VPS через набор независимых Bash-инструментов.
