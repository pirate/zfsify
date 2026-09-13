#!/bin/bash
set -Eeuo pipefail
DEV=$1 ORIGINAL_UUID=$2 DEFAULT_MOUNT=$3 POOL=$4 WORK=$5 SOURCE=$6
cp /etc/fstab "$WORK/fstab.before"
python3 - "$DEV" "$ORIGINAL_UUID" "$DEFAULT_MOUNT" <<'PY'
from pathlib import Path
import sys
p=Path('/etc/fstab'); out=[]
for line in p.read_text().splitlines():
    fields=line.split()
    if fields and not line.lstrip().startswith('#') and (fields[0] in (sys.argv[1], 'UUID='+sys.argv[2]) or len(fields)>1 and fields[1]==sys.argv[3]):
        out.append('# zfsify replaced: '+line)
    else: out.append(line)
p.write_text('\n'.join(out)+'\n')
PY
zfs set mountpoint="$DEFAULT_MOUNT" "$POOL/data"
zpool set cachefile=/etc/zfs/zpool.cache "$POOL"
systemctl enable zfs-import-cache.service zfs-mount.service zfs.target
# Enroll only this pool GUID; later imports of unrelated pools are never resized.
install -m 755 "$SOURCE/grow.sh" /usr/local/sbin/zfs-on-boot-grow
mkdir -p /etc/zfsify/volumes
zpool get -H -o value guid "$POOL" > "/etc/zfsify/volumes/$POOL"
cat > /etc/systemd/system/zfsify-volume-grow@.service <<'SERVICE'
[Unit]
Description=Expand an enrolled zfsify data pool after disk resize
After=zfs-import.target zfs-mount.service local-fs.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/zfs-on-boot-grow %i
[Install]
WantedBy=multi-user.target
SERVICE
systemctl daemon-reload
