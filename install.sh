#!/bin/sh
# zfsify: preserve by default; --erase retains configuration and users only.
set -eu
if [ "$(id -u)" != 0 ]; then echo 'Run as root: curl -fsSL URL | sudo sh' >&2; exit 1; fi
work=$(mktemp -d /tmp/zfs-on-boot.XXXXXXXX)
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT
cat > "$work/stage.sh" <<'ZFS_ON_BOOT_c602468291242e53a62175bf071ce027ce088ab7252f2f455c2112cc25353f7c'
#!/bin/bash
# Preserve an ext4 Ubuntu installation by migrating through a RAM rescue OS.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
SOURCE=${1:?source directory required}
shift
MODE=auto
TARGET=/
BACKUP=
MODE_COUNT=0
TARGET_COUNT=0
for arg in "$@"; do
    case "$arg" in
        --auto) MODE=auto; MODE_COUNT=$((MODE_COUNT+1)) ;;
        --preserve) MODE=preserve; MODE_COUNT=$((MODE_COUNT+1)) ;;
        --erase) MODE=erase; MODE_COUNT=$((MODE_COUNT+1)) ;;
        --inplace) MODE=inplace; MODE_COUNT=$((MODE_COUNT+1)) ;;
        --backup) MODE=backup; BACKUP=ask; MODE_COUNT=$((MODE_COUNT+1)) ;;
        --backup=*) MODE=backup; BACKUP=${arg#*=}; MODE_COUNT=$((MODE_COUNT+1)) ;;
        --help|-h)
            cat <<'EOF'
Usage: curl -fsSL URL | sudo sh -s -- [--auto | --preserve | --erase | --backup[=REMOTE:PATH|/MOUNT/DIR] | --inplace] [/ | MOUNTPOINT | BLOCK_DEVICE]

Default: detect the disk and choose a data-preserving strategy.
Automatic 50/50 and slice-by-slice accept Enter or 15 seconds idle.
Backup fallback waits for input; explicit flags skip strategy prompts.
  --preserve               Request the 50/50 copy-and-verify strategy.
  --auto                   Choose automatically (the default).
  --backup                 Guide me through a temporary Volume or rclone remote.
  --backup=/mnt/backup     Use a mounted, separate ext4 disk without prompts.
  --backup=myremote:path   Use an existing root-user rclone configuration.
  --erase                  Fresh Ubuntu with limited settings restore for /;
                           discard ALL files when targeting a data volume.
  --inplace                EXPERIMENTAL root conversion using recycled ext4 space.
                           Uses a temporary 1 GiB journal area on the same disk.

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
        [[ $MODE != inplace ]] || { echo '--inplace currently supports the boot drive only.' >&2; exit 2; }
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
[[ $ID = ubuntu && ( $VERSION_ID = 22.04 || $VERSION_ID = 24.04 || $VERSION_ID = 26.04 ) ]] || die 'Ubuntu 22.04, 24.04, or 26.04 is required.'
ARCH=$(dpkg --print-architecture)
case $ARCH in
    amd64) MIRROR=http://archive.ubuntu.com/ubuntu; SECURITY_MIRROR=http://security.ubuntu.com/ubuntu ;;
    arm64) MIRROR=http://ports.ubuntu.com/ubuntu-ports; SECURITY_MIRROR=$MIRROR ;;
    *) die 'Root conversion supports amd64 and arm64 Ubuntu.' ;;
esac
CODENAME=$VERSION_CODENAME
# Match Ubuntu's installed initramfs implementation, including newer releases.
INITRAMFS_PACKAGE=zfs-initramfs
if [[ $(dpkg-query -W -f='${db:Status-Status}' dracut 2>/dev/null || true) = installed ]]; then
    INITRAMFS_PACKAGE=zfs-dracut
fi
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
[[ $ARCH != arm64 || $FIRMWARE = uefi ]] || die 'ARM64 root conversion requires UEFI firmware (not a board-specific U-Boot boot chain).'
BOOT_PACKAGES=(grub2-common)
[[ $FIRMWARE != bios ]] || BOOT_PACKAGES+=(grub-pc-bin extlinux syslinux-common)
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
echo "Detected Ubuntu $VERSION_ID | $ARCH | $FIRMWARE boot"
echo "Root filesystem: $ROOTDEV on $DISK | used $USED_PCT% ($USED_BYTES / $FS_BYTES bytes)"
[[ $(df -Pk /boot | awk 'NR==2 {print $4}') -ge 500000 ]] || die 'At least 500 MB free in /boot is required.'
[[ $(df -Pk / | awk 'NR==2 {print $4}') -ge 3500000 ]] || die 'At least 3.5 GB free disk space is required for staging, including erase mode.'
[[ $(blockdev --getsize64 "$DISK") -ge 10000000000 ]] || die 'At least a 10 GB disk is required.'
[[ $(blockdev --getss "$DISK") = 512 ]] || die 'Only 512-byte logical sectors are supported.'
[[ -s /root/.ssh/authorized_keys ]] || die 'A root SSH authorized_keys file is required.'
[[ ! -e $WORK ]] || die "$WORK already exists. Inspect it before retrying; use the documented cleanup procedure."
[[ ! -d /boot/zfs-on-boot ]] || die 'Old boot staging files exist; inspect them before retrying.'
# Refuse layouts containing data that the root-only copy would miss.
validate_layout() {
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
}
[[ $MODE = erase ]] || validate_layout
PRESERVE_CAPACITY=0
INPLACE_CAPACITY=0
TOTAL_USED=$USED_BYTES
if [[ $MODE != erase ]]; then
    . "$SOURCE/plan.env"
    BOOT_USED=0
    [[ $BOOT_MOUNT != /boot ]] || BOOT_USED=$(df -B1 --output=used /boot | tail -1)
    TOTAL_USED=$((USED_BYTES+BOOT_USED))
    PRESERVE_CAPACITY=$(( (SPLIT-ROOT_START)*512-1048576 ))
    TAIL_CAPACITY=$(( (ROOT_END-SPLIT+1)*512 ))
    (( PRESERVE_CAPACITY <= TAIL_CAPACITY )) || PRESERVE_CAPACITY=$TAIL_CAPACITY
    COPY_END=$(( (ROOT_END+1)/2048*2048-2097152-1 ))
    IMAGE_START=$ROOT_START
    (( IMAGE_START >= 1050624 )) || IMAGE_START=1050624
    INPLACE_CAPACITY=$(( (COPY_END-IMAGE_START+1)*512-1048576 ))
fi
python3 "$SOURCE/boot-config.py" "$SOURCE/boot-preview"
echo "Preserved Ubuntu boot arguments: $(cat "$SOURCE/boot-preview/cmdline-ubuntu")"
echo 'CPU/PCI/I/O/display kernel arguments and existing sysctl/modprobe configuration are retained.'
echo 'Active network links/addresses are captured for the RAM rescue; installed network configuration is preserved.'
ip -brief address
EXPLICIT=()
[[ $MODE = auto ]] || EXPLICIT=(--explicit)
while :; do
python3 "$SOURCE/strategy.py" menu "${EXPLICIT[@]}" --kind root --disk "$DISK" --size "$FS_BYTES" --used "$TOTAL_USED" \
    --preserve-capacity "$PRESERVE_CAPACITY" --inplace-capacity "$INPLACE_CAPACITY" \
    --mode "$MODE" --backup "$BACKUP" > "$SOURCE/selection"
mapfile -t SELECTION < "$SOURCE/selection"
MODE=${SELECTION[0]}; BACKUP=${SELECTION[1]}
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
elif [[ $MODE = inplace ]]; then
    cat <<EOF
EXPERIMENTAL IN-PLACE CONVERSION: $ROOTDEV -> one native ZFS root partition.
  [ ext4 files + free space                    ]
  [ ext4 files shrinking | sparse ZFS growing  ]  copy, sync, verify, release 64 MiB batches
  [ completed ZFS image inside ext4           ]  verify the complete manifest
  [ native ZFS partition; no image or mapper  ]  fsremap relocates physical blocks
A temporary 1 GiB area at the end holds the rescue system and migration journal.
Original file data is released progressively. This is not a retained full backup.
The rescue entry resumes an interrupted copy or remap. Bootloader replacement
still has a short recovery window; keep a provider backup before converting.
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
REVIEW=$(python3 "$SOURCE/strategy.py" confirm "${EXPLICIT[@]}" --mode "$MODE" --label "Selected: $MODE on $DISK. Review the diagram above.")
[[ $REVIEW != 1 ]] || break
done
# Ensure a preserving strategy has a validated partition plan.
[[ $MODE = erase || -s $SOURCE/plan.env ]] || validate_layout
if [[ $MODE = inplace && $FIRMWARE = uefi ]]; then
    [[ $ARCH != arm64 ]] || BOOT_PACKAGES+=(grub-efi-arm64-bin)
    [[ $ARCH != amd64 ]] || BOOT_PACKAGES+=(grub-efi-amd64-bin)
fi
mkdir -m 700 "$WORK"
exec > >(tee -a "$WORK/stage.log") 2>&1
trap 'echo "Staging failed at line $LINENO; the disk has NOT been erased. See /var/lib/zfs-on-boot/stage.log."' ERR
phase 1 'Preflight passed; migration strategy selected' true
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
    phase 2 'Prepare existing Ubuntu for ZFS boot' apt-get install -y --no-install-recommends linux-image-virtual "$INITRAMFS_PACKAGE" zfsutils-linux "${BOOT_PACKAGES[@]}" cloud-guest-utils rsync
fi
if [[ $ARCH = arm64 ]]; then
    python3 "$SOURCE/boot-config.py" "$WORK/boot"
    phase 2 'Build ARM64 ZFSBootMenu automatically' bash "$SOURCE/zbm-build.sh" "$WORK"
fi
phase 2 'Build independent RAM rescue Ubuntu' debootstrap --variant=minbase "$CODENAME" "$ROOT" "$MIRROR"
cat > "$ROOT/etc/apt/sources.list" <<EOF
deb $MIRROR $CODENAME main universe
deb $MIRROR $CODENAME-updates main universe
deb $SECURITY_MIRROR $CODENAME-security main universe
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
# Only boot utilities are needed here; do not install a GRUB loader on the live disk.
phase 2 'Install RAM rescue packages' chroot "$ROOT" apt-get install -y --no-install-recommends linux-image-virtual "$INITRAMFS_PACKAGE" zfsutils-linux "${BOOT_PACKAGES[@]}" openssh-server cloud-init netplan.io systemd-sysv $RESOLVED_PACKAGE systemd-timesyncd udev sudo locales ca-certificates curl wget lsb-release python3 gdisk parted e2fsprogs dosfstools cpio gzip rsync cloud-guest-utils apparmor busybox-static rclone binutils efibootmgr </dev/null
if [[ $MODE = inplace ]]; then
    phase 2 'Install experimental block remapper' chroot "$ROOT" apt-get install -y --no-install-recommends fstransform dmsetup
