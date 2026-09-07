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
