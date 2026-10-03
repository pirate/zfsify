#!/usr/bin/env python3
"""Optional root encryption. Secrets are acquired only in the RAM rescue OS."""
import argparse
import getpass
import json
import os
from pathlib import Path
import resource
import signal
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
    value = urllib.parse.urlsplit(url)
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


def configure(mode, url, yes, output):
    if url:
        validate_url(url)
        if mode == 'off':
            raise ValueError('--no-encrypt conflicts with --encrypt-key-url.')
        mode = 'on'
    if mode == 'auto':
        if yes:
            mode = 'off'
        else:
            from strategy import choose, heading
            heading('Encrypt the new ZFS root filesystem?')
            mode = {'1': 'off', '2': 'on'}.get(choose(
                '  1) No encryption [default]\n'
                '  2) Encrypt / and /boot; enter a passphrase in RAM rescue\n'
                '     Each subsequent boot requires unlocking in the preboot console.\n'
                '  q) Cancel', '1', ['1', '2', 'q']))
            if mode is None:
                raise ValueError('Cancelled.')
    if mode == 'on':
        if yes and not url:
            raise ValueError('--yes --encrypt requires --encrypt-key-url=https://host/path. '
                             'Without --yes, enter the passphrase in RAM rescue.')
        print('Encryption: AES-256-GCM for / and /boot. ZFSBootMenu requires a passphrase at every boot.\n'
              'The bootloader remains unencrypted. Old ext4 remnants and external backups are not erased/encrypted.',
              file=sys.stderr)
        if url:
            print('The RAM installer will fetch the passphrase over HTTPS. The URL is not a secret; '
                  'control access at your key server. Keep the same passphrase available for interrupted rescue.\n'
                  'This URL is used during conversion only, not for automatic unlocking on later boots.', file=sys.stderr)
        else:
            print('After the rescue reboot, enter the passphrase in the console, or reconnect via SSH and run:\n'
                  '  zfsify-unlock\nNo passphrase is saved in the staged rescue image.', file=sys.stderr)
    output.write_text(json.dumps({'enabled': mode == 'on', 'key_url': url}) + '\n')


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    config = sub.add_parser('configure')
    config.add_argument('--mode', choices=['auto', 'on', 'off'], default='auto')
    config.add_argument('--key-url', default='')
    config.add_argument('--yes', action='store_true')
    config.add_argument('--output', type=Path, required=True)
    sub.add_parser('acquire')
    sub.add_parser('prompt')
    args = parser.parse_args()
    if args.action == 'configure':
        configure(args.mode, args.key_url, args.yes, args.output)
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
