#!/bin/bash
# Execute on the test Droplet. Does not reboot or change packages.
set -Eeuo pipefail
[[ -f /etc/zfs-on-boot-installed ]]
[[ $(findmnt -n -o FSTYPE /) = zfs ]]
[[ $(findmnt -n -o SOURCE /) = rpool/ROOT/ubuntu ]]
[[ $(findmnt -n -o FSTYPE --target /boot) = zfs ]]
[[ $(findmnt -n -o SOURCE --target /boot) = rpool/ROOT/ubuntu ]]
[[ $(zpool get -H -o value compatibility rpool) = grub2 ]]
[[ $(zpool get -H -o value bootfs rpool) = rpool/ROOT/ubuntu ]]
[[ $(zpool list -H -o health rpool) = ONLINE ]]
systemctl is-active ssh systemd-networkd systemd-resolved
cloud-init status --wait
getent ahostsv4 archive.ubuntu.com >/dev/null
curl --fail --silent --show-error --max-time 15 http://169.254.169.254/metadata/v1/id
printf '\n'
modinfo -F version zfs
findmnt --target /
findmnt --target /boot
zpool status
zfs list
uname -r
systemctl --failed --no-pager
[[ -z $(systemctl --failed --plain --no-legend) ]]
[[ $(grub-probe /boot) = zfs ]]
printf 'ZFS root verification passed.\n'
