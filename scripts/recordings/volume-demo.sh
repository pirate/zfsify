#!/bin/bash
set -euo pipefail
export TERM=xterm-256color LC_ALL=C
say() { printf '\n\033[1;36m%s\033[0m\n' "$1"; }
run() { printf '\n\033[1;32m$ %s\033[0m\n' "$*"; eval "$*"; sleep 2; }
printf '\033[2J\033[H'
say 'zfsify | attached volume, existing data preserved'
printf 'Live DigitalOcean run: Ubuntu 24.04 / 1 GiB RAM / 1 GiB data volume\n'
printf 'Installer served on localhost for this pre-release recording.\n'
run 'lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS'
run 'df -h /mnt/data'
run 'find /mnt/data -maxdepth 2 -type f | sort'
say 'One command converts the volume. The operating system keeps running.'
run 'curl -fsSL http://127.0.0.1:8765/reformat.sh | bash -s -- /mnt/data'
say 'Conversion complete. Same mount point; every file verified.'
run 'findmnt -no SOURCE,FSTYPE,TARGET --target /mnt/data'
run '(cd /mnt/data && sha256sum --check /root/data.sha256)'
run 'zpool list -o name,size,alloc,free,health'
run 'zpool get autoexpand'
run 'getfattr --only-values -n user.demo /mnt/data/README.txt'
[[ $(stat -c %i /mnt/data/releases/payload.bin) = $(stat -c %i /mnt/data/releases/current.bin) ]]
getfacl -cp /mnt/data/config/application.env | grep -q 'user:nobody:r--'
[[ $(findmnt -no FSTYPE /) = ext4 ]]
say 'PASS: hashes, hard links, ACLs, xattrs. Root stays ext4; no reboot.'
sleep 5
