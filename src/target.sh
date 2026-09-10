#!/bin/bash
# Called in RAM after verified copy. Boot setup is deliberately after verification.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
MODE=$(cat /etc/zfs-on-boot/mode)
DISK=$(cat /etc/zfs-on-boot/disk)
if [[ $MODE = erase ]]; then
    python3 /etc/zfs-on-boot/identity.py /target /etc/zfs-on-boot/identity.tar
    tar --numeric-owner --acls --xattrs -xpf /run/priority.tar -C /target
fi
# Both modes retain the old /etc; replace only disk/boot-specific configuration.
rm -f /target/etc/grub.d/41_zfs_on_boot
rm -rf /target/boot/zfs-on-boot /target/var/lib/zfs-on-boot
mkdir -p /target/boot/grub /target/{proc,sys,dev,run,tmp} /target/etc/{default/grub.d,modprobe.d,cloud/cloud.cfg.d,zfs,initramfs-tools/conf.d}
chmod 1777 /target/tmp
mount --rbind /dev /target/dev
mount --make-rslave /target/dev
mount -t proc proc /target/proc
mount -t sysfs sysfs /target/sys
mount --bind /run /target/run
cp /etc/hostid /target/etc/hostid
cp /etc/modprobe.d/zfs-on-boot.conf /target/etc/modprobe.d/zfs-on-boot.conf
cp /target/etc/fstab /target/etc/fstab.before-zfsify
{ printf '# / and /boot are on rpool/ROOT/ubuntu, mounted by the ZFS initramfs.\n';
  awk '$1 ~ /^#/ || NF == 0 || ($2 != "/" && $2 != "/boot" && $2 != "/boot/efi" && $3 != "swap")' /target/etc/fstab.before-zfsify;
} > /target/etc/fstab
# ZFSBootMenu supplies root= dynamically, including for recovery clones.
zfs set org.zfsbootmenu:commandline="$(cat /etc/zfs-on-boot/boot/cmdline-ubuntu)" rpool/ROOT
# Remove GRUB's package hooks so future kernel updates cannot reinstall it.
mapfile -t OLD_BOOT_PACKAGES < <(chroot /target dpkg-query -W -f='${db:Status-Status} ${binary:Package}\n' 'grub*' 'shim-signed*' 2>/dev/null | awk '$1!="not-installed" {print $2}')
if (( ${#OLD_BOOT_PACKAGES[@]} )); then
    # Ubuntu cloud images mark shim-signed essential. Authorize replacing only
    # the old boot stack; abort if APT proposes removing unrelated packages.
    chroot /target apt-get -s purge "${OLD_BOOT_PACKAGES[@]}" > /run/zfsify-boot-removal.plan
    while read -r package; do
        case $package in grub-*|grub2-*|shim-signed*|os-prober) ;; *) echo "Unexpected package removal: $package" >&2; exit 1;; esac
    done < <(awk '$1=="Remv" || $1=="Purg" {print $2}' /run/zfsify-boot-removal.plan)
    chroot /target apt-get purge -y --allow-remove-essential "${OLD_BOOT_PACKAGES[@]}"
fi
rm -rf /target/boot/grub
cat > /target/etc/cloud/cloud.cfg.d/99-zfs-on-boot.cfg <<'EOF'
network: {config: disabled}
growpart: {mode: 'off'}
resize_rootfs: false
ssh_deletekeys: false
EOF
echo 'RESUME=none' > /target/etc/initramfs-tools/conf.d/resume
mkdir -p /target/usr/local/{lib/zfs-on-boot,sbin}
cp /usr/local/lib/zfs-on-boot/progress.py /target/usr/local/lib/zfs-on-boot/
cp /usr/local/sbin/zfs-on-boot-{grow,status} /target/usr/local/sbin/
cp /etc/systemd/system/zfs-on-boot-grow.service /target/etc/systemd/system/
chroot /target systemctl enable zfs-on-boot-grow.service
zpool set cachefile=/target/etc/zfs/zpool.cache rpool
# Existing kernels must have ZFS modules too; install missing module packages in
# staging, never download anything after the source disk is removed.
DRACUT=0
if [[ $(chroot /target dpkg-query -W -f='${db:Status-Status}' dracut 2>/dev/null || true) = installed ]]; then
    DRACUT=1
    mkdir -p /target/etc/dracut.conf.d
    # Let ZFSBootMenu choose the root dataset; do not bake RAM rescue's command
    # line or a particular boot environment into this or future initramfs files.
    cat > /target/etc/dracut.conf.d/90-zfsify.conf <<'EOF'
add_dracutmodules+=" zfs "
hostonly="no"
hostonly_cmdline="no"
EOF
fi
for kernel in /target/boot/vmlinuz-*; do
    version=${kernel##*/vmlinuz-}
    chroot /target modinfo -k "$version" zfs >/dev/null
    if (( DRACUT )); then
        chroot /target dracut --force "/boot/initrd.img-$version" "$version"
    elif [[ -f /target/boot/initrd.img-$version ]]; then
        chroot /target update-initramfs -u -k "$version"
    else
        chroot /target update-initramfs -c -k "$version"
    fi
done
cp /usr/local/sbin/zfsify-snapshot /target/usr/local/sbin/
mkdir -p /target/etc/apt/apt.conf.d
printf 'DPkg::Pre-Invoke { "/usr/local/sbin/zfsify-snapshot apt"; };\n' > /target/etc/apt/apt.conf.d/80-zfsify-snapshot
cat > /target/etc/systemd/system/zfsify-snapshot.service <<'UNIT'
[Unit]
Description=Create a daily ZFS root recovery snapshot
After=zfs-mount.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/zfsify-snapshot daily
UNIT
cat > /target/etc/systemd/system/zfsify-snapshot.timer <<'UNIT'
[Unit]
Description=Daily ZFS root recovery snapshot
[Timer]
OnCalendar=daily
Persistent=true
[Install]
WantedBy=timers.target
UNIT
chroot /target systemctl enable zfsify-snapshot.timer
umount /target/run /target/proc
# UEFI package hooks may mount efivarfs beneath the chroot's sysfs.
umount -R /target/sys
umount -R /target/dev
