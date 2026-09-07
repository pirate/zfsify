# DigitalOcean validation

Passed on 2026-09-07 UTC (2026-09-06 Pacific). All runtime testing was performed
on a live DigitalOcean Droplet. No local runtime or VM tests were used.

## Environment

- Stock image: `ubuntu-24-04-x64`.
- Plan: `s-2vcpu-4gb`, SFO3, 80 GB included disk, IPv6 enabled.
- Attached Volumes: none (`volume_ids: []`).
- Firmware: legacy BIOS. Original Ubuntu kernel: `6.8.0-124-generic`.
- Stock disk layout included separate `/boot` and `/boot/efi` partitions, plus
  a tiny ISO metadata disk. Only the root disk was rewritten.

## Clean one-command acceptance

The test Droplet was rebuilt from the stock image after development fixes.
The exact packaged script was copied to an HTTP server bound to loopback **on
the DigitalOcean Droplet**, and started with:

```sh
curl -fsSL http://127.0.0.1:8765/install.sh | sh
```

The HTTP server and staging command ran as temporary systemd services so the
test controller could observe them over separate SSH connections. No manual
repairs, recovery boot, or extra disk were used during this clean acceptance run.
This tested the curl-pipeline installation before publication. The public
`install.sh` is byte-for-byte identical to that tested artifact; the GitHub
download URL itself was not used in the recorded Droplet run.

Tested `dist/install.sh` SHA-256:

```text
a673e046cef57aa4bbb58b9d5dc234007f6a3d579bb30f5a737264e35ac86181
```

Start: 00:27:20 UTC. Installed Ubuntu and cloud-init checks completed by
00:31:16 UTC: approximately four minutes, including both installer reboots and
DigitalOcean's first-boot agent provisioning.

Verified:

- `/` and `/boot` both resolve to `rpool/ROOT/ubuntu`, filesystem `zfs`.
- The root disk contains a 1 MiB BIOS boot partition and one ZFS partition using
  the remaining space. No ext4/FAT filesystem or separate boot pool remains.
- GRUB reads `/boot` directly as ZFS. Pool compatibility is `grub2`.
- Pool ONLINE, with zero read, write, or checksum errors.
- Original SSH host keys and root authorized key continued working.
- DNS, provider metadata access, and IPv6 HTTPS access worked.
- Cloud-init reported `done`, `errors: []`, and no recoverable errors.
- DigitalOcean's Droplet Agent installed successfully.
- No failed systemd units.
- A root snapshot and mounted clone contained the kernel, initramfs, and matching
  modules, and excluded a file written after the snapshot. Test objects removed.
- Running the installer again exited before creating staging state or changing
  the pool GUID.

## Kernel maintenance and reboot

Reinstalled `linux-image-virtual`, `linux-image-6.8.0-139-generic`, and
`linux-modules-6.8.0-139-generic` through APT. Package hooks regenerated the
initramfs and GRUB configuration successfully on ZFS. Then rebooted and verified
that the boot ID changed and all root, service, cloud-init, package-audit, and
snapshot checks passed again at 00:32:56 UTC.

Running kernel: `6.8.0-139-generic`. ZFS: `2.2.2-0ubuntu9.4`.
This was a package reinstallation/reboot test, not an upgrade to a later ABI or
an Ubuntu release upgrade.

Evidence: [installation log](evidence/digitalocean-install.log),
[kernel package log](evidence/digitalocean-kernel-maintenance.log), and
[post-reboot checks](evidence/digitalocean-after-kernel-reboot.txt).

Evidence files are sanitized for public distribution: test Droplet IDs and
UUIDs are redacted; terminal carriage returns are normalized.

## Development findings

- `linux-image-generic` pulled in unnecessary physical-device firmware and made
  the initial RAM archive too large. `linux-image-virtual` includes the required
  kernel/ZFS modules without that firmware. Staging now builds and checks the
  complete archive before copying it to `/boot`.
- A bare devtmpfs lacks `/dev/fd`; the installer now creates the standard proc
  descriptor links before using Bash logging redirection.
- Installer output and the rescue shell explicitly use the VGA console so they
  are visible in DigitalOcean's Recovery Console.
- The minimal image needs `lsb-release` for cloud-init's apt configuration and
  `wget` for DigitalOcean's vendor agent installation. Both are included.
- Before erasure, the GRUB one-shot fallback was tested by power-cycling a failed
  RAM boot and returning successfully to the original ext4 Ubuntu system.

## Limits

Tested only on this amd64/BIOS DigitalOcean configuration with 4 GiB RAM. UEFI,
ARM, other providers, smaller-memory plans, application/data migration, disk
growth, reusable generalized snapshots, and release upgrades are not validated.
The build uses current signed Ubuntu repositories, so later builds can resolve
newer packages than the versions recorded here.

## Cleanup

The temporary Droplet and the test SSH key were deleted after acceptance. Both
resource lookups returned HTTP 404. The temporary local SSH private key was
removed; the API token was never written into this project or its logs.
