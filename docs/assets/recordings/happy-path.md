# Root conversion recording

A real DigitalOcean Ubuntu 24.04 x86-64 Droplet was converted from ext4 to ZFS on its included 25 GB boot disk, using 1 GiB RAM and no swap. Root was 8.50% used at startup (`df` rounded this to 9%). A pre-existing project with a 128 MiB random data file and a README survived with matching SHA256 hashes.

- [GIF preview](happy-path.gif): 1103 × 660, about 425 KiB, 38 seconds.
- [Edited asciicast](happy-path.cast): the same selected output, with editorial headings.
- [Full captured asciicast](happy-path-full.cast): about 11 minutes 48 seconds of real timestamped SSH output, including automatic reconnection across both reboots.
- [Selection manifest](happy-path-selection.json): exact selected terminal text and its source timestamps.
- [RAM rescue SSH evidence](happy-path-ram-ssh.txt) and [postboot evidence](happy-path-postboot.txt).

Recorded on 2026-09-07. The installer was a development build with SHA256:

```text
d485da9968b0db2237211c371cabdaf73db19cbf195af7eebf10b757fb394c81
```

The exact command was run against a loopback HTTP server on the disposable Droplet:

```bash
curl -fsSL http://127.0.0.1:8765/reformat.sh | bash
```

The recorded command identifies the exact installer bytes. Fixture creation and the private loopback server were prepared before recording. The installer itself ran from the recorded command without manual intervention.

The GIF and edited cast accelerate the genuine 15-second countdown and select actual installer output. Package-manager chatter, long waits, and reboot downtime are shortened or omitted. Editorial headings and reconnect cards are labeled; byte counts, throughput, IOPS, device names, and command results come from the actual run. Lines are wrapped for readability. The full cast retains the captured output and original timestamps; its idle-time hint allows a player to shorten inactivity.

SSH reconnected successfully to the compressed RAM rescue with `UsePAM yes`. After installation, `/` and Ubuntu `/boot` mounted from `rpool/ROOT/ubuntu`, the pool was ONLINE, the initial recovery snapshot existed, and no systemd units were failed. The kernel command line showed ZFSBootMenu's ZFS root selection. This recording does not show interaction with DigitalOcean's browser Recovery Console.

Rendered locally with `agg 1.9.0`, using the `github-dark` theme, 16 px font, 110 columns × 32 rows, and 1.25 line height. Installer execution and acceptance were performed only on DigitalOcean.

The owned demo Droplet (`598403298`) and uploaded SSH key (`59168045`) were deleted after capture; subsequent uncached DigitalOcean API reads returned HTTP 404 for both. The local private key and its public-key file were removed. No other cloud resources were touched.
