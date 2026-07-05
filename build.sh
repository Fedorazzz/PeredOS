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
    
    local deps=("debootstrap" "chroot" "xorriso" "grub-mkrescue" "mksquashfs" "systemd-nspawn")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Отсутствуют зависимости: ${missing[*]}"
        log_info "Установка зависимостей..."
        apt-get update
        apt-get install -y debootstrap grub-pc-bin grub-efi-amd64-bin \
            xorriso squashfs-tools systemd-container binutils
    fi
    
    log_success "Все зависимости установлены"
}

# === Этап 1: Создание базовой системы ===
stage1_base_system() {
    log_step "Этап 1: Создание базовой системы"
    
    rm -rf "${BUILD_DIR}/rootfs"
    mkdir -p "${BUILD_DIR}/rootfs"
    
    log_info "Запуск debootstrap..."
    debootstrap \
        --arch="${TARGET_ARCH}" \
        --variant=minbase \
        --include=linux-image-amd64,systemd,systemd-resolved, \
        systemd-timesyncd,sudo,vim,nano,curl,wget,gnupg, \
        apt-transport-https,ca-certificates,iptables, \
        btrfs-progs,cryptsetup,cryptsetup-initramfs, \
        grub-pc,grub-efi-amd64,os-prober \
        "${DEBIAN_VERSION}" \
        "${BUILD_DIR}/rootfs" \
        http://deb.debian.org/debian
    
    log_success "Базовая система создана"
}

# === Этап 2: Копирование конфигураций ===
stage2_configs() {
    log_step "Этап 2: Применение конфигураций ПередОС"
    
    # Копирование всех конфигураций
    cp -r "${ROOTFS_DIR}/etc/"* "${BUILD_DIR}/rootfs/etc/"
    
    # Установка прав
    chmod 644 "${BUILD_DIR}/rootfs/etc/os-release"
    chmod 644 "${BUILD_DIR}/rootfs/etc/fstab"
    chmod 600 "${BUILD_DIR}/rootfs/etc/shadow" 2>/dev/null || true
    
    # Создание пользователя
    log_info "Создание пользователя 'user'..."
    chroot "${BUILD_DIR}/rootfs" useradd -m -G sudo,audio,video,netdev -s /bin/bash user 2>/dev/null || true
    
    # Установка пароля для root и user
    echo "root:peredos" | chroot "${BUILD_DIR}/rootfs" chpasswd
    echo "user:peredos" | chroot "${BUILD_DIR}/rootfs" chpasswd
    
    log_success "Конфигурации применены"
}

# === Этап 3: Установка пакетов ===
stage3_packages() {
    log_step "Этап 3: Установка пакетов ПередОС"
    
    # Обновление репозиториев
    chroot "${BUILD_DIR}/rootfs" apt-get update
    
    # Базовые утилиты
    log_info "Установка базовых утилит..."
    chroot "${BUILD_DIR}/rootfs" apt-get install -y \
        bash-completion \
        htop \
        neofetch \
        lm-sensors \
        usbutils \
        pciutils \
        wireless-tools \
        wpasupplicant \
        net-tools \
        iputils-ping \
        traceroute \
        dnsutils \
        openssh-client \
        git \
        zip \
        unzip \
        tar \
        gzip \
        less \
        man-db
    
    # Графическое окружение
    log_info "Установка графического окружения GNOME..."
    chroot "${BUILD_DIR}/rootfs" apt-get install -y \
        gnome-session \
        gnome-shell \
        gnome-terminal \
        gnome-control-center \
        gnome-software \
        gnome-tweaks \
        gnome-calculator \
        gnome-calendar \
        gnome-clocks \
        gnome-screenshot \
        gnome-system-monitor \
        nautilus \
        mutter
    
    # Приложения
    log_info "Установка приложений..."
    chroot "${BUILD_DIR}/rootfs" apt-get install -y \
        firefox-esr \
        thunderbird \
        libreoffice \
        vlc \
        gimp \
        gedit
    
    # Безопасность
    log_info "Установка компонентов безопасности..."
    chroot "${BUILD_DIR}/rootfs" apt-get install -y \
        selinux-basics \
        selinux-policy-default \
        auditd \
        fail2ban \
        ufw \
        firewalld \
        flatpak \
        xdg-desktop-portal
    
    # Шрифты и темы
    log_info "Установка шрифтов и тем..."
    chroot "${BUILD_DIR}/rootfs" apt-get install -y \
        fonts-noto \
        fonts-dejavu \
        papirus-icon-theme \
        adwaita-icon-theme
    
    # Очистка
    log_info "Очистка..."
    chroot "${BUILD_DIR}/rootfs" apt-get clean
    chroot "${BUILD_DIR}/rootfs" apt-get autoremove -y
    
    log_success "Пакеты установлены"
}

