# VPS Setup & Security Toolkit

Набор Bash-скриптов для автоматической подготовки, настройки и защиты VPS на базе Debian/Ubuntu.

Проект разделён на два независимых скрипта:

* `setup.sh` — основная настройка VPS
* `vps-security-installer.sh` — установка и настройка дополнительного уровня защиты

---

## 📁 Файлы проекта

```text
.
├── setup.sh
├── vps-security-installer.sh
└── README.md
```

---

# ⚙️ setup.sh

Основной скрипт первоначальной настройки VPS.

Предназначен для автоматической подготовки сервера после установки Debian/Ubuntu.

### Выполняет:

* обновление и очистку системы;
* установку базовых системных утилит;
* настройку сетевых параметров;
* включение TCP BBR;
* настройку Swap;
* первоначальную настройку Nginx;
* подготовку ACME/SSL;
* создание системного MOTD;
* настройку автоматических задач обслуживания;
* мониторинг основных параметров VPS;
* настройку необходимых системных служб.

### Запуск

```bash
curl -fsSL https://raw.githubusercontent.com/iurievi4/vps-setup/main/setup.sh | bash
```

---

# 🛡️ vps-security-installer.sh

Отдельный скрипт для установки и настройки защиты уже работающего VPS.

Скрипт можно запускать независимо от `setup.sh`.

## Fail2ban

Автоматически:

* устанавливает Fail2ban, если он отсутствует;
* определяет используемый SSH-порт;
* настраивает защиту SSH;
* включает `sshd` jail;
* включает `recidive`;
* проверяет конфигурацию перед перезапуском;
* сохраняет предыдущую конфигурацию перед изменением;
* включает Fail2ban в автозагрузку.

### Используемые параметры

```text
SSH:
maxretry = 3
findtime = 10m
bantime  = 24h

recidive:
maxretry = 3
findtime = 1d
bantime  = 1w
```

---

# 🚫 AntiScanner

AntiScanner блокирует IP-адреса и сети из внешнего blacklist с помощью `ipset` и `iptables`.

### Возможности

* автоматическая загрузка blacklist;
* проверка полученного списка;
* проверка корректности IPv4-адресов;
* использование локального кэша при недоступности источника;
* атомарное обновление `ipset`;
* защита от одновременного запуска обновлений;
* автоматическое создание `iptables DROP`;
* сохранение правил firewall;
* журналирование обновлений;
* хранение количества заблокированных сетей;
* автоматическое обновление по понедельникам.

### Основные файлы

```text
/etc/antiscan/blacklist.txt
/etc/antiscan/last_update
/etc/antiscan/blocked_count
/etc/default/antiscan
/var/log/antiscan-update.log
/usr/local/bin/update-antiscan.sh
```

### IPSet

Используется:

```text
SCANNERS-BLOCK-V4
```

Правило блокировки:

```text
iptables INPUT → SCANNERS-BLOCK-V4 → DROP
```

---

# ☁️ Cloudflare WARP

Скрипт автоматически устанавливает и настраивает Cloudflare WARP в режиме SOCKS5-прокси.

### Возможности

* установка `cloudflare-warp`;
* запуск `warp-svc`;
* регистрация клиента;
* настройка proxy mode;
* настройка SOCKS5-порта;
* проверка доступности прокси;
* проверка соединения через Cloudflare.

Локальный SOCKS5:

```text
127.0.0.1:40000
```

Проверка соединения выполняется через:

```text
https://www.cloudflare.com/cdn-cgi/trace
```

---

# 📋 Security MOTD

Скрипт может интегрировать информацию о безопасности в существующий:

```text
/etc/update-motd.d/99-custom-sysinfo
```

или создать отдельный:

```text
/etc/update-motd.d/98-security-status
```

### Отображается:

```text
AntiScanner
  Blocked IPs
  Last update

Fail2ban
  SSH jail
  recidive

Cloudflare WARP
```

Например:

```text
🛡️ СТАТУС СЛУЖБ БЕЗОПАСНОСТИ:

AntiScanner           : RUN
  Blocked IPs         : 154
  Last update         : 2026-10-02 04:15

Fail2ban              : RUNNING
  SSH jail            : OK | banned: 0
  recidive             : OK

Cloudflare WARP       : RUNNING (SOCKS5 :40000)
```

---

# 🔄 Автоматическое обновление AntiScanner

После установки создаётся cron-задача:

```text
15 4 * * 1
```

То есть blacklist обновляется:

**каждый понедельник в 04:15.**

При обновлении используется временный `ipset`, после чего выполняется атомарная замена существующего набора.

Это позволяет не оставлять текущий рабочий blacklist в промежуточном состоянии во время обновления.

---

# 🔁 Повторный запуск

Скрипт рассчитан на повторный запуск.

Перед изменением существующего Fail2ban-конфига создаётся резервная копия:

```text
/etc/fail2ban/jail.d/vps-setup.local.bak-YYYYMMDD-HHMMSS
```

Перед изменением основного MOTD также создаётся резервная копия.

Уже установленные компоненты повторно не устанавливаются без необходимости.

---

# 🚀 Установка

## 1. Основная настройка VPS

```bash
curl -fsSL https://raw.githubusercontent.com/iurievi4/vps-setup/main/setup.sh | bash
```

## 2. Установка защиты

```bash
curl -fsSL https://raw.githubusercontent.com/iurievi4/vps-setup/main/vps-security-installer.sh | bash
```

Скрипты можно использовать как вместе, так и независимо друг от друга.

---

# 🔍 Проверка после установки

### Fail2ban

```bash
systemctl status fail2ban --no-pager
```

Проверка SSH jail:

```bash
fail2ban-client status sshd
```

Проверка recidive:

```bash
fail2ban-client status recidive
```

### AntiScanner

```bash
systemctl status antiscan.service --no-pager
```

Количество записей:

```bash
ipset list SCANNERS-BLOCK-V4
```

Проверка правила:

```bash
iptables -C INPUT -m set --match-set SCANNERS-BLOCK-V4 src -j DROP
```

Ручное обновление:

```bash
/usr/local/bin/update-antiscan.sh
```

Журнал:

```bash
tail -50 /var/log/antiscan-update.log
```

### Cloudflare WARP

```bash
systemctl status warp-svc --no-pager
```

```bash
warp-cli status
```

Проверка SOCKS5:

```bash
ss -lnt | grep 40000
```

---

# ⚠️ Важно

Скрипты предназначены для серверов, которыми вы управляете.

Перед запуском рекомендуется иметь доступ к VPS через консоль провайдера или другой резервный способ подключения.

Особое внимание следует уделить настройкам SSH и firewall, поскольку ошибочная конфигурация может привести к потере доступа к серверу.

---

# 📌 Назначение проекта

Проект предназначен для автоматизации типовых операций при развёртывании VPS:

```text
┌─────────────────────────────┐
│          VPS Setup          │
├─────────────────────────────┤
│                             │
│  setup.sh                   │
│  ├─ Система                 │
│  ├─ Сеть                    │
│  ├─ BBR                     │
│  ├─ Swap                    │
│  ├─ Nginx                   │
│  ├─ SSL                     │
│  └─ Обслуживание             │
│                             │
│  vps-security-installer.sh  │
│  ├─ Fail2ban                │
│  ├─ AntiScanner             │
│  ├─ Cloudflare WARP         │
│  └─ Security MOTD           │
│                             │
└─────────────────────────────┘
```

---

## 📄 Лицензия

Скрипты предоставляются как набор инструментов для автоматизации настройки VPS.

Используйте на свой риск и проверяйте конфигурацию перед применением на продуктивных серверах.