fi
mkdir -p "$ROOT/etc/zfs-on-boot"
printf '%s\n' "$FIRMWARE" > "$ROOT/etc/zfs-on-boot/firmware"
python3 "$SOURCE/boot-config.py" "$ROOT/etc/zfs-on-boot/boot"
if [[ $ARCH = arm64 ]]; then
    mkdir -p "$ROOT/etc/zfs-on-boot/zbm"
    mv "$WORK/zfsbootmenu.EFI" "$ROOT/etc/zfs-on-boot/zbm/"
else
    phase 2 "Download verified ZFSBootMenu 3.1.0 for $FIRMWARE" bash "$SOURCE/zbm-install.sh" download "$ROOT"
fi
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
[[ $MODE != preserve && $MODE != inplace ]] || cp "$SOURCE/plan.env" "$ROOT/etc/zfs-on-boot/plan.env"
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
cp "$SOURCE/inplace.sh" "$SOURCE/inplace-move.py" "$ROOT/etc/zfs-on-boot/"
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
phase 3 'Build minimal RAM boot shim' python3 "$SOURCE/build-rescue.py" "$ROOT" "$WORK/shim" "$SOURCE" "$KVER" "$(blkid -s UUID -o value "$ROOTDEV")" "$DISK"
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
RESCUE_CMDLINE=$(cat "$ROOT/etc/zfs-on-boot/boot/cmdline-grub")
cat > /etc/grub.d/09_zfs_on_boot <<EOF
#!/bin/sh
cat <<'GRUB'
menuentry 'ZFS on boot installer ($MODE)'  --id zfs-on-boot-install {
    search --no-floppy --fs-uuid --set=root $BOOT_UUID
    linux $BOOT_PREFIX/zfs-on-boot/vmlinuz $RESCUE_CMDLINE rdinit=/init panic=0
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

ZFS_ON_BOOT_c602468291242e53a62175bf071ce027ce088ab7252f2f455c2112cc25353f7c
cat > "$work/strategy.py" <<'ZFS_ON_BOOT_7bb341c54bd2bcf40a581404dac06822b1d4973f69b50f8ca4f298aa183d25ff'
#!/usr/bin/env python3
"""Read-only strategy discovery and timed choices; never format or mount disks."""
import argparse
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import time

MARGIN = 256 * 1024**2


def recommended(size, used, preserve_capacity, inplace_capacity):
    # Leave working room for filesystem metadata instead of treating 49.9% as a guarantee.
    required = used * 11 // 10 + MARGIN
    preserve = used * 2 < size and required <= preserve_capacity
    inplace = required <= inplace_capacity
    default = 'preserve' if preserve else 'inplace' if inplace else 'backup'
    return default, preserve, inplace


def backup_candidates(disk, used):
    """Only writable ext4 mounts on a single, different disk with ample space."""
    def command(*args):
        return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL)
    try:
        mounts = json.loads(command('findmnt', '--json', '--list', '-t', 'ext4',
                                    '-o', 'TARGET,SOURCE,OPTIONS'))['filesystems']
    except (OSError, subprocess.CalledProcessError, ValueError, KeyError):
        return []
    found = []
    for mount in mounts:
        try:
            target, source = mount['target'], mount['source']
            if 'rw' not in mount['options'].split(',') or not source.startswith('/dev/'):
                continue
            # Bind mounts/subvolumes cannot be mounted by UUID at the same path in rescue.
            if '[' in source or not Path(source).is_block_device():
                continue
            parents = {line.split()[0] for line in command('lsblk', '-snrpo', 'NAME,TYPE', source).splitlines()
                       if line.split()[-1] == 'disk'}
            if len(parents) != 1 or os.path.realpath(disk) in map(os.path.realpath, parents):
                continue
            space = os.statvfs(target)
            if space.f_bavail * space.f_frsize >= used * 12 // 10 + MARGIN:
                found.append(dict(path=target, device=source, disk=next(iter(parents)),
                                  free=space.f_bavail * space.f_frsize,
                                  total=space.f_blocks * space.f_frsize))
        except (OSError, subprocess.CalledProcessError, KeyError, ValueError):
            continue
    unique = {item['device']: item for item in found}
    return sorted(unique.values(), key=lambda item: (-item['free'] / max(1, item['total']),
                                                     -item['free'], item['path']))


def choose(prompt, default, options, seconds=15):
    """Read /dev/tty, never the curl pipe. Invalid/partial input never means consent."""
    print(prompt, file=sys.stderr, flush=True)
    try:
        tty = open('/dev/tty', 'r')
    except OSError:
        tty = None
    try:
        if seconds is None:
            if tty is None:
                raise ValueError('Manual confirmation requires a terminal. Re-run in an interactive SSH session.')
            print(f'Enter = {default}; waiting for your selection (no timeout): ',
                  end='', file=sys.stderr, flush=True)
            line = tty.readline()
            if not line:
                raise ValueError('Terminal closed; cancelled.')
            answer = line.strip().lower() or default
            if answer not in options:
                raise ValueError('Unknown choice; cancelled.')
            return answer
        deadline = time.monotonic() + seconds
        while True:
            left = max(0, deadline - time.monotonic())
            print(f'\rEnter = {default}; starting in {int(left + .999):2d}s (Ctrl-C cancels). ',
                  end='', file=sys.stderr, flush=True)
            if tty and select.select([tty], [], [], min(1, left))[0]:
                answer = tty.readline().strip().lower()
                print(file=sys.stderr)
                if not answer:
                    return default
                if answer not in options:
                    raise ValueError('Unknown choice; cancelled without starting conversion.')
                return answer
            if not tty:
                time.sleep(min(1, left))
            if time.monotonic() >= deadline:
                # A partially typed answer must not be silently ignored at timeout.
                if tty:
                    import termios
                    old = termios.tcgetattr(tty)
                    new = old.copy(); new[3] &= ~termios.ICANON
                    try:
                        termios.tcsetattr(tty, termios.TCSANOW, new)
                        if select.select([tty], [], [], 0)[0]:
                            raise ValueError('Unfinished choice; cancelled without starting conversion.')
                    finally:
                        termios.tcsetattr(tty, termios.TCSANOW, old)
                print(file=sys.stderr)
                return default
    finally:
        if tty:
            tty.close()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest='action', required=True)
    menu = sub.add_parser('menu')
    menu.add_argument('--kind', choices=['root', 'volume'], required=True)
    menu.add_argument('--disk', required=True)
    menu.add_argument('--size', type=int, required=True)
    menu.add_argument('--used', type=int, required=True)
    menu.add_argument('--preserve-capacity', type=int, required=True)
    menu.add_argument('--inplace-capacity', type=int, default=0)
    menu.add_argument('--mode', choices=['auto', 'preserve', 'inplace', 'backup', 'erase'], default='auto')
    menu.add_argument('--backup', default='')
    menu.add_argument('--erase-only', action='store_true')
    menu.add_argument('--explicit', action='store_true')
    confirm = sub.add_parser('confirm')
    confirm.add_argument('--label', required=True)
    confirm.add_argument('--explicit', action='store_true')
    confirm.add_argument('--mode', choices=['preserve', 'inplace', 'backup', 'erase'], required=True)
    destination = sub.add_parser('destination')
    destination.add_argument('--disk', required=True)
    destination.add_argument('--used', type=int, required=True)
    transport = sub.add_parser('transport')
    args = p.parse_args()
    if args.action == 'destination':
        candidates = backup_candidates(args.disk, args.used)
        print('Candidate destinations (space available does not mean a disk is reserved for backups):', file=sys.stderr)
        for i, item in enumerate(candidates, 1):
            print(f"  {i}) {item['path']} — {item['device']} on {item['disk']}; "
                  f"{item['free']/1e9:.1f}/{item['total']/1e9:.1f} GB free"
                  + (' [recommended by free-space ratio; confirm ownership/use]' if i == 1 else ''), file=sys.stderr)
        options = {str(i): item['path'] for i, item in enumerate(candidates, 1)}
        options.update(p='path', r='', q='q')
        choice = choose('  p) Enter another directory  r) Refresh disks  q) Back',
                        '1' if candidates else 'r', options, seconds=None)
        print(options[choice])
        return
    if args.action == 'confirm':
        if args.explicit:
            print('1')
            return
        answer = choose(args.label + '\n  1) Proceed with this plan\n  2) Review all strategies\n  q) Cancel', '1', ['1', '2', 'q'], seconds=15 if args.mode in ('preserve', 'inplace') else None)
        if answer == 'q':
            raise ValueError('Cancelled.')
        print(answer)
        return
    if args.action == 'transport':
        print(choose('Choose backup setup: 1) attached Volume  2) rclone config  3) existing remote  q) cancel',
                     '1', ['1', '2', '3', 'q'], seconds=None))
        return
    backup = args.backup if args.backup not in ('', 'ask') else 'ask'
    default, preserve, inplace = recommended(args.size, args.used, args.preserve_capacity,
                                            args.inplace_capacity if args.kind == 'root' else 0)
    available = {'preserve': preserve, 'inplace': inplace and args.kind == 'root', 'backup': True, 'erase': True}
    if args.erase_only:
        available.update(preserve=False, inplace=False, backup=False)
    if args.mode != 'auto':
        default = args.mode
    labels = {'preserve': '50/50: keep ext4 until the ZFS copy is verified',
              'inplace': 'Slice-by-slice: recycle verified ext4 blocks (experimental)',
              'backup': 'External backup: verify an independent archive, then restore',
              'erase': 'ERASE: discard data; root gets limited settings restoration'}
    keys = {'1': 'preserve', '2': 'inplace', '3': 'backup', '4': 'erase'}
    print(f'\nMigration options for {args.disk} ({args.used/1e9:.2f}/{args.size/1e9:.2f} GB used):', file=sys.stderr)
    for key, mode in keys.items():
        reason = '' if available[mode] else (' — rerun without --erase to assess preservation' if args.erase_only else ' — unavailable for data volumes' if mode == 'inplace' and args.kind != 'root'
                  else ' — unavailable: insufficient working space')
        print(f'  {key}) {labels[mode]}{reason}' + (' [default]' if mode == default else ''), file=sys.stderr)
    print('  q) Cancel\nExternal backup always requires manual destination selection and confirmation.', file=sys.stderr)
    if not available[default]:
        raise ValueError(f'{default} does not fit this disk; use automatic selection or --backup.')
    if args.explicit:
        print(default)
        print(backup)
        return
    default_key = next(k for k, v in keys.items() if v == default)
    choice = choose('Choose a strategy. Erase requires --erase or explicit confirmation.', default_key, [*keys, 'q'],
                    seconds=15 if default in ('preserve', 'inplace') else None)
    if choice == 'q':
        raise ValueError('Cancelled.')
    mode = keys[choice]
    if not available[mode]:
        raise ValueError('That strategy is unavailable; cancelled without starting conversion.')
    if mode == 'erase' and args.mode != 'erase':
        try:
            with open('/dev/tty', 'r') as tty:
                print('Type y and press Enter to confirm data loss: ', end='', file=sys.stderr, flush=True)
                if tty.readline().strip() != 'y':
                    raise ValueError('Erase cancelled.')
        except OSError:
            raise ValueError('Erase needs explicit --erase or terminal confirmation.') from None
    print(mode)
    print(backup or 'ask')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyboardInterrupt) as error:
        print(f'\nzfsify: {error or "Cancelled."}', file=sys.stderr)
        sys.exit(2)

