<div align="center">

# ⚡ zfsify

Convert an Ubuntu VPS or attached volume to ZFS with one command,
using the disks and data you already have.

[![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04+-E95420?logo=ubuntu&logoColor=white)](#requirements)
[![Experimental](https://img.shields.io/badge/status-experimental-f59e0b)](#implementation-status)
[![MIT](https://img.shields.io/badge/license-MIT-64748b)](LICENSE)

[Quick start](#quick-start) · [How it works](#how-it-works) · [Space requirements](#why-is-50-free-space-needed) · [Recovery options](#when-the-disk-is-more-than-half-full)

</div>

Cloud providers usually ship Ubuntu with ext4, so getting ZFS on a VPS means
building a custom boot image or manually partitioning and migrating disks.
zfsify handles that work on a normal Ubuntu server. You can convert the boot
drive, including `/` and `/boot`, or use ZFS for data on attached volumes.

The workflow is designed for Ubuntu instances on DigitalOcean, Vultr, Hetzner,
AWS, GCP, Azure, and other cloud providers. You create the VPS or volume through
your provider as usual, then run zfsify inside Ubuntu. It checks the disk layout,
transfers your files, and configures ZFS so you can use snapshots, compression,
and checksums with your existing installation.

> [!NOTE]
> **This README describes the target design for implementation.** The currently
> validated configuration is Ubuntu 24.04 amd64 with BIOS on DigitalOcean.
> Broader provider support, Ubuntu 22.04, attached-volume conversion, and the
> recovery choices below require implementation and validation. Check
> [implementation status](#implementation-status) before running the script.

## Quick start

Connect to your Ubuntu VPS over SSH and run:

```sh
curl -fsSL https://raw.githubusercontent.com/pirate/zfsify/main/reformat.sh | sudo sh
```

Choose the boot drive or an attached volume from the filesystems shown by the
installer. It displays the selected device, its used and available space, and
what will happen to the data before starting.

If at least half the filesystem is free, zfsify uses that space to keep a temporary
copy of your files while it converts the disk. Your applications, accounts, and
configuration are carried over. A boot-drive conversion reboots into a temporary
RAM environment and then back into Ubuntu on ZFS; plan for downtime while files
are copied and the boot configuration is updated. Applications using a data
volume must also stop while that volume is converted.

If there is too little free space, the installer offers [a remote backup or a
reinstall with a limited restore](#when-the-disk-is-more-than-half-full). It shows
the consequences of each choice before asking you to proceed.

Take a provider snapshot or an independent backup before converting important
data. The temporary copy is on the same disk, so a disk failure or interrupted
repartitioning can affect both copies.

## Requirements

- **Ubuntu 22.04 or later**, with root access.
- **At least 50% free space** on `/` or the volume being converted for migration
  entirely within that disk. Filesystem metadata and temporary installation files
  also need room; zfsify checks whether the actual contents fit before proceeding.
- A supported, shrinkable source filesystem and disk layout, checked by the installer.
- SSH access and access to Ubuntu package repositories.

For a boot-drive conversion, the server also needs enough RAM to run the temporary
installation environment. The currently tested configuration requires **4 GiB RAM**,
a **16 GB disk**, **8 GB free on `/`** for staging, and **500 MB free in `/boot`**.

## How it works

A running system cannot reformat its own root filesystem. zfsify prepares a
small Ubuntu environment that runs from RAM, allowing it to unmount the boot
drive and work on the disk while SSH remains available between reboots.

1. **Copy the existing data to the end of the drive.** The filesystem is checked
   and shrunk to make room for temporary storage, then the files are copied and
   verified there.
2. **Set up ZFS at the start of the drive.** Once the temporary copy is verified,
   the front of the disk can be reformatted.
3. **Transfer the data back onto ZFS.** The files are restored to the ZFS partition
   at the start of the disk, with ownership, permissions, and filesystem metadata.

```text
                     Start of disk                         End of disk
Before               [          existing filesystem                  ]
Temporary copy       [ existing filesystem ][ verified copy at end    ]
Create ZFS           [      empty ZFS      ][ verified copy at end    ]
Restore              [    restored ZFS     ][ verified copy at end    ]
Finish               [              ZFS uses the disk                 ]
```

After the transfer is verified, zfsify removes the temporary storage and expands
ZFS to fill the available disk space. For the boot drive, it also configures the
bootloader and initramfs, then reboots into the migrated Ubuntu installation.
Small bootloader partitions are retained where required by the firmware.

<details>
<summary>What happens to files and metadata?</summary>

A full migration carries over applications, configuration, accounts, and persistent
data, including numeric ownership, permissions, ACLs, extended attributes, hard
links, symbolic links, and sparse files. Virtual filesystems such as `/proc`,
`/sys`, and `/dev` are recreated by Linux. Temporary files, installer staging
files, and swap files are excluded.

Boot and mount configuration is adjusted for ZFS. The previous filesystem table
is saved as `/etc/fstab.before-zfsify`. The copy must pass verification before its
source storage is reclaimed. The migrated system's first boot happens after the
disk conversion is complete.

</details>

## Why is 50% free space needed?

**The disk temporarily needs to hold two copies of your data.** One copy keeps
your installation intact while the other part of the disk is reformatted. For
example, 35 GB of data on an 80 GB disk leaves room for a second 35 GB copy;
60 GB of data on the same disk does not.

Filesystem overhead and working space also count, so being exactly half full may
still leave too little room. zfsify measures the space required before modifying
the partition layout.

## When the disk is more than half full

The installer offers two ways to proceed and shows the amount of data each can
retain. Both require your approval before erasing the disk.

### Option A: Back up elsewhere, convert, and restore everything

Use an S3 bucket, another cloud storage service, or a separate volume with enough
space to hold the backup. zfsify opens **rclone's own configuration flow** to
choose and configure the destination, then uses rclone to transfer the backup.

After verifying the backup, it reformats the selected disk as ZFS and restores
the installation. This allows the full disk to be used for the converted system
without needing room for two local copies. Transfer time and provider bandwidth
charges depend on the destination and amount of data.

<details>
<summary>Backup format and credentials</summary>

The filesystem is backed up in an archive format that retains Linux ownership,
permissions, ACLs, extended attributes, and links. rclone transports that archive
and handles its own remote configuration and credentials through its standard
CLI or UI. zfsify does not add a separate bucket-configuration system.

The backup remains available until the restored system has been verified. It
contains system configuration and credentials, so use a private destination with
appropriate access controls.

</details>

### Option B: Install fresh Ubuntu and restore what fits

Choose this when you can reinstall applications or discard some data. zfsify
calculates how much it can save outside the disk area being erased and shows a
preview such as **“Restore 3.200 GB of 61.500 GB”**, along with the files that will
be kept and omitted. The amount is determined by the available temporary storage.

It saves complete files in this priority order:

| Priority | Data to keep |
|---|---|
| 1 | Accounts and access: user/group/password records, users' SSH configuration and keys, networking, and information needed to configure a bootable system |
| 2 | The rest of `/etc` |
| 3 | `/root` and `/home` |
| 4 | `/var`, `/opt`, `/lib`, installed software, application data, and other files |

The installer then erases the disk, installs a fresh Ubuntu release selected in
the setup flow, and restores the saved files. **Anything omitted from the preview
is lost unless you have another backup.** If the essential account, access, and
boot information cannot fit, this option stops before erasure.

Restoring configuration or part of an application's files may leave that
application needing reinstallation. The fresh system supplies its own kernel,
boot files, and core libraries; incompatible system files are excluded from the
restore preview. Services with missing dependencies or data stay disabled until
you repair them.

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

When you increase the disk size through your cloud provider, the next boot expands
the partition and ZFS pool to use the added space. The pool has `autoexpand=on`;
zfsify also handles the partition expansion needed before ZFS can use it.

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

The [volume toolkit](docs/volumes.md) also provides individual commands for
inspecting attached storage, creating ZFS data pools, and adding stripe or mirror
devices. Use it when you want to manage a pool directly. The guide describes the
commands, their requirements, and known limitations.

## Implementation status

This README is the specification for the intended user experience. The
[validation records](docs/validation.md) identify the code versions and scenarios
that have been tested. Ubuntu 22.04+, broad cloud-provider support, selecting and
converting attached volumes through the installer, rclone backup/restore, and the
size-limited priority restore described here are implementation targets.

The existing `--erase` option carries over a fixed set of accounts and configuration;
it does not implement the priority-based restore preview described above. The
published script must be checked against the validation records before use.

For implementation and testing instructions, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Related projects

- [OpenZFS](https://github.com/openzfs/zfs) provides the filesystem used by zfsify.
- [rclone](https://rclone.org/) supports transfers to S3 and other storage services.
- [zfsbox](https://github.com/pirate/zfsbox) runs virtualized ZFS on macOS, Linux, and Docker.
- [ZFSBootMenu](https://zfsbootmenu.org/) provides ZFS boot-environment selection and recovery tools.
