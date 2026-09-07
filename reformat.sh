#!/bin/sh
# zfsify: preserve by default; --erase retains configuration and users only.
set -eu
if [ "$(id -u)" != 0 ]; then echo 'Run as root: curl -fsSL URL | sudo sh' >&2; exit 1; fi
work=$(mktemp -d /tmp/zfs-on-boot.XXXXXXXX)
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT
cat > "$work/stage.sh" <<'ZFS_ON_BOOT_f3adb0710b4f84518c9b98d784ee768a655d56edb260905e44b505a44e16395b'
#!/bin/bash
# Preserve an ext4 Ubuntu installation by migrating through a RAM rescue OS.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
SOURCE=${1:?source directory required}
shift
MODE=preserve
for arg in "$@"; do
    case "$arg" in
        --erase) MODE=erase ;;
        --help|-h) echo 'Usage: curl -fsSL URL | sudo sh -s -- [--erase]'; exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done
export LC_ALL=C
[[ -t 1 ]] && export ZFS_PROGRESS_TTY=1
PROGRESS=$SOURCE/progress.py
phase() { local n=$1 label=$2; shift 2; python3 "$PROGRESS" run --phase "$n" --label "$label" --devices "$DISK,$ROOTDEV" -- "$@"; }
WORK=/var/lib/zfs-on-boot
ROOT=$WORK/root
die() { echo "zfs-on-boot: $*" >&2; exit 1; }
[[ $(id -u) = 0 ]] || die 'Run with sudo sh (or as root).'
. /etc/os-release
[[ $ID = ubuntu && $VERSION_ID = 24.04 && $(uname -m) = x86_64 ]] || die 'This release supports Ubuntu 24.04 amd64 only.'
[[ ! -e /etc/zfs-on-boot-installed ]] || die 'Already installed; nothing to do.'
[[ ! -d /sys/firmware/efi ]] || die 'This release supports legacy BIOS only; UEFI support is not yet tested.'
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
read -r FS_BYTES USED_BYTES < <(df -B1 --output=size,used / | tail -1)
USED_PCT=$(awk -v u="$USED_BYTES" -v s="$FS_BYTES" 'BEGIN {printf "%.2f",100*u/s}')
echo "Root filesystem: $ROOTDEV on $DISK | used $USED_PCT% ($USED_BYTES / $FS_BYTES bytes)"
if (( USED_BYTES * 2 >= FS_BYTES )) && [[ $MODE != erase ]]; then
    cat <<'EOF'
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! WARNING: ROOT IS AT LEAST 50% USED. PRESERVATION IS NOT ELIGIBLE.     !!
!! The alternative ERASES THIS ENTIRE DISK and installs fresh Ubuntu.  !!
!! Applications and data are deleted. /etc, users, SSH keys and        !!
!! basic settings survive. There is no automatic fallback to erasure. !!
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
EOF
    answer=
    if { exec 3<>/dev/tty; } 2>/dev/null; then
        printf 'Wipe the disk and install fresh Ubuntu? Type y and press Enter: ' >&3
        IFS= read -r answer <&3 || true
        exec 3>&-
    fi
    [[ $answer = y ]] || die 'Cancelled. To explicitly erase noninteractively, pass --erase.'
    MODE=erase
fi
[[ $(df -Pk /boot | awk 'NR==2 {print $4}') -ge 500000 ]] || die 'At least 500 MB free in /boot is required.'
[[ $(df -Pk / | awk 'NR==2 {print $4}') -ge 8000000 ]] || die 'At least 8 GB free disk space is required for staging, including erase mode.'
[[ $(blockdev --getsize64 "$DISK") -ge 16000000000 ]] || die 'At least a 16 GB disk is required.'
[[ $(blockdev --getss "$DISK") = 512 ]] || die 'Only 512-byte logical sectors are supported.'
[[ -s /root/.ssh/authorized_keys ]] || die 'A root SSH authorized_keys file is required.'
[[ ! -e $WORK ]] || die "$WORK already exists. Inspect it before retrying; use the documented cleanup procedure."
[[ ! -d /boot/zfs-on-boot ]] || die 'Old boot staging files exist; inspect them before retrying.'
# Refuse layouts containing data that the root-only copy would miss.
if [[ $MODE = preserve ]]; then
    while read -r target fstype; do
        case "$fstype" in ext4|ext3|ext2|xfs|btrfs|zfs|vfat|ntfs|fuse.*)
            [[ $target = / || $target = /boot || $target = /boot/efi ]] || die "Additional filesystem mounted at $target is unsupported." ;;
        esac
    done < <(findmnt -rn -o TARGET,FSTYPE)
    sfdisk --json "$DISK" > "$SOURCE/table.json"
    python3 "$SOURCE/plan.py" "$SOURCE/table.json" "$ROOTDEV" "$(findmnt -n -o SOURCE --target /boot)" "$(findmnt -n -o SOURCE --target /boot/efi 2>/dev/null || true)" > "$SOURCE/plan.env"
fi
lsblk -o NAME,PATH,SIZE,FSTYPE,MOUNTPOINTS "$DISK"
PREFIX=$DISK; [[ $DISK = *[0-9] ]] && PREFIX=${DISK}p
if [[ $MODE = preserve ]]; then
    cat <<EOF
