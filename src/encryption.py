#!/usr/bin/env python3
"""Optional root encryption; plaintext bootstrap keys require explicit selection."""
import argparse
import getpass
import json
import os
from pathlib import Path
import resource
import secrets
import signal
import shlex
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import warnings

CONFIG = Path('/etc/zfs-on-boot/encryption.json')
KEY = Path('/run/zfsify-encryption/rpool.key')


def validate_url(url):
    try:
        value = urllib.parse.urlsplit(url)
    except ValueError:
        # urlsplit errors can include the supplied netloc, including credentials.
        raise ValueError('Invalid HTTPS key URL.') from None
    if (value.scheme != 'https' or not value.hostname or value.username is not None
            or value.password is not None or value.query or value.fragment
            or any(c.isspace() for c in url)):
        raise ValueError('Use an HTTPS key URL without credentials, query, fragment, or whitespace. '
                         'The URL is stored on the unencrypted rescue disk; restrict access at the key server.')
    return url


def validate_key(data):
    # A single optional line ending is convenient for ordinary text key files.
    if data.endswith(b'\n'):
        data = data[:-1]
        if data.endswith(b'\r'):
            data = data[:-1]
    if not 8 <= len(data) <= 512 or any(c in data for c in (b'\0', b'\n', b'\r')):
        raise ValueError('Use a single-line passphrase of 8–512 UTF-8 bytes.')
    data.decode('utf-8')
    return data


def boot_key_warning():
    print('\033[1;31m\n!!! PLAINTEXT BOOT KEY: THIS DEFEATS DISK ENCRYPTION !!!\n'
          'Anyone with the boot disk or its snapshots can decrypt this server.\n'
          'Temporary bootstrap only. Later remove this file and change the passphrase.\n'
          'That is fast, but DOES NOT revoke old disk copies or an exposed data key.\n'
          'For forensic protection, rewrite under a fresh encryption root and\n'
          'retire old copies. Passphrase rotation alone cannot provide that.\n'
          'Then use a person or remote key source at boot.\n'
          'https://pirate.github.io/zfsify/docs/encryption#temporary-plaintext-boot-key\n'
          '\033[0m', file=sys.stderr)


def configure(mode, url, yes, output):
    key = os.environ.get('ZFSIFY_ENCRYPT_KEY')
    boot_key = key is not None
    if url or boot_key:
        if mode != 'on':
            raise ValueError('Key sources require explicit --encrypt.')
        if url and boot_key:
            raise ValueError('Choose one key source: HTTPS or a supplied key.')
        if url:
            validate_url(url)
        else:
            key = validate_key(key.encode()).decode()
    if mode == 'auto':
        if yes:
            mode = 'off'
        else:
            from strategy import choose
            mode = {'1': 'off', '2': 'on', '3': 'temporary'}.get(choose(
                'Choose how this server will unlock at boot.', '1', ['1', '2', '3', 'q'],
                title='Would you like to encrypt your files?', items=[
                    ('1', 'No encryption [default]', 'Boot normally, without a passphrase.'),
                    ('2', 'Encrypt · unlock at each boot', 'Encrypt / and /boot. Enter your passphrase after the rescue reboot; future boots need console unlock.'),
                    ('3', 'Encrypt · temporary automatic unlock', 'Save a plaintext key on this disk: this defeats disk encryption. Generate 16 characters, then save and retype them.'),
                    ('q', 'Cancel', '')]))
            if mode is None:
                raise ValueError('Cancelled.')
    generated = mode == 'temporary'
    if generated:
        mode, boot_key = 'on', True
        boot_key_warning()
        # Deliberately short and hand-transcribable; generated only in the TUI.
        key = ''.join(secrets.choice('ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789') for _ in range(16))
        warnings.simplefilter('error', getpass.GetPassWarning)
        with open('/dev/tty', 'w') as tty:
            print('Temporary key: ' + key + '\nSave this key in your password manager or write it down.', file=tty, flush=True)
            while getpass.getpass('Retype the saved key to continue (no timeout): ', stream=tty) != key:
                print('Key does not match. Save and retype the displayed key.', file=tty, flush=True)
    if mode == 'on':
        if yes and not url and not boot_key:
            raise ValueError('--yes --encrypt requires --encrypt-key-url=https://host/path or '
                             'ZFSIFY_ENCRYPT_KEY / --encrypt-key=KEY. Without --yes, enter the passphrase in RAM rescue.')
        print('Encryption: AES-256-GCM for / and /boot.\n'
              'The bootloader remains unencrypted. Old ext4 remnants and external backups are not erased/encrypted.',
              file=sys.stderr)
        if url:
            print('The RAM installer will fetch the passphrase over HTTPS. The URL is not a secret; '
                  'control access at your key server. Keep the same passphrase available for interrupted rescue.\n'
                  'This URL is used during conversion only, not for automatic unlocking on later boots.', file=sys.stderr)
        if boot_key:
            if not generated:
                boot_key_warning()
            with open(output.parent/'bootstrap.key', 'w', opener=lambda p, f: os.open(p, f, 0o600)) as stream:
                stream.write(key)
            print('Temporary key saved for rescue and automatic boot. Replace it after bootstrap.', file=sys.stderr)
        elif not url:
            print('After the rescue reboot, enter the passphrase in the console, or reconnect via SSH and run:\n'
                  '  zfsify-unlock\nNo passphrase is saved in the staged rescue image.', file=sys.stderr)
        if not boot_key:
            print('ZFSBootMenu requires a passphrase at every boot.', file=sys.stderr)
    output.write_text(json.dumps({'enabled': mode == 'on', 'key_url': url, 'boot_key': boot_key}) + '\n')


