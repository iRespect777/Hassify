# 📖 Home Assistant Supervised Installer v4.1
## Содержание
```
 1. Обзор
 2. Что устанавливается
 3. Требования
 4. Быстрый старт
 5. Пошаговая инструкция
 6. Все опции командной строки
 7. Что делает скрипт (детально по шагам)
 8. Маскировка os-release
 9. Дополнительные утилиты
10. Управление Home Assistant
11. Обновление Home Assistant
12. Удаление
13. Файлы и директории
14. Troubleshooting
15. FAQ
```

---

## 1. Обзор

Скрипт выполняет **полную автоматическую установку Home Assistant Supervised** на TV-бокс **X96Q** и аналогичные устройства на базе Allwinner H616/H313 с Armbian Bookworm.

**Ключевые особенности:**

- Автоматическая установка всех компонентов HA Supervised
- Маскировка Armbian под Debian 12 (только для проверок HA)
- Продолжение с места остановки при сбое или обрыве SSH
- Оптимизация для TV-бокса (eMMC/SD, swap, журнал)
- Watchdog — автоперезапуск HA при зависании
- Автоочистка диска при нехватке места
- Telegram-уведомления о проблемах
- mDNS — доступ по `homeassistant.local`
- Автоопределение типа устройства
- Полное удаление одной командой

---

## 2. Что устанавливается

```
┌─────────────────────────────────────────────────┐
│           Home Assistant (веб :8123)            │
├─────────────────────────────────────────────────┤
│        Аддоны (Supervisor, Docker)              │
├─────────────────────────────────────────────────┤
│          HA Supervisor (Docker)                 │
├─────────────────────────────────────────────────┤
│             Docker CE                           │
├─────────────────────────────────────────────────┤
│  OS-Agent │ AppArmor │ NetworkManager │ Avahi   │
├─────────────────────────────────────────────────┤
│    Armbian Bookworm (замаскирован под Debian)    │
├─────────────────────────────────────────────────┤
│        X96Q / Allwinner H616 (aarch64)          │
└─────────────────────────────────────────────────┘
```

**Компоненты:**

| Компонент | Назначение |
|-----------|------------|
| Docker CE | Контейнерная платформа для HA |
| OS-Agent | Связь между хост-системой и HA |
| HA Supervised | Supervisor + Core + аддоны |
| NetworkManager | Управление сетью (требование HA) |
| systemd-resolved | DNS (требование HA) |
| AppArmor | Безопасность (требование HA) |
| Avahi (mDNS) | Доступ по имени .local |
| bluez | Bluetooth для IoT |

**Утилиты (опционально):**

| Утилита | Назначение |
|---------|------------|
| `ha-health` | Быстрая диагностика системы |
| `ha-watchdog` | Автоперезапуск HA при зависании |
| `ha-cleanup` | Автоочистка диска |
| `ha-notify` | Отправка уведомлений в Telegram |

---

## 3. Требования

### Минимальные

| Параметр | Значение |
|----------|----------|
| Устройство | X96Q или аналог на Allwinner H616/H313 |
| Архитектура | aarch64 (ARM64) |
| ОС | Armbian Bookworm (на базе Debian 12) |
| Ядро | ≥ 5.x |
| Init | systemd |
| RAM | ≥ 768 МБ (с обязательным swap) |
| Диск | ≥ 4 ГБ свободно |
| Интернет | Обязателен |

### Рекомендуемые

| Параметр | Значение |
|----------|----------|
| RAM | 2 ГБ |
| Диск | 16+ ГБ eMMC или SD |
| cgroup | v2 |
| Соединение | Ethernet (стабильнее Wi-Fi) |

### Поддерживаемые устройства

Скрипт автоматически определяет тип устройства:

| Устройство | Тип машины HA |
|------------|---------------|
| X96Q и другие TV-боксы | `qemuarm-64` |
| Raspberry Pi 5 | `raspberrypi5-64` |
| Raspberry Pi 4 | `raspberrypi4-64` |
| Raspberry Pi 3 | `raspberrypi3-64` |
| ODROID-N2 | `odroid-n2` |
| ODROID-C4 | `odroid-c4` |
| Khadas VIM3 | `khadas-vim3` |
| Любой aarch64 | `qemuarm-64` |

