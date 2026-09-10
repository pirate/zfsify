#!/bin/bash
# Execute inside the disposable test VM. Does not reboot or change packages.
set -Eeuo pipefail
[[ -f /etc/zfs-on-boot-installed ]]
[[ $(findmnt -n -o FSTYPE /) = zfs ]]
[[ $(findmnt -n -o SOURCE /) = rpool/ROOT/ubuntu ]]
[[ $(findmnt -n -o FSTYPE --target /boot) = zfs ]]
[[ $(findmnt -n -o SOURCE --target /boot) = rpool/ROOT/ubuntu ]]
[[ $(zpool get -H -o value compatibility rpool) = openzfs-2.1-linux ]]
[[ $(zpool get -H -o value bootfs rpool) = rpool/ROOT/ubuntu ]]
[[ $(zpool list -H -o health rpool) = ONLINE ]]
systemctl is-active ssh systemd-networkd systemd-resolved
cloud-init status --wait
getent ahostsv4 archive.ubuntu.com >/dev/null
if [[ ${ZFSIFY_SKIP_DO_METADATA:-${ZFSIFY_NESTED_DO_GUEST:-0}} != 1 ]]; then
    curl --fail --silent --show-error --max-time 15 http://169.254.169.254/metadata/v1/id
fi
printf '\n'
modinfo -F version zfs
findmnt --target /
findmnt --target /boot
zpool status
zfs list
uname -r
systemctl --failed --no-pager
[[ -z $(systemctl --failed --plain --no-legend) ]]
if [[ -d /sys/firmware/efi ]]; then
    [[ $(findmnt -n -o FSTYPE --target /boot/efi) = vfat ]]
    [[ -s /boot/efi/EFI/ZFSBootMenu/zfsbootmenu.EFI ]]
    case $(uname -m) in x86_64) fallback=BOOTX64.EFI;; aarch64) fallback=BOOTAA64.EFI;; *) exit 1;; esac
    cmp /boot/efi/EFI/ZFSBootMenu/zfsbootmenu.EFI "/boot/efi/EFI/BOOT/$fallback"
    efibootmgr | grep -F ZFSBootMenu
else
    [[ $(findmnt -n -o FSTYPE --target /boot/syslinux) = ext4 ]]
    [[ -s /boot/syslinux/vmlinuz-bootmenu && -s /boot/syslinux/initramfs-bootmenu.img ]]
    grep -q 'zbm.timeout=15' /boot/syslinux/syslinux.cfg
fi
python3 - "$(zfs get -H -o value org.zfsbootmenu:commandline rpool/ROOT)" <<'PY'
from pathlib import Path
import shlex, sys
expected = shlex.split(sys.argv[1])
actual = shlex.split(Path('/proc/cmdline').read_text())
assert any(arg.startswith('console=') for arg in expected)
assert not any(arg.startswith('root=') for arg in expected)
assert all(arg in actual for arg in expected), (expected, actual)
PY
zfs list -t snapshot rpool/ROOT/ubuntu@zfsify-installed
systemctl is-enabled zfsify-snapshot.timer
! command -v grub-install
printf 'ZFS root verification passed.\n'
