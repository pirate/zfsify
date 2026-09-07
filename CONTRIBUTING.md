# Contributing

Small, inspectable changes and evidence from disposable DigitalOcean Droplets
are welcome. Keep destructive behavior explicit and document the exact supported
configuration. Never test this installer on a workstation or a valuable server.

The root installer lives in `src/` and is distributed as `reformat.sh` and its
`install.sh` alias. The [volume toolkit](docs/volumes.md) lives in the root-level
shell scripts and uses `DO_API_TOKEN` for provider operations. The installer test
harness uses `DIGITALOCEAN_TOKEN`; installation itself needs no cloud API token.

## Package the installer

The source of truth is the files in `src/`. Packaging only embeds
those files; it does not install Ubuntu or change the controller's disk layout.

```sh
python3 scripts/package.py
```

Commit the generated installer and checksum together with their source changes.
The installed Ubuntu package set can change as signed Ubuntu
repositories publish updates, even when the shell script is unchanged.

## Test on DigitalOcean

The harness creates a billable `s-2vcpu-4gb` Ubuntu 24.04 Droplet and a temporary SSH
key, installs the packaged script there, verifies the result and another reboot,
then deletes its recorded cloud resources. Requires Python 3, curl, OpenSSH, and a
DigitalOcean token supplied through `DIGITALOCEAN_TOKEN`. Set it in your environment
without putting the value in source, command examples, or logs.

```sh
bash scripts/do-e2e.sh
```

All installer runtime testing belongs on DigitalOcean; do not run the installer
locally. `scripts/verify-snapshot.sh` is an additional check to run on the owned test
Droplet: it creates a test snapshot and clone, verifies their contents, and removes
those objects. The automated harness does not cover every manual check in the
[recorded validation](docs/validation.md), such as kernel package reinstallation.

For debugging, `KEEP_TEST_DROPLET=1 bash scripts/do-e2e.sh` retains resources. They
continue to incur charges until deleted. The harness prints a private evidence
directory containing `resources.json` and the temporary SSH key. Clean up using:

```sh
python3 scripts/do-test.py destroy --state /path/to/evidence/resources.json
```

Inspect any cleanup failure and delete remaining owned resources through
DigitalOcean if needed. Never publish API tokens, temporary private keys,
machine-specific RAM archives, or unreviewed logs. Sanitize provider identifiers
and network details before adding evidence to a pull request.

## Useful contributions

- A reproducible DigitalOcean failure with sanitized logs and image/plan details.
- Migration recovery and interrupted-operation handling.
- Additional disk layouts backed by migration and expansion evidence.
- UEFI or additional provider support backed by real deployment evidence.

Keep unvalidated configurations labeled as such. Include the packaged installer
checksum, package/kernel versions, disk layout, and post-reboot results when
reporting a successful installation.