---

## 4. Быстрый старт

### Шаг 1 — Скачать скрипт

```bash
wget -O install_ha.sh https://github.com/iRespect777/HAS-tvbox/blob/main/install_ha.sh
```

Или создать вручную:

```bash
nano install_ha.sh
# Вставить содержимое скрипта
# Ctrl+O → Enter → Ctrl+X
```

### Шаг 2 — Сделать исполняемым

```bash
chmod +x install_ha.sh
```

### Шаг 3 — Запустить

```bash
sudo bash install_ha.sh
```

### Шаг 4 — Следовать инструкциям

Скрипт покажет:
1. Информацию о системе
2. Результаты проверок
3. План установки
4. Запросит подтверждение

После подтверждения — полностью автоматическая установка.

### Шаг 5 — Открыть HA

```
http://<IP-адрес>:8123
http://homeassistant.local:8123  (если настроен mDNS)
```

> ⚠️ Первая загрузка интерфейса занимает до 20 минут

---

## 5. Пошаговая инструкция

### Подготовка

**1. Установите Armbian Bookworm на X96Q:**

```bash
# Скачайте образ Armbian Bookworm для вашего TV-бокса
# Запишите на SD-карту или eMMC
# Загрузитесь с неё
```

**2. Подключитесь по SSH:**

```bash
ssh root@<IP-адрес-приставки>
# Пароль по умолчанию: 1234 (Armbian попросит сменить)
```

**3. Убедитесь что система обновлена:**

```bash
apt update && apt upgrade -y
reboot
```

**4. Подключитесь снова и проверьте:**

```bash
uname -m          # Должно быть: aarch64
cat /etc/os-release  # Должен быть bookworm
```

### Установка

**5. Скачайте и запустите скрипт:**

```bash
wget -O install_ha.sh https://your-url/install_ha.sh
sudo bash install_ha.sh
```

**6. Скрипт покажет баннер с информацией о системе:**

```
    ╦ ╦┌─┐┌┬┐┌─┐  ╔═╗┌─┐┌─┐┬┌─┐┌┬┐┌─┐┌┐┌┌┬┐
    ╠═╣│ ││││├┤   ╠═╣└─┐└─┐│└─┐ │ ├─┤│││ │
    ...

    ⚙  Устройство:   X96Q
    ⚙  Ядро:         6.1.xx
    ⚙  ОС:           Armbian 24.x Bookworm
    ⚙  RAM:          924M
    ⚙  Диск /:       14G (свободно: 10G)
    ⚙  Температура:  45°C
```

**7. Пройдут проверки совместимости:**

```
 ✔  Запуск от root
 ✔  Архитектура: aarch64
 ✔  Init: systemd
 ✔  Ядро: 6.1.xx
 ✔  Кодовое имя: bookworm
 ✔  Интернет: доступен
 ✔  Свободно: 10240 МБ
 ✔  RAM: 924 МБ
 ✔  cgroup: v2
 ✔  Модуль: overlay
 ✔  Модуль: br_netfilter
```

**8. Покажется план установки — подтвердите:**

```
  ℹ  План:
      ➜ Обновление системы
      ➜ Зависимости (20 пакетов)
      ➜ NetworkManager + systemd-resolved
      ➜ AppArmor
      ➜ Swap
      ➜ Docker
      ➜ OS-Agent
      ➜ Маскировка + HA Supervised (qemuarm-64)
      ➜ Оптимизация eMMC/SD
      ➜ Watchdog + очистка + mDNS + Telegram
      ➜ Health-check

  Начать? [y/N]: y
```

**9. Дождитесь завершения:**

Установка занимает **15–40 минут** в зависимости от скорости интернета.

Во время шага 10 скрипт спросит:
- Сменить ли hostname на `homeassistant` (для mDNS)
- Настроить ли Telegram-уведомления

