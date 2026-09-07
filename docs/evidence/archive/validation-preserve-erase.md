# DigitalOcean: preservation, erase, and automatic disk resizing

Archived test record for the exact installer checksums below. These results
do not describe the current boot layout or minimum requirements. See the
[current validation index](../../validation.md) for supported workflows and evidence.

Validation date: **2026-09-07 UTC** (2026-09-06 Pacific).
All installer executions and acceptance checks ran on real DigitalOcean Droplets;
no local VM or local installer runtime tests were used.

## Supported configuration

Ubuntu Server **24.04 amd64**, legacy BIOS/GRUB, GPT, a plain ext4 root, root SSH
key access, and the included Droplet disk. Tests used SFO3, `s-2vcpu-4gb`
(4 GiB RAM, 80 GB disk) and `s-4vcpu-8gb` (8 GiB RAM, 160 GB disk).
Neither Droplet had an attached Volume. The provider's ISO metadata device was
left untouched.

The final layout contains one 1 MiB BIOS boot-code partition and one ZFS member
occupying the remaining usable disk space. `/` and `/boot` both resolve to
`rpool/ROOT/ubuntu`; there is no ext4 boot filesystem or separate data Volume.
The pool is `ONLINE`, uses `compatibility=grub2`, and has `autoexpand=on`.

## Installer versions

The final clean conversion runs used this frozen self-contained bundle:

```text
9c2fd39ee17b8ed121f9ffaa96a6d6ea59004dd1d2595718f32df91c8f7dc186
```

An intermediate published bundle (`38e6cae41e467229b1e781b8334c36d07dcfe4790c0abfc5b375ac114babd0ea`)
differed only by removal of one trailing space in `ram-init.sh` and the resulting
generated heredoc delimiter hashes. Its public download and already-installed
guard were checked on a converted Droplet. [Intermediate endpoint evidence](../published-check.txt).

The final bundle is:

```text
fa531a4d1aac02faa63bb1ccfe2513ff896110e7ff7f79bd6d980f86b2360386
```

It additionally fixes a telemetry display issue observed in the preservation
log: partition recreation can reset Linux I/O counters. The progress reporter
now skips that sample and establishes a new baseline, avoiding negative MB/s or
IOPS. The modified reporting function was regression-tested **on DigitalOcean**
with reset, subsequent normal, and removed-device readings. The final bundle's
already-installed guard also passed on DigitalOcean without changing the pool
GUID or creating staging files. The full conversions and resize used the frozen
checksum above; they were not repeated for this display-only change. Disk,
copy, identity-restoration, boot, and growth logic did not change.

[Telemetry regression checks](../telemetry-regression.txt) ·
[Final bundle guard](../final-bundle-check.txt) ·
[Final public download and guard](../published-final-check.txt)

## Preservation: passed

The final clean preservation run used a freshly rebuilt 160 GB / 8 GiB Droplet
with less than 50% of ext4 used. The installer was piped to `sh` without input.
It shrank ext4 offline, copied to temporary ZFS, passed its checksum/metadata
comparison, relocated through a temporary mirror, expanded to the full disk,
and booted the retained Ubuntu installation. ZFS recorded a 1.93 GiB resilver
in nine seconds with zero errors.

Acceptance checks verified a 512 MiB random file and its hard link, a 2 GiB
sparse file, SHA-256 file contents, ACLs, xattrs, hard-link identity, sparse
allocation, numeric ownership, retained configuration, and byte-identical passwd
and shadow records. Original SSH host keys matched their hashes, and a separate
SSH login as the retained test user succeeded. Root and boot both used ZFS;
networking, DNS, DigitalOcean metadata, APT update, AppArmor, cloud-init, and GRUB
worked, with no failed systemd units. A further ordinary reboot passed the
root/boot, complete preservation fixture, service health, and automatic-growth
checks again.

[Preservation acceptance](../preserve-final-acceptance.txt) ·
[Additional reboot acceptance](../preserve-final-reboot.txt) ·
[Retained user SSH login](../preserve-user-login.txt) ·
[Phase and throughput excerpts](../preserve-progress-excerpts.txt)

