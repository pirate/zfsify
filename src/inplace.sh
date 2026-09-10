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
    phase 4 'Reserve space for the persistent rescue and journal' resize2fs -p "$ROOTDEV" "$(( (COPY_END-ROOT_START+1)/2-1024 ))K"
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