**10. После установки откройте браузер:**

```
http://<IP-адрес>:8123
```

Увидите:
```
Preparing Home Assistant
This can take up to 20 minutes...
```

Затем — мастер создания аккаунта.

### Если нужна перезагрузка

Если AppArmor не был активен, скрипт предложит перезагрузку:

```
  ⚠  НУЖНА ПЕРЕЗАГРУЗКА (AppArmor)

  Перезагрузить? [y/N]: y
```

После перезагрузки HA запустится автоматически.

---

## 6. Все опции командной строки

### Справка

```bash
sudo bash install_ha.sh --help
```

### Основные режимы

| Команда | Описание |
|---------|----------|
| `sudo bash install_ha.sh` | Полная установка |
| `sudo bash install_ha.sh --check` | Только проверки (ничего не устанавливает) |
| `sudo bash install_ha.sh --uninstall` | Удаление Home Assistant |
| `sudo bash install_ha.sh --dry-run` | Предпросмотр (показывает что будет сделано) |

### Настройка установки

| Опция | Описание |
|-------|----------|
| `--skip-swap` | Не создавать swap-файл |
| `--skip-update` | Не обновлять систему (apt upgrade) |
| `--skip-optimize` | Не оптимизировать eMMC/SD |
| `--skip-extras` | Не устанавливать watchdog, mDNS, Telegram |
| `--swap-size 4096` | Задать размер swap в МБ (по умолчанию: авто) |
| `--machine raspberrypi4-64` | Задать тип машины HA (по умолчанию: авто) |
| `--no-wait` | Не ждать запуска HA после установки |
| `--log /root/install.log` | Задать путь к лог-файлу |
| `--reset-state` | Сбросить прогресс (начать установку заново) |

### Примеры

```bash
# Проверить совместимость перед установкой
sudo bash install_ha.sh --check

# Посмотреть что будет сделано (без выполнения)
sudo bash install_ha.sh --dry-run

# Минимальная установка (без доп. утилит и swap)
sudo bash install_ha.sh --skip-swap --skip-extras --skip-optimize

# Быстрая установка (без обновления и ожидания)
sudo bash install_ha.sh --skip-update --no-wait

# Swap 4 ГБ, лог в файл
sudo bash install_ha.sh --swap-size 4096 --log /root/ha_install.log

# Для Raspberry Pi 4
sudo bash install_ha.sh --machine raspberrypi4-64

# Начать установку с нуля (сбросить прогресс)
sudo bash install_ha.sh --reset-state
sudo bash install_ha.sh

# Удалить HA
sudo bash install_ha.sh --uninstall
```

---

## 7. Что делает скрипт (детально по шагам)

### Шаг 1/11 — Обновление системы

```
apt-get update
apt-get upgrade
apt-get autoremove
```

Пропуск: `--skip-update`

### Шаг 2/11 — Зависимости

Устанавливает 20 пакетов:

```
apparmor          — система безопасности (требование HA)
avahi-daemon      — mDNS (homeassistant.local)
bluez             — Bluetooth для IoT-устройств
ca-certificates   — SSL-сертификаты
cifs-utils        — поддержка сетевых дисков SMB
curl              — HTTP-клиент
dbus              — межпроцессное взаимодействие
gnupg             — ключи репозиториев
jq                — парсинг JSON
libglib2.0-bin    — библиотека для OS-Agent
lsb-release       — информация о дистрибутиве
network-manager   — управление сетью (требование HA)
nfs-common        — поддержка сетевых дисков NFS
software-properties-common — управление репозиториями
systemd-journal-remote     — удалённый журнал
systemd-resolved  — DNS (требование HA)
systemd-timesyncd — синхронизация времени
udisks2           — управление дисками
usbutils          — утилиты USB (lsusb)
wget              — загрузчик файлов
```

### Шаг 3/11 — Сеть

- Создаёт конфигурацию NetworkManager
- Переключает управление сетью с `networking.service` на `NetworkManager`
- Включает `systemd-resolved` и настраивает DNS

