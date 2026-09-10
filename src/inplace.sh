#!/bin/bash
# Sourced by the RAM installer. Experimental: no automatic power-loss recovery.
. /etc/zfs-on-boot/plan.env
BOOTDEV=$(blkid -U "$(cat /etc/zfs-on-boot/old-boot-uuid)")
mkdir -p /scratch
mount "$BOOTDEV" /scratch
STATE=/scratch/zfsify-inplace-state
mkdir -m 700 "$STATE"
MOVER=/etc/zfs-on-boot/inplace-move.py
MANIFEST=$STATE/manifest.sqlite
mount "$ROOTDEV" /old
mount --bind /scratch /old/boot
mkdir -p /var/log/zfs-on-boot
cp /old/var/lib/zfs-on-boot/stage.log /var/log/zfs-on-boot/stage.log
rm -rf /old/var/lib/zfs-on-boot /old/boot/zfs-on-boot
IMAGE=/old/.zfsify.img
[[ ! -e $IMAGE ]]
DEVICES=$DISK,$ROOTDEV,$BOOTDEV
phase 4 'Record original file hashes and metadata on the separate boot filesystem' python3 "$MOVER" capture "$MANIFEST" /old
# fsremap rounds the destination down to ext4's block size. Ubuntu cloud root
# partitions can end between 4 KiB boundaries; ZFS also uses 4 KiB sectors here.
IMAGE_BYTES=$(( $(blockdev --getsize64 "$ROOTDEV") / 4096 * 4096 ))
truncate -s "$IMAGE_BYTES" "$IMAGE"
LOOP=$(losetup -f --show "$IMAGE")
# A DM mapping prevents whole-disk GPT auto-partitioning inside the loop image.
# It exists only during migration; fsremap produces a native partition afterward.
dmsetup create zfsify-image --table "0 $((IMAGE_BYTES/512)) linear $LOOP 0"
ZPART=/dev/mapper/zfsify-image
DEVICES=$DISK,$ROOTDEV,$BOOTDEV,$ZPART
create_root_pool off
phase 5 'Copy, checksum and release original data in 64 MiB batches' python3 "$MOVER" move "$MANIFEST" /old /target
phase 6 'Verify complete original manifest against the ZFS image' python3 "$MOVER" verify "$MANIFEST" /target
zpool export rpool
dmsetup remove zfsify-image
losetup -d "$LOOP"
umount /old/boot
umount /old
phase 6 'Check outer ext4 before physical block relocation' bash -c 'e2fsck -fp "$1"; rc=$?; [ "$rc" -le 1 ]' _ "$ROOTDEV"
mount -o ro "$ROOTDEV" /old
DEVICES=$DISK,$ROOTDEV,$BOOTDEV
phase 6 "Remap ZFS image onto $ROOTDEV with fstransform's fsremap" fsremap --questions=no --mem-buffer=32M --secondary-storage=32M --temp-dir="$STATE" -- "$ROOTDEV" "$IMAGE"
zpool import -N -R /target -d "$ROOTDEV" rpool
zfs mount rpool/ROOT/ubuntu
phase 6 'Verify the native ZFS partition after remapping' python3 "$MOVER" verify "$MANIFEST" /target
# Keep the original hash/metadata manifest and remapper log private for inspection.
mkdir -p -m 700 /target/var/log/zfs-on-boot/inplace
cp -a "$STATE/." /target/var/log/zfs-on-boot/inplace/
zpool set autotrim=on rpool
zpool export rpool
umount /scratch
# Preserve root's exact starting sector. Use its existing front boot area for
# ZFSBootMenu, then number the final native root partition consistently.
mapfile -t PARTS < <(while read -r name; do cat "/sys/class/block/$name/partition" 2>/dev/null || true; done < <(lsblk -nr -o NAME "$DISK"))
ARGS=()
for number in "${PARTS[@]}"; do ARGS+=(-d "$number"); done
phase 6 'Finalize GPT around the already-verified native ZFS root' sgdisk "${ARGS[@]}" -n "1:2048:$((ROOT_START-1))" -t 1:EF00 -n "2:$ROOT_START:$ROOT_END" -t 2:BF01 "$DISK"
# Everything on this disk is unmounted, so reread the complete table. sgdisk
# may already have refreshed it; adding individual entries would race that.
partprobe "$DISK"
udevadm settle
ZPART=$(part 2)
zpool import -N -R /target -d "$ZPART" rpool
zfs mount rpool/ROOT/ubuntu
DEVICES=$DISK,$ZPART
