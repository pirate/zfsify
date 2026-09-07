#!/bin/bash
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
ACTION=${1:?} ROOT=${2:?}
FIRMWARE=$(cat "$ROOT/etc/zfs-on-boot/firmware" 2>/dev/null || cat /etc/zfs-on-boot/firmware)
KCL='zbm.timeout=15 zbm.prefer=rpool zbm.sort_key=creation zfs.zfs_arc_min=16777216 zfs.zfs_arc_max=67108864 console=ttyS0,115200n8 console=tty0'
if [[ $ACTION = download ]]; then
    DEST=$ROOT/etc/zfs-on-boot/zbm
    mkdir -p "$DEST"
    if [[ $FIRMWARE = uefi ]]; then
        curl --fail --location --retry 3 https://github.com/zbm-dev/zfsbootmenu/releases/download/v3.1.0/zfsbootmenu-release-x86_64-v3.1.0-linux6.6.EFI -o "$DEST/zfsbootmenu.EFI"
        echo 'd4a67012f03659c91a1f227aa6739b4b41bd5c7d0bd64e89aa7358bf08826cfd  '"$DEST/zfsbootmenu.EFI" | sha256sum -c -
        curl --fail --location --retry 3 https://github.com/zbm-dev/zfsbootmenu/releases/download/v3.1.0/zbm-kcl -o "$DEST/zbm-kcl"
        echo '16edae3eee5df9a0b133734bc4d8a8cb68ca73ac30f98cb21cea3212b051ff01  '"$DEST/zbm-kcl" | sha256sum -c -
        chroot "$ROOT" bash /etc/zfs-on-boot/zbm/zbm-kcl -d -a "$KCL" /etc/zfs-on-boot/zbm/zfsbootmenu.EFI
        exit 0
    fi
    URL=https://github.com/zbm-dev/zfsbootmenu/releases/download/v3.1.0/zfsbootmenu-release-x86_64-v3.1.0-linux6.6.tar.gz
    curl --fail --location --retry 3 "$URL" -o "$DEST/components.tar.gz"
    echo '7c0ff5eb3fc4ac33c0885ce9a23eef90e9c20fbadc44fc95302d9247ab875fb8  '"$DEST/components.tar.gz" | sha256sum -c -
    tar -xzf "$DEST/components.tar.gz" --strip-components=1 -C "$DEST"
    rm "$DEST/components.tar.gz"
    test -s "$DEST/vmlinuz-bootmenu" && test -s "$DEST/initramfs-bootmenu.img"
    exit 0
fi
[[ $ACTION = install ]]
DISK=${3:?} BOOTDEV=${4:?}
if [[ $FIRMWARE = uefi ]]; then
    mkfs.vfat -F 32 -n ZFSBOOTMENU "$BOOTDEV"
    mkdir -p "$ROOT/boot/efi"
    mount "$BOOTDEV" "$ROOT/boot/efi"
    mkdir -p "$ROOT/boot/efi/EFI/BOOT" "$ROOT/boot/efi/EFI/ZFSBootMenu"
    cp /etc/zfs-on-boot/zbm/zfsbootmenu.EFI "$ROOT/boot/efi/EFI/ZFSBootMenu/zfsbootmenu.EFI"
    cp /etc/zfs-on-boot/zbm/zfsbootmenu.EFI "$ROOT/boot/efi/EFI/BOOT/BOOTX64.EFI"
    printf 'UUID=%s /boot/efi vfat defaults,umask=0077 0 2\n' "$(blkid -s UUID -o value "$BOOTDEV")" >> "$ROOT/etc/fstab"
    printf 'ZFSBootMenu 3.1.0; upstream UEFI linux6.6\n' > "$ROOT/etc/zfsbootmenu-version"
    sync
    umount "$ROOT/boot/efi"
    efibootmgr --create --disk "$DISK" --part 1 --label ZFSBootMenu --loader '\EFI\ZFSBootMenu\zfsbootmenu.EFI'
    exit 0
fi
# Syslinux's GPT boot code finds partition attribute bit 2. Keep the GPT intact.
mkfs.ext4 -F -O '^64bit,^metadata_csum' -L ZFSBOOTMENU "$BOOTDEV"
mkdir -p "$ROOT/boot/syslinux"
mount "$BOOTDEV" "$ROOT/boot/syslinux"
cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "$ROOT/boot/syslinux/"
cp /etc/zfs-on-boot/zbm/{vmlinuz-bootmenu,initramfs-bootmenu.img} "$ROOT/boot/syslinux/"
cat > "$ROOT/boot/syslinux/syslinux.cfg" <<'CFG'
SERIAL 0 115200
DEFAULT zfsbootmenu
PROMPT 0
TIMEOUT 10
LABEL zfsbootmenu
    LINUX /vmlinuz-bootmenu
    INITRD /initramfs-bootmenu.img
    APPEND zbm.timeout=15 zbm.prefer=rpool zbm.sort_key=creation zfs.zfs_arc_min=16777216 zfs.zfs_arc_max=67108864 console=ttyS0,115200n8 console=tty0
CFG
extlinux --install "$ROOT/boot/syslinux"
printf 'UUID=%s /boot/syslinux ext4 defaults 0 2\n' "$(blkid -s UUID -o value "$BOOTDEV")" >> "$ROOT/etc/fstab"
printf 'ZFSBootMenu 3.1.0; upstream release components linux6.6\n' > "$ROOT/etc/zfsbootmenu-version"
sync
umount "$ROOT/boot/syslinux"
# Activate the BIOS loader only after its files are durable.
dd if=/usr/lib/syslinux/mbr/gptmbr.bin of="$DISK" bs=440 count=1 conv=notrunc,fsync
