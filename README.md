## README.md

```markdown
# Home Assistant Supervised — Ultimate Installer

Автоматический установщик Home Assistant Supervised для TV-боксов, одноплатных компьютеров и x86 машин.

## Возможности

- Полная установка HA Supervised + Docker + OS-Agent за 15-30 минут
- Интерактивный мастер на русском языке (whiptail + text fallback)
- 5 готовых профилей: minimal, standard, full, server, dev
- Автоматическая подмена os-release для Armbian/Ubuntu
- Оптимизация для TV-боксов: ZRAM, eMMC tuning, USB power fix
- Безопасность: UFW, Fail2Ban, SSH hardening
- Watchdog с экспоненциальным откатом
- Автобэкапы + восстановление
- Уведомления: Telegram, ntfy.sh, Discord, любой webhook
- Перенос данных на внешний USB SSD
- HACS (магазин сообщества)
- Возобновление после сбоя (идемпотентные шаги)
- Продолжение после перезагрузки (AppArmor)

## Поддерживаемые платформы

| Архитектура |                                 Устройства                                     |
|-------------|--------------------------------------------------------------------------------|
| aarch64     | TV-боксы (Allwinner, Amlogic, Rockchip), Raspberry Pi 3/4/5, Orange Pi, ODROID |
| x86_64      | Мини-ПК, серверы, обычные ПК                                                   |
| armv7l      | Raspberry Pi 2, старые SBC                                                     |


|         ОС              |            Поддержка         |
|-------------------------|------------------------------|
| Armbian Bookworm/Trixie | Полная                       |
| Debian 12/13            | Полная                       |
| Ubuntu 22.04/24.04      | Базовая (подмена os-release) |

**Требования:** RAM 1ГБ+, диск 16ГБ+, интернет, ядро 4.x+

## Быстрый старт

### Установка с мастером (рекомендуется)

```bash
curl -fsSL https://raw.githubusercontent.com/iRespect777/HAS-tvbox/refs/heads/main/ha-installer/install.sh -o /tmp/install.sh
sudo bash /tmp/install.sh
```

### Установка одной командой

```bash
curl -fsSL https://raw.githubusercontent.com/iRespect777/HAS-tvbox/refs/heads/main/ha-installer/install.sh -o /tmp/install.sh
sudo bash /tmp/install.sh --profile standard --timezone Europe/Moscow
```

### TV-бокс с USB SSD

```bash
sudo bash /tmp/install.sh \
  --profile standard \
  --timezone Europe/Moscow \
  --data-dir /mnt/ssd \
  --swap zram \
  --auto-reboot
```

### Переустановка с восстановлением бэкапа

```bash
sudo bash /tmp/install.sh \
  --profile standard \
  --timezone Europe/Moscow \
  --restore-backup /mnt/usb/ha_config_20250101.tar.gz
```

### Headless (без вопросов, через SSH)

```bash
sudo bash /tmp/install.sh \
  --profile full \
  --timezone Europe/Moscow \
  --webhook "https://ntfy.sh/my-ha" \
  --auto-reboot \
  --silent
