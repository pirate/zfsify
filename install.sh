#!/bin/sh
# zfs-on-boot v0.1: DESTRUCTIVE fresh reinstall, preserves root SSH and network settings.
set -eu
if [ "$(id -u)" != 0 ]; then echo 'Run as root: curl -fsSL URL | sudo sh' >&2; exit 1; fi
work=$(mktemp -d /tmp/zfs-on-boot.XXXXXXXX)
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT
cat > "$work/stage.sh" <<'ZFS_ON_BOOT_c1aff21517aac78497ce09a1f0fc7ba8d7defdb89256bd51d2ec648271b12565'
#!/bin/bash
# Run only on a fresh, disposable Ubuntu VPS. This is a REINSTALL.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
SOURCE=${1:?source directory required}
WORK=/var/lib/zfs-on-boot
ROOT=$WORK/root
die() { echo "zfs-on-boot: $*" >&2; exit 1; }
[[ $(id -u) = 0 ]] || die 'Run with sudo sh (or as root).'
. /etc/os-release
[[ $ID = ubuntu && $VERSION_ID = 24.04 && $(uname -m) = x86_64 ]] || die 'v0.1 supports Ubuntu 24.04 amd64 only.'
[[ ! -e /etc/zfs-on-boot-installed ]] || die 'Already installed; nothing to do.'
[[ ! -d /sys/firmware/efi ]] || die 'v0.1 supports legacy BIOS only; UEFI support is not yet tested.'
[[ -f /boot/grub/grub.cfg ]] || die 'GRUB is required.'
[[ $(findmnt -n -o FSTYPE /) = ext4 ]] || die 'Only a plain ext4 root partition is supported.'
[[ $(awk '/MemTotal/ {print $2}' /proc/meminfo) -ge 3800000 ]] || die 'At least 4 GiB RAM is required to build and run the installer.'
[[ $(lsblk -dn -o TYPE,FSTYPE | awk '$1=="disk" && $2!="iso9660" {n++} END {print n+0}') = 1 ]] || die 'Exactly one non-ISO disk is required; detach additional disks first.'
ROOTDEV=$(readlink -f "$(findmnt -n -o SOURCE /)")
[[ $(lsblk -dn -o TYPE "$ROOTDEV") = part ]] || die 'Root must be a direct disk partition (no LVM, RAID, or encryption).'
DISK=/dev/$(lsblk -dn -o PKNAME "$ROOTDEV")
[[ -b $DISK ]] || die 'Cannot resolve root disk.'
[[ $(findmnt -n -o FSTYPE --target /boot) = ext4 ]] || die '/boot must be on ext4.'
BOOT_MOUNT=$(findmnt -n -o TARGET --target /boot)
BOOT_PREFIX=/boot
if [[ $BOOT_MOUNT = /boot ]]; then
    BOOT_PREFIX=
    [[ /dev/$(lsblk -dn -o PKNAME "$(findmnt -n -o SOURCE /boot)") = "$DISK" ]] || die '/boot must be on the root disk.'