ZFS_ON_BOOT_7bb341c54bd2bcf40a581404dac06822b1d4973f69b50f8ca4f298aa183d25ff
cat > "$work/network.py" <<'ZFS_ON_BOOT_a82ba05a7315d207cd87119e21c43094cf67c3e79fbc41412e7a6cee530b5aec'
#!/usr/bin/env python3
"""Capture hardware NIC addresses and main-table routes for the RAM installer."""
import json
from pathlib import Path
import shlex
import subprocess
import sys


def ip(*args):
    return json.loads(subprocess.check_output(['ip', '-j', *args]))


def render(links, routes):
    q = shlex.quote
    lines = ['#!/bin/bash', 'set -eu', 'ip link set lo up']
    for link in links:
        name, mac = link['ifname'], link['address']
        lines += [
            f'iface=$(for p in /sys/class/net/*; do if [ "$(cat "$p/address")" = {q(mac)} ]; then basename "$p"; break; fi; done)',
            '[ -n "$iface" ]',
            f'ip link set "$iface" mtu {int(link["mtu"])} up',
        ]
        for addr in link.get('addr_info', []):
            if addr['scope'] in ('global', 'site'):
                lines.append(f'ip addr replace {q(addr["local"] + "/" + str(addr["prefixlen"]))} dev "$iface"')
        for family in ['-4', '-6']:
            # ip route show usually lists the default first. With a /32 address,
            # its gateway needs an explicit direct route before a via route works.
            # Keep kernel-protocol host routes too: adding the address alone does
            # not recreate a provider gateway outside the address's own prefix.
            for route in sorted(routes[(name, family)], key=lambda r: 'gateway' in r):
                if route.get('dst', '').startswith('fe80:'):
                    continue
                cmd = f'ip {family} route replace {q(route.get("dst", "default"))}'
                if 'gateway' in route:
                    cmd += ' via ' + q(route['gateway'])
                cmd += ' dev "$iface"'
                if 'scope' in route:
                    cmd += ' scope ' + q(route['scope'])
                if 'prefsrc' in route:
                    cmd += ' src ' + q(route['prefsrc'])
                if 'metric' in route:
                    cmd += ' metric ' + str(route['metric'])
                if 'onlink' in route.get('flags', []):
                    cmd += ' onlink'
                lines.append(cmd)
    return '\n'.join(lines) + '\n'


if __name__ == '__main__':
    # RAM boot recreates hardware NICs, not Docker bridges or veth pairs.
    links = [link for link in ip('address', 'show')
             if link['ifname'] != 'lo' and link.get('address')
             and Path('/sys/class/net', link['ifname'], 'device').exists()]
    routes = {(link['ifname'], family): ip(family, 'route', 'show', 'dev', link['ifname'])
              for link in links for family in ['-4', '-6']}
    Path(sys.argv[1]).write_text(render(links, routes))

ZFS_ON_BOOT_a82ba05a7315d207cd87119e21c43094cf67c3e79fbc41412e7a6cee530b5aec
cat > "$work/boot-config.py" <<'ZFS_ON_BOOT_36d30568afc0a651df79dd47bddc4d62e8de417c96f14604377c7c68db04201b'
#!/usr/bin/env python3
"""Retain existing boot options while replacing the old root/initramfs contract."""
from pathlib import Path
import re
import shlex
import sys

# These identify the old filesystem or a one-shot boot mode, not the hardware.
REPLACED = {
    'BOOT_IMAGE', 'BOOTIF', 'root', 'rootfstype', 'rootflags', 'rootdelay',
    'rootwait', 'resume', 'resume_offset', 'initrd', 'init', 'rdinit', 'boot',
    'ro', 'rw', 'single', 'emergency', 'rescue', 'rd.break', 'break',
    'systemd.unit', 'rd.systemd.unit',
}


def commandlines(text, consoles=('tty0',)):
    # Linux command lines use double quotes, not shell evaluation. Retain their
    # spelling, including quoted values containing spaces, for the final kernel.
    tokens = re.findall(r'(?:[^\s"]|"[^"]*")+', text)
    kept = []
    for token in tokens:
        if token == '--':
            break  # Following words are init arguments, not kernel options.
        key = token.split('=', 1)[0].strip('"')
        if key in REPLACED or key.startswith(('zbm.', 'systemd.run')):
            continue
        kept.append(token)
    if not any(t.split('=', 1)[0].strip('"') == 'console' for t in kept):
        kept += ['console=' + console for console in consoles]
    # Keep diagnostics visible and leave the RAM/ZBM init program in control.
    # All other existing CPU, PCI, I/O, display and driver options pass through.
    rescue = [t for t in kept if t.split('=', 1)[0].strip('"') not in
              {'quiet', 'splash', 'vt.handoff', 'panic'}
              and not t.split('=', 1)[0].strip('"').startswith(('systemd.', 'rd.', 'zfs.', 'spl.'))]
    return {'ubuntu': ' '.join(kept), 'rescue': ' '.join(rescue),
            'grub': ' '.join(shlex.quote(t) for t in rescue)}


if __name__ == '__main__':
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    active = Path('/sys/class/tty/console/active')
    consoles = active.read_text().split() if active.exists() else ['tty0']
    for name, value in commandlines(Path('/proc/cmdline').read_text(), consoles or ['tty0']).items():
        (out / ('cmdline-' + name)).write_text(value + '\n')

