#!/bin/bash
################################################################################
# ПередОС — Скрипт сборки операционной системы
# НПО "всё ПО"
# Версия: 1.0.0
################################################################################

set -euo pipefail

# === Конфигурация ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
ROOTFS_DIR="${SCRIPT_DIR}/rootfs"
ISO_DIR="${BUILD_DIR}/iso"
ISO_FILE="${BUILD_DIR}/peredos-1.0-pioneer-amd64.iso"
TARGET_ARCH="amd64"
DEBIAN_VERSION="bookworm"
OS_NAME="ПередОС"
OS_VERSION="1.0"
OS_CODENAME="pioneer"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"

# Пароль учётной записи live-пользователя.
# Можно задать снаружи: sudo PEREDOS_PASSWORD='секрет' ./build.sh
LIVE_USER="user"
if [[ -z "${PEREDOS_PASSWORD:-}" ]]; then
    PEREDOS_PASSWORD="peredos"
    PASSWORD_IS_DEFAULT=1
else
    PASSWORD_IS_DEFAULT=0
fi

# Ключ репозитория ПередОС (бинарный .gpg или ASCII-armored .asc).
# Если файла нет, репозиторий repo.peredos.vsepo.ru в образ не включается,
# иначе apt update падает из-за AllowInsecureRepositories=false.
PEREDOS_REPO_KEY="${PEREDOS_REPO_KEY:-${SCRIPT_DIR}/branding/peredos-archive-keyring.gpg}"

CHROOT="${BUILD_DIR}/rootfs"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# === Функции ===
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Этот скрипт должен быть запущен с правами root (sudo)"
        exit 1
    fi
}

