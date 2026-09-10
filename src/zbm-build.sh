#!/bin/bash
# Build upstream ARM64 ZFSBootMenu without changing the host's initramfs tooling.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive
WORK=${1:?}
BUILD=$WORK/zbm-build
[[ $(dpkg --print-architecture) = arm64 ]]
mkdir -p "$BUILD"
cleanup() {
    local point
    for point in dev proc sys; do
        if mountpoint -q "$BUILD/$point"; then umount -R "$BUILD/$point" || return; fi
    done
}
trap cleanup EXIT
# A fixed, independent Ubuntu builder keeps dracut out of both installed systems.
# No kernel compilation is needed: Ubuntu supplies the ARM64 kernel and ZFS.
debootstrap --variant=minbase noble "$BUILD" http://ports.ubuntu.com/ubuntu-ports
cat > "$BUILD/etc/apt/sources.list" <<'EOF'
deb http://ports.ubuntu.com/ubuntu-ports noble main universe
deb http://ports.ubuntu.com/ubuntu-ports noble-updates main universe
deb http://ports.ubuntu.com/ubuntu-ports noble-security main universe
EOF
printf '#!/bin/sh\nexit 101\n' > "$BUILD/usr/sbin/policy-rc.d"
chmod 755 "$BUILD/usr/sbin/policy-rc.d"
cp -L /etc/resolv.conf "$BUILD/etc/resolv.conf"
mount --rbind /dev "$BUILD/dev"
mount --make-rslave "$BUILD/dev"
mount -t proc proc "$BUILD/proc"
mount -t sysfs sysfs "$BUILD/sys"
chroot "$BUILD" apt-get update
chroot "$BUILD" apt-get install -y --no-install-recommends linux-image-virtual zfsutils-linux dracut-core systemd-boot-efi kexec-tools fzf libyaml-pp-perl libsort-versions-perl libboolean-perl make binutils file bsdextrautils kbd ca-certificates
# Ubuntu 26.04 ARM64 kernels use PE zboot, which noble's kexec cannot load.
# This Ubuntu package runs against noble's libraries; only the isolated boot
# image gets it. Keep the installed OS and the builder's other packages intact.
curl --fail --location --retry 3 https://ports.ubuntu.com/ubuntu-ports/pool/main/k/kexec-tools/kexec-tools_2.0.32-3ubuntu1_arm64.deb -o "$BUILD/tmp/kexec.deb"
echo 'bce6037e64e248fc03663fa607a3ad65dc0d3d7042a246d5691fd8dcae5dfbba  '"$BUILD/tmp/kexec.deb" | sha256sum -c -
chroot "$BUILD" dpkg -i /tmp/kexec.deb
# Ubuntu ARM64 vmlinuz may be gzip-wrapped; an EFI stub needs the raw kernel.
# This changes only the disposable builder, not the installed Ubuntu kernels.
for kernel in "$BUILD"/boot/vmlinuz-*; do
    if gzip -t "$kernel" 2>/dev/null; then
        gzip -dc "$kernel" > "$kernel.uncompressed"
        mv "$kernel.uncompressed" "$kernel"
    fi
done
curl --fail --location --retry 3 https://codeload.github.com/zbm-dev/zfsbootmenu/tar.gz/refs/tags/v3.1.0 -o "$BUILD/zbm.tar.gz"
echo '55aa61ff7450131348dcfe45c2b7ea01bec84b559f0e8e149b3dc8dbd093eaff  '"$BUILD/zbm.tar.gz" | sha256sum -c -
mkdir "$BUILD/zbm-src"
tar -xzf "$BUILD/zbm.tar.gz" --strip-components=1 -C "$BUILD/zbm-src"
if [[ $(awk '/MemTotal/ {print $2}' /proc/meminfo) -lt 750000 ]]; then
    # kexec_file_load duplicates the decompressed ARM kernel in memory and can
    # OOM at 512 MiB. The supported kexec_load syscall avoids that extra copy.
    sed -i 's/kexec -a -l/kexec -c -l/' "$BUILD/zbm-src/zfsbootmenu/lib/zfsbootmenu-core.sh"
fi
chroot "$BUILD" make -C /zbm-src core dracut
cat > "$BUILD/etc/zfsbootmenu/config.yaml" <<'EOF'
Global:
  ManageImages: true
  DracutConfDir: /etc/zfsbootmenu/dracut.conf.d
Components:
  Enabled: false
EFI:
  Enabled: true
  ImageDir: /output
  Versions: false
Kernel:
  Prefix: zfsbootmenu
EOF
cat > "$BUILD/etc/zfsbootmenu/dracut.conf.d/zfsify.conf" <<'EOF'
hostonly="no"
hostonly_cmdline="no"
compress="gzip"
zfsbootmenu_release_build="1"
EOF
KCL="$(cat "$WORK/boot/cmdline-rescue") zbm.timeout=15 zbm.prefer=rpool zbm.sort_key=creation zfs.zfs_arc_min=16777216 zfs.zfs_arc_max=67108864"
chroot "$BUILD" generate-zbm --no-initcpio --cmdline "$KCL"
test -s "$BUILD/output/zfsbootmenu.EFI"
cp "$BUILD/output/zfsbootmenu.EFI" "$WORK/zfsbootmenu.EFI"
cleanup
trap - EXIT
rm -rf "$BUILD"
