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

**This software is experimental. Always make a full offsite backup before
proceeding.** Conversion repartitions the selected disk. A failure can leave it
unbootable or destroy data; snapshots on that same disk are not an offsite backup.

Converting `/` takes the server offline and reboots it twice. Have working access
to the VM or provider's recovery console.

Converting an attached volume makes that volume unavailable during conversion.
Stop any applications that use it so it can be unmounted.

## Quick start

```sh
# Convert the Ubuntu boot drive.
curl -fsSL https://pirate.github.io/zfsify/reformat.sh | sudo sh

# Or convert an attached ext4 disk; replace the path with your disk's ID.
curl -fsSL https://pirate.github.io/zfsify/reformat.sh | sudo bash -s -- /dev/disk/by-id/YOUR-DISK
```

Architecture, boot mode, and available space are detected automatically. Review
the displayed disk and plan: **automatic choices proceed after a 15-second countdown**.
Backup setup waits for input; explicit options skip selection prompts.
One invocation converts one disk.

<details>
<summary><strong>What happens to your data, bootability, and recovery options</strong></summary>

- **Below 50% used, with enough working space:** ext4 is shrunk and files are copied
  to a temporary ZFS partition at the end of the disk. The original copy stays until
  verification succeeds; ZFS is then moved to the front and expanded. We try to
  retain a bootable path for most of the process, but partition and bootloader
  replacement still have interruption windows. A disk failure can affect both copies.
- **At least 50% used on `/`, or two copies otherwise won't fit:** files are copied
  and verified in slices, releasing their old ext4 space as the conversion advances.
  **The original Ubuntu installation can no longer boot once its data starts being
  reclaimed**, until ZFS boot setup finishes. A temporary rescue entry can resume
  interrupted copying or relocation; interruption during the final partition or
  bootloader changes may require the provider's rescue image.
- **If you choose backup and restore:** a separate disk or remote destination holds
  a complete archive, which is read back and verified before the source is erased.
  Ubuntu cannot boot from that source again until restoration and boot setup finish.
  Keep the destination accessible until the restored system works. `--backup` opens
  guided setup; `--backup=/mnt/backup` or `--backup=remote:path` uses that destination
  without prompting. [Backup setup and cleanup](docs/backup.md).
- **If you choose `--erase`:** the disk is erased. For `/`, zfsify installs fresh
  Ubuntu of the same release, retaining accounts, SSH access, and `/etc`, then as
  much home/application data as fits its displayed restore budget. **Anything omitted
  is lost; applications may need reinstalling. On a data volume, all files are lost.**
  Erasure requires this explicit option or confirmation; it is never an automatic fallback.

The installer checks actual capacity, so 50% is a guide rather than a guarantee.
If neither method fits `/`, it asks for a backup destination. Attached data disks
need space for a second copy or a separate backup destination. Interactive backup
setup waits for your selection and confirmation, without a countdown.

![Conversion with room for a second copy](docs/assets/disk-conversion.svg)

Files and metadata are preserved; boot and mount settings are updated for ZFS.
ZFSBootMenu replaces GRUB, while Ubuntu packages remain managed through APT.
A small firmware/bootloader partition stays outside ZFS.

Follow progress after reconnecting with `zfs-on-boot-status`. On failure, **do not
blindly reboot or delete temporary partitions**. See the [recovery guide](docs/recovery.md)
and [interrupted conversion](docs/inplace.md#limits).

After conversion, snapshots are taken daily and before package changes. Use
ZFSBootMenu in your provider's preboot console to boot a clone of a working
snapshot. [Snapshot recovery](docs/recovery.md#open-the-preboot-console).

![Snapshot selection in DigitalOcean's recovery console](docs/assets/screenshots/digitalocean-snapshots.jpg)

After enlarging the actual disk through your provider, reboot to expand ZFS
without guest-side resize commands. Boot-disk and attached-volume growth have
both been tested on DigitalOcean.

</details>

## Requirements

- **Ubuntu 22.04, 24.04, or 26.04**, on **x64 (amd64) or ARM64**.
- **For `/`: 512 MiB RAM, a 10 GB disk, 3.5 GB free on `/`, and 500 MB free in `/boot`.**
  Additional working space may be needed for the data being converted.
- **ext4 on a direct disk or partition, with 512-byte logical sectors.** The boot
  disk must use GPT and GRUB; a separate ext4 `/boot` is supported. Data disks must
  contain only one source filesystem. LVM, RAID, encrypted sources, and 4K logical
  sectors are not supported.
- **BIOS or UEFI on x64; UEFI on ARM64. Secure Boot must be disabled.**
- Internet access to Ubuntu package repositories. For boot-drive conversion,
  put your SSH public key in `/root/.ssh/authorized_keys` for rescue access.

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

Observed Ubuntu file-copy speed on small DigitalOcean Droplets' built-in SSDs
is roughly **20 MB/s**. A **1 GiB ARM64 VM** copied and verified files at about
**19 MB/s** during conversion. Native NVMe conversion throughput has not
been benchmarked.

At 20 MB/s, copying 20 GB alone takes about **17 minutes**. Allow additional time
for package installation, verification, relocation, and reboots. Many small files,
limited RAM, and backup network bandwidth can make the process slower.

[Volume guide](docs/volumes.md) · [Cloud-init guide](docs/cloud-init.md) ·
[Recovery guide](docs/recovery.md) · [Contributing](CONTRIBUTING.md)
