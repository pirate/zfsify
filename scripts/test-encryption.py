#!/usr/bin/env python3
"""Key lifecycle and controlling-terminal tests; no host disks are modified."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import pty
import select
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / 'src/encryption.py'
sys.path.insert(0, str(SOURCE.parent))
spec = importlib.util.spec_from_file_location('encryption', SOURCE)
encryption = importlib.util.module_from_spec(spec)
spec.loader.exec_module(encryption)


class EncryptionTests(unittest.TestCase):
    def configure(self, *args):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp)/'config.json'
            result = subprocess.run([sys.executable, str(SOURCE), 'configure',
                                     '--output', str(output), *args], capture_output=True,
                                    text=True, start_new_session=True, timeout=3)
            return result, json.loads(output.read_text()) if output.exists() else None

    def test_default_headless_is_unencrypted(self):
        result, config = self.configure('--yes')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(config, {'enabled': False, 'key_url': ''})

    def test_explicit_modes_do_not_prompt(self):
        for mode in ('on', 'off'):
            result, config = self.configure('--mode', mode)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(config['enabled'], mode == 'on')
            self.assertNotIn('waiting for your selection', result.stderr)

    def test_headless_requires_key_source(self):
        result, config = self.configure('--yes', '--mode', 'on')
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(config)
        self.assertIn('requires --encrypt-key-url', result.stderr)
        result, config = self.configure('--yes', '--key-url', 'https://keys.example.org/root')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(config['enabled'])

    def test_conflicting_options_and_unsafe_urls(self):
        for url in ('http://keys.example.org/key', 'https://user:secret@host/key',
                    'https://host/key?token=secret', 'https://host/key#secret', 'https://',
                    'https://host/key\nsecret'):
            result, config = self.configure('--yes', '--key-url', url)
            self.assertNotEqual(result.returncode, 0)
            self.assertIsNone(config)
            self.assertNotIn('secret', result.stderr.replace('not a secret', ''))
        result, config = self.configure('--mode', 'off', '--key-url', 'https://keys.example.org/root')
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(config)

    def test_key_bytes_not_trimmed_or_truncated(self):
        for data in (b' correct horse ', b'a'*512, b'correct horse\n', b'correct horse\r\n'):
            self.assertEqual(encryption.validate_key(data), data.rstrip(b'\r\n'))
        for data in (b'', b'short', b'a'*513, b'correct\nhorse', b'correct\0horse', b'a'*8+b'\n\n'):
            with self.assertRaises(ValueError): encryption.validate_key(data)

    def test_atomic_key_permissions(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(encryption, 'KEY', Path(tmp)/'rpool.key'):
            encryption.save_key(b'correct horse battery staple')
            self.assertEqual(encryption.KEY.stat().st_mode & 0o777, 0o600)
            self.assertEqual(encryption.KEY.read_bytes(), b'correct horse battery staple')
            self.assertEqual(list(Path(tmp).iterdir()), [encryption.KEY])

    def test_non_rescue_input_refused(self):
        with patch.object(encryption.os, 'geteuid', return_value=0), \
             patch.object(encryption.subprocess, 'check_output', return_value='ext4\n'):
            with self.assertRaisesRegex(ValueError, 'RAM rescue'):
                encryption.require_rescue()

    def test_remote_failure_does_not_leak_response(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, key = Path(tmp)/'config', Path(tmp)/'key'
            config.write_text(json.dumps({'enabled': True, 'key_url': 'https://host/key'}))
            with patch.object(encryption, 'CONFIG', config), patch.object(encryption, 'KEY', key), \
                 patch.object(encryption, 'require_rescue'), \
                 patch.object(encryption.urllib.request, 'build_opener') as opener:
                opener.return_value.open.side_effect = OSError('secret response body')
                with self.assertRaises(ValueError) as error: encryption.acquire()
                self.assertNotIn('secret response body', str(error.exception))
                self.assertFalse(key.exists())

    def test_redirects_refused(self):
        with self.assertRaises(ValueError): encryption.NoRedirect().redirect_request(None, 302, '', {}, 'http://host/key')

    def terminal(self, body, messages):
        pid, fd = pty.fork()
        if pid == 0:
            os.dup2(os.open('/dev/null', os.O_RDONLY), 0)
            os.execv(sys.executable, [sys.executable, '-c',
                f'import sys; sys.path.insert(0,{str(SOURCE.parent)!r}); import encryption as e; '+body])
        data = b''; pending = list(messages); start = time.monotonic()
        try:
            while time.monotonic()-start < 8:
                if pending and pending[0][0] in data:
                    marker, answer = pending.pop(0)
                    os.write(fd, answer)
                if select.select([fd], [], [], .05)[0]:
                    try: chunk = os.read(fd, 65536)
                    except OSError: break
                    if not chunk: break
                    data += chunk
            else:
                os.kill(pid, 9)
                self.fail('PTY test timed out: '+data.decode(errors='replace'))
            _, status = os.waitpid(pid, 0)
            return os.waitstatus_to_exitcode(status), data.decode(errors='replace')
        finally:
            os.close(fd)

    def test_interactive_default_and_enable(self):
        for answer, enabled in [(b'\n', False), (b'2\n', True)]:
            with tempfile.TemporaryDirectory() as tmp:
                output=Path(tmp)/'config'
                rc, out=self.terminal(f'e.configure("auto", "", False, e.Path({str(output)!r}))',
                                      [(b'waiting for your selection', answer)])
                self.assertEqual(rc, 0, out)
                self.assertEqual(json.loads(output.read_text())['enabled'], enabled)

    def test_prompt_uses_tty_without_echo_and_preserves_spaces(self):
        with tempfile.TemporaryDirectory() as tmp:
            key, config = Path(tmp)/'key', Path(tmp)/'config'
            config.write_text('{"enabled":true}')
            body=(f'e.KEY=e.Path({str(key)!r}); e.CONFIG=e.Path({str(config)!r}); '
                  'e.require_rescue=lambda: None; e.prompt()')
            phrase=b' padded horse battery '
            rc, out=self.terminal(body, [(b'future boots):', phrase+b'\n'),
                                         (b'Confirm passphrase:', phrase+b'\n')])
            self.assertEqual(rc, 0, out)
            self.assertEqual(key.read_bytes(), phrase)
            self.assertNotIn(phrase.decode(), out)

    def test_initramfs_hook_handles_key_already_copied_by_ubuntu(self):
        # Execute the actual generated hook with initramfs-tools' duplicate-copy
        # return code. An existing key must not abort rebuilding the boot image.
        hook = SOURCE.with_suffix('.sh').read_text().split("<<'HOOK'\n", 1)[1].split('\nHOOK', 1)[0]
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            functions = directory/'hook-functions'
            functions.write_text('copy_file() { mkdir -p "$DESTDIR/etc/zfs"; '
                                 'test ! -e "$DESTDIR/etc/zfs/zfsify-rpool.key" || return 1; '
                                 'echo fixture > "$DESTDIR/etc/zfs/zfsify-rpool.key"; }\n')
            script = directory/'hook'
            script.write_text(hook.replace('/usr/share/initramfs-tools/hook-functions', str(functions)))
            for _ in range(2):
                result = subprocess.run(['sh', str(script)], env={**os.environ, 'DESTDIR': tmp},
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                key = directory/'etc/zfs/zfsify-rpool.key'
                self.assertEqual(key.read_text(), 'fixture\n')
                self.assertEqual(key.stat().st_mode & 0o777, 0o600)


if __name__ == '__main__':
    unittest.main(verbosity=2)