PRESERVE: your Ubuntu installation, users, applications and files move to ZFS.
Devices: source $ROOTDEV; temporary ${PREFIX}32; final ${PREFIX}2.
$DISK (tiny bootloader area omitted):
  [              original ext4              ]
  [       smaller ext4      ][ temporary ZFS ]  shrink offline; copy + verify
  [       new ZFS member    ][ temporary ZFS ]  attach mirror; resilver
  [       new ZFS member    ][ free space    ]  detach temporary member
  [                   ZFS                   ]  grow; / and /boot on ZFS
The server reboots into RAM. Services are offline during migration.
Original ext4 is removed only after the copy is checksum-verified.
Power loss during repartitioning can require provider recovery.
EOF
else
    cat <<EOF
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! ERASE MODE: ALL EXISTING DATA ON $DISK WILL BE DELETED.
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  [ existing partitions + ALL their data ]
  [ 1 MiB BIOS ][ ZFS: fresh Ubuntu / and /boot ]
Devices: erase $DISK; create ${PREFIX}1 (BIOS) and ${PREFIX}2 (ZFS).
/etc, users, SSH authorized_keys and basic settings are retained.
Application data and other home-directory contents are removed.
EOF
fi
cat <<'EOF'
10 phases: preflight > prepare RAM > stage reboot > shrink/format > copy
           > checksum verify > configure boot > relocate > expand > finish
Live status includes logical copy bytes, MB/s and block-device IOPS.
SSH disconnects at reboot. Reconnect and run: zfs-on-boot-status
Package/metadata phases have no meaningful byte total and show n/a.
EOF
for (( remaining=15; remaining>0; remaining-- )); do
    printf '\rStarting %s in %2ds. Press Ctrl-C to cancel. ' "$MODE" "$remaining"
    sleep 1
done
printf '\n'
mkdir -m 700 "$WORK"
exec > >(tee -a "$WORK/stage.log") 2>&1
trap 'echo "Staging failed at line $LINENO; the disk has NOT been erased. See /var/lib/zfs-on-boot/stage.log."' ERR
phase 1 'Preflight passed; permission and countdown complete' true
if [[ $MODE = erase ]]; then
    # Capture configuration before APT/staging modifies it. This archive is private.
    tar --numeric-owner --acls --xattrs --exclude=etc/grub.d/41_zfs_on_boot -cpf "$WORK/identity.tar" -C / etc var/lib/cloud usr/share/keyrings
    # Generated AppArmor include files are policy, not application payloads.
    for settings in usr/local/share/ca-certificates var/lib/snapd/apparmor; do
        [[ ! -d /$settings ]] || tar --numeric-owner --acls --xattrs -rpf "$WORK/identity.tar" -C / "$settings"
    done
    python3 - "$WORK/identity-files" <<'IDENTITY'
import os, pwd, sys
paths=set()
for user in pwd.getpwall():
    home=user.pw_dir
    if home in ('/', '/nonexistent', '/dev/null') or not os.path.isdir(home): continue
    if user.pw_uid != 0 and user.pw_uid < 1000: continue
    paths.add(home.lstrip('/'))
    for rel in ('.ssh', '.ssh/authorized_keys', '.ssh/authorized_keys2'):
        path=os.path.join(home, rel)
        if os.path.lexists(path): paths.add(path.lstrip('/'))
open(sys.argv[1], 'wb').write(b''.join(os.fsencode(path)+b'\0' for path in sorted(paths)))
IDENTITY
    tar --numeric-owner --acls --xattrs --no-recursion --null -rpf "$WORK/identity.tar" -C / -T "$WORK/identity-files"
fi
mkdir -p /usr/local/lib/zfs-on-boot /usr/local/sbin
cp "$PROGRESS" /usr/local/lib/zfs-on-boot/progress.py
install -m 755 "$SOURCE/status.sh" /usr/local/sbin/zfs-on-boot-status
# Prevent inherited terminal input (including the rest of a curl pipe) reaching apt.
phase 2 'Update Ubuntu package indexes' apt-get update
phase 2 'Install staging tools' apt-get install -y --no-install-recommends debootstrap cpio gzip python3
if [[ $MODE = preserve ]]; then
    # Install boot support into the OS that will actually be migrated.
    phase 2 'Prepare existing Ubuntu for ZFS boot' apt-get install -y --no-install-recommends linux-image-virtual zfs-initramfs zfsutils-linux grub-pc-bin grub2-common cloud-guest-utils rsync
fi
phase 2 'Build independent RAM rescue Ubuntu' debootstrap --variant=minbase noble "$ROOT" http://archive.ubuntu.com/ubuntu
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
phase 2 'Update rescue package indexes' chroot "$ROOT" apt-get update
# grub-pc-bin avoids package installation trying to install GRUB on the live disk.
phase 2 'Install RAM rescue packages' chroot "$ROOT" apt-get install -y --no-install-recommends linux-image-virtual zfs-initramfs zfsutils-linux grub-pc-bin grub2-common openssh-server cloud-init netplan.io systemd-sysv systemd-resolved systemd-timesyncd udev sudo locales ca-certificates curl wget lsb-release python3 gdisk parted e2fsprogs dosfstools cpio gzip rsync cloud-guest-utils apparmor </dev/null
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
[[ $MODE != erase ]] || cp "$WORK/identity.tar" "$ROOT/etc/zfs-on-boot/identity.tar"
printf '%s\n' "$MODE" > "$ROOT/etc/zfs-on-boot/mode"
printf '%s\n' "$ROOTDEV" > "$ROOT/etc/zfs-on-boot/old-root-device"
if [[ $BOOT_MOUNT = /boot ]]; then
    findmnt -n -o UUID /boot > "$ROOT/etc/zfs-on-boot/old-boot-uuid"
