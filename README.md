<div align="center">

# ⚡ zfsify

**One command: Convert any live Ubuntu VPS to root (`/`)-on-ZFS.**

Reformat a fresh Ubuntu VPS onto ZFS in place, without losing any data (as long as <50% of `/` is used).<br>

[![Ubuntu 24.04](https://img.shields.io/badge/Ubuntu-24.04-E95420?logo=ubuntu&logoColor=white)](#requirements)
[![DigitalOcean tested](https://img.shields.io/badge/DigitalOcean-tested-0080FF?logo=digitalocean&logoColor=white)](docs/validation.md)
[![Status: experimental](https://img.shields.io/badge/status-experimental-f59e0b)](#requirements)
[![License: MIT](https://img.shields.io/badge/license-MIT-64748b)](LICENSE)

[Quick start](#-quick-start) · [How it works](#how-it-works) · [Disk layout](#disk-layout) · [Validation](docs/validation.md) · [Volume toolkit](docs/volumes.md)

</div>

---

Formerly **zfs.wizard**. zfsify now focuses on root-on-ZFS installation; the
original [cloud block-storage toolkit](docs/volumes.md) remains available.

> [!CAUTION]
> **This erases the entire root disk and installs a fresh Ubuntu system.**
> Existing applications, other users, home directories, and data are deleted.
> Use a fresh, disposable VPS. Only root SSH access, host keys, hostname, machine
> identity, and network configuration are carried over. There is no confirmation prompt.

## 🚀 Quick start

Create a fresh **DigitalOcean Ubuntu 24.04 x64 Droplet with at least 4 GiB RAM**,
add your SSH key, and connect as root. Wait for its initial cloud-init run to finish
before starting (`cloud-init status --wait`). Check the [requirements](#requirements), then:

```sh
curl -fsSL https://raw.githubusercontent.com/pirate/zfsify/main/install.sh | sudo sh
```

Leave SSH connected until the first reboot. The installer builds Ubuntu in RAM,
repartitions the disk, installs the new system, and reboots again. Reconnect using
the same IP address and SSH key once it finishes. The recorded DigitalOcean run
took **about four minutes**; package downloads and machine size affect timing.

```sh
findmnt /
findmnt --target /boot
sudo zpool status
```

Both mount lookups should report `rpool/ROOT/ubuntu` with filesystem type `zfs`,
and the pool should be `ONLINE`.

<details>
<summary><strong>Prefer to inspect the script before running it?</strong></summary>

Download the script and published checksum into an empty directory on the target VPS:

```sh
curl -fSLO https://raw.githubusercontent.com/pirate/zfsify/main/install.sh
curl -fSLO https://raw.githubusercontent.com/pirate/zfsify/main/SHA256SUMS
sha256sum -c SHA256SUMS
less install.sh
sudo sh install.sh
```

For a fixed version, replace `main` in both URLs with the same full commit SHA.
The checksum detects mismatched or corrupted downloads; it is not an independent
signature. The installer is a readable shell script containing both installation
stages. Ubuntu packages come from signed Ubuntu APT repositories.

</details>

## Why zfsify?

| | What you get |
|---|---|
| **Root on ZFS** | `/`, `/boot`, and kernel modules live in the same dataset. |
| **Your included disk** | All filesystem storage is ZFS; no attached Volume is required. |
| **Whole-system snapshots** | Capture boot files and the root filesystem together. |
| **Familiar Ubuntu** | Ubuntu 24.04, APT, systemd, OpenSSH, Netplan, and cloud-init. |
| **Small, inspectable installer** | Two shell stages packaged into a single download. |
| **Access preserved** | Keep root authorized keys, SSH host keys, and network configuration. |

## How it works

```mermaid
flowchart LR
    A["Fresh Ubuntu VPS<br/>ext4 root"] --> B["Stage Ubuntu + ZFS<br/>and a RAM installer"]
    B -->|Reboot 1| C["Run entirely in RAM<br/>Erase + repartition disk"]
    C --> D["Copy Ubuntu to ZFS<br/>Install GRUB + initramfs"]
    D -->|Reboot 2| E["Ubuntu on ZFS<br/>Same IP + SSH keys"]
    style A fill:#334155,color:#fff,stroke:#64748b
    style B fill:#1e3a8a,color:#fff,stroke:#3b82f6
    style C fill:#78350f,color:#fff,stroke:#f59e0b
    style D fill:#1e3a8a,color:#fff,stroke:#3b82f6
    style E fill:#064e3b,color:#fff,stroke:#10b981
```

The original OS builds and checks a self-contained RAM environment before setting
a one-shot GRUB boot entry. The RAM OS can then rewrite the disk it booted from.
It copies the new Ubuntu installation onto ZFS and installs the permanent bootloader.

No custom ISO upload, extra disk, cloud API token, or provider recovery boot is
needed for installation. The cloud API is used only by the optional test harness.

## Disk layout

```text
Included VPS disk · GPT
┌───────────────────────────────────────────────────────────────┐
│ 1 MiB BIOS boot code │ ZFS rpool · all remaining usable space │
└───────────────────────────────────────────────────────────────┘
                       └── rpool/ROOT/ubuntu → /
                           ├── boot/       kernel + initramfs
                           ├── usr/        system + modules
                           ├── etc/        configuration
                           └── var/ …      everything else
```

The tiny BIOS partition contains GRUB boot code, **no filesystem**. GRUB reads
`/boot` directly from ZFS; there is no ext4/FAT filesystem or separate boot pool.
Ubuntu's `zfs-initramfs` imports the root pool during boot.

> [!IMPORTANT]
> The pool uses `compatibility=grub2`. Keep that restriction: enabling features
> GRUB cannot read can make the machine unbootable. Native ZFS encryption is not
> supported by this boot layout.

## Requirements

| Component | Supported baseline |
|---|---|
| Provider | **DigitalOcean**, tested on `s-2vcpu-4gb` in SFO3 with an 80 GB included disk |
| OS | Ubuntu Server **24.04**, **amd64/x86_64** |
| Boot | **Legacy BIOS + GRUB** |
| Source storage | One disk, plain **ext4** root; separate ext4 `/boot` on the same disk is accepted |
| Memory | **4 GiB RAM** minimum |
| Space | **16 GB disk**, **8 GB free on `/`**, **500 MB free in `/boot`**; final archive must also fit |
| Access | Root `/root/.ssh/authorized_keys`, working Netplan, package repository access |

A small ISO metadata disk is allowed. Detach additional data disks before use.
The installer rejects unsupported OS, architecture, firmware, and storage layouts
before erasure. These checks do not make it safe to run on a machine with valuable data.

**Currently outside the supported scope:** UEFI, ARM, LVM, RAID, encrypted root,
smaller-memory VPS plans, and providers other than DigitalOcean. The minimum disk
size is a preflight threshold; the recorded live test used 80 GB.

## 📸 First snapshot

After installation, take a snapshot of the root dataset:

```sh
sudo zfs snapshot rpool/ROOT/ubuntu@fresh-install
sudo zfs list -t snapshot
```

Snapshots include `/boot` and matching kernel modules. Quiesce applications when
you need application-consistent snapshots. Snapshots on the same disk do not
protect against losing that disk, and zfsify does not yet provide a boot-environment
selector or automated rollback workflow.

## FAQ

<details>
<summary><strong>Can it preserve my existing applications and data?</strong></summary>

**No. This release performs a fresh reinstall.** It carries over root authorized
SSH keys, SSH host keys, hostname, `/etc/hosts`, machine ID, and Netplan configuration.
Everything else on the old disk is erased. Being less than 50% full does not change
this behavior. In-place ext4-to-ZFS migration is a possible future direction, not
an available mode.

</details>

<details>
<summary><strong>Will the pool grow automatically when I resize my Droplet?</strong></summary>

No. Automatic disk expansion is not implemented. Growing the disk requires
expanding the last partition and then its ZFS vdev. Cloud-init's `growpart` and
`resize_rootfs` are disabled because the stock ext4 expansion flow is not used.
Do not assume a provider resize expands the pool, or that setting `autoexpand`
alone would resize the partition.

</details>

<details>
<summary><strong>What happens if installation fails?</strong></summary>

Before reboot, staging installs prerequisites and creates a one-shot GRUB entry;
it does not erase the source filesystem. Inspect staging logs and any mounts below
`/var/lib/zfs-on-boot/root` before cleaning up or retrying.

During installation, the RAM OS provides SSH with the original keys. On failure
it stays running with a console shell. If networking fails, use DigitalOcean's
Recovery Console. **After erasure, do not reboot a failed install:** the RAM OS
may be your only remaining recovery environment. A power loss may require a
provider recovery boot or rebuilding the Droplet. One-shot GRUB fallback cannot
restore an erased disk.

| Stage | Log |
|---|---|
| Preparation | `/var/lib/zfs-on-boot/stage.log` |
| RAM installer | `/run/zfs-on-boot.log` |
| Installed system | `/var/log/zfs-on-boot/install.log` |

Re-running the installer on an already installed system exits without reinstalling.
Internal paths retain the original `zfs-on-boot` name to preserve the tested code.

</details>

<details>
<summary><strong>What defaults does it configure?</strong></summary>

ZFS uses `lz4` compression, `ashift=12`, POSIX ACLs, `xattr=sa`, and `atime=off`.
The ARC is capped at 256 MiB and no swap is configured. To change the ARC cap,
edit `/etc/modprobe.d/zfs-on-boot.conf`, run `sudo update-initramfs -u -k all`,
and reboot. Ubuntu's `linux-image-virtual` metapackage supplies the kernel.

Cloud-init remains installed, but network regeneration and automatic root expansion
are disabled. This is an installation for one specific VPS: do not distribute its
snapshot without generalizing SSH keys, network settings, machine identity, and
cloud-init state. The generated RAM image includes private SSH host keys and must
never be uploaded as a public release artifact.

</details>

## Validation & development

The first installer was validated on a real DigitalOcean Droplet: installation,
root and boot mounts, SSH continuity, networking, cloud-init, snapshots, kernel
package reinstallation, and subsequent reboot. See the [validation report](docs/validation.md)
for versions, sanitized evidence, and the exact tested checksum. This is an
**experimental release**, not a claim of broad cloud compatibility.

```text
src/stage.sh              build and stage the RAM environment
src/ram-init.sh           boot in RAM, format, install, reboot
scripts/package.py       package both stages into one shell script
scripts/do-e2e.sh         disposable DigitalOcean installation + reboot test
scripts/verify*.sh        checks executed inside a test Droplet
install.sh               published standalone installer
SHA256SUMS               checksum of the published installer
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for packaging and DigitalOcean testing.
Ideas for future work include data-preserving migration, automatic disk growth,
UEFI support, and additional providers. None of these are implemented in this release.

## 🧰 Cloud volume toolkit

The original **zfs.wizard** tools for attached DigitalOcean block-storage volumes
are still included at their existing paths. They provide storage inspection,
pool creation, stripe/mirror helpers, and interactive wizards. They do not replace
the root filesystem and are independent of `install.sh`.

See the [volume toolkit guide](docs/volumes.md) for setup, all script entry points,
examples, Terraform behavior, and known limitations. These legacy workflows have
not been revalidated as part of the root installer release.

## Related projects

- [**zfsbox**](https://github.com/pirate/zfsbox) — the sibling project: virtualized ZFS from userspace on macOS, Linux, and Docker.
- [**OpenZFS**](https://openzfs.org/) — the filesystem powering zfsify; see its [Ubuntu root-on-ZFS guide](https://openzfs.github.io/openzfs-docs/Getting%20Started/Ubuntu/Ubuntu%2022.04%20Root%20on%20ZFS.html) for a manual installation reference with a different layout.
- [**ZFSBootMenu**](https://zfsbootmenu.org/) — an alternative boot manager with ZFS boot-environment features. zfsify currently uses GRUB.
- [**debootstrap**](https://wiki.debian.org/Debootstrap) and [**cloud-init**](https://cloud-init.io/) — the tools behind the Ubuntu bootstrap and cloud integration.

---

<div align="center">

Built by [@pirate](https://github.com/pirate) · [MIT licensed](LICENSE) · Powered by OpenZFS

</div>
