#!/bin/sh
# zfsify: preserve by default; --erase retains configuration and users only.
set -eu
if [ "$(id -u)" != 0 ]; then echo 'Run as root: curl -fsSL URL | sudo sh' >&2; exit 1; fi
work=$(mktemp -d /tmp/zfs-on-boot.XXXXXXXX)
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT
cat > "$work/stage.sh" <<'ZFS_ON_BOOT_5e80bc4dc662423d8b75807195b57dcba2b03e130dc95c8915723b735d7dc1a2'
#!/bin/bash
# Preserve an ext4 Ubuntu installation by migrating through a RAM rescue OS.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
SOURCE=${1:?source directory required}
shift
MODE=preserve
TARGET=/
BACKUP=
MODE_COUNT=0
TARGET_COUNT=0
for arg in "$@"; do
    case "$arg" in
        --erase) MODE=erase; MODE_COUNT=$((MODE_COUNT+1)) ;;
        --backup) MODE=backup; BACKUP=ask; MODE_COUNT=$((MODE_COUNT+1)) ;;
        --backup=*) MODE=backup; BACKUP=${arg#*=}; MODE_COUNT=$((MODE_COUNT+1)) ;;
        --help|-h)
            cat <<'EOF'
Usage: curl -fsSL URL | sudo sh -s -- [--erase | --backup[=REMOTE:PATH|/MOUNT/DIR]] [/ | MOUNTPOINT | BLOCK_DEVICE]

Default: preserve your installation or data in place when less than 50% is used.
  --backup                 Guide me through a temporary Volume or rclone remote.
  --backup=/mnt/backup     Use a mounted, separate ext4 disk without prompts.
  --backup=myremote:path   Use an existing root-user rclone configuration.
  --erase                  Fresh Ubuntu with limited settings restore for /;
                           discard ALL files when targeting a data volume.

The positional path is the disk to CONVERT; --backup= is where to KEEP its backup.
Examples: --backup=/mnt/backup /          (convert the boot disk)
          --backup=/mnt/backup /mnt/data  (convert a data disk)
