# Validation and recordings

The [ZFSBootMenu validation report](validation-zfsbootmenu.md) records the tested
Ubuntu releases, memory sizes, disk layouts, installer checksums, and remaining
limits. Runtime validation uses disposable DigitalOcean infrastructure.

| Workflow | Evidence |
|---|---|
| Preserve Ubuntu and boot from ZFS | [Root conversion recording](recordings.html?demo=root), [512 MiB acceptance](validation-zfsbootmenu.md) |
| Reinstall with bounded priority restoration | [Erase-mode acceptance](validation-zfsbootmenu.md) |
| Back up a full root drive with rclone, convert, and restore | [Interactive recording](recordings.html?demo=rclone), [backup acceptance](validation-zfsbootmenu.md) |
| Convert an attached ext4 Volume without rebooting | [Volume recording](recordings.html?demo=volume), [capture and verification notes](assets/recordings/volume-provenance.md) |
| Initialize an empty attached Volume | [Explicit erase-mode acceptance](validation-zfsbootmenu.md) |
| Expand root and data pools after a provider disk resize | [Automatic expansion evidence](validation-zfsbootmenu.md) |
| Boot a snapshot clone and take automatic snapshots | [Recovery and snapshot evidence](validation-zfsbootmenu.md) |
| Restore RAM networking with gateway host routes and renamed NICs | [DigitalOcean network regression](evidence/network-route-replay.txt) — targeted route replay, not a full conversion |
| Preserve hardware/console boot arguments and NIC MTUs | [Boot portability acceptance](evidence/boot-portability.txt) — full DigitalOcean conversion and subsequent reboot |

The recordings offer selected highlights and full terminal captures. Their notes
identify the installer build, fixture, timing edits, and acceptance results.
They contain real command output; preview headings are editorial.

The [cloud-init templates](cloud-init.md) invoke the same installer after first-boot
configuration. Their first-boot scheduling has not been separately tested end to
end. Advanced pool-management and provisioning helpers have separate limitations
in the [volume guide](volumes.md).

DigitalOcean resize tests included enlarging the actual disk and booting normally;
the installed services expanded the partition and ZFS pool without guest growth
commands. CPU/RAM-only resizes do not increase disk capacity. Provider support is
limited to the configurations actually recorded, rather than every image or VPS
layout offered by a provider.

## Archived test records

These reports retain results for their identified checksums and configurations.
They are evidence, not setup instructions or claims about the current installer.

- [GRUB-based preservation, erase, and disk expansion](evidence/archive/validation-preserve-erase.md)
- [GRUB-based fresh installation and kernel maintenance](evidence/archive/validation-reinstall.md)
