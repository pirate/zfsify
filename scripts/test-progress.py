#!/usr/bin/env python3
"""Exercise actual progress subprocesses and PTYs using temporary ordinary files."""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'src/progress.py'
spec = importlib.util.spec_from_file_location('progress', SOURCE)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def launcher(directory, command, extra=()):
    return [sys.executable, '-c',
            f'import importlib.util,sys; s=importlib.util.spec_from_file_location("progress",{str(SOURCE)!r}); '
            'm=importlib.util.module_from_spec(s); s.loader.exec_module(m); '
            f'm.STATE=m.Path({str(directory / "state.json")!r}); m.LOG=m.Path({str(directory / "progress.log")!r}); '
            'sys.exit(m.main())', 'run', '--phase', '5', '--label', 'Copy and verify local preview files',
            '--devices', 'local filesystem', '--source', 'source.bin', '--target', 'copy.bin', *extra,
            '--', *command]


def terminal(command, *, width=96, resize=False, interrupt=False, env=None):
    pid, fd = pty.fork()
    if pid == 0:
        fcntl.ioctl(1, termios.TIOCSWINSZ, struct.pack('HHHH', 24, width, 0, 0))
        os.environ.update(TERM='xterm-256color', PYTHONIOENCODING='utf-8')
        os.environ.pop('NO_COLOR', None)
        os.environ.update(env or {})
        os.execv(command[0], command)
    chunks = []; started = time.monotonic(); resized = stopped = False
    try:
        while time.monotonic() - started < 15:
            elapsed = time.monotonic() - started
            if resize and elapsed > .3 and not resized:
                fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 16, 40, 0, 0)); resized = True
            if interrupt and elapsed > .3 and not stopped:
                if interrupt == 'term': os.kill(pid, signal.SIGTERM)
                else: os.write(fd, b'\x03')
                stopped = True
            if select.select([fd], [], [], .05)[0]:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    break
                if not data:
                    break
                chunks.append([round(elapsed, 3), 'o', data.decode('utf-8', errors='replace')])
        else:
            os.kill(pid, signal.SIGKILL)
            raise AssertionError('Progress process did not finish')
        _, status = os.waitpid(pid, 0)
        return os.waitstatus_to_exitcode(status), chunks
    finally:
        os.close(fd)


def copy_fixture(directory, seconds=2):
    data = directory / 'source.bin'
    data.write_bytes(os.urandom(32*1024**2))
    code = '''import hashlib,os,sys,time
source,target=sys.argv[1:3]
total=os.path.getsize(source); done=0
print(f'ZFSIFY_START 0 {total}',flush=True)
with open(source,'rb') as src,open(target,'wb') as dst:
 while chunk:=src.read(1024**2):
  dst.write(chunk); dst.flush(); done+=len(chunk)
  print(f'ZFSIFY_PROGRESS {done} {total}',flush=True)
  time.sleep(float(sys.argv[3])/32)
assert hashlib.sha256(open(source,'rb').read()).digest()==hashlib.sha256(open(target,'rb').read()).digest()
print('SHA-256 verified: source.bin = copy.bin',flush=True)
'''
    return [sys.executable, '-c', code, str(data), str(directory/'copy.bin'), str(seconds)]