fi
[[ $(df -Pk /boot | awk 'NR==2 {print $4}') -ge 500000 ]] || die 'At least 500 MB free in /boot is required.'
[[ $(df -Pk / | awk 'NR==2 {print $4}') -ge 8000000 ]] || die 'At least 8 GB free disk space is required.'
[[ $(blockdev --getsize64 "$DISK") -ge 16000000000 ]] || die 'At least a 16 GB disk is required.'
[[ -s /root/.ssh/authorized_keys ]] || die 'A root SSH authorized_keys file is required.'
[[ ! -e $WORK ]] || die "$WORK already exists. Inspect it before retrying; use the documented cleanup procedure."
mkdir -m 700 "$WORK"
exec > >(tee -a "$WORK/stage.log") 2>&1
trap 'echo "Staging failed at line $LINENO; the disk has NOT been erased. See /var/lib/zfs-on-boot/stage.log."' ERR
echo 'THIS REINSTALLS UBUNTU AND ERASES ALL EXISTING DISK CONTENTS.'
echo "Target: $DISK. Preserving root SSH access, host keys, hostname, and network configuration only."
# Prevent inherited terminal input (including the rest of a curl pipe) reaching apt.
apt-get update </dev/null
apt-get install -y --no-install-recommends debootstrap cpio gzip python3 </dev/null
debootstrap --variant=minbase noble "$ROOT" http://archive.ubuntu.com/ubuntu
cat > "$ROOT/etc/apt/sources.list" <<'EOF'
deb http://archive.ubuntu.com/ubuntu noble main universe
deb http://archive.ubuntu.com/ubuntu noble-updates main universe
deb http://security.ubuntu.com/ubuntu noble-security main universe
EOF
printf '#!/bin/sh\nexit 101\n' > "$ROOT/usr/sbin/policy-rc.d"
chmod 755 "$ROOT/usr/sbin/policy-rc.d"
mount --rbind /dev "$ROOT/dev"
mount --make-rslave "$ROOT/dev"
mount -t proc proc "$ROOT/proc"
mount -t sysfs sysfs "$ROOT/sys"
cleanup_mounts() { umount -R "$ROOT/dev" 2>/dev/null || true; umount "$ROOT/proc" "$ROOT/sys" 2>/dev/null || true; }
trap cleanup_mounts EXIT
cp -L /etc/resolv.conf "$ROOT/etc/resolv.conf"
chroot "$ROOT" apt-get update </dev/null
# grub-pc-bin avoids package installation trying to install GRUB on the live disk.
chroot "$ROOT" apt-get install -y --no-install-recommends linux-image-virtual zfs-initramfs zfsutils-linux grub-pc-bin grub2-common openssh-server cloud-init netplan.io systemd-sysv systemd-resolved systemd-timesyncd udev sudo locales ca-certificates curl wget lsb-release python3 gdisk parted e2fsprogs dosfstools cpio gzip </dev/null
mkdir -p "$ROOT/root/.ssh" "$ROOT/etc/zfs-on-boot" "$ROOT/etc/ssh/sshd_config.d"
chmod 700 "$ROOT/root/.ssh"
cp /root/.ssh/authorized_keys "$ROOT/root/.ssh/authorized_keys"
chmod 600 "$ROOT/root/.ssh/authorized_keys"
cp /etc/ssh/ssh_host_* "$ROOT/etc/ssh/"
cp /etc/hostname "$ROOT/etc/hostname"
cp /etc/hosts "$ROOT/etc/hosts"
cp /etc/machine-id "$ROOT/etc/machine-id"
cp -a /etc/netplan/. "$ROOT/etc/netplan/"
chmod 600 "$ROOT"/etc/netplan/*.yaml
cat > "$ROOT/etc/ssh/sshd_config.d/10-zfs-on-boot.conf" <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
cat > "$ROOT/etc/cloud/cloud.cfg.d/90-zfs-on-boot.cfg" <<'EOF'
datasource_list: [ DigitalOcean, ConfigDrive, None ]
disable_root: false
ssh_deletekeys: false
# Preserve the configuration captured from this particular VPS.
network: {config: disabled}
growpart: {mode: 'off'}
resize_rootfs: false
EOF
# A fresh install, but the identity and access of this specific machine survive.
chroot "$ROOT" passwd -l root
chroot "$ROOT" systemctl enable ssh systemd-networkd systemd-resolved
chroot "$ROOT" zgenhostid -f
cat > "$ROOT/etc/modprobe.d/zfs-on-boot.conf" <<'EOF'
options zfs zfs_arc_max=268435456
EOF
printf '%s\n' "$DISK" > "$ROOT/etc/zfs-on-boot/disk"
blockdev --getsize64 "$DISK" > "$ROOT/etc/zfs-on-boot/disk-size"
blkid -s UUID -o value "$ROOTDEV" > "$ROOT/etc/zfs-on-boot/old-root-uuid"
cp "$SOURCE/ram-init.sh" "$ROOT/init"
chmod 755 "$ROOT/init"
# Capture address/route state as shell commands selected by MAC, not guessed eth0.
python3 - "$ROOT/etc/zfs-on-boot/network.sh" <<'PY'
import json, subprocess, sys, shlex
def ip(*args): return json.loads(subprocess.check_output(['ip','-j',*args]))
q=shlex.quote
lines=['#!/bin/bash', 'set -eu', 'ip link set lo up']
for link in ip('address','show'):
    if link['ifname']=='lo' or not link.get('address'): continue
    name=link['ifname']; mac=link['address']
    lines += [f"iface=$(for p in /sys/class/net/*; do if [ \"$(cat \"$p/address\")\" = {q(mac)} ]; then basename \"$p\"; break; fi; done)", '[ -n "$iface" ]', 'ip link set "$iface" up']
    for addr in link.get('addr_info',[]):
        if addr['scope']=='global':
            lines.append(f"ip addr replace {q(addr['local']+'/'+str(addr['prefixlen']))} dev \"$iface\"")
    for fam in ['-4','-6']:
        for route in ip(fam,'route','show','dev',name):
            if route.get('protocol')=='kernel' or route.get('dst','').startswith('fe80:'): continue
            cmd=f"ip {fam} route replace {q(route.get('dst','default'))}"
            if 'gateway' in route: cmd+=' via '+q(route['gateway'])
            cmd+=' dev "$iface"'
            if 'metric' in route: cmd+=' metric '+str(route['metric'])
            if 'onlink' in route.get('flags',[]): cmd+=' onlink'
            lines.append(cmd)
open(sys.argv[1],'w').write('\n'.join(lines)+'\n')
PY
chmod 700 "$ROOT/etc/zfs-on-boot/network.sh"
KERNEL=$(ls "$ROOT"/boot/vmlinuz-* | sort -V | tail -1)
KVER=${KERNEL##*/vmlinuz-}
chroot "$ROOT" modinfo -k "$KVER" zfs >/dev/null
printf '%s\n' "$KVER" > "$ROOT/etc/zfs-on-boot/kernel"
# The target initramfs is generated after the real ZFS pool exists.
rm -f "$ROOT"/boot/initrd.img-* "$ROOT/initrd.img" "$ROOT/initrd.img.old"
chroot "$ROOT" apt-get clean
rm -rf "$ROOT/var/lib/apt/lists/"* "$ROOT/usr/share/doc/"* "$ROOT/usr/share/man/"*
rm -f "$ROOT/usr/sbin/policy-rc.d"
cleanup_mounts
trap - EXIT
# Refuse to stage a RAM image too large for the machine.
ROOT_BYTES=$(du -sx --block-size=1 "$ROOT" | awk '{print $1}')
RAM_BYTES=$(awk '/MemTotal/ {printf "%.0f", $2*1024}' /proc/meminfo)
(( ROOT_BYTES + 1600000000 < RAM_BYTES )) || die "RAM installer is too large ($ROOT_BYTES bytes) for available RAM."
(cd "$ROOT" && find . -xdev -print0 | cpio --null -o --format=newc 2>"$WORK/cpio.log" | gzip -1) > "$WORK/installer.img"
gzip -t "$WORK/installer.img"
IMAGE_BYTES=$(stat -c %s "$WORK/installer.img")
BOOT_FREE=$(df -B1 /boot | awk 'NR==2 {print $4}')
(( IMAGE_BYTES + 50000000 < BOOT_FREE )) || die 'The complete installer does not fit in /boot; no boot entry was changed.'
mkdir -m 700 /boot/zfs-on-boot
cp "$KERNEL" /boot/zfs-on-boot/vmlinuz
cp "$WORK/installer.img" /boot/zfs-on-boot/installer.img
sha256sum /boot/zfs-on-boot/vmlinuz /boot/zfs-on-boot/installer.img > "$WORK/SHA256SUMS"
BOOT_UUID=$(findmnt -n -o UUID --target /boot)
cat > /etc/grub.d/09_zfs_on_boot <<EOF
#!/bin/sh
cat <<'GRUB'
menuentry 'ZFS on boot installer (ERASE DISK)' --id zfs-on-boot-install {
    search --no-floppy --fs-uuid --set=root $BOOT_UUID
    linux $BOOT_PREFIX/zfs-on-boot/vmlinuz rdinit=/init console=ttyS0,115200n8 console=tty0 panic=0
    initrd $BOOT_PREFIX/zfs-on-boot/installer.img
}
GRUB
EOF
chmod 755 /etc/grub.d/09_zfs_on_boot
# Put the standard Ubuntu entry first so an interrupted one-shot boot falls back.
mv /etc/grub.d/09_zfs_on_boot /etc/grub.d/41_zfs_on_boot
update-grub
grub-reboot zfs-on-boot-install
grub-editenv /boot/grub/grubenv list | grep -qx next_entry=zfs-on-boot-install
echo 'Installer staged and checked. Rebooting now. SSH returns in the RAM installer and then in Ubuntu.'
sync
shutdown -r +0 'zfs-on-boot installer staged'

ZFS_ON_BOOT_c1aff21517aac78497ce09a1f0fc7ba8d7defdb89256bd51d2ec648271b12565
cat > "$work/ram-init.sh" <<'ZFS_ON_BOOT_9b3b5ade4c747b0f38d94942542eca345c2540f1cf860053251d3d0d5e23158c'
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

ZFS_ON_BOOT_9b3b5ade4c747b0f38d94942542eca345c2540f1cf860053251d3d0d5e23158c
bash "$work/stage.sh" "$work" </dev/null
