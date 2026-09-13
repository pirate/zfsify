#!/bin/bash
set -Eeuo pipefail
cp /usr/local/sbin/zfsify-snapshot /target/usr/local/sbin/
mkdir -p /target/etc/apt/apt.conf.d
printf 'DPkg::Pre-Invoke { "/usr/local/sbin/zfsify-snapshot apt"; };\n' > /target/etc/apt/apt.conf.d/80-zfsify-snapshot
cat > /target/etc/systemd/system/zfsify-snapshot.service <<'UNIT'
[Unit]
Description=Create a daily ZFS root recovery snapshot
After=zfs-mount.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/zfsify-snapshot daily
UNIT
cat > /target/etc/systemd/system/zfsify-snapshot.timer <<'UNIT'
[Unit]
Description=Daily ZFS root recovery snapshot
[Timer]
OnCalendar=daily
Persistent=true
[Install]
WantedBy=timers.target
UNIT
chroot /target systemctl enable zfsify-snapshot.timer
chroot /target systemctl enable zfs-on-boot-grow.service
zfs snapshot rpool/ROOT/ubuntu@zfsify-installed
zpool get autoexpand rpool
zfs list -t snapshot rpool/ROOT/ubuntu@zfsify-installed
