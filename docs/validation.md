# Validation records

Runtime validation runs on DigitalOcean Droplets. Each report identifies the
installer checksum, machine configuration, checks performed, and remaining limits.

| Report | Coverage |
|---|---|
| [Fresh reinstall](validation-reinstall.md) | Ubuntu 24.04 amd64, BIOS, 4 GiB RAM, 80 GB disk; root and boot on ZFS, SSH, networking, snapshots, kernel package reinstallation, and reboot |

The reinstall report applies to the checksum recorded in that document. It does
not establish runtime validation for the current preservation, identity-restoration,
progress, or automatic-growth code. Those paths require their own DigitalOcean
acceptance results before they can be described as tested.
