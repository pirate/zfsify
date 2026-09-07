# Set up ZFS when creating a VPS

Use cloud-init when you want a newly provisioned Ubuntu server to convert its
boot disk or an attached data disk automatically. Use the
[one-command installer](../README.md#quick-start) over SSH when the server already
exists or you want to review its plan in a terminal.

The templates download and run the same `reformat.sh` entry point. They do not
require a custom Ubuntu image, an ISO, or a cloud API token inside the guest.
They create a systemd job that starts after cloud-init has finished configuring
users and networking.

| Target | Template | Default behavior |
|---|---|---|
| Boot drive, including `/` and `/boot` | [`cloud-init/root.yml`](../cloud-init/root.yml) | Preserve the existing Ubuntu installation |
| One attached disk | [`cloud-init/volume.yml`](../cloud-init/volume.yml) | Preserve ext4 data; explicit opt-in required to erase |

Use one template for each server launch: both use the same service and launcher
paths. To convert more disks, run the installer once per target afterward.
The underlying conversion paths have DigitalOcean acceptance evidence;
**these first-boot templates have not been separately tested end to end**.

## Convert the root drive at first boot

1. Create a normal Ubuntu VPS with a supported image and disk layout. Follow the
   [root requirements](../README.md#requirements), including at least 512 MiB RAM,
   a 10 GB disk, and the staging-space checks. A fresh, mostly empty image is the
   usual starting point.
2. Select your SSH public key in the provider's creation form.
3. Paste [`cloud-init/root.yml`](../cloud-init/root.yml) into the provider's
   **user data** or **cloud-init** field, then create the server.

The root template uses preservation mode. It performs the normal preflight and
15-second countdown, stages a compressed RAM environment, reboots to migrate the
disk, and reboots through ZFSBootMenu into Ubuntu on ZFS. Expect two SSH disconnects
and installation downtime. Install or start application workloads after that boot.

A root filesystem at least 50% used requires an explicit backup or erase decision.
This unattended template has no terminal to answer that prompt, so it stops; it
does not erase the disk. Connect over SSH and choose the appropriate mode in the
[space and backup guide](../README.md#when-the-disk-is-more-than-half-full).

### Ensure the recovery SSH key is available

The root installer requires your public key in `/root/.ssh/authorized_keys` so
you can reconnect while it is running from RAM. DigitalOcean's root-login images
normally receive the selected key there. Providers that inject keys only into
`ubuntu` or another default account need an explicit root key in cloud-init.

Add this top-level section to the root template, replacing the example with your
**public** key. If your configuration already has a `users` list, merge the entries
instead of adding a second list:

```yaml
users:
  - default
  - name: root
    lock_passwd: true
    ssh_authorized_keys:
      - ssh-ed25519 REPLACE_WITH_YOUR_PUBLIC_KEY
```

The template disables SSH password authentication. A private key or provider API
token does not belong in user data.

## Convert an attached volume at first boot

Attach the volume when provisioning the server, then customize
[`cloud-init/volume.yml`](../cloud-init/volume.yml):

- Set `TARGET` to its stable `/dev/disk/by-id/…` path, or an existing mount point.
  The placeholder deliberately refuses to run.
- Keep `ERASE=no` to preserve an existing ext4 filesystem with more than 50% free.
- Set `ERASE=yes` only for an empty disk or a disk whose entire contents you intend
  to discard. On data volumes, erase mode restores no files.

The target must be attached and discoverable when the job starts. The script
converts that one disk while Ubuntu stays running; it does not install a bootloader
or reboot for a data-volume conversion. Existing mount points are retained.
Unmounted inputs receive a generated mount point printed in the logs.

Cloud-init does not create the cloud Volume itself. Use the provider's creation
form/API or your provisioning tools for that, then give the guest the exact device
identity. The [volume guide](volumes.md) covers layout requirements, remote backup,
named pools, and provider helpers.

## Follow progress and confirm the result

Connect over SSH and inspect the first-boot job:

```sh
sudo journalctl -u zfsify-first-boot.service -f
```

For root conversion, reconnect after the first reboot and run:

```sh
sudo zfs-on-boot-status
```

After Ubuntu boots from ZFS, inspect its root filesystem and pool:

```sh
findmnt /
findmnt --target /boot
sudo zpool status
```

For a data-volume conversion, inspect the selected mount point instead. Its
work directory and `conversion.log` path appear in the service journal.

Each template records an attempt in `/var/lib/zfsify/first-boot.started`. This
prevents unattended retries after a partial conversion or later reboot. If it
stops, inspect the journal, disk layout, and any `/var/lib/zfs-on-boot` or
`/var/lib/zfsify-volume.*` staging state before deciding how to recover. Do not
clear the marker or staging directories blindly: a temporary pool may hold the
verified copy. Once the failure state is understood, use the regular installer
for a deliberate retry or recovery.

## Reproducible provisioning

The templates fetch the published installer when the job starts. For a fleet that
requires a fixed build, host or pin the reviewed installer artifact and change the
URL in the launcher. Record its SHA-256 with your provisioning configuration.
The signed Ubuntu package repositories can still provide newer packages during
preparation; a fixed shell-script checksum does not pin every Ubuntu package.