```

## После установки

HA доступен через 10-15 минут:

```
http://IP-АДРЕС:8123
http://homeassistant.local:8123
```

### Полезные команды

```bash
ha-health              # Отчёт о здоровье системы
ha-backup              # Создать бэкап
ha-restore             # Восстановить из бэкапа
ha-notify "текст"      # Отправить уведомление
```

### Обслуживание

```bash
sudo bash /tmp/install.sh --check        # Диагностика
sudo bash /tmp/install.sh --status       # Мониторинг (live)
sudo bash /tmp/install.sh --update       # Обновить HA + OS-Agent
sudo bash /tmp/install.sh --benchmark    # Тест производительности
sudo bash /tmp/install.sh --self-update  # Обновить скрипт
sudo bash /tmp/install.sh --uninstall   # Удалить HA
```

## Профили

| Профиль | Что включено |
|---------|-------------|
| `minimal` | Только HA + Docker |
| `standard` | + ZRAM, UFW, SSH, Watchdog, бэкапы, HACS, eMMC tuning |
| `full` | + Prometheus мониторинг |
| `server` | + Статический IP + мониторинг |
| `dev` | HA + HACS, без оптимизаций |

## Все опции

<details>
<summary>Показать все опции</summary>

### Режимы

| Опция | Описание |
|-------|----------|
| `-c`, `--check` | Диагностика |
| `-s`, `--status` | Мониторинг (live) |
| `-u`, `--uninstall` | Удаление |
| `--update` | Обновление HA |
| `--self-update` | Обновление скрипта |
| `--self-test` | Самотест |
| `--benchmark` | Тест производительности |
| `--export-config` | Экспорт конфигурации |
| `--history` | История запусков |

### Опции установки

| Опция | Пример | Описание |
|-------|--------|----------|
| `--profile` | `--profile standard` | Профиль установки |
| `--timezone` | `--timezone Europe/Moscow` | Часовой пояс |
| `--locale` | `--locale ru_RU.UTF-8` | Локаль |
| `--data-dir` | `--data-dir /mnt/ssd` | Внешний диск |
| `--restore-backup` | `--restore-backup /path/file.tar.gz` | Восстановить бэкап |
| `--wifi` | `--wifi "SSID" "password"` | Настройка WiFi |
| `--webhook` | `--webhook "https://ntfy.sh/topic"` | Webhook уведомления |
| `--swap` | `--swap 2048` или `--swap zram` или `--swap none` | Настройка swap |
| `--docker-mirror` | `--docker-mirror "https://mirror.gcr.io"` | Зеркало Docker |
| `--auto-reboot` | | Авто-перезагрузка |
| `--from-step` | `--from-step docker` | Продолжить с шага |
| `--import-config` | `--import-config /path/config.sh` | Импорт конфига |
| `--skip-update` | | Пропуск apt update |
| `--dry-run` | | Без изменений |
| `--silent` | | Тихий режим |
| `--machine` | `--machine qemuarm-64` | Тип машины HA |
| `--os-agent-ver` | `--os-agent-ver 1.6.0` | Версия OS-Agent |
| `--ha-ver` | `--ha-ver 1.7.0` | Версия HA |

</details>

## Шаги установки

Установка состоит из 15 идемпотентных шагов. При сбое — повторный запуск продолжит с того места где остановился.

| # | Шаг | Что делает |
|---|-----|-----------|
| 1 | Проверка | Система, RAM, диск, интернет, порты |
| 2 | Обновление | apt update/upgrade, часовой пояс, WiFi |
| 3 | Зависимости | Пакеты, swap |
| 4 | Сеть | NetworkManager, статический IP |
| 5 | AppArmor | Параметры загрузчика |
| 6 | Производительность | ZRAM, CPU, eMMC, USB |
| 7 | Docker | Установка, зеркало, внешний диск |
| 8 | Версии | Определение последних версий |
| 9 | Загрузка | .deb пакеты + SHA256 |
| 10 | OS-Agent | Установка агента |
| 11 | HA | Установка Home Assistant Supervised |
| 12 | Безопасность | UFW, Fail2Ban, SSH, автообновления |
| 13 | Утилиты | Watchdog, бэкапы, cron, мониторинг |
| 14 | HACS | Магазин сообщества |
| 15 | Восстановление | Бэкап (если указан) |

## Утилиты

Скрипт устанавливает набор утилит для обслуживания:

| Утилита | Расписание | Что делает |
|---------|-----------|-----------|
| `ha-watchdog` | Каждые 5 мин | Проверяет HA, перезапускает при сбое |
| `ha-cleanup` | 3:30 ночи | Очистка диска при нехватке места |
| `ha-net-recovery` | Каждые 10 мин | Восстановление сети при обрыве |
| `ha-thermal` | Каждые 5 мин | Уведомление при перегреве |
| `ha-backup` | Воскресенье 4:00 | Бэкап конфигурации HA |
| `ha-weekly-report` | Понедельник 9:00 | Еженедельный отчёт о состоянии |
| `ha-boot-check` | При загрузке | Проверка после перезагрузки |
| `ha-metrics` | Каждую минуту | Метрики Prometheus |

## Уведомления

Поддерживаются одновременно:

| Способ | Как настроить |
|--------|---------------|
| **ntfy.sh** | `--webhook "https://ntfy.sh/тема"` (бесплатно, без регистрации) |
| **Telegram** | Выбрать в мастере, ввести токен бота и Chat ID |
| **Discord** | `--webhook "https://discord.com/api/webhooks/..."` |
| **Любой webhook** | `--webhook "https://your-service.com/hook"` |

## Файловая структура

```
/var/lib/ha-installer/         Конфиг, состояние, история
/var/backups/homeassistant/    Бэкапы конфигурации HA
/usr/local/bin/ha-*            Утилиты обслуживания
/var/log/ha_install_*.log      Логи установки
/etc/cron.d/ha-tools           Задания cron
```

## Устранение неполадок

### Скрипт зависает

```bash
# Запустить с профилем (без wizard)
sudo bash /tmp/install.sh --profile standard --timezone Europe/Moscow
```

### Нет сети после установки

```bash
# Восстановить из бэкапа
sudo cp /var/lib/ha-installer/backup/interfaces.bak /etc/network/interfaces
sudo systemctl restart networking
```

### HA показывает "Unsupported"

```bash
# Перезагрузить (для AppArmor)
sudo reboot

# Проверить drop-in
cat /etc/systemd/system/hassio-supervisor.service.d/fix-os-release.conf
```

### Место закончилось

```bash
sudo ha-cleanup
# или
sudo docker system prune -af
```

## Полная документация

Подробная документация по каждому шагу, настройке и устранению неполадок:
**[docs/DOCUMENTATION.md](docs/DOCUMENTATION.md)**

## Лицензия

MIT License. Подробности в файле [LICENSE](LICENSE).

## Благодарности

- [Home Assistant](https://www.home-assistant.io/) — платформа умного дома
- [home-assistant/supervised-installer](https://github.com/home-assistant/supervised-installer) — официальный установщик
- [home-assistant/os-agent](https://github.com/home-assistant/os-agent) — OS Agent
```
