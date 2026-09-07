#!/bin/bash
set -x
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
mount -t devtmpfs devtmpfs /dev
mkdir -p /proc /sys /run /dev/pts /target
mount -t proc proc /proc
ln -sfn /proc/self/fd /dev/fd
ln -sfn /proc/self/fd/0 /dev/stdin
ln -sfn /proc/self/fd/1 /dev/stdout
ln -sfn /proc/self/fd/2 /dev/stderr
mount -t sysfs sysfs /sys
mount -t tmpfs -o mode=755 tmpfs /run
mount -t devpts devpts /dev/pts
exec </dev/tty0 >/dev/tty0 2>&1
set -Eeuo pipefail
rescue() {
    trap - ERR
    echo "INSTALLATION FAILED at line $1. Keeping RAM OS alive; use SSH or the provider console."
    echo "Log: /run/zfs-on-boot.log. Do not reboot after disk erasure."
    while true; do /bin/bash </dev/tty0 >/dev/tty0 2>&1 || true; sleep 2; done
}
trap 'rescue "$LINENO"' ERR
exec > >(tee -a /run/zfs-on-boot.log) 2>&1
echo 'Starting independent ZFS installer in RAM.'
/usr/lib/systemd/systemd-udevd --daemon
udevadm trigger --action=add
udevadm settle
modprobe zfs
mkdir -p /run/sshd
/usr/sbin/sshd -E /run/sshd.log
bash /etc/zfs-on-boot/network.sh
echo 'SSH is available with the original host keys and authorized keys.'
DISK=$(cat /etc/zfs-on-boot/disk)
[[ -b $DISK ]]
[[ $(blockdev --getsize64 "$DISK") = "$(cat /etc/zfs-on-boot/disk-size)" ]]
[[ $(lsblk -dn -o TYPE,FSTYPE | awk '$1=="disk" && $2!="iso9660" {n++} END {print n+0}') = 1 ]]
[[ $(findmnt -n -o FSTYPE /) = rootfs || $(findmnt -n -o FSTYPE /) = tmpfs ]]
[[ -z $(lsblk -nr -o MOUNTPOINTS "$DISK" | tr -d '[:space:]') ]]
[[ $(blkid -U "$(cat /etc/zfs-on-boot/old-root-uuid)") = "$DISK"* ]]
[[ $(uname -r) = "$(cat /etc/zfs-on-boot/kernel)" ]]
[[ -s /root/.ssh/authorized_keys && -s /boot/vmlinuz-$(uname -r) ]]
[[ -z $(zpool list -H -o name 2>/dev/null) ]]
echo "Preflight complete. ERASING $DISK now."
sgdisk --zap-all "$DISK"
sgdisk -n 1:1MiB:+1MiB -t 1:EF02 -c 1:BIOS "$DISK"
sgdisk -n 2:0:0 -t 2:BF01 -c 2:rpool "$DISK"
partprobe "$DISK"
udevadm settle
part() { lsblk -nrpo NAME,PARTN "$DISK" | awk -v n="$1" '$2==n {print $1}'; }
ZPART=$(part 2)
[[ -b $ZPART ]]
# GRUB reads /boot from the same ZFS dataset as /. Keep its on-disk features
# within the compatibility profile shipped by Ubuntu's OpenZFS package.
zpool create -f -o ashift=12 -o compatibility=grub2 -o cachefile=none -O compression=lz4 -O atime=off -O xattr=sa -O acltype=posixacl -O mountpoint=none -R /target rpool "$ZPART"
zfs create -o mountpoint=none rpool/ROOT
zfs create -o mountpoint=/ -o canmount=noauto rpool/ROOT/ubuntu
zfs mount rpool/ROOT/ubuntu
zpool set bootfs=rpool/ROOT/ubuntu rpool
mkdir -p /target/boot
echo 'Copying Ubuntu from RAM to ZFS.'
tar --one-file-system --numeric-owner --xattrs --acls --exclude=./target --exclude=./proc --exclude=./sys --exclude=./dev --exclude=./run --exclude=./tmp --exclude=./init --exclude=./etc/zfs-on-boot -C / -cf - . | tar --numeric-owner --xattrs --acls -C /target -xf -
mkdir -p /target/{proc,sys,dev,run,tmp}
chmod 1777 /target/tmp
mount --rbind /dev /target/dev
mount --make-rslave /target/dev
mount -t proc proc /target/proc
mount -t sysfs sysfs /target/sys
mount --bind /run /target/run
printf '# / and /boot are on rpool/ROOT/ubuntu, mounted by zfs-initramfs.\n' > /target/etc/fstab
mkdir -p /target/etc/default/grub.d
cat > /target/etc/default/grub.d/50-zfs-on-boot.cfg <<'EOF'
GRUB_CMDLINE_LINUX="root=ZFS=rpool/ROOT/ubuntu"
GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyS0,115200n8"
GRUB_DISABLE_OS_PROBER=true
GRUB_TIMEOUT=2
EOF
echo 'RESUME=none' > /target/etc/initramfs-tools/conf.d/resume
zpool set cachefile=/target/etc/zfs/zpool.cache rpool
chroot /target update-initramfs -c -k "$(uname -r)"
[[ $(chroot /target grub-probe /boot) = zfs ]]
chroot /target grub-install --target=i386-pc --recheck "$DISK"
chroot /target update-grub
ln -sf /run/systemd/resolve/stub-resolv.conf /target/etc/resolv.conf
# Record identity installation now: providers may regenerate stale machine IDs
# on first boot because they look like an un-generalized image clone.
touch /target/etc/machine-id
mkdir -p /target/var/lib/dbus
ln -sf /etc/machine-id /target/var/lib/dbus/machine-id
printf 'Installed by zfs-on-boot at %s\n' "$(date -u +%FT%TZ)" > /target/etc/zfs-on-boot-installed
mkdir -p /target/var/log/zfs-on-boot
cp /run/zfs-on-boot.log /target/var/log/zfs-on-boot/install.log
sync
umount /target/run /target/proc /target/sys
umount -R /target/dev
zpool export rpool
echo 'Installation complete. Rebooting into Ubuntu on ZFS.'
sync
reboot -f
