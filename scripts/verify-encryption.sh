#!/bin/bash
# Run as root in a disposable converted guest; never prints encryption keys.
set -Eeuo pipefail
[[ $(findmnt -n -o FSTYPE /) = zfs ]]
[[ $(zfs get -H -o value encryption rpool) = aes-256-gcm ]]
[[ $(zfs get -H -o value encryptionroot rpool/ROOT/ubuntu) = rpool ]]
[[ $(zfs get -H -o value keyformat rpool) = passphrase ]]
[[ $(zfs get -H -o value keystatus rpool) = available ]]
[[ $(zfs get -H -o value keylocation rpool) = file:///etc/zfs/zfsify-rpool.key ]]
[[ $(zfs get -H -o value org.zfsbootmenu:keysource rpool) = rpool/ROOT/ubuntu ]]
[[ $(stat -c '%a:%u' /etc/zfs/zfsify-rpool.key) = 600:0 ]]
for image in /boot/initrd.img-*; do
    [[ $(stat -c '%a:%u' "$image") = 600:0 ]]
    if command -v lsinitramfs >/dev/null; then
        lsinitramfs "$image" | grep -E '(^|/)etc/zfs/zfsify-rpool.key$'
    else
        lsinitrd "$image" | grep 'etc/zfs/zfsify-rpool.key'
    fi
done
zfs get encryption,encryptionroot,keyformat,keystatus rpool rpool/ROOT/ubuntu
printf 'Encrypted root, inherited key, boot configuration and private initramfs verified.\n'
