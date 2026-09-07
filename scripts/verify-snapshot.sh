#!/bin/bash
# Run only on the owned test Droplet after the main verification passes.
set -Eeuo pipefail
dataset=rpool/ROOT/ubuntu
name=zfs-on-boot-test-$(date +%s)
mountdir=/mnt/$name
cleanup() {
    zfs destroy "rpool/$name" 2>/dev/null || true
    zfs destroy "$dataset@$name" 2>/dev/null || true
    rm -f "/root/$name"
    rmdir "$mountdir" 2>/dev/null || true
}
trap cleanup EXIT
zfs snapshot "$dataset@$name"
printf 'written after the snapshot\n' > "/root/$name"
zfs clone -o mountpoint="$mountdir" "$dataset@$name" "rpool/$name"
test ! -e "$mountdir/root/$name"
test -f "$mountdir/boot/vmlinuz-$(uname -r)"
test -f "$mountdir/boot/initrd.img-$(uname -r)"
test -d "$mountdir/lib/modules/$(uname -r)"
test -f "$mountdir/etc/zfs-on-boot-installed"
echo 'Root snapshot and clone include boot files and matching kernel modules.'
