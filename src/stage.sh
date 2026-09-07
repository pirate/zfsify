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