> ⚠️ Может кратковременно прервать SSH-соединение. При повторном запуске шаг будет пропущен.

### Шаг 4/11 — AppArmor

- Проверяет активность AppArmor в ядре
- Если не активен — добавляет `apparmor=1 security=apparmor` в `/boot/armbianEnv.txt`
- Требует перезагрузки для активации

### Шаг 5/11 — Swap

- Автоматически определяет размер:
  - RAM < 1.5 ГБ → swap 3 ГБ
  - RAM ≥ 1.5 ГБ → swap 2 ГБ
- Создаёт `/swapfile`
- Добавляет в `/etc/fstab`
- Устанавливает `swappiness=10` (минимальное использование)

Пропуск: `--skip-swap`
Ручной размер: `--swap-size 4096`

### Шаг 6/11 — Docker

- Удаляет старые версии Docker
- Устанавливает Docker CE через официальный скрипт
- Настраивает `journald` как log-driver
- Устанавливает `overlay2` как storage-driver
- Проверяет работоспособность (`docker run hello-world`)

### Шаг 7/11 — OS-Agent

- Автоматически определяет последнюю версию через GitHub API
- Скачивает `.deb` пакет с retry (3 попытки)
- Проверяет целостность `.deb` файла
- Устанавливает и проверяет D-Bus

### Шаг 8/11 — HA Supervised + маскировка

1. **Бэкап** `/etc/os-release` → `~/.ha_install_backup/os-release.original`
2. **Подмена** `/etc/os-release` на Debian 12
3. **Скачивание** `homeassistant-supervised.deb` (с retry)
4. **Установка** с автоопределённым типом машины
5. **Создание systemd drop-in** для автоподмены перед каждым стартом Supervisor
6. **Создание скрипта отката** `/root/restore_armbian_identity.sh`

### Шаг 9/11 — Оптимизация TV-бокса

- **Журнал systemd:** макс. 50 МБ, хранение 7 дней
- **fstab:** добавление `noatime` (уменьшение операций записи)
- **tmpfs /tmp:** 128 МБ в RAM
- **sysctl:** оптимизация `dirty_ratio`, `dirty_writeback_centisecs`

Пропуск: `--skip-optimize`

### Шаг 10/11 — Дополнительные настройки

#### Watchdog

- Cron-задача каждые 5 минут
- Проверяет HTTP-ответ HA
- Перезапускает `homeassistant` после 3 неудачных проверок
- Ротация лога (макс. 1000 строк)

#### Автоочистка диска

- Cron-задача ежедневно в 03:30
- Срабатывает если свободно < 1 ГБ
- Очищает: Docker мусор, журнал, apt-кэш, старые логи
- Отправляет уведомление в Telegram

#### mDNS

- Включает `avahi-daemon`
- Предлагает сменить hostname на `homeassistant`
- Доступ по `http://homeassistant.local:8123`

#### ha-health

- Утилита быстрой диагностики
- Показывает: RAM, диск, температуру, контейнеры, USB, проблемы HA, лог watchdog

#### USB-устройства

- Автоопределение Zigbee-адаптеров (CC2531, ConBee, Sonoff)
- Автоопределение Z-Wave-адаптеров
- Показ `/dev/ttyUSB*` и `/dev/ttyACM*`

#### Telegram

- Опциональная настройка
- Требует Bot Token и Chat ID
- Интегрируется с watchdog и автоочисткой
- Тестовое сообщение при настройке

Пропуск: `--skip-extras`

### Шаг 11/11 — Health-check

Проверяет 15 компонентов:

| # | Проверка | Тип |
|---|----------|-----|
| 1 | Docker работает | Критично |
| 2 | HA Supervisor запущен | Предупреждение |
| 3 | HA Core запущен | Предупреждение |
| 4 | AppArmor активен | Предупреждение |
| 5 | NetworkManager активен | Критично |
| 6 | systemd-resolved активен | Предупреждение |
| 7 | OS-Agent D-Bus работает | Предупреждение |
| 8 | Swap присутствует | Предупреждение |
| 9 | Температура CPU в норме | Критично если >80°C |
| 10 | Маскировка os-release активна | Предупреждение |
| 11 | Drop-in systemd присутствует | Предупреждение |
| 12 | Watchdog установлен | Предупреждение |
| 13 | Автоочистка установлена | Предупреждение |
| 14 | mDNS (avahi) работает | Предупреждение |
| 15 | Telegram настроен | Информация |

