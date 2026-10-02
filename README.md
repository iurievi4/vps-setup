# VPS Setup & Security Toolkit

Набор Bash-скриптов для автоматической настройки и защиты VPS на базе Debian/Ubuntu.

Проект состоит из лаунчера и двух самостоятельных скриптов:

* `install.sh` — интерактивный лаунчер;
* `setup.sh` — основная настройка VPS;
* `vps-security-installer.sh` — установка дополнительной защиты.

---

## 📁 Структура проекта

```text
vps-setup/
├── install.sh
├── setup.sh
├── vps-security-installer.sh
└── README.md
```

---

# 🚀 Быстрая установка

Для запуска лаунчера:

```bash
curl -fsSL https://raw.githubusercontent.com/iurievi4/vps-setup/main/install.sh | bash
```

После запуска появится меню:

```text
╔══════════════════════════════════════════════════════════╗
║                      VPS INSTALLER                       ║
╚══════════════════════════════════════════════════════════╝

  1) Полная автоматическая установка
  2) Ручной запуск setup.sh
  3) Установка безопасности
  0) Выход
```

---

# 🧩 install.sh

`install.sh` — основной лаунчер проекта.

Он не содержит основной логики установки, а загружает актуальные версии скриптов из репозитория и запускает выбранный режим.

## 1. Полная автоматическая установка

Запускается:

```text
setup.sh
```

Автоматический профиль:

* PostgreSQL — отключён;
* Microsoft SQL Server — отключён;
* TorrServer — отключён;
* Cloudflare WARP — включён;
* 3x-ui — SQLite;
* восстановление резервной базы — отключено;
* при первой установке используется новая пустая база;
* интерактивные вопросы автоматического режима отключаются.

Запуск:

```bash
curl -fsSL https://raw.githubusercontent.com/iurievi4/vps-setup/main/install.sh | bash -s -- 1
```

Или через меню:

```text
1
```

### Повторный запуск

Лаунчер можно запускать повторно.

При повторном запуске существующая установка определяется, и `setup.sh` запускается повторно с разрешением на повторный bootstrap.

**Существующая база 3x-ui не должна использоваться для восстановления резервной копии.**

---

## 2. Ручной запуск setup.sh

Запускается обычный `setup.sh` без автоматических параметров.

```bash
curl -fsSL https://raw.githubusercontent.com/iurievi4/vps-setup/main/install.sh | bash -s -- 2
```

Или выбрать в меню:

```text
2
```

В этом режиме `setup.sh` работает в своём штатном интерактивном режиме и позволяет пользователю самостоятельно выбрать необходимые параметры.

---

## 3. Установка безопасности

Запускается:

```text
vps-security-installer.sh
```

Он устанавливает и настраивает:

* Fail2ban;
* AntiScanner;
* Cloudflare WARP;
* Security MOTD.

Запуск:

```bash
curl -fsSL https://raw.githubusercontent.com/iurievi4/vps-setup/main/install.sh | bash -s -- 3
```

Или выбрать в меню:

```text
3
```

---

# ⚙️ setup.sh

Основной скрипт первоначальной настройки VPS.

Выполняет подготовку сервера и настройку основных системных компонентов.

Основные задачи:

* обновление системы;
* установка необходимых пакетов;
* настройка сети;
* TCP BBR;
* Swap;
* Nginx;
* ACME/SSL;
* системный MOTD;
* автоматические задачи обслуживания;
* настройка firewall;
* SSH;
* 3x-ui;
* дополнительные системные сервисы.

---

## 🗄️ 3x-ui и база данных

В автоматическом режиме `install.sh` использует:

```text
SQLite
```

и не выполняет восстановление существующих резервных копий базы.

Автоматический режим предназначен для **чистой первоначальной установки**.

При повторном запуске нельзя принудительно создавать новую базу поверх уже работающей установки — существующая база должна сохраняться.

Для восстановления резервной базы используется ручной режим `setup.sh`, если такая функция предусмотрена текущей версией скрипта.

---

# 🛡️ vps-security-installer.sh

Отдельный установщик дополнительной защиты VPS.

Скрипт можно запускать независимо от `setup.sh`.

## Fail2ban

Настраивает защиту SSH:

* установка Fail2ban при отсутствии;
* определение SSH-порта;
* `sshd` jail;
* `recidive`;
* проверка конфигурации;
* резервное копирование существующей конфигурации;
* автоматический запуск службы;
* автозапуск после перезагрузки.

Основные параметры SSH:

```text
maxretry = 3
findtime = 10m
bantime  = 24h
```

Для `recidive`:

```text
maxretry = 3
findtime = 1d
bantime  = 1w
```

---

# 🚫 AntiScanner

