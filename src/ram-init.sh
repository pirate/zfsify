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
