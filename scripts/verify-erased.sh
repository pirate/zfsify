#!/bin/bash
# Execute only on the DigitalOcean erase fixture.
set -Eeuo pipefail
[[ $(findmnt -n -o FSTYPE /) = zfs ]]
grep -q '(erase)' /etc/zfs-on-boot-installed
sha256sum -c /etc/zfsify-keys.before
cmp /etc/passwd /etc/zfsify-passwd.before
cmp /etc/shadow /etc/zfsify-shadow.before
[[ ! -e /home/erasetest/delete-me && ! -e /root/space-gate ]]
grep -qx 'keep configuration' /etc/zfsify-erase-test.conf
[[ $(stat -c %U /home/erasetest/.ssh/authorized_keys) = erasetest ]]
[[ $(stat -c %a /home/erasetest/.ssh/authorized_keys) = 600 ]]
[[ $(zpool get -H -o value autoexpand rpool) = on ]]
[[ $(zpool list -Hp -o size rpool) -gt 80000000000 ]]
command -v awk
[[ -e /etc/alternatives/awk ]]
systemctl is-active ssh systemd-resolved systemd-networkd
[[ -z $(systemctl --failed --plain --no-legend) ]]
printf 'ERASE VERIFIED: fresh ZFS root, retained accounts/configuration/SSH access, original data removed.\n'
