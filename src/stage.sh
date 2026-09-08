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
python3 "$SOURCE/network.py" "$ROOT/etc/zfs-on-boot/network.sh"
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
