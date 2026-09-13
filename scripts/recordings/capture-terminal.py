#!/usr/bin/env python3
"""Record a real terminal command. Test drivers can supply explicit prompt answers."""
import argparse
import codecs
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import struct
import termios
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--output', required=True, type=Path)
p.add_argument('--answer', action='append', default=[], metavar='PROMPT=ANSWER')
p.add_argument('--width', type=int, default=110)
p.add_argument('--height', type=int, default=30)
p.add_argument('command', nargs=argparse.REMAINDER)
a = p.parse_args()
command = a.command[1:] if a.command[:1] == ['--'] else a.command
answers = [item.rsplit('=', 1) for item in a.answer]
a.output.parent.mkdir(parents=True, exist_ok=True)
pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(1, termios.TIOCSWINSZ, struct.pack('HHHH', a.height, a.width, 0, 0))
    os.environ.update(TERM='xterm-256color', LANG='C.UTF-8', PYTHONIOENCODING='utf-8')
    os.execvp(command[0], command)
start = time.monotonic()
buffer = ''
decode = codecs.getincrementaldecoder('utf-8')(errors='replace')
try:
    with a.output.open('w') as out:
        out.write(json.dumps(dict(version=2, width=a.width, height=a.height))+'\n')
        while True:
            if not select.select([fd], [], [], 1)[0]:
                continue
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            text = decode.decode(chunk)
            out.write(json.dumps([round(time.monotonic()-start, 3), 'o', text], ensure_ascii=False)+'\n')
            out.flush()
            buffer = (buffer + text)[-8192:]
            if answers and answers[0][0] in buffer:
                _, answer = answers.pop(0)
                # Leave a readable pause in the recording before the test's answer.
                time.sleep(2)
                os.write(fd, (answer+'\n').encode())
                buffer = ''
finally:
    os.close(fd)
_, status = os.waitpid(pid, 0)
raise SystemExit(os.waitstatus_to_exitcode(status))
