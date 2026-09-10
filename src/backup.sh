#!/bin/bash
# Whole-filesystem archive transport. rclone owns all remote configuration.
set -Eeuo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
ACTION=${1:?}
if [[ $ACTION = configure ]]; then
    DEST=${2:?} OUT=${3:?} SOURCE_DISK=${4:?}
    USED_BYTES=${5:-0}
    CONFIRM_REQUIRED=0
    [[ $DEST != ask ]] || CONFIRM_REQUIRED=1
    # The same destination checks serve explicit flags and the interactive retry loop.
    validate_destination() {
        if [[ $DEST = /* ]]; then
            DEST=$(realpath -e "$DEST") || return 1
            [[ -d $DEST ]] || { echo 'Backup volume directory must already exist.' >&2; return 1; }
            BACKUP_DEV=$(findmnt -n -o SOURCE --target "$DEST")
            [[ -b $BACKUP_DEV && $(findmnt -n -o FSTYPE --target "$DEST") = ext4 ]] || { echo 'Mount a separate ext4 volume first, then enter its directory (not /dev/...).'; return 1; }
            mapfile -t BACKUP_DISKS < <(lsblk -snrpo NAME,TYPE "$BACKUP_DEV" | awk '$2=="disk" {print $1}')
            [[ ${#BACKUP_DISKS[@]} = 1 && ${BACKUP_DISKS[0]} != "$SOURCE_DISK" ]] || { echo "That directory is on the source disk ($SOURCE_DISK). Attach and mount another disk first." >&2; return 1; }
        else
            [[ $DEST = *:* && $DEST != :* ]] || { echo 'Use a named rclone remote:path or mounted volume directory.' >&2; return 1; }
            CONFIG=$(rclone config file | tail -1)
            [[ -f $CONFIG ]] || { echo 'Run rclone config first (choose option 2).' >&2; return 1; }
        fi
    }
    if [[ $DEST = ask ]]; then
        if ! { exec 3<>/dev/tty; } 2>/dev/null; then
            echo 'Backup selection and confirmation require an interactive SSH terminal.' >&2
            exit 1
        fi
        while :; do
            cat >&3 <<EOF

BACKUP SETUP - keep all files from $SOURCE_DISK
  1) Attached Volume / disk (recommended if your provider offers one)
     Create a temporary Volume now, or use one already mounted here.
  2) Configure cloud storage with rclone (S3, SFTP, and others)
  3) Use an existing rclone remote
  q) Cancel before conversion

The backup is checksum-verified before erasing $SOURCE_DISK, then restored
onto ZFS. Keep the destination attached/accessible until conversion is verified.
EOF
            if (( USED_BYTES > 0 )); then
                awk -v n="$USED_BYTES" 'BEGIN {printf "Source currently uses %.1f GB. Plan for at least %.0f GB free at the destination\n(used space + 20%%, rounded up); compression may help, but do not rely on it.\n", n/1e9, int(n*1.2/1e9)+1}' >&3
            fi
            choice=$(python3 "$(dirname "$0")/strategy.py" transport) || exit 1
            case $choice in
                1)
                    cat >&3 <<EOF

ATTACH A TEMPORARY VOLUME
  1. Open your provider's storage page and create a Volume in this server's
     region / availability zone. Attach it to this server.
  2. For a NEW empty Volume, choose ext4 and mount it using provider instructions.
     Keep this window open; use a second SSH session for any mount commands.
     Already have a mounted ext4 disk? Use its directory below.

DigitalOcean: Volumes -> Add Volume -> select this Droplet ->
  Automatically Format & Mount -> Ext4. Find its directory under /mnt below.
  https://docs.digitalocean.com/products/volumes/how-to/create/
  https://docs.digitalocean.com/products/volumes/how-to/mount-unmount/
Other providers and step-by-step help:
  https://pirate.github.io/zfsify/docs/backup.html

Only format the NEW backup Volume. $SOURCE_DISK is the source to preserve.
Do not run zfsify on the backup Volume; it stays ext4 for the rescue OS.
EOF
                    while :; do
                        printf '\nAttached disks (source to convert: %s):\n' "$SOURCE_DISK" >&3
                        lsblk -o NAME,PATH,SIZE,FSTYPE,MOUNTPOINTS >&3
                        printf '\nMounted ext4 filesystems and available space:\n' >&3
                        df -h -t ext4 >&3 || true
                        DEST=$(python3 "$(dirname "$0")/strategy.py" destination --disk "$SOURCE_DISK" --used "$USED_BYTES") || exit 1
                        [[ $DEST != q ]] || break
                        [[ -n $DEST ]] || continue
                        if [[ $DEST = path ]]; then
                            printf 'Enter absolute mounted directory (q = back): ' >&3
                            IFS= read -r DEST <&3 || exit 1
                        fi
                        [[ $DEST != q && $DEST != Q ]] || break
                        [[ $DEST = /* ]] || { echo 'Enter the absolute mount directory.' >&3; continue; }
                        validate_destination >&3 2>&3 && break
                    done
                    [[ $DEST != q && $DEST != Q ]] || continue
                    ;;
                2|3)
                    cat >&3 <<'EOF'

Use a private destination; the archive includes accounts and credentials.
Remote setup: https://rclone.org/commands/rclone_config/
Provider guides: https://rclone.org/overview/
EOF
                    if [[ $choice = 2 ]]; then
                        echo 'Opening rclone config. Create a remote with n; finish with q to return here.' >&3
                        rclone config <&3 >&3 2>&3 || continue
                    fi
                    echo 'Configured remotes:' >&3
                    rclone listremotes >&3
                    printf 'Enter remote:folder (e.g. myremote:zfsify-backups), or q to go back: ' >&3
                    IFS= read -r DEST <&3 || exit 1
                    [[ $DEST != q && $DEST != Q ]] || continue
                    validate_destination >&3 2>&3 || continue
                    ;;
                q|Q) echo 'Cancelled before conversion.' >&3; exit 1;;
                *) echo 'Choose 1, 2, 3, or q.' >&3; continue;;
            esac
            break
        done
        exec 3>&-
    else
        validate_destination || exit 1
    fi
    # Interactive choices need consent before any destination writes.
    # An explicit --backup= destination already supplies that authorization.
    if (( CONFIRM_REQUIRED )); then
        if ! { exec 3<>/dev/tty; } 2>/dev/null; then
            echo 'Backup requires manual destination confirmation in an interactive SSH terminal.' >&2
            exit 1
        fi
        printf '\nSource to convert: %s\nBackup destination: %s\n' "$SOURCE_DISK" "$DEST" >&3
        if [[ $DEST = /* ]]; then
            printf 'Destination device: %s on disk %s\n' "$BACKUP_DEV" "${BACKUP_DISKS[0]}" >&3
            lsblk -o NAME,PATH,SIZE,FSTYPE,MOUNTPOINTS "${BACKUP_DISKS[0]}" >&3
            df -h "$DEST" >&3
        fi
        printf 'A new private backup folder will be written here; existing data is retained.\nConfirm this is the destination you intend to use: type y and press Enter (no timeout): ' >&3
        IFS= read -r CONFIRM_DEST <&3 || exit 1
        [[ $CONFIRM_DEST = y ]] || { echo 'Backup cancelled before writing to destination.' >&3; exit 1; }
        exec 3>&-
    fi
    mkdir -m 700 -p "$OUT"
    if [[ $DEST = /* ]]; then
        printf "Backup device: %s on %s (separate from %s)\n" "$BACKUP_DEV" "${BACKUP_DISKS[0]}" "$SOURCE_DISK"
        df -h "$DEST"
        blkid -s UUID -o value "$BACKUP_DEV" > "$OUT/volume-uuid"
        BACKUP_MOUNT=$(findmnt -n -o TARGET --target "$DEST")
        printf '%s' "${DEST#"$BACKUP_MOUNT"}" > "$OUT/volume-subdir"
        : > "$OUT/rclone.conf"
    else
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
    echo 'Destination selected. Conversion will copy, read-back verify, reformat, and restore.'
    echo 'Leave a temporary Volume attached through reboot. It is not deleted automatically.'
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
    [[ $ACTUAL = "$EXPECTED" ]] || { echo 'Backup verification failed; original disk retained.' >&2; exit 1; }
    "${RCLONE[@]}" copyto "$HASHDIR/zfsify-backup.sha256" "$DEST/root.tar.gz.sha256"
    echo 'Complete offline backup read back and checksum-verified; original disk may now be reformatted.'
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
    cat "$CONF/destination" > "$LOGDIR/remote-backup-location"
    {
        printf 'Backup retained at: %s\n' "$(cat "$CONF/destination")"
        echo 'After conversion finishes, verify your files and applications (and reboot for root conversion).'
        if [[ -f $CONF/volume-uuid ]]; then
            printf 'Temporary ext4 Volume UUID: %s\n' "$(cat "$CONF/volume-uuid")"
            echo 'When satisfied: unmount that Volume, remove its mount configuration if needed,'
            echo 'then detach and delete it in your provider console to stop storage charges.'
            echo 'DigitalOcean: https://docs.digitalocean.com/products/volumes/how-to/delete-detach/'
        else
            echo 'When satisfied, keep the archive as a backup or remove its unique folder with rclone.'
        fi
        echo 'Backup and cleanup guide: https://pirate.github.io/zfsify/docs/backup.html'
    } | tee "$LOGDIR/backup-next-steps.txt"
else
    exit 2
fi