---

## 8. Маскировка os-release

### Зачем нужна

HA Supervisor проверяет `/etc/os-release` и ожидает `ID=debian`. Armbian имеет `ID=armbian` — Supervisor показывает `unsupported system`.

### Что подменяется

**Только один файл:** `/etc/os-release`

Не затрагиваются: `/etc/issue`, `/etc/armbian-release`, `lsb_release`, MOTD, и любые другие системные файлы.

### Как работает

```
 Установка:
   os-release подменяется на Debian 12

 При каждом старте HA Supervisor:
   systemd drop-in проверяет и восстанавливает подмену
   (на случай если apt upgrade перезаписал файл)

 Бэкап оригинала:
   ~/.ha_install_backup/os-release.original
```

### Откат маскировки

```bash
sudo bash /root/restore_armbian_identity.sh
```

После отката HA будет работать, но покажет предупреждение `unsupported system`.

---

## 9. Дополнительные утилиты

### ha-health — диагностика

```bash
ha-health
```

Вывод:

```
===== СИСТЕМА =====
  Hostname:    homeassistant
  Uptime:      up 2 hours, 15 minutes
  RAM:         412M / 924M
  Swap:        28M / 3.0G
  Диск /:      3.2G / 14G (10G свободно)
  CPU:         52°C

===== КОНТЕЙНЕРЫ =====
  hassio_supervisor   Up 2 hours
  homeassistant       Up 2 hours
  hassio_cli          Up 2 hours
  hassio_audio        Up 2 hours
  hassio_dns          Up 2 hours
  hassio_observer     Up 2 hours
  hassio_multicast    Up 2 hours

===== USB =====
  /dev/ttyUSB0 (root:dialout)

===== HA =====
  version: 2024.x.x
  machine: qemuarm-64
  arch: aarch64

===== ПРОБЛЕМЫ =====
  (вывод ha resolution info)

===== WATCHDOG =====
  2024-01-15 12:30:00 OK Восстановлен (HTTP 200)
```

### ha-watchdog — автоперезапуск

Работает автоматически через cron. Вручную:

```bash
ha-watchdog
```

Лог:

```bash
cat /var/log/ha-watchdog.log
```

Формат лога:

```
2024-01-15 12:30:00 OK Восстановлен (HTTP 200)
2024-01-15 12:35:00 WARN HA не отвечает (1/3)
2024-01-15 12:40:00 WARN HA не отвечает (2/3)
2024-01-15 12:45:00 WARN HA не отвечает (3/3)
2024-01-15 12:45:00 ACTION Перезапуск homeassistant
```

Отключить:

```bash
rm /etc/cron.d/ha-watchdog
```

### ha-cleanup — автоочистка

Работает автоматически через cron (03:30). Вручную:

```bash
ha-cleanup
```

Лог:

```bash
cat /var/log/ha-cleanup.log
```

Отключить:

```bash
rm /etc/cron.d/ha-cleanup
```

### ha-notify — Telegram

Отправить сообщение:

```bash
ha-notify "Тестовое сообщение"
ha-notify "⚠️ Проблема с сервером"
ha-notify "✅ Всё работает"
```

Настроить если пропустили при установке:

```bash
nano /usr/local/bin/ha-notify
```

Замените:

```bash
TOKEN="ваш_токен_бота"
CHAT="ваш_chat_id"
```

Получить токен: https://t.me/BotFather
Получить chat_id: https://t.me/userinfobot

---

## 10. Управление Home Assistant

### Веб-интерфейс

```
http://<IP-адрес>:8123
http://homeassistant.local:8123
```

### Командная строка (CLI)

