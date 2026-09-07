# Cloud volume toolkit

The original **zfs.wizard / ZFS Cloud Management Toolkit** is preserved within
zfsify. These scripts manage ZFS data pools on attached DigitalOcean block-storage
volumes. They are separate from the new [root-on-ZFS installer](../README.md).

| Goal | Entry point |
|---|---|
| Reinstall Ubuntu with `/` and `/boot` on ZFS using the included disk | [`install.sh`](../install.sh); see the main README |
| Inspect attached storage or manage an additional data pool | The legacy scripts described here |

The legacy scripts remain at the repository root so existing paths keep working.
They were inspected for documentation during the rename, but were **not runtime
revalidated** with the new installer. Known implementation gaps are listed below.

> [!CAUTION]
> Pool-creation and vdev helpers can erase the selected device and change pool
> topology. Use them only with identified, disposable data devices; never point
> them at the root disk or zfsify's `rpool`. Some helpers format without prompting.
> DigitalOcean Volumes incur ongoing charges and are not automatically deleted.

## Setup

Clone the repository on a DigitalOcean Droplet and run commands from its root:

```sh
git clone https://github.com/pirate/zfsify.git
cd zfsify
sudo bash setup.sh
```

`setup.sh` makes component scripts executable and installs missing `curl`, `jq`,
`zfsutils-linux`, and `parted` packages through APT. It also checks provider metadata
access and reports whether `DO_API_TOKEN` is present. Individual tools may need
additional packages; the monolithic wizard installs its own dependencies.

Provider API operations use **`DO_API_TOKEN`**. Supply it through a private shell
environment, never a committed file. If using sudo, explicitly preserve that
variable where needed, e.g. `sudo --preserve-env=DO_API_TOKEN bash terraform_list_volumes.sh`.
Do not confuse it with the root installer's optional test-harness variable,
`DIGITALOCEAN_TOKEN`.

## Inspect storage

```sh
sudo bash terraform_get_droplet_metadata.sh
sudo --preserve-env=DO_API_TOKEN bash terraform_list_volumes.sh sfo3
sudo bash zfs_list_disks.sh
sudo --preserve-env=DO_API_TOKEN bash summarize_storage.sh
sudo bash find_new_disks.sh --all
sudo bash find_new_disks.sh --largest
```

The metadata helper reports the current Droplet. The volume helper lists volumes
in a region, which may include volumes belonging to other Droplets. The storage
summary combines local pool/device information with provider volume information
when credentials are available. Disk discovery reports candidates; independently
verify device identity and contents before formatting anything. Some inspection
helpers install missing dependencies, so do not treat every script as read-only.

## Create or extend a data pool

After attaching an empty data Volume and verifying its device path, the individual
helpers can be called directly. The following are examples with a placeholder
device path; substitute only a verified disposable data device:

```sh
# Erases the selected data device and creates /zfs/datapool.
sudo bash zfs_create_pool.sh datapool /dev/disk/by-id/YOUR_EMPTY_VOLUME

# Adds capacity by adding a top-level vdev; this does not add redundancy.
sudo bash zfs_add_stripe.sh datapool /dev/disk/by-id/YOUR_SECOND_EMPTY_VOLUME

# Attaches a mirror to an explicitly identified existing pool device.
sudo bash zfs_add_mirror.sh datapool /dev/disk/by-id/YOUR_SECOND_EMPTY_VOLUME /dev/disk/by-id/YOUR_EXISTING_POOL_DEVICE
```

Choose a topology deliberately: adding a stripe and attaching a mirror are
different operations, not sequential setup steps. A failed unreplicated top-level
vdev can lose the entire pool. Do not use these helpers to modify the root pool's
boot layout.

The pool-creation helper defaults to `/zfs/POOL_NAME`, lz4 compression, `atime=off`,
and `autoexpand=on`, and creates a `test` dataset. Those defaults belong to this
data-pool helper; they do not imply automatic disk growth in the root installer.

## Interactive workflows

### Modular wizard: `main.sh`

```sh
sudo --preserve-env=DO_API_TOKEN bash main.sh --poolname datapool
```

The intended sequence is metadata → storage summary → new-disk discovery →
optional volume creation → create pool/add stripe/attach mirror → summary →
optional speed test and usage examples. It uses the component scripts below.