fi
[[ $MODE != preserve ]] || cp "$SOURCE/plan.env" "$ROOT/etc/zfs-on-boot/plan.env"
mkdir -p "$ROOT/usr/local/lib/zfs-on-boot" "$ROOT/usr/local/sbin"
cp "$PROGRESS" "$ROOT/usr/local/lib/zfs-on-boot/progress.py"
install -m 755 "$SOURCE/status.sh" "$ROOT/usr/local/sbin/zfs-on-boot-status"
install -m 755 "$SOURCE/grow.sh" "$ROOT/usr/local/sbin/zfs-on-boot-grow"
cp "$SOURCE/grow.service" "$ROOT/etc/systemd/system/zfs-on-boot-grow.service"
cp "$SOURCE/target.sh" "$ROOT/etc/zfs-on-boot/target.sh"
cp "$SOURCE/identity.py" "$ROOT/etc/zfs-on-boot/identity.py"
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
phase 3 'Compress and stage RAM boot image' bash -o pipefail -c 'cd "$1"; find . -xdev -print0 | cpio --null -o --format=newc | gzip -1 > "$2"' _ "$ROOT" "$WORK/installer.img"
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
menuentry 'ZFS on boot installer ($MODE)'  --id zfs-on-boot-install {
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

ZFS_ON_BOOT_f3adb0710b4f84518c9b98d784ee768a655d56edb260905e44b505a44e16395b
cat > "$work/ram-init.sh" <<'ZFS_ON_BOOT_b0d25922822fd674c6760c8406d94b78bfa4036c0ccc9a417c64bf8c8fb0e568'
#!/bin/bash
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
mount -t devtmpfs devtmpfs /dev
mkdir -p /proc /sys /run /dev/pts /target /old
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
    echo "INSTALLATION FAILED at line $1. RAM rescue remains available over SSH."
    echo 'Run zfs-on-boot-status; logs: /run/zfs-on-boot.log and /var/log/zfs-on-boot/progress.log.'
    echo 'Do not reboot after source removal. Use the provider console if SSH is unavailable.'
    while true; do /bin/bash </dev/tty0 >/dev/tty0 2>&1 || true; sleep 2; done
}
trap 'rescue "$LINENO"' ERR
exec > >(tee -a /run/zfs-on-boot.log) 2>&1
/usr/lib/systemd/systemd-udevd --daemon
udevadm trigger --action=add
udevadm settle
modprobe zfs
mkdir -p /run/sshd
/usr/sbin/sshd -E /run/sshd.log
bash /etc/zfs-on-boot/network.sh
DISK=$(cat /etc/zfs-on-boot/disk)
MODE=$(cat /etc/zfs-on-boot/mode)
ROOTDEV=$(blkid -U "$(cat /etc/zfs-on-boot/old-root-uuid)")
DEVICES=$DISK,$ROOTDEV
phase() { local n=$1 label=$2; shift 2; python3 /usr/local/lib/zfs-on-boot/progress.py run --phase "$n" --label "$label" --devices "$DEVICES" -- "$@"; }
part() { lsblk -nrpo NAME,PARTN "$DISK" | awk -v n="$1" '$2==n {print $1}'; }
[[ -b $DISK && -b $ROOTDEV ]]
[[ $ROOTDEV = "$(cat /etc/zfs-on-boot/old-root-device)" ]]
[[ $(blockdev --getsize64 "$DISK") = "$(cat /etc/zfs-on-boot/disk-size)" ]]
[[ $(lsblk -dn -o TYPE,FSTYPE | awk '$1=="disk" && $2!="iso9660" {n++} END {print n+0}') = 1 ]]
[[ $(findmnt -n -o FSTYPE /) = rootfs || $(findmnt -n -o FSTYPE /) = tmpfs ]]
[[ -z $(lsblk -nr -o MOUNTPOINTS "$DISK" | tr -d '[:space:]') ]]
[[ $(uname -r) = "$(cat /etc/zfs-on-boot/kernel)" ]]
[[ -s /root/.ssh/authorized_keys && -s /boot/vmlinuz-$(uname -r) ]]
[[ -z $(zpool list -H -o name 2>/dev/null) ]]
echo "Independent RAM OS ready. Mode: $MODE. Devices: $DEVICES"
lsblk -o NAME,PATH,SIZE,FSTYPE,MOUNTPOINTS "$DISK"
if [[ $MODE = preserve ]]; then
    . /etc/zfs-on-boot/plan.env
    # Free staging space only after this archive has successfully booted into RAM.
    mount "$ROOTDEV" /old
    if [[ -f /etc/zfs-on-boot/old-boot-uuid ]]; then
        BOOTDEV=$(blkid -U "$(cat /etc/zfs-on-boot/old-boot-uuid)")
        mount "$BOOTDEV" /old/boot
    fi
    mkdir -p /var/log/zfs-on-boot
    cp /old/var/lib/zfs-on-boot/stage.log /var/log/zfs-on-boot/stage.log
    rm -rf /old/var/lib/zfs-on-boot /old/boot/zfs-on-boot
    [[ -z ${BOOTDEV:-} ]] || umount /old/boot
    umount /old
    phase 4 "Check offline ext4 $ROOTDEV" bash -c 'e2fsck -f -p "$1"; rc=$?; [ "$rc" -le 1 ]' _ "$ROOTDEV"
    # Leave an extra MiB between the shrunken filesystem and its partition end.
    SHRINK_KIB=$(( (SPLIT-ROOT_START)*512/1024-1024 ))
    phase 4 "Shrink ext4 on $ROOTDEV" resize2fs -p "$ROOTDEV" "${SHRINK_KIB}K"
    phase 4 "Shorten $ROOTDEV and create temporary ZFS partition" sgdisk -d "$ROOT_PART" -n "$ROOT_PART:$ROOT_START:$((SPLIT-1))" -t "$ROOT_PART:8300" -u "$ROOT_PART:$ROOT_GUID" -n "32:$SPLIT:$ROOT_END" -t 32:BF01 "$DISK"
    partprobe "$DISK"
    udevadm settle
    TEMP=$(part 32)
    ZPART=$TEMP
    mount -o ro "$ROOTDEV" /old
    [[ -z ${BOOTDEV:-} ]] || mount -o ro "$BOOTDEV" /old/boot
    SOURCE=/old/
