# Experimental conversion with less free space

`--inplace` is an experimental root migration backend. It keeps zfsify's Ubuntu
packages, RAM rescue, ZFSBootMenu, snapshots, and disk-growth setup. It uses
Ubuntu's `fstransform` package for **`fsremap`**, the physical block mover; it
does not require a fork of fstransform or a permanent storage-mapping layer.

Use only a disposable VM:

```sh
curl -fsSL https://raw.githubusercontent.com/pirate/zfsify/refs/heads/experiment/inplace-zfs/reformat.sh | sudo bash -s -- --inplace
```

The prototype requires the existing supported GPT/ext4 root layout, UEFI, and a
separate ext4 `/boot` before the root partition. The normal staging requirements
still apply, including 3.5 GB free on `/` and 500 MB free on `/boot`. There is no
50% gate for this mode, but enough space must remain for filesystem overhead and
the final ZFS data. A universal minimum free-space percentage is not established.

## What happens

1. Boot the existing RAM rescue and save a file hash/metadata manifest on `/boot`.
2. Create a sparse ZFS image inside the original ext4 filesystem.
3. Copy in 64 MiB batches with a small memory buffer. Flush and verify each batch,
   commit its checkpoint, then punch holes in the original file to reuse its space.
   Trim unused blocks in the temporary ZFS image when ext4 needs more room.
4. Verify all files, export ZFS, and let `fsremap` rearrange the image's blocks
   onto the original partition. Its journal and 32 MiB secondary scratch file
   live on the existing boot filesystem on the same disk.
5. Import the native ZFS partition, verify the manifest again, and finish the
   usual Ubuntu boot setup. The existing area before root becomes the EFI
   partition; its size may exceed the normal installer's 512 MiB.

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

- Ubuntu 24.04 ARM64, 1 GiB RAM, 25 GiB boot disk, about 74% used: unattended
  root conversion, all 123,526 manifest entries verified before and after remapping,
  ZFSBootMenu boot, normal reboot, preservation checks, and scrub. No extra writable disk.
  [Root acceptance](evidence/inplace-root-acceptance.txt).
- An 8 GiB disk at 76% usage, with a 6000 MiB file: interrupt the mover after
  freeing source blocks, resume, remap, verify metadata/hashes, and scrub.
  [Mover acceptance](evidence/inplace-mover-acceptance.txt) ·
  [Repeat the disposable-VM test](../scripts/test-inplace-mover.sh).
- [CLI checks](evidence/inplace-cli-acceptance.txt) cover unusual filenames,
  malformed progress output, and completed byte totals.

## Limits

Original data is released progressively, so there is no retained complete ext4
copy. The file mover records checkpoints outside root, and fsremap maintains its
own journal, but **automatic recovery after power loss is not implemented or
validated**. Existing Ubuntu cannot simply boot midway through this conversion.
The separate boot filesystem also gets replaced after a successful remap.

Do not use this prototype on a server holding needed data. The normal
preservation and external-backup modes remain available without `--inplace`.
