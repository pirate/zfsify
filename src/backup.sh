#!/bin/bash
# Whole-filesystem archive transport. rclone owns all remote configuration.
set -Eeuo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
ACTION=${1:?}
if [[ $ACTION = configure ]]; then
    DEST=${2:?} OUT=${3:?} SOURCE_DISK=${4:?}
    if [[ $DEST = ask ]]; then
        exec 3<>/dev/tty
        rclone config <&3 >&3 2>&3
        rclone listremotes >&3
        printf 'Backup destination (configured-remote:path or mounted volume directory): ' >&3
        IFS= read -r DEST <&3
        exec 3>&-
    fi
    mkdir -m 700 -p "$OUT"
    if [[ $DEST = /* ]]; then
        DEST=$(realpath -e "$DEST")
        [[ -d $DEST ]] || { echo 'Backup volume directory must already exist.' >&2; exit 1; }
        BACKUP_DEV=$(findmnt -n -o SOURCE --target "$DEST")
        [[ -b $BACKUP_DEV && $(findmnt -n -o FSTYPE --target "$DEST") = ext4 ]] || { echo 'Local backup requires a separate ext4 volume.' >&2; exit 1; }
        mapfile -t BACKUP_DISKS < <(lsblk -snrpo NAME,TYPE "$BACKUP_DEV" | awk '$2=="disk" {print $1}')
        [[ ${#BACKUP_DISKS[@]} = 1 && ${BACKUP_DISKS[0]} != "$SOURCE_DISK" ]] || { echo 'Backup must be on a different physical disk.' >&2; exit 1; }
        printf "Backup device: %s on %s (separate from %s)\n" "$BACKUP_DEV" "${BACKUP_DISKS[0]}" "$SOURCE_DISK"
        blkid -s UUID -o value "$BACKUP_DEV" > "$OUT/volume-uuid"
        BACKUP_MOUNT=$(findmnt -n -o TARGET --target "$DEST")
        printf '%s' "${DEST#"$BACKUP_MOUNT"}" > "$OUT/volume-subdir"
        : > "$OUT/rclone.conf"
    else
        [[ $DEST = *:* && $DEST != :* ]] || { echo 'Use a named rclone remote:path or mounted volume directory.' >&2; exit 1; }
        CONFIG=$(rclone config file | tail -1)
        [[ -f $CONFIG ]] || { echo 'Run rclone config first.' >&2; exit 1; }
        cp "$CONFIG" "$OUT/rclone.conf"; chmod 600 "$OUT/rclone.conf"
        # Credentials must travel in rclone's configuration, not depend on files
        # that disappear when the source disk is erased.
        rclone config dump | python3 -c 'import json,os,sys
for remote,config in json.load(sys.stdin).items():
 for key,value in config.items():
  if isinstance(value,str) and value.startswith(("/","~")) and os.path.isfile(os.path.expanduser(value)):
   sys.exit("Remote "+remote+" uses external credential file "+key+"; use an inline credential in rclone config before conversion.")'
    fi
    if [[ -n ${RCLONE_CONFIG_PASS:-} ]]; then
        printf '%s' "$RCLONE_CONFIG_PASS" > "$OUT/rclone-pass"; chmod 600 "$OUT/rclone-pass"
    fi
    DEST=${DEST%/}/zfsify-$(date -u +%Y%m%dT%H%M%S)-$(cat /proc/sys/kernel/random/uuid)
    printf '%s' "$DEST" > "$OUT/destination"
    printf 'Backup location: %s\n' "$DEST"
    # Verify that the configured remote can be contacted before staging a reboot.
    rclone --config "$OUT/rclone.conf" mkdir "${DEST%/*}"
    rclone --config "$OUT/rclone.conf" lsf "${DEST%/*}" --max-depth 1 >/dev/null
    exit 0
fi
CONF=${ZFSIFY_BACKUP_CONF:-/etc/zfs-on-boot/backup}
OLD=${ZFSIFY_BACKUP_SOURCE:-/old}
NEW=${ZFSIFY_BACKUP_TARGET:-/target}
HASHDIR=${ZFSIFY_BACKUP_STATE:-/run}
LOGDIR=${ZFSIFY_BACKUP_LOG:-$NEW/var/log/zfs-on-boot}
export RCLONE_CONFIG=$CONF/rclone.conf
[[ ! -f $CONF/rclone-pass ]] || export RCLONE_CONFIG_PASS="$(cat "$CONF/rclone-pass")"
DEST=$(cat "$CONF/destination")
if [[ -f $CONF/volume-uuid ]]; then
    mkdir -p /backup-volume
    mountpoint -q /backup-volume || mount -o rw "$(blkid -U "$(cat "$CONF/volume-uuid")")" /backup-volume
    DEST=/backup-volume$(cat "$CONF/volume-subdir")/${DEST##*/}
    trap 'sync; umount /backup-volume' EXIT
fi
RCLONE=(rclone --buffer-size 4M --transfers 1 --checkers 1 --stats 5s --stats-one-line --stats-log-level NOTICE)
if [[ $ACTION = save ]]; then
    # Source is offline and read-only. Explicit boot argument includes a separate
    # /boot filesystem while --one-file-system excludes unrelated mounted volumes.
    EXTRA=(); EXCLUDES=()
    if [[ ${ZFSIFY_BACKUP_DATA:-0} != 1 ]]; then
        mountpoint -q "$OLD/boot" && EXTRA=(boot)
        EXCLUDES=(--exclude='./proc' --exclude='./sys' --exclude='./dev' --exclude='./run'
          --exclude='./tmp' --exclude='./var/lib/zfs-on-boot' --exclude='./boot/zfs-on-boot'
          --exclude='boot/zfs-on-boot' --exclude='./boot/efi' --exclude='boot/efi'
          --exclude='./backup-volume' --exclude='./rescue-media' --exclude='./swapfile' --exclude='./swap.img')
    fi
    mkfifo "$HASHDIR/zfsify-backup-hash.pipe"
    sha256sum < "$HASHDIR/zfsify-backup-hash.pipe" > "$HASHDIR/zfsify-backup.sha256" & HASH_PID=$!
    tar --numeric-owner --acls --xattrs --sparse --one-file-system "${EXCLUDES[@]}" -cpf - -C "$OLD" . "${EXTRA[@]}" \
        | gzip -1 | tee "$HASHDIR/zfsify-backup-hash.pipe" | "${RCLONE[@]}" rcat "$DEST/root.tar.gz"
    wait "$HASH_PID"
    rm "$HASHDIR/zfsify-backup-hash.pipe"
    # Hashing a complete read-back verifies remote payload, not merely upload exit.
    EXPECTED=$(awk '{print $1}' "$HASHDIR/zfsify-backup.sha256")
    [[ $EXPECTED =~ ^[a-f0-9]{64}$ ]]
    ACTUAL=$("${RCLONE[@]}" cat "$DEST/root.tar.gz" | sha256sum | awk '{print $1}')
    [[ $ACTUAL = "$EXPECTED" ]] || { echo 'Remote backup verification failed; original disk retained.' >&2; exit 1; }
    "${RCLONE[@]}" copyto "$HASHDIR/zfsify-backup.sha256" "$DEST/root.tar.gz.sha256"
    echo 'Complete offline backup downloaded and checksum-verified; original disk may now be reformatted.'
elif [[ $ACTION = restore ]]; then
    mkfifo "$HASHDIR/zfsify-restore-hash.pipe"
    sha256sum < "$HASHDIR/zfsify-restore-hash.pipe" > "$HASHDIR/zfsify-restored.sha256" & HASH_PID=$!
    # Include system namespaces too: Docker overlay metadata and file capabilities
    # must survive; tar otherwise restores only user.* extended attributes.
    "${RCLONE[@]}" cat "$DEST/root.tar.gz" | tee "$HASHDIR/zfsify-restore-hash.pipe" | gzip -dc | tar --numeric-owner --same-owner --acls --xattrs --xattrs-include='*' -xpf - -C "$NEW"
    wait "$HASH_PID"
    rm "$HASHDIR/zfsify-restore-hash.pipe"
    cmp "$HASHDIR/zfsify-backup.sha256" "$HASHDIR/zfsify-restored.sha256"
    mkdir -p "$LOGDIR"
    cp "$HASHDIR/zfsify-backup.sha256" "$LOGDIR/remote-backup.sha256"
    printf '%s\n' "$DEST" > "$LOGDIR/remote-backup-location"
    echo 'Restored remote archive. The remote backup is retained.'
else
    exit 2
fi
