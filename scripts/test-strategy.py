#!/usr/bin/env python3
"""Policy and real controlling-terminal tests. No disks or cloud resources changed."""
import importlib.util
import json
import os
from pathlib import Path
import pty
import select
import sys
import time
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / 'src/strategy.py'
sys.path.insert(0, str(SOURCE.parent))
spec = importlib.util.spec_from_file_location('strategy', SOURCE)
strategy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(strategy)
G = 1024**3


class StrategyTests(unittest.TestCase):
    def test_recommendation_matrix(self):
        for used, half, inplace, backup, expected in [
            (4*G, 10*G, 18*G, '', 'preserve'),
            (4*G, 10*G, 18*G, '/mnt/backup', 'preserve'),
            (14*G, 10*G, 18*G, '', 'inplace'),
            (14*G, 10*G, 18*G, '/mnt/backup', 'inplace'),
            (18*G, 10*G, 18*G, '', 'backup'),
            (int(9.9*G), 10*G, 18*G, '', 'inplace'),
            (14*G, 10*G, 0, '', 'backup'),
        ]:
            with self.subTest(used=used, backup=backup):
                self.assertEqual(strategy.recommended(20*G, used, half, inplace)[0], expected)

    def test_discovery_excludes_source_readonly_shared_and_small_disks(self):
        mounts = [{'target': '/'+name, 'source': '/dev/'+name, 'options': opts}
                  for name, opts in [('source','rw'), ('readonly','ro'), ('shared','rw'),
                                     ('small','rw'), ('backup','rw')]]
        def command(args, **kw):
            if args[0] == 'findmnt':
                return json.dumps({'filesystems': mounts})
            return {'/dev/source': '/dev/vda disk', '/dev/shared': '/dev/vdb disk\n/dev/vdc disk',
                    '/dev/small': '/dev/vdd disk', '/dev/backup': '/dev/vde disk'}[args[-1]]
        class Space:
            f_frsize = 1
            f_bavail = 20*G
            f_blocks = 25*G
        def space(path):
            s = Space(); s.f_bavail = G if path == '/small' else 20*G; return s
        with patch.object(strategy.subprocess, 'check_output', side_effect=command), \
             patch.object(Path, 'is_block_device', return_value=True), \
             patch.object(strategy.os, 'statvfs', side_effect=space):
            self.assertEqual([item['path'] for item in strategy.backup_candidates('/dev/vda', 8*G)], ['/backup'])

    def terminal(self, body, inputs=(), timeout=20):
        pid, fd = pty.fork()
        if pid == 0:
            # Exactly like curl | sh: stdin is not the controlling terminal.
            null = os.open('/dev/null', os.O_RDONLY); os.dup2(null, 0)
            os.execv(sys.executable, [sys.executable, '-c',
                f'import importlib.util,sys; sys.path.insert(0,{str(SOURCE.parent)!r}); s=importlib.util.spec_from_file_location("strategy",{str(SOURCE)!r}); '
                'm=importlib.util.module_from_spec(s); s.loader.exec_module(m); '+body])
        output = b''; start = time.monotonic(); pending = list(inputs)
        try:
            while time.monotonic()-start < timeout:
                while pending and pending[0][0] <= time.monotonic()-start:
                    os.write(fd, pending.pop(0)[1])
                if select.select([fd], [], [], .05)[0]:
                    try: chunk = os.read(fd, 65536)
                    except OSError: break
                    if not chunk: break
                    output += chunk
            else:
                os.kill(pid, 9)
                self.fail('Terminal test timed out: '+output.decode(errors='replace'))
            _, status = os.waitpid(pid, 0)
            return os.waitstatus_to_exitcode(status), output.decode(errors='replace'), time.monotonic()-start
        finally:
            os.close(fd)

    def test_enter_and_explicit_choice(self):
        for answer, expected in [(b'\n', '1'), (b'2\n', '2')]:
            rc, out, elapsed = self.terminal('print("RESULT",m.choose("test", "1", ["1","2"]))', [(0.2, answer)])
            self.assertEqual(rc, 0, out); self.assertIn('RESULT '+expected, out); self.assertLess(elapsed, 2)

    def test_idle_never_confirms_and_partial_input_waits(self):
        body = 'import sys; sys.argv=["strategy","confirm","--mode","preserve","--label","plan"]; m.main()'
        rc, out, elapsed = self.terminal(body, [(15.3, b'1'), (15.6, b'\n')])
        self.assertEqual(rc, 0, out)
        self.assertGreaterEqual(elapsed, 15.6)
        self.assertIn('full offsite backup', out)
        self.assertNotIn('starting in', out)

    def test_invalid_input_reprompts(self):
        rc, out, _ = self.terminal('print("RESULT",m.choose("test", "1", ["1","2"]))',
                                   [(0.2, b'invalid\n'), (.5, b'2\n')])
        self.assertEqual(rc, 0, out)
        self.assertIn('RESULT 2', out)

    def test_menu_override_cancel_and_erase(self):
        base = ('import sys; m.backup_candidates=lambda *a: []; '
                'sys.argv=["strategy","menu","--kind","root","--disk","/dev/test",'
                '"--size","20000000000","--used","4000000000",'
                '"--preserve-capacity","10000000000","--inplace-capacity","18000000000"]; ')
        for input_bytes, expected in [(b'\n', 'preserve'), (b'2\n', 'inplace'), (b'3\n', 'backup')]:
            rc, out, _ = self.terminal(base+'m.main()', [(0.2, input_bytes)])
            self.assertEqual(rc, 0, out); self.assertIn('\r\n'+expected+'\r\n', out)
        rc, out, _ = self.terminal(base+'m.main()', [(0.2, b'q\n')])
        self.assertNotEqual(rc, 0, out)
        rc, out, _ = self.terminal(base+'m.main()', [(0.2, b'4\n')])
        self.assertEqual(rc, 0, out); self.assertIn('\r\nerase\r\n', out)

    def test_backup_default_overrides_and_volume_limit(self):
        base = ('import sys; m.backup_candidates=lambda *a: ["/mnt/backup with spaces"]; '
                'sys.argv=["strategy","menu","--kind","root","--disk","/dev/test",'
                '"--size","20000000000","--used","14000000000",'
                '"--preserve-capacity","10000000000","--inplace-capacity","18000000000"]; ')
        rc, out, _ = self.terminal(base+'m.main()', [(0.2, b'\n')])
        self.assertEqual(rc, 0, out); self.assertIn('\r\ninplace\r\nask\r\n', out)
        rc, out, _ = self.terminal(base+'sys.argv += ["--mode","backup"]; m.main()', [(0.2, b'\n')])
        self.assertEqual(rc, 0, out); self.assertIn('\r\nbackup\r\nask\r\n', out)
        rc, out, _ = self.terminal(base+'sys.argv += ["--mode","inplace"]; m.main()', [(0.2, b'\n')])
        self.assertEqual(rc, 0, out); self.assertIn('\r\ninplace\r\n', out)
        rc, out, _ = self.terminal(base+'sys.argv += ["--mode","preserve"]; m.main()')
        self.assertNotEqual(rc, 0, out)
        rc, out, _ = self.terminal(base.replace('"root"','"volume"')+'m.main()', [(0.2, b'2\n')])
        self.assertNotEqual(rc, 0, out); self.assertIn('unavailable for data volumes', out)

    def test_review_transport_and_explicit_erase(self):
        for command, answer, expected in [('confirm","--mode","preserve","--label","plan', b'2\n', '2'),
                                          ('transport', b'\n', '1')]:
            rc, out, _ = self.terminal('import sys; sys.argv=["strategy","'+command+'"]; m.main()', [(0.2, answer)])
            self.assertEqual(rc, 0, out); self.assertIn('\r\n'+expected+'\r\n', out)
        body = ('import sys; m.backup_candidates=lambda *a: []; '
                'sys.argv=["strategy","menu","--kind","volume","--disk","/dev/test",'
                '"--size","20000000000","--used","0","--preserve-capacity","0",'
                '"--mode","erase","--erase-only"]; m.main()')
        rc, out, _ = self.terminal(body, [(0.2, b'\n')])
        self.assertEqual(rc, 0, out); self.assertIn('\r\nerase\r\n', out)
        self.assertNotIn('Type y', out)

    def test_flags_select_method_but_final_confirmation_requires_terminal(self):
        import subprocess
        for mode in ['preserve', 'inplace', 'backup', 'erase']:
            args = [sys.executable, str(SOURCE), 'menu', '--kind', 'root', '--disk', '/dev/test',
                    '--size', str(20*G), '--used', str(4*G), '--preserve-capacity', str(10*G),
                    '--inplace-capacity', str(18*G), '--mode', mode,
                    '--backup', '/mnt/chosen disk']
            p = subprocess.run(args, capture_output=True, text=True, start_new_session=True, timeout=2)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(p.stdout, mode+'\n/mnt/chosen disk\n')
            self.assertNotIn('starting in', p.stderr); self.assertNotIn('waiting for', p.stderr)
            p = subprocess.run([sys.executable, str(SOURCE), 'confirm', '--mode', mode,
                                '--label', 'plan'], capture_output=True,
                               text=True, start_new_session=True, timeout=2)
            self.assertNotEqual(p.returncode, 0, p.stderr)
            self.assertIn('requires a terminal', p.stderr)

    def test_yes_is_noninteractive_but_never_infers_backup_destination(self):
        import subprocess
        base = [sys.executable, str(SOURCE), 'menu', '--kind', 'root', '--disk', '/dev/test',
                '--size', str(20*G), '--used', str(4*G), '--preserve-capacity', str(10*G),
                '--inplace-capacity', str(18*G), '--yes']
        for mode in ('auto', 'preserve', 'inplace', 'erase', 'backup'):
            args = base + ['--mode', mode]
            if mode == 'backup': args += ['--backup', '/mnt/explicit-backup']
            result = subprocess.run(args, capture_output=True, text=True, start_new_session=True, timeout=2)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines()[0], 'preserve' if mode == 'auto' else mode)
            selected = result.stdout.splitlines()[0]
            result = subprocess.run([sys.executable, str(SOURCE), 'confirm', '--mode', selected,
                                     '--label', 'plan', '--yes'], capture_output=True, text=True,
                                    start_new_session=True, timeout=2)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, '1\n')
        for args in (base + ['--mode', 'backup'], base + ['--used', str(19*G)]):
            result = subprocess.run(args, capture_output=True, text=True, start_new_session=True, timeout=2)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('requires --backup=', result.stderr)

    def test_backup_configuration_explicit_and_interactive_consent(self):
        # Exercise the real configure flow with a fake rclone transport: no disks,
        # network access, or credentials. Record any attempted destination write.
        import shlex
        import subprocess
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory/'rclone.conf').write_text('[test]\ntype = local\n')
            script = ("rclone() { case \"${1:-} ${2:-}\" in "
                      "'config file') echo "+shlex.quote(str(directory/'rclone.conf'))+";; "
                      "'config dump') echo '{}';; "
                      "'listremotes ') echo test:;; "
                      "*) echo called >> "+shlex.quote(str(directory/'writes'))+";; esac; }; "
                      "cat() { if [[ ${1:-} = /proc/sys/kernel/random/uuid ]]; then echo test-id; "
                      "else command cat \"$@\"; fi; }; "
                      "source "+shlex.quote(str(SOURCE.with_name('backup.sh')))+" ")
            def command(dest, name):
                return ['bash', '-c', script+'configure '+shlex.quote(dest)+' '+
                        shlex.quote(str(directory/name))+' /dev/source 1000000000', str(SOURCE.with_name('backup.sh'))]
            p = subprocess.run(command('test:backups', 'explicit'), capture_output=True,
                               text=True, start_new_session=True, timeout=5)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertTrue((directory/'writes').exists())
            (directory/'writes').unlink()
            for answer, expected in [(b'n\n', 1), (b'y\n', 0)]:
                name = 'declined' if expected else 'confirmed'
                body = 'import subprocess,sys; sys.exit(subprocess.call('+repr(command('ask', name))+'))'
                rc, out, _ = self.terminal(body, [(0.2, b'3\n'), (.5, b'test:backups\n'), (.8, answer)])
                self.assertEqual(rc, expected, out)
                self.assertEqual((directory/'writes').exists(), not expected)
                self.assertEqual((directory/name).exists(), not expected)
                self.assertNotIn('starting in', out)

    def test_backup_waits_past_fifteen_seconds(self):
        body = ('import sys; sys.argv=["strategy","confirm","--mode","backup","--label","backup plan"]; m.main()')
        rc, out, elapsed = self.terminal(body, [(15.3, b'1\n')])
        self.assertEqual(rc, 0, out); self.assertGreaterEqual(elapsed, 15.3)
        self.assertIn('no timeout', out); self.assertNotIn('starting in', out)

    def test_destination_recommendation_still_requires_selection(self):
        body = ('import sys; m.backup_candidates=lambda *a: [dict(path="/mnt/mostly empty", '
                'device="/dev/vdb1", disk="/dev/vdb", free=19e9, total=20e9), '
                'dict(path="/mnt/data", device="/dev/vdc1", disk="/dev/vdc", free=15e9, total=20e9)]; '
                'sys.argv=["strategy","destination","--disk","/dev/vda","--used","1000000000"]; m.main()')
        for answer, expected in [(b'\n', '/mnt/mostly empty'), (b'2\n', '/mnt/data'), (b'q\n', 'q')]:
            rc, out, _ = self.terminal(body, [(0.2, answer)])
            self.assertEqual(rc, 0, out); self.assertIn('\r\n'+expected+'\r\n', out)
            self.assertIn('/dev/vdb1 on /dev/vdb', out); self.assertNotIn('starting in', out)

    def test_no_controlling_terminal(self):
        import subprocess
        body = (f'import importlib.util,sys; sys.path.insert(0,{str(SOURCE.parent)!r}); s=importlib.util.spec_from_file_location("strategy",{str(SOURCE)!r}); '
                'm=importlib.util.module_from_spec(s); s.loader.exec_module(m); '
                'print(m.choose("test", "1", ["1","q"]))')
        p = subprocess.run([sys.executable, '-c', body], input='', capture_output=True,
                           text=True, start_new_session=True, timeout=2)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('requires a terminal', p.stderr)

    def test_final_confirmation_defaults_to_cancel_for_every_mode(self):
        for mode in ('preserve', 'inplace', 'backup', 'erase'):
            body = f'import sys; sys.argv=["strategy","confirm","--mode",{mode!r},"--label","plan"]; m.main()'
            rc, out, _ = self.terminal(body, [(0.2, b'\n')])
            self.assertNotEqual(rc, 0, out)


if __name__ == '__main__':
    unittest.main(verbosity=2)
