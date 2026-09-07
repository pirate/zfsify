# Root backup and restore recording

Recorded on real DigitalOcean Droplets on 2026-09-07. The conversion did not run on the recording workstation.

- Source: Ubuntu 24.04 amd64, BIOS boot, 1 vCPU, 1 GiB RAM, 25 GiB included disk, `sfo3`.
- Original root: ext4 `/dev/vda1`, **60.99% used** by the installer's byte-based calculation (`df -h` rounds this to 62%).
- Backup destination: a separate DigitalOcean Ubuntu 22.04 Droplet, 512 MiB RAM and 10 GiB included disk, running `rclone serve sftp`. It stays online while the source boots into RAM.
- Data fixture: a 12,500 MiB allocated zero-filled file, a text file, a hard link, and a user xattr. The filler is intentionally highly compressible; these transfer speeds and archive sizes are not a benchmark for incompressible application data.
- Tested development installer SHA-256: `d485da9968b0db2237211c371cabdaf73db19cbf195af7eebf10b757fb394c81`.
- The command downloads that exact bundle from a temporary HTTP server bound to the source Droplet's loopback address.

The recording starts with the no-flag root command, selects **A** at the high-usage warning, completes **rclone's native interactive configuration**, and chooses `backup:recordings`. The hidden password is absent from the recording. rclone owns the remote configuration; zfsify does not ask its own SFTP/S3 credential questions.

`rclone-root-full.cast` contains the actual PTY output, including staging and reconnects. Explicit recording notes identify the SSH boundaries. `rclone-root.cast` and `rclone-root.gif` are edited presentations: editorial headings, selected verbatim output, wrapped lines, an accelerated countdown, and omitted package chatter/idle waits. `rclone-root-selection.json` identifies the excerpts and source times where available. No successful commands, progress values, speeds, or checksums are invented.

This demonstrates the SFTP backend on DigitalOcean. It is not a test of S3 permissions, other rclone backends, another provider, or the provider's browser recovery console.

## Recorded result

The same run completed without manual migration intervention. The 981.028 MiB archive was downloaded completely and checksum-verified before the disk was erased, then restored and checksum-checked again. Ubuntu rebooted through ZFSBootMenu with both `/` and `/boot` on `rpool/ROOT/ubuntu`; `zpool status -x` reported all pools healthy. Both original file hashes passed, the hard link count remained two, and `rpool/ROOT/ubuntu@zfsify-installed` was present.

The full PTY timeline is 1102.8 seconds including interactive configuration and reconnect waits. The edited cast is 75.7 seconds; the rendered GIF is 74.7 seconds. The GIF is approximately 443 KiB, rendered with `agg` using the GitHub dark theme, 110 columns, 32 rows, 16 px text and a 12 fps cap.

The temporary backup Droplet was deleted after the successful restore (DigitalOcean returned HTTP 404 when read back). The converted source and its SSH key were handed to the primary task for the separately requested provider-console recording.