ZFS_ON_BOOT_36d30568afc0a651df79dd47bddc4d62e8de417c96f14604377c7c68db04201b
cat > "$work/ram-init.sh" <<'ZFS_ON_BOOT_7dad8f083911d88745ba0fbc5848010198194c395895a424e1ac1cb263b2554b'
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
exec </dev/console >/dev/console 2>&1
set -Eeuo pipefail
MIGRATION_STARTED=0
[[ " $(cat /proc/cmdline) " != *' zfsify.rescue='* ]] || MIGRATION_STARTED=1
rescue() {
    trap - ERR
    echo "INSTALLATION FAILED at line $1. Use the provider console; SSH requires working networking."
    echo 'Run zfs-on-boot-status; logs: /run/zfs-on-boot.log and /var/log/zfs-on-boot/progress.log.'
    if [[ $MIGRATION_STARTED = 0 ]]; then
        echo 'Disk migration has not started. Rebooting returns to the original Ubuntu boot entry.'
    elif [[ ${MODE:-} = inplace ]]; then
        echo 'The persistent rescue entry can resume copy/remap; bootloader cutover may need provider recovery.'
    else
        echo 'Do not reboot after source removal. Inspect the migration logs before taking action.'
    fi
    while true; do /bin/bash </dev/console >/dev/console 2>&1 || true; sleep 2; done
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
ROOTDEV=$(blkid -U "$(cat /etc/zfs-on-boot/old-root-uuid)" || true)
if [[ $MODE = inplace && -z $ROOTDEV ]]; then
    # fsremap replaces ext4's UUID; recovery uses the persistent journal.
    ROOTDEV=$(cat /etc/zfs-on-boot/old-root-device)
fi
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
create_root_pool() {
# Ubuntu's root-pool defaults, with boot-image compatibility and disk growth.
# Keep ext4's distinct Unicode filenames distinct rather than normalizing them.
phase 4 "Create rpool on $ZPART" zpool create -f -o ashift=12 -o autotrim="${1:-on}" -o compatibility=openzfs-2.1-linux -o autoexpand=on -o cachefile=none -O compression=lz4 -O relatime=on -O devices=off -O dnodesize=auto -O xattr=sa -O acltype=posixacl -O canmount=off -O mountpoint=none -R /target rpool "$ZPART"
zfs create -o canmount=off -o mountpoint=none rpool/ROOT
zfs create -o mountpoint=/ -o canmount=noauto rpool/ROOT/ubuntu
zfs mount rpool/ROOT/ubuntu
zpool set bootfs=rpool/ROOT/ubuntu rpool
}
MIGRATION_STARTED=1
if [[ $MODE = inplace ]]; then
    source /etc/zfs-on-boot/inplace.sh
else
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
create_root_pool
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
python3 /usr/local/lib/zfs-on-boot/progress.py run --phase 5 --label "Copy $SOURCE to $ZPART" --devices "$DEVICES" --source "$SOURCE" --target "$ZPART" --total "$TOTAL" -- rsync -aHAXS --numeric-ids --info=progress2,name0 --outbuf=L --stats "${EXCLUDES[@]}" "$SOURCE" /target/
phase 6 "Checksum and metadata verification: $ROOTDEV -> $ZPART" bash -o pipefail -c 'rsync -aHAXSnic --numeric-ids --delete "$@" > /run/copy-differences; cat /run/copy-differences; test ! -s /run/copy-differences' _ "${EXCLUDES[@]}" "$SOURCE" /target/
echo 'Verified: file checksums, ownership, permissions, ACLs, xattrs and hard links match.'
fi
fi  # Existing preservation/backup/erase backend.
if [[ $MODE != inplace || $INPLACE_PHASE != configured ]]; then
phase 7 'Configure ZFS root, initramfs and boot services' bash /etc/zfs-on-boot/target.sh
fi
phase 7 'Flush the configured ZFS root to disk' zpool sync rpool
[[ $MODE != inplace ]] || inplace_checkpoint configured
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
    python3 /usr/local/lib/zfs-on-boot/progress.py run --phase 8 --label "Relocate via mirror: $TEMP -> $FRONT" --devices "$DEVICES" --source "$TEMP" --target "$FRONT" --resilver -- zpool attach -f -w rpool "$TEMP" "$FRONT"
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
elif [[ $MODE = inplace ]]; then
    phase 8 'Native remap complete: no mirror relocation required' true
    # The new loader and root are durable before releasing the rescue area.
    cp -a "$STATE/." /target/var/log/zfs-on-boot/inplace/
    sync
    umount /scratch
    sgdisk -d 32 "$DISK"
    partx -d --nr 32 "$DISK"
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

ZFS_ON_BOOT_7dad8f083911d88745ba0fbc5848010198194c395895a424e1ac1cb263b2554b
cat > "$work/target.sh" <<'ZFS_ON_BOOT_6a3110d389741d58aec4c4f7510299045f54cca22e8f8516370bd55ca3619168'
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

ZFS_ON_BOOT_6a3110d389741d58aec4c4f7510299045f54cca22e8f8516370bd55ca3619168
cat > "$work/progress.py" <<'ZFS_ON_BOOT_d18ef74b2e2f3466754064bdd47b3aedf0aac496f9e707a6f701857c44d7df75'
#!/usr/bin/python3
"""Dependency-free migration dashboard, live Linux telemetry and durable plain logs."""
import argparse
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import time

STATE = Path('/run/zfs-on-boot-progress.json')
LOG = Path('/var/log/zfs-on-boot/progress.log')
ANSI = re.compile(r'\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))')


def clean(value):
    return ''.join(c for c in ANSI.sub('', str(value)) if c.isprintable())


def amount(n):
    for unit in ('B', 'KB', 'MB', 'GB', 'TB', 'PB'):
        if abs(n) < 1000 or unit == 'PB':
            return f'{n:,.1f} {unit}'
        n /= 1000


def duration(seconds):
    seconds = max(0, int(seconds))
    return f'{seconds//3600}h {seconds%3600//60:02d}m' if seconds >= 3600 else f'{seconds//60:02d}:{seconds%60:02d}'


def render(s, width=88, frame=0, color=False, unicode=True):
    """Each tile represents a share of logical bytes, not a physical disk extent."""
    width = max(1, width)
    total, done = s.get('total', 0), s.get('done', 0)
    fraction = min(1, max(0, done / total)) if total else 0
    status = s.get('status', 'running')
    running = status == 'running'
    solid, empty, active = ('█', '░', '▓') if unicode else ('#', '.', '>')
    tick, arrow, dot = ('✓', '→', '·') if unicode else ('+', '->', '.')
    pulses = '·•●•' if unicode else '|/-\\'
    spinner = pulses[frame % len(pulses)]
    badge = spinner if running else tick if status == 'complete' else '!'
    phase = s['phase']
    rail = ' '.join(tick if i < phase or (i == phase and status == 'complete') else
                    ('●' if unicode else '*') if i == phase else dot for i in range(1, 11))
    lines = [f'  zfsify  {dot}  {badge} {status.upper()}  {dot}  PHASE {phase:02d}/10',
             f'  {rail}', f"  {s['label']}", '']
    if s.get('source') or s.get('target'):
        lines.append(f"  {s.get('source') or 'source'}  {arrow}  {s.get('target') or 'destination'}")
    else:
        lines.append(f"  Devices  {s['devices']}")
    cells = max(1, min(28, (width - 12) // 2))
    if total:
        filled = int(fraction * cells)
        blocks = solid * filled + empty * (cells - filled)
        if running and filled < cells:
            blocks = blocks[:filled] + (active if frame % 4 < 2 else solid) + blocks[filled+1:]
        lines += [f'  {" ".join(blocks)}  {fraction*100:5.1f}%',
                  f"  {'~' if s.get('approximate') else ''}{amount(done)} / {amount(total)}  {dot}  logical bytes"]
    else:
        head = frame % (cells + 4)
        blocks = ''.join(active if 0 <= head-i < 4 and running else empty for i in range(cells))
        lines += [f'  {" ".join(blocks)}', f'  {"Working" if running else status.capitalize()}  {dot}  total unavailable (streaming / metadata)']
    speed = max(0, s.get('speed', 0))
    eta = duration((total - done) / speed) if total > done and speed > 0 and running else '--'
    rate = f'{amount(speed)}/s' if total else '--'
    lines.append(f"  {rate}{' avg' if not running and total else ''}  {dot}  elapsed {duration(s['elapsed'])}  {dot}  ETA {eta}")
    if s.get('files_total'):
        lines.append(f"  Files  {s.get('files_done', 0):,} / {s['files_total']:,}")
    for device, values in s.get('io', {}).items():
        lines.append(f'  {device}  R {values[0]:.1f} MB/s  W {values[1]:.1f} MB/s  {values[2]:.0f} IOPS')
    if not s.get('io'):
        lines.append('  Device I/O  waiting for counters' if running else '  Device I/O  unavailable')
    lines = [clean(line)[:width] for line in lines]
    if color:
        accent = '31' if status == 'failed' else '32' if status == 'complete' else '36'
        lines[0] = f'\033[1;{accent}m{lines[0]}\033[0m'
        lines[1] = f'\033[2m{lines[1]}\033[0m'
        tiles = re.compile('(' + '|'.join(re.escape(c)+'+' for c in (solid, empty, active)) + ')')
        lines[5] = tiles.sub(lambda match: f'\033[{"90" if match[0][0] == empty else "1;"+accent}m'
                             + match[0] + '\033[0m', lines[5])
    return '\n'.join(lines)


class Display:
    """Redraw only our own rows; never erase the user's terminal scrollback."""
    def __init__(self, animate=True):
        self.stream = sys.stdout
        self.owned = False
        if animate and not self.stream.isatty() and os.environ.get('ZFS_PROGRESS_TTY') == '1':
            try:
                self.stream = open('/dev/tty', 'w', buffering=1)
                self.owned = True
            except OSError:
                pass
        self.live = animate and self.stream.isatty() and os.environ.get('TERM') != 'dumb'
        self.color = self.live and 'NO_COLOR' not in os.environ
        self.unicode = 'UTF' in (self.stream.encoding or '').upper().replace('-', '')
        self.rows = 0
        self.frame = 0
        self.width = None
        if self.live:
            self.stream.write('\033[?25l')

    def clear(self):
        if self.rows:
            self.stream.write(f'\033[{self.rows}A\r\033[J')
            self.rows = 0

    def draw(self, state):
        if not self.live:
            print(render(state, width=160, unicode=False), file=self.stream, flush=True)
            return
        size = os.get_terminal_size(self.stream.fileno())
        width = max(1, (size.columns or 80) - 1)
        # After resize, old rows may have reflowed. Start below them instead of
        # moving the cursor into unrelated terminal history.
        if self.width != width:
            self.rows = 0
            self.width = width
        self.clear()
        lines = render(state, width, self.frame, self.color, self.unicode).splitlines()
        lines = lines[:max(1, (size.lines or 24) - 1)]
        self.stream.write('\n'.join(lines) + '\n')
        self.stream.flush()
        self.rows = len(lines)
        self.frame += 1

    def message(self, text):
        self.clear()
        print(clean(text), file=self.stream, flush=True)

    def close(self):
        if self.live:
            self.stream.write('\033[0m\033[?25h')
            self.stream.flush()
        if self.owned:
            self.stream.close()


def disks(names):
    result = {}
    for name in names:
        try:
            fields = list(map(int, Path('/sys/class/block', Path(name).resolve().name, 'stat').read_text().split()))
            result[name] = (fields[2]*512, fields[6]*512, fields[0]+fields[4])
        except (OSError, ValueError):
            pass
    return result


def zbytes(value):
    match = re.fullmatch(r'([\d.,]+)([KMGTPE]?)', value)
    return int(float(match[1].replace(',', '')) * 1024 ** (' KMGTPE'.index(match[2]) if match[2] else 0))


class Counters:
    def __init__(self, state):
        self.state = state
        self.initial = 0

    def consume(self, line):
        s = self.state
        if match := re.match(r'^\s*([\d,]+)\s+(\d+)%\s+', line):
            s['done'] = int(match[1].replace(',', ''))
        elif match := re.fullmatch(r'ZFSIFY_(START|PROGRESS|FILES) ([0-9]{1,20}) ([0-9]{1,20})', line):
            kind, done, total = match.groups()
            if kind == 'FILES':
                s['files_done'], s['files_total'] = int(done), int(total)
            else:
                s['done'], s['total'] = int(done), int(total)
                if kind == 'START':
                    self.initial = int(done)
        else:
            return False
        return True


def watch(args, display):
    last_version = None
    while True:
        source = STATE if STATE.exists() else Path('/var/log/zfs-on-boot/last-progress.json')
        try:
            state = json.loads(source.read_text())
            ready = state['label'].startswith('Ready') and state['status'] == 'complete'
            version = json.dumps(state, sort_keys=True)
            if display.live or version != last_version or args.once:
                display.draw(state)
                last_version = version
            if ready:
                next_steps = Path('/var/log/zfs-on-boot/backup-next-steps.txt')
                if next_steps.exists():
                    for line in next_steps.read_text().splitlines():
                        display.message(line)
            if args.once or state['status'] == 'failed' or ready:
                return 0
        except (OSError, ValueError):
            if last_version != 'waiting':
                display.message('Waiting for installer status...')
                last_version = 'waiting'
            if args.once:
                return 1
        time.sleep(.125 if display.live else 1)


def run(args, display):
    cmd = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not cmd:
        raise ValueError('A phase command is required')
    LOG.parent.mkdir(parents=True, exist_ok=True)
    start = tick = time.monotonic()
    names = list(dict.fromkeys(args.devices.split(',')))
    prev = disks(names)
    state = dict(phase=args.phase, label=args.label, devices=','.join(names), total=args.total,
                 source=args.source, target=args.target, done=0, speed=0, elapsed=0, status='running', io={})
    counters = Counters(state)
    last_done = last_print = last_frame = 0
    buffer = ''

    def publish(final=False):
        nonlocal tick, prev, last_done, last_print
        now = time.monotonic()
        dt = max(now-tick, .001)
        current = disks(names)
        state['io'] = {d: [(v[0]-prev[d][0])/dt/1e6, (v[1]-prev[d][1])/dt/1e6, (v[2]-prev[d][2])/dt]
                       for d, v in current.items() if d in prev and all(new >= old for new, old in zip(v, prev[d]))}
        state['speed'] = max(0, state['done']-counters.initial)/max(now-start, .001) if final else max(0, state['done']-last_done)/dt
        state['elapsed'] = now-start
        prev, tick, last_done = current, now, state['done']
        tmp = STATE.with_suffix('.tmp')
        tmp.write_text(json.dumps(state))
        tmp.replace(STATE)
        if final or now-last_print >= 5:
            message = render(state, width=160, unicode=False)
            with LOG.open('a') as log:
                log.write(message+'\n')
            if not display.live:
                display.draw(state)
            last_print = now
        if final:
            if display.live:
                display.draw(state)

    publish()
    child = None
    try:
        with LOG.open('a') as log, selectors.DefaultSelector() as selector:
            log.write('COMMAND: '+repr(cmd)+'\n')
            child = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     stdin=subprocess.DEVNULL, env={**os.environ, 'LC_ALL':'C'})
            selector.register(child.stdout, selectors.EVENT_READ)
            eof = False
            while not eof:
                for key, _ in selector.select(timeout=.125 if display.live else 1):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        eof = True
                        break
                    buffer += chunk.decode(errors='replace')
                    lines = re.split('[\r\n]', buffer)
                    buffer = lines.pop()
                    # Bound output from tools that emit very long unterminated lines.
                    if len(buffer) > 65536:
                        lines.append(buffer)
                        buffer = ''
                    for line in lines:
                        if counters.consume(line):
                            if line.startswith('ZFSIFY_START '):
                                last_done = counters.initial
                        elif line:
                            display.message(line)
                            log.write(clean(line)+'\n')
                    log.flush()
                now = time.monotonic()
                if now-tick >= 1:
                    if args.resilver:
                        try:
                            scan = subprocess.check_output(['zpool', 'status', '-p', args.pool], text=True)
                            match = re.search(r'([\d.,]+[KMGTPE]?) / ([\d.,]+[KMGTPE]?) issued', scan)
                            if match:
                                state['done'], state['total'] = map(zbytes, match.groups())
                            elif match := re.search(r'scan: resilvered ([\d.,]+[KMGTPE]?)', scan):
                                state['done'] = state['total'] = zbytes(match[1])
                            state['approximate'] = True
                        except subprocess.CalledProcessError:
                            pass
                    publish()
                if display.live and now-last_frame >= .125:
                    display.draw(state)
                    last_frame = now
            if buffer and not counters.consume(buffer):
                display.message(buffer)
                log.write(clean(buffer)+'\n')
            code = child.wait()
            child.stdout.close()
    except BaseException:
        if child is not None and child.poll() is None:
            child.terminate()
            child.wait()
        state['status'] = 'failed'
        publish(final=True)
        raise
    state['status'] = 'complete' if code == 0 else 'failed'
    if code == 0 and state['total']:
        state['done'] = state['total']
    publish(final=True)
    return code


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest='action', required=True)
    f = sub.add_parser('watch')
    f.add_argument('--once', action='store_true')
    r = sub.add_parser('run')
    r.add_argument('--phase', type=int, choices=range(1, 11), required=True)
    r.add_argument('--label', required=True)
    r.add_argument('--devices', required=True)
    r.add_argument('--source', default='')
    r.add_argument('--target', default='')
    r.add_argument('--total', type=int, default=0)
    r.add_argument('--resilver', action='store_true')
    r.add_argument('--pool', default='rpool')
    r.add_argument('command', nargs=argparse.REMAINDER)
    args = p.parse_args()
    def terminate(signum, _frame):
        raise SystemExit(128 + signum)
    previous = signal.signal(signal.SIGTERM, terminate)
    display = Display(animate=not getattr(args, 'once', False))
    try:
        return watch(args, display) if args.action == 'watch' else run(args, display)
    except KeyboardInterrupt:
        return 130
    finally:
        display.close()
        signal.signal(signal.SIGTERM, previous)


if __name__ == '__main__':
    sys.exit(main())

ZFS_ON_BOOT_d18ef74b2e2f3466754064bdd47b3aedf0aac496f9e707a6f701857c44d7df75
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
cat > "$work/ram-boot.sh" <<'ZFS_ON_BOOT_30759405362171b29af22cd9fa1d9408c0b2de06d8b20bc9cbdd6d983d34ab54'
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
    if [ "${RECOVERY:-0}" = 1 ]; then
        echo "Persistent rescue bootstrap failed: $*. Disk migration may be incomplete."
        exec sh
    fi
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
# The persistent rescue copy survives after the original ext4 UUID is gone.
RECOVERY=0
for arg in $(cat /proc/cmdline); do
    case "$arg" in zfsify.rescue=*) SOURCE_UUID=${arg#*=}; RECOVERY=1;; esac
done
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

ZFS_ON_BOOT_30759405362171b29af22cd9fa1d9408c0b2de06d8b20bc9cbdd6d983d34ab54
cat > "$work/build-rescue.py" <<'ZFS_ON_BOOT_6937b61de010540f98d6814303fa45e6671b21a2273402e37bcc911d198d235a'
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
controllers = ['virtio_pci', 'virtio_mmio', 'virtio_blk', 'virtio_scsi', 'scsi_mod', 'sd_mod', 'nvme', 'nvme_core', 'ahci', 'libata', 'hv_vmbus', 'hv_storvsc']
# Discover the running boot disk's driver chain as well as common fallback
# controllers. This covers another hypervisor/controller without naming a cloud.
disk = Path('/sys/class/block') / Path(sys.argv[6]).name
device = disk.resolve(strict=True)
detected = []
for parent in [device, *device.parents]:
    module = parent/'driver/module'
    if module.exists() and module.resolve().name not in detected:
        detected.append(module.resolve().name)
for module in dict.fromkeys(detected + controllers + required):
    deps = subprocess.run(['chroot', str(root), 'modprobe', '--show-depends', '--set-version', kernel, module], text=True, capture_output=True)
    if deps.returncode:
        if module in required + detected: raise RuntimeError('Missing required rescue module: '+module)
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

ZFS_ON_BOOT_6937b61de010540f98d6814303fa45e6671b21a2273402e37bcc911d198d235a
cat > "$work/zbm-install.sh" <<'ZFS_ON_BOOT_ed338db083ec398d1f5969db5185383810761cd6ddeb3b2b5a6c455eb7e9c0d4'
#!/bin/bash
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
ACTION=${1:?} ROOT=${2:?}
FIRMWARE=$(cat "$ROOT/etc/zfs-on-boot/firmware" 2>/dev/null || cat /etc/zfs-on-boot/firmware)
BOOT_CONFIG=$ROOT/etc/zfs-on-boot/boot
[[ $ACTION = download ]] || BOOT_CONFIG=/etc/zfs-on-boot/boot
KCL="$(cat "$BOOT_CONFIG/cmdline-rescue") zbm.timeout=15 zbm.prefer=rpool zbm.sort_key=creation zfs.zfs_arc_min=16777216 zfs.zfs_arc_max=67108864"
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
# A resumed installation can format this partition again, changing its UUID.
# Replace the boot mount entry rather than accumulating obsolete UUIDs.
python3 - "$ROOT/etc/fstab" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
lines = p.read_text().splitlines(keepends=True)
p.write_text(''.join(line for line in lines if line.lstrip().startswith('#')
                     or len(line.split()) < 2
                     or line.split()[1] not in ('/boot/efi', '/boot/syslinux')))
PY
if [[ $FIRMWARE = uefi ]]; then
    case $(uname -m) in
        x86_64) EFI_FALLBACK=BOOTX64.EFI ;;
        aarch64) EFI_FALLBACK=BOOTAA64.EFI ;;
        *) echo 'Unsupported UEFI architecture' >&2; exit 1 ;;
    esac
    mkfs.vfat -F 32 -n ZFSBOOTMENU "$BOOTDEV"
    mkdir -p "$ROOT/boot/efi"
    mount "$BOOTDEV" "$ROOT/boot/efi"
    mkdir -p "$ROOT/boot/efi/EFI/BOOT" "$ROOT/boot/efi/EFI/ZFSBootMenu"
    cp /etc/zfs-on-boot/zbm/zfsbootmenu.EFI "$ROOT/boot/efi/EFI/ZFSBootMenu/zfsbootmenu.EFI"
    cp /etc/zfs-on-boot/zbm/zfsbootmenu.EFI "$ROOT/boot/efi/EFI/BOOT/$EFI_FALLBACK"
    printf 'UUID=%s /boot/efi vfat defaults,umask=0077 0 2\n' "$(blkid -s UUID -o value "$BOOTDEV")" >> "$ROOT/etc/fstab"
    printf 'ZFSBootMenu 3.1.0; %s UEFI\n' "$(uname -m)" > "$ROOT/etc/zfsbootmenu-version"
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
cat > "$ROOT/boot/syslinux/syslinux.cfg" <<CFG
SERIAL 0 115200
DEFAULT zfsbootmenu
PROMPT 0
TIMEOUT 10
LABEL zfsbootmenu
    LINUX /vmlinuz-bootmenu
    INITRD /initramfs-bootmenu.img
    APPEND $KCL