check_dependencies() {
    log_step "Проверка зависимостей"

    if ! command -v apt-get &> /dev/null; then
        log_error "Сборка поддерживается только на Debian/Ubuntu (нужен apt-get)"
        exit 1
    fi

    local missing=()
    local -A cmd_pkg=(
        [debootstrap]=debootstrap
        [xorriso]=xorriso
        [mksquashfs]=squashfs-tools
        [grub-mkrescue]=grub-common
        [mformat]=mtools
    )
    local cmd
    for cmd in "${!cmd_pkg[@]}"; do
        command -v "$cmd" &> /dev/null || missing+=("${cmd_pkg[$cmd]}")
    done

    # Каталоги модулей GRUB нужны grub-mkrescue для BIOS и UEFI
    [[ -d /usr/lib/grub/i386-pc ]] || missing+=("grub-pc-bin")
    [[ -d /usr/lib/grub/x86_64-efi ]] || missing+=("grub-efi-amd64-bin")

    if [[ ${#missing[@]} -gt 0 ]]; then
        # убираем дубликаты
        mapfile -t missing < <(printf '%s\n' "${missing[@]}" | sort -u)
        log_warn "Не хватает пакетов: ${missing[*]}"
        log_info "Установка зависимостей..."
        apt-get update
        apt-get install -y "${missing[@]}"
    fi

    log_success "Все зависимости установлены"
}

# === Работа с chroot ===
chroot_mount() {
    mountpoint -q "${CHROOT}/proc" || mount -t proc proc "${CHROOT}/proc"
    mountpoint -q "${CHROOT}/sys" || mount -t sysfs sysfs "${CHROOT}/sys"
    mountpoint -q "${CHROOT}/dev" || mount --bind /dev "${CHROOT}/dev"
    mountpoint -q "${CHROOT}/dev/pts" || mount -t devpts devpts "${CHROOT}/dev/pts"
    # DNS внутри chroot
    cp -L /etc/resolv.conf "${CHROOT}/etc/resolv.conf"
}

chroot_umount() {
    local m
    for m in dev/pts dev sys proc; do
        if mountpoint -q "${CHROOT}/${m}" 2>/dev/null; then
            umount "${CHROOT}/${m}" 2>/dev/null || umount -l "${CHROOT}/${m}" || true
        fi
    done
}

# Выполнить команду в chroot (неинтерактивно)
in_chroot() {
    DEBIAN_FRONTEND=noninteractive LC_ALL=C chroot "${CHROOT}" "$@"
}

# Установить пакеты в chroot
apt_install() {
    in_chroot apt-get install -y --no-install-recommends "$@"
}

require_rootfs() {
    if [[ ! -x "${CHROOT}/bin/sh" && ! -e "${CHROOT}/bin/sh" ]]; then
        log_error "Базовая система не найдена. Сначала выполните этап 1."
        exit 1
    fi
}

# Начало этапа, использующего chroot: монтируем и гарантируем размонтирование
begin_chroot_stage() {
    require_rootfs
    trap 'chroot_umount' EXIT
    chroot_mount
}

end_chroot_stage() {
    chroot_umount
    trap - EXIT
}

# === Этап 1: Создание базовой системы ===
stage1_base_system() {
    log_step "Этап 1: Создание базовой системы"

    # Не удаляем rootfs, пока в нём что-то смонтировано (иначе rm -rf заденет /dev хоста)
    chroot_umount
    if findmnt -rn | grep -q " ${CHROOT}/"; then
        log_error "В ${CHROOT} остались точки монтирования. Размонтируйте их вручную."
        exit 1
    fi

    rm -rf "${CHROOT}"
    mkdir -p "${CHROOT}"

    # Список пакетов — одной строкой без пробелов (иначе bash разобьёт аргумент)
    local include
    include="linux-image-amd64,initramfs-tools,live-boot,systemd,systemd-sysv"
    include+=",systemd-resolved,systemd-timesyncd,dbus,udev,sudo,vim-tiny,nano"
    include+=",curl,wget,gnupg,apt-transport-https,ca-certificates,iptables"
    include+=",btrfs-progs,cryptsetup,cryptsetup-initramfs,locales,kmod"
    include+=",grub-common,grub2-common,grub-pc-bin,grub-efi-amd64-bin,os-prober"

    log_info "Запуск debootstrap..."
    debootstrap \
        --arch="${TARGET_ARCH}" \
        --variant=minbase \
        --components=main,contrib,non-free,non-free-firmware \
        --include="${include}" \
        "${DEBIAN_VERSION}" \
        "${CHROOT}" \
        "${DEBIAN_MIRROR}"

    log_success "Базовая система создана"
}

# === Этап 2: Копирование конфигураций ===
stage2_configs() {
    log_step "Этап 2: Применение конфигураций ПередОС"

    begin_chroot_stage

    # Копирование конфигураций (права из git не переносим — задаём явно ниже)
    log_info "Копирование /etc..."
    local item name
    for item in "${ROOTFS_DIR}/etc/"*; do
        name="$(basename "$item")"
        # fstab содержит плейсхолдеры UUID — это шаблон для установщика,
        # live-системе он не подходит (root — overlay от live-boot)
        if [[ "$name" == "fstab" ]]; then
            mkdir -p "${CHROOT}/usr/share/peredos"
            install -m 644 "$item" "${CHROOT}/usr/share/peredos/fstab.template"
            continue
        fi
        cp -r --no-preserve=mode,ownership "$item" "${CHROOT}/etc/"
    done

    # Копирование /usr (скрипты ПередОС)
    if [[ -d "${ROOTFS_DIR}/usr" ]]; then
        log_info "Копирование /usr..."
        cp -r --no-preserve=mode,ownership "${ROOTFS_DIR}/usr/." "${CHROOT}/usr/"
    fi

    # Права: каталоги 755, файлы 644, затем исключения
    local dir
    for dir in apt default modules-load.d systemd sysctl.d; do
        find "${CHROOT}/etc/${dir}" -type d -exec chmod 755 {} +
        find "${CHROOT}/etc/${dir}" -type f -exec chmod 644 {} +
    done
    chmod 644 "${CHROOT}"/etc/{os-release,issue,issue.net,hostname}
    find "${CHROOT}/usr/lib/peredos" -type d -exec chmod 755 {} +
    find "${CHROOT}/usr/lib/peredos" -type f -exec chmod 755 {} +

    # sudo: группа sudo остаётся с паролем (правило из Debian по умолчанию).
    # Без пароля — только live-пользователь и только в live-сессии.
    install -d -m 750 "${CHROOT}/etc/sudoers.d"
    echo "${LIVE_USER} ALL=(ALL:ALL) NOPASSWD: ALL" > "${CHROOT}/etc/sudoers.d/10-peredos-live"
    chmod 440 "${CHROOT}/etc/sudoers.d/10-peredos-live"
    chroot "${CHROOT}" visudo -c -q

    # Репозиторий ПередОС включаем только если есть ключ
    if [[ -f "${PEREDOS_REPO_KEY}" ]]; then
        log_info "Подключение репозитория ПередОС (ключ: ${PEREDOS_REPO_KEY})"
        mkdir -p "${CHROOT}/usr/share/keyrings"
        if grep -q "BEGIN PGP" "${PEREDOS_REPO_KEY}"; then
            gpg --dearmor < "${PEREDOS_REPO_KEY}" \
                > "${CHROOT}/usr/share/keyrings/peredos-archive-keyring.gpg"
        else
            install -m 644 "${PEREDOS_REPO_KEY}" \
                "${CHROOT}/usr/share/keyrings/peredos-archive-keyring.gpg"
        fi
        sed -i 's#^deb https://repo.peredos.vsepo.ru#deb [signed-by=/usr/share/keyrings/peredos-archive-keyring.gpg] https://repo.peredos.vsepo.ru#' \
            "${CHROOT}/etc/apt/sources.list"
    else
        log_warn "Ключ репозитория ПередОС не найден — репозиторий отключён"
        sed -i 's#^deb https://repo.peredos.vsepo.ru#\# (отключено: нет ключа) &#' \
            "${CHROOT}/etc/apt/sources.list"
    fi

    # Локаль
    sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/; s/^# *\(ru_RU.UTF-8 UTF-8\)/\1/' \
        "${CHROOT}/etc/locale.gen"
    in_chroot locale-gen
    echo 'LANG=ru_RU.UTF-8' > "${CHROOT}/etc/default/locale"

    # Пользователь
    log_info "Создание пользователя '${LIVE_USER}'..."
    local groups="sudo,audio,video,plugdev,cdrom"
    in_chroot getent group netdev &> /dev/null || in_chroot groupadd -r netdev
    groups+=",netdev"
    if ! in_chroot id "${LIVE_USER}" &> /dev/null; then
        in_chroot useradd -m -G "${groups}" -s /bin/bash "${LIVE_USER}"
    fi

    # Пароли (root заблокирован — работаем через sudo)
    echo "${LIVE_USER}:${PEREDOS_PASSWORD}" | in_chroot chpasswd
    in_chroot passwd -l root
    if [[ $PASSWORD_IS_DEFAULT -eq 1 ]]; then
        log_warn "Используется пароль по умолчанию 'peredos'. Задайте свой через PEREDOS_PASSWORD."
    fi

    end_chroot_stage
    log_success "Конфигурации применены"
}

# === Этап 3: Установка пакетов ===
stage3_packages() {
    log_step "Этап 3: Установка пакетов ПередОС"

    begin_chroot_stage

    # Не запускать службы внутри chroot во время установки пакетов
    printf '#!/bin/sh\nexit 101\n' > "${CHROOT}/usr/sbin/policy-rc.d"
    chmod 755 "${CHROOT}/usr/sbin/policy-rc.d"

    in_chroot apt-get update

    log_info "Установка базовых утилит..."
    apt_install \
        bash-completion htop neofetch lm-sensors usbutils pciutils \
        wireless-tools wpasupplicant net-tools iputils-ping traceroute \
        bind9-dnsutils openssh-client git zip unzip tar gzip less man-db \
        firmware-linux-free memtest86+

    log_info "Установка графического окружения GNOME..."
    apt_install \
        gdm3 gnome-session gnome-shell gnome-terminal gnome-control-center \
        gnome-software gnome-tweaks gnome-calculator gnome-calendar \
        gnome-clocks gnome-screenshot gnome-system-monitor nautilus mutter \
        gnome-backgrounds dbus-user-session xwayland \
        xserver-xorg-core xserver-xorg-input-libinput \
        xserver-xorg-video-fbdev xserver-xorg-video-vesa \
        pipewire pipewire-pulse wireplumber \
        network-manager network-manager-gnome

    log_info "Установка приложений..."
    apt_install \
        firefox-esr thunderbird libreoffice libreoffice-gnome \
        libreoffice-l10n-ru vlc gimp gedit

    log_info "Установка компонентов безопасности..."
    # ufw не ставим: firstboot настраивает firewalld, вместе они конфликтуют
    apt_install \
        selinux-basics selinux-policy-default auditd fail2ban \
        firewalld flatpak xdg-desktop-portal xdg-desktop-portal-gnome

    log_info "Установка шрифтов и тем..."
    apt_install \
        fonts-noto fonts-noto-color-emoji fonts-dejavu \
        papirus-icon-theme adwaita-icon-theme

    # Включение служб (внутри chroot через systemctl enable — без запуска).
    # Сеть — NetworkManager (панель сети и Wi-Fi в GNOME), DNS — systemd-resolved,
    # который NetworkManager подхватывает через stub-resolv.conf.
    log_info "Включение служб..."
    in_chroot systemctl enable \
        NetworkManager systemd-resolved systemd-timesyncd \
        gdm3 auditd fail2ban firewalld peredos-firstboot.service

    # Автовход live-пользователя в GNOME
    mkdir -p "${CHROOT}/etc/gdm3"
    cat > "${CHROOT}/etc/gdm3/daemon.conf" << EOF
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=${LIVE_USER}
EOF

    log_info "Очистка..."
    in_chroot apt-get autoremove -y
    in_chroot apt-get clean
    rm -f "${CHROOT}/usr/sbin/policy-rc.d"
    rm -rf "${CHROOT}"/var/lib/apt/lists/*

    end_chroot_stage
    log_success "Пакеты установлены"
}

# === Этап 4: Настройка брендинга ===
stage4_branding() {
    log_step "Этап 4: Применение брендинга ПередОС"
    
    # Копирование обоев
    require_rootfs
    mkdir -p "${BUILD_DIR}/rootfs/usr/share/backgrounds/peredos"
    mkdir -p "${BUILD_DIR}/rootfs/usr/share/pixmaps"
    cp "${SCRIPT_DIR}/branding/wallpapers/"*.jpg \
        "${BUILD_DIR}/rootfs/usr/share/backgrounds/peredos/"
    
    # Копирование логотипа
    cp "${SCRIPT_DIR}/branding/logo.png" \
        "${BUILD_DIR}/rootfs/usr/share/pixmaps/peredos-logo.png"
    
    # Установка обоев по умолчанию
    mkdir -p "${BUILD_DIR}/rootfs/usr/share/glib-2.0/schemas"
    cat > "${BUILD_DIR}/rootfs/usr/share/glib-2.0/schemas/99_peredos.gschema.override" << 'EOF'
[org.gnome.desktop.background]
picture-uri='file:///usr/share/backgrounds/peredos/default-dark.jpg'
picture-uri-dark='file:///usr/share/backgrounds/peredos/default-dark.jpg'
picture-options='zoom'

[org.gnome.desktop.interface]
gtk-theme='Adwaita'
icon-theme='Papirus'
cursor-theme='Adwaita'
font-name='Noto Sans 11'
monospace-font-name='Noto Sans Mono 11'

[org.gnome.desktop.wm.preferences]
titlebar-font='Noto Sans Bold 11'

[org.gnome.shell]
show-battery-percentage=true
EOF
    
    # Компиляция gsettings (при ошибке в override сборка должна остановиться)
    chroot "${CHROOT}" glib-compile-schemas /usr/share/glib-2.0/schemas/
    
    log_success "Брендинг применён"
}

# === Этап 5: Создание Initramfs ===
stage5_initramfs() {
    log_step "Этап 5: Создание Initramfs"

    begin_chroot_stage
    # live-boot должен попасть в initramfs, иначе live-система не загрузится
    in_chroot update-initramfs -c -k all
    end_chroot_stage

    log_success "Initramfs создан"
}

# === Этап 6: Сборка ISO ===
# Подготовка rootfs к упаковке
finalize_rootfs() {
    chroot_umount
    # resolv.conf: на живой системе DNS ведёт systemd-resolved
    rm -f "${CHROOT}/etc/resolv.conf"
    ln -s ../run/systemd/resolve/stub-resolv.conf "${CHROOT}/etc/resolv.conf"
    # machine-id должен генерироваться при загрузке
    : > "${CHROOT}/etc/machine-id"
    rm -f "${CHROOT}/var/lib/dbus/machine-id"
    rm -rf "${CHROOT}/tmp/"* "${CHROOT}/var/tmp/"*
    find "${CHROOT}/var/log" -type f -exec truncate -s 0 {} + 2>/dev/null || true
}

stage6_iso() {
    log_step "Этап 6: Сборка ISO образа"

    require_rootfs
    finalize_rootfs

    rm -rf "${ISO_DIR}"
    mkdir -p "${ISO_DIR}/boot/grub" "${ISO_DIR}/live"

    # Самое свежее установленное ядро
    local vmlinuz kernel_version
    vmlinuz=$(find "${CHROOT}/boot" -maxdepth 1 -name 'vmlinuz-*' | sort -V | tail -1)
    if [[ -z "$vmlinuz" ]]; then
        log_error "Ядро не найдено в ${CHROOT}/boot. Выполните этапы 1-3."
        exit 1
    fi
    kernel_version="${vmlinuz##*/vmlinuz-}"
    if [[ ! -f "${CHROOT}/boot/initrd.img-${kernel_version}" ]]; then
        log_error "Нет initrd для ядра ${kernel_version}. Выполните этап 5."
        exit 1
    fi
    log_info "Ядро: ${kernel_version}"

    cp "${vmlinuz}" "${ISO_DIR}/live/vmlinuz"
    cp "${CHROOT}/boot/initrd.img-${kernel_version}" "${ISO_DIR}/live/initrd.img"

    # memtest86+ (если установлен)
    local memtest_entry=""
    if [[ -f "${CHROOT}/boot/memtest86+x64.bin" ]]; then
        cp "${CHROOT}/boot/memtest86+x64.bin" "${ISO_DIR}/boot/memtest86+.bin"
        memtest_entry='menuentry "Проверка памяти (memtest86+)" {
    linux /boot/memtest86+.bin
}'
    elif [[ -f "${CHROOT}/boot/memtest86+.bin" ]]; then
        cp "${CHROOT}/boot/memtest86+.bin" "${ISO_DIR}/boot/memtest86+.bin"
        memtest_entry='menuentry "Проверка памяти (memtest86+)" {
    linux /boot/memtest86+.bin
}'
    fi

    # SquashFS. Содержимое виртуальных ФС не пакуем, но сами каталоги оставляем.
    # Ядро и initrd остаются внутри образа (понадобятся установщику).
    log_info "Создание SquashFS образа..."
    mksquashfs \
        "${CHROOT}" \
        "${ISO_DIR}/live/filesystem.squashfs" \
        -comp zstd \
        -Xcompression-level 15 \
        -noappend \
        -wildcards \
        -e 'proc/*' 'sys/*' 'dev/*' 'run/*' 'tmp/*'

    # GRUB конфигурация (live-boot: boot=live, образ ищется в /live)
    log_info "Создание GRUB конфигурации..."
    cat > "${ISO_DIR}/boot/grub/grub.cfg" << EOF
# ПередОС GRUB Config
set timeout=5
set default=0

insmod all_video
loadfont unicode
set gfxmode=auto
terminal_output gfxterm

set menu_color_normal=cyan/blue
set menu_color_highlight=white/blue

menuentry "Запустить ПередОС ${OS_VERSION} (${OS_CODENAME})" --class peredos {
    set gfxpayload=keep
    linux /live/vmlinuz boot=live components quiet splash
    initrd /live/initrd.img
}

menuentry "Запустить ПередОС (Безопасный режим)" --class peredos {
    linux /live/vmlinuz boot=live components nomodeset
    initrd /live/initrd.img
}

${memtest_entry}
EOF

    # Создание ISO (BIOS + UEFI). Ошибки не скрываем.
    log_info "Сборка ISO..."
    grub-mkrescue \
        -o "${ISO_FILE}" \
        "${ISO_DIR}" \
        --modules="part_gpt part_msdos fat iso9660 gfxterm all_video" \
        -- -volid "PEREDOS_${OS_VERSION//./_}"

    log_success "ISO образ собран: ${ISO_FILE}"
}

