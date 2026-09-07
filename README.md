<div align="center">

# ⚡ zfsify

Move an Ubuntu VPS onto ZFS using its included disk, with `/` and `/boot` in
the same dataset. The installer can preserve your existing installation when
less than half the root filesystem is used, or reinstall Ubuntu with your
accounts and configuration.

[![Ubuntu 24.04](https://img.shields.io/badge/Ubuntu-24.04-E95420?logo=ubuntu&logoColor=white)](#requirements)
[![Experimental](https://img.shields.io/badge/status-experimental-f59e0b)](#requirements)
[![MIT](https://img.shields.io/badge/license-MIT-64748b)](LICENSE)

[Quick start](#quick-start) · [Migration](#how-preservation-works) · [Validation](docs/validation.md) · [Volume toolkit](docs/volumes.md)

</div>

## Quick start

On an Ubuntu 24.04 amd64 VPS that meets the [requirements](#requirements),
wait for initial provisioning to finish (`cloud-init status --wait`), then run
the following command as root. Take a provider snapshot before migrating valuable
data, since the process repartitions the disk and takes services offline.

```sh
curl -fsSL https://pirate.github.io/zfsify/reformat.sh | sh
```

With **less than 50% of the root filesystem used**, this selects preservation
without requesting input. The installer shows the disk layout and target devices, then gives you
**15 seconds** to cancel with Ctrl-C before preparation starts. It reboots into
a RAM environment, migrates the filesystem, and reboots into Ubuntu on ZFS.

At **50% or more**, the installer asks for permission to erase the disk. It
requires a lowercase `y` followed by Enter in an interactive terminal; otherwise
it exits before preparing the migration.

### Reinstall Ubuntu

To erase application data and install a fresh Ubuntu base while keeping accounts
and configuration, use `--erase`:

```sh
curl -fsSL https://pirate.github.io/zfsify/reformat.sh | bash -s -- --erase
```

This option authorizes erasure without a confirmation prompt and includes the
same 15-second cancellation period. Use `sudo sh` or `sudo bash -s -- --erase`
when running from an account other than root.

<details>
<summary>What erase mode keeps and removes</summary>


**Erase mode deletes application data and home-directory contents.** It installs
a stock Ubuntu base and carries over `/etc`, user/group/password records, home
directory ownership, users' `.ssh/authorized_keys` and `authorized_keys2`, host
keys, machine identity, network configuration, cloud-init state, APT signing
keyrings, locally installed CA certificates, and generated Snap AppArmor policy
includes (not Snap applications or their data). It does not
reinstall your applications or preserve other home files (including private SSH
keys). Existing application configuration in `/etc` may refer to software or data
that needs reinstalling. Custom login shells must exist in the stock installation.
Software-selection links in `/etc/alternatives` and the dynamic-linker cache
come from the fresh OS in erase mode. System-file ownership is translated to
the retained account IDs. Carried-over local systemd units are kept but disabled
until their applications are restored. Disk-specific boot configuration is adjusted in both modes; the original fstab
is saved as `/etc/fstab.before-zfsify`, and root/boot/swap entries are replaced.

</details>

After either mode completes, reconnect with your SSH key and check the result:

```sh
findmnt /
findmnt --target /boot
zpool status
```

Both mount lookups should show `rpool/ROOT/ubuntu` with filesystem type `zfs`,
and the pool should be `ONLINE`.

## Requirements

- Ubuntu Server **24.04 amd64**, legacy BIOS with GRUB.
- One included disk with a GPT table and a plain ext4 root partition. An ISO
  metadata disk is permitted. No attached Volumes are needed or used.
- Preservation requires root to be the last partition; a separate ext4 `/boot`
  and the standard Ubuntu BIOS/EFI helper partitions are supported.
- At least **4 GiB RAM**, a **16 GB disk**, **8 GB free on `/`** for staging,
  and **500 MB free in `/boot`**. These staging requirements also apply to erase.
- Root SSH key access, working Ubuntu package repositories and Netplan networking.
- Initial cloud-init provisioning should finish before running the installer.

The project targets DigitalOcean. Other distributions, UEFI, ARM, LVM, RAID,
encrypted root, additional data partitions, and additional mounted local data
filesystems are outside the supported scope. The installer checks the OS and
disk layout before proceeding.

The usage threshold is calculated from allocated ext4 bytes and filesystem size
before staging. A successful migration also requires ext4 to shrink sufficiently
and the temporary ZFS partition to hold the copied data and metadata. If any step
fails, the installer stops in a rescue environment. Erasure always requires your
explicit consent.

## How preservation works

```text
Included disk (tiny bootloader area omitted)

[                  original ext4                  ]
[          smaller ext4        ][ temporary ZFS    ]  shrink; copy; verify
[          new ZFS member      ][ temporary ZFS    ]  attach; resilver
[          new ZFS member      ][ free space       ]  detach temporary
[                       ZFS                       ]  grow to disk end
```

The installer builds a complete RAM OS using signed Ubuntu APT repositories.
After booting that OS, the original filesystem is unmounted, checked and shrunk.
It creates a temporary ZFS pool in the freed tail of the same disk. `rsync`
preserves file contents, numeric ownership, permissions, ACLs, xattrs, hard links
and sparse files. A second, checksum-based comparison must find no differences
before the original ext4 partitions are removed.

It replaces the front of the disk with a mirror member, waits for a successful
ZFS resilver, detaches the temporary tail member, and extends the front partition.
The temporary mirror relocates data; it provides no protection against physical
disk failure because both members are on the same disk.

The source partitions are removed after copy verification and boot configuration
succeed; the first boot of the copied system happens after relocation. A power
loss during shrinking or relocation may require recovery from a provider snapshot.

The final layout is:

```text
GPT disk
  1   1 MiB   BIOS boot code (no filesystem)
  2   rest    rpool
                rpool/ROOT/ubuntu -> /, including /boot
```

GRUB reads the kernel/initramfs directly from ZFS. The pool uses
`compatibility=grub2`, lz4 compression, POSIX ACLs and xattr=sa. Do not enable ZFS
features incompatible with GRUB; this layout does not support native encryption.
A 256 MiB ARC cap is installed in `/etc/modprobe.d/zfs-on-boot.conf`. Adjust it and
regenerate the initramfs if your workload needs a different limit. Swap files
are excluded and swap fstab entries are removed.

## Progress and reconnecting

The installer displays its current phase, elapsed time, target devices, and disk
throughput. After either reboot, reconnect using your existing SSH key. You can
view progress during staging, in the RAM environment, and after installation:

```sh
zfs-on-boot-status        # refresh every second; Ctrl-C exits the viewer
zfs-on-boot-status --once # print the current state
```

<details>
<summary>Installation phases and throughput measurements</summary>

The installer reports ten phases:

1. Preflight and consent
2. Prepare Ubuntu and the RAM environment
3. Build the archive and stage reboot
4. Check/shrink ext4, or format for erase
5. Copy files
6. Verify checksums and metadata
7. Configure ZFS boot
8. Relocate through a temporary mirror (skipped for erase)
9. Expand the final partition and pool
10. Install GRUB and finish

Each report identifies the block devices being touched, elapsed time, a phase
bar, read/write MB/s and IOPS sampled from Linux block-device counters. Copy
phases show logical bytes moved/total and logical MB/s. Resilver progress uses
ZFS's issued/total counters when available. Package installation, checksums,
filesystem metadata operations and GRUB do not expose reliable byte totals;
those measurements are shown as `n/a`. The overall bar represents equally weighted
phases, whose durations vary. Physical disk and partition counters overlap.

Noninteractive logs include periodic progress reports and detailed command output.

</details>

## Automatic disk growth

The pool has `autoexpand=on`. A systemd service, `zfs-on-boot-grow.service`, runs
on each normal boot. It discovers the single root vdev, runs `growpart`, refreshes
the kernel's partition mapping and runs `zpool online -e`. It is idempotent and
leaves the starting sector unchanged. This handles a provider disk enlargement
on the boot after the resize; CPU/RAM-only resizes do not grow storage.
Cloud-init's generic root resize is disabled so it does not run ext4 tools on ZFS.
Multi-device pools are refused by this automatic-growth helper.

## Logs and recovery

Before reboot: `/var/lib/zfs-on-boot/stage.log` and
`/var/log/zfs-on-boot/progress.log`. Preparation installs packages and adds a
one-shot GRUB entry, but does not repartition the running root.

In RAM: `/run/zfs-on-boot.log`, `/var/log/zfs-on-boot/progress.log`, and
`zfs-on-boot-status`. Failure leaves RAM SSH and a provider-console shell running;
it does not automatically reboot or resume a partially completed migration.
**Do not reboot after source removal** without inspecting the failure.

After success: `/var/log/zfs-on-boot/`. Re-running the installer refuses an
already converted system before making changes.

Staging archives contain private host keys and (in erase mode) account records
and configuration. They are stored in root-only staging directories and are
never public release assets. Inspect mounts and logs before manually cleaning
an interrupted `/var/lib/zfs-on-boot` or `/boot/zfs-on-boot` directory.

## Development

```sh
python3 scripts/package.py
```

This packages `src/` into `reformat.sh`, its `install.sh` alias, and `dist/`.
The wrapper buffers all embedded scripts before launching the installer, passes
arguments through, and separates terminal consent from its piped input.
`SHA256SUMS` records the generated `reformat.sh` digest.

Runtime tests run on DigitalOcean Droplets. The [validation records](docs/validation.md)
describe the installer versions and scenarios covered. See [CONTRIBUTING.md](CONTRIBUTING.md)
for packaging and test instructions.

- `src/stage.sh`: usage gate, explanation/countdown, identity capture and RAM boot.
- `src/plan.py`: partition-layout validation and non-overlapping migration geometry.
- `src/ram-init.sh`: offline copy/verification, relocation and final boot.
- `src/target.sh`: boot configuration and erase-mode identity restoration.
- `src/progress.py`: command runner, phase state and Linux device telemetry.
- `src/grow.sh`: boot-time expansion of the final partition and ZFS vdev.
- `scripts/verify-preserved.sh`: DO fixture checks for data and metadata retention.
- `scripts/do-test.py`: recorded DO resource lifecycle; token comes from environment.

## 🧰 Volume tools

For ZFS data pools on attached DigitalOcean Volumes, the [volume toolkit](docs/volumes.md)
provides storage inspection, pool creation, stripe and mirror helpers, and
interactive setup. Its guide covers each command, requirements, and known limitations.

## Related projects

- [zfsbox](https://github.com/pirate/zfsbox) runs virtualized ZFS on macOS, Linux, and Docker.
- [OpenZFS](https://github.com/openzfs/zfs) provides the filesystem used by zfsify.
- [ZFSBootMenu](https://zfsbootmenu.org/) offers ZFS boot-environment selection and recovery tools.
- [cloud-init](https://cloud-init.io/) handles cloud instance initialization.