else
    phase 4 "Erase $DISK and create BIOS + ZFS partitions" bash -e -c 'sgdisk --zap-all "$1"; sgdisk -n 1:1MiB:+1MiB -t 1:EF02 -n 2:0:0 -t 2:BF01 "$1"' _ "$DISK"
    partprobe "$DISK"
    udevadm settle
    ZPART=$(part 2)
    SOURCE=/
fi
[[ -b $ZPART ]]
DEVICES=$DISK,$ROOTDEV,${BOOTDEV:-$ROOTDEV},$ZPART
phase 4 "Create rpool on $ZPART" zpool create -f -o ashift=12 -o compatibility=grub2 -o autoexpand=on -o cachefile=none -O compression=lz4 -O atime=off -O xattr=sa -O acltype=posixacl -O mountpoint=none -R /target rpool "$ZPART"
zfs create -o mountpoint=none rpool/ROOT
zfs create -o mountpoint=/ -o canmount=noauto rpool/ROOT/ubuntu
zfs mount rpool/ROOT/ubuntu
zpool set bootfs=rpool/ROOT/ubuntu rpool
# Do not traverse virtual filesystems or include our RAM installer/staging data.
# A separate source /boot is deliberately included; unsupported mounts were refused.
EXCLUDES=(--exclude=/proc/*** --exclude=/sys/*** --exclude=/dev/*** --exclude=/run/*** --exclude=/target/*** --exclude=/old/*** --exclude=/tmp/*** --exclude=/init --exclude=/etc/zfs-on-boot/*** --exclude=/var/lib/zfs-on-boot/*** --exclude=/boot/zfs-on-boot/*** --exclude=/boot/efi/*** --exclude=/var/log/zfs-on-boot/*** --exclude=/swapfile --exclude=/swap.img)
rsync -aHAXS --numeric-ids --dry-run --stats "${EXCLUDES[@]}" "$SOURCE" /target/ > /run/copy-size.txt
TOTAL=$(awk -F ': ' '/^Total transferred file size:/ {gsub(/[^0-9]/,"",$2); print $2}' /run/copy-size.txt)
# Real copy errors (including ENOSPC) stop before original data is deleted.
python3 /usr/local/lib/zfs-on-boot/progress.py run --phase 5 --label "Copy $SOURCE to $ZPART" --devices "$DEVICES" --total "$TOTAL" -- rsync -aHAXS --numeric-ids --info=progress2,name0 --outbuf=L --stats "${EXCLUDES[@]}" "$SOURCE" /target/
phase 6 "Checksum and metadata verification: $ROOTDEV -> $ZPART" bash -o pipefail -c 'rsync -aHAXSnic --numeric-ids --delete "$@" > /run/copy-differences; cat /run/copy-differences; test ! -s /run/copy-differences' _ "${EXCLUDES[@]}" "$SOURCE" /target/
echo 'Verified: file checksums, ownership, permissions, ACLs, xattrs and hard links match.'
phase 7 'Configure ZFS root, initramfs and boot services' bash /etc/zfs-on-boot/target.sh
if [[ $MODE = preserve ]]; then
    [[ -z ${BOOTDEV:-} ]] || umount /old/boot
    umount /old
    # Keep the verified temporary ZFS partition intact. Remove every other GPT
    # entry and make the final front member larger than the temporary member.
    mapfile -t PARTS < <(lsblk -nr -o PARTN "$DISK" | awk 'NF && $1!=32 {print $1}')
    ARGS=()
    for number in "${PARTS[@]}"; do ARGS+=(-d "$number"); done
    phase 8 "Replace original ext4 with front mirror member on $DISK" sgdisk "${ARGS[@]}" -n 1:2048:4095 -t 1:EF02 -n "2:4096:$((SPLIT-1))" -t 2:BF01 "$DISK"
    # Remove obsolete kernel partition mappings before installing the new ones.
    for number in "${PARTS[@]}"; do partx -d --nr "$number" "$DISK"; done
    partx -a --nr 1:2 "$DISK"
    udevadm settle
    FRONT=$(part 2)
    [[ $(blockdev --getsize64 "$FRONT") -ge $(blockdev --getsize64 "$TEMP") ]]
    DEVICES=$DISK,$FRONT,$TEMP
    python3 /usr/local/lib/zfs-on-boot/progress.py run --phase 8 --label "Relocate via mirror: $TEMP -> $FRONT" --devices "$DEVICES" --resilver -- zpool attach -f -w rpool "$TEMP" "$FRONT"
    [[ $(zpool list -H -o health rpool) = ONLINE ]]
    zpool status -p rpool
    zpool status rpool | grep -q 'errors: No known data errors'
    # A successful attach -w must leave a readable, fully resilvered front copy.
    [[ $(zpool status -P rpool | awk -v d="$FRONT" '$1==d {print $2}') = ONLINE ]]
    phase 8 "Detach temporary $TEMP after successful resilver" zpool detach rpool "$TEMP"
    zpool labelclear -f "$TEMP"
    phase 9 "Remove temporary partition $TEMP" sgdisk -d 32 "$DISK"
    partx -d --nr 32 "$DISK"
    ZPART=$FRONT
else
    phase 8 'Fresh install: no relocation required' true
fi
DEVICES=$DISK,$ZPART
phase 9 "Grow final ZFS partition $ZPART to fill $DISK" bash -e -c '
set +e
output=$(growpart "$1" 2 2>&1); rc=$?
set -e
echo "$output"
if [ "$rc" != 0 ]; then [ "$rc" = 1 ] && [[ $output = *NOCHANGE:* ]]; fi
partx -u --nr 2 "$1"
zpool online -e rpool "$2"
' _ "$DISK" "$ZPART"
mount --rbind /dev /target/dev
mount --make-rslave /target/dev
mount -t proc proc /target/proc
mount -t sysfs sysfs /target/sys
phase 10 "Install GRUB on $DISK; /boot is on ZFS" chroot /target grub-install --target=i386-pc --recheck "$DISK"
phase 10 'Finalize GRUB configuration' chroot /target update-grub
umount /target/proc /target/sys
umount -R /target/dev
ln -sf /run/systemd/resolve/stub-resolv.conf /target/etc/resolv.conf
touch /target/etc/machine-id
mkdir -p /target/var/lib/dbus
ln -sf /etc/machine-id /target/var/lib/dbus/machine-id
printf 'Installed by zfsify (%s) at %s\n' "$MODE" "$(date -u +%FT%TZ)" > /target/etc/zfs-on-boot-installed
phase 10 'Ready to reboot' true
mkdir -p /target/var/log/zfs-on-boot
cp /run/zfs-on-boot.log /target/var/log/zfs-on-boot/install.log
cp /var/log/zfs-on-boot/*.log /target/var/log/zfs-on-boot/
cp /run/zfs-on-boot-progress.json /target/var/log/zfs-on-boot/last-progress.json
sync
zpool export rpool
echo 'Migration complete. Rebooting into Ubuntu with / and /boot on ZFS.'
sync
reboot -f

ZFS_ON_BOOT_b0d25922822fd674c6760c8406d94b78bfa4036c0ccc9a417c64bf8c8fb0e568
cat > "$work/target.sh" <<'ZFS_ON_BOOT_46827e9cffcde6d6f8956b1fb2b68862dba0c65e9b1258493c9aba0e663f5c84'
#!/bin/bash
# Called in RAM after verified copy. Boot setup is deliberately after verification.
set -Eeuo pipefail
MODE=$(cat /etc/zfs-on-boot/mode)
DISK=$(cat /etc/zfs-on-boot/disk)
if [[ $MODE = erase ]]; then
    python3 /etc/zfs-on-boot/identity.py /target /etc/zfs-on-boot/identity.tar
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
{ printf '# / and /boot are on rpool/ROOT/ubuntu, mounted by zfs-initramfs.\n';
  awk '$1 ~ /^#/ || NF == 0 || ($2 != "/" && $2 != "/boot" && $2 != "/boot/efi" && $3 != "swap")' /target/etc/fstab.before-zfsify;
} > /target/etc/fstab
cat > /target/etc/default/grub.d/99-zfs-on-boot.cfg <<'EOF'
GRUB_CMDLINE_LINUX="root=ZFS=rpool/ROOT/ubuntu"
GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyS0,115200n8"
GRUB_DISABLE_OS_PROBER=true
GRUB_TIMEOUT=2
EOF
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
for kernel in /target/boot/vmlinuz-*; do
    version=${kernel##*/vmlinuz-}
    chroot /target modinfo -k "$version" zfs >/dev/null
    if [[ -f /target/boot/initrd.img-$version ]]; then
        chroot /target update-initramfs -u -k "$version"
    else
        chroot /target update-initramfs -c -k "$version"
    fi