# === Этап 7: Очистка ===
stage7_cleanup() {
    log_step "Этап 7: Очистка"

    chroot_umount

    log_success "Очистка завершена"
}

# === Главная функция ===
main() {
    log_step "═══════════════════════════════════════════════════"
    log_step "  ПередОС ${OS_VERSION} (${OS_CODENAME}) — Сборщик"
    log_step "  НПО \"всё ПО\""
    log_step "═══════════════════════════════════════════════════"
    
    check_root
    check_dependencies
    
    stage1_base_system
    stage2_configs
    stage3_packages
    stage4_branding
    stage5_initramfs
    stage6_iso
    stage7_cleanup
    
    log_step "═══════════════════════════════════════════════════"
    log_step "  Сборка завершена успешно!"
    log_step "  ISO: ${ISO_FILE}"
    log_step "═══════════════════════════════════════════════════"
}

# Обработка аргументов
case "${1:-}" in
    --help|-h)
        echo "ПередОС — Скрипт сборки"
        echo ""
        echo "Использование: sudo $0 [опции]"
        echo ""
        echo "Опции:"
        echo "  --stage N     Запустить только этап N (1-7)"
        echo "  --clean       Очистить build директорию"
        echo "  --help, -h    Показать эту справку"
        echo ""
        echo "Примеры:"
        echo "  sudo $0              # Полная сборка"
        echo "  sudo $0 --stage 1    # Только базовая система"
        echo "  sudo $0 --clean      # Очистка"
        exit 0
        ;;
    --clean)
        check_root
        log_info "Очистка build директории..."
        chroot_umount
        if findmnt -rn | grep -q " ${BUILD_DIR}/"; then
            log_error "В ${BUILD_DIR} остались точки монтирования. Размонтируйте их вручную."
            exit 1
        fi
        rm -rf "${BUILD_DIR}"
        log_success "Очистка завершена"
        exit 0
        ;;
    --stage)
        check_root
        check_dependencies
        case "${2:-}" in
            1) stage1_base_system ;;
            2) stage2_configs ;;
            3) stage3_packages ;;
            4) stage4_branding ;;
            5) stage5_initramfs ;;
            6) stage6_iso ;;
            7) stage7_cleanup ;;
            *) log_error "Неизвестный этап: ${2:-}" ; exit 1 ;;
        esac
        exit 0
        ;;
    "")
        main
        ;;
    *)
        log_error "Неизвестный аргумент: $1"
        echo "Используйте --help для справки"
        exit 1
        ;;
esac
