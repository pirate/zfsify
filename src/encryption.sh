#!/bin/bash
# Sourced only by the RAM installer and target setup. No secrets in shell variables.
ENCRYPTION_ARGS=()
ENCRYPTION_ENABLED=$(python3 -c 'import json; print(int(json.load(open("/etc/zfs-on-boot/encryption.json"))["enabled"]))')
if [[ $ENCRYPTION_ENABLED = 1 ]]; then
    ENCRYPTION_ARGS=(-O encryption=aes-256-gcm -O keyformat=passphrase -O keylocation=file:///run/zfsify-encryption/rpool.key)
fi
encryption_acquire() {
    (( ${#ENCRYPTION_ARGS[@]} == 0 )) || python3 /etc/zfs-on-boot/encryption.py acquire
}
encryption_load() {
    [[ $(zfs get -H -o value encryption rpool) != off ]] || return 0
    [[ $(zfs get -H -o value keystatus rpool) != available ]] || return 0
    while ! zfs load-key -L file:///run/zfsify-encryption/rpool.key rpool; do
        echo 'Unable to unlock rpool; no further copy, remap or partition changes will run.' >&2
        rm -f /run/zfsify-encryption/rpool.key
        # An automatic source returning the wrong key must stop, not spin forever.
        if python3 -c 'import json; c=json.load(open("/etc/zfs-on-boot/encryption.json")); exit(not (c["key_url"] or c.get("boot_key")))'; then
            return 1
        fi
        encryption_acquire
    done
}
encryption_target() {
    (( ${#ENCRYPTION_ARGS[@]} != 0 )) || return 0
    # Only the verified, encrypted target ever receives a persistent key.
    [[ $(zfs get -H -o value encryptionroot rpool/ROOT/ubuntu) = rpool ]]
    install -m 600 /run/zfsify-encryption/rpool.key /target/etc/zfs/zfsify-rpool.key
    zfs set keylocation=file:///etc/zfs/zfsify-rpool.key rpool
    zfs set org.zfsbootmenu:keysource=rpool/ROOT/ubuntu rpool
    printf 'UMASK=0077\n' > /target/etc/initramfs-tools/conf.d/zfsify-encryption
    # Explicit hook works across Ubuntu zfs-initramfs package versions.
    mkdir -p /target/etc/initramfs-tools/hooks /target/etc/dracut.conf.d
    cat > /target/etc/initramfs-tools/hooks/zfsify-encryption <<'HOOK'
#!/bin/sh
set -e
case "$1" in prereqs) exit 0;; esac
. /usr/share/initramfs-tools/hook-functions
# Ubuntu's zfs hook may already have included the same key.
if [ ! -e "$DESTDIR/etc/zfs/zfsify-rpool.key" ]; then
    copy_file config /etc/zfs/zfsify-rpool.key
fi
chmod 600 "$DESTDIR/etc/zfs/zfsify-rpool.key"
HOOK
    chmod 755 /target/etc/initramfs-tools/hooks/zfsify-encryption
    printf 'install_items+=" /etc/zfs/zfsify-rpool.key "\n' > /target/etc/dracut.conf.d/91-zfsify-encryption.conf
}