done
[[ $(chroot /target grub-probe /boot) = zfs ]]
# GRUB is installed after the final GPT layout has been created.
chroot /target update-grub
umount /target/run /target/proc /target/sys
umount -R /target/dev

ZFS_ON_BOOT_46827e9cffcde6d6f8956b1fb2b68862dba0c65e9b1258493c9aba0e663f5c84
cat > "$work/progress.py" <<'ZFS_ON_BOOT_384f4cdae1a15781231b3f9a0b7df1dff0216ea3f7cf23d207302d76e123db9d'
#!/usr/bin/python3
"""Run a phase with live Linux disk telemetry, or follow it across SSH sessions."""
import argparse
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys
import time

STATE = Path('/run/zfs-on-boot-progress.json')
LOG = Path('/var/log/zfs-on-boot/progress.log')

def render(s):
    fraction = min(1, s.get('done', 0) / s['total']) if s.get('total') else 0
    fraction = 1 if s.get('status') == 'complete' else fraction
    overall = ((s['phase'] - 1) + (fraction * .95 if s.get('total') else 0)) / 10
    if s['label'] == 'Ready to reboot' and s['status'] == 'complete': overall = 1
    bar = '#' * int(overall * 24) + '-' * (24 - int(overall * 24))
    data = (f"{'~' if s.get('approximate') else ''}{s.get('done', 0)/1e6:,.1f}/{s['total']/1e6:,.1f} MB "
            f"({fraction*100:.1f}%) | {s.get('speed', 0)/1e6:,.1f} MB/s logical"
            + (' (phase average)' if s['status'] != 'running' else '')) if s.get('total') else 'data total: n/a (metadata/package operation)'
    io = ' | '.join(f"{d}: R {v[0]:.1f} W {v[1]:.1f} MB/s {v[2]:.0f} IOPS" for d, v in s.get('io', {}).items())
    return (f"[{bar}] phase {s['phase']}/10: {s['label']} [{s['status']}]\n"
            f"  devices: {s['devices']} | elapsed {s['elapsed']:.0f}s\n  {data}\n  {io}")

