<div align="center">

<!-- Кнопки переключения языков -->
<a href="#русский"><img src="https://img.shields.io/badge/🇷🇺_Русский-activeblue" alt="Русский"></a>
<a href="#english"><img src="https://img.shields.io/badge/🇬🇧_English-inactive-lightgrey" alt="English"></a>


Ultimate Home Assistant Supervised Installer (HAS-TVBox)
Ультимативный установщик Home Assistant Supervised для TV-боксов, SBC и десктопов (Armbian / Debian).

License: MIT
Bash Version

<!-- TODO: Замените iRespect777/HAS-tvbox на ваш репозиторий -->
GitHub release

</div>

🇷🇺 Русский
📖 О проекте
Этот скрипт позволяет легко и безопасно установить Home Assistant Supervised на устройства, официально не поддерживаемые HassOS (TV-боксы на Amlogic/Rockchip, Raspberry Pi, обычные ПК).
Он автоматически решает проблемы с архитектурой, подменяет os-release для прохождения проверок HA, патчит загрузчик для AppArmor и настраивает NetworkManager без обрыва SSH-сессии.

✨ Основные возможности
Идемпотентность: Скрипт запоминает пройденные шаги. Если отключится свет или оборвется SSH, при повторном запуске он продолжит с места остановки.
Авто-перезагрузка: При активации AppArmor скрипт создаст systemd-задачу, которая автоматически продолжит установку после ребута.
Безопасность сети: Безопасный переход на NetworkManager с полным откатом (rollback) в случае потери связи.
Модульность: Можно установить только HA, а затем через меню установить Tailscale VPN, Cloudflare Tunnel, UFW или ZRAM.
Умные бэкапы: Поддержка локальных бэкапов (tar/CLI), а также удаленных через rsync (SSH) или rclone (Яндекс.Диск, Google Drive и др.).
Уведомления: Встроенная поддержка Telegram, ntfy.sh, Discord, Slack и Gotify.
Оптимизация eMMC: Отключение atime, настройка журналирования и ZRAM для продления ресурса флеш-памяти.
Установка HACS: Автоматическая установка HACS (3 разных метода для максимальной надежности).
📋 Требования
ОС: Armbian (Bookworm, Trixie) или чистый Debian 11/12/13.
Архитектура: aarch64 (ARM 64-bit) или x86_64 (AMD64). (ARMv7 / 32-bit не поддерживается самим Home Assistant).
RAM: от 1 ГБ (рекомендуется 2 ГБ+).
Диск: от 10 ГБ свободного места.
Доступ: Root права (sudo).
🚀 Быстрый старт
Подключитесь к вашему устройству по SSH и выполните команду:

bash

<!-- TODO: Замените iRespect777/HAS-tvbox и install.sh на реальные ссылки, если они отличаются -->
wget -qO- https://raw.githubusercontent.com/iRespect777/HAS-tvbox/main/install.sh | bash
Или скачайте скрипт и запустите его вручную:

bash

wget https://raw.githubusercontent.com/iRespect777/HAS-tvbox/main/install.sh
chmod +x install.sh
sudo ./install.sh
После запуска откроется интерактивный мастер, который проведет вас через все этапы настройки.

🛠 Профили установки
В скрипте встроено несколько предустановок:

Minimal: Только HA и Docker (для очень слабых устройств).
Standard: HA + Файрвол + Бэкапы + Watchdog (рекомендуется для большинства).
Full: Стандарт + Мониторинг (Prometheus) + Удаленный доступ.
Server: Для серверов со статическим IP.
Custom: Ручной выбор каждого компонента через меню.
⚙️ Полезные команды после установки
sudo ha-install --status — Мониторинг системы в реальном времени.
sudo ha-install --check — Диагностика состояния HA и Docker.
sudo ha-install --rescue — Режим восстановления (автоматически чинит DNS, Docker, Supervisor).
sudo ha-install --modules — Установка дополнительных модулей (VPN, HACS и др.).
ha-health — Краткий отчет о здоровье системы.
🤝 Вклад и помощь
Если вы нашли баг или хотите предложить фичу, создайте Issue в репозитории.