Setup and cleanup: https://pirate.github.io/zfsify/docs/backup.html
EOF
            exit 0 ;;
        /*) TARGET_COUNT=$((TARGET_COUNT+1)); TARGET=$arg ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done
(( MODE_COUNT <= 1 && TARGET_COUNT <= 1 )) || { echo "Specify one mode and one target per invocation." >&2; exit 2; }
if [[ $TARGET != / ]]; then
    running_root=$(findmnt -n -o SOURCE /)
    running_disk=
    if [[ -b $running_root ]]; then
        running_root=$(readlink -f "$running_root")
        running_disk=$(lsblk -snrpo NAME,TYPE "$running_root" | awk '$2=="disk" {print $1}')
    fi
    resolved=$(readlink -f "$TARGET")
    if [[ $resolved != "$running_root" && $resolved != "$running_disk" ]]; then
        exec bash "$SOURCE/volume.sh" "$SOURCE" "$TARGET" "$MODE" "$BACKUP"
    fi
fi
export LC_ALL=C
[[ -t 1 ]] && export ZFS_PROGRESS_TTY=1
PROGRESS=$SOURCE/progress.py
phase() { local n=$1 label=$2; shift 2; python3 "$PROGRESS" run --phase "$n" --label "$label" --devices "$DISK,$ROOTDEV" -- "$@"; }
WORK=/var/lib/zfs-on-boot
ROOT=$WORK/root
die() { echo "zfs-on-boot: $*" >&2; exit 1; }
[[ $(id -u) = 0 ]] || die 'Run with sudo sh (or as root).'
exec 9>/run/zfsify-migrate.lock
flock -n 9 || die 'Another zfsify conversion is running.'
. /etc/os-release
[[ $ID = ubuntu && ( $VERSION_ID = 22.04 || $VERSION_ID = 24.04 || $VERSION_ID = 26.04 ) && $(uname -m) = x86_64 ]] || die 'Ubuntu 22.04, 24.04, or 26.04 amd64 is required.'
CODENAME=$VERSION_CODENAME
RESOLVED_PACKAGE=systemd-resolved
[[ $VERSION_ID != 22.04 ]] || RESOLVED_PACKAGE=
[[ ! -e /etc/zfs-on-boot-installed ]] || die 'Already installed; nothing to do.'
FIRMWARE=bios
if [[ -d /sys/firmware/efi ]]; then
    FIRMWARE=uefi
    secure_boot=(/sys/firmware/efi/efivars/SecureBoot-*)
    if [[ -f ${secure_boot[0]} ]]; then
        [[ $(od -An -tu1 -j4 -N1 "${secure_boot[0]}" | tr -d ' ') = 0 ]] || die 'Secure Boot must be disabled for the upstream ZFSBootMenu image.'
    else
        # Some OVMF builds implement UEFI without Secure Boot variables at all.
        command -v mokutil >/dev/null || die 'Install mokutil to check this firmware’s Secure Boot support.'
        secure_state=$(mokutil --sb-state 2>&1 || true)
        [[ $secure_state = *"doesn't support Secure Boot"* ]] || die 'Cannot determine UEFI Secure Boot state.'
    fi
fi
[[ -f /boot/grub/grub.cfg ]] || die 'GRUB is required.'
[[ $(findmnt -n -o FSTYPE /) = ext4 ]] || die 'Only a plain ext4 root partition is supported.'
[[ $(awk '/MemTotal/ {print $2}' /proc/meminfo) -ge 450000 ]] || die 'At least 512 MiB RAM is required; the compressed rescue size is checked before reboot.'
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
if (( USED_BYTES * 2 >= FS_BYTES )) && [[ $MODE = preserve ]]; then
    cat <<'EOF'
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! ROOT IS AT LEAST 50% USED: not enough room for same-disk migration. !!
!! A: KEEP ALL FILES via a temporary Volume or rclone remote.          !!
!!    Guided setup -> backup -> verify -> format ZFS -> restore.       !!
!! B: ERASE for fresh Ubuntu with a limited priority restore.          !!
!!    Only B discards applications/data outside the restore budget.   !!
!!    /etc, users, SSH keys and basic settings are retained with B.    !!
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
EOF
    answer=
    if { exec 3<>/dev/tty; } 2>/dev/null; then
        printf 'Choose A to keep everything (guided backup), B (or y) to ERASE, or Enter to cancel: ' >&3
        IFS= read -r answer <&3 || true
        exec 3>&-
    fi
    case $answer in a|A) MODE=backup; BACKUP=ask;; b|B|y) MODE=erase;; *) die 'Cancelled. Use --backup=remote:path or --erase to choose explicitly.';; esac
fi
[[ $(df -Pk /boot | awk 'NR==2 {print $4}') -ge 500000 ]] || die 'At least 500 MB free in /boot is required.'
[[ $(df -Pk / | awk 'NR==2 {print $4}') -ge 3500000 ]] || die 'At least 3.5 GB free disk space is required for staging, including erase mode.'
[[ $(blockdev --getsize64 "$DISK") -ge 10000000000 ]] || die 'At least a 10 GB disk is required.'
[[ $(blockdev --getss "$DISK") = 512 ]] || die 'Only 512-byte logical sectors are supported.'
[[ -s /root/.ssh/authorized_keys ]] || die 'A root SSH authorized_keys file is required.'
[[ ! -e $WORK ]] || die "$WORK already exists. Inspect it before retrying; use the documented cleanup procedure."
[[ ! -d /boot/zfs-on-boot ]] || die 'Old boot staging files exist; inspect them before retrying.'
# Refuse layouts containing data that the root-only copy would miss.
if [[ $MODE != erase ]]; then
    while read -r target fstype; do
        case "$fstype" in ext4|ext3|ext2|xfs|btrfs|zfs|vfat|ntfs|fuse.*)
            if [[ $target != / && $target != /boot && $target != /boot/efi ]]; then
                mounted_source=$(findmnt -n -o SOURCE --target "$target")
                if [[ -b $mounted_source ]]; then
                    [[ $(lsblk -snrpo NAME,TYPE "$mounted_source" | awk '$2=="disk" {print $1}') != "$DISK" ]] || die "Additional filesystem on the selected disk at $target is unsupported."
                else
                    die "Unsupported mounted filesystem at $target."
                fi
            fi ;;
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
$DISK (512 MiB ZFSBootMenu partition omitted):
  [              original ext4              ]
  [       smaller ext4      ][ temporary ZFS ]  shrink offline; copy + verify
  [       new ZFS member    ][ temporary ZFS ]  attach mirror; resilver
  [       new ZFS member    ][ free space    ]  detach temporary member
  [                   ZFS                   ]  grow; / and /boot on ZFS
The server reboots into RAM. Services are offline during migration.
Original ext4 is removed only after the copy is checksum-verified.
Power loss during repartitioning can require provider recovery.
EOF
elif [[ $MODE = backup ]]; then
    echo "BACKUP AND RESTORE: $ROOTDEV -> archive on a separate Volume or rclone remote"
    echo "                    -> read-back verification -> reformat $DISK as ZFS -> restore."
    echo 'The backup remains available after completion. Destination setup follows before rescue preparation.'
else
    cat <<EOF
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! ERASE MODE: ALL EXISTING DATA ON $DISK WILL BE DELETED.
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  [ existing partitions + ALL their data ]
  [ 512 MiB ZFSBootMenu ][ ZFS: fresh Ubuntu / and /boot ]
Devices: erase $DISK; create ${PREFIX}1 (ZFSBootMenu) and ${PREFIX}2 (ZFS).
/etc, users, SSH authorized_keys and basic settings are retained.
Complete optional files are retained in priority order within the RAM budget; omitted data is removed.
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
cleanup_swap() { [[ ! -f $WORK/staging.swap ]] || swapoff "$WORK/staging.swap" 2>/dev/null || true; }
trap cleanup_swap EXIT
if [[ $(awk '/MemTotal/ {print $2}' /proc/meminfo) -lt 750000 ]]; then
    # Package preparation can use disk swap; the offline migration never does.
    fallocate -l 512M "$WORK/staging.swap"
    chmod 600 "$WORK/staging.swap"
    mkswap "$WORK/staging.swap"
    swapon "$WORK/staging.swap"
fi
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
    for directory, dirs, files in os.walk(os.path.join(home, '.ssh'), followlinks=False):
        for name in dirs+files: paths.add(os.path.join(directory, name).lstrip('/'))
open(sys.argv[1], 'wb').write(b''.join(os.fsencode(path)+b'\0' for path in sorted(paths)))
IDENTITY
    tar --numeric-owner --acls --xattrs --no-recursion --null -rpf "$WORK/identity.tar" -C / -T "$WORK/identity-files"
    RAM_BYTES=$(awk '/MemTotal/ {printf "%.0f", $2*1024}' /proc/meminfo)
    PRIORITY_BUDGET=$((RAM_BYTES > 450000000 ? RAM_BYTES-450000000 : 0))
    (( PRIORITY_BUDGET <= RAM_BYTES/3 )) || PRIORITY_BUDGET=$((RAM_BYTES/3))
    phase 2 'Preview optional files that fit the priority restore budget' python3 "$SOURCE/priority.py" "$PRIORITY_BUDGET" "$WORK/priority-files"
    printf "%s\n" "$PRIORITY_BUDGET" > "$WORK/priority-budget"
fi
mkdir -p /usr/local/lib/zfs-on-boot /usr/local/sbin
cp "$PROGRESS" /usr/local/lib/zfs-on-boot/progress.py
install -m 755 "$SOURCE/status.sh" /usr/local/sbin/zfs-on-boot-status
# Prevent inherited terminal input (including the rest of a curl pipe) reaching apt.
phase 2 'Update Ubuntu package indexes' apt-get update
phase 2 'Install staging tools' apt-get install -y --no-install-recommends debootstrap cpio gzip python3 squashfs-tools rclone
[[ $MODE != backup ]] || bash "$SOURCE/backup.sh" configure "$BACKUP" "$WORK/backup" "$DISK" "$USED_BYTES"
if [[ $MODE != erase ]]; then
    # Install boot support into the OS that will actually be migrated.
    phase 2 'Prepare existing Ubuntu for ZFS boot' apt-get install -y --no-install-recommends linux-image-virtual zfs-initramfs zfsutils-linux grub-pc-bin grub2-common cloud-guest-utils rsync extlinux syslinux-common
fi
phase 2 'Build independent RAM rescue Ubuntu' debootstrap --variant=minbase "$CODENAME" "$ROOT" http://archive.ubuntu.com/ubuntu
cat > "$ROOT/etc/apt/sources.list" <<EOF
deb http://archive.ubuntu.com/ubuntu $CODENAME main universe
deb http://archive.ubuntu.com/ubuntu $CODENAME-updates main universe
deb http://security.ubuntu.com/ubuntu $CODENAME-security main universe
EOF
printf '#!/bin/sh\nexit 101\n' > "$ROOT/usr/sbin/policy-rc.d"
chmod 755 "$ROOT/usr/sbin/policy-rc.d"
mount --rbind /dev "$ROOT/dev"
mount --make-rslave "$ROOT/dev"
mount -t proc proc "$ROOT/proc"
mount -t sysfs sysfs "$ROOT/sys"
cleanup_mounts() { umount -R "$ROOT/dev" 2>/dev/null || true; umount "$ROOT/proc" "$ROOT/sys" 2>/dev/null || true; }
trap 'cleanup_mounts; cleanup_swap' EXIT
cp -L /etc/resolv.conf "$ROOT/etc/resolv.conf"
phase 2 'Update rescue package indexes' chroot "$ROOT" apt-get update
# grub-pc-bin avoids package installation trying to install GRUB on the live disk.
phase 2 'Install RAM rescue packages' chroot "$ROOT" apt-get install -y --no-install-recommends linux-image-virtual zfs-initramfs zfsutils-linux grub-pc-bin grub2-common openssh-server cloud-init netplan.io systemd-sysv $RESOLVED_PACKAGE systemd-timesyncd udev sudo locales ca-certificates curl wget lsb-release python3 gdisk parted e2fsprogs dosfstools cpio gzip rsync cloud-guest-utils apparmor busybox-static extlinux syslinux-common rclone binutils efibootmgr </dev/null
mkdir -p "$ROOT/etc/zfs-on-boot"
printf '%s\n' "$FIRMWARE" > "$ROOT/etc/zfs-on-boot/firmware"
phase 2 "Download verified ZFSBootMenu 3.1.0 for $FIRMWARE" bash "$SOURCE/zbm-install.sh" download "$ROOT"
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
options zfs zfs_arc_min=16777216 zfs_arc_max=67108864
EOF
printf '%s\n' "$DISK" > "$ROOT/etc/zfs-on-boot/disk"
blockdev --getsize64 "$DISK" > "$ROOT/etc/zfs-on-boot/disk-size"
blkid -s UUID -o value "$ROOTDEV" > "$ROOT/etc/zfs-on-boot/old-root-uuid"
[[ $MODE != backup ]] || cp -a "$WORK/backup" "$ROOT/etc/zfs-on-boot/backup"
if [[ $MODE = erase ]]; then
    cp "$WORK/identity.tar" "$ROOT/etc/zfs-on-boot/identity.tar"
    cp "$WORK/priority-files" "$WORK/priority-budget" "$ROOT/etc/zfs-on-boot/"
fi
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
install -m 755 "$SOURCE/snapshot.sh" "$ROOT/usr/local/sbin/zfsify-snapshot"
cp "$SOURCE/backup.sh" "$ROOT/etc/zfs-on-boot/backup.sh"
cp "$SOURCE/zbm-install.sh" "$ROOT/etc/zfs-on-boot/zbm-install.sh"
cp "$SOURCE/identity.py" "$ROOT/etc/zfs-on-boot/identity.py"
cp "$SOURCE/ram-init.sh" "$ROOT/init"
chmod 755 "$ROOT/init"
# Capture address/route state as shell commands selected by MAC, not guessed eth0.
python3 - "$ROOT/etc/zfs-on-boot/network.sh" <<'PY'
import json, os, subprocess, sys, shlex
def ip(*args): return json.loads(subprocess.check_output(['ip','-j',*args]))
q=shlex.quote
lines=['#!/bin/bash', 'set -eu', 'ip link set lo up']
for link in ip('address','show'):
    if link['ifname']=='lo' or not link.get('address'): continue
    # RAM boot recreates hardware NICs, not the installed OS's Docker bridges,
    # veth pairs or other software interfaces.
    if not os.path.exists('/sys/class/net/'+link['ifname']+'/device'): continue
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
trap cleanup_swap EXIT
# SquashFS stays compressed in RAM; only a small boot shim is unpacked.
phase 3 'Compress rescue filesystem (one worker, bounded memory)' mksquashfs "$ROOT" "$WORK/rescue.squashfs" -noappend -comp xz -b 128K -processors 1 -mem 64M
RAM_BYTES=$(awk '/MemTotal/ {printf "%.0f", $2*1024}' /proc/meminfo)
RESCUE_BYTES=$(stat -c %s "$WORK/rescue.squashfs")
(( RESCUE_BYTES + 230000000 < RAM_BYTES )) || die "Compressed rescue ($RESCUE_BYTES bytes) leaves insufficient working RAM; no boot entry changed."
phase 3 'Build minimal RAM boot shim' python3 "$SOURCE/build-rescue.py" "$ROOT" "$WORK/shim" "$SOURCE" "$KVER" "$(blkid -s UUID -o value "$ROOTDEV")"
phase 3 'Pack minimal RAM boot shim' bash -o pipefail -c 'cd "$1"; find . -xdev -print0 | cpio --null -o --format=newc | gzip -1 > "$2"' _ "$WORK/shim" "$WORK/installer.img"
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

ZFS_ON_BOOT_5e80bc4dc662423d8b75807195b57dcba2b03e130dc95c8915723b735d7dc1a2
cat > "$work/ram-init.sh" <<'ZFS_ON_BOOT_491886382d7bc5107634e77dade50ada29953bc6a5f8c0a6d2e669aaaee32257'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
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
# ZFS 2.1 inode caches can outgrow a 512 MiB rescue OS during large file trees.
# Flush and evict clean caches under pressure; never use the source disk as swap.
if [[ $(awk '/MemTotal/ {print $2}' /proc/meminfo) -lt 750000 ]]; then
    echo 16777216 > /sys/module/zfs/parameters/zfs_arc_min
    echo 33554432 > /sys/module/zfs/parameters/zfs_arc_max
    echo 16777216 > /sys/module/zfs/parameters/zfs_dirty_data_max
    (
        while sleep 2; do
            if [[ $(awk '/MemAvailable/ {print $2}' /proc/meminfo) -lt 80000 ]]; then
                sync
                echo 3 > /proc/sys/vm/drop_caches
            fi
        done
    ) & CACHE_GUARD=$!
fi
mkdir -p /run/sshd
/usr/sbin/sshd -E /run/sshd.log
bash /etc/zfs-on-boot/network.sh
DISK=$(cat /etc/zfs-on-boot/disk)
MODE=$(cat /etc/zfs-on-boot/mode)
BOOT_TYPE=8300
BOOT_ATTR=(-A 1:set:2)
if [[ $(cat /etc/zfs-on-boot/firmware) = uefi ]]; then
    BOOT_TYPE=EF00
    BOOT_ATTR=()
    mount -t efivarfs efivarfs /sys/firmware/efi/efivars
fi
ROOTDEV=$(blkid -U "$(cat /etc/zfs-on-boot/old-root-uuid)")
BACKUPDEV=
if [[ -f /etc/zfs-on-boot/backup/volume-uuid ]]; then
    BACKUPDEV=$(blkid -U "$(cat /etc/zfs-on-boot/backup/volume-uuid)")
fi
DEVICES=$DISK,$ROOTDEV${BACKUPDEV:+,$BACKUPDEV}
phase() { local n=$1 label=$2; shift 2; python3 /usr/local/lib/zfs-on-boot/progress.py run --phase "$n" --label "$label" --devices "$DEVICES" -- "$@"; }
part() { local name; while read -r name; do [[ $(cat "/sys/class/block/${name##*/}/partition" 2>/dev/null || true) != "$1" ]] || printf '%s\n' "$name"; done < <(lsblk -nrpo NAME "$DISK"); }
[[ -b $DISK && -b $ROOTDEV ]]
[[ $ROOTDEV = "$(cat /etc/zfs-on-boot/old-root-device)" ]]
[[ $(blockdev --getsize64 "$DISK") = "$(cat /etc/zfs-on-boot/disk-size)" ]]
[[ $(findmnt -n -o FSTYPE /) = rootfs || $(findmnt -n -o FSTYPE /) = tmpfs || $(findmnt -n -o FSTYPE /) = overlay ]]
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
elif [[ $MODE = backup ]]; then
    mount -o ro "$ROOTDEV" /old
    if [[ -f /etc/zfs-on-boot/old-boot-uuid ]]; then
        BOOTDEV=$(blkid -U "$(cat /etc/zfs-on-boot/old-boot-uuid)")
        mount -o ro "$BOOTDEV" /old/boot
    fi
    phase 4 'Archive the offline installation with rclone and verify a full download' bash /etc/zfs-on-boot/backup.sh save
    [[ -z ${BOOTDEV:-} ]] || umount /old/boot
    umount /old
