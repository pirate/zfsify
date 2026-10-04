# Temporary boot key validation — 2026-10-04

Disposable ARM64 QEMU/HVF guest: Ubuntu 24.04.5, UEFI, 1 GiB RAM, 25 GiB disk.
No production machines were changed.

- Full 50/50 conversion with a plaintext ZFSBootMenu load-key hook completed.
  The guest booted into encrypted ZFS automatically, without console input.
- General root, preservation and encryption verifiers passed. File hashes,
  accounts, SSH keys, ACLs, xattrs, hard links and sparse files were retained.
  The pool scrub reported no errors.
- Executed the passphrase-change procedure in `docs/encryption.md`, rebuilt the
  Ubuntu initramfs and removed the plaintext hook from the mounted ESP.
  On reboot, ZFSBootMenu waited for input. Entering the new passphrase booted
  Ubuntu successfully; the encryption and preservation verifiers passed and a new recovery
  snapshot was created. The rotation used `zfs change-key`, without copying data.
- Recorded the final encryption TUI inside the guest. Its temporary key contains
  16 alphanumeric characters and requires saving/retyping. The generated key in
  this UI recording is disposable and was never used on a production server.
- 17 encryption tests cover explicit CLI/environment consent, secret redaction,
  TUI mismatch/cancellation, saved-key confirmation, resume reuse and literal
  shell metacharacters in hook keys. Existing 15 strategy and 9 progress tests,
  shell syntax, focused ShellCheck and whitespace checks pass.

The full conversion was started before the final key-entry interface revisions;
its boot-hook installation and encrypted boot path match the final implementation.
The final supplied-key/generate-and-retype interface was tested separately in the
same guest and in controlling-terminal tests. The recordings contain real guest
terminal output, with long idle gaps shortened in the boot recordings.

This round did not repeat BIOS/DigitalOcean or test the proposed phone web UI.
Earlier DigitalOcean final-console validation remains outstanding. The phone
workflow is research documentation, not a shipped service. Test VM disks and
keys are removed after verification; only nonsecret test evidence is retained.