def disks(names):
    result = {}
    for name in names:
        try:
            fields = list(map(int, Path('/sys/class/block', Path(name).name, 'stat').read_text().split()))
            result[name] = (fields[2]*512, fields[6]*512, fields[0]+fields[4])
        except (OSError, ValueError):
            pass
    return result

p = argparse.ArgumentParser(description=__doc__)
sub = p.add_subparsers(dest='action', required=True)
f = sub.add_parser('watch')
f.add_argument('--once', action='store_true')
r = sub.add_parser('run')
r.add_argument('--phase', type=int, required=True)
r.add_argument('--label', required=True)
r.add_argument('--devices', required=True)
r.add_argument('--total', type=int, default=0)
r.add_argument('--resilver', action='store_true')
r.add_argument('command', nargs=argparse.REMAINDER)

def zbytes(value):
    match = re.fullmatch(r'([\d.,]+)([KMGTPE]?)', value)
    return int(float(match[1].replace(',', '')) * 1024 ** (' KMGTPE'.index(match[2]) if match[2] else 0))
a = p.parse_args()
if a.action == 'watch':
    while True:
        source = STATE if STATE.exists() else Path('/var/log/zfs-on-boot/last-progress.json')
        try:
            state = json.loads(source.read_text())
            if sys.stdout.isatty(): print('\033[H\033[2J', end='')
            print(render(state), flush=True)
            if a.once or state['status'] == 'failed' or (state['label'] == 'Ready to reboot' and state['status'] == 'complete'):
                break
        except (OSError, ValueError):
            print('Waiting for installer status...', flush=True)
            if a.once: sys.exit(1)
        time.sleep(1)
    sys.exit(0)

cmd = a.command[1:] if a.command[:1] == ['--'] else a.command
if not cmd: p.error('A phase command is required')
LOG.parent.mkdir(parents=True, exist_ok=True)
start = tick = time.monotonic()
prev = disks(a.devices.split(','))
state = dict(phase=a.phase, label=a.label, devices=','.join(dict.fromkeys(a.devices.split(','))), total=a.total,
             done=0, speed=0, elapsed=0, status='running', io={})
last_done = 0
buffer = ''
last_print = 0
rsync = re.compile(r'^\s*([\d,]+)\s+(\d+)%\s+')

def publish(final=False):
    global tick, prev, last_done, last_print
    now = time.monotonic()
    dt = max(now-tick, .001)
    current = disks(a.devices.split(','))
    state['io'] = {d: [(v[0]-prev[d][0])/dt/1e6, (v[1]-prev[d][1])/dt/1e6, (v[2]-prev[d][2])/dt]
                   for d, v in current.items() if d in prev
                   # Partition recreation resets counters; establish a new baseline.
                   if all(new >= old for new, old in zip(v, prev[d]))}
    state['speed'] = state['done']/max(now-start, .001) if final else max(0, state['done']-last_done)/dt
    state['elapsed'] = now-start
    prev, tick, last_done = current, now, state['done']
    tmp = STATE.with_suffix('.tmp')
    tmp.write_text(json.dumps(state))
    tmp.replace(STATE)
    if final or now-last_print >= (1 if os.environ.get('ZFS_PROGRESS_TTY') == '1' else 5):
        message = render(state)
        print(message, flush=True)
        with LOG.open('a') as log: log.write(message+'\n')
        last_print = now