CFG
extlinux --install "$ROOT/boot/syslinux"
printf 'UUID=%s /boot/syslinux ext4 defaults 0 2\n' "$(blkid -s UUID -o value "$BOOTDEV")" >> "$ROOT/etc/fstab"
printf 'ZFSBootMenu 3.1.0; upstream release components linux6.6\n' > "$ROOT/etc/zfsbootmenu-version"
sync
umount "$ROOT/boot/syslinux"
# Activate the BIOS loader only after its files are durable.
dd if=/usr/lib/syslinux/mbr/gptmbr.bin of="$DISK" bs=440 count=1 conv=notrunc,fsync

ZFS_ON_BOOT_ed338db083ec398d1f5969db5185383810761cd6ddeb3b2b5a6c455eb7e9c0d4
cat > "$work/zbm-build.sh" <<'ZFS_ON_BOOT_4c76357c973dd0cf134c763bf14137a2d5fafead0fd40a9e34313a98f32866a3'
#!/bin/bash
# Build upstream ARM64 ZFSBootMenu without changing the host's initramfs tooling.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive
WORK=${1:?}
BUILD=$WORK/zbm-build
[[ $(dpkg --print-architecture) = arm64 ]]
mkdir -p "$BUILD"
cleanup() {
    local point
    for point in dev proc sys; do
        if mountpoint -q "$BUILD/$point"; then umount -R "$BUILD/$point" || return; fi
    done
}
trap cleanup EXIT
# A fixed, independent Ubuntu builder keeps dracut out of both installed systems.
# No kernel compilation is needed: Ubuntu supplies the ARM64 kernel and ZFS.
debootstrap --variant=minbase noble "$BUILD" http://ports.ubuntu.com/ubuntu-ports
cat > "$BUILD/etc/apt/sources.list" <<'EOF'
deb http://ports.ubuntu.com/ubuntu-ports noble main universe
deb http://ports.ubuntu.com/ubuntu-ports noble-updates main universe
deb http://ports.ubuntu.com/ubuntu-ports noble-security main universe
EOF
printf '#!/bin/sh\nexit 101\n' > "$BUILD/usr/sbin/policy-rc.d"
chmod 755 "$BUILD/usr/sbin/policy-rc.d"
cp -L /etc/resolv.conf "$BUILD/etc/resolv.conf"
mount --rbind /dev "$BUILD/dev"
mount --make-rslave "$BUILD/dev"
mount -t proc proc "$BUILD/proc"
mount -t sysfs sysfs "$BUILD/sys"
chroot "$BUILD" apt-get update
chroot "$BUILD" apt-get install -y --no-install-recommends linux-image-virtual zfsutils-linux dracut-core systemd-boot-efi kexec-tools fzf libyaml-pp-perl libsort-versions-perl libboolean-perl make binutils file bsdextrautils kbd ca-certificates
# Ubuntu 26.04 ARM64 kernels use PE zboot, which noble's kexec cannot load.
# This Ubuntu package runs against noble's libraries; only the isolated boot
# image gets it. Keep the installed OS and the builder's other packages intact.
curl --fail --location --retry 3 https://ports.ubuntu.com/ubuntu-ports/pool/main/k/kexec-tools/kexec-tools_2.0.32-3ubuntu1_arm64.deb -o "$BUILD/tmp/kexec.deb"
echo 'bce6037e64e248fc03663fa607a3ad65dc0d3d7042a246d5691fd8dcae5dfbba  '"$BUILD/tmp/kexec.deb" | sha256sum -c -
chroot "$BUILD" dpkg -i /tmp/kexec.deb
# Ubuntu ARM64 vmlinuz may be gzip-wrapped; an EFI stub needs the raw kernel.
# This changes only the disposable builder, not the installed Ubuntu kernels.
for kernel in "$BUILD"/boot/vmlinuz-*; do
    if gzip -t "$kernel" 2>/dev/null; then
        gzip -dc "$kernel" > "$kernel.uncompressed"
        mv "$kernel.uncompressed" "$kernel"
    fi
