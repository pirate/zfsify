<div align="center">

# ⚡ zfsify

Convert an Ubuntu VPS or attached volume to ZFS with one command,
using the disks and data you already have.

[![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04+-E95420?logo=ubuntu&logoColor=white)](#requirements)
[![Experimental](https://img.shields.io/badge/status-experimental-f59e0b)](#implementation-status)
[![MIT](https://img.shields.io/badge/license-MIT-64748b)](LICENSE)

[Quick start](#quick-start) · [How it works](#how-it-works) · [Space requirements](#why-is-50-free-space-needed) · [Recovery options](#when-the-disk-is-more-than-half-full)

</div>

Cloud providers usually ship Ubuntu with ext4. Getting ZFS means building a
custom boot image or manually partitioning disks and migrating your files.
zfsify automates that work for the boot drive, including `/` and `/boot`, and
attached data volumes.

Create a normal Ubuntu VPS or volume on DigitalOcean, Vultr, Hetzner, AWS, GCP,
Azure, or another provider, then run zfsify inside Ubuntu. It transfers your
installation onto ZFS so you can use snapshots, compression, and checksums.

## Quick start

Connect to your Ubuntu VPS over SSH and run:

```sh
curl -fsSL https://raw.githubusercontent.com/pirate/zfsify/main/reformat.sh | sudo sh
```

Choose the boot drive or an attached volume. The installer shows its disk usage
and the planned changes before starting.

With at least half the filesystem free, zfsify makes a temporary copy of your
files on the same disk, then converts it while keeping your applications,
accounts, and configuration. Boot-drive conversion requires two reboots and
downtime; applications using a data volume must stop during its conversion.

With less space available, choose [remote backup or a reinstall with a limited
restore](#when-the-disk-is-more-than-half-full).

Take a provider snapshot or independent backup before converting important data.
A disk failure or interrupted repartitioning can affect both local copies.

## Requirements

- **Ubuntu 22.04 or later**, with root access.
- **At least 50% free space** on `/` or the volume being converted for migration
  within that disk. The installer also checks space for metadata and temporary files.
- A supported, shrinkable source filesystem and disk layout, checked by the installer.
- SSH access and access to Ubuntu package repositories.

Boot-drive conversion uses a temporary RAM environment. The tested configuration
requires **4 GiB RAM**, a **16 GB disk**, **8 GB free on `/`** for staging, and
**500 MB free in `/boot`**.

## How it works

To reformat the root filesystem, zfsify boots a temporary Ubuntu environment
from RAM. It can then unmount and modify the disk while providing SSH access.

1. **Copy the data to the end of the drive.** Shrink the filesystem to make room,
   then copy and verify the files in temporary storage.
2. **Set up ZFS at the start of the drive.** Reformat the front of the disk once
   the temporary copy is verified.
3. **Transfer the data back onto ZFS**, keeping ownership, permissions, and
   filesystem metadata.

![Disk conversion: copy data to the end, create ZFS at the start, restore, and expand](docs/assets/disk-conversion.svg)

After verifying the transfer, zfsify removes temporary storage and expands ZFS
to fill the disk. Boot-drive conversions also configure the bootloader and
initramfs before rebooting. Small bootloader partitions are kept where required.

<details>
<summary>What happens to files and metadata?</summary>

Migration keeps persistent files and their numeric ownership, permissions,
ACLs, extended attributes, hard links, symbolic links, and sparse allocation.
Linux recreates `/proc`, `/sys`, and `/dev`; temporary, staging, and swap files
are excluded.

Boot and mount configuration is updated for ZFS, with the previous filesystem
table saved as `/etc/fstab.before-zfsify`. Files are verified before reclaiming
their source storage; the first boot follows the completed conversion.

</details>

## Why is 50% free space needed?

**The disk temporarily holds two copies of your data** while each part is
reformatted. An 80 GB disk with 35 GB of data has room for another copy; one
holding 60 GB does not.

Metadata and working space also count, so zfsify checks the actual space needed
before repartitioning. A disk exactly half full may still need more room.

## When the disk is more than half full

Choose one of these options after reviewing how much data it can retain.
Both require approval before erasing the disk.

### Option A: Back up elsewhere, convert, and restore everything

Use an S3 bucket, another cloud storage service, or a separate volume with enough
space to hold the backup. zfsify opens **rclone's own configuration flow** to
choose and configure the destination, then uses rclone to transfer the backup.

After verifying the backup, zfsify reformats the disk as ZFS and restores the
installation. Allow time and bandwidth for uploading and downloading the backup.

<details>
<summary>Backup format and credentials</summary>

The backup archive retains Linux ownership, permissions, ACLs, extended
attributes, and links. rclone handles transfers, remote configuration, and
credentials through its standard CLI or UI.

Keep the backup until the restored system is verified. Use a private destination
because the archive contains system configuration and credentials.

</details>

### Option B: Install fresh Ubuntu and restore what fits

Choose this if you can reinstall applications or discard some data. zfsify
uses available temporary storage to save files before erasure and previews what
fits: for example, **“Restore 3.200 GB of 61.500 GB”**, with files kept and omitted.

It saves complete files in this priority order:

| Priority | Data to keep |
|---|---|
| 1 | Accounts and access: user/group/password records, users' SSH configuration and keys, networking, and information needed to configure a bootable system |
| 2 | The rest of `/etc` |
| 3 | `/root` and `/home` |
| 4 | `/var`, `/opt`, `/lib`, installed software, application data, and other files |

zfsify installs your selected Ubuntu release and restores the saved files.
**Omitted files are lost unless you have another backup.** If essential account,
access, and boot information cannot fit, it stops before erasure.

Applications with incomplete files may need reinstallation. Ubuntu supplies its
own kernel, boot files, and core libraries; incompatible files are excluded from
the preview. Services with missing dependencies or data stay disabled until repaired.

## Using ZFS after conversion

Check the root filesystem and pool after reconnecting:

```sh
findmnt /
findmnt --target /boot
sudo zpool status
```

For a boot-drive conversion, `/` and `/boot` live in `rpool/ROOT/ubuntu`, so a root
snapshot includes the kernel and its modules alongside the rest of the system:

```sh
sudo zfs snapshot rpool/ROOT/ubuntu@before-upgrade
sudo zfs list -t snapshot
```

After a provider disk resize, the next boot expands the partition and ZFS pool.
zfsify handles partition growth and enables ZFS `autoexpand`.

<details>
<summary>Boot compatibility</summary>

The tested BIOS layout uses a 1 MiB partition for GRUB boot code and the rest of the
usable disk for ZFS. GRUB reads `/boot` directly from the pool, which uses
`compatibility=grub2`. Keep that compatibility setting so the bootloader can read
the pool. Native ZFS encryption requires a different boot arrangement.

</details>

## Progress and recovery

The installer shows the current operation, target devices, elapsed time, copy
progress, and disk throughput. After reconnecting, view the current state with:

```sh
zfs-on-boot-status
zfs-on-boot-status --once
```

If migration fails, the RAM environment keeps SSH and a provider-console shell
available for inspection. **Avoid rebooting after the source filesystem has been
removed**, since the RAM environment may be the only working system at that point.

| Stage | Logs |
|---|---|
| Preparation | `/var/lib/zfs-on-boot/stage.log` |
| RAM environment | `/run/zfs-on-boot.log` |
| Progress and completed installation | `/var/log/zfs-on-boot/` |

## 🧰 Volume tools

The [volume toolkit](docs/volumes.md) provides commands for inspecting storage,
creating ZFS data pools, and adding stripe or mirror devices. Its guide covers
usage, requirements, and limitations.

## Implementation status

The [validation records](docs/validation.md) cover Ubuntu 24.04 amd64 with BIOS
on DigitalOcean. Ubuntu 22.04, other providers, attached-volume conversion,
rclone recovery, and priority-based restores are implementation targets.
The current `--erase` option retains a fixed set of accounts and configuration.

See [CONTRIBUTING.md](CONTRIBUTING.md) for implementation and testing instructions.

## Related projects

- [OpenZFS](https://github.com/openzfs/zfs) provides the filesystem used by zfsify.
- [rclone](https://rclone.org/) supports transfers to S3 and other storage services.
- [zfsbox](https://github.com/pirate/zfsbox) runs virtualized ZFS on macOS, Linux, and Docker.
- [ZFSBootMenu](https://zfsbootmenu.org/) provides ZFS boot-environment selection and recovery tools.