fi
if [[ $MODE = erase ]]; then
    mount -o ro "$ROOTDEV" /old
    phase 4 'Save the selected priority files from the offline source' tar --sparse --numeric-owner --acls --xattrs --no-recursion --null -cpf /run/priority.tar -C /old -T /etc/zfs-on-boot/priority-files
    [[ $(stat -c %s /run/priority.tar) -le $(( $(cat /etc/zfs-on-boot/priority-budget) + 1048576 )) ]]
    umount /old
fi
if [[ $MODE != preserve ]]; then
    phase 4 "Erase $DISK and create ZFSBootMenu + ZFS partitions" bash -e -c 'disk=$1; type=$2; shift 2; sgdisk --zap-all "$disk"; sgdisk -n 1:1MiB:+512MiB -t "1:$type" "$@" -n 2:0:0 -t 2:BF01 "$disk"' _ "$DISK" "$BOOT_TYPE" "${BOOT_ATTR[@]}"
    partprobe "$DISK"
    udevadm settle
    ZPART=$(part 2)
    # A fresh install comes from the immutable SquashFS, not its live overlay.
    # SSH sessions can update PAM logs/cache files without racing copy verification.
    SOURCE=/rescue-media/lower/
    [[ $(findmnt -n -o FSTYPE --target "$SOURCE") = squashfs ]]
fi
[[ -b $ZPART ]]
DEVICES=$DISK,$ROOTDEV,${BOOTDEV:-$ROOTDEV},$ZPART${BACKUPDEV:+,$BACKUPDEV}
phase 4 "Create rpool on $ZPART" zpool create -f -o ashift=12 -o compatibility=openzfs-2.1-linux -o autoexpand=on -o cachefile=none -O compression=lz4 -O atime=off -O xattr=sa -O acltype=posixacl -O mountpoint=none -R /target rpool "$ZPART"
zfs create -o mountpoint=none rpool/ROOT
zfs create -o mountpoint=/ -o canmount=noauto rpool/ROOT/ubuntu
zfs mount rpool/ROOT/ubuntu
zpool set bootfs=rpool/ROOT/ubuntu rpool
# Do not traverse virtual filesystems or include our RAM installer/staging data.
# A separate source /boot is deliberately included; unsupported mounts were refused.
EXCLUDES=(--exclude=/proc/*** --exclude=/sys/*** --exclude=/dev/*** --exclude=/run/*** --exclude=/target/*** --exclude=/old/*** --exclude=/tmp/*** --exclude=/init --exclude=/rescue-media/*** --exclude=/etc/zfs-on-boot/*** --exclude=/var/lib/zfs-on-boot/*** --exclude=/boot/zfs-on-boot/*** --exclude=/boot/efi/*** --exclude=/var/log/zfs-on-boot/*** --exclude=/swapfile --exclude=/swap.img)
if [[ $MODE = backup ]]; then
    phase 5 'Restore and checksum-check the rclone archive' bash /etc/zfs-on-boot/backup.sh restore
    phase 6 'Remote archive checksum and extraction verified' true
else
rsync -aHAXS --numeric-ids --dry-run --stats "${EXCLUDES[@]}" "$SOURCE" /target/ > /run/copy-size.txt
TOTAL=$(awk -F ': ' '/^Total transferred file size:/ {gsub(/[^0-9]/,"",$2); print $2}' /run/copy-size.txt)
# Real copy errors (including ENOSPC) stop before original data is deleted.
python3 /usr/local/lib/zfs-on-boot/progress.py run --phase 5 --label "Copy $SOURCE to $ZPART" --devices "$DEVICES" --total "$TOTAL" -- rsync -aHAXS --numeric-ids --info=progress2,name0 --outbuf=L --stats "${EXCLUDES[@]}" "$SOURCE" /target/
phase 6 "Checksum and metadata verification: $ROOTDEV -> $ZPART" bash -o pipefail -c 'rsync -aHAXSnic --numeric-ids --delete "$@" > /run/copy-differences; cat /run/copy-differences; test ! -s /run/copy-differences' _ "${EXCLUDES[@]}" "$SOURCE" /target/
echo 'Verified: file checksums, ownership, permissions, ACLs, xattrs and hard links match.'
fi
phase 7 'Configure ZFS root, initramfs and boot services' bash /etc/zfs-on-boot/target.sh
phase 7 'Flush the configured ZFS root to disk' zpool sync rpool
if [[ $MODE = preserve ]]; then
    [[ -z ${BOOTDEV:-} ]] || umount /old/boot
    umount /old
    # Keep the verified temporary ZFS partition intact. Remove every other GPT
    # entry and make the final front member larger than the temporary member.
    mapfile -t PARTS < <(while read -r name; do cat "/sys/class/block/$name/partition" 2>/dev/null || true; done < <(lsblk -nr -o NAME "$DISK") | awk '$1!=32')
    ARGS=()
    for number in "${PARTS[@]}"; do ARGS+=(-d "$number"); done
    phase 8 "Replace original ext4 with front mirror member on $DISK" sgdisk "${ARGS[@]}" -n 1:2048:1050623 -t "1:$BOOT_TYPE" "${BOOT_ATTR[@]}" -n "2:1050624:$((SPLIT-1))" -t 2:BF01 "$DISK"
    # Remove obsolete kernel partition mappings before installing the new ones.
    for number in "${PARTS[@]}"; do partx -d --nr "$number" "$DISK"; done
    partx -a --nr 1:2 "$DISK"
    udevadm settle
    FRONT=$(part 2)
    [[ $(blockdev --getsize64 "$FRONT") -ge $(blockdev --getsize64 "$TEMP") ]]
    DEVICES=$DISK,$FRONT,$TEMP
fi
# Establish the boot path as soon as its partition exists, before relocation.
mount --rbind /dev /target/dev
mount --make-rslave /target/dev
mount -t proc proc /target/proc
mount -t sysfs sysfs /target/sys
phase 8 "Install ZFSBootMenu on $(part 1); Ubuntu /boot remains on ZFS" bash /etc/zfs-on-boot/zbm-install.sh install /target "$DISK" "$(part 1)"
umount /target/proc
umount -R /target/sys
umount -R /target/dev
if [[ $MODE = preserve ]]; then
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
zfs snapshot rpool/ROOT/ubuntu@zfsify-installed
[[ -z ${CACHE_GUARD:-} ]] || kill "$CACHE_GUARD"
zpool export rpool
echo 'Migration complete. Rebooting into Ubuntu with / and /boot on ZFS.'
sync
reboot -f

ZFS_ON_BOOT_491886382d7bc5107634e77dade50ada29953bc6a5f8c0a6d2e669aaaee32257
cat > "$work/target.sh" <<'ZFS_ON_BOOT_7c3138cbab8a048de8971e39a8b5ca24917e2907f5115c91ddd96ff6920c9c57'
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
{ printf '# / and /boot are on rpool/ROOT/ubuntu, mounted by zfs-initramfs.\n';
  awk '$1 ~ /^#/ || NF == 0 || ($2 != "/" && $2 != "/boot" && $2 != "/boot/efi" && $3 != "swap")' /target/etc/fstab.before-zfsify;
} > /target/etc/fstab
# ZFSBootMenu supplies root= dynamically, including for recovery clones.
zfs set org.zfsbootmenu:commandline="console=ttyS0,115200n8 console=tty0" rpool/ROOT
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
for kernel in /target/boot/vmlinuz-*; do
    version=${kernel##*/vmlinuz-}
    chroot /target modinfo -k "$version" zfs >/dev/null
    if [[ -f /target/boot/initrd.img-$version ]]; then
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