class ProgressTests(unittest.TestCase):
    def test_tiles_width_failure_and_unknown_totals(self):
        state = dict(phase=5, label='Copy\x1b[2J data', status='running', elapsed=31,
                     devices='/dev/vda', total=100, done=25, speed=3, io={})
        for width in (8, 40, 80, 120):
            text = m.render(state, width=width)
            self.assertTrue(all(len(line) <= width for line in text.splitlines()))
            self.assertNotIn('\x1b', text)
        self.assertIn('25.0%', m.render(state))
        state['status'] = 'failed'
        self.assertIn('25.0%', m.render(state)); self.assertNotIn('100.0%', m.render(state))
        state.update(total=0, status='running')
        self.assertNotIn('%', m.render(state)); self.assertIn('total unavailable', m.render(state))
        self.assertNotEqual(m.render(state, frame=1), m.render(state, frame=5))

    def test_counter_protocol_and_resumed_baseline(self):
        state = {}; counters = m.Counters(state)
        self.assertTrue(counters.consume('ZFSIFY_START 500 1000'))
        self.assertEqual(counters.initial, 500)
        self.assertTrue(counters.consume('ZFSIFY_PROGRESS 600 1000'))
        self.assertTrue(counters.consume('ZFSIFY_FILES 3 8'))
        self.assertEqual(state['done'], 600); self.assertEqual(state['files_total'], 8)
        self.assertTrue(counters.consume('  1,234  10%  1.0MB/s'))
        self.assertEqual(state['done'], 1234)
        self.assertFalse(counters.consume('ERROR: disk full'))

    def test_real_copy_pipe_and_clean_log(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            p = subprocess.run(launcher(d, copy_fixture(d, .2)), capture_output=True, text=True, timeout=5)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertNotIn('\x1b', p.stdout)
            self.assertNotIn('\x1b', (d/'progress.log').read_text())
            state = json.loads((d/'state.json').read_text())
            self.assertEqual(state['done'], 32*1024**2); self.assertEqual(state['status'], 'complete')
            self.assertIn('SHA-256 verified', p.stdout)

    def test_real_copy_tty_resize_no_color_and_tee(self):
        for mode in ('normal', 'resize', 'no-color', 'tee'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                d = Path(tmp); command = launcher(d, copy_fixture(d, 1))
                if mode == 'tee':
                    import shlex
                    command = ['/bin/bash', '-c', 'set -o pipefail; '+shlex.join(command)+' | tee '+shlex.quote(str(d/'tee.log'))]
                rc, events = terminal(command, resize=mode == 'resize',
                                      env={'NO_COLOR':'1'} if mode == 'no-color' else {'ZFS_PROGRESS_TTY':'1'} if mode == 'tee' else {})
                out = ''.join(e[2] for e in events)
                self.assertEqual(rc, 0, out); self.assertIn('100.0%', out)
                self.assertIn('\x1b[?25l', out); self.assertIn('\x1b[?25h', out)
                self.assertNotIn('\x1b[2J', out)
                self.assertGreater(out.count('PHASE'), 3)
                self.assertNotIn('\x1b', (d/'progress.log').read_text())
                if mode == 'no-color': self.assertNotIn('\x1b[1;36m', out)
                if mode == 'tee': self.assertNotIn('\x1b', (d/'tee.log').read_text())

    def test_failure_and_interrupt_restore_cursor(self):
        for interrupt in (False, True, 'term'):
            with tempfile.TemporaryDirectory() as tmp:
                d = Path(tmp)
                code = 'import time,sys; print("ZFSIFY_PROGRESS 25 100",flush=True); time.sleep(2); sys.exit(7)'
                rc, events = terminal(launcher(d, [sys.executable, '-c', code]), interrupt=interrupt)
                out = ''.join(e[2] for e in events)
                self.assertEqual(rc, 143 if interrupt == 'term' else 130 if interrupt else 7, out)
                self.assertIn('FAILED', out); self.assertIn('\x1b[?25h', out)
                self.assertNotIn('100.0%', out)
                self.assertEqual(json.loads((d/'state.json').read_text())['status'], 'failed')

    def test_resilver_uses_selected_pool_and_byte_counters(self):
        from contextlib import redirect_stdout
        from unittest.mock import patch
        import io
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            args = argparse.Namespace(command=[sys.executable, '-c', 'import time; time.sleep(1.2)'],
                                      phase=8, label='Resilver', devices='/dev/test', source='old', target='new',
                                      total=0, resilver=True, pool='data_pool')
            with patch.object(m, 'STATE', d/'state.json'), patch.object(m, 'LOG', d/'progress.log'), \
                 patch.object(m.subprocess, 'check_output', return_value='512 / 1024 issued') as query, \
                 redirect_stdout(io.StringIO()):
                display = m.Display(animate=False)
                self.assertEqual(m.run(args, display), 0)
                display.close()
                query.assert_called_with(['zpool', 'status', '-p', 'data_pool'], text=True)
            state = json.loads((d/'state.json').read_text())
            self.assertTrue(state['approximate']); self.assertEqual(state['total'], 1024)

    def test_watch_once_plain_and_dumb_terminal(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            state = dict(phase=10, label='Ready: preview complete', status='complete', elapsed=1,
                         devices='preview', total=0, done=0, speed=0, io={})
            (d/'state.json').write_text(json.dumps(state))
            command = launcher(d, [])[:3] + ['watch', '--once']
            rc, events = terminal(command)
            self.assertEqual(rc, 0); self.assertNotIn('\x1b', ''.join(e[2] for e in events))
            rc, events = terminal(launcher(d, [sys.executable, '-c', 'print("done")']), env={'TERM':'dumb'})
            self.assertEqual(rc, 0); self.assertNotIn('\x1b', ''.join(e[2] for e in events))


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--record':
        dest = Path(sys.argv[2]); dest.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            rc, events = terminal(launcher(d, copy_fixture(d, 5)))
            assert rc == 0
            header = dict(version=2, width=96, height=24,
                          title='zfsify TUI preview — real local file copy, not a disk conversion')
            dest.write_text('\n'.join(json.dumps(e, ensure_ascii=False) for e in [header, *events])+'\n')
            print(dest)
    else:
        unittest.main(verbosity=2)
