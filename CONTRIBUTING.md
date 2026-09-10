# Contributing

Contributions should make ZFS on Ubuntu easier to set up, operate, and recover.
Keep destructive behavior explicit, make supported inputs clear, and back changes
to conversion behavior with evidence from disposable VMs.

## Repository map

| Path | Purpose |
|---|---|
| `reformat.sh` | Self-contained installer for an existing root drive or attached data disk |
| `install.sh` | Generated alias of `reformat.sh` |
| `src/` | Installer source: preflight, RAM boot, migration, backup, boot setup, snapshots, and growth |
| `cloud-init/` | First-boot templates that schedule the same installer |
| `tools/volumes/` | Advanced inspection, named-pool, vdev, wizard, and benchmark helpers |
| `tools/digitalocean/` | DigitalOcean metadata, Volume listing, and Terraform provisioning |
| `scripts/` | Packaging, guest verification, and DigitalOcean acceptance harness |
| `scripts/recordings/` | Recording and presentation helpers |
| `docs/` | Usage guides and validation index |
| `docs/assets/recordings/` | Captured terminal output, previews, and provenance |
| `docs/evidence/` | Sanitized acceptance results; archived reports under `archive/` |

User-facing documentation should explain which command to choose and what it
will do. Keep descriptions self-contained; avoid assuming the reader knows other
scripts or the implementation history. The [README](README.md) is the starting
point, with focused guides for [cloud-init](docs/cloud-init.md) and
[data volumes](docs/volumes.md).

## Package the installer

Edit `src/`, then regenerate both distributed entry points and their checksum:

```sh
python3 scripts/package.py
```

Packaging embeds the source files; it does not run the installer or change disk
layouts. Commit generated installers and `SHA256SUMS` with their source changes.
The disposable `dist/` packaging output is ignored by Git. Signed Ubuntu
repositories can supply newer packages even when the installer checksum stays
unchanged, so preserve package versions with runtime evidence.

## Validate in disposable VMs

Installer runtime testing belongs in disposable VMs: DigitalOcean for amd64,
or a native ARM64 VM with UEFI for ARM64. Local VMs must use disposable virtual
disks without host disk passthrough or shared host folders. Never run the installer
on the workstation itself or a server holding needed data.
The DigitalOcean acceptance harness requires Python 3, curl,
OpenSSH, and an API token supplied privately as `DIGITALOCEAN_TOKEN`.

```sh
bash scripts/do-e2e.sh preserve
bash scripts/do-e2e.sh erase
DO_TEST_SIZE=s-1vcpu-512mb-10gb DO_TEST_IMAGE=ubuntu-22-04-x64 \
  bash scripts/do-e2e.sh preserve
```

By default, the harness creates a billable Ubuntu 24.04 `s-1vcpu-1gb` Droplet and
a temporary SSH key. It installs a data/account fixture, runs the packaged
installer, verifies the result and another reboot, then deletes the resources
recorded in its state file. The smaller-plan override above exercises Ubuntu
22.04 with 512 MiB RAM.

Native ARM64 tests must boot Ubuntu through UEFI and GRUB, so they exercise the
firmware path used after conversion. A hypervisor's direct-kernel boot skips that
path. Inside the VM, use `scripts/setup-fixture.sh preserve`, run `reformat.sh`,
then run `ZFSIFY_SKIP_DO_METADATA=1 bash scripts/verify.sh` and
`bash scripts/verify-preserved.sh` after conversion and again after a reboot.

The harness does not cover every workflow in the [validation index](docs/validation.md).
For example, provider disk growth, console recovery, attached data disks, and
first-boot templates require evidence for their own behavior. Run only checks
appropriate to the change; record failures and limitations rather than broadening
a success claim to untested layouts.

For RAM networking changes, copy the checkout to a disposable Ubuntu VM and
run `sudo python3 scripts/verify-network.py` there. It exercises IPv4/IPv6 gateway
dependencies, connected subnets, `onlink`, MTUs, and replay after NIC renaming in
isolated network namespaces. It also captures the VM's actual NICs and routes;
it does not change the host's network or test a complete conversion.
`sudo python3 scripts/verify-boot-config.py` checks boot-argument filtering and
GRUB syntax on that VM. Boot/shim changes also need a full conversion and reboot.

`scripts/verify-snapshot.sh` is an additional owned-Droplet check: it creates a
snapshot and clone, verifies their contents, and removes those test objects.
When reporting a completed run, include the installer checksum, Ubuntu image,
RAM/disk size, firmware, kernel and ZFS versions, and post-reboot results.

## Credentials and cleanup

The installer itself needs no cloud API token. The two provider tooling contexts
use distinct environment variables:

| Variable | Consumer |
|---|---|
| `DIGITALOCEAN_TOKEN` | Disposable test harness under `scripts/` |
| `DO_API_TOKEN` | Metadata/API/provisioning helpers under `tools/` |

For debugging, `KEEP_TEST_DROPLET=1 bash scripts/do-e2e.sh` retains cloud resources.
They continue to incur charges. The harness prints a private evidence directory
containing `resources.json` and the temporary SSH key. Delete those owned cloud
resources using:

```sh
python3 scripts/do-test.py destroy --state /path/to/evidence/resources.json
```

Investigate cleanup failures and remove any remaining owned resources through
DigitalOcean. Preserve useful sanitized evidence before removing temporary
controller keys and state. Never publish tokens, private keys, machine-specific
rescue images, backup archives, rclone credentials, or unreviewed logs.

## Useful contributions

- Reproducible failures with sanitized logs and precise image/layout details.
- Recovery from interrupted migrations and failed boots.
- Additional disk layouts or providers backed by real migration and growth evidence.
- Clearer first-run explanations, progress reporting, and operating guides.
- Reliable advanced helpers for managing data pools without surprising side effects.

Keep setup examples aligned with the actual entry points. Preserve raw recording
captures and disclose shortened waits, selected excerpts, preparation outside the
capture, and the exact installer build shown in each preview.
