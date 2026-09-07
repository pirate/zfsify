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