# === Этап 4: Настройка брендинга ===
stage4_branding() {
    log_step "Этап 4: Применение брендинга ПередОС"
    
    # Копирование обоев
    mkdir -p "${BUILD_DIR}/rootfs/usr/share/backgrounds/peredos"
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
icon-theme='Papyrus'
cursor-theme='Adwaita'
font-name='Noto Sans 11'
monospace-font-name='Noto Sans Mono 11'

[org.gnome.desktop.wm.preferences]
titlebar-font='Noto Sans Bold 11'

[org.gnome.shell]
show-battery-percentage=true
EOF
    
    # Компиляция gsettings
    chroot "${BUILD_DIR}/rootfs" glib-compile-schemas /usr/share/glib-2.0/schemas/ 2>/dev/null || true
    
    log_success "Брендинг применён"
}

# === Этап 5: Создание Initramfs ===
stage5_initramfs() {
    log_step "Этап 5: Создание Initramfs"
    
    # Обновление initramfs
    chroot "${BUILD_DIR}/rootfs" update-initramfs -c -k all || true
    
    log_success "Initramfs создан"
}

# === Этап 6: Сборка ISO ===
stage6_iso() {
    log_step "Этап 6: Сборка ISO образа"
    
    rm -rf "${ISO_DIR}"
    mkdir -p "${ISO_DIR}/boot/grub"
    
    # Копирование ядра и initramfs
    local kernel_version
    kernel_version=$(ls "${BUILD_DIR}/rootfs/boot/vmlinuz-"* 2>/dev/null | head -1 | sed 's/.*vmlinuz-//')
    
    if [[ -z "$kernel_version" ]]; then
        log_warn "Ядро не найдено, используем заглушку"
        kernel_version="6.1.0-18-amd64"
    fi
    
    cp "${BUILD_DIR}/rootfs/boot/vmlinuz-${kernel_version}" "${ISO_DIR}/boot/vmlinuz" 2>/dev/null || true
    cp "${BUILD_DIR}/rootfs/boot/initrd.img-${kernel_version}" "${ISO_DIR}/boot/initramfs" 2>/dev/null || true
    
    # Создание SquashFS
    log_info "Создание SquashFS образа..."
    mksquashfs \
        "${BUILD_DIR}/rootfs" \
        "${ISO_DIR}/filesystem.squashfs" \
        -comp zstd \
        -Xcompression-level 15 \
        -noappend \
        -wildcards \
        -e "boot/*" \
        -e "proc/*" \
        -e "sys/*" \
        -e "dev/*" \
        -e "run/*" \
        -e "tmp/*"
    
    # GRUB конфигурация
    log_info "Создание GRUB конфигурации..."
    cat > "${ISO_DIR}/boot/grub/grub.cfg" << EOF
# ПередОС GRUB Config
set timeout=5
set default=0

# Тема
loadfont unicode

set menu_color_normal=cyan/blue
set menu_color_highlight=white/blue

# Заголовок
menuentry "Запустить ПередОС 1.0 (Pioneer)" --class peredos {
    set gfxpayload=keep
    linux /boot/vmlinuz root=/dev/ram0 quiet splash
    initrd /boot/initramfs
}

menuentry "Запустить ПередОС (Безопасный режим)" --class peredos {
    linux /boot/vmlinuz root=/dev/ram0 nomodeset single
    initrd /boot/initramfs
}

menuentry "Проверка памяти (memtest86+)" {
    linux16 /boot/memtest86+.bin
}
EOF
    
    # Создание ISO
    log_info "Сборка ISO..."
    grub-mkrescue \
        -o "${ISO_FILE}" \
        "${ISO_DIR}" \
        --modules="part_gpt part_msdos fat iso9660 zstd" \
        2>/dev/null || xorriso -as mkisofs \
            -iso-level 3 \
            -full-iso9660-filenames \
            -volid "PEREDOS_1.0" \
            -eltorito-boot boot/grub/grub.img \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            --eltorito-catalog boot/grub/boot.cat \
            "${ISO_DIR}"
    
    log_success "ISO образ собран: ${ISO_FILE}"
}

# === Этап 7: Очистка ===
stage7_cleanup() {
    log_step "Этап 7: Очистка"
    
    # Очистка монтирований
    umount "${BUILD_DIR}/rootfs/proc" 2>/dev/null || true
    umount "${BUILD_DIR}/rootfs/sys" 2>/dev/null || true
    umount "${BUILD_DIR}/rootfs/dev" 2>/dev/null || true
    
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
        log_info "Очистка build директории..."
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