done
curl --fail --location --retry 3 https://codeload.github.com/zbm-dev/zfsbootmenu/tar.gz/refs/tags/v3.1.0 -o "$BUILD/zbm.tar.gz"
echo '55aa61ff7450131348dcfe45c2b7ea01bec84b559f0e8e149b3dc8dbd093eaff  '"$BUILD/zbm.tar.gz" | sha256sum -c -
mkdir "$BUILD/zbm-src"
tar -xzf "$BUILD/zbm.tar.gz" --strip-components=1 -C "$BUILD/zbm-src"
if [[ $(awk '/MemTotal/ {print $2}' /proc/meminfo) -lt 750000 ]]; then
    # kexec_file_load duplicates the decompressed ARM kernel in memory and can
    # OOM at 512 MiB. The supported kexec_load syscall avoids that extra copy.
    sed -i 's/kexec -a -l/kexec -c -l/' "$BUILD/zbm-src/zfsbootmenu/lib/zfsbootmenu-core.sh"
fi
chroot "$BUILD" make -C /zbm-src core dracut
cat > "$BUILD/etc/zfsbootmenu/config.yaml" <<'EOF'
Global:
  ManageImages: true
  DracutConfDir: /etc/zfsbootmenu/dracut.conf.d
Components:
  Enabled: false
EFI:
  Enabled: true
  ImageDir: /output
  Versions: false
Kernel:
  Prefix: zfsbootmenu
EOF
cat > "$BUILD/etc/zfsbootmenu/dracut.conf.d/zfsify.conf" <<'EOF'
hostonly="no"
hostonly_cmdline="no"
compress="gzip"
zfsbootmenu_release_build="1"
EOF
KCL="$(cat "$WORK/boot/cmdline-rescue") zbm.timeout=15 zbm.prefer=rpool zbm.sort_key=creation zfs.zfs_arc_min=16777216 zfs.zfs_arc_max=67108864"
chroot "$BUILD" generate-zbm --no-initcpio --cmdline "$KCL"
test -s "$BUILD/output/zfsbootmenu.EFI"
cp "$BUILD/output/zfsbootmenu.EFI" "$WORK/zfsbootmenu.EFI"
cleanup
trap - EXIT
rm -rf "$BUILD"

ZFS_ON_BOOT_4c76357c973dd0cf134c763bf14137a2d5fafead0fd40a9e34313a98f32866a3
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
cat > "$work/volume.sh" <<'ZFS_ON_BOOT_5eaf49c4beff6959a8b4e183b8d51d5e663cd38065f1f93498f5cfdd31a0ffd9'
#!/bin/bash
# Non-root ext4 conversion. The running OS stays on its own disk.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C DEBIAN_FRONTEND=noninteractive
SOURCE=${1:?} TARGET=${2:?} MODE=${3:-auto} BACKUP=${4:-ask}
[[ ! -t 1 ]] || export ZFS_PROGRESS_TTY=1
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
POOL=${ORIGINAL_UUID,,}; POOL=zfsify_${POOL//-/}; POOL=${POOL:0:23}
! zpool list "$POOL" >/dev/null 2>&1 || die 'Pool name already exists.'
DISK_BYTES=$(blockdev --getsize64 "$DISK")
LAST=$((DISK_BYTES/512-34))
SPLIT=$(( ((LAST+1+2048)/2/2048+2)*2048 ))
[[ $SPLIT -gt $((START+262144)) ]] || die 'Disk too small for migration.'
PRESERVE_CAPACITY=$(( (SPLIT-START)*512-1048576 ))
TAIL_CAPACITY=$(( (LAST-SPLIT+1)*512 ))
(( PRESERVE_CAPACITY <= TAIL_CAPACITY )) || PRESERVE_CAPACITY=$TAIL_CAPACITY
ERASE_ONLY=()
[[ $MODE != erase ]] || ERASE_ONLY=(--erase-only)
EXPLICIT=()
[[ $MODE = auto ]] || EXPLICIT=(--explicit)
while :; do
python3 "$SOURCE/strategy.py" menu "${EXPLICIT[@]}" --kind volume --disk "$DISK" --size "$FS_BYTES" --used "$USED_BYTES" \
    --preserve-capacity "$PRESERVE_CAPACITY" --mode "$MODE" --backup "$BACKUP" "${ERASE_ONLY[@]}" > "$WORK/selection"
mapfile -t SELECTION < "$WORK/selection"
MODE=${SELECTION[0]}; BACKUP=${SELECTION[1]}
lsblk -o NAME,PATH,SIZE,FSTYPE,MOUNTPOINTS "$DISK"
echo "$MODE data volume: $DEV on $DISK; final pool $POOL at $DEFAULT_MOUNT"
case $MODE in
preserve) echo '[ ext4 ] -> [ smaller ext4 | temporary ZFS ] -> [ ZFS mirror | temporary ZFS ] -> [ full ZFS ]';;
backup) echo '[ ext4 ] -> [ verified archive on separate Volume / remote ] -> [ full ZFS ] -> [ restored data ]';;
erase) echo '[ ext4: all data discarded ] -> [ empty full-disk ZFS ]';;
esac
[[ $MODE != erase ]] || echo 'ERASE: no files from this data volume will be retained.'
echo "Work logs: $WORK; stop applications using $MOUNT before proceeding."
REVIEW=$(python3 "$SOURCE/strategy.py" confirm "${EXPLICIT[@]}" --mode "$MODE" --label "Selected: $MODE on $DISK. Stop applications using $MOUNT before proceeding.")
[[ $REVIEW != 1 ]] || break
done
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
    python3 "$SOURCE/progress.py" run --phase 5 --label "Copy $DEV to $LOOP" --devices "$DISK,$DEV,$LOOP" --source "$DEV" --target "$LOOP" --total "$TOTAL" -- rsync -aHAXS --numeric-ids --info=progress2,name0 --outbuf=L "$WORK/old/" "$WORK/new/"
    phase 6 'Verify every copied file and its metadata' bash -o pipefail -c 'rsync -aHAXSnic --numeric-ids --delete "$1/" "$2/" > "$3"; cat "$3"; test ! -s "$3"' _ "$WORK/old" "$WORK/new" "$WORK/differences"
    umount "$WORK/old"
    # The verified tail ends before the backup GPT; writing the new GPT cannot touch it.
    phase 8 "Create the final GPT on $DISK" sgdisk --clear -n "1:2048:$((SPLIT-1))" -t 1:BF01 "$DISK"
    partprobe "$DISK"
    udevadm settle
    FRONT=$(part 1)
    [[ -b $FRONT && $(blockdev --getsize64 "$FRONT") -ge $(blockdev --getsize64 "$LOOP") ]]
    python3 "$SOURCE/progress.py" run --phase 8 --label "Relocate verified data via mirror" \
        --devices "$DISK,$LOOP,$FRONT" --source "$LOOP" --target "$FRONT" --resilver --pool "$POOL" \
        -- zpool attach -f -w "$POOL" "$LOOP" "$FRONT"
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