publish()
with LOG.open('a') as log:
    log.write('COMMAND: '+repr(cmd)+'\n')
    child = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                             env={**os.environ, 'LC_ALL':'C'})
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ)
    eof = False
    while not eof:
        for key, _ in selector.select(timeout=1):
            chunk = os.read(key.fileobj.fileno(), 65536)
            if not chunk:
                eof = True
                break
            buffer += chunk.decode(errors='replace')
            lines = re.split('[\r\n]', buffer)
            buffer = lines.pop()
            for line in lines:
                match = rsync.match(line)
                if match:
                    state['done'] = int(match[1].replace(',', ''))
                elif line:
                    print(line, flush=True)
                    log.write(line+'\n')
                    log.flush()
        if a.resilver:
            try:
                scan = subprocess.check_output(['zpool', 'status', '-p', 'rpool'], text=True)
                m = re.search(r'([\d.,]+[KMGTPE]?) / ([\d.,]+[KMGTPE]?) issued', scan)
                if m: state['done'], state['total'] = map(zbytes, m.groups())
                elif (m := re.search(r'scan: resilvered ([\d.,]+[KMGTPE]?)', scan)):
                    state['done'] = state['total'] = zbytes(m[1])
                state['approximate'] = True
            except subprocess.CalledProcessError:
                pass
        if time.monotonic()-tick >= 1: publish()
    if buffer:
        print(buffer, flush=True)
        log.write(buffer+'\n')
    code = child.wait()
state['status'] = 'complete' if code == 0 else 'failed'
if code == 0 and state['total']: state['done'] = state['total']
publish(final=True)
sys.exit(code)

ZFS_ON_BOOT_384f4cdae1a15781231b3f9a0b7df1dff0216ea3f7cf23d207302d76e123db9d
cat > "$work/plan.py" <<'ZFS_ON_BOOT_47fad85edc65109b9740efb8f67c1fdd4ec324179cc6db9ff49a21152ecc694f'
#!/usr/bin/python3
"""Validate a GPT layout and calculate disjoint source, scratch and final regions."""
import json
from pathlib import Path
import sys
import re

table = json.loads(Path(sys.argv[1]).read_text())['partitiontable']
root, boot, efi = sys.argv[2:5]
assert table['label'] == 'gpt' and table['sectorsize'] == 512, 'GPT / 512-byte sectors required'
parts = table['partitions']
source = next(p for p in parts if p['node'] == root)
assert source == max(parts, key=lambda p: p['start'] + p['size']), 'Root must be the last partition on disk'
for part in parts:
    assert part['node'] in (root, boot, efi) or part['type'].upper() in (
        '21686148-6449-6E6F-744E-656564454649', 'C12A7328-F81F-11D2-BA4B-00A0C93EC93B'), 'Unrecognized data partition: '+part['node']
    assert re.search(r'(\d+)$', part['node'])[1] != '32', 'Partition 32 must be unused'
