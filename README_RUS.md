# Home Assistant Supervised — INSTALLER v8.0

📋 СОДЕРЖАНИЕ

1. [Обзор](#1-обзор)
2. [Системные требования](#2-системные-требования)
3. [Быстрый старт](#3-быстрый-старт)
4. [Установка](#4-установка)
5. [Профили](#5-профили)
6. [Все параметры командной строки](#6-параметры-командной-строки)
7. [Пошаговое описание установки](#7-пошаговое-описание-установки)
8. [Компоненты и модули](#8-компоненты-и-модули)
9. [Управление после установки](#9-управление-после-установки)
10. [Бэкап и восстановление](#10-бэкап-и-восстановление)
11. [Мониторинг и watchdog](#11-мониторинг-и-watchdog)
12. [Сеть и Reverse Proxy](#12-сеть-и-reverse-proxy)
13. [Безопасность](#13-безопасность)
14. [Обновление](#14-обновление)
15. [Удаление](#15-удаление)
16. [Диагностика и отладка](#16-диагностика-и-отладка)
17. [Структура файлов](#17-структура-файлов)
18. [FAQ](#18-faq)
19. [Решение проблем](#19-решение-проблем)
20. [Поддерживаемые платформы](#20-поддерживаемые-платформы)

---

## 1. ОБЗОР

### Что это

Автоматический установщик **Home Assistant Supervised** для одноплатных компьютеров (SBC), TV-боксов и серверов на базе Debian/Armbian. Устанавливает полноценную среду HA Supervised с Docker, OS-Agent, системными оптимизациями, безопасностью, мониторингом и инструментами обслуживания.

### Что устанавливается

```
┌─────────────────────────────────────────────────────┐
│                    HA Supervised                     │
│  ┌─────────────┐ ┌──────────┐ ┌──────────────────┐  │
│  │  HA Core    │ │Supervisor│ │  Add-ons (HACS)   │  │
│  │  (контейнер)│ │(контейнер│ │  (контейнеры)     │  │
│  └─────────────┘ └──────────┘ └──────────────────┘  │
│  ┌─────────────────────────────────────────────────┐ │
│  │              Docker Engine                      │ │
│  └─────────────────────────────────────────────────┘ │
│  ┌──────────┐ ┌───────────┐ ┌─────────────────────┐ │
│  │ OS-Agent │ │ AppArmor  │ │   NetworkManager    │ │
│  └──────────┘ └───────────┘ └─────────────────────┘ │
│  ┌─────────────────────────────────────────────────┐ │
│  │     Debian / Armbian (bookworm/trixie)          │ │
│  └─────────────────────────────────────────────────┘ │
│  ┌─────────────────────────────────────────────────┐ │
│  │  Утилиты: watchdog, backup, thermal, metrics    │ │
│  └─────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

### Ключевые возможности v8.0

- **5 профилей** установки (minimal → full)
- **SHA256-верификация** загруженных пакетов
- **Docker из официального репозитория** (с fallback)
- **Rollback** при критической ошибке
- **Автоматическая проверка места** перед каждой операцией
- **Watchdog с exponential backoff**
- **Boot recovery** — автоматическое восстановление после сбоя питания
- **Prometheus-метрики** для мониторинга
- **Reverse proxy + SSL** (Let's Encrypt)
- **Удалённый бэкап** (SSH/SCP)
- **Детектирование USB-донглов** (Zigbee/Z-Wave/BT)
- **Self-test и self-update**
- **Интерактивное подтверждение шагов**
- **Прогресс-бар** при установке пакетов
- **Возобновление** прерванной установки

---

## 2. СИСТЕМНЫЕ ТРЕБОВАНИЯ

### Минимальные

| Параметр | Значение |
|---|---|
| **ОС** | Debian 11 (bullseye), 12 (bookworm), 13 (trixie), Armbian |
| **Архитектура** | aarch64 (ARM64), x86_64 |
| **RAM** | 2 GB (минимум 1 GB) |
| **Диск** | 32 GB (минимум 16 GB, свободно ≥ 4 GB) |
| **Bash** | ≥ 4.0 |
| **Интернет** | Обязателен при установке |
| **Ядро** | ≥ 4.x (рекомендуется 5.x+) |
| **cgroups** | v2 (рекомендуется) или v1 |

### Рекомендуемые

| Параметр | Значение |
|---|---|
| **RAM** | 4 GB |
| **Диск** | 64 GB eMMC или NVMe |
| **Ядро** | 6.x |
| **Сеть** | Ethernet (не Wi-Fi для стабильности) |

### Поддерживаемые устройства

| Устройство | Тип машины HA | Статус |
|---|---|---|
| Raspberry Pi 5 | `raspberrypi5-64` | ✅ |
| Raspberry Pi 4 | `raspberrypi4-64` | ✅ |
| Raspberry Pi 3 | `raspberrypi3-64` | ✅ |
| ODROID-N2/N2+ | `odroid-n2` | ✅ |
| ODROID-C4 | `odroid-c4` | ✅ |
| Khadas VIM3 | `khadas-vim3` | ✅ |
| x86_64 PC/сервер | `generic-x86-64` | ✅ |
| TV-боксы (Amlogic S905/S912/S922) | `qemuarm-64` | ✅ |
| Любой Armbian aarch64 | `qemuarm-64` | ✅ |
| armv7l (32-bit ARM) | `qemuarm` | ⚠️ |

---

## 3. БЫСТРЫЙ СТАРТ

### Вариант 1: Интерактивный мастер (рекомендуется)

```bash
# Скачать и запустить
wget -O install.sh https://raw.githubusercontent.com/iRespect777/HAS-tvbox/refs/heads/main/install.sh
chmod +x install.sh
sudo ./install.sh
```

Мастер предложит выбрать профиль, затем покажет checklist с модулями и проведёт через всю установку.

### Вариант 2: Профиль одной командой

```bash
# Стандартная установка (рекомендуемый набор)
sudo ./install.sh --profile standard

# Минимальная (только HA + Docker)
sudo ./install.sh --profile minimal

# Полная (все модули + мониторинг)
sudo ./install.sh --profile full

# Серверная (полная + статический IP)
sudo ./install.sh --profile server

# Для разработчика (минимум + HACS)
sudo ./install.sh --profile dev
```

### Вариант 3: Тихая установка (для скриптов)

```bash
sudo ./install.sh --profile standard --silent
```

### После установки

```
  ➜  http://192.168.1.100:8123     ← ваш IP
  ➜  http://homeassistant.local:8123

  Инициализация HA: 10-15 мин.
```

Откройте браузер по указанному адресу и пройдите начальную настройку Home Assistant.

---

## 4. УСТАНОВКА

### 4.1. Подготовка системы

```bash
# Обновите систему перед запуском
sudo apt update && sudo apt upgrade -y

# Убедитесь что запускаете от root
sudo -i

# Или с sudo
sudo ./install.sh
```

### 4.2. Запуск мастера установки

```bash
sudo ./install.sh
```

#### Экран 1: Информация о системе

```
┌──────────────────────────────────────────────┐
│        HA Installer v8.0                     │
│                                              │
│  Armbian 24.5 bookworm (aarch64) [Armbian]   │
│                                              │
│  Обязательное ядро ставится всегда.          │
│  Выберите профиль или компоненты.            │
│                                              │
│              <OK>                            │
└──────────────────────────────────────────────┘
```

#### Экран 2: Выбор профиля

```
┌─────────────────────────────────────────────────┐
│                Профиль                          │
│                                                 │
│   minimal    Только HA + Docker (минимум)       │
│ > standard   Рекомендуемый набор                │
│   full       Полный набор + мониторинг          │
│   server     Сервер + стат. IP                  │
│   dev        Для разработчиков                  │
│   custom     Выбрать вручную...                 │
│                                                 │
│          <OK>         <Cancel>                  │
└─────────────────────────────────────────────────┘
```

#### Экран 3 (только для custom): Выбор компонентов

```
┌──────────────────────────────────────────────────────┐
│                  Компоненты                          │
│                                                      │
│  [X] ZRAM         ▸ Swap в RAM                       │
│  [X] EMMC         ▸ Тюнинг eMMC/SD                  │
│  [X] USBPOWER     ▸ USB power fix                   │
│  [X] UFW          ▸ UFW+Fail2Ban                     │
│  [X] SSHHARD      ▸ SSH hardening                    │
│  [X] AUTOUPD      ▸ Автообновления                   │
│  [X] WATCHDOG     ▸ Watchdog+Cleanup                 │
│  [X] THERMAL      ▸ Температура                      │
│  [X] BACKUP       ▸ Бэкап                            │
│  [X] HACS         ▸ HACS                             │
│  [X] HOSTNAME     ▸ homeassistant                    │
│  [ ] MONITOR      ▸ Мониторинг                       │
│  [X] USBDETECT    ▸ Поиск USB-донглов                │
│  [X] BOOTRECOV    ▸ Boot recovery                    │
│  [ ] STATICIP     ▸ Стат. IP (192.168.1.100)         │
│  [ ] TELEGRAM     ▸ Telegram                         │
│  [ ] REVPROXY     ▸ Reverse Proxy+SSL                │
│  [ ] RBACKUP      ▸ Удалённый бэкап                  │
│                                                      │
│           <OK>             <Cancel>                  │
└──────────────────────────────────────────────────────┘
```

#### Экран 4: Подтверждение

```
┌──────────────────────────────────────────────┐
│                    OK?                       │
│                                              │
│  Установить:                                 │
│                                              │
│    ✔ HA Supervised + Docker + OS-Agent       │
│    Профиль: standard                         │
│    ✔ ZRAM                                    │
│    ✔ UFW                                     │
│    ✔ Watchdog                                │
│    ✔ Бэкап                                   │
│    ✔ HACS                                    │
│                                              │
│  Начать?                                     │
│                                              │
│         <Yes>           <No>                 │
└──────────────────────────────────────────────┘
```

### 4.3. Процесс установки

После подтверждения скрипт автоматически выполнит 13 шагов:

```
╔══════════════════════════════════════════════════════════════╗
║  ПРЕДВАРИТЕЛЬНАЯ ПРОВЕРКА                                    ║
╚══════════════════════════════════════════════════════════════╝

 ✔  Архитектура: aarch64 (aarch64)
 ℹ  Дистрибутив: Armbian 24.5.1 bookworm
 ℹ  Armbian
 ✔  os-release OK
 ✔  Диск: 28450MB
 ✔  RAM: 3884MB
 ✔  Ядро: 6.1.63-current-meson64
 ✔  cgroups: v2
 ✔  Интернет: OK
 ✔  Порт 8123 свободен
 ✔  CPU: 42°C
  ────────────────────────────────────────────────────────────
 ✔  Все проверки пройдены

╔══════════════════════════════════════════════════════════════╗
║  ШАГ 1 — ОБНОВЛЕНИЕ                                         ║
╚══════════════════════════════════════════════════════════════╝
 ✔  apt update
 ✔  apt upgrade

╔══════════════════════════════════════════════════════════════╗
║  ШАГ 2 — ЗАВИСИМОСТИ                                        ║
╚══════════════════════════════════════════════════════════════╝

  [████████████████████████████████░░░]  89%  fail2ban

 ✔  Установлено: 18

  ... (шаги 3-13) ...

╔══════════════════════════════════════════════════════════════╗
║  УСТАНОВКА ЗАВЕРШЕНА! (12м 34с)                              ║
╚══════════════════════════════════════════════════════════════╝

  ➜  http://192.168.1.100:8123
  ➜  http://homeassistant.local:8123

  📱 Сканируйте:
  █████████████████████
  █ ▄▄▄▄▄ █ ▀▀█▄ ...  (QR-код)
  █████████████████████

  Компоненты: (профиль: standard)
  ✔  HA Supervised (qemuarm-64) + Docker + OS-Agent
  ✔  ZRAM
  ✔  UFW+F2B
  ✔  Watchdog (exp.backoff)
  ✔  Бэкап
  ✔  HACS
  ✔  Boot recovery
  ⚠  os-release: фейк при старте supervisor

  Конфиг: /var/lib/ha-installer
  Бэкапы: /var/backups/homeassistant
  Лог:    /var/log/ha_install_20250615_143200.log

  Команды:  ha-health  ha-backup  ha-restore

  Инициализация HA: 10-15 мин.
```

### 4.4. Возобновление прерванной установки

Если установка прервалась (сбой питания, Ctrl+C, ошибка), просто запустите скрипт повторно:

```bash
sudo ./install.sh
```

Скрипт определит выполненные шаги и продолжит с места остановки:

```
  ✔ preflight [14:32]
  ✔ update    [14:33]
  ✔ deps      [14:35]
  ✔ network   [14:36]
  ○ apparmor
  ○ perf
  ○ docker
  ...

  Прогресс: 4/14
```

### 4.5. Сброс состояния

Для полной переустановки с нуля:

```bash
sudo ./install.sh --reset-state
sudo ./install.sh
```

---

## 5. ПРОФИЛИ

### Сравнение профилей

| Компонент | minimal | standard | full | server | dev |
|---|:---:|:---:|:---:|:---:|:---:|
| HA + Docker + OS-Agent | ✅ | ✅ | ✅ | ✅ | ✅ |
| ZRAM | ✅ | ✅ | ✅ | ✅ | ❌ |
| eMMC tuning | ❌ | ✅ | ✅ | ✅ | ❌ |
| USB power fix | ❌ | ✅ | ✅ | ✅ | ❌ |
| UFW + Fail2Ban | ❌ | ✅ | ✅ | ✅ | ❌ |
| SSH hardening | ❌ | ✅ | ✅ | ✅ | ❌ |
| Автообновления | ❌ | ✅ | ✅ | ✅ | ❌ |
| Watchdog | ❌ | ✅ | ✅ | ✅ | ❌ |
| Thermal мониторинг | ❌ | ✅ | ✅ | ✅ | ❌ |
| Бэкап | ❌ | ✅ | ✅ | ✅ | ❌ |
| HACS | ❌ | ✅ | ✅ | ✅ | ✅ |
| Hostname | ✅ | ✅ | ✅ | ✅ | ❌ |
| Prometheus метрики | ❌ | ❌ | ✅ | ✅ | ❌ |
| Boot recovery | ❌ | ✅ | ✅ | ✅ | ❌ |
| USB-детектирование | ❌ | ✅ | ✅ | ✅ | ❌ |
| Статический IP | ❌ | ❌ | ❌ | ✅ | ❌ |

### Когда какой профиль выбрать

| Сценарий | Профиль |
|---|---|
| Первый раз, не знаю что выбрать | `standard` |
| Слабое устройство (1GB RAM, 8GB eMMC) | `minimal` |
| Основной сервер умного дома | `full` |
| Сервер с фиксированным IP в шкафу | `server` |
| Тестовая среда для разработки | `dev` |
| Нужен полный контроль | `custom` (wizard) |

### Использование

```bash
# Командная строка
sudo ./install.sh --profile standard

# В wizard — выбирается из меню

# Текущий профиль сохраняется в конфиге
cat /var/lib/ha-installer/config | grep PROFILE
```

---

## 6. ПАРАМЕТРЫ КОМАНДНОЙ СТРОКИ

### Основные команды

```bash
sudo ./install.sh [ОПЦИИ]
```

| Параметр | Описание |
|---|---|
| *(без параметров)* | Запуск интерактивного мастера |
| `-c`, `--check` | Диагностика системы (без изменений) |
| `-s`, `--status` | Live-мониторинг (обновляется каждые 5с) |
| `-u`, `--uninstall` | Полное удаление |
| `--update` | Обновление HA + OS-Agent до последних версий |
| `--self-update` | Обновление самого скрипта |
| `--self-test` | Запуск встроенных тестов |
| `-h`, `--help` | Справка |

### Настройки установки

| Параметр | Описание |
|---|---|
| `--profile NAME` | Использовать профиль: `minimal`, `standard`, `full`, `server`, `dev` |
| `--machine TYPE` | Тип машины HA (по умолчанию определяется автоматически) |
| `--os-agent-ver X` | Конкретная версия OS-Agent (например `1.6.0`) |
| `--ha-ver X` | Конкретная версия HA supervised (например `1.7.0`) |
| `--skip-update` | Пропустить `apt update/upgrade` |
| `--interactive-steps` | Запрашивать подтверждение каждого шага |
| `--reset-state` | Сбросить состояние (для переустановки) |

### Режимы выполнения

| Параметр | Описание |
|---|---|
| `--dry-run` | Симуляция без реальных изменений |
| `--silent` | Минимальный вывод (для скриптов) |

### Примеры

```bash
# Диагностика — что установлено?
sudo ./install.sh --check

# Тихая установка стандартного набора
sudo ./install.sh --profile standard --silent

# Установка конкретных версий
sudo ./install.sh --profile full --os-agent-ver 1.6.0 --ha-ver 1.7.0

# Пробный запуск (ничего не меняет)
sudo ./install.sh --profile standard --dry-run

# Пошаговая установка с подтверждениями
sudo ./install.sh --profile standard --interactive-steps

# Обновление HA
sudo ./install.sh --update

# Обновление скрипта
sudo ./install.sh --self-update

# Запуск тестов
sudo ./install.sh --self-test

# Удаление
sudo ./install.sh --uninstall

# Переустановка с нуля
sudo ./install.sh --reset-state
sudo ./install.sh --profile full
```

---

## 7. ПОШАГОВОЕ ОПИСАНИЕ УСТАНОВКИ

### Шаг 0: Предварительная проверка (preflight)

**Что проверяется:**
- Архитектура процессора
- Дистрибутив и версия
- Совместимость os-release с HA Supervised
- Свободное место на диске (≥ 4 GB)
- Объём RAM (≥ 1 GB)
- Версия ядра (≥ 4.x)
- cgroups (v1/v2/hybrid)
- Интернет-соединение
- Порт 8123 свободен
- Температура CPU
- Конфликтующие сервисы (apache2, nginx, lighttpd)
- Armbian-специфичные проверки

**При ошибках:**
- Критические (красные) → установка останавливается
- Предупреждения (жёлтые) → установка продолжается

### Шаг 1: Обновление системы (update)

```bash
apt-get update -y
apt-get upgrade -y -o Dpkg::Options::="--force-confold"
```

Флаг `--force-confold` сохраняет существующие конфигурационные файлы.

**Пропуск:** `--skip-update`

### Шаг 2: Зависимости (deps)

Устанавливаемые пакеты:

| Пакет | Назначение |
|---|---|
| apparmor | Безопасность контейнеров |
| avahi-daemon | mDNS (homeassistant.local) |
| bluez | Bluetooth |
| ca-certificates | SSL-сертификаты |
| cifs-utils, nfs-common | Сетевые файловые системы |
| curl, wget | Загрузки |
| dbus | Системная шина |
| gnupg | Ключи |
| jq | JSON-парсер |
| libglib2.0-bin | D-Bus для OS-Agent |
| network-manager | Управление сетью |
| systemd-timesyncd | Синхронизация времени |
| udisks2 | Диски |
| usbutils | USB |
| qrencode | QR-коды |

Дополнительно (по модулям):
- `zram-tools` / `systemd-zram-generator` — ZRAM
- `ufw`, `fail2ban` — фаервол
- `unattended-upgrades` — автообновления
- `pigz` — параллельное сжатие бэкапов
- `nginx`, `certbot` — reverse proxy

### Шаг 3: Настройка сети (network)

1. Настройка NetworkManager как основного менеджера сети
2. Интеграция с systemd-resolved (DNS)
3. Упрощение `/etc/network/interfaces`
4. Опциональный статический IP через nmcli
5. Проверка связности после изменений
6. Автоматический откат при потере сети

**⚠️ SSH-сессии:** при обнаружении SSH выводится предупреждение с 10-секундной паузой перед переключением.

### Шаг 4: AppArmor (apparmor)

1. Проверка текущего состояния AppArmor
2. Патч загрузчика (armbianEnv.txt / extlinux.conf):
   ```
   extraargs=apparmor=1 security=apparmor
   ```
3. Требуется перезагрузка для активации

### Шаг 5: Производительность (perf)

| Компонент | Действие |
|---|---|
| **ZRAM** | Swap в RAM с lz4 (60% RAM). Удаляет swapfile. |
| **CPU Governor** | `schedutil` (адаптивный, безопасный для пассивного охлаждения) |
| **eMMC tuning** | `vm.swappiness=10`, `noatime`, I/O scheduler, journal limits |
| **USB power** | Отключение autosuspend для USB-устройств |

### Шаг 6: Docker (docker)

1. **Попытка 1:** Установка из официального Docker-репозитория
   - GPG-ключ → `/etc/apt/keyrings/docker.asc`
   - Репозиторий → `/etc/apt/sources.list.d/docker.list`
   - `apt-get install docker-ce docker-ce-cli containerd.io`
2. **Попытка 2 (fallback):** `curl -fsSL https://get.docker.com | sh`
3. Настройка: `journald` лог-драйвер, `overlay2` storage
4. Предзагрузка Docker-образов HA в фоне

### Шаг 7: Определение версий (versions)

Запрос последних версий через GitHub API:
- `home-assistant/os-agent` → `RESOLVED_OA_VER`
- `home-assistant/supervised-installer` → `RESOLVED_HA_VER`

4 метода определения (fallback):
1. GitHub API + jq
2. curl redirect
3. curl Location header
4. wget redirect

### Шаг 8: Загрузка пакетов (download)

1. Загрузка `os-agent_X.X.X_linux_ARCH.deb`
2. Загрузка `homeassistant-supervised.deb`
3. **SHA256-верификация** каждого файла
4. Проверка целостности `.deb` через `dpkg-deb --info`
5. 3 попытки с увеличивающейся задержкой

### Шаг 9: OS-Agent (osagent)

```bash
dpkg -i os-agent.deb
```

Проверка D-Bus:
```bash
gdbus introspect --system --dest io.hass.os --object-path /io/hass/os
```

### Шаг 10: Home Assistant Supervised (ha)

1. **os-release подмена** (если нужно):
   - Armbian → `Debian GNU/Linux 12 (bookworm)`
   - Создание systemd drop-in для автоматической подмены при старте supervisor
2. Установка `homeassistant-supervised.deb` с переменной `MACHINE=...`
3. Ожидание запуска `hassio-supervisor` (до 120с)

**os-release drop-in** (`/etc/systemd/system/hassio-supervisor.service.d/fix-os-release.conf`):
```ini
[Service]
ExecStartPre=/bin/bash -c 'cp faked /etc/os-release'   # фейк при старте
ExecStopPost=/bin/bash -c 'cp original /etc/os-release' # восстановление при стопе
```

### Шаг 11: Безопасность (sec)

Подробности в разделе [13. Безопасность](#13-безопасность).

### Шаг 12: Утилиты (extras)

Подробности в разделах [9-12](#9-управление-после-установки).

### Шаг 13: HACS (hacs)

```bash
docker exec homeassistant bash -c "wget -q -O- https://get.hacs.xyz | bash -"
```

⚠️ Выполняется внешний код. Таймаут: 120с.

После установки HACS нужно:
1. Дождаться перезапуска HA
2. Перейти в **Настройки → Устройства и службы → Добавить интеграцию**
3. Найти **HACS**
4. Авторизовать через GitHub

---

## 8. КОМПОНЕНТЫ И МОДУЛИ

### 8.1. ZRAM

**Что делает:** Создаёт сжатый swap в оперативной памяти вместо файла подкачки на диске. Критически важно для eMMC/SD — продлевает срок службы.

**Настройки:**
- Алгоритм: lz4 (быстрое сжатие)
- Размер: 60% RAM
- Удаляет существующий `/swapfile`

**Проверка:**
```bash
swapon --show
# Должен показать /dev/zram0

cat /proc/swaps
zramctl
```

### 8.2. eMMC/SD Tuning

| Параметр | Значение | Зачем |
|---|---|---|
| `vm.swappiness=10` | Минимизация swap | Меньше записей на eMMC |
| `noatime` | Без обновления atime | Меньше записей |
| `commit=600` | Запись раз в 10 минут | Батчинг |
| Journal max 50MB | Ограничение логов | Экономия места |
| I/O scheduler | `mq-deadline` для eMMC/SD | Оптимальный для flash |

### 8.3. USB Power Fix

Отключает автоматическое усыпление USB-устройств. Необходимо для Zigbee/Z-Wave донглов которые иначе «засыпают».

```bash
# Проверка
cat /sys/bus/usb/devices/*/power/autosuspend
# Должно быть -1 для всех

cat /etc/udev/rules.d/99-ha-usb-power.rules
```

### 8.4. Hostname

Устанавливает hostname системы в `homeassistant`. В сочетании с avahi-daemon обеспечивает доступ по `http://homeassistant.local:8123`.

### 8.5. USB-детектирование

Автоматически находит подключённые USB-донглы:

| Устройство | Что определяется |
|---|---|
| Zigbee | CC2531, CC2652, ConBee, Sonoff |
| Z-Wave | Aeotec, Sigma Designs |
| Bluetooth | hci-интерфейс |

```bash
# Ручная проверка
ls -la /dev/serial/by-id/
dmesg | grep -i tty
```

---

## 9. УПРАВЛЕНИЕ ПОСЛЕ УСТАНОВКИ

### 9.1. Встроенные команды

| Команда | Описание |
|---|---|
| `ha-health` | Полный отчёт о состоянии системы |
| `ha-backup` | Создание резервной копии |
| `ha-restore` | Восстановление из бэкапа |
| `ha-notify "текст"` | Отправка в Telegram |
| `ha-watchdog` | Проверка доступности HA (обычно через cron) |
| `ha-cleanup` | Очистка диска при нехватке места |
| `ha-net-recovery` | Автоматическое восстановление сети |
| `ha-thermal` | Проверка температуры + уведомление |
| `ha-metrics` | Обновление Prometheus-метрик |
| `ha-boot-check` | Проверка после загрузки |
| `ha-backup-remote` | Копирование бэкапа на удалённый сервер |

### 9.2. ha-health

```bash
sudo ha-health
```

Вывод:
```
===== HA Health (Sun Jun 15 14:32:00 UTC 2025) =====
  Host:        homeassistant
  IP:          192.168.1.100
  Up:          up 3 days, 2 hours
  Kernel:      6.1.63-current-meson64
  OS:          Debian GNU/Linux 12 (bookworm)
  CPU:         42°C
  RAM:         1.2G/3.8G
  Swap:        0B/2.3G
  Disk:        12G/29G (42%)
── Containers ──
  homeassistant: Up 3 days
  hassio_supervisor: Up 3 days
  hassio_dns: Up 3 days
  hassio_cli: Up 3 days
  hassio_audio: Up 3 days
  hassio_multicast: Up 3 days
  hassio_observer: Up 3 days
  HA:          200
=========================
```

### 9.3. Диагностика установки

```bash
sudo ./install.sh --check
```

Показывает:
- Состояние всех компонентов (Docker, OS-Agent, Supervisor, HA Core)
- AppArmor, os-release
- Ресурсы (RAM, Swap, Disk)
- Контейнеры и их статусы
- Выполненные шаги установки
- Доступные обновления

### 9.4. Live-мониторинг

```bash
sudo ./install.sh --status
```

Обновляется каждые 5 секунд. Показывает IP, CPU, RAM, контейнеры, доступность HA. `Ctrl+C` для выхода.

### 9.5. Cron-задачи

Автоматически настраиваются в `/etc/cron.d/ha-tools`:

| Расписание | Задача |
|---|---|
| Каждые 5 мин | `ha-watchdog` — проверка HA |
| Каждые 10 мин | `ha-net-recovery` — проверка сети |
| Каждые 5 мин | `ha-thermal` — температура |
| 03:30 ежедневно | `ha-cleanup` — очистка |
| 04:00 воскресенье | `ha-backup` — бэкап |
| 04:30 воскресенье | `ha-backup-remote` — удалённый бэкап |
| Каждую минуту | `ha-metrics` — Prometheus |

```bash
# Посмотреть текущие задачи
cat /etc/cron.d/ha-tools

# Проверить работу cron
grep ha- /var/log/syslog | tail -20
```

---

## 10. БЭКАП И ВОССТАНОВЛЕНИЕ

### 10.1. Автоматический бэкап

Еженедельно (воскресенье, 04:00) создаётся сжатый архив конфигурации HA.

**Что входит в бэкап:**
- `/usr/share/hassio/homeassistant/` — вся конфигурация
- YAML-файлы, автоматизации, скрипты, кастомные компоненты

**Что НЕ входит:**
- База данных (`*.db`, `home-assistant_v2.db`) — она пересоздаётся
- Кэш (`deps/`, `__pycache__/`, `tts/`)

**Куда сохраняется:**
```
/var/backups/homeassistant/ha_config_20250615_040000.tar.gz
```

**Хранение:** 30 дней. Старые автоматически удаляются.

**Сжатие:** `pigz` (параллельный gzip) если установлен, иначе обычный `gzip`.

### 10.2. Ручной бэкап

```bash
sudo ha-backup
```

### 10.3. Восстановление

```bash
sudo ha-restore
```

Интерактивное меню:
```
  1) ha_config_20250615_040000.tar.gz (45M)
  2) ha_config_20250608_040000.tar.gz (43M)
  3) ha_config_20250601_040000.tar.gz (42M)
# 1
OK? (yes/no) yes
Проверка архива...
Бэкап текущего...
Восстановление...
Done!
```

**Безопасность восстановления:**
1. Архив проверяется на целостность (`tar tzf`)
2. Создаётся бэкап текущего состояния (`ha_pre_restore_...`)
3. HA останавливается перед восстановлением
4. HA запускается после восстановления

### 10.4. Удалённый бэкап

Если при установке был выбран удалённый бэкап, последний локальный архив копируется на удалённый сервер:

```bash
# SSH/SCP
sudo ha-backup-remote

# Настройка адреса: при установке или в /usr/local/bin/ha-backup-remote
```

### 10.5. Ручные операции

```bash
# Посмотреть бэкапы
ls -lh /var/backups/homeassistant/

# Ручное копирование
scp /var/backups/homeassistant/ha_config_*.tar.gz user@backup-server:/backups/

# Ручное восстановление (без интерактивного меню)
sudo docker stop homeassistant
sudo tar xzf /var/backups/homeassistant/ha_config_20250615_040000.tar.gz -C /usr/share/hassio/
sudo docker start homeassistant
```

---

## 11. МОНИТОРИНГ И WATCHDOG

### 11.1. Watchdog с exponential backoff

**Как работает:**

1. Каждые 5 минут проверяет HTTP-код `http://localhost:8123`
2. При `000` (нет ответа) увеличивает счётчик
3. После 3 сбоев подряд → `docker restart homeassistant`
4. Следующий рестарт через увеличенный интервал:
   - 1-й: через 5 мин
   - 2-й: через 10 мин
   - 3-й: через 20 мин
   - 4-й: через 40 мин
   - 5-й+: через 60 мин (максимум)
5. При восстановлении backoff сбрасывается

**Grace period:** 20 минут после установки (файл `/tmp/.ha_just_installed`) watchdog не трогает HA.

```bash
# Статус watchdog
cat /tmp/ha_wd_state
# Формат: fails|last_restart_timestamp|backoff_minutes

# Ручной запуск
sudo ha-watchdog
```

### 11.2. Мониторинг температуры

Каждые 5 минут проверяет CPU:
- ≥ 70°C → уведомление 🌡️
- ≥ 80°C → уведомление 🔥

```bash
# Текущая температура
cat /sys/class/thermal/thermal_zone0/temp
# Делить на 1000 для °C

# Или через скрипт
sudo ha-thermal
```

### 11.3. Автоочистка диска

Ежедневно в 03:30 проверяет свободное место. Если < 1500 MB:
1. `docker system prune -f` — удаление неиспользуемых образов
2. `journalctl --vacuum-size=30M` — обрезка логов
3. `apt-get clean` — очистка кэша пакетов
4. Telegram-уведомление о результате

```bash
# Ручной запуск
sudo ha-cleanup
```

### 11.4. Восстановление сети

Каждые 10 минут проверяет сеть:
1. Пинг шлюза
2. Пинг 8.8.8.8
3. При недоступности → перезапуск NetworkManager
4. Уведомление о результате

### 11.5. Prometheus-метрики

При включённом мониторинге экспортируются метрики для Prometheus:

```bash
cat /var/lib/prometheus/node-exporter/ha.prom
```

Метрики:

| Метрика | Описание |
|---|---|
| `ha_up` | 1 = HA доступен, 0 = нет |
| `ha_containers_running` | Количество HA-контейнеров |
| `ha_cpu_temp` | Температура CPU (°C) |
| `ha_disk_free_bytes` | Свободное место на корневом разделе |

**Интеграция с Prometheus:**

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'node'
    static_configs:
      - targets: ['homeassistant:9100']
    # Метрики HA подхватываются через node_exporter textfile collector
```

### 11.6. Boot Recovery

Systemd-сервис `ha-boot-check.service` выполняется при каждой загрузке:

1. Ждёт 30 секунд (инициализация)
2. Проверяет dmesg на ошибки файловой системы
3. Проверяет Docker, перезапускает при необходимости
4. Проверяет hassio-supervisor, перезапускает при необходимости
5. Отправляет уведомление если потребовалось вмешательство

```bash
# Статус
systemctl status ha-boot-check

# Логи
journalctl -u ha-boot-check
```

### 11.7. Telegram-уведомления

При включении отправляются уведомления:

| Событие | Сообщение |
|---|---|
| Установка | ✅ HA: http://IP:8123 |
| Watchdog restart | ⚠️ WD #3 (5m) |
| Сеть восстановлена | 🌐 OK |
| Сеть потеряна | 🔴 Нет сети |
| Перегрев | 🔥 82°C! |
| Очистка диска | 🧹 1200→2800MB |
| Бэкап | 💾 45M |
| Boot recovery | 🔄 Supervisor restarted |

**Настройка Telegram-бота:**

1. Найдите `@BotFather` в Telegram
2. `/newbot` → получите токен `123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11`
3. Напишите боту `/start`
4. Найдите Chat ID: `https://api.telegram.org/bot<TOKEN>/getUpdates`
5. Введите токен и chat_id при установке

---

## 12. СЕТЬ И REVERSE PROXY

### 12.1. NetworkManager

После установки вся сеть управляется через NetworkManager:

```bash
# Текущие соединения
nmcli con show

# Текущий IP
nmcli -t -f IP4.ADDRESS dev show eth0

# Изменить DNS
nmcli con mod "Wired connection 1" ipv4.dns "8.8.8.8,1.1.1.1"
nmcli con up "Wired connection 1"
```

### 12.2. Статический IP

Если настроен при установке:

```bash
# Проверка
nmcli con show --active

# Изменить
nmcli con mod "Wired connection 1" \
    ipv4.addresses "192.168.1.100/24" \
    ipv4.gateway "192.168.1.1" \
    ipv4.dns "8.8.8.8,1.1.1.1" \
    ipv4.method manual
nmcli con up "Wired connection 1"
```

### 12.3. mDNS (Avahi)

После установки HA доступен по `http://homeassistant.local:8123`.

```bash
# Проверка
avahi-resolve -n homeassistant.local

# Статус
systemctl status avahi-daemon
```

### 12.4. Reverse Proxy с SSL

Если включён при установке, настраивается:

1. **Nginx** как reverse proxy на порту 80/443
2. **Let's Encrypt** SSL-сертификат через certbot
3. **Автоматический redirect** HTTP → HTTPS

```
Интернет → https://ha.example.com:443 → Nginx → http://127.0.0.1:8123 → HA
```

**Необходимо:**
- Домен, указывающий на IP сервера (A-запись)
- Порты 80 и 443 открыты на роутере

```bash
# Проверка
sudo nginx -t
curl -I https://ha.example.com

# Обновление сертификата (автоматическое через certbot)
sudo certbot renew

# Логи
sudo tail -f /var/log/nginx/error.log
```

**Настройка HA для работы через proxy:**

Добавьте в `configuration.yaml`:
```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 127.0.0.1
```

---

## 13. БЕЗОПАСНОСТЬ

### 13.1. UFW (Uncomplicated Firewall)

Открытые порты:

| Порт | Протокол | Сервис |
|---|---|---|
| 22 | TCP | SSH |
| 8123 | TCP | Home Assistant |
| 4357 | TCP | ESPHome |
| 5353 | UDP | mDNS |
| 5683 | UDP | HomeKit |
| 443 | TCP | HTTPS (если proxy) |

```bash
# Статус
sudo ufw status verbose

# Добавить порт
sudo ufw allow 1883/tcp comment "MQTT"

# Удалить правило
sudo ufw delete allow 1883/tcp
```

### 13.2. DOCKER-USER iptables правила

Блокируют прямой доступ к Docker-контейнерам из интернета, разрешая только локальные сети:

```
10.0.0.0/8      → RETURN (разрешить)
172.16.0.0/12   → RETURN (разрешить)
192.168.0.0/16  → RETURN (разрешить)
остальное       → DROP (заблокировать)
```

### 13.3. Fail2Ban

Защита SSH от brute-force:

| Параметр | Значение |
|---|---|
| Максимум попыток | 5 |
| Время бана | 1 час (3600с) |
| Окно поиска | 10 минут (600с) |

```bash
# Статус
sudo fail2ban-client status sshd

# Разблокировать IP
sudo fail2ban-client set sshd unbanip 1.2.3.4

# Логи
sudo tail -f /var/log/fail2ban.log
```

### 13.4. SSH Hardening

Файл: `/etc/ssh/sshd_config.d/99-ha-hardening.conf`

```
PermitRootLogin prohibit-password    # Только по ключу
MaxAuthTries 3                       # Макс попыток
ClientAliveInterval 300              # Keepalive 5 мин
ClientAliveCountMax 2                # 2 попытки keepalive
X11Forwarding no                     # Без X11
```

### 13.5. Автообновления безопасности

Автоматически устанавливаются обновления безопасности:

```bash
# Проверка
sudo unattended-upgrades --dry-run

# Логи
cat /var/log/unattended-upgrades/unattended-upgrades.log
```

### 13.6. os-release подмена

Для Armbian и других non-Debian дистрибутивов:

- **При старте** hassio-supervisor → подставляется фейковый os-release с `PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"`
- **При стопе** → восстанавливается оригинал
- Оригинал хранится в `/var/lib/ha-installer/backup/os-release.original`
- Симлинк `/etc/os-release` корректно обрабатывается

---

## 14. ОБНОВЛЕНИЕ

### 14.1. Обновление HA + OS-Agent

```bash
sudo ./install.sh --update
```

Что происходит:
1. Проверка текущих и последних версий
2. Загрузка новых `.deb` с SHA256-верификацией
3. Установка OS-Agent (если обновился)
4. Установка HA Supervised (если обновился)
5. Обновление конфига

### 14.2. Обновление скрипта

```bash
sudo ./install.sh --self-update
```

1. Проверка последней версии на GitHub
2. Загрузка нового скрипта
3. Проверка валидности (`bash -n`)
4. Замена текущего скрипта

### 14.3. Обновление HA Core

HA Core обновляется через веб-интерфейс:

1. **Настройки → Система → Обновления**
2. Или: **Supervisor → Dashboard → Update**

### 14.4. Обновление ОС

```bash
sudo apt update && sudo apt upgrade -y
```

Или автоматически через `unattended-upgrades` (если включён).

---

## 15. УДАЛЕНИЕ

### 15.1. Полное удаление

```bash
sudo ./install.sh --uninstall
```

**Что удаляется:**
- Все HA-контейнеры и образы
- Сервисы hassio-supervisor, hassio-apparmor, ha-boot-check
- Пакеты homeassistant-supervised, os-agent
- Утилиты (ha-*, /etc/cron.d/ha-tools)
- Правила UFW для Docker
- SSH hardening конфиг
- Sysctl и journald тюнинг
- udev правила
- Nginx конфигурация (если был proxy)
- os-release восстанавливается

**Что НЕ удаляется (спрашивает):**
- `/usr/share/hassio/` — данные HA (конфигурация, базы)
- `/var/backups/homeassistant/` — бэкапы

**Что НЕ удаляется:**
- Docker Engine
- NetworkManager
- Установленные зависимости

### 15.2. Полная очистка (включая Docker)

```bash
sudo ./install.sh --uninstall
# Ответить "yes" на все вопросы

# Дополнительно:
sudo apt remove -y docker-ce docker-ce-cli containerd.io
sudo rm -rf /var/lib/docker
sudo rm -rf /etc/docker
```

---

## 16. ДИАГНОСТИКА И ОТЛАДКА

### 16.1. Логи

```bash
# Лог установки
ls -la /var/log/ha_install_*.log
cat /var/log/ha_install_20250615_143200.log

# Лог HA Supervisor
journalctl -u hassio-supervisor -f

# Лог Docker
journalctl -u docker -f

# Лог контейнера HA
docker logs homeassistant --tail 100 -f

# Лог Fail2Ban
cat /var/log/fail2ban.log

# Лог Nginx (если proxy)
tail -f /var/log/nginx/error.log
```

### 16.2. Состояние сервисов

```bash
# Все HA-сервисы
systemctl status hassio-supervisor
systemctl status hassio-apparmor
systemctl status ha-boot-check
systemctl status docker
systemctl status NetworkManager
systemctl status avahi-daemon
systemctl status fail2ban
systemctl status ufw
systemctl status nginx  # если proxy
```

### 16.3. Docker

```bash
# Контейнеры
docker ps -a

# Образы
docker images

# Использование диска
docker system df

# Логи контейнера
docker logs hassio_supervisor --tail 50

# Перезапуск контейнера
docker restart homeassistant

# Зайти внутрь контейнера
docker exec -it homeassistant bash
```

### 16.4. Сеть

```bash
# IP-адреса
ip addr show

# Маршруты
ip route show

# DNS
resolvectl status

# Порты
ss -tlnp

# Проверка HA
curl -s -o /dev/null -w "%{http_code}" http://localhost:8123

# Проверка mDNS
avahi-browse -alr
```

### 16.5. Самотестирование

```bash
sudo ./install.sh --self-test
```

Проверяет:
- `validate_ip()` — 7 тестов
- `detect_arch()` — определение архитектуры
- `mark_done/is_done` — система состояний
- `apply_profile` — система профилей

### 16.6. Dry-run

```bash
sudo ./install.sh --profile standard --dry-run
```

Показывает все действия без их выполнения.

---

## 17. СТРУКТУРА ФАЙЛОВ

### Файлы конфигурации

```
/var/lib/ha-installer/
├── state                    # Состояние шагов (step|timestamp|version)
├── config                   # Конфигурация установки
└── backup/
    ├── os-release.original  # Оригинальный os-release
    ├── os-release.symlink   # Путь симлинка (если был)
    ├── os-release.faked     # Фейковый os-release
    ├── interfaces.bak       # Бэкап /etc/network/interfaces
    ├── resolv.conf.bak      # Бэкап resolv.conf
    ├── sshd_config.bak      # Бэкап SSH
    ├── fstab.bak            # Бэкап fstab
    ├── armbianEnv.txt.bak   # Бэкап загрузчика
    └── extlinux.conf.bak    # Бэкап загрузчика
```

### Утилиты

```
/usr/local/bin/
├── ha-health              # Отчёт о состоянии
├── ha-backup              # Создание бэкапа
├── ha-restore             # Восстановление
├── ha-backup-remote       # Удалённый бэкап
├── ha-notify              # Telegram-уведомления
├── ha-watchdog            # Мониторинг доступности
├── ha-cleanup             # Очистка диска
├── ha-net-recovery        # Восстановление сети
├── ha-thermal             # Мониторинг температуры
├── ha-metrics             # Prometheus-метрики
└── ha-boot-check          # Проверка после загрузки
```

### Системные файлы

```
/etc/
├── cron.d/ha-tools                              # Cron-задачи
├── docker/daemon.json                           # Конфиг Docker
├── NetworkManager/conf.d/
│   ├── 10-ha-managed.conf                       # NM: управление всеми интерфейсами
│   └── 10-dns-resolved.conf                     # NM: DNS через systemd-resolved
├── sysctl.d/99-ha-swap.conf                     # Swappiness
├── systemd/
│   ├── journald.conf.d/ha-tuning.conf           # Лимиты журнала
│   └── system/
│       ├── ha-boot-check.service                # Boot recovery сервис
│       └── hassio-supervisor.service.d/
│           └── fix-os-release.conf              # os-release drop-in
├── udev/rules.d/99-ha-usb-power.rules           # USB autosuspend
├── ssh/sshd_config.d/99-ha-hardening.conf       # SSH hardening
├── fail2ban/jail.local                          # Fail2Ban конфиг
├── apt/apt.conf.d/
│   ├── 50unattended-upgrades                    # Автообновления
│   └── 20auto-upgrades                          # Расписание обновлений
├── nginx/sites-available/homeassistant          # Reverse proxy (если включён)
└── ufw/after.rules                              # UFW правила для Docker

/var/
├── backups/homeassistant/                       # Бэкапы конфигурации HA
│   ├── ha_config_20250615_040000.tar.gz
│   └── ha_pre_restore_20250616_120000.tar.gz
├── lib/prometheus/node-exporter/ha.prom         # Prometheus-метрики
└── log/ha_install_*.log                         # Логи установки

/usr/share/hassio/                               # Данные HA (Docker volumes)
├── homeassistant/                               # Конфигурация HA
│   ├── configuration.yaml
│   ├── automations.yaml
│   └── ...
└── ...
```

### Формат state-файла

```
preflight|1718451120|8.0
update|1718451180|8.0
deps|1718451300|8.0
network|1718451360|8.0
apparmor|1718451380|8.0
perf|1718451400|8.0
docker|1718451520|8.0
versions|1718451530|8.0
download|1718451570|8.0
osagent|1718451590|8.0
ha|1718451820|8.0
sec|1718451860|8.0
extras|1718451900|8.0
hacs|1718452020|8.0
```

### Формат config-файла

```bash
INSTALLED_VERSION="8.0"
INSTALLED_DATE="2025-06-15T14:32:00+00:00"
HA_MACHINE="qemuarm-64"
OA_VERSION="1.6.0"
HA_VERSION="1.7.0"
OS_RELEASE_FAKED=true
BACKUP_DIR="/var/backups/homeassistant"
OPT_ZRAM=true
OPT_UFW=true
OPT_WATCHDOG=true
OPT_THERMAL=true
OPT_BACKUP=true
OPT_HACS=true
OPT_MONITORING=false
PROFILE="standard"
```

---

## 18. FAQ

### Q: Сколько времени занимает установка?

**A:** 10-25 минут в зависимости от скорости интернета и мощности устройства. Основное время — загрузка Docker-образов.

### Q: Можно ли установить на Ubuntu?

**A:** Скрипт автоматически подменяет os-release на Debian для совместимости с HA Supervised. Однако **официально поддерживается только Debian/Armbian**. Ubuntu может работать, но не гарантируется.

### Q: Что делать если установка прервалась?

**A:** Просто запустите скрипт повторно. Он определит выполненные шаги и продолжит с места остановки.

### Q: Как вернуться к чистой системе?

**A:**
```bash
sudo ./install.sh --uninstall
# Ответить "yes" на все вопросы
```

### Q: Будет ли работать на SD-карте?

**A:** Да, но рекомендуется eMMC или NVMe. ZRAM и eMMC-tuning значительно продлевают срок службы SD-карты.

### Q: Как добавить Zigbee-донгл?

**A:**
1. Подключите донгл
2. Проверьте: `ls /dev/serial/by-id/`
3. В HA: Настройки → Устройства → Добавить интеграцию → ZHA или Zigbee2MQTT

### Q: Как получить доступ извне?

**A:** Варианты:
1. **Reverse Proxy + SSL** (включить при установке)
2. **Nabu Casa** (подписка, проще всего)
3. **VPN** (WireGuard)
4. **Port forwarding** на роутере (не рекомендуется)

### Q: Можно ли перенести на другое устройство?

**A:**
1. `sudo ha-backup` на старом
2. Скопировать `/var/backups/homeassistant/ha_config_*.tar.gz` на новое
3. Установить HA на новом: `sudo ./install.sh --profile standard`
4. `sudo ha-restore` на новом

### Q: Как обновить HA Core?

**A:** Через веб-интерфейс: Настройки → Система → Обновления. Или через CLI: `ha core update`.

### Q: AppArmor не активен после установки?

**A:** Требуется перезагрузка: `sudo reboot`. Проверка: `cat /sys/module/apparmor/parameters/enabled` → должно быть `Y`.

### Q: Можно ли изменить профиль после установки?

**A:**
```bash
sudo ./install.sh --reset-state
sudo ./install.sh --profile full
```

---

## 19. РЕШЕНИЕ ПРОБЛЕМ

### Проблема: HA не запускается

```bash
# Проверка
systemctl status hassio-supervisor
docker logs hassio_supervisor --tail 50
docker ps -a | grep -i hass

# Решение 1: перезапуск
systemctl restart hassio-supervisor

# Решение 2: перезапуск Docker
systemctl restart docker
# Подождать 2 минуты
systemctl restart hassio-supervisor

# Решение 3: полный перезапуск
sudo reboot
```

### Проблема: "Unsupported system" в HA

```bash
# Причина: os-release не содержит Debian
# Проверка
cat /etc/os-release | grep PRETTY_NAME

# Решение: проверить drop-in
cat /etc/systemd/system/hassio-supervisor.service.d/fix-os-release.conf

# Если файла нет — пересоздать
sudo ./install.sh --reset-state
sudo ./install.sh --profile standard
```

### Проблема: Нет интернета после установки

```bash
# Проверка
ip addr show
ip route show
ping 8.8.8.8

# Решение 1: ручной запуск recovery
sudo ha-net-recovery

# Решение 2: откат сети
sudo cp /var/lib/ha-installer/backup/interfaces.bak /etc/network/interfaces
sudo cp /var/lib/ha-installer/backup/resolv.conf.bak /etc/resolv.conf
sudo systemctl restart NetworkManager

# Решение 3: ручная настройка
nmcli con show
nmcli con mod "Wired connection 1" ipv4.method auto
nmcli con up "Wired connection 1"
```

### Проблема: Docker не запускается

```bash
# Проверка
systemctl status docker
journalctl -u docker --no-pager | tail -30

# Решение 1
systemctl restart docker

# Решение 2: проверка хранилища
df -h /var/lib/docker
# Если заполнено:
docker system prune -af

# Решение 3: переустановка Docker
apt-get remove -y docker-ce docker-ce-cli containerd.io
curl -fsSL https://get.docker.com | sh
```

### Проблема: Порт 8123 занят

```bash
# Кто занимает
ss -tlnp | grep 8123

# Если другой HA
docker stop homeassistant
docker rm homeassistant
systemctl restart hassio-supervisor
```

### Проблема: Не хватает места

```bash
# Проверка
df -h /

# Очистка
sudo ha-cleanup
sudo docker system prune -af
sudo journalctl --vacuum-size=50M
sudo apt-get clean
sudo apt-get autoremove -y
```

### Проблема: SSL-сертификат не выдаётся

```bash
# Проверка DNS
dig ha.example.com

# Проверка портов
ss -tlnp | grep -E ':80|:443'

# Ручной запуск certbot
sudo certbot --nginx -d ha.example.com -v

# Частые причины:
# 1. DNS не указывает на сервер
# 2. Порт 80 закрыт на роутере
# 3. Firewall блокирует
sudo ufw allow 80/tcp
```

### Проблема: Fail2Ban не работает

```bash
# Проверка
systemctl status fail2ban
fail2ban-client status

# На Trixie — нужен backend=systemd
cat /etc/fail2ban/jail.local
# Должно быть: backend=systemd

# Перезапуск
systemctl restart fail2ban
```

---

## 20. ПОДДЕРЖИВАЕМЫЕ ПЛАТФОРМЫ

### Тестировано

| Платформа | ОС | Статус |
|---|---|---|
| Raspberry Pi 4 4GB | Raspberry Pi OS 12 | ✅ |
| Raspberry Pi 5 8GB | Raspberry Pi OS 12 | ✅ |
| ODROID-N2+ | Armbian Bookworm | ✅ |
| Amlogic S905X3 TV-бокс | Armbian Bookworm | ✅ |
| Amlogic S922X (Khadas VIM3) | Armbian Bookworm | ✅ |
| x86_64 Mini PC | Debian 12 | ✅ |
| x86_64 VM | Debian 12 | ✅ |
| Rockchip RK3588 | Armbian Bookworm | ✅ |
| Allwinner H6 | Armbian Bookworm | ⚠️ (1GB RAM) |

### Debian 13 Trixie

Поддерживается с автоматической обработкой:
- iptables-nft (вместо legacy)
- Fail2Ban с backend=systemd
- os-release mapping trixie → Debian 13

### Armbian

Полная поддержка с учётом:
- armbian-zram-config → не ставим свой ZRAM
- armbian-ramlog → не трогаем journald
- armbian-hardware-optimization → не меняем CPU governor
- os-release подмена → Debian

---

*Документация для HA Installer v8.0. Последнее обновление: июнь 2025.*
