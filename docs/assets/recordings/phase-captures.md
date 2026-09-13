# Terminal captures — 2026-09-13

Eight previews contain actual installer/status output, without title cards.
`raw/*.cast.gz` retains the full source terminal captures. `select-phases.py`
selects excerpts, shortens waits, and slows the choice screen for readability;
`render-cast.py` renders the same terminal output to GIF.

| Preview | Raw capture | Method |
|---|---|---|
| phase-1 | slice-stage | Interactive default slice conversion |
| phase-2 through phase-4 | slice-rescue | Same root conversion |
| phase-5 | slice-ready | Same root conversion |
| two-copy | two-copy-rescue | Root conversion with room for two copies |
| attached-disk | volume | Preserve attached ext4 disk |
| rclone | rclone | Archive, verify and restore attached disk |

The fixtures ran in disposable QEMU/HVF ARM64 UEFI VMs: Ubuntu 24.04,
2 vCPUs, 1 GiB RAM, 25 GiB root disk; attached-disk examples used a 4 GiB disk.
Kernel: 6.8.0-139-generic. ZFS: 2.2.2-0ubuntu9.4.
The slice fixture started at 71% usage; conversion used no external backup.
The rclone example used an explicitly selected directory on the separate root
disk with rclone's local transport; it is not a network/S3 throughput test.
Fixtures, capture scripts, and status connections were prepared outside the clips.

Installer SHA-256:

- Slice: `7c1fdd6592aecf18b39de6e7db92a16c0dc1c2028c5ee5c561ab0e26a566f925`
- Two-copy: `a209a7ae9f09d70d7dd5888513ff639fd4fe591af94b6009885c534cf61abf3a`

Both root runs passed native-ZFS boot, an additional reboot, scrub with zero
errors, and preservation of file bytes, accounts, SSH host keys, ACLs, xattrs,
hard links, sparse files and configuration. Attached-disk preservation and
rclone restore passed checksum checks; explicit noninteractive attached-disk
erasure also completed. All disposable VM disks and keys were removed afterward.

A first two-copy run exhausted memory. The rescue cache guard now also covers
1 GiB guests; the successful captures above use that fix. Final UI-only changes
retain full backup instructions after the dashboard and have targeted test coverage.
No new DigitalOcean conversion was run for this UI update.