<!-- TODO: Укажите ваши контакты или ссылку на обсуждение, если нужно -->
Автор: [Ваше Имя / Ник GitHub]

<div align="center">

<!-- Кнопки переключения языков -->
<a href="#русский"><img src="https://img.shields.io/badge/🇷🇺_Русский-inactive-lightgrey" alt="Русский"></a>
<a href="#english"><img src="https://img.shields.io/badge/🇬🇧_English-activeblue" alt="English"></a>

</div>

🇬🇧 English
📖 About
This script allows you to easily and safely install Home Assistant Supervised on devices not officially supported by HassOS (TV-boxes based on Amlogic/Rockchip, Raspberry Pi, regular PCs).
It automatically resolves architecture issues, fakes os-release to pass HA checks, patches the bootloader for AppArmor, and configures NetworkManager without dropping your SSH session.

✨ Key Features
Idempotency: The script remembers completed steps. If power is lost or SSH drops, re-running it will resume from the point of failure.
Auto-Reboot: When enabling AppArmor, the script creates a systemd task to automatically continue the installation after a reboot.
Network Safety: Safe migration to NetworkManager with a full network rollback in case of connection loss.
Modularity: You can install just HA, and then use the menu to add Tailscale VPN, Cloudflare Tunnel, UFW, or ZRAM later.
Smart Backups: Supports local backups (tar/CLI) and remote backups via rsync (SSH) or rclone (Google Drive, Dropbox, etc.).
Notifications: Built-in support for Telegram, ntfy.sh, Discord, Slack, and Gotify.
eMMC Optimization: Disables atime, configures journald, and sets up ZRAM to prolong flash memory lifespan.
HACS Installation: Automated HACS installation (3 fallback methods for maximum reliability).
📋 Requirements
OS: Armbian (Bookworm, Trixie) or pure Debian 11/12/13.
Architecture: aarch64 (ARM 64-bit) or x86_64 (AMD64). (ARMv7 / 32-bit is not supported by Home Assistant itself).
RAM: 1 GB minimum (2 GB+ recommended).
Storage: 10 GB free space minimum.
Access: Root privileges (sudo).
🚀 Quick Start
Connect to your device via SSH and run:

bash

<!-- TODO: Replace iRespect777/HAS-tvbox and install.sh with actual links if different -->
wget -qO- https://raw.githubusercontent.com/iRespect777/HAS-tvbox/main/install.sh | bash
Or download the script and run it manually:

bash

wget https://raw.githubusercontent.com/iRespect777/HAS-tvbox/main/install.sh
chmod +x install.sh
sudo ./install.sh
An interactive wizard will open, guiding you through the configuration process.

🛠 Installation Profiles
Several presets are built into the script:

Minimal: Just HA and Docker (for very weak devices).
Standard: HA + Firewall + Backups + Watchdog (recommended for most users).
Full: Standard + Monitoring (Prometheus) + Remote Access.
Server: For servers with a static IP.
Custom: Manual selection of every component via menu.
⚙️ Useful Post-Install Commands
sudo ha-install --status — Real-time system monitoring.
sudo ha-install --check — Diagnose HA and Docker health.
sudo ha-install --rescue — Rescue mode (automatically fixes DNS, Docker, Supervisor).
sudo ha-install --modules — Install additional modules (VPN, HACS, etc.).
ha-health — Quick system health report.
🤝 Contributing & Support
If you find a bug or want to suggest a feature, please open an Issue in the repository.

<!-- TODO: Add your contacts or link to discussions if needed -->
Author: [Your Name / GitHub Username]

<!-- TODO: Добавьте информацию о лицензии, если используете отличную от MIT -->
📄 License
This project is licensed under the MIT License - see the LICENSE file for details.
