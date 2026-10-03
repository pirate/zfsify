# Native root encryption validation — 2026-10-03

Test environments: Ubuntu 24.04, 1 GiB RAM, 25 GiB disk; native ARM64
QEMU/HVF with UEFI, and a disposable DigitalOcean amd64 Droplet with BIOS.
The booted ARM64 guests used kernel `6.8.0-146-generic` and OpenZFS
`2.2.2-0ubuntu9.5`.

| Path | Result |
|---|---|
| ARM64 preserve (50/50) | Preserved files, accounts, SSH keys, ACLs, xattrs, hard links and sparse files; encrypted root boot and subsequent reboot passed. The first run exposed a duplicate initramfs-key hook error before releasing the original ext4 data; the hook was repaired and that run resumed. |
| ARM64 erase | Clean packaged conversion and subsequent reboot passed; bounded-restoration and encryption verifiers passed. |
| ARM64 slice conversion | Clean packaged conversion, full copy and post-remap manifest verification, encrypted root boot and subsequent reboot passed; preservation and encryption verifiers passed. |
| ARM64 boot maintenance and recovery | Initramfs rebuild and reboot passed with initramfs-tools and dracut. Booting a clone of the installed root snapshot passed. |
| DigitalOcean BIOS slice conversion | SSH passphrase entry, interruption at the persistent copy checkpoint, wrong-key rejection, correct-key resume, full manifest verification, remap, final boot configuration, snapshot creation and reboot completed. Final ZFSBootMenu console unlock and Ubuntu boot remain **unverified** because browser sign-in was unavailable. |

ARM64 guests passed the general guest verifier and zero-error pool scrubs.
The encryption verifier checked inherited AES-256-GCM encryption, key location,
ZFSBootMenu keysource, root-only key/initramfs permissions and key inclusion in
the final Ubuntu initramfs. Subsequent boots used console passphrases, without
a permanent network key-fetch service.

DigitalOcean's wrong-key attempt left `keystatus=unavailable`, removed the RAM
key file and kept the copy checkpoint paused. Correct input resumed conversion.
Its staged rescue image included the initramfs-hook repair; this was not an
unmodified installer end-to-end run. One initial rescue boot did not return SSH;
a power cycle returned to ext4 and a later rescue boot worked. The cause was not
established.

The clean ARM64 erase and slice runs used installer SHA256:

```text
c7fd17b5a470075cda4dfbd212f9b694fc5c0d8616060ec7d4197c753a480e19
```

Later changes to malformed-URL diagnostics and removal of the rescue-only unlock
helper from erase installs were covered by unit tests and a live guest cleanup
check, respectively; those changes did not receive another complete conversion.

Local checks passed: 12 encryption tests, 15 strategy tests, 9 progress tests,
shell syntax, focused ShellCheck and `git diff --check`. The encryption tests
include real controlling-terminal input, hidden passphrases, URL validation,
RAM-only key handling and duplicate initramfs-key handling.

Encrypted external-backup restoration, Ubuntu 22.04/26.04 and 512 MiB guests were
not tested in this round. Earlier unencrypted results do not establish those
encrypted configurations. All disposable VMs, Droplets, test SSH keys and secret
files were removed after testing; production servers were not changed.
