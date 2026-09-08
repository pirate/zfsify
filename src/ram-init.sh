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
MIGRATION_STARTED=0
rescue() {
    trap - ERR
    echo "INSTALLATION FAILED at line $1. Use the provider console; SSH requires working networking."
    echo 'Run zfs-on-boot-status; logs: /run/zfs-on-boot.log and /var/log/zfs-on-boot/progress.log.'
    if [[ $MIGRATION_STARTED = 0 ]]; then
        echo 'Disk migration has not started. Rebooting returns to the original Ubuntu boot entry.'
    else
        echo 'Do not reboot after source removal. Inspect the migration logs before taking action.'
    fi
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
MIGRATION_STARTED=1
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
