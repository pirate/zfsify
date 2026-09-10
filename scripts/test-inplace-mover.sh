#!/bin/bash
# Destructive integration test. Run INSIDE a disposable Ubuntu VM only.
# Needs: zfsutils-linux fstransform dmsetup e2fsprogs acl attr libcap2-bin python3.
# ZFSIFY_DISPOSABLE_TEST=1 bash scripts/test-inplace-mover.sh /dev/UNUSED_8_GIB_DISK
set -Eeuo pipefail
[[ ${ZFSIFY_DISPOSABLE_TEST:-} = 1 ]] || { echo 'Disposable VM opt-in required.' >&2; exit 2; }
D=$(readlink -f "${1:?an unused 8 GiB test disk is required}")
[[ $(lsblk -dn -o TYPE "$D") = disk && $(blockdev --getsize64 "$D") = 8589934592 ]]
[[ -z $(lsblk -nr -o MOUNTPOINTS "$D" | tr -d '[:space:]') ]]
! zpool list -H -o name | grep -qx zfsify_test
MOVER=$(cd "$(dirname "$0")/../src" && pwd)/inplace-move.py
STATE=$(mktemp -d /root/zfsify-inplace-test.XXXXXXXX)
OLD=$STATE/old
NEW=$STATE/new
mkdir "$OLD" "$NEW"
mkfs.ext4 -F -m 0 "$D"
mount "$D" "$OLD"
dd if=/dev/urandom of="$OLD/large.bin" bs=1M count=6000 status=progress
ln "$OLD/large.bin" "$OLD/hardlink.bin"
truncate -s 1G "$OLD/sparse.bin"
printf tail | dd of="$OLD/sparse.bin" bs=1 seek=1073741820 conv=notrunc status=none
ln -s large.bin "$OLD/symlink"
setfattr -n user.test -v preserved "$OLD/large.bin"
setfacl -m u:1000:r "$OLD/large.bin"
cp /bin/true "$OLD/capability"
setcap cap_net_bind_service=ep "$OLD/capability"
printf unicode > "$OLD/é"
printf distinct > "$OLD/"$'e\u0301'
df -B1 "$OLD"
python3 "$MOVER" capture "$STATE/manifest.sqlite" "$OLD"
truncate -s "$(blockdev --getsize64 "$D")" "$OLD/.zfsify.img"
LOOP=$(losetup -f --show "$OLD/.zfsify.img")
dmsetup create zfsify-test-image --table "0 $(blockdev --getsz "$D") linear $LOOP 0"
zpool create -f -o ashift=12 -o compatibility=openzfs-2.1-linux -o cachefile=none -o autotrim=off -O compression=lz4 -O xattr=sa -O acltype=posixacl -O mountpoint="$NEW" zfsify_test /dev/mapper/zfsify-test-image
# Kill only the mover after it has released part of the file, then resume its
# journal. This tests process interruption, NOT whole-machine power-loss recovery.
python3 - "$MOVER" "$STATE" <<'PY'
import os, sqlite3, subprocess, sys, time
mover, state = sys.argv[1:]
cmd = ['python3', mover, 'move', state+'/manifest.sqlite', state+'/old', state+'/new', '--pool', 'zfsify_test']
child = subprocess.Popen(cmd)
db = sqlite3.connect(state+'/manifest.sqlite')
deadline = time.monotonic() + 120
while child.poll() is None and time.monotonic() < deadline:
    offset = db.execute('SELECT offset FROM entries WHERE path=?', (b'large.bin',)).fetchone()[0]
    if offset >= 256*1024**2:
        child.kill()
        child.wait()
        source = os.stat(state+'/old/large.bin')
        assert source.st_blocks * 512 < source.st_size, 'Source extents were not released'
        print(f'INTERRUPTED: committed {offset} bytes of large.bin; resuming the same manifest.', flush=True)
        break
    time.sleep(.05)
else:
    child.kill() if child.poll() is None else None
    child.wait()
    raise RuntimeError('Did not interrupt a partially completed copy')
subprocess.run(cmd, check=True)
PY
python3 "$MOVER" verify "$STATE/manifest.sqlite" "$NEW"
zpool export zfsify_test
dmsetup remove zfsify-test-image
losetup -d "$LOOP"
umount "$OLD"
set +e
e2fsck -fp "$D"; rc=$?
set -e
(( rc <= 1 ))
mount -o ro "$D" "$OLD"
fsremap --questions=no --mem-buffer=16M --exact-secondary-storage=32M --temp-dir="$STATE" -- "$D" "$OLD/.zfsify.img"
zpool import -d "$D" zfsify_test
python3 "$MOVER" verify "$STATE/manifest.sqlite" "$NEW"
[[ $(stat -c %b "$NEW/sparse.bin") -lt 10000 ]]
zpool scrub -w zfsify_test
zpool status -P zfsify_test
zpool status zfsify_test | grep -q 'errors: No known data errors'
lsblk -f "$D"
zpool export zfsify_test
printf 'PASS: >50%% usage, file larger than free space, interrupted mover resumed, native remap, metadata, hashes and scrub.\nLogs/manifest: %s\n' "$STATE"
