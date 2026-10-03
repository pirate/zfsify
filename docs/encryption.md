# Encrypted root

`--encrypt` creates native ZFS AES-256-GCM encryption on `rpool`; its root dataset
inherits encryption. Ubuntu's `/boot` is inside the encrypted filesystem. The
small firmware/ZFSBootMenu partition and pool metadata remain unencrypted.

See [tested configurations and remaining validation](evidence/encryption-2026-10-03.md).

## Interactive setup

Select encryption in the root-conversion menu, or pass `--encrypt`. Review and
confirm the conversion as usual. After booting the RAM rescue environment, it
waits for a passphrase before changing the disk. Enter it twice in the console,
or reconnect using your existing root SSH key and run:

```sh
zfsify-unlock
```

Use `ssh -t root@SERVER zfsify-unlock` to run it directly. Input is hidden and read
from the terminal, never from the `curl | sh` stream. Keep a separate copy of the
passphrase: losing it means losing access to the encrypted data. Use characters
available in your preboot console’s keyboard layout.

## Headless conversion

```sh
curl -fsSL https://pirate.github.io/zfsify/reformat.sh | sudo bash -s -- \
  --yes --preserve --encrypt-key-url=https://keys.example.net/my-server
```

The URL implies `--encrypt` and can be combined with any root conversion method.
It must return a single UTF-8 passphrase of 8–512 bytes, optionally followed by
one newline. HTTPS certificates are verified, including public CA certificates
installed in the original Ubuntu's `/usr/local/share/ca-certificates`. Redirects,
embedded credentials, query strings and fragments are rejected.

**The URL is stored on the unencrypted rescue disk and is not an access secret.**
Restrict access at your key server, for example to the server's source address;
anyone able to retrieve that response can unlock the pool. The key itself is
fetched only in RAM after reboot and is never embedded in the rescue image.
The key server must be reachable from that environment. Failed retrieval stops
conversion before repartitioning or releasing source data; wrong keys on resume
stop further migration.
Keep the same key available until conversion and recovery testing are complete.

`--yes --encrypt` without a key URL is rejected rather than waiting unexpectedly.
Headless conversion does **not** enable unattended boot: the URL is not installed
as a permanent network unlock service.

## Boot and recovery

Enter the passphrase in ZFSBootMenu using your VM's serial/display console or
your provider's preboot recovery console. A console that depends on the running
Ubuntu SSH service cannot unlock an unbooted machine. Preboot SSH unlocking is
not configured by zfsify.

Following [ZFSBootMenu's native-encryption setup](https://zfsbootmenu.org/en/latest/general/native-encryption.html),
the key is stored root-only at `/etc/zfs/zfsify-rpool.key` inside the encrypted
root and its final Ubuntu initramfs. This avoids a second unlock prompt and
supports snapshot recovery. Kernel updates retain this configuration with
initramfs-tools or dracut. Never copy that key or the final Ubuntu initramfs to
the unencrypted firmware partition. Treat exported initramfs files as secrets.

After an interrupted slice-based conversion, boot the persistent rescue entry
and supply the same passphrase again (or retain access to the same HTTPS key).
Do not change the key mid-conversion. Rotating keys after installation also
requires updating the key file, initramfs and your snapshot recovery plan.

This encrypts the new filesystem; it is not secure erasure of the previous ext4
installation. Old free blocks, provider snapshots, rescue metadata and retained
backup archives may still disclose old data. Configure encryption separately
for external backups, such as an rclone crypt remote.
