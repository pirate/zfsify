# Validation records

**DigitalOcean Ubuntu 24.04 amd64 is tested end-to-end**, including preservation,
erase with retained identity, root and boot on the included disk's ZFS pool, and
an automatic **80 GB → 160 GB** disk expansion after a normal provider resize and
boot. No special guest commands were needed for expansion.

Runtime validation runs on real DigitalOcean Droplets. Each report identifies the
installer checksum, machine configuration, checks performed, and remaining limits.

| Report | Coverage |
|---|---|
| [Preservation, erase, and automatic resizing](validation-preserve-erase.md) | Current conversion logic: retained file data and metadata, accounts and SSH access, erase semantics, usage gate/countdown/progress, root/boot ZFS, and real DO disk resize |
| [Historical fresh reinstall](validation-reinstall.md) | Earlier checksum: Ubuntu 24.04 amd64, BIOS, 4 GiB RAM, 80 GB disk; root and boot on ZFS, SSH, networking, snapshots, kernel package reinstallation, and reboot |

Support is scoped to the layouts and requirements in the README. Results from a
historical checksum do not establish coverage of later code. The current report
records the exact conversion-tested and published checksums and the final telemetry-only
change, which received its own DigitalOcean regression check.
