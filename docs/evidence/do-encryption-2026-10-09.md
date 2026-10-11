# DigitalOcean encryption acceptance — 2026-10-09

Disposable DigitalOcean Droplets in SFO3 used Ubuntu 24.04 amd64, BIOS boot,
1 GiB RAM and a 25 GiB boot disk. No attached volumes were used. Production
Droplets were not modified.

The packaged installer SHA-256 is
`7f9e233be7409fbd568264374fd52853ff537f7cd2ded120e595e8baa9e157b8`.

## Encrypted preservation

The normal 50/50 conversion with `--yes --encrypt` and a supplied environment
key booted into `rpool/ROOT/ubuntu`. The temporary plaintext boot hook unlocked
the native AES-256-GCM pool. Preservation checks covered file contents, users,
shadow entries, SSH host keys, ACLs, extended attributes, hard links, sparse
files and configuration. The pool occupied the remainder of the boot disk and
scrub reported zero errors.

The same checks passed after a normal reboot and again after rebuilding every
Ubuntu initramfs and rebooting. Encryption verification confirmed inherited
encryption, the expected key source, and root-only key/initramfs permissions.
[Captured verification output](do-encryption-preserve-2026-10-09.txt).

## Console selection

The stock image supplied both `console=tty1` and `console=ttyS0`. ZFSBootMenu
uses the last console argument for interaction, which put its passphrase prompt
on serial instead of the provider's display console. The installer now orders
an existing active graphical console last for rescue and ZFSBootMenu when a
framebuffer or VGA console is available. Serial-only systems and the final
Ubuntu command line retain their original ordering.

The final package booted its RAM environment with `console=ttyS0` followed by
`console=tty1`; `/proc/consoles` confirmed `tty1` controlled `/dev/console`.
Linux regression tests cover graphical/serial combinations, inactive displays,
quoted console arguments, and GRUB syntax.

Manual passphrase entry in the DigitalOcean browser console is still pending:
the browser login expired during testing. This report does not claim that
interactive check has passed.

## Other checks

- 17 encryption, 17 strategy and 12 progress tests pass.
- Linux boot-argument, GRUB syntax and network replay checks pass.
- Shell syntax, focused ShellCheck and packaged installer integrity pass.
- An earlier HTTPS-key attempt stopped before disk mutation when its test
  server was unavailable. The original ext4 root remained bootable. After the
  endpoint became available, TLS-verified key retrieval in RAM succeeded.

The preceding installer build
`d9a2aeda6d26f33fb9c7e586f18e057156d97046a04e931a1b8a3fde5a276005`
also passed encrypted preservation, automatic reboots, and an initramfs rebuild
followed by reboot. A wrapping-passphrase change took 0.358 seconds; this does
not establish revocation of old disk copies. These results preceded the
console-order fix and are not substituted for final-build acceptance.