```bash
# Информация
ha core info              # Версия, статус HA Core
ha supervisor info        # Статус Supervisor
ha resolution info        # Проблемы и предупреждения
ha host info              # Информация о хосте
ha network info           # Сетевые настройки

# Логи
ha core logs              # Логи HA Core
ha supervisor logs        # Логи Supervisor

# Управление
ha core restart           # Перезапуск HA Core
ha core stop              # Остановка
ha core start             # Запуск
ha host reboot            # Перезагрузка хоста
ha host shutdown          # Выключение

# Обновление
ha core update            # Обновить HA Core
ha supervisor update      # Обновить Supervisor

# Бэкапы
ha backups list           # Список бэкапов
ha backups new            # Создать бэкап
```

### Docker

```bash
# Контейнеры
docker ps                 # Запущенные контейнеры
docker ps -a              # Все контейнеры
docker logs homeassistant # Логи HA Core
docker logs hassio_supervisor  # Логи Supervisor

# Перезапуск контейнеров
docker restart homeassistant
docker restart hassio_supervisor
```

### Службы systemd

```bash
systemctl status hassio-supervisor  # Статус Supervisor
systemctl restart hassio-supervisor # Перезапуск
systemctl stop hassio-supervisor    # Остановка
systemctl start hassio-supervisor   # Запуск
```

---

## 11. Обновление Home Assistant

### Через веб-интерфейс

```
Настройки → Система → Обновления
```

### Через CLI

```bash
ha core update            # Обновить HA Core
ha supervisor update      # Обновить Supervisor
```

### После обновления Armbian

Если `apt upgrade` перезаписал `/etc/os-release`:

1. systemd drop-in автоматически восстановит подмену при следующем старте Supervisor
2. Проверить: `cat /etc/os-release | grep ID` — должно быть `ID=debian`
3. Если нет — перезапустить: `systemctl restart hassio-supervisor`

---

## 12. Удаление

### Команда

```bash
sudo bash install_ha.sh --uninstall
```

### Что удаляется

- ✅ Все контейнеры HA (supervisor, core, аддоны)
- ✅ Docker-образы HA
- ✅ Пакеты `homeassistant-supervised`, `os-agent`
- ✅ Маскировка os-release (восстанавливается оригинал)
- ✅ Drop-in systemd
- ✅ Утилиты: `ha-health`, `ha-watchdog`, `ha-cleanup`, `ha-notify`
- ✅ Cron-задачи
- ✅ Скрипт отката

### Что НЕ удаляется

- Docker CE (может использоваться для другого)
- Swap-файл
- Сетевые настройки (NetworkManager)
- Данные HA (`/usr/share/hassio/`)

### Полная очистка данных

```bash
sudo rm -rf /usr/share/hassio
```

### Удаление Docker

```bash
sudo apt-get purge docker-ce docker-ce-cli containerd.io
sudo rm -rf /var/lib/docker
```

---

## 13. Файлы и директории

### Созданные скриптом

| Путь | Описание |
|------|----------|
| `/root/.ha_install_backup/` | Бэкапы изменённых файлов |
| `/root/.ha_install_backup/os-release.original` | Оригинальный os-release |
| `/root/.ha_install_backup/interfaces.bak` | Оригинальный interfaces |
| `/root/.ha_install_backup/fstab.bak` | Оригинальный fstab |
| `/root/.ha_install_backup/armbianEnv.txt.bak` | Оригинальный armbianEnv |
| `/root/.ha_install_state` | Прогресс установки |
| `/root/restore_armbian_identity.sh` | Скрипт отката маскировки |
| `/usr/local/bin/ha-health` | Утилита диагностики |
| `/usr/local/bin/ha-watchdog` | Скрипт watchdog |
| `/usr/local/bin/ha-cleanup` | Скрипт автоочистки |
| `/usr/local/bin/ha-notify` | Скрипт Telegram |
| `/etc/cron.d/ha-watchdog` | Cron watchdog (*/5 мин) |
| `/etc/cron.d/ha-cleanup` | Cron очистки (03:30) |
| `/var/log/ha_install_*.log` | Лог установки |
| `/var/log/ha-watchdog.log` | Лог watchdog |
| `/var/log/ha-cleanup.log` | Лог автоочистки |