last = source['start'] + source['size'] - 1
split = ((last * 51 // 100) // 2048) * 2048
assert split > source['start'] + 8*1024**3//512, 'Insufficient front space'
assert split - 4096 >= last - split + 1, 'Front mirror member must be at least as large as temporary member'
number = re.search(r'(\d+)$', root)[1]
# Names from the kernel are validated without evaluating arbitrary partition labels.
assert number.isdigit()
for key, value in dict(ROOT_PART=number, ROOT_START=source['start'], ROOT_END=last,
                       SPLIT=split, ROOT_GUID=source['uuid']).items():
    assert all(c.isalnum() or c == '-' for c in str(value))
    print(f'{key}={value}')

ZFS_ON_BOOT_47fad85edc65109b9740efb8f67c1fdd4ec324179cc6db9ff49a21152ecc694f
cat > "$work/grow.sh" <<'ZFS_ON_BOOT_5cb37c8fad7ded94f754ea45474cb05d10b14081fb004a40bd2f5197f61c47d0'
#!/bin/bash
# Idempotent boot-time expansion of the single, last ZFS root partition.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
exec 9>/run/zfs-on-boot-grow.lock
flock -n 9 || exit 0
[[ $(findmnt -n -o FSTYPE /) = zfs ]] || exit 0
POOL=$(findmnt -n -o SOURCE /); POOL=${POOL%%/*}
mapfile -t LEAVES < <(zpool status -P "$POOL" | awk '$1 ~ /^\/dev\// {print $1}')
[[ ${#LEAVES[@]} = 1 ]] || { echo 'Refusing auto-growth: expected one root vdev.'; exit 1; }
DEV=$(readlink -f "${LEAVES[0]}")
[[ $(lsblk -dn -o TYPE "$DEV") = part ]]
DISK=/dev/$(lsblk -dn -o PKNAME "$DEV")
PART=$(cat "/sys/class/block/${DEV##*/}/partition")
[[ $(lsblk -dn -o TYPE "$DISK") = disk ]]
# growpart handles the backup GPT header and never changes the starting sector.
set +e
OUTPUT=$(growpart "$DISK" "$PART" 2>&1)
RC=$?
set -e
echo "$OUTPUT"
if (( RC != 0 )); then
    [[ $RC = 1 && $OUTPUT = *NOCHANGE:* ]] || exit "$RC"
fi
partx -u --nr "$PART" "$DISK"
udevadm settle
zpool set autoexpand=on "$POOL"
zpool online -e "$POOL" "$DEV"
zpool list -Hp -o name,size,health "$POOL"

ZFS_ON_BOOT_5cb37c8fad7ded94f754ea45474cb05d10b14081fb004a40bd2f5197f61c47d0
cat > "$work/grow.service" <<'ZFS_ON_BOOT_49cb7a543d69361254c98c549f7ce9498fb49e946b00802ddf45cf9c7fdd919f'
[Unit]
Description=Expand the ZFS root partition after a cloud disk resize
After=zfs-import.target zfs-mount.service local-fs.target
ConditionPathExists=/etc/zfs-on-boot-installed

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/zfs-on-boot-grow

[Install]
WantedBy=multi-user.target

ZFS_ON_BOOT_49cb7a543d69361254c98c549f7ce9498fb49e946b00802ddf45cf9c7fdd919f
cat > "$work/status.sh" <<'ZFS_ON_BOOT_36ba77788a7f472f54b98caab63dd238b25b9a255249784a4835d781bb6d24f3'
#!/bin/sh
exec python3 /usr/local/lib/zfs-on-boot/progress.py watch "$@"

ZFS_ON_BOOT_36ba77788a7f472f54b98caab63dd238b25b9a255249784a4835d781bb6d24f3
cat > "$work/identity.py" <<'ZFS_ON_BOOT_d7aae2d1b323632b2e9b0e6397902bcf924431b52c7f69e949934999eb6c562c'
#!/usr/bin/python3
"""Restore account configuration without breaking the fresh OS's system ownership."""
import os
from pathlib import Path
import stat
import subprocess
import sys
import tarfile

root = Path(sys.argv[1])
archive = Path(sys.argv[2])
with tarfile.open(archive) as tar:
    old = {name: tar.extractfile('etc/'+name).read().decode().splitlines()
           for name in ('passwd','group','shadow','gshadow')}
fresh = {name: (root/'etc'/name).read_text().splitlines() for name in old}

def records(lines): return {line.split(':')[0]: line.split(':') for line in lines if line and not line.startswith('#')}
new_ids = {}
for db in ('group','passwd'):
    original = records(old[db]); base = records(fresh[db])
    occupied = {int(row[2]) for row in original.values()}
    for name, row in base.items():
        if name not in original:
            number = int(row[2])
            if number in occupied: number = next(n for n in range(100, 1000) if n not in occupied)
            occupied.add(number)
            added = row.copy(); added[2] = str(number)
            if db == 'passwd': added[3] = str(new_ids['group'].get(int(row[3]), int(row[3])))
            old[db].append(':'.join(added)); original[name] = added
    new_ids[db] = {int(row[2]): int(original[name][2]) for name, row in base.items()}
for db in ('shadow','gshadow'):
    existing = records(old[db])
    old[db] += [line for line in fresh[db] if line.split(':')[0] not in existing]

# Translate ownership by account name before restoring /etc. Preserve modes and
# capabilities that chown can otherwise clear, and handle hard-linked files once.
seen = set()
for directory, dirs, files in os.walk(root, followlinks=False):
    for path in [Path(directory), *(Path(directory)/name for name in files),
                 *(Path(directory)/name for name in dirs if (Path(directory)/name).is_symlink())]:
        st = path.lstat(); key = (st.st_dev, st.st_ino)
        if key in seen: continue
        seen.add(key)
        uid = new_ids['passwd'].get(st.st_uid, st.st_uid)
        gid = new_ids['group'].get(st.st_gid, st.st_gid)
        if (uid, gid) == (st.st_uid, st.st_gid): continue
        try: cap = os.getxattr(path, 'security.capability', follow_symlinks=False)
        except OSError: cap = None
        os.chown(path, uid, gid, follow_symlinks=False)
        if not stat.S_ISLNK(st.st_mode): os.chmod(path, stat.S_IMODE(st.st_mode))
        if cap is not None: os.setxattr(path, 'security.capability', cap, follow_symlinks=False)

subprocess.run(['tar','--numeric-owner','--acls','--xattrs',
                '--exclude=etc/alternatives','--exclude=etc/ld.so.cache',
                '-xpf',str(archive),'-C',str(root)],check=True)
for name, lines in old.items(): (root/'etc'/name).write_text('\n'.join(lines)+'\n')
# Original software selection links cannot point into an erased OS. Keep its
# configuration, but disable local service definitions until their app is restored.
units = root/'etc/systemd/system'
for link in units.glob('*.wants/*'):
    if link.is_symlink() and (units/link.name).is_file() and not (units/link.name).is_symlink():
        print('Disabled carried-over local unit:', link.name)
        link.unlink()
print('Restored /etc and account records; translated fresh system-file ownership.')

ZFS_ON_BOOT_d7aae2d1b323632b2e9b0e6397902bcf924431b52c7f69e949934999eb6c562c
bash "$work/stage.sh" "$work" "$@" </dev/null