AntiScanner блокирует IP-адреса и сети из внешнего blacklist с помощью `ipset` и `iptables`.

Возможности:

* загрузка blacklist;
* проверка полученного списка;
* фильтрация IPv4;
* локальный кэш;
* работа при временной недоступности источника;
* атомарное обновление `ipset`;
* защита от параллельного запуска;
* правило DROP в `iptables`;
* сохранение firewall;
* журналирование;
* автоматическое обновление.

Основные файлы:

```text
/etc/antiscan/blacklist.txt
/etc/antiscan/last_update
/etc/antiscan/blocked_count
/etc/default/antiscan
/var/log/antiscan-update.log
/usr/local/bin/update-antiscan.sh
```

IPSet:

```text
SCANNERS-BLOCK-V4
```

Правило firewall:

```text
INPUT → SCANNERS-BLOCK-V4 → DROP
```

Автоматическое обновление:

```text
Понедельник 04:15
```

---

# ☁️ Cloudflare WARP

`vps-security-installer.sh` устанавливает и настраивает Cloudflare WARP в режиме локального SOCKS5-прокси.

Выполняется:

* установка `cloudflare-warp`;
* запуск `warp-svc`;
* регистрация клиента;
* настройка proxy mode;
* настройка SOCKS5;
* подключение WARP;
* проверка локального порта;
* проверка соединения Cloudflare.

Локальный SOCKS5:

```text
127.0.0.1:40000
```

---

# 📋 Security MOTD

Security installer интегрирует информацию о безопасности в системный MOTD.

В зависимости от существующей конфигурации используется:

```text
/etc/update-motd.d/99-custom-sysinfo
```

или отдельный:

```text
/etc/update-motd.d/98-security-status
```

Может отображаться:

* AntiScanner;
* количество заблокированных сетей;
* время последнего обновления;
* Fail2ban;
* SSH jail;
* recidive;
* Cloudflare WARP.

Перед изменением существующего MOTD создаётся резервная копия.

---

# 🔄 Повторный запуск

Скрипты рассчитаны на повторный запуск.

### `install.sh`

Можно повторно выполнить:

```bash
curl -fsSL https://raw.githubusercontent.com/iurievi4/vps-setup/main/install.sh | bash
```

### Автоматический режим

```bash
curl -fsSL https://raw.githubusercontent.com/iurievi4/vps-setup/main/install.sh | bash -s -- 1
```

### Ручной setup

```bash
curl -fsSL https://raw.githubusercontent.com/iurievi4/vps-setup/main/install.sh | bash -s -- 2
```

### Security

```bash
curl -fsSL https://raw.githubusercontent.com/iurievi4/vps-setup/main/install.sh | bash -s -- 3
```

---

# 🔍 Проверка после установки

## Fail2ban

```bash
systemctl status fail2ban --no-pager
```

```bash
fail2ban-client status sshd
```

```bash
fail2ban-client status recidive
```

## AntiScanner

```bash
systemctl status antiscan.service --no-pager
```

```bash
ipset list SCANNERS-BLOCK-V4
```

```bash
iptables -C INPUT -m set --match-set SCANNERS-BLOCK-V4 src -j DROP
```

Принудительное обновление:

```bash
/usr/local/bin/update-antiscan.sh
```

Журнал:

```bash
tail -50 /var/log/antiscan-update.log
```

## Cloudflare WARP

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

Особое внимание следует уделить:

* SSH;
* UFW;
* iptables;
* сетевым настройкам;
* автоматическим firewall-правилам.

Изменение SSH-порта или firewall может привести к потере доступа к серверу при неправильной конфигурации.

---

# 🧭 Рекомендуемый порядок

Для нового VPS:

```text
install.sh
    ↓
1) Полная автоматическая установка
    ↓
setup.sh
    ↓
система + сеть + BBR + Swap + Nginx + 3x-ui
```

Для уже работающего VPS:

```text
install.sh
    ↓
3) Установка безопасности
    ↓
Fail2ban
AntiScanner
Cloudflare WARP
Security MOTD
```

Для ручной настройки:

```text
install.sh
    ↓
2) Ручной запуск setup.sh
```

---

# 📌 Назначение проекта

Проект предназначен для автоматизации типовой подготовки VPS.

### VPS Setup

* базовая система;
* сеть;
* BBR;
* Swap;
* Nginx;
* SSL;
* firewall;
* SSH;
* 3x-ui;
* обслуживание.

### Security

* Fail2ban;
* AntiScanner;
* Cloudflare WARP;
* Security MOTD.

---

# 📄 Лицензия

Скрипты предоставляются как набор инструментов для автоматизации настройки VPS.

Используйте их на свой риск и проверяйте конфигурацию перед применением на продуктивных серверах.