**Known gaps:** `main.sh` references `terraform_create_new_volume.sh`, which is
absent from the existing repository. That branch of the workflow cannot complete
as shipped. Several operations run in background jobs without reliably propagating
failure, and the background volume assignment does not update the parent shell.
Use individual helpers on already attached devices rather than relying on the
wizard's volume-provisioning path.

### Monolithic wizard: `zfs-wizard.sh`

```sh
sudo bash zfs-wizard.sh
```

An earlier all-in-one interactive implementation installs prerequisites, discovers
storage, guides pool changes, and benchmarks results. It remains available for
reference and existing users. It has separate device-discovery and formatting
logic from `main.sh`; neither is used by the new root installer.

### Terraform volume creation: `terraform.sh`

```sh
sudo --preserve-env=DO_API_TOKEN bash terraform.sh --size 100 --name datapool --region sfo3
```

This creates and attaches a billable Volume using Terraform and the DigitalOcean
provider. Options are `--size`/`-s`, `--name`/`-n`, and `--region`/`-r`; defaults
are 100 GB, `zfs-HOSTNAME`, and the current Droplet's region. Missing Terraform
dependencies may be installed through the HashiCorp APT repository.

**Review these existing behaviors before use:**

- It writes the API token to `terraform.tfvars` under `/tmp/do-volume-terraform`
  and retains the directory. Protect it as private credential/state material.
- It removes an existing state file before applying a new plan. Re-running can
  leave earlier cloud resources unmanaged; account for existing resources first.
- It applies the saved Terraform plan without another interactive approval.
- Its final `exec ./zfs-wizard.sh` occurs after changing into the Terraform
  directory, so the wizard handoff can fail even after the Volume was created.
  Verify provider state before retrying to avoid duplicate charges.

No Terraform or legacy wizard behavior was changed as part of the rename.

## Script reference

| Script | Purpose / arguments |
|---|---|
| [`setup.sh`](../setup.sh) | Prepare dependencies and component executable permissions |
| [`main.sh`](../main.sh) | Modular interactive workflow; `--poolname NAME` (default `tank`) |
| [`zfs-wizard.sh`](../zfs-wizard.sh) | Original monolithic interactive wizard |
| [`terraform.sh`](../terraform.sh) | Create/attach a Volume; `--size`, `--name`, `--region` |
| [`terraform_get_droplet_metadata.sh`](../terraform_get_droplet_metadata.sh) | Current Droplet metadata as JSON |
| [`terraform_list_volumes.sh`](../terraform_list_volumes.sh) | Provider volumes; optional `REGION` |
| [`zfs_list_disks.sh`](../zfs_list_disks.sh) | Devices used by local ZFS pools |
| [`summarize_storage.sh`](../summarize_storage.sh) | Local pools and cloud storage summary |
| [`find_new_disks.sh`](../find_new_disks.sh) | Candidate unformatted disks; `--all` or `--largest` |
| [`zfs_create_pool.sh`](../zfs_create_pool.sh) | Format a device and create `POOL_NAME DEVICE` |
| [`zfs_add_stripe.sh`](../zfs_add_stripe.sh) | Add top-level vdev: `POOL_NAME DEVICE` |
| [`zfs_add_mirror.sh`](../zfs_add_mirror.sh) | Attach mirror: `POOL_NAME DEVICE [MIRROR_TARGET]` |
| [`speedtest.sh`](../speedtest.sh) | Read/write benchmark: `POOL_NAME` |

The old README listed `terraform_create_new_volume.sh`; that file is not present.
`terraform.sh` uses a different argument interface and is not a drop-in substitute.

## Benchmarks and datasets

```sh
sudo bash speedtest.sh datapool
sudo zfs create datapool/projects
sudo zfs snapshot -r datapool@before-change
sudo zfs list -t snapshot
```

The benchmark writes and removes `/zfs/POOL_NAME/speedtest_file` and drops system
caches; do not run it where that filename holds real data or where the extra load
would disrupt workloads. Zero-filled writes, compression, and caching can skew
its results. This is a quick diagnostic, not a standardized storage benchmark.

For failures, inspect actual `zpool status`, device mounts, and the DigitalOcean
console rather than relying only on progress indicators. For cloud API failures,
check metadata connectivity, region, token permissions, and the root process's
environment. Keep Terraform state and logs private. See [CONTRIBUTING.md](../CONTRIBUTING.md)
for how to report a reproducible issue.