def require_rescue():
    if os.geteuid() != 0:
        raise ValueError('Run as root in the zfsify RAM rescue environment.')
    fs = subprocess.check_output(['findmnt', '-n', '-o', 'FSTYPE', '/run'], text=True).strip()
    if fs != 'tmpfs' or not Path('/run/zfsify-encryption-ready').exists():
        raise ValueError('Passphrases may only be supplied after booting the zfsify RAM rescue environment.')
    if len(Path('/proc/swaps').read_text().splitlines()) > 1:
        raise ValueError('Disable disk swap before handling the encryption passphrase in rescue.')
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    os.umask(0o077)
    KEY.parent.mkdir(mode=0o700, exist_ok=True)


def save_key(data):
    data = validate_key(data)
    # Publish only complete keys. The directory is private and lives on tmpfs.
    fd, name = tempfile.mkstemp(dir=KEY.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
        os.replace(name, KEY)
    finally:
        Path(name).unlink(missing_ok=True)


def prompt():
    require_rescue()
    if not json.loads(CONFIG.read_text())['enabled']:
        raise ValueError('Encryption was not selected for this conversion.')
    if KEY.exists():
        raise ValueError('A passphrase has already been supplied to the RAM installer.')
    # Never fall back to echoed input, including when invoked over non-PTY SSH.
    warnings.simplefilter('error', getpass.GetPassWarning)
    while True:
        try:
            data = validate_key(getpass.getpass('ZFS passphrase (also used for future boots): ').encode())
            if getpass.getpass('Confirm passphrase: ').encode() != data:
                print('Passphrases differ. Try again.', file=sys.stderr)
                continue
            save_key(data)
            print('Passphrase delivered to the RAM installer. Follow progress with zfs-on-boot-status.')
            return
        except ValueError as error:
            print(str(error), file=sys.stderr)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError('Key URL redirects are not allowed. Use the final HTTPS URL.')


def acquire():
    config = json.loads(CONFIG.read_text())
    if not config['enabled']:
        return
    require_rescue()
    if KEY.exists():
        validate_key(KEY.read_bytes())
        return
    if config.get('boot_key') and not config['key_url']:
        save_key((CONFIG.parent/'bootstrap.key').read_bytes())
        return
    if config['key_url']:
        validate_url(config['key_url'])
        # No inherited proxies or redirect downgrade; normal TLS certificate verification.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        try:
            with opener.open(config['key_url'], timeout=30) as response:
                save_key(response.read(515))
        except Exception:
            # Never echo server response bodies, URLs, or key material into logs.
            raise ValueError('Unable to obtain a valid passphrase from the HTTPS key server. '
                             'No further migration will run; restore key-server access before resuming the rescue boot.') from None
        print('Encryption passphrase received in RAM.')
        return
    print('Waiting for encryption passphrase. Use this console, or SSH in and run zfsify-unlock.', flush=True)
    with open('/dev/console', 'r+b', buffering=0) as console:
        child = subprocess.Popen([sys.executable, __file__, 'prompt'], stdin=console,
                                 stdout=console, stderr=console, start_new_session=True)
        try:
            while not KEY.exists():
                if child.poll() is not None:
                    # An unavailable console still allows the explicit SSH helper.
                    print('Console input closed; waiting for zfsify-unlock over SSH.', flush=True)
                    while not KEY.exists():
                        time.sleep(.25)
                    break
                time.sleep(.25)
        finally:
            if child.poll() is None:
                child.send_signal(signal.SIGINT)  # getpass restores terminal echo in finally.
            child.wait()
    validate_key(KEY.read_bytes())


def install_boot_hook(output):
    config = json.loads(CONFIG.read_text())
    if not config.get('boot_key'):
        return
    require_rescue()
    if not config['enabled']:
        raise ValueError('A boot key requires encryption.')
    key = validate_key(KEY.read_bytes()).decode('utf-8')
    output.parent.mkdir(parents=True, exist_ok=True)
    # A shell builtin feeds stdin: the secret is never a process argument.
    hook = ('#!/bin/sh\nset +x\n'
            '[ "${ZBM_ENCRYPTION_ROOT:-}" = rpool ] || exit 0\n'
            "printf '%s' " + shlex.quote(key) +
            ' | zfs load-key -L file:///dev/stdin rpool\n')
    with open(output, 'w', opener=lambda p, f: os.open(p, f, 0o700)) as stream:
        stream.write(hook)
    boot_key_warning()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    config = sub.add_parser('configure')
    config.add_argument('--mode', choices=['auto', 'on', 'off'], default='auto')
    config.add_argument('--key-url', default='')
    config.add_argument('--yes', action='store_true')
    config.add_argument('--output', type=Path, required=True)
    hook = sub.add_parser('boot-hook')
    hook.add_argument('--output', type=Path, required=True)
    sub.add_parser('acquire')
    sub.add_parser('prompt')
    args = parser.parse_args()
    if args.action == 'configure':
        configure(args.mode, args.key_url, args.yes, args.output)
    elif args.action == 'boot-hook':
        install_boot_hook(args.output)
    elif args.action == 'prompt':
        prompt()
    else:
        acquire()


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, getpass.GetPassWarning, EOFError, KeyboardInterrupt) as error:
        print(f'zfsify: {error or "Passphrase input cancelled."}', file=sys.stderr)
        sys.exit(2)
