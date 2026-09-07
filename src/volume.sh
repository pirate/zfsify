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
    echo 'WARNING: at least 50% is used. Data preservation is not eligible.'
    echo 'Choose A for rclone backup/restore, or y to erase this DATA VOLUME and discard all its files.'
    answer=
    if { exec 3<>/dev/tty; } 2>/dev/null; then read -r -p 'Type A for backup, or y and Enter to erase: ' answer <&3; exec 3>&-; fi
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
backup) echo '[ ext4 ] -> [ verified rclone archive elsewhere ] -> [ full ZFS ] -> [ restored data ]';;
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
    bash "$SOURCE/backup.sh" configure "$BACKUP" "$WORK/backup" "$DISK"
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
