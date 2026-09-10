# Experimental conversion with less free space

`--inplace` requests the experimental slice-by-slice root migration backend.
Automatic selection also uses it when 50/50 does not fit and enough working
space remains. It takes priority over external backup, even with another disk
mounted. It keeps zfsify's Ubuntu packages, RAM rescue, ZFSBootMenu, snapshots, and disk-growth setup. It uses
Ubuntu's `fstransform` package for **`fsremap`**, the physical block mover; it
does not require a fork of fstransform or a permanent storage-mapping layer.

Use only a disposable VM:

```sh
curl -fsSL https://raw.githubusercontent.com/pirate/zfsify/refs/heads/experiment/inplace-zfs/reformat.sh | sudo bash -s -- --inplace
```

The backend uses the supported GPT/ext4 root layout on BIOS or UEFI, with `/boot`
either inside root or on a separate ext4 partition. The normal staging requirements
still apply, including 3.5 GB free on `/` and 500 MB free on `/boot`. There is no
50% gate for this mode, but enough space must remain for filesystem overhead and
the final ZFS data. A universal minimum free-space percentage is not established.

## What happens

1. Boot the RAM rescue, shrink ext4 by 1 GiB, and put the persistent rescue and
   journal in that temporary space. Install a rescue entry before releasing data.
2. Save a file hash/metadata manifest and create a sparse ZFS image inside ext4.
   Reserve space at its beginning for the final bootloader when necessary.
3. Copy in 64 MiB batches with a small memory buffer. Flush and verify each batch,
   commit its checkpoint, then punch holes in the original file to reuse its space.
   Trim unused blocks in the temporary ZFS image when ext4 needs more room.
4. Verify all files, export ZFS, and let `fsremap` rearrange the image's blocks
   onto the original partition. Its journal and 32 MiB secondary scratch file
   live in the temporary area on the same disk. Remapping uses a 16 MiB transfer
   buffer with automatic primary scratch allocation disabled for low-memory hosts.
5. Import the native ZFS partition, verify the manifest again, and finish the
   usual Ubuntu boot setup. Install ZFSBootMenu, release the temporary area, and
   expand root. The front boot partition is at least 512 MiB.

The final root uses one native ZFS partition. It has no loop file, device-mapper
dependency, extra disk, or permanent collection of small vdevs.

## Why this split

[fstransform](https://github.com/cosmos72/fstransform) already solves overlapping
physical block relocation. Its frontend does not implement Ubuntu root boot
setup, and its file mover does not provide the same ACL/xattr preservation and
per-batch verification used here. Keeping those pieces in zfsify and calling
`fsremap` is a smaller integration than moving the Ubuntu installer upstream or
implementing another block-remapping algorithm.

## Validation

- Final bundle, DigitalOcean Ubuntu 22.04, BIOS, **512 MiB RAM**, 10 GiB disk
  at 62% usage: unattended conversion, 104,934 manifest entries verified before
  and after remapping, native boot, preservation checks, clean scrub, and normal
  reboot. No extra Volume or conversion swap.
  [End-to-end evidence](evidence/inplace-do-512mb-final.txt).
- Final bundle, native ARM64 Ubuntu 24.04, 1 GiB RAM, 25 GiB disk at 71% usage:
  unattended conversion, complete manifest verification, native boot, preserved
  files/metadata, clean scrub, and normal reboot.
  [End-to-end evidence](evidence/inplace-arm64-final.txt).
- DigitalOcean Ubuntu 24.04, BIOS, 1 GiB RAM, 25 GiB disk at 71% usage:
  provider power-cycle during remapping, automatic rescue/resume, native ZFS
  boot, preservation checks, clean scrub, and automatic growth to 50 GiB.
  [Recovery and resize evidence](evidence/inplace-do-recovery.txt).
- Ubuntu 24.04 ARM64, 1 GiB RAM, 25 GiB boot disk at 71% usage: hard reset
  during copying, automatic resume, 123,459 manifest entries verified before and
  after remapping, native boot, scrub, initramfs rebuild/reboot, and automatic
  expansion to 32 GiB. [Recovery and growth evidence](evidence/inplace-arm64-recovery.txt).
- An 8 GiB disk at 76% usage, with a 6000 MiB file: interrupted mover resumed,
  native remap, metadata/hash verification, and clean scrub.
  [Mover evidence](evidence/inplace-mover-recovery.txt).
- Resumed byte totals, file counters, transfer rates, and mapper IOPS:
  [progress checks](evidence/inplace-progress-recovery.txt).

Repeat the end-to-end tests with `scripts/do-e2e.sh inplace` (set
`DIGITALOCEAN_TOKEN`, optionally `DO_TEST_SIZE` and `DO_TEST_IMAGE`) or
`scripts/arm64-e2e.sh` on Apple Silicon (QEMU/HVF and Python `pycdlib`). Both create
disposable guests, fill root beyond 50%, convert, verify, scrub, reboot, and clean up.

## Limits

Original data is released progressively, so there is no retained complete ext4
copy. The persistent rescue entry resumes copying from the manifest or remapping
from fsremap's journal. Existing Ubuntu cannot boot midway through conversion.
GPT and bootloader replacement still have a recovery window: interruption there
can require a provider rescue image. A journal is not a backup.

The journal, geometry, and original manifest are retained privately under
`/var/log/zfs-on-boot/inplace/`. Do not delete the temporary partition or its
journal during an interrupted conversion.

Do not use this prototype on a server holding needed data. The normal
`--preserve` and `--backup` options request the other preservation strategies.