## Erase and identity restoration: passed

On a freshly rebuilt 80 GB / 4 GiB Droplet, a 40 GB allocated file took ext4 usage
above 50%. The piped installer ran with `--erase` without input, completed the
15-second countdown, installed a fresh Ubuntu base, and booted from ZFS.

Checks confirmed:

- Original passwd and shadow records remained byte-identical; host SSH keys and
  the test user's authorized key matched their original checksums.
- Retained `/etc` configuration and home-directory/key ownership were correct;
  a separate SSH login as the retained test user succeeded.
- The large source file and a home-directory application-data fixture were gone.
- SSH, networking, DNS, DigitalOcean metadata, APT update, AppArmor, cloud-init,
  and GRUB's ZFS probe worked; systemd reported no failed units.
- The status viewer reported all ten phases complete, and the normal boot-time
  growth service completed successfully with `NOCHANGE` on the original disk.

[Clean erase acceptance](../erase-final-acceptance.txt) ·
[Retained user SSH login](../erase-user-login.txt)

## DigitalOcean disk resize: passed, no guest commands

After the clean erase acceptance passed, the Droplet was shut down and resized
through the DigitalOcean API from **80 GB to 160 GB**, including the disk, then
powered on normally. No `growpart`, `zpool online`, partition-editing command,
or manual service invocation was run inside Ubuntu to expand it.

On that boot, the installed growth service expanded partition 2 and the ZFS pool:

| Measurement | Before | After |
|---|---:|---:|
| Included disk bytes | 85,899,345,920 | 171,798,691,840 |
| ZFS pool size bytes | 85,362,475,008 | 171,261,820,928 |
| ZFS partition start sector | 4,096 | 4,096 |
| Pool health | ONLINE | ONLINE |

All root/boot, identity-restoration, SSH service, networking, metadata, and system
health checks passed again after the resize. The service journal records the
partition's old and new sector counts and the expanded pool size.

**Users only need to perform the normal DigitalOcean disk resize and boot the
Droplet. No special commands are needed inside the VPS.** CPU/RAM-only resizes
do not add disk space. [Resize acceptance and service journal](../final-resize.txt).

## Usage gate, consent, and progress: passed

On DigitalOcean, the >50% fixture reported 55.41% usage before staging. Without
`--erase`, no terminal input caused an abort with the large warning and no
staging directory. A pseudo-terminal test confirmed that `n` and uppercase `Y`
were refused; exact lowercase `y` entered the 15-second countdown. Interrupting
that countdown left no staging directory. Explicit `--erase` proceeded without
input. The under-50% preservation path selected preservation without input.

Observed progress included phase bars, block-device names, logical bytes and
copy speed, and device read/write MB/s and IOPS. Metadata/package phases use
`n/a` for byte totals; they do not invent a total. Disk counter samples can be
zero while work is served from cache. The status command worked through RAM SSH
and after the final boot. The excerpts retain the original counter-reset
display anomaly; the final bundle fixes it as described above.

## Cleanup

Both disposable test Droplets and their temporary DigitalOcean SSH key were
deleted after acceptance. The API returned 204 for each deletion and subsequent
GET requests returned 404. The local temporary private key was removed. No
Volumes or test snapshots were created for these runs.

## Limits

These results establish the supported DigitalOcean Ubuntu 24.04 amd64 BIOS
configuration, not every possible Droplet layout or every cloud provider.
UEFI, ARM, LVM, encrypted root, multi-disk pools, attached data filesystems, and
other Ubuntu releases were not validated. The installer still has the capacity
and layout checks described in the README. A filesystem below 50% usage can
still fail a shrink or space check; that does not authorize erasure.

The conversion has no automatic rollback after source removal. These tests do
not establish power-loss recovery during repartitioning or preservation of
application state outside the documented filesystem copy semantics. The older
[reinstall report](validation-reinstall.md) covers its own historical checksum
and additional package/snapshot checks; those checks are not attributed to this
bundle unless explicitly listed above.
