#!/bin/busybox sh
# Minimal initramfs: read the compressed rescue filesystem into RAM, then release
# the source disk before starting any migration command.
export PATH=/sbin:/bin:/usr/sbin:/usr/bin
/bin/busybox --install -s /bin
mkdir -p /dev /proc /sys /source /payload /rescue
mount -t devtmpfs devtmpfs /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys
exec </dev/console >/dev/console 2>&1
fail() {
    echo "Rescue bootstrap failed: $*; source disk has not been changed."
    source=$(/sbin/blkid -U "$SOURCE_UUID" 2>/dev/null || true)
    if [ -b "$source" ]; then
        mount -o remount,rw /source 2>/dev/null || mount -o rw "$source" /source 2>/dev/null || true
        if mountpoint -q /source; then
            echo "$*" > /source/var/lib/zfs-on-boot/bootstrap-error.log
            sync
            umount /source
        fi
    fi
    echo 'Returning to the original Ubuntu installation in 10 seconds.'
    sleep 10
    reboot -f
    exec sh
}
. /config
for module in $MODULES; do
    # Controllers for other providers can return ENODEV on this hypervisor.
    /sbin/modprobe "$module" || case "$module" in ext4|loop|squashfs|overlay) fail "$module";; esac
done
for attempt in $(seq 1 60); do
    source=$(/sbin/blkid -U "$SOURCE_UUID")
    [ -b "$source" ] && break
    sleep 1
done
mount -o ro "$source" /source || fail 'mount source'
mount -t tmpfs -o size=80%,mode=700 tmpfs /payload || fail 'RAM storage'
cp /source/var/lib/zfs-on-boot/rescue.squashfs /payload/rescue.squashfs || fail 'copy rescue'
echo "$RESCUE_SHA  /payload/rescue.squashfs" | sha256sum -c - || fail 'rescue checksum'
umount /source || fail 'release source disk'
mkdir /payload/lower /payload/upper /payload/work
mount -t squashfs -o loop,ro /payload/rescue.squashfs /payload/lower || fail 'mount compressed rescue'
mount -t overlay -o lowerdir=/payload/lower,upperdir=/payload/upper,workdir=/payload/work overlay /rescue || fail 'rescue overlay'
mkdir -p /rescue/rescue-media
mount --move /payload /rescue/rescue-media || fail 'move RAM backing storage'
umount /proc
umount /sys
umount /dev
exec switch_root /rescue /init