ZFS_ON_BOOT_5eaf49c4beff6959a8b4e183b8d51d5e663cd38065f1f93498f5cfdd31a0ffd9
cat > "$work/backup.sh" <<'ZFS_ON_BOOT_e2bfc8707b78361fcdf3849cf43bc8fc2f04d09e6c01b597150899d2b353543a'
#!/bin/bash
# Whole-filesystem archive transport. rclone owns all remote configuration.
set -Eeuo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
ACTION=${1:?}
if [[ $ACTION = configure ]]; then
    DEST=${2:?} OUT=${3:?} SOURCE_DISK=${4:?}
    USED_BYTES=${5:-0}
    CONFIRM_REQUIRED=0
    [[ $DEST != ask ]] || CONFIRM_REQUIRED=1
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
            echo 'Backup selection and confirmation require an interactive SSH terminal.' >&2
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
            choice=$(python3 "$(dirname "$0")/strategy.py" transport) || exit 1
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
                        DEST=$(python3 "$(dirname "$0")/strategy.py" destination --disk "$SOURCE_DISK" --used "$USED_BYTES") || exit 1
                        [[ $DEST != q ]] || break
                        [[ -n $DEST ]] || continue
                        if [[ $DEST = path ]]; then
                            printf 'Enter absolute mounted directory (q = back): ' >&3
                            IFS= read -r DEST <&3 || exit 1
                        fi
                        [[ $DEST != q && $DEST != Q ]] || break
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
    # Interactive choices need consent before any destination writes.
    # An explicit --backup= destination already supplies that authorization.
    if (( CONFIRM_REQUIRED )); then
        if ! { exec 3<>/dev/tty; } 2>/dev/null; then
            echo 'Backup requires manual destination confirmation in an interactive SSH terminal.' >&2
            exit 1
        fi
        printf '\nSource to convert: %s\nBackup destination: %s\n' "$SOURCE_DISK" "$DEST" >&3
        if [[ $DEST = /* ]]; then
            printf 'Destination device: %s on disk %s\n' "$BACKUP_DEV" "${BACKUP_DISKS[0]}" >&3
            lsblk -o NAME,PATH,SIZE,FSTYPE,MOUNTPOINTS "${BACKUP_DISKS[0]}" >&3
            df -h "$DEST" >&3
        fi
        printf 'A new private backup folder will be written here; existing data is retained.\nConfirm this is the destination you intend to use: type y and press Enter (no timeout): ' >&3
        IFS= read -r CONFIRM_DEST <&3 || exit 1
        [[ $CONFIRM_DEST = y ]] || { echo 'Backup cancelled before writing to destination.' >&3; exit 1; }
        exec 3>&-
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

ZFS_ON_BOOT_e2bfc8707b78361fcdf3849cf43bc8fc2f04d09e6c01b597150899d2b353543a
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
cat > "$work/inplace.sh" <<'ZFS_ON_BOOT_68f27b4745026c11870c8494bc84365cb5a852bf8260c79eab890f96f7d79a1d'
#!/bin/bash
# Sourced by the RAM installer. Persistent state lives outside the source.
. /etc/zfs-on-boot/plan.env
MOVER=/etc/zfs-on-boot/inplace-move.py
mkdir -p /scratch
STATE=/scratch/zfsify-inplace-state
MANIFEST=$STATE/manifest.sqlite
IMAGE=/old/.zfsify.img
inplace_checkpoint() {
    printf '%s\n' "$1" > "$STATE/phase.new"
    sync -f "$STATE/phase.new"
    mv "$STATE/phase.new" "$STATE/phase"
    sync -f "$STATE"
    INPLACE_PHASE=$1
}
inplace_mount_source() {
    mount "$ROOTDEV" /old
    if [[ -f /etc/zfs-on-boot/old-boot-uuid ]]; then
        OLD_BOOT=$(blkid -U "$(cat /etc/zfs-on-boot/old-boot-uuid)")
        mount "$OLD_BOOT" /old/boot
    fi
}
inplace_unmount_source() {
    ! mountpoint -q /old/boot || umount /old/boot
    ! mountpoint -q /old || umount /old
}
inplace_map_image() {
    LOOP=$(losetup -f --show "$IMAGE")
    # This offset reserves the final boot area inside the sparse image.
    dmsetup create zfsify-image --table "0 $((IMAGE_BYTES/512-IMAGE_OFFSET)) linear $LOOP $IMAGE_OFFSET"
    ZPART=/dev/mapper/zfsify-image
}
inplace_unmap_image() {
    zpool export rpool
    dmsetup remove zfsify-image
    losetup -d "$LOOP"
    inplace_unmount_source
    DEVICES=$DISK,$ROOTDEV,$SCRATCH
}

SCRATCH=$(part 32)
if [[ -z $SCRATCH ]]; then
    # Shrink only enough for the journal/rescue, never to half the disk.
    SCRATCH_START=$(( (ROOT_END+1)/2048*2048-2097152 ))
    COPY_END=$((SCRATCH_START-1))
    IMAGE_OFFSET=0
    (( ROOT_START >= 1050624 )) || IMAGE_OFFSET=$((1050624-ROOT_START))
    IMAGE_BYTES=$(( (COPY_END-ROOT_START+1)/8*4096 ))
    ZFS_START=$((ROOT_START+IMAGE_OFFSET))
    ZFS_END=$((ROOT_START+IMAGE_BYTES/512-1))
    phase 4 "Check ext4 before reserving 1 GiB on $DISK" bash -c 'e2fsck -fp "$1"; rc=$?; [ "$rc" -le 1 ]' _ "$ROOTDEV"
    phase 4 'Reserve space for the persistent rescue and journal' resize2fs "$ROOTDEV" "$(( (COPY_END-ROOT_START+1)/2-1024 ))K"
    sgdisk -d "$ROOT_PART" -n "$ROOT_PART:$ROOT_START:$COPY_END" -t "$ROOT_PART:8300" -u "$ROOT_PART:$ROOT_GUID" -n "32:$SCRATCH_START:$ROOT_END" -t 32:8300 "$DISK"
    partprobe "$DISK"
    udevadm settle
    SCRATCH=$(part 32)
    mkfs.ext4 -q -F -m 0 -L ZFSIFY_RESCUE "$SCRATCH"
    mount "$SCRATCH" /scratch
    mkdir -m 700 "$STATE"
    printf 'ROOT_START=%s\nROOT_END=%s\nCOPY_END=%s\nIMAGE_OFFSET=%s\nIMAGE_BYTES=%s\nZFS_START=%s\nZFS_END=%s\n' \
        "$ROOT_START" "$ROOT_END" "$COPY_END" "$IMAGE_OFFSET" "$IMAGE_BYTES" "$ZFS_START" "$ZFS_END" > "$STATE/geometry"
    sgdisk --backup="$STATE/table.gpt" "$DISK"
    inplace_mount_source
    mkdir -p /scratch/var/lib/zfs-on-boot /scratch/boot/zfs-on-boot
    cp /rescue-media/rescue.squashfs /scratch/var/lib/zfs-on-boot/
    cp /old/boot/zfs-on-boot/{installer.img,vmlinuz} /scratch/boot/zfs-on-boot/
    cp /old/var/lib/zfs-on-boot/stage.log "$STATE/stage.log"
    SCRATCH_UUID=$(blkid -s UUID -o value "$SCRATCH")
    mkdir -p /scratch/boot/grub
    cat > /scratch/boot/grub/grub.cfg <<EOF
set timeout=3
set default=0
menuentry 'Resume ZFS conversion' {
    search --no-floppy --fs-uuid --set=root $SCRATCH_UUID
    linux /boot/zfs-on-boot/vmlinuz $(cat /etc/zfs-on-boot/boot/cmdline-grub) rdinit=/init panic=0 zfsify.rescue=$SCRATCH_UUID
    initrd /boot/zfs-on-boot/installer.img
}
EOF
    inplace_checkpoint prepare
    if [[ $(cat /etc/zfs-on-boot/firmware) = bios ]]; then
        grub-install --target=i386-pc --boot-directory=/scratch/boot "$DISK"
    else
        # Use the existing ESP until the verified native root is ready.
        ESP=$(lsblk -nrpo NAME,PARTTYPE "$DISK" | awk 'tolower($2)=="c12a7328-f81f-11d2-ba4b-00a0c93ec93b" {print $1; exit}')
        mkdir -p /scratch/efi
        mount "$ESP" /scratch/efi
        EFI_ARCH=x86_64; [[ $(uname -m) != aarch64 ]] || EFI_ARCH=arm64
        grub-install --target="$EFI_ARCH-efi" --efi-directory=/scratch/efi --boot-directory=/scratch/boot --bootloader-id=zfsify-rescue --no-nvram
        ESP_NUMBER=$(cat "/sys/class/block/${ESP##*/}/partition")
        EFI_NAME=grubx64.efi; [[ $EFI_ARCH != arm64 ]] || EFI_NAME=grubaa64.efi
        efibootmgr --create --disk "$DISK" --part "$ESP_NUMBER" --label zfsify-rescue --loader "\\EFI\\zfsify-rescue\\$EFI_NAME"
        umount /scratch/efi
    fi
    sync
    inplace_unmount_source
else
    mount "$SCRATCH" /scratch
    [[ $(blkid -s LABEL -o value "$SCRATCH") = ZFSIFY_RESCUE && -s $STATE/geometry && -s $STATE/phase ]]
    . "$STATE/geometry"
    INPLACE_PHASE=$(cat "$STATE/phase")
    echo "Resuming in-place migration: $INPLACE_PHASE on $DISK"
fi
DEVICES=$DISK,$ROOTDEV,$SCRATCH
mkdir -p /var/log/zfs-on-boot
cp "$STATE/stage.log" /var/log/zfs-on-boot/stage.log

if [[ $INPLACE_PHASE = prepare ]]; then
    inplace_mount_source
    rm -rf /old/var/lib/zfs-on-boot /old/boot/zfs-on-boot
    rm -f "$IMAGE" "$MANIFEST" "$MANIFEST-journal"
    phase 4 'Record original file hashes and metadata in the journal' python3 "$MOVER" capture "$MANIFEST" /old
    truncate -s "$IMAGE_BYTES" "$IMAGE"
    inplace_map_image
    create_root_pool off
    zpool sync rpool
    # Persist the image's directory entry as well as its pool labels before
    # any original file extents can be released on another filesystem's journal.
    sync -f /old
    inplace_checkpoint copy
elif [[ $INPLACE_PHASE = copy ]]; then
    phase 4 'Recover the outer ext4 journal' bash -c 'e2fsck -fp "$1"; rc=$?; [ "$rc" -le 1 ]' _ "$ROOTDEV"
    inplace_mount_source
    inplace_map_image
    zpool import -f -N -R /target -d "$ZPART" rpool
    zfs mount rpool/ROOT/ubuntu
fi
if [[ $INPLACE_PHASE = copy ]]; then
    DEVICES=$DISK,$ROOTDEV,$SCRATCH,$ZPART
    phase 5 'Copy, checksum and release original data in 64 MiB batches' python3 "$MOVER" move "$MANIFEST" /old /target
    phase 6 'Verify the complete manifest against the ZFS image' python3 "$MOVER" verify "$MANIFEST" /target
    inplace_unmap_image
    inplace_checkpoint copied
fi
JOB=$STATE/fstransform/fsremap.job.1
if [[ $INPLACE_PHASE = remap && ! -d $JOB ]]; then
    # The checkpoint can reach disk before fsremap is even executed.
    inplace_checkpoint copied
fi
if [[ $INPLACE_PHASE = copied ]]; then
    phase 6 'Check outer ext4 before physical block relocation' bash -c 'e2fsck -fp "$1"; rc=$?; [ "$rc" -le 1 ]' _ "$ROOTDEV"
    mount -o ro "$ROOTDEV" /old
    inplace_checkpoint remap
    # Exact secondary size disables automatic primary mmap allocation. Keep
    # scratch on partition 32 and bound RAM use even on 512 MiB machines.
    phase 6 "Remap the image onto $ROOTDEV" fsremap --questions=no --mem-buffer=16M --exact-secondary-storage=32M --temp-dir="$STATE" -- "$ROOTDEV" "$IMAGE"
    inplace_checkpoint native
elif [[ $INPLACE_PHASE = remap ]]; then
    # Never mount ext4 or create a new job once physical relocation started.
    if [[ -f $JOB/storage.bin ]]; then
        phase 6 'Resume physical block relocation from its journal' fsremap --questions=no --mem-buffer=16M --temp-dir="$STATE" --resume-job=1 -- "$ROOTDEV"
    else
        # fsremap removes storage.bin on success, before our next checkpoint.
        # A completed relocation is also recorded as zero outstanding blocks.
        # The full native manifest is verified below before changing the GPT.
        tail -n 1 "$JOB/fsremap.persist" | grep -Eq '^0[[:space:]]+0$'
    fi
    inplace_checkpoint native
fi
if [[ $INPLACE_PHASE = native ]]; then
    dmsetup create zfsify-native --table "0 $((IMAGE_BYTES/512-IMAGE_OFFSET)) linear $ROOTDEV $IMAGE_OFFSET"
    zpool import -f -N -R /target -d /dev/mapper/zfsify-native rpool
    zfs mount rpool/ROOT/ubuntu
    phase 6 'Verify all files after physical remapping' python3 "$MOVER" verify "$MANIFEST" /target
    zpool set autotrim=on rpool
    zpool export rpool
    dmsetup remove zfsify-native
    inplace_checkpoint partition
fi
if [[ $INPLACE_PHASE = partition ]]; then
    # Preserve partition 32 until the final loader has been installed.
    mapfile -t PARTS < <(while read -r name; do cat "/sys/class/block/$name/partition" 2>/dev/null || true; done < <(lsblk -nr -o NAME "$DISK") | awk '$1!=32')
    ARGS=(); for number in "${PARTS[@]}"; do ARGS+=(-d "$number"); done
    sgdisk "${ARGS[@]}" -n "1:2048:$((ZFS_START-1))" -t "1:$BOOT_TYPE" "${BOOT_ATTR[@]}" -n "2:$ZFS_START:$ZFS_END" -t 2:BF01 "$DISK"
    for number in "${PARTS[@]}"; do partx -d --nr "$number" "$DISK"; done
    partx -a --nr 1:2 "$DISK"
    udevadm settle
    inplace_checkpoint target
fi
[[ $INPLACE_PHASE = target || $INPLACE_PHASE = configured ]]
ZPART=$(part 2)
zpool import -f -N -R /target -d "$ZPART" rpool
zfs mount rpool/ROOT/ubuntu
mkdir -p -m 700 /target/var/log/zfs-on-boot/inplace
DEVICES=$DISK,$ZPART,$SCRATCH

ZFS_ON_BOOT_68f27b4745026c11870c8494bc84365cb5a852bf8260c79eab890f96f7d79a1d
cat > "$work/inplace-move.py" <<'ZFS_ON_BOOT_e48c067a76dd746fc2782b206265a3db15b24d6c8f6a4f2906cba152ccb2aca8'
#!/usr/bin/python3
"""Experimental offline mover: verify and journal each batch before freeing ext4.

The SQLite manifest must live outside the filesystem being converted. fsremap
handles the later physical block relocation; this module handles file semantics.
"""
import argparse
import base64
import ctypes
import hashlib
import json
import os
import sqlite3
import stat
import subprocess
import time

BUFFER = 4 * 1024**2
BATCH = 64 * 1024**2
SKIP = {b'proc', b'sys', b'dev', b'run', b'tmp', b'old', b'target',
        b'rescue-media', b'var/lib/zfs-on-boot', b'boot/zfs-on-boot',
        b'boot/zfsify-inplace-state', b'boot/efi', b'.zfsify.img',
        b'swapfile', b'swap.img'}


def encode(value):
    return base64.b64encode(value).decode('ascii')


def decode(value):
    return base64.b64decode(value)


def digest(path):
    result = hashlib.sha256()
    with open(path, 'rb', buffering=0) as stream:
        while data := stream.read(BUFFER):
            result.update(data)
    return result.hexdigest()


def metadata(path):
    s = os.lstat(path)
    result = {key: getattr(s, 'st_' + key) for key in
              ('mode', 'uid', 'gid', 'size', 'atime_ns', 'mtime_ns', 'dev', 'ino', 'nlink', 'rdev')}
    result['attrs'] = {encode(os.fsencode(key)): encode(os.getxattr(path, key, follow_symlinks=False))
                       for key in os.listxattr(path, follow_symlinks=False)}
    if stat.S_ISLNK(s.st_mode):
        result['link'] = encode(os.readlink(path))
    return result


def capture(db, source):
    db.execute('CREATE TABLE entries(path BLOB PRIMARY KEY, meta TEXT, digest TEXT, offset INTEGER DEFAULT 0, done INTEGER DEFAULT 0)')
    links = {}

    def visit(relative):
        path = os.path.join(source, relative)
        meta = metadata(path)
        checksum = None
        if not stat.S_ISDIR(meta['mode']) and meta['nlink'] > 1:
            identity = (meta['dev'], meta['ino'])
            if identity in links:
                meta['hardlink'] = encode(links[identity])
            else:
                links[identity] = relative
        if stat.S_ISREG(meta['mode']) and 'hardlink' not in meta:
            checksum = digest(path)
        db.execute('INSERT INTO entries(path,meta,digest) VALUES(?,?,?)',
                   (relative, json.dumps(meta), checksum))
        if stat.S_ISDIR(meta['mode']):
            with os.scandir(path) as children:
                for child in children:
                    rel = os.path.join(relative, child.name)
                    if rel not in SKIP:
                        visit(rel)

    visit(b'')
    db.commit()
    print(f"Manifest saved: {db.execute('SELECT count(*) FROM entries').fetchone()[0]} entries", flush=True)


def apply_metadata(path, meta):
    os.chown(path, meta['uid'], meta['gid'], follow_symlinks=False)
    if not stat.S_ISLNK(meta['mode']):
        os.chmod(path, stat.S_IMODE(meta['mode']))
    for key, value in meta['attrs'].items():
        os.setxattr(path, decode(key), decode(value), follow_symlinks=False)
    os.utime(path, ns=(meta['atime_ns'], meta['mtime_ns']), follow_symlinks=False)


def move(db, source, target, pool):
    root_device = os.stat(source).st_dev
    libc = ctypes.CDLL(None, use_errno=True)
    libc.fallocate.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_longlong, ctypes.c_longlong]

    def release(fd, offset, length):
        if length and libc.fallocate(fd, 3, offset, length):  # KEEP_SIZE | PUNCH_HOLE
            raise OSError(ctypes.get_errno(), 'Cannot release verified source extent')
        os.fsync(fd)

    total = sum(json.loads(meta)['size'] for (meta,) in db.execute(
        'SELECT meta FROM entries WHERE digest IS NOT NULL'))
    moved = sum(offset for (offset,) in db.execute('SELECT offset FROM entries'))
    total_files = files_done = 0
    for encoded, done in db.execute('SELECT meta,done FROM entries'):
        if not stat.S_ISDIR(json.loads(encoded)['mode']):
            total_files += 1
            files_done += done
    print(f'ZFSIFY_START {moved} {total}', flush=True)
    print(f'ZFSIFY_FILES {files_done} {total_files}', flush=True)
    started, initial, last_report = time.monotonic(), moved, 0
    for relative, encoded, checksum, offset, done in db.execute('SELECT * FROM entries ORDER BY rowid'):
        meta = json.loads(encoded)
        src, dst = os.path.join(source, relative), os.path.join(target, relative)
        mode = meta['mode']
        if stat.S_ISDIR(mode):
            os.makedirs(dst, mode=0o700, exist_ok=True)
            continue
        if done and os.path.lexists(dst):
            apply_metadata(dst, meta)
            continue
        if 'hardlink' in meta:
            canonical = os.path.join(target, decode(meta['hardlink']))
            if not os.path.lexists(dst):
                os.link(canonical, dst, follow_symlinks=False)
        elif stat.S_ISREG(mode):
            reclaim = meta['dev'] == root_device
            infd = os.open(src, os.O_RDWR if reclaim else os.O_RDONLY)
            outfd = os.open(dst, os.O_CREAT | os.O_RDWR, 0o600)
            try:
                os.ftruncate(outfd, meta['size'])
                # A committed checkpoint may precede a crash before hole punching.
                if reclaim and offset:
                    release(infd, 0, offset)
                while offset < meta['size']:
                    # ZFS COW metadata can leave obsolete blocks allocated in
                    # the enclosing ext4 image. Reclaim them before headroom
                    # runs out; the temporary loop/DM stack forwards discard.
                    space = os.statvfs(source)
                    if space.f_bavail * space.f_frsize < 1024**3:
                        print('Reclaiming unused ZFS image blocks on ext4...', flush=True)
                        subprocess.run(['zpool', 'trim', '-w', pool], check=True)
                    # Stop before an ENOSPC write can suspend the file-backed
                    # pool. Both filesystems need room for a batch and metadata.
                    for filesystem in (source, target):
                        free = os.statvfs(filesystem)
                        if free.f_bavail * free.f_frsize < 2 * BATCH:
                            raise RuntimeError('Insufficient working space; migration paused before the next batch')
                    end = min(offset + BATCH, meta['size'])
                    position = offset
                    expected = hashlib.sha256()
                    while position < end:
                        data = os.pread(infd, min(BUFFER, end - position), position)
                        if not data:
                            raise RuntimeError(f'Short source read: {src!r}')
                        expected.update(data)
                        if data.strip(b'\0'):
                            written = os.pwrite(outfd, data, position)
                            if written != len(data):
                                raise RuntimeError(f'Short target write: {dst!r}')
                        position += len(data)
                    os.fsync(outfd)
                    actual = hashlib.sha256()
                    position = offset
                    while position < end:
                        data = os.pread(outfd, min(BUFFER, end - position), position)
                        if not data:
                            raise RuntimeError(f'Short verification read: {dst!r}')
                        actual.update(data)
                        position += len(data)
                    if expected.digest() != actual.digest():
                        raise RuntimeError(f'Batch checksum mismatch: {dst!r}')
                    subprocess.run(['zpool', 'sync', pool], check=True)
                    db.execute('UPDATE entries SET offset=? WHERE path=?', (end, relative))
                    db.commit()
                    if reclaim:
                        release(infd, offset, end - offset)
                    moved += end - offset
                    offset = end
                    now = time.monotonic()
                    if now - last_report >= 2:
                        speed = (moved - initial) / max(now - started, 0.001) / 1e6
                        print(f'ZFSIFY_PROGRESS {moved} {total}', flush=True)
                        print(f'ZFSIFY_FILES {files_done} {total_files}', flush=True)
                        print(f'{moved/1e6:,.1f}/{total/1e6:,.1f} MB | {speed:.1f} MB/s | {os.fsdecode(relative)!r}', flush=True)
                        last_report = now
            finally:
                os.close(outfd)
                os.close(infd)
            if digest(dst) != checksum:
                raise RuntimeError(f'Whole-file checksum mismatch: {dst!r}')
        elif stat.S_ISLNK(mode):
            if not os.path.lexists(dst):
                os.symlink(decode(meta['link']), dst)
        elif not os.path.lexists(dst):
            os.mknod(dst, mode, meta['rdev'])
        apply_metadata(dst, meta)
        db.execute('UPDATE entries SET done=1 WHERE path=?', (relative,))
        db.commit()
        files_done += not done
    for relative, encoded in db.execute('SELECT path,meta FROM entries ORDER BY rowid DESC'):
        meta = json.loads(encoded)
        if stat.S_ISDIR(meta['mode']):
            apply_metadata(os.path.join(target, relative), meta)
    subprocess.run(['zpool', 'sync', pool], check=True)
    subprocess.run(['zpool', 'trim', '-w', pool], check=True)
    print(f'ZFSIFY_PROGRESS {moved} {total}', flush=True)
    print(f'ZFSIFY_FILES {files_done} {total_files}', flush=True)