ZFS_ON_BOOT_7c3138cbab8a048de8971e39a8b5ca24917e2907f5115c91ddd96ff6920c9c57
cat > "$work/progress.py" <<'ZFS_ON_BOOT_188b5977b14b29e4d6dc2addc0ea491f68961aae7e8a5926449ca330a3c4b6e0'
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
    if s['label'].startswith('Ready') and s['status'] == 'complete': overall = 1
    bar = '#' * int(overall * 24) + '-' * (24 - int(overall * 24))
    data = (f"{'~' if s.get('approximate') else ''}{s.get('done', 0)/1e6:,.1f}/{s['total']/1e6:,.1f} MB "
            f"({fraction*100:.1f}%) | {s.get('speed', 0)/1e6:,.1f} MB/s logical"
            + (' (phase average)' if s['status'] != 'running' else '')) if s.get('total') else 'data total: n/a (streaming or metadata operation)'
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
            if state['label'].startswith('Ready') and state['status'] == 'complete':
                next_steps = Path('/var/log/zfs-on-boot/backup-next-steps.txt')
                if next_steps.exists(): print('\n' + next_steps.read_text(), flush=True)
            if a.once or state['status'] == 'failed' or (state['label'].startswith('Ready') and state['status'] == 'complete'):
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

ZFS_ON_BOOT_188b5977b14b29e4d6dc2addc0ea491f68961aae7e8a5926449ca330a3c4b6e0
cat > "$work/plan.py" <<'ZFS_ON_BOOT_41be88f6c01738992b7ab4ff60d30d2075d0c3276563a104254ed48a510c340b'
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
front_start = 1050624  # 1 MiB alignment + 512 MiB ZFSBootMenu partition
split = ((last + 1 + front_start) // 2 // 2048 + 2) * 2048
assert split > source['start'] + 3*1024**3//512, 'Insufficient front space'
assert split - front_start >= last - split + 1, 'Front mirror member must be at least as large as temporary member'
number = re.search(r'(\d+)$', root)[1]
# Names from the kernel are validated without evaluating arbitrary partition labels.
assert number.isdigit()
for key, value in dict(ROOT_PART=number, ROOT_START=source['start'], ROOT_END=last,
                       SPLIT=split, ROOT_GUID=source['uuid']).items():
    assert all(c.isalnum() or c == '-' for c in str(value))
    print(f'{key}={value}')

ZFS_ON_BOOT_41be88f6c01738992b7ab4ff60d30d2075d0c3276563a104254ed48a510c340b
cat > "$work/grow.sh" <<'ZFS_ON_BOOT_ee907fb7b1fedd8e0650bceca7b998803de9c12430234391fb4647cc92890960'
#!/bin/bash
# Idempotent expansion of a single-partition pool explicitly enrolled by zfsify.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
exec 9>/run/zfs-on-boot-grow.lock
flock -w 120 9 || exit 1
if [[ $# = 0 ]]; then
    [[ $(findmnt -n -o FSTYPE /) = zfs ]] || exit 0
    POOL=$(findmnt -n -o SOURCE /); POOL=${POOL%%/*}
else
    POOL=$1
    [[ $POOL =~ ^zfsify_[a-f0-9]+$ ]] || exit 1
    [[ -f /etc/zfsify/volumes/$POOL ]] || exit 1
    [[ $(zpool get -H -o value guid "$POOL") = $(cat "/etc/zfsify/volumes/$POOL") ]] || exit 1
fi
mapfile -t LEAVES < <(zpool status -P "$POOL" | awk '$1 ~ /^\/dev\// {print $1}')
[[ ${#LEAVES[@]} = 1 ]] || { echo 'Refusing auto-growth: expected one vdev.'; exit 1; }
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

ZFS_ON_BOOT_ee907fb7b1fedd8e0650bceca7b998803de9c12430234391fb4647cc92890960
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
cat > "$work/ram-boot.sh" <<'ZFS_ON_BOOT_67f6d2616ea5352e8cc71452ba3951bd86e70af36c5e4b2707ac6f40f21e97c3'
#!/bin/busybox sh
# Minimal initramfs: read the compressed rescue filesystem into RAM, then release
# the source disk before starting any migration command.
export PATH=/sbin:/bin:/usr/sbin:/usr/bin
/bin/busybox --install -s /bin
mkdir -p /dev /proc /sys /source /payload /rescue
mount -t devtmpfs devtmpfs /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys
exec </dev/console >/dev/console 2>&1
fail() {
    echo "Rescue bootstrap failed: $*; source disk has not been changed."
    source=$(/sbin/blkid -U "$SOURCE_UUID" 2>/dev/null || true)
    if [ -b "$source" ]; then
        mount -o remount,rw /source 2>/dev/null || mount -o rw "$source" /source 2>/dev/null || true
        if mountpoint -q /source; then
            echo "$*" > /source/var/lib/zfs-on-boot/bootstrap-error.log
            sync
            umount /source
        fi
    fi
    echo 'Returning to the original Ubuntu installation in 10 seconds.'
    sleep 10
    reboot -f
    exec sh
}
. /config
for module in $MODULES; do
    # Controllers for other providers can return ENODEV on this hypervisor.
    /sbin/modprobe "$module" || case "$module" in ext4|loop|squashfs|overlay) fail "$module";; esac
done
for attempt in $(seq 1 60); do
    source=$(/sbin/blkid -U "$SOURCE_UUID")
    [ -b "$source" ] && break
    sleep 1
done
mount -o ro "$source" /source || fail 'mount source'
mount -t tmpfs -o size=80%,mode=700 tmpfs /payload || fail 'RAM storage'
cp /source/var/lib/zfs-on-boot/rescue.squashfs /payload/rescue.squashfs || fail 'copy rescue'
echo "$RESCUE_SHA  /payload/rescue.squashfs" | sha256sum -c - || fail 'rescue checksum'
umount /source || fail 'release source disk'
mkdir /payload/lower /payload/upper /payload/work
mount -t squashfs -o loop,ro /payload/rescue.squashfs /payload/lower || fail 'mount compressed rescue'
mount -t overlay -o lowerdir=/payload/lower,upperdir=/payload/upper,workdir=/payload/work overlay /rescue || fail 'rescue overlay'
mkdir -p /rescue/rescue-media
mount --move /payload /rescue/rescue-media || fail 'move RAM backing storage'
umount /proc
umount /sys
umount /dev
exec switch_root /rescue /init

ZFS_ON_BOOT_67f6d2616ea5352e8cc71452ba3951bd86e70af36c5e4b2707ac6f40f21e97c3
cat > "$work/build-rescue.py" <<'ZFS_ON_BOOT_f24c263d32e9c3f16233736955cd5f9e26248abee1c45160d09b696ddf7308b3'
#!/usr/bin/python3
"""Build a small disk-independent boot shim; execute only on the target Ubuntu VPS."""
from pathlib import Path
import hashlib
import re
import shutil
import subprocess
import sys
root, shim, source = map(Path, sys.argv[1:4])
kernel, uuid = sys.argv[4:6]
shim.mkdir()
for name in ['bin', 'sbin', 'usr/bin', 'usr/sbin', 'dev', 'proc', 'sys']:
    (shim/name).mkdir(parents=True, exist_ok=True)
def copy(path):
    dest = shim/path.lstrip('/')
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root/path.lstrip('/'), dest)
copy('/usr/bin/busybox')
shutil.copy2(shim/'usr/bin/busybox', shim/'bin/busybox')
for binary, alias in [('/usr/bin/kmod', '/sbin/modprobe'), ('/usr/sbin/blkid', '/sbin/blkid')]:
    copy(binary)
    shutil.copy2(shim/binary.lstrip('/'), shim/alias.lstrip('/'))
    ldd = subprocess.check_output(['chroot', str(root), 'ldd', binary], text=True)
    for path in re.findall(r'(/[^\s()]+)', ldd): copy(path)
modules = []
required = ['ext4', 'loop', 'squashfs', 'overlay']
controllers = ['virtio_pci', 'virtio_blk', 'virtio_scsi', 'scsi_mod', 'sd_mod', 'nvme', 'nvme_core', 'ahci', 'libata', 'hv_vmbus', 'hv_storvsc']
for module in controllers + required:
    deps = subprocess.run(['chroot', str(root), 'modprobe', '--show-depends', '--set-version', kernel, module], text=True, capture_output=True)
    if deps.returncode:
        if module in required: raise RuntimeError('Missing required rescue module: '+module)
        continue
    modules.append(module)
    for line in deps.stdout.splitlines():
        if line.startswith('insmod '): copy(line.split()[1])
for path in (root/'lib/modules'/kernel).glob('modules.*'):
    if path.is_file(): copy('/lib/modules/'+kernel+'/'+path.name)
shutil.copy2(source/'ram-boot.sh', shim/'init')
(shim/'init').chmod(0o755)
image = root.parent/'rescue.squashfs'
with image.open('rb') as stream:
    hasher = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024*1024), b''): hasher.update(chunk)
    digest = hasher.hexdigest()
(shim/'config').write_text(f'SOURCE_UUID={uuid}\nRESCUE_SHA={digest}\nMODULES="{" ".join(modules)}"\n')

ZFS_ON_BOOT_f24c263d32e9c3f16233736955cd5f9e26248abee1c45160d09b696ddf7308b3
cat > "$work/zbm-install.sh" <<'ZFS_ON_BOOT_9b0d3e3af73c62681e392d73a420f7e7b116ebd554e138ad116601d92ea6c9bc'
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

ZFS_ON_BOOT_9b0d3e3af73c62681e392d73a420f7e7b116ebd554e138ad116601d92ea6c9bc
cat > "$work/snapshot.sh" <<'ZFS_ON_BOOT_6980f24230b5f647bc24e8520a2de685e8f6d362da9351c3ff3bff41675ba717'
#!/bin/bash
# Own only zfsify-{apt,daily,boot}-* snapshots; never remove user snapshots.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
[[ $(findmnt -n -o FSTYPE /) = zfs ]] || exit 0
DATASET=$(findmnt -n -o SOURCE /)
case ${1:-daily} in apt) KIND=apt; KEEP=14;; daily) KIND=daily; KEEP=7;; boot) KIND=boot; KEEP=5;; *) exit 2;; esac
exec 9>/run/zfsify-snapshot.lock
flock 9
NAME=$DATASET@zfsify-$KIND-$(date -u +%Y%m%dT%H%M%S)-$$
zfs snapshot "$NAME"
echo "Recovery snapshot: $NAME"
mapfile -t OWNED < <(zfs list -H -t snapshot -o name -s creation -d 1 "$DATASET" | awk -v p="$DATASET@zfsify-$KIND-" 'index($0,p)==1')
for ((i=0; i<${#OWNED[@]}-KEEP; i++)); do
    # A held snapshot or one backing a recovery clone stays intact.
    zfs destroy "${OWNED[i]}" || echo "Retained busy snapshot: ${OWNED[i]}" >&2
done

ZFS_ON_BOOT_6980f24230b5f647bc24e8520a2de685e8f6d362da9351c3ff3bff41675ba717
cat > "$work/volume.sh" <<'ZFS_ON_BOOT_5cbb3b74fd48d187b7818609ed823057b4e56e6b2364d86faeb62be8dd9bb762'
#!/bin/bash
# Non-root ext4 conversion. The running OS stays on its own disk.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C DEBIAN_FRONTEND=noninteractive
SOURCE=${1:?} TARGET=${2:?} MODE=${3:-preserve} BACKUP=${4:-ask}
die() { echo "zfsify: $*" >&2; exit 1; }
[[ $(id -u) = 0 ]] || die 'Run as root.'
exec 9>/run/zfsify-migrate.lock
flock -n 9 || die 'Another zfsify conversion is running.'
. /etc/os-release
[[ $ID = ubuntu && ( $VERSION_ID = 22.04 || $VERSION_ID = 24.04 || $VERSION_ID = 26.04 ) ]] || die 'Ubuntu 22.04, 24.04, or 26.04 is required.'
part() { local name; while read -r name; do [[ $(cat "/sys/class/block/${name##*/}/partition" 2>/dev/null || true) != "$1" ]] || printf "%s\n" "$name"; done < <(lsblk -nrpo NAME "$DISK"); }
ROOT_SOURCE=$(findmnt -n -o SOURCE /)
if [[ $(findmnt -n -o FSTYPE /) = zfs ]]; then
    mapfile -t ROOT_LEAVES < <(zpool status -P "${ROOT_SOURCE%%/*}" | awk '$1 ~ /^\/dev\// {print $1}')
else
    ROOT_LEAVES=("$(readlink -f "$ROOT_SOURCE")")
fi
(( ${#ROOT_LEAVES[@]} > 0 )) || die 'Cannot identify the running root disks.'
ROOT_DISKS=()
for root_leaf in "${ROOT_LEAVES[@]}"; do
    [[ -b $root_leaf ]] || die 'Cannot identify a root vdev.'
    while read -r root_disk; do ROOT_DISKS+=("$root_disk"); done < <(lsblk -snrpo NAME,TYPE "$root_leaf" | awk '$2=="disk" {print $1}')
done
(( ${#ROOT_DISKS[@]} > 0 )) || die 'Cannot identify the running root disks.'
if [[ -b $TARGET ]]; then
    DEV=$(readlink -f "$TARGET")
    TYPE=$(lsblk -dn -o TYPE "$DEV")
    if [[ $TYPE = disk ]]; then
        mapfile -t PARTS < <(lsblk -nrpo NAME,TYPE "$DEV" | awk '$2=="part" {print $1}')
        [[ ${#PARTS[@]} -le 1 ]] || die 'Data disks with multiple partitions are not supported.'
        [[ ${#PARTS[@]} = 0 ]] || DEV=${PARTS[0]}
    fi
    MOUNT=$(findmnt -rn -S "$DEV" -o TARGET | head -1 || true)
else
    [[ -d $TARGET ]] || die 'Target must be a mounted filesystem or block device.'
    MOUNT=$(readlink -f "$TARGET")
    [[ $(findmnt -n -o TARGET --target "$MOUNT") = "$MOUNT" ]] || die 'Specify the mount point itself, not a subdirectory.'
    DEV=$(readlink -f "$(findmnt -n -o SOURCE --target "$MOUNT")")
fi
[[ -b $DEV ]] || die 'Target is not a local block device.'
TYPE=$(lsblk -dn -o TYPE "$DEV")
case $TYPE in disk) DISK=$DEV; START=0;; part) DISK=/dev/$(lsblk -dn -o PKNAME "$DEV"); START=$(lsblk -dn -o START "$DEV");; *) die 'Only a disk or direct partition is supported.';; esac
for root_disk in "${ROOT_DISKS[@]}"; do
    [[ $DISK != "$root_disk" ]] || die 'Refusing a data-volume operation on the running root disk; use target /.'
done
[[ -z $(lsblk -nr -o TYPE "$DISK" | grep -Ev '^(disk|part)$' || true) ]] || die 'Deactivate device-mapper, encryption, or RAID mappings before conversion.'
if command -v zpool >/dev/null; then
    while read -r leaf; do
        [[ -b $leaf ]] || continue
        while read -r pool_disk; do
            [[ $pool_disk != "$DISK" ]] || die 'The target belongs to an imported ZFS pool; export that pool before erasing its disk.'
        done < <(lsblk -snrpo NAME,TYPE "$leaf" | awk '$2=="disk" {print $1}')
    done < <(zpool status -P 2>/dev/null | awk '$1 ~ /^\/dev\// {print $1}')
fi
[[ $(blockdev --getss "$DISK") = 512 ]] || die '512-byte logical sectors required.'
[[ $(lsblk -nr -o TYPE "$DISK" | awk '$1=="part" {n++} END{print n+0}') -le 1 ]] || die 'Only one source filesystem per data disk is supported.'
SOURCE_FS=$(blkid -s TYPE -o value "$DEV" || true)
[[ $SOURCE_FS = ext4 || $MODE = erase ]] || die 'Preservation and backup conversion currently require ext4; --erase can initialize an empty disk.'
[[ $MOUNT != '[SWAP]' && $SOURCE_FS != swap ]] || die 'Disable swap and inspect its disk before conversion.'
[[ $(lsblk -nr -o MOUNTPOINTS "$DISK" | sed '/^$/d' | wc -l) -le 1 ]] || die 'Unmount nested or additional filesystems first.'
WORK=$(mktemp -d /var/lib/zfsify-volume.XXXXXXXX)
chmod 700 "$WORK"
mkdir "$WORK/old" "$WORK/new"
OWN_MOUNT=
MIGRATION_STARTED=0
cleanup_preflight() {
    if [[ $MIGRATION_STARTED = 0 ]]; then
        [[ -z $OWN_MOUNT ]] || umount "$WORK/old" || true
        # Keep logs, but never leave an unexpected source mount after cancellation.
    fi
}
trap cleanup_preflight EXIT
ORIGINAL_UUID=$(blkid -s UUID -o value "$DEV" || true)
[[ -n $ORIGINAL_UUID ]] || ORIGINAL_UUID=$(cat /proc/sys/kernel/random/uuid)
if [[ -z $MOUNT && $MODE = erase ]]; then
    DEFAULT_MOUNT=/mnt/zfsify-${ORIGINAL_UUID:0:8}
elif [[ -z $MOUNT ]]; then
    mount -o ro "$DEV" "$WORK/old"
    OWN_MOUNT=1
    MOUNT=$WORK/old
    DEFAULT_MOUNT=/mnt/zfsify-${ORIGINAL_UUID:0:8}
else
    DEFAULT_MOUNT=$MOUNT
fi
if [[ -n $MOUNT ]]; then
    read -r FS_BYTES USED_BYTES < <(df -B1 --output=size,used "$MOUNT" | tail -1)
else
    FS_BYTES=$(blockdev --getsize64 "$DEV"); USED_BYTES=0
fi
if (( USED_BYTES*2 >= FS_BYTES )) && [[ $MODE = preserve ]]; then
    echo 'WARNING: at least 50% is used; not enough room for same-disk migration.'
    echo 'A: KEEP ALL FILES using a temporary Volume or rclone remote; guided setup follows.'
    echo 'y: ERASE this DATA VOLUME and discard all its files.'
    answer=
    if { exec 3<>/dev/tty; } 2>/dev/null; then printf 'Choose A for guided backup, y to ERASE, or Enter to cancel: ' >&3; IFS= read -r answer <&3 || true; exec 3>&-; fi
    case $answer in a|A) MODE=backup; BACKUP=ask;; y) MODE=erase;; *) die 'Cancelled; choose --backup or --erase explicitly.';; esac
fi
POOL=${ORIGINAL_UUID,,}; POOL=zfsify_${POOL//-/}; POOL=${POOL:0:23}
! zpool list "$POOL" >/dev/null 2>&1 || die 'Pool name already exists.'
DISK_BYTES=$(blockdev --getsize64 "$DISK")
LAST=$((DISK_BYTES/512-34))
SPLIT=$(( ((LAST+1+2048)/2/2048+2)*2048 ))
[[ $SPLIT -gt $((START+262144)) ]] || die 'Disk too small for migration.'
lsblk -o NAME,PATH,SIZE,FSTYPE,MOUNTPOINTS "$DISK"
echo "$MODE data volume: $DEV on $DISK; final pool $POOL at $DEFAULT_MOUNT"
case $MODE in
preserve) echo '[ ext4 ] -> [ smaller ext4 | temporary ZFS ] -> [ ZFS mirror | temporary ZFS ] -> [ full ZFS ]';;
backup) echo '[ ext4 ] -> [ verified archive on separate Volume / remote ] -> [ full ZFS ] -> [ restored data ]';;
erase) echo '[ ext4: all data discarded ] -> [ empty full-disk ZFS ]';;
esac
[[ $MODE != erase ]] || echo 'ERASE: no files from this data volume will be retained.'
echo "Work logs: $WORK; stop applications using $MOUNT before the countdown ends."
for ((n=15;n>0;n--)); do printf '\rStarting in %2ds; Ctrl-C cancels. ' "$n"; sleep 1; done; printf '\n'
exec > >(tee -a "$WORK/conversion.log") 2>&1
phase() { local n=$1 label=$2; shift 2; python3 "$SOURCE/progress.py" run --phase "$n" --label "$label" --devices "$DISK,$DEV" -- "$@"; }
phase 2 'Update Ubuntu package indexes' apt-get update
phase 2 'Install data migration tools' apt-get install -y --no-install-recommends zfsutils-linux gdisk e2fsprogs rsync python3 cloud-guest-utils rclone
if [[ $MODE = backup ]]; then
    bash "$SOURCE/backup.sh" configure "$BACKUP" "$WORK/backup" "$DISK" "$USED_BYTES"
    export ZFSIFY_BACKUP_CONF=$WORK/backup ZFSIFY_BACKUP_SOURCE=$WORK/old
    export ZFSIFY_BACKUP_TARGET=$WORK/new ZFSIFY_BACKUP_STATE=$WORK ZFSIFY_BACKUP_LOG=$WORK
    export ZFSIFY_BACKUP_DATA=1
fi
# A busy filesystem aborts here; never force-unmount or kill user processes.
[[ -z $MOUNT ]] || umount "$MOUNT"
MIGRATION_STARTED=1
LOOP=
trap 'echo "Conversion stopped. Do not wipe or detach devices. Inspect $WORK and zpool status; temporary device: ${LOOP:-none}."' ERR
if [[ $MODE = backup ]]; then
    mount -o ro "$DEV" "$WORK/old"
    phase 4 "Back up and read-back verify $DEV with rclone" bash "$SOURCE/backup.sh" save
    umount "$WORK/old"
fi
if [[ $MODE = preserve ]]; then
    phase 4 "Check $DEV offline" bash -c 'e2fsck -f -p "$1"; rc=$?; [ "$rc" -le 1 ]' _ "$DEV"
    phase 4 "Shrink $DEV" resize2fs "$DEV" "$(((SPLIT-START)*512/1024-1024))K"
    LOOP=$(losetup --find --show --offset "$((SPLIT*512))" --sizelimit "$(((LAST-SPLIT+1)*512))" "$DISK")
    phase 4 "Create temporary ZFS on $LOOP" zpool create -f -o ashift=12 -o autoexpand=on -O compression=lz4 -O xattr=sa -O acltype=posixacl -O mountpoint=none "$POOL" "$LOOP"
    [[ $(zpool status -P "$POOL" | awk '$1 ~ /^\/dev\// {print $1}') = "$LOOP" ]] || die 'Unexpected temporary vdev layout; original filesystem has not been deleted.'
    zfs create -o mountpoint="$WORK/new" "$POOL/data"
    mount -o ro "$DEV" "$WORK/old"
    TOTAL=$(rsync -aHAXS --numeric-ids --dry-run --stats "$WORK/old/" "$WORK/new/" | awk -F ': ' '/^Total transferred file size:/ {gsub(/[^0-9]/,"",$2);print $2}')
    python3 "$SOURCE/progress.py" run --phase 5 --label "Copy $DEV to $LOOP" --devices "$DISK,$DEV,$LOOP" --total "$TOTAL" -- rsync -aHAXS --numeric-ids --info=progress2,name0 --outbuf=L "$WORK/old/" "$WORK/new/"
    phase 6 'Verify every copied file and its metadata' bash -o pipefail -c 'rsync -aHAXSnic --numeric-ids --delete "$1/" "$2/" > "$3"; cat "$3"; test ! -s "$3"' _ "$WORK/old" "$WORK/new" "$WORK/differences"
    umount "$WORK/old"
    # The verified tail ends before the backup GPT; writing the new GPT cannot touch it.
    phase 8 "Create the final GPT on $DISK" sgdisk --clear -n "1:2048:$((SPLIT-1))" -t 1:BF01 "$DISK"
    partprobe "$DISK"
    udevadm settle
    FRONT=$(part 1)
    [[ -b $FRONT && $(blockdev --getsize64 "$FRONT") -ge $(blockdev --getsize64 "$LOOP") ]]
    phase 8 "Resilver $LOOP to $FRONT" zpool attach -f -w "$POOL" "$LOOP" "$FRONT"
    [[ $(zpool list -H -o health "$POOL") = ONLINE ]]
    zpool status "$POOL" | grep -q 'errors: No known data errors'
    zpool detach "$POOL" "$LOOP"
    zpool labelclear -f "$LOOP"
    losetup -d "$LOOP"; LOOP=
    phase 9 'Expand the final data partition' growpart "$DISK" 1
    partx -u --nr 1 "$DISK"
    zpool online -e "$POOL" "$FRONT"
else
    phase 4 "Erase data disk $DISK" sgdisk --clear -n 1:2048:0 -t 1:BF01 "$DISK"
    partprobe "$DISK"; udevadm settle
    FRONT=$(part 1)
    zpool create -f -o ashift=12 -o autoexpand=on -O compression=lz4 -O xattr=sa -O acltype=posixacl -O mountpoint=none "$POOL" "$FRONT"
    zfs create -o mountpoint="$WORK/new" "$POOL/data"
fi
if [[ $MODE = backup ]]; then
    phase 5 'Restore verified data-volume archive' bash "$SOURCE/backup.sh" restore
fi
cp /etc/fstab "$WORK/fstab.before"
python3 - "$DEV" "$ORIGINAL_UUID" "$DEFAULT_MOUNT" <<'PY'
from pathlib import Path
import sys
p=Path('/etc/fstab'); out=[]
for line in p.read_text().splitlines():
    fields=line.split()
    if fields and not line.lstrip().startswith('#') and (fields[0] in (sys.argv[1], 'UUID='+sys.argv[2]) or len(fields)>1 and fields[1]==sys.argv[3]):
        out.append('# zfsify replaced: '+line)
    else: out.append(line)
p.write_text('\n'.join(out)+'\n')
PY
zfs set mountpoint="$DEFAULT_MOUNT" "$POOL/data"
zpool set cachefile=/etc/zfs/zpool.cache "$POOL"
systemctl enable zfs-import-cache.service zfs-mount.service zfs.target
# Enroll only this pool GUID; later imports of unrelated pools are never resized.
install -m 755 "$SOURCE/grow.sh" /usr/local/sbin/zfs-on-boot-grow
mkdir -p /etc/zfsify/volumes
zpool get -H -o value guid "$POOL" > "/etc/zfsify/volumes/$POOL"
cat > /etc/systemd/system/zfsify-volume-grow@.service <<'SERVICE'
[Unit]
Description=Expand an enrolled zfsify data pool after disk resize
After=zfs-import.target zfs-mount.service local-fs.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/zfs-on-boot-grow %i
[Install]
WantedBy=multi-user.target
SERVICE
systemctl daemon-reload
systemctl enable "zfsify-volume-grow@$POOL.service"
phase 10 'Ready: data volume converted' zpool status "$POOL"
echo "ZFS data mounted at $DEFAULT_MOUNT; original fstab and logs saved in $WORK."
[[ $MODE != backup ]] || cat "$WORK/backup-next-steps.txt"

ZFS_ON_BOOT_5cbb3b74fd48d187b7818609ed823057b4e56e6b2364d86faeb62be8dd9bb762
cat > "$work/backup.sh" <<'ZFS_ON_BOOT_3c9893dd92a0ee9b419747f9064bb6c2336862f914b24ce9ea267b9808a3fcb5'
#!/bin/bash
# Whole-filesystem archive transport. rclone owns all remote configuration.
set -Eeuo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
ACTION=${1:?}
if [[ $ACTION = configure ]]; then
    DEST=${2:?} OUT=${3:?} SOURCE_DISK=${4:?}
    USED_BYTES=${5:-0}
    # The same destination checks serve explicit flags and the interactive retry loop.
    validate_destination() {
        if [[ $DEST = /* ]]; then
            DEST=$(realpath -e "$DEST") || return 1
            [[ -d $DEST ]] || { echo 'Backup volume directory must already exist.' >&2; return 1; }
            BACKUP_DEV=$(findmnt -n -o SOURCE --target "$DEST")
            [[ -b $BACKUP_DEV && $(findmnt -n -o FSTYPE --target "$DEST") = ext4 ]] || { echo 'Mount a separate ext4 volume first, then enter its directory (not /dev/...).'; return 1; }
            mapfile -t BACKUP_DISKS < <(lsblk -snrpo NAME,TYPE "$BACKUP_DEV" | awk '$2=="disk" {print $1}')
            [[ ${#BACKUP_DISKS[@]} = 1 && ${BACKUP_DISKS[0]} != "$SOURCE_DISK" ]] || { echo "That directory is on the source disk ($SOURCE_DISK). Attach and mount another disk first." >&2; return 1; }
        else
            [[ $DEST = *:* && $DEST != :* ]] || { echo 'Use a named rclone remote:path or mounted volume directory.' >&2; return 1; }
            CONFIG=$(rclone config file | tail -1)
            [[ -f $CONFIG ]] || { echo 'Run rclone config first (choose option 2).' >&2; return 1; }
        fi
    }
    if [[ $DEST = ask ]]; then
        if ! { exec 3<>/dev/tty; } 2>/dev/null; then
            echo 'Interactive backup needs a terminal. Use --backup=/mnt/backup or --backup=remote:path.' >&2
            exit 1
        fi
        while :; do
            cat >&3 <<EOF

BACKUP SETUP - keep all files from $SOURCE_DISK
  1) Attached Volume / disk (recommended if your provider offers one)
     Create a temporary Volume now, or use one already mounted here.
  2) Configure cloud storage with rclone (S3, SFTP, and others)
  3) Use an existing rclone remote
  q) Cancel before conversion

The backup is checksum-verified before erasing $SOURCE_DISK, then restored
onto ZFS. Keep the destination attached/accessible until conversion is verified.
EOF
            if (( USED_BYTES > 0 )); then
                awk -v n="$USED_BYTES" 'BEGIN {printf "Source currently uses %.1f GB. Plan for at least %.0f GB free at the destination\n(used space + 20%%, rounded up); compression may help, but do not rely on it.\n", n/1e9, int(n*1.2/1e9)+1}' >&3
            fi
            printf '\nChoose [1/2/3/q]: ' >&3
            IFS= read -r choice <&3 || exit 1
            case $choice in
                1)
                    cat >&3 <<EOF

ATTACH A TEMPORARY VOLUME
  1. Open your provider's storage page and create a Volume in this server's
     region / availability zone. Attach it to this server.
  2. For a NEW empty Volume, choose ext4 and mount it using provider instructions.
     Keep this window open; use a second SSH session for any mount commands.
     Already have a mounted ext4 disk? Use its directory below.

DigitalOcean: Volumes -> Add Volume -> select this Droplet ->
  Automatically Format & Mount -> Ext4. Find its directory under /mnt below.
  https://docs.digitalocean.com/products/volumes/how-to/create/
  https://docs.digitalocean.com/products/volumes/how-to/mount-unmount/
Other providers and step-by-step help:
  https://pirate.github.io/zfsify/docs/backup.html

Only format the NEW backup Volume. $SOURCE_DISK is the source to preserve.
Do not run zfsify on the backup Volume; it stays ext4 for the rescue OS.
EOF
                    while :; do
                        printf '\nAttached disks (source to convert: %s):\n' "$SOURCE_DISK" >&3
                        lsblk -o NAME,PATH,SIZE,FSTYPE,MOUNTPOINTS >&3
                        printf '\nMounted ext4 filesystems and available space:\n' >&3
                        df -h -t ext4 >&3 || true
                        printf '\nEnter mounted directory, e.g. /mnt/zfsify_backup\n[Enter = refresh after attaching; q = back]: ' >&3
                        IFS= read -r DEST <&3 || exit 1
                        [[ $DEST != q && $DEST != Q ]] || break
                        [[ -n $DEST ]] || continue
                        [[ $DEST = /* ]] || { echo 'Enter the absolute mount directory.' >&3; continue; }
                        validate_destination >&3 2>&3 && break
                    done
                    [[ $DEST != q && $DEST != Q ]] || continue
                    ;;
                2|3)
                    cat >&3 <<'EOF'

Use a private destination; the archive includes accounts and credentials.
Remote setup: https://rclone.org/commands/rclone_config/
Provider guides: https://rclone.org/overview/
EOF
                    if [[ $choice = 2 ]]; then
                        echo 'Opening rclone config. Create a remote with n; finish with q to return here.' >&3
                        rclone config <&3 >&3 2>&3 || continue
                    fi
                    echo 'Configured remotes:' >&3
                    rclone listremotes >&3
                    printf 'Enter remote:folder (e.g. myremote:zfsify-backups), or q to go back: ' >&3
                    IFS= read -r DEST <&3 || exit 1
                    [[ $DEST != q && $DEST != Q ]] || continue
                    validate_destination >&3 2>&3 || continue
                    ;;
                q|Q) echo 'Cancelled before conversion.' >&3; exit 1;;
                *) echo 'Choose 1, 2, 3, or q.' >&3; continue;;
            esac
            break
        done
        exec 3>&-
    else
        validate_destination || exit 1
    fi
    mkdir -m 700 -p "$OUT"
    if [[ $DEST = /* ]]; then
        printf "Backup device: %s on %s (separate from %s)\n" "$BACKUP_DEV" "${BACKUP_DISKS[0]}" "$SOURCE_DISK"
        df -h "$DEST"
        blkid -s UUID -o value "$BACKUP_DEV" > "$OUT/volume-uuid"
        BACKUP_MOUNT=$(findmnt -n -o TARGET --target "$DEST")
        printf '%s' "${DEST#"$BACKUP_MOUNT"}" > "$OUT/volume-subdir"
        : > "$OUT/rclone.conf"
    else
        cp "$CONFIG" "$OUT/rclone.conf"; chmod 600 "$OUT/rclone.conf"
        # Credentials must travel in rclone's configuration, not depend on files
        # that disappear when the source disk is erased.
        rclone config dump | python3 -c 'import json,os,sys
for remote,config in json.load(sys.stdin).items():
 for key,value in config.items():
  if isinstance(value,str) and value.startswith(("/","~")) and os.path.isfile(os.path.expanduser(value)):
   sys.exit("Remote "+remote+" uses external credential file "+key+"; use an inline credential in rclone config before conversion.")'
    fi
    if [[ -n ${RCLONE_CONFIG_PASS:-} ]]; then
        printf '%s' "$RCLONE_CONFIG_PASS" > "$OUT/rclone-pass"; chmod 600 "$OUT/rclone-pass"
    fi
    DEST=${DEST%/}/zfsify-$(date -u +%Y%m%dT%H%M%S)-$(cat /proc/sys/kernel/random/uuid)
    printf '%s' "$DEST" > "$OUT/destination"
    printf 'Backup location: %s\n' "$DEST"
    echo 'Destination selected. Conversion will copy, read-back verify, reformat, and restore.'
    echo 'Leave a temporary Volume attached through reboot. It is not deleted automatically.'
    # Verify that the configured remote can be contacted before staging a reboot.
    rclone --config "$OUT/rclone.conf" mkdir "${DEST%/*}"
    rclone --config "$OUT/rclone.conf" lsf "${DEST%/*}" --max-depth 1 >/dev/null
    exit 0
fi
CONF=${ZFSIFY_BACKUP_CONF:-/etc/zfs-on-boot/backup}
OLD=${ZFSIFY_BACKUP_SOURCE:-/old}
NEW=${ZFSIFY_BACKUP_TARGET:-/target}
HASHDIR=${ZFSIFY_BACKUP_STATE:-/run}
LOGDIR=${ZFSIFY_BACKUP_LOG:-$NEW/var/log/zfs-on-boot}
export RCLONE_CONFIG=$CONF/rclone.conf
[[ ! -f $CONF/rclone-pass ]] || export RCLONE_CONFIG_PASS="$(cat "$CONF/rclone-pass")"
DEST=$(cat "$CONF/destination")
if [[ -f $CONF/volume-uuid ]]; then
    mkdir -p /backup-volume
    mountpoint -q /backup-volume || mount -o rw "$(blkid -U "$(cat "$CONF/volume-uuid")")" /backup-volume
    DEST=/backup-volume$(cat "$CONF/volume-subdir")/${DEST##*/}
    trap 'sync; umount /backup-volume' EXIT
fi
RCLONE=(rclone --buffer-size 4M --transfers 1 --checkers 1 --stats 5s --stats-one-line --stats-log-level NOTICE)
if [[ $ACTION = save ]]; then
    # Source is offline and read-only. Explicit boot argument includes a separate
    # /boot filesystem while --one-file-system excludes unrelated mounted volumes.
    EXTRA=(); EXCLUDES=()
    if [[ ${ZFSIFY_BACKUP_DATA:-0} != 1 ]]; then
        mountpoint -q "$OLD/boot" && EXTRA=(boot)
        EXCLUDES=(--exclude='./proc' --exclude='./sys' --exclude='./dev' --exclude='./run'
          --exclude='./tmp' --exclude='./var/lib/zfs-on-boot' --exclude='./boot/zfs-on-boot'
          --exclude='boot/zfs-on-boot' --exclude='./boot/efi' --exclude='boot/efi'
          --exclude='./backup-volume' --exclude='./rescue-media' --exclude='./swapfile' --exclude='./swap.img')
    fi
    mkfifo "$HASHDIR/zfsify-backup-hash.pipe"
    sha256sum < "$HASHDIR/zfsify-backup-hash.pipe" > "$HASHDIR/zfsify-backup.sha256" & HASH_PID=$!
    tar --numeric-owner --acls --xattrs --sparse --one-file-system "${EXCLUDES[@]}" -cpf - -C "$OLD" . "${EXTRA[@]}" \
        | gzip -1 | tee "$HASHDIR/zfsify-backup-hash.pipe" | "${RCLONE[@]}" rcat "$DEST/root.tar.gz"
    wait "$HASH_PID"
    rm "$HASHDIR/zfsify-backup-hash.pipe"
    # Hashing a complete read-back verifies remote payload, not merely upload exit.
    EXPECTED=$(awk '{print $1}' "$HASHDIR/zfsify-backup.sha256")
    [[ $EXPECTED =~ ^[a-f0-9]{64}$ ]]
    ACTUAL=$("${RCLONE[@]}" cat "$DEST/root.tar.gz" | sha256sum | awk '{print $1}')
    [[ $ACTUAL = "$EXPECTED" ]] || { echo 'Backup verification failed; original disk retained.' >&2; exit 1; }
    "${RCLONE[@]}" copyto "$HASHDIR/zfsify-backup.sha256" "$DEST/root.tar.gz.sha256"
    echo 'Complete offline backup read back and checksum-verified; original disk may now be reformatted.'
elif [[ $ACTION = restore ]]; then
    mkfifo "$HASHDIR/zfsify-restore-hash.pipe"
    sha256sum < "$HASHDIR/zfsify-restore-hash.pipe" > "$HASHDIR/zfsify-restored.sha256" & HASH_PID=$!
    # Include system namespaces too: Docker overlay metadata and file capabilities
    # must survive; tar otherwise restores only user.* extended attributes.
    "${RCLONE[@]}" cat "$DEST/root.tar.gz" | tee "$HASHDIR/zfsify-restore-hash.pipe" | gzip -dc | tar --numeric-owner --same-owner --acls --xattrs --xattrs-include='*' -xpf - -C "$NEW"
    wait "$HASH_PID"
    rm "$HASHDIR/zfsify-restore-hash.pipe"
    cmp "$HASHDIR/zfsify-backup.sha256" "$HASHDIR/zfsify-restored.sha256"
    mkdir -p "$LOGDIR"
    cp "$HASHDIR/zfsify-backup.sha256" "$LOGDIR/remote-backup.sha256"
    cat "$CONF/destination" > "$LOGDIR/remote-backup-location"
    {
        printf 'Backup retained at: %s\n' "$(cat "$CONF/destination")"
        echo 'After conversion finishes, verify your files and applications (and reboot for root conversion).'
        if [[ -f $CONF/volume-uuid ]]; then
            printf 'Temporary ext4 Volume UUID: %s\n' "$(cat "$CONF/volume-uuid")"
            echo 'When satisfied: unmount that Volume, remove its mount configuration if needed,'
            echo 'then detach and delete it in your provider console to stop storage charges.'
            echo 'DigitalOcean: https://docs.digitalocean.com/products/volumes/how-to/delete-detach/'
        else
            echo 'When satisfied, keep the archive as a backup or remove its unique folder with rclone.'
        fi
        echo 'Backup and cleanup guide: https://pirate.github.io/zfsify/docs/backup.html'
    } | tee "$LOGDIR/backup-next-steps.txt"
else
    exit 2
fi

ZFS_ON_BOOT_3c9893dd92a0ee9b419747f9064bb6c2336862f914b24ce9ea267b9808a3fcb5
cat > "$work/priority.py" <<'ZFS_ON_BOOT_30f084bb342a56cb18894353d441529c4b70c40d8929df99548c01212793b161'
#!/usr/bin/python3
"""Select complete optional files for erase mode within a conservative RAM budget."""
import os
from pathlib import Path
import stat
import sys
budget = int(sys.argv[1]); output = Path(sys.argv[2]); rootdev = os.stat('/').st_dev
excluded = ('/var/lib/zfs-on-boot', '/var/lib/dpkg', '/var/lib/apt', '/var/cache/apt',
            '/var/lib/cloud', '/var/lib/systemd', '/var/log/zfs-on-boot', '/root/.cache')
used = logical = omitted = 0
seen = set(); parents = set(); preview = []
def paths(base):
    try: info = os.lstat(base)
    except FileNotFoundError: return
    if info.st_dev != rootdev or any(base == p or base.startswith(p+'/') for p in excluded): return
    if stat.S_ISDIR(info.st_mode):
        with os.scandir(base) as entries:
            for entry in entries: yield from paths(entry.path)
    elif stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
        yield base, info
with output.open('wb') as selected, output.with_suffix('.manifest').open('w') as manifest:
    priority = ('/root', '/home', '/var', '/opt', '/srv', '/usr/local')
    skip = {'etc','root','home','var','opt','srv','usr','bin','sbin','lib','lib32','lib64','libx32','boot','dev','proc','sys','run','tmp','mnt','media','lost+found','swapfile','swap.img','vmlinuz','vmlinuz.old','initrd.img','initrd.img.old'}
    additional = [entry.path for entry in os.scandir('/') if entry.name not in skip]
    for base in (*priority, *additional):
        for name, info in paths(base):
            # Account SSH contents are captured as mandatory identity, independently.
            if '/.ssh/' in name: continue
            key = info.st_dev, info.st_ino
            cost = 4096 + (info.st_blocks*512 if stat.S_ISREG(info.st_mode) and key not in seen else 0)
            ancestry = [str(p) for p in Path(name).parents if str(p) != '/' and str(p) not in parents]
            cost += 4096 * len(ancestry)
            if used + cost > budget:
                omitted += info.st_size
                manifest.write('OMIT\t'+name+'\n'); continue
            used += cost; logical += info.st_size; seen.add(key)
            for parent in reversed(ancestry):
                selected.write(os.fsencode(parent.lstrip('/'))+b'\0'); parents.add(parent)
            selected.write(os.fsencode(name.lstrip('/'))+b'\0')
            manifest.write('KEEP\t'+name+'\n')
            if len(preview) < 30: preview.append(name)
print(f'Priority restore: {logical/1e9:.3f} GB of {((logical+omitted)/1e9):.3f} GB eligible optional logical file data selected.')
print(f'Archive budget: {budget/1e6:.1f} MB; conservative selected allocation: {used/1e6:.1f} MB.')
print('Accounts, SSH contents, and /etc are mandatory and retained separately.')
print('Fresh Ubuntu supplies core libraries, kernels, and package databases. Omitted files will be lost.')
print('First selected files:\n'+'\n'.join(preview))
print('Complete KEEP/OMIT preview:', output.with_suffix('.manifest'))

ZFS_ON_BOOT_30f084bb342a56cb18894353d441529c4b70c40d8929df99548c01212793b161
bash "$work/stage.sh" "$work" "$@" </dev/null
