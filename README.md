<div align="center">

# ⚡ zfsify

Convert a running Ubuntu VPS or attached volume from ext4 to ZFS in-place, preserving existing data through slice-by-slice filesystem conversion. 

Reboots into a ramdisk, converts chunks slice-by-slice in O(N) time. The end result is existing OS + data running perfectly on a now-ZFS-formatted `/` disk (aka `rpool`, just like [Ubuntu Server's 24.04+'s native ZFS root](https://www.phoronix.com/news/OpenZFS-Ubuntu-24.04-LTS)). You also get a beautiful new [boot menu](https://zfsbootmenu.org) (in `bpool`) that lets you boot from previous snapshots, send/recv, and more.

[![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04+-E95420?logo=ubuntu&logoColor=white)](#requirements)
[![Experimental](https://img.shields.io/badge/status-experimental-f59e0b)](#before-you-start)
[![MIT](https://img.shields.io/badge/license-MIT-64748b)](LICENSE)

</div>

<p align="center">
<a href="https://pirate.github.io/zfsify/docs/recordings.html?clip=phase-1"><img src="docs/assets/recordings/phase-1.gif" width="49%" alt="1. Scan disk and choose a method"></a>
<a href="https://pirate.github.io/zfsify/docs/recordings.html?clip=phase-2"><img src="docs/assets/recordings/phase-2.gif" width="49%" alt="2. Prepare the disk"></a>
<a href="https://pirate.github.io/zfsify/docs/recordings.html?clip=phase-3"><img src="docs/assets/recordings/phase-3.gif" width="49%" alt="3. Convert ext4 to ZFS"></a>
<a href="https://pirate.github.io/zfsify/docs/recordings.html?clip=phase-4"><img src="docs/assets/recordings/phase-4.gif" width="49%" alt="4. Finish disk and boot setup"></a>
<a href="https://pirate.github.io/zfsify/docs/recordings.html?clip=phase-5"><img src="docs/assets/recordings/phase-5.gif" width="49%" alt="5. Enable snapshots, recovery and growth"></a>
</p>

Cloud providers usually ship Ubuntu with ext4. Getting ZFS on `/` means building a
custom vm boot img or iso and uploading it. That's a pain though, and not all cloud
providers support it. zfsify automates that work and lets you in-place convert any disk, `/` and any other `/dev/disk*` others too!

Create a normal Ubuntu VPS or volume on DigitalOcean, Vultr, Hetzner, AWS, GCP,
Azure, or another provider, then run zfsify inside Ubuntu. It transfers your
installation onto ZFS so you can use snapshots, compression, checksums, booting
from snapshots, and all the other benefits of ZFS.

## Choose a setup

- **Existing Ubuntu server or VM:** convert ext4 `/`, including `/boot`, on its current disk.
- **Attached disk or volume:** convert ext4 using its mount point, such as `/mnt/data`, or block-device path, such as `/dev/disk/by-id/...`; retain its files and mount point.
- **New Ubuntu server:** use the [cloud-init templates](docs/cloud-init.md) to convert the boot disk or an attached volume after provisioning.

## Before you start

**⚠️ This is experimental software! make a full offsite backup before proceeding.**

We try to keep the process bootable/recoverable 90% of the time if it gets interrupted, and we provide [recovery instructions](docs/recovery) for some possible failure modes. Despite our best efforts, there are several 10~60s parts of the process where recovery/bootability is impossible if it gets interrupted (when changing the parition table). 🤞 Make offsite backups and avoid power outages during those parts!

If converting `/`: confirm that you can access your VM's display, VNC, or VPS cloud recovery console UI (only if you need to interact with ZFSBootMenu / boot from a snapshot). Expect 2 reboots and downtime/no apps runnable during the bulk of the process. After the first reboot you should be able to reconnect into the ramdisk and watch the transfer process over ssh, then reconnect after the last reboot into the new copied OS running in ZFS `rpool`.

If converting an attached disk other than `/`: make an offsite backup or snapshot in your cloud. Stop applications that use it, allow volume downtime until conversion finishes.

## 🔢 Quickstart

```sh
# Convert your Ubuntu ext4 grub install to Ubuntu ZFS rpool + ZFSBootMenu bpool
curl -fsSL https://pirate.github.io/zfsify/reformat.sh | sudo sh

# Or convert any other attached disk, e.g.
curl -fsSL https://pirate.github.io/zfsify/reformat.sh | sudo bash -s -- /dev/disk/by-id/abc-123
curl -fsSL https://pirate.github.io/zfsify/reformat.sh | sudo bash -s -- /dev/disk/rdisk4
```

## Minimum Requirements

- **System:** 🍥 Ubuntu `>= 22.04` (tested on `24.04` and `26.04`), on 🛠️ `x64` or `arm64`, 📟 >512 MiB RAM, with 🌐 internet access (for Ubuntu package repositories)
- **Source disk:** 💿 ext4 on a disk w/ 512-byte logical sectors. **❌ LVM, RAID, or encrypted ext4 sources are NOT supported.**
- **Bootloaders:** BIOS or UEFI on `x64`, only UEFI on `arm64`. Secure Boot must be disabled. All get converted to ZFSBootMenu on `bpool`. 
- **SSH:** you must have at least one public key in `/root/.ssh/authorized_keys`, it gets copied to the ramdisk to allow you to reconnect and watch the progress during the conversion.

## How it Works

<details>
<summary><h3 id="disk-scan">1. 💿 Scans the disk and selects an algorithm</h3></summary>

![Scan disk and choose a method](docs/assets/recordings/phase-1.gif)

- **Enough room for two copies:** it selects the temporary-partition method, usually when less than 50% of the filesystem is used.
- **Less free space on `/`:** it selects slice-by-slice conversion when the data fits alongside the recovery area and filesystem overhead.
- **Insufficient working space:** it asks you to choose a separate backup destination. Attached volumes require room for two copies or a separate backup.
- **Explicit options:** it uses your requested method (`--preserve`, `--inplace`, `--backup`, or `--erase`) when applicable. It never selects erasure as an automatic fallback.

</details>

<details>
<summary><h3 id="prepare-disk">2. 🚀 Prepares the disk for conversion</h3></summary>

![Prepare the disk](docs/assets/recordings/phase-2.gif)

- **Boot drive:** it stages a temporary RAM boot environment and reboots into it, retaining SSH access. For slice-based conversion, it also prepares persistent rescue storage so interrupted copying can resume.
- **Attached volume:** it unmounts the source filesystem before conversion; applications using that volume must be stopped first.
- **Backup and restore:** it prompts you to select and confirm a destination, then creates a complete archive and reads it back to verify it before erasing the source. An explicit `--backup=/mnt/backup` or `--backup=remote:path` selects the destination; final conversion confirmation is still required. [Backup setup](docs/backup.md).

</details>

<details>
<summary><h3 id="convert-to-zfs">3. 🔃 Converts ext4 to ZFS</h3></summary>

![Convert ext4 to ZFS](docs/assets/recordings/phase-3.gif)

- **Two-copy method:** it shrinks ext4, copies files to ZFS at the disk's end, and verifies them before replacing the original. It then moves ZFS to the front and expands it. Bootability is preserved where possible, but partition and bootloader replacement have interruption windows; disk failure can destroy both copies.
- **Slice-based method:** it copies and verifies files in slices, then reuses their ext4 space for ZFS. **The original Ubuntu installation becomes unbootable when its data starts being reclaimed.** The temporary rescue entry can resume interrupted copying or relocation.
- **Backup and restore:** it erases the source, creates ZFS, and restores the verified archive. The source remains unbootable until restoration and boot setup finish; keep the backup until the restored system works.
- **Erase (`--erase`):** for `/`, it installs fresh Ubuntu of the same release, preserves accounts, SSH access, and `/etc`, then restores as much home/application data as the displayed budget allows. **Omitted data is lost; applications may need reinstalling. For an attached volume, it erases all files.**

<p align="center">
<a href="https://pirate.github.io/zfsify/docs/recordings.html?clip=attached-disk"><img src="docs/assets/recordings/attached-disk.gif" width="49%" alt="Attached disk"></a>
<a href="https://pirate.github.io/zfsify/docs/recordings.html?clip=rclone"><img src="docs/assets/recordings/rclone.gif" width="49%" alt="rclone backup and restore"></a>
<a href="https://pirate.github.io/zfsify/docs/recordings.html?clip=two-copy"><img src="docs/assets/recordings/two-copy.gif" width="49%" alt="50/50 conversion"></a>
</p>

![Conversion with room for a second copy](docs/assets/disk-conversion.svg)

</details>

<details>
<summary><h3 id="finish-setup">4. 💾 Finishes disk and boot setup</h3></summary>

![Finish disk and boot setup](docs/assets/recordings/phase-4.gif)

- **Files and mounts:** it preserves ownership, permissions, ACLs, and extended attributes. It removes the old ext4 entries from `/etc/fstab` and configures ZFS to mount the new datasets at their original paths.
- **Boot drive:** it rebuilds Ubuntu's initramfs with ZFS support, preserves applicable kernel boot arguments, and replaces GRUB with ZFSBootMenu. A small firmware/bootloader partition remains outside ZFS; Ubuntu packages continue to use APT.
- **Attached volume:** it mounts the new dataset at the original mount point and enables mounting at startup. You can then restart applications that use the volume.

</details>

<details>
<summary><h3 id="snapshots-and-growth">5. 📸 Enables snapshots, recovery, and auto-grow on resize</h3></summary>

![Enable snapshots, recovery and growth](docs/assets/recordings/phase-5.gif)

- **Boot-drive snapshots:** it creates an initial recovery snapshot and schedules daily snapshots and snapshots before APT package changes, then reboots into Ubuntu. For recovery, you can open ZFSBootMenu in the provider's preboot console and boot a clone of a working snapshot. [Snapshot recovery](docs/recovery.md#open-the-preboot-console).
- **Disk growth:** it expands the ZFS partition and pool on reboot after you enlarge the disk through your provider. No guest-side resize commands are needed; both boot-disk and attached-volume growth have been tested on DigitalOcean.

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
| Small DigitalOcean Droplet, built-in SSD | About **20~50 MB/s** copying Ubuntu files |
| Local ARM64 VM, 1 GiB RAM | About **19 MB/s** copying and verifying files |
| Native NVMe | Not benchmarked |

**Allow at least 17 minutes per 20 GB at 20 MB/s**, plus package installation,
verification, relocation, and reboots. Small files, limited RAM, and backup
network bandwidth can increase the total time.

[Volume guide](docs/volumes.md) · [Cloud-init guide](docs/cloud-init.md) ·
[Recovery guide](docs/recovery.md) · [Contributing](CONTRIBUTING.md)