### Системные конфигурации

| Путь | Описание |
|------|----------|
| `/etc/os-release` | Подменён на Debian 12 |
| `/etc/docker/daemon.json` | Настройки Docker |
| `/etc/NetworkManager/conf.d/10-ha-managed.conf` | Настройки NM |
| `/etc/systemd/system/hassio-supervisor.service.d/mask-os-release.conf` | Drop-in маскировки |
| `/etc/systemd/journald.conf.d/10-ha-tvbox.conf` | Лимиты журнала |
| `/etc/sysctl.d/99-ha-swap.conf` | Настройки swap |
| `/etc/sysctl.d/99-ha-emmc.conf` | Оптимизация записи |
| `/swapfile` | Swap-файл |

### Home Assistant

| Путь | Описание |
|------|----------|
| `/usr/share/hassio/` | Данные HA (конфиг, аддоны, БД) |
| `/usr/share/hassio/homeassistant/` | Конфигурация HA |

---

## 14. Troubleshooting

### Скрипт упал на середине

```bash
# Просто запустите заново — продолжит с места остановки
sudo bash install_ha.sh

# Или начать заново
sudo bash install_ha.sh --reset-state
sudo bash install_ha.sh
```

### HA не запускается / долго загружается

```bash
# Проверить контейнеры
docker ps -a

# Логи Supervisor
docker logs hassio_supervisor

# Логи Core
docker logs homeassistant

# Перезапуск
systemctl restart hassio-supervisor

# Полная диагностика
ha-health
```

### «Unsupported system» в HA

```bash
# Проверить маскировку
cat /etc/os-release | grep ID
# Должно быть: ID=debian

# Проверить drop-in
cat /etc/systemd/system/hassio-supervisor.service.d/mask-os-release.conf

# Проверить проблемы
ha resolution info

# Перезапустить Supervisor (drop-in применит маскировку)
systemctl restart hassio-supervisor
```

### AppArmor не активен

```bash
# Проверить
cat /sys/module/apparmor/parameters/enabled
# Должно быть: Y

# Если N — проверить загрузчик
cat /boot/armbianEnv.txt | grep extraargs
# Должно содержать: apparmor=1 security=apparmor

# Перезагрузить
reboot
```

### Нет места на диске

```bash
# Проверить
df -h /

# Запустить очистку вручную
ha-cleanup

# Или ручная очистка
docker system prune -a
journalctl --vacuum-size=20M
apt-get clean
```

### SSH обрыв при установке

При перезапуске NetworkManager (шаг 3) SSH может оборваться.

```bash
# Просто подключитесь снова и запустите скрипт
ssh root@<IP>
sudo bash install_ha.sh
# Шаг 3 будет пропущен, установка продолжится
```

### Сеть не работает после установки

```bash
# Проверить NetworkManager
systemctl status NetworkManager
nmcli device status
nmcli connection show

# Перезапустить
systemctl restart NetworkManager

# Если не помогает — восстановить из бэкапа
cp /root/.ha_install_backup/interfaces.bak /etc/network/interfaces
systemctl enable networking
systemctl start networking
```

### Перегрев

```bash
# Проверить температуру
ha-health
# или
cat /sys/class/thermal/thermal_zone0/temp
# Разделите на 1000 = °C

# Решения:
# - Установить радиатор
# - Обеспечить вентиляцию
# - Уменьшить количество аддонов
```

### Watchdog не работает

```bash
# Проверить cron
cat /etc/cron.d/ha-watchdog

# Запустить вручную
ha-watchdog

# Проверить лог
cat /var/log/ha-watchdog.log
```

### Telegram не работает

```bash
# Проверить настройки
cat /usr/local/bin/ha-notify

# Тест
ha-notify "Тест"

# Если не работает — проверьте:
# 1. Токен бота
# 2. Chat ID
# 3. Бот должен быть запущен (/start в чате с ботом)
```

