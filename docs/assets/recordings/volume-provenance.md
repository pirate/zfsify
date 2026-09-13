# Attached-volume recording

Recorded on a real DigitalOcean Droplet on 2026-09-07 (UTC), using Ubuntu 24.04,
1 GiB RAM, its normal ext4 boot disk, and a separate 1 GiB DigitalOcean Volume.
Only the attached Volume was converted. The operating system kept running and
no reboot was required.

- [GIF preview](volume.gif).
- [Edited asciicast](volume.cast): the same selected terminal output.
- [Full asciicast](volume-full.cast): the complete 53-second scripted terminal recording.
- [Selection manifest](volume-selection.json): exact selected text and source timestamps
  for progress blocks and countdown events.
- [Additional acceptance output](volume-acceptance.txt).

The preview shortens the countdown, omits package-manager chatter, and selects
completed/live phase output. Only captured terminal content is shown; recording
annotations are omitted. Command results, byte counts, rates, IOPS, and device names
are captured output.
The recording is a scripted demonstration with printed commands immediately followed
by execution, rather than a hand-typed shell session.

The exact installer was served from a guest-local HTTP server. The displayed
`curl http://127.0.0.1:8765/reformat.sh | bash -s -- /mnt/data` command is the command
actually executed. Installer SHA-256:

```text
d485da9968b0db2237211c371cabdaf73db19cbf195af7eebf10b757fb394c81
```

Before recording, the fixture was formatted as ext4 and mounted at `/mnt/data`.
It contained 180 MiB of random payload, a hard link to that payload, a 128 MiB
sparse file, configuration/text files, a POSIX ACL, and a user extended attribute.
`df` reported 181 MiB used (20%). The initial package installation was outside
the recording: asciinema and the migration dependencies were already installed.
The installer still performed its normal package-index and dependency phases.

Acceptance demonstrated:

- `/mnt/data` changed from `/dev/sda` ext4 to a ZFS dataset at the same mount point.
- All five file paths passed SHA-256 verification.
- The two payload paths retained the same inode; the 128 MiB sparse file used only
  25 allocated 512-byte blocks afterward.
- The POSIX ACL and user xattr survived.
- The pool was ONLINE, with no known data errors and `autoexpand=on`.
- The enrolled pool's automatic growth service was enabled.
- `/` remained ext4 throughout. This recording does not demonstrate provider resizing;
  that has separate acceptance evidence.

The Droplet, Volume, and API SSH-key registration were deleted after capture;
all three resource lookups returned HTTP 404. The temporary private/public key
files were removed from the recording controller.

To regenerate the edited cast and GIF from the full capture (Pillow required):

```sh
python3 scripts/recordings/volume-render.py docs/assets/recordings docs/assets/recordings

```

The recording command script is retained as
[`scripts/recordings/volume-demo.sh`](../../../scripts/recordings/volume-demo.sh).
It expects the disposable fixture and local HTTP server described above; it is
not an installer entry point.
