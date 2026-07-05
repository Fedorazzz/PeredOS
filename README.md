# ПередОС 1.0 "Pioneer"

> Передовая операционная система от НПО "всё ПО"

![ПередОС Логотип](branding/logo.png)

## Описание

**ПередОС** — это современная Linux-система, построенная на базе Debian 12 (Bookworm) с ядром Linux 6.8 LTS. ОС разработана с фокусом на максимальную безопасность, высокую производительность и современный минималистичный дизайн.

### Уникальные технологии

- **ПередЗащита** — многоуровневая система безопасности (SELinux, LUKS2, Flatpak)
- **ПередСкорость** — оптимизация загрузки < 10 секунд (Btrfs, zstd, оптимизированный scheduler)
- **ПередДизайн** — современный интерфейс GNOME с адаптивными темами
- **ПередЦентр** — единый центр управления системой

## Структура проекта

```
peredos/
├── build.sh              # Скрипт сборки ISO
├── docs/
│   └── MANIFEST.md       # Манифест ОС
├── branding/
│   ├── logo.png          # Логотип ПередОС
│   └── wallpapers/       # Обои рабочего стола
│       ├── default-dark.jpg
│       └── default-light.jpg
├── rootfs/               # Корневая файловая система
│   ├── etc/
│   │   ├── apt/          # Настройки репозиториев
│   │   ├── default/grub  # Конфигурация загрузчика
│   │   ├── fstab         # Таблица файловых систем
│   │   ├── hostname      # Имя хоста
│   │   ├── os-release    # Информация об ОС
│   │   ├── sysctl.d/     # Оптимизации ядра
│   │   ├── systemd/      # Настройки systemd
│   │   └── ...
│   └── ...
├── iso/                  # Файлы для ISO образа
└── kernel/               # Конфигурации ядра
```

## Системные требования

| Уровень | Процессор | ОЗУ | Диск | Графика |
|---------|-----------|-----|------|---------|
| Минимальные | 2 ядра, 1.5 GHz | 4 GB | 25 GB SSD | DirectX 11 / Vulkan 1.1 |
| Рекомендуемые | 4+ ядра, 2.5 GHz | 8+ GB | 50+ GB NVMe SSD | Vulkan 1.3+ |
| Оптимальные | 8+ ядер, 3.5 GHz | 16+ GB | 100+ GB NVMe SSD | Dedicated GPU |

## Сборка из исходников

### Требования

- Debian/Ubuntu-based система
- Права root (sudo)
- Интернет-соединение
- ~10 GB свободного места

### Установка зависимостей

```bash
sudo apt-get update
sudo apt-get install -y debootstrap grub-pc-bin grub-efi-amd64-bin \
    xorriso squashfs-tools systemd-container binutils
```

### Запуск сборки

```bash
# Полная сборка
cd peredos
sudo ./build.sh

# Только определённый этап
sudo ./build.sh --stage 1  # Базовая система
sudo ./build.sh --stage 2  # Конфигурации
sudo ./build.sh --stage 3  # Пакеты
sudo ./build.sh --stage 4  # Брендинг
sudo ./build.sh --stage 5  # Initramfs
sudo ./build.sh --stage 6  # ISO

# Очистка
sudo ./build.sh --clean
```

Результат сборки: `build/peredos-1.0-pioneer-amd64.iso`

## Установка

### Создание загрузочного USB

```bash
# С помощью dd
sudo dd if=peredos-1.0-pioneer-amd64.iso of=/dev/sdX bs=4M status=progress

# Или с помощью Ventoy (рекомендуется)
# Просто скопируйте ISO на флешку с Ventoy
```

### Процесс установки

1. Загрузитесь с USB накопителя
2. Выберите "Запустить ПередОС 1.0 (Pioneer)"
3. Следуйте инструкциям установщика
4. Перезагрузитесь в новую систему

## Технический стек

- **Ядро:** Linux 6.8 LTS (x86_64, ARM64, RISC-V)
- **База:** Debian 12 Bookworm
- **Инициализация:** Systemd
- **Графика:** Wayland + Mutter (GNOME 45)
- **Аудио/Видео:** PipeWire
- **ФС:** Btrfs с zstd сжатием
- **Безопасность:** SELinux + LUKS2 + Flatpak
- **Сеть:** NetworkManager + iwd

## Лицензия

GPL v3 — свободное программное обеспечение

## Контакты

- **Организация:** НПО "всё ПО"
- **Сайт:** https://peredos.vsepo.ru
- **Поддержка:** support@vsepo.ru
- **Разработка:** dev@vsepo.ru

---

*ПередОС — технологии будущего, доступные сегодня.*
*© 2025 НПО "всё ПО"*