---

## 15. FAQ

**Q: Можно ли использовать на других TV-боксах?**

A: Да, если aarch64 + Armbian Bookworm. Скрипт автоматически определяет тип устройства. Для нестандартных устройств используйте `--machine qemuarm-64`.

**Q: Можно ли использовать на Raspberry Pi?**

A: Да, скрипт автоматически определит тип и установит `raspberrypi4-64` или `raspberrypi5-64`. Но для RPi рекомендуется официальный HA OS.

**Q: Будет ли работать без маскировки?**

A: HA установится и будет работать, но покажет предупреждение `unsupported system` и некоторые функции (автобэкап и др.) могут быть ограничены.

**Q: Безопасно ли менять os-release?**

A: Скрипт меняет только один файл. Оригинал сохраняется. Обновления Armbian (`apt upgrade`) продолжают работать. Drop-in автоматически восстанавливает подмену.

**Q: Сколько RAM нужно?**

A: Минимум 768 МБ + swap. С 1 ГБ RAM + 3 ГБ swap HA работает, но медленно. 2 ГБ RAM — комфортно.

**Q: Можно ли добавлять аддоны?**

A: Да, это полноценный HA Supervised. Рекомендуемые первые аддоны:
- File Editor — редактирование конфигов
- Terminal & SSH — SSH через веб
- Samba Share — доступ к конфигам с ПК
- Mosquitto — MQTT-брокер
- HACS — магазин кастомных интеграций

**Q: Как перенести HA на другое устройство?**

A: Создайте бэкап (Настройки → Система → Бэкапы), установите HA на новом устройстве, восстановите из бэкапа.

**Q: Скрипт можно запускать повторно?**

A: Да. Выполненные шаги будут пропущены. Для полного перезапуска: `--reset-state`.

**Q: Как обновить скрипт?**

A: Скачайте новую версию и запустите. Все выполненные шаги будут пропущены (state-файл). Для полной переустановки: `--reset-state`.

**Q: Что если TV-бокс зависнет?**

A: Watchdog проверяет HA каждые 5 минут. Если HA не отвечает 3 проверки подряд (15 мин), контейнер перезапускается. Если завис сам TV-бокс — нужна физическая перезагрузка (вынуть питание).

**Q: Как подключить Zigbee-стик?**

A: Подключите USB-стик, проверьте `ha-health` (раздел USB). В HA: Настройки → Устройства → Добавить интеграцию → ZHA или Zigbee2MQTT.

**Q: Занимает ли watchdog ресурсы?**

A: Нет. Одна проверка `curl` каждые 5 минут потребляет минимум CPU и памяти.

**Q: Можно ли отключить watchdog/автоочистку?**

A:
```bash
rm /etc/cron.d/ha-watchdog    # Отключить watchdog
rm /etc/cron.d/ha-cleanup     # Отключить автоочистку
```

**Q: Куда пишутся логи установки?**

A: `/var/log/ha_install_YYYYMMDD_HHMMSS.log`
Или в путь, указанный через `--log`.

---

## Краткая шпаргалка

```bash
# ===== УСТАНОВКА =====
sudo bash install_ha.sh              # Полная
sudo bash install_ha.sh --check      # Проверки
sudo bash install_ha.sh --dry-run    # Предпросмотр

# ===== ПОСЛЕ УСТАНОВКИ =====
ha-health                            # Диагностика
ha core info                         # Статус HA
docker ps                            # Контейнеры

# ===== ОБСЛУЖИВАНИЕ =====
ha core update                       # Обновить HA
ha-cleanup                           # Очистить диск
ha-notify "текст"                    # Telegram

# ===== ПРОБЛЕМЫ =====
docker logs hassio_supervisor        # Логи
systemctl restart hassio-supervisor   # Перезапуск
cat /var/log/ha-watchdog.log         # Лог watchdog

# ===== УДАЛЕНИЕ =====
sudo bash install_ha.sh --uninstall  # Удалить HA
