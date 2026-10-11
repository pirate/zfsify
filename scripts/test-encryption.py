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
    def configure(self, *args, key=None):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp)/'config.json'
            result = subprocess.run([sys.executable, str(SOURCE), 'configure',
                                     '--output', str(output), *args], capture_output=True,
                                    text=True, start_new_session=True, timeout=3,
                                    env={**{k:v for k,v in os.environ.items() if k != 'ZFSIFY_ENCRYPT_KEY'},
                                         **({'ZFSIFY_ENCRYPT_KEY': key} if key is not None else {})})
            return result, json.loads(output.read_text()) if output.exists() else None

    def test_default_headless_is_unencrypted(self):
        result, config = self.configure('--yes')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(config, {'enabled': False, 'key_url': '', 'boot_key': False})

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
        result, config = self.configure('--yes', '--mode', 'on', '--key-url', 'https://keys.example.org/root')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(config['enabled'])

    def test_conflicting_options_and_unsafe_urls(self):
        for url in ('http://keys.example.org/key', 'https://user:secret@host/key',
                    'https://host/key?token=secret', 'https://host/key#secret', 'https://',
                    'https://host/key\nsecret', 'https://user:secret＠host/key'):
            result, config = self.configure('--yes', '--mode', 'on', '--key-url', url)
            self.assertNotEqual(result.returncode, 0)
            self.assertIsNone(config)
            self.assertNotIn('secret', result.stderr.replace('not a secret', ''))
        result, config = self.configure('--mode', 'off', '--key-url', 'https://keys.example.org/root')
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(config)

    def test_boot_key_is_explicit_and_warns(self):
        result, config = self.configure('--mode', 'on', '--yes', key='my temporary key')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(config['enabled'] and config['boot_key'])
        self.assertIn('\033[1;31m', result.stderr)
        self.assertIn('DEFEATS DISK ENCRYPTION', result.stderr)
        self.assertIn('DOES NOT revoke old disk copies', result.stderr)
        self.assertNotIn('my temporary key', result.stderr)
        for args in [('--mode', 'off'), ('--yes',), ('--mode', 'on', '--key-url', 'https://host/key')]:
            result, config = self.configure(*args, key='my temporary key')
            self.assertNotEqual(result.returncode, 0)
            self.assertIsNone(config)
        result, config = self.configure('--mode', 'on', '--yes', key='')
        self.assertNotEqual(result.returncode, 0)

    def test_supplied_bootstrap_survives_rescue_resume(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); config = root/'config'; key = root/'ram-key'
            with contextlib.redirect_stderr(io.StringIO()), patch.dict(os.environ, {'ZFSIFY_ENCRYPT_KEY':'saved temporary key'}):
                encryption.configure('on', '', True, config)
            secret = (root/'bootstrap.key').read_bytes()
            self.assertEqual(secret, b'saved temporary key')
            self.assertEqual((root/'bootstrap.key').stat().st_mode & 0o777, 0o600)
            self.assertNotIn(secret.decode(), config.read_text())
            with patch.object(encryption, 'CONFIG', config), patch.object(encryption, 'KEY', key), \
                 patch.object(encryption, 'require_rescue'):
                encryption.acquire()
                self.assertEqual(key.read_bytes(), secret)
                key.unlink()
                encryption.acquire()
                self.assertEqual(key.read_bytes(), secret)

    def test_generated_key_requires_saved_key_confirmation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); output=root/'config'
            body=("e.secrets.choice=lambda alphabet: 'A'; "
                  f'e.configure("auto", "", False, e.Path({str(output)!r}))')
            rc,out=self.terminal(body, [(b'waiting for your selection', b'3\n'),
                (b'Retype the saved key', b'wrong key\n'),
                (b'Key does not match. Save and retype the displayed key.\r\nRetype the saved key', b'A'*16+b'\n')])
            self.assertEqual(rc, 0, out)
            self.assertIn('Temporary key: '+'A'*16+'\r\n', out)
            self.assertEqual((root/'bootstrap.key').read_bytes(), b'A'*16)
            self.assertTrue(json.loads(output.read_text())['boot_key'])

    def test_generated_key_cancel_does_not_save_key(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); output=root/'config'
            body=f'e.configure("auto", "", False, e.Path({str(output)!r}))'
            rc,out=self.terminal(body, [(b'waiting for your selection', b'3\n'),
                (b'Retype the saved key', b'\x03')])
            self.assertNotEqual(rc, 0)
            self.assertFalse(output.exists())
            self.assertFalse((root/'bootstrap.key').exists())

    def test_boot_hook_handles_literal_key_and_scopes_pool(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); key = root/'key'; config = root/'config'; hook = root/'hook'
            phrase = bytes([32, 39, 92, 34]) + b" $(touch SHOULD_NOT_EXIST) `false` "
            key.write_bytes(phrase)
            config.write_text('{"enabled": true, "boot_key": false}')
            with patch.object(encryption, 'CONFIG', config), patch.object(encryption, 'KEY', key), \
                 patch.object(encryption, 'require_rescue'), contextlib.redirect_stderr(io.StringIO()):
                encryption.install_boot_hook(hook)
                self.assertFalse(hook.exists())
                config.write_text('{"enabled": true, "boot_key": true}')
                encryption.install_boot_hook(hook)
            self.assertEqual(hook.stat().st_mode & 0o777, 0o700)
            fake = root/'zfs'
            fake.write_text('#!/bin/sh\ncat > "$CAPTURE"\nprintf "%s\\n" "$@" > "$ARGS"\n')
            fake.chmod(0o755)
            env = {**os.environ, 'PATH': str(root)+':'+os.environ['PATH'],
                   'CAPTURE': str(root/'capture'), 'ARGS': str(root/'args')}
            result = subprocess.run(['sh', str(hook)], env={**env, 'ZBM_ENCRYPTION_ROOT': 'other'},
                                    capture_output=True, cwd=tmp)
            self.assertEqual(result.returncode, 0)
            self.assertFalse((root/'capture').exists())
            result = subprocess.run(['sh', str(hook)], env={**env, 'ZBM_ENCRYPTION_ROOT': 'rpool'},
                                    capture_output=True, cwd=tmp)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((root/'capture').read_bytes(), phrase)
            self.assertEqual((root/'args').read_text().splitlines(),
                             ['load-key', '-L', 'file:///dev/stdin', 'rpool'])
            self.assertFalse((root/'SHOULD_NOT_EXIST').exists())
            self.assertNotIn(phrase, result.stdout + result.stderr)

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
                config = json.loads(output.read_text())
                self.assertEqual(config['enabled'], enabled)
                self.assertEqual(config['boot_key'], answer == b'3\n')

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