def verify(db, target):
    count = 0
    for relative, encoded, checksum in db.execute('SELECT path,meta,digest FROM entries'):
        meta = json.loads(encoded)
        path = os.path.join(target, relative)
        actual = metadata(path)
        for key in ('mode', 'uid', 'gid', 'mtime_ns', 'attrs'):
            if actual[key] != meta[key]:
                raise RuntimeError(f'Metadata mismatch ({key}): {path!r}')
        if checksum and digest(path) != checksum:
            raise RuntimeError(f'Checksum mismatch: {path!r}')
        if 'link' in meta and actual['link'] != meta['link']:
            raise RuntimeError(f'Symlink mismatch: {path!r}')
        if 'hardlink' in meta and actual['ino'] != os.lstat(os.path.join(target, decode(meta['hardlink']))).st_ino:
            raise RuntimeError(f'Hard-link mismatch: {path!r}')
        count += 1
    print(f'VERIFIED: {count} entries; SHA256, modes, owners, timestamps, ACLs, xattrs and hard links.', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['capture', 'move', 'verify'])
    parser.add_argument('manifest')
    parser.add_argument('source')
    parser.add_argument('target', nargs='?')
    parser.add_argument('--pool', default='rpool')
    args = parser.parse_args()
    db = sqlite3.connect(args.manifest)
    db.execute('PRAGMA synchronous=FULL')
    if args.action == 'capture':
        capture(db, os.fsencode(args.source))
    elif args.action == 'move':
        move(db, os.fsencode(args.source), os.fsencode(args.target), args.pool)
    else:
        verify(db, os.fsencode(args.source))

ZFS_ON_BOOT_e48c067a76dd746fc2782b206265a3db15b24d6c8f6a4f2906cba152ccb2aca8
bash "$work/stage.sh" "$work" "$@" </dev/null
