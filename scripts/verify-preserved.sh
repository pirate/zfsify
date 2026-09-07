#!/bin/bash
# Run only on the DigitalOcean migration fixture.
set -Eeuo pipefail
sha256sum -c /root/migration-fixture.SHA256SUMS
sha256sum -c /root/hostkeys.before
cmp /root/passwd.before /etc/passwd
cmp /root/shadow.before /etc/shadow
[[ $(stat -c %i /root/migration-fixture/random.bin) = "$(stat -c %i /root/migration-fixture/hardlink.bin)" ]]
[[ $(getfattr --only-values -n user.zfsify /root/migration-fixture/random.bin 2>/dev/null) = retained ]]
getfacl -cp /root/migration-fixture/random.bin | grep -q '^user:migrationtest:r--$'
[[ $(stat -c %b /root/migration-fixture/sparse.bin) -lt 10000 ]]
[[ $(stat -c %U /home/migrationtest/.ssh/authorized_keys) = migrationtest ]]
grep -qx 'retained config' /etc/zfsify-test.conf
[[ $(zpool get -H -o value autoexpand rpool) = on ]]
[[ $(zpool status -P rpool | awk '$1 ~ /^\/dev\// {n++} END {print n}') = 1 ]]
[[ $(lsblk -nr -o FSTYPE /dev/vda | awk 'NF && $1!="zfs_member" {n++} END {print n+0}') = 0 ]]
[[ $(zpool list -Hp -o size rpool) -gt 80000000000 ]]
systemctl is-enabled zfs-on-boot-grow.service
systemctl show zfs-on-boot-grow -p Result
printf 'PRESERVATION VERIFIED: bytes, users, shadow, host keys, ACLs, xattrs, hard links, sparse files, configuration, full-disk ZFS.\n'
