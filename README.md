<div align="center">

# ⚡ zfsify

Convert an Ubuntu VPS or attached volume from ext4 to ZFS with one command,
preserving existing data through in-place filesystem conversion.

[![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04+-E95420?logo=ubuntu&logoColor=white)](#requirements)
[![Experimental](https://img.shields.io/badge/status-experimental-f59e0b)](#before-you-start)
[![MIT](https://img.shields.io/badge/license-MIT-64748b)](LICENSE)

</div>

<p align="center">
<a href="https://pirate.github.io/zfsify/docs/recordings.html?demo=root"><img src="docs/assets/recordings/happy-path.gif" width="49%" alt="Ubuntu boot-drive conversion on DigitalOcean"></a>
<a href="https://pirate.github.io/zfsify/docs/recordings.html?demo=volume"><img src="docs/assets/recordings/volume.gif" width="49%" alt="Attached ext4 volume conversion on DigitalOcean"></a>
<a href="https://pirate.github.io/zfsify/docs/recordings.html?demo=rclone"><img src="docs/assets/recordings/rclone-root.gif" width="49%" alt="Backup and restore during conversion on DigitalOcean"></a>
<a href="docs/assets/recordings/progress-preview.gif"><img src="docs/assets/recordings/progress-preview.gif" width="49%" alt="Live progress during a local file copy"></a>
</p>

Cloud providers usually ship Ubuntu with ext4. Getting ZFS means building a
custom boot image or manually partitioning disks and migrating your files.
zfsify automates that work for the boot drive, including / and /boot, and
attached data volumes.

Create a normal Ubuntu VPS or volume on DigitalOcean, Vultr, Hetzner, AWS, GCP,
Azure, or another provider, then run zfsify inside Ubuntu. It transfers your
installation onto ZFS so you can use snapshots, compression, checksums, booting
from snapshots, and all the other benefits of ZFS.

## Choose a setup

- **Existing Ubuntu server or VM:** convert ext4 `/`, including `/boot`, on its current disk.
- **Attached disk or volume:** convert ext4 using its mount point, such as `/mnt/data`, or block-device path, such as `/dev/disk/by-id/...`; retain its files and mount point.
- **New Ubuntu server:** use the [cloud-init templates](docs/cloud-init.md) to convert the boot disk or an attached volume after provisioning.

## Before you start

**Experimental software: make a full offsite backup before proceeding.**
Repartitioning or an interrupted conversion can destroy data or leave the disk
unbootable.

Before running the command:

- **Boot drive (`/`):** allow server downtime and two reboots; confirm access to the VM or provider's recovery console.
- **Attached volume:** stop applications that use it; allow volume downtime until conversion finishes.

## Quick start

```sh
# Convert the Ubuntu boot drive.
curl -fsSL https://pirate.github.io/zfsify/reformat.sh | sudo sh

# Or convert an attached ext4 disk; replace the path with your disk's ID.
curl -fsSL https://pirate.github.io/zfsify/reformat.sh | sudo bash -s -- /dev/disk/by-id/YOUR-DISK
```

Review the selected disk and plan before the **15-second countdown** ends.
Backup destination selection waits for confirmation; explicit command-line
options skip selection prompts. Convert one disk per invocation.

## Requirements

- **OS:** Ubuntu 22.04, 24.04, or 26.04.
- **CPU architecture:** x64 (amd64) or ARM64.
- **RAM:** 512 MiB minimum for boot-drive conversion.
- **Disk:** 10 GB minimum for the boot drive.
- **Free space:** 3.5 GB on `/` and 500 MB in `/boot` to stage boot-drive conversion; additional working space depends on the selected method.
- **Filesystem:** ext4 on a direct disk or partition with 512-byte logical sectors. No LVM, RAID, encrypted sources, or 4K logical sectors.
- **Boot:** GPT and GRUB; BIOS or UEFI on x64, UEFI on ARM64; Secure Boot disabled. A separate ext4 `/boot` is supported.
- **Attached volumes:** one source filesystem per disk; room for a second copy or a separate backup destination.
- **Internet:** access to Ubuntu package repositories.
- **SSH:** for boot-drive conversion, your public key must be in `/root/.ssh/authorized_keys`; automatically copied to the rescue environment and fresh installs to preserve SSH access.

## Process, data safety, and recovery

<details>
<summary><strong>1. Inspect the selected disk and choose a method</strong></summary>

- **Enough room for two copies:** use a temporary partition (usually below 50% used).
- **Less free space on `/`:** rewrite in place, slice by slice.
- **Insufficient working space:** ask for a separate backup destination. Attached volumes require room for two copies or a separate backup.
- **On request:** use backup and restore (`--backup`) or erase (`--erase`). Erasure is never an automatic fallback.

</details>

<details>
<summary><strong>2. Prepare for conversion</strong></summary>

- **Boot drive:** install a temporary RAM boot environment, then reboot into it; prepare persistent rescue storage for slice-based conversion.
- **Attached volume:** unmount the source filesystem.
- **Backup and restore:** select and confirm a destination, then create a complete archive and read it back to verify it before erasing the source. An explicit `--backup=/mnt/backup` or `--backup=remote:path` skips destination prompts. [Backup setup](docs/backup.md).

</details>

<details>
<summary><strong>3. Convert ext4 to ZFS</strong></summary>

- **Two-copy method:** shrink ext4, copy files to ZFS at the disk's end, and verify before replacing the original. Move ZFS to the front and expand it. Bootability is preserved where possible, but partition and bootloader replacement have interruption windows; disk failure can destroy both copies.
- **Slice-based method:** copy and verify files in slices, then reuse their ext4 space. **The original Ubuntu installation becomes unbootable when its data starts being reclaimed.** The temporary rescue entry supports resuming interrupted copying or relocation.
- **Backup and restore:** erase the source, create ZFS, and restore the archive. The source remains unbootable until restoration and boot setup finish; keep the backup until the restored system works.
- **Erase (`--erase`):** for `/`, install fresh Ubuntu of the same release, preserve accounts, SSH access, and `/etc`, then restore as much home/application data as the displayed budget allows. **Omitted data is lost; applications may need reinstalling. For an attached volume, erase all files.**

![Conversion with room for a second copy](docs/assets/disk-conversion.svg)

</details>

<details>
<summary><strong>4. Finish disk and boot setup</strong></summary>

- Preserve file metadata and update mount settings for ZFS.
- **Boot drive:** update Ubuntu boot settings, replace GRUB with ZFSBootMenu, and reboot into Ubuntu. Keep a small firmware/bootloader partition outside ZFS; continue managing Ubuntu packages with APT.
- **Attached volume:** restore its mount point. You can then restart applications that use it.

</details>

<details>
<summary><strong>5. Use and maintain ZFS</strong></summary>

- **Snapshots:** automatic daily snapshots and snapshots before package changes. To recover a boot drive, use ZFSBootMenu in the provider's preboot console to boot a clone of a working snapshot. [Snapshot recovery](docs/recovery.md#open-the-preboot-console).
- **Disk growth:** enlarge the actual disk through the provider, then reboot; ZFS expands without guest-side resize commands. Tested for boot disks and attached Volumes on DigitalOcean.

![Snapshot selection in DigitalOcean's recovery console](docs/assets/screenshots/digitalocean-snapshots.jpg)

</details>

**If conversion stops:** reconnect and run `zfs-on-boot-status`. Do not blindly
reboot or delete temporary partitions. Interruptions during final partition or
bootloader replacement may require a provider rescue image.
[Recovery guide](docs/recovery.md) · [Interrupted conversion](docs/inplace.md#limits)

## Tested environments

| Environment | Ubuntu / architecture | Configuration |
|---|---|---|
| DigitalOcean Droplets | 22.04 and 24.04, x64, BIOS | 1 vCPU; 512 MiB RAM / 10 GiB boot SSD or 1 GiB RAM / 25 GiB boot SSD; attached 1–2 GiB Volumes |
| Local VMs on Apple Silicon (QEMU/HVF) | 24.04, ARM64, UEFI | 2 vCPUs; 512 MiB RAM / 10 GiB disk or 1 GiB RAM / 25 GiB disk |
| Local VMs on Apple Silicon (QEMU/HVF) | 26.04, ARM64, UEFI | 2 vCPUs; 1 GiB RAM / 25 GiB disk |
| KVM guest hosted on a DigitalOcean Droplet | 24.04, x64, UEFI | 1 GiB RAM / 20 GiB disk |

Other providers have not been explicitly tested. Cloud-init scheduling has not
been separately tested end to end.

## Performance

| Environment | Observed transfer speed |
|---|---|
| Small DigitalOcean Droplet, built-in SSD | About **20 MB/s** copying Ubuntu files |
| Local ARM64 VM, 1 GiB RAM | About **19 MB/s** copying and verifying files |
| Native NVMe | Not benchmarked |

**Allow at least 17 minutes per 20 GB at 20 MB/s**, plus package installation,
verification, relocation, and reboots. Small files, limited RAM, and backup
network bandwidth can increase the total time.

[Volume guide](docs/volumes.md) · [Cloud-init guide](docs/cloud-init.md) ·
[Recovery guide](docs/recovery.md) · [Contributing](CONTRIBUTING.md)
