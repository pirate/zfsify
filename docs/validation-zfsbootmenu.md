# ZFSBootMenu and low-memory validation

Runtime tests run on disposable DigitalOcean infrastructure only. No installer,
VM, filesystem migration, or formatting test ran on the development workstation.
Results below were collected on 2026-09-07 UTC.

## Completed checks

| Test | Configuration | Result |
|---|---|---|
| Unattended preservation | Ubuntu 22.04 amd64, BIOS, 512 MiB / 10 GiB Droplet | Passed conversion, ZFSBootMenu boot, all fixtures, and another reboot |
| Fresh install with priority restore | Ubuntu 22.04 amd64, BIOS, 512 MiB / 10 GiB Droplet, 55% used | Passed unattended `--erase`, accounts/SSH/configuration and bounded complete-file restore, then another reboot |
| Unattended preservation | Ubuntu 24.04 amd64, BIOS, 1 GiB / 25 GiB Droplet | Passed complete recorded conversion, RAM SSH access, preserved hashes, ZFS boot, and initial snapshot |
| Root archive backup and restore | Ubuntu 24.04, 1 GiB, 61% used; separate DigitalOcean SFTP server | Passed recorded interactive rclone configuration, offline upload, full read-back verification, restore, ZFS boot, hashes and hard links |
| UEFI root preservation | Ubuntu 24.04, 1 GiB / 20 GiB KVM guest hosted on a DigitalOcean Droplet, OVMF | Completed preservation and booted from its ZFSBootMenu EFI entry; `/` and `/boot` on ZFS, ESP mounted at `/boot/efi` |
| Boot-disk resize | Converted Ubuntu 24.04 Droplet, 25 → 50 GiB | Next boot expanded partition and rpool automatically; no guest growth command; fixture hashes passed |
| Data-volume preservation | Whole-device ext4, 2 GiB DigitalOcean Volume | Converted in place; hashes, hard links, sparse allocation, ACLs and xattrs passed |
| Data-volume resize | Converted data volume, 2 → 3 GiB | Boot service expanded partition/pool; files passed |
| Data-volume rclone backup | More than half-full 1 GiB ext4 Volume; rclone SFTP transport | Backup read-back, ZFS conversion, restore, hashes, ACLs and xattrs passed |
| Empty data-volume initialization | Blank 1 GiB DigitalOcean Volume | Explicit `--erase` created an empty ZFS filesystem with automatic growth configured |
| Snapshot recovery | Deliberately removed original `/sbin/init`; booted a clone of a prior snapshot | ZFSBootMenu booted the recovery clone, files passed; repaired and returned to original environment |
| Snapshot retention | Created 16 APT snapshots plus a manual snapshot | Kept 14 automatic snapshots, preserved manual snapshot; daily timer enabled |
| APT snapshot hook | Reinstalled the Ubuntu `hostname` package | Actual APT/dpkg operation automatically created a new root snapshot |

The clean 512 MiB preservation run used installer SHA-256
`4b69c86355d5afc3081c80edb0c4e64ef572bad85660185d4200555ec8fc0bd2`.
Each run records its own installer checksum; coverage applies to the identified
configuration and scenario.

The clean 512 MiB erase run used installer SHA-256
`d485da9968b0db2237211c371cabdaf73db19cbf195af7eebf10b757fb394c81`.

Root resize evidence records the actual kernel-visible disk size changing to
53,687,091,200 bytes and the pool growing to 52,613,349,376 bytes. The firmware
partition is 512 MiB. ZFS owns the remaining partition, with its normal overhead.

## Recovery evidence and limits

The recovery test used the actual ZFSBootMenu boot path, with the recovery clone
selected through the pool's bootfs property before reboot. It proved that an
older environment with its own init, kernel and modules can boot independently
of the damaged default environment. DigitalOcean's actual browser Recovery
Console was also used to open the boot-environment and snapshot menus; see the
[console screenshots](recovery.md#digitalocean-console-screenshots). Those captures
do not establish a complete interactive clone-and-boot recovery run.

The SFTP archive test used rclone's SFTP server on the same DigitalOcean test
host, with the destination on a separate Volume and a localhost-only endpoint.
It exercises rclone's transport, configuration, streaming, read-back and restore,
not S3-specific permissions or every rclone backend.

## Runtime configuration

The rescue environment uses compressed SquashFS in RAM. On 512 MiB systems it
bounds ARC and dirty writes and reclaims clean caches under memory pressure.
A fresh-install copy reads the immutable image so SSH/PAM activity cannot change
its source. GRUB removal runs noninteractively and restricts package removal to
the boot stack. UEFI chroot cleanup recursively unmounts EFI-variable submounts.

The UEFI run used installer SHA-256
`7a7a193846b57658cc88f354c28f877ebbfc52f92b25f1de1c26b6ef44e40fc6`.
This is a nested VM on DigitalOcean infrastructure, not a provider-native UEFI
Droplet or evidence for another cloud provider. Cloud-init scheduling and the
advanced multi-disk helpers have not been separately validated end to end.

## Evidence

- [UEFI preservation and boot](evidence/zbm-uefi-boot.txt)
- [Recorded Ubuntu 24.04 root conversion](assets/recordings/happy-path.md)
- [Recorded root rclone backup and restore](assets/recordings/rclone-root-provenance.md)
- [512 MiB clean conversion](evidence/zbm-512-clean-acceptance.txt)
- [512 MiB subsequent reboot](evidence/zbm-512-clean-reboot.txt)
- [512 MiB erase and priority restore](evidence/zbm-erase-final-acceptance.txt)
- [512 MiB erase subsequent reboot](evidence/zbm-erase-final-reboot.txt)
- [Root backup restore](evidence/zbm-root-backup-acceptance.txt)
- [Automatic root expansion](evidence/zbm-root-resize-zbm-acceptance.txt)
- [Data-volume preservation](evidence/zbm-volume-acceptance.txt)
- [Automatic volume expansion](evidence/zbm-volume-resize-acceptance.txt)
- [Data-volume rclone restore](evidence/zbm-data-backup-acceptance.txt)
- [Blank volume initialization](evidence/zbm-blank-volume-acceptance.txt)
- [Actual APT snapshot hook](evidence/zbm-apt-hook-acceptance.txt)
- [Snapshot retention](evidence/zbm-snapshot-retention-acceptance.txt)
- [Recovery clone boot](evidence/zbm-recovery-clone-boot.txt)
- [Return to the original environment](evidence/zbm-recovery-return.txt)

Machine-specific rescue images, backup archives, SSH private keys, rclone
credentials, and unreviewed logs are not publication artifacts.
