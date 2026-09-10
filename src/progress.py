#!/usr/bin/python3
"""Run a phase with live Linux disk telemetry, or follow it across SSH sessions."""
import argparse
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys
import time

STATE = Path('/run/zfs-on-boot-progress.json')
LOG = Path('/var/log/zfs-on-boot/progress.log')

def render(s):
    fraction = min(1, s.get('done', 0) / s['total']) if s.get('total') else 0
    fraction = 1 if s.get('status') == 'complete' else fraction
    overall = ((s['phase'] - 1) + (fraction * .95 if s.get('total') else 0)) / 10
    if s['label'].startswith('Ready') and s['status'] == 'complete': overall = 1
    bar = '#' * int(overall * 24) + '-' * (24 - int(overall * 24))
    data = (f"{'~' if s.get('approximate') else ''}{s.get('done', 0)/1e6:,.1f}/{s['total']/1e6:,.1f} MB "
            f"({fraction*100:.1f}%) | {s.get('speed', 0)/1e6:,.1f} MB/s logical"
            + (' (phase average)' if s['status'] != 'running' else '')) if s.get('total') else 'data total: n/a (streaming or metadata operation)'
    io = ' | '.join(f"{d}: R {v[0]:.1f} W {v[1]:.1f} MB/s {v[2]:.0f} IOPS" for d, v in s.get('io', {}).items())
    return (f"[{bar}] phase {s['phase']}/10: {s['label']} [{s['status']}]\n"
            f"  devices: {s['devices']} | elapsed {s['elapsed']:.0f}s\n  {data}\n  {io}")

def disks(names):
    result = {}
    for name in names:
        try:
            fields = list(map(int, Path('/sys/class/block', Path(name).name, 'stat').read_text().split()))
            result[name] = (fields[2]*512, fields[6]*512, fields[0]+fields[4])
        except (OSError, ValueError):
            pass
    return result

p = argparse.ArgumentParser(description=__doc__)
sub = p.add_subparsers(dest='action', required=True)
f = sub.add_parser('watch')
f.add_argument('--once', action='store_true')
r = sub.add_parser('run')
r.add_argument('--phase', type=int, required=True)
r.add_argument('--label', required=True)
r.add_argument('--devices', required=True)
r.add_argument('--total', type=int, default=0)
r.add_argument('--resilver', action='store_true')
r.add_argument('command', nargs=argparse.REMAINDER)

def zbytes(value):
    match = re.fullmatch(r'([\d.,]+)([KMGTPE]?)', value)
    return int(float(match[1].replace(',', '')) * 1024 ** (' KMGTPE'.index(match[2]) if match[2] else 0))
a = p.parse_args()
if a.action == 'watch':
    while True:
        source = STATE if STATE.exists() else Path('/var/log/zfs-on-boot/last-progress.json')
        try:
            state = json.loads(source.read_text())
            if sys.stdout.isatty(): print('\033[H\033[2J', end='')
            print(render(state), flush=True)
            if state['label'].startswith('Ready') and state['status'] == 'complete':
                next_steps = Path('/var/log/zfs-on-boot/backup-next-steps.txt')
                if next_steps.exists(): print('\n' + next_steps.read_text(), flush=True)
            if a.once or state['status'] == 'failed' or (state['label'].startswith('Ready') and state['status'] == 'complete'):
                break
        except (OSError, ValueError):
            print('Waiting for installer status...', flush=True)
            if a.once: sys.exit(1)
        time.sleep(1)
    sys.exit(0)

cmd = a.command[1:] if a.command[:1] == ['--'] else a.command
if not cmd: p.error('A phase command is required')
LOG.parent.mkdir(parents=True, exist_ok=True)
start = tick = time.monotonic()
prev = disks(a.devices.split(','))
state = dict(phase=a.phase, label=a.label, devices=','.join(dict.fromkeys(a.devices.split(','))), total=a.total,
             done=0, speed=0, elapsed=0, status='running', io={})
last_done = 0
buffer = ''
last_print = 0
rsync = re.compile(r'^\s*([\d,]+)\s+(\d+)%\s+')

def publish(final=False):
    global tick, prev, last_done, last_print
    now = time.monotonic()
    dt = max(now-tick, .001)
    current = disks(a.devices.split(','))
    state['io'] = {d: [(v[0]-prev[d][0])/dt/1e6, (v[1]-prev[d][1])/dt/1e6, (v[2]-prev[d][2])/dt]
                   for d, v in current.items() if d in prev
                   # Partition recreation resets counters; establish a new baseline.
                   if all(new >= old for new, old in zip(v, prev[d]))}
    state['speed'] = state['done']/max(now-start, .001) if final else max(0, state['done']-last_done)/dt
    state['elapsed'] = now-start
    prev, tick, last_done = current, now, state['done']
    tmp = STATE.with_suffix('.tmp')
    tmp.write_text(json.dumps(state))
    tmp.replace(STATE)
    if final or now-last_print >= (1 if os.environ.get('ZFS_PROGRESS_TTY') == '1' else 5):
        message = render(state)
        print(message, flush=True)
        with LOG.open('a') as log: log.write(message+'\n')
        last_print = now

publish()
with LOG.open('a') as log:
    log.write('COMMAND: '+repr(cmd)+'\n')
    child = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                             env={**os.environ, 'LC_ALL':'C'})
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ)
    eof = False
    while not eof:
        for key, _ in selector.select(timeout=1):
            chunk = os.read(key.fileobj.fileno(), 65536)
            if not chunk:
                eof = True
                break
            buffer += chunk.decode(errors='replace')
            lines = re.split('[\r\n]', buffer)
            buffer = lines.pop()
            for line in lines:
                match = rsync.match(line)
                if match:
                    state['done'] = int(match[1].replace(',', ''))
                elif match := re.fullmatch(r'ZFSIFY_PROGRESS ([0-9]{1,20}) ([0-9]{1,20})', line):
                    state['done'], state['total'] = int(match[1]), int(match[2])
                elif line:
                    print(line, flush=True)
                    log.write(line+'\n')
                    log.flush()
        if a.resilver:
            try:
                scan = subprocess.check_output(['zpool', 'status', '-p', 'rpool'], text=True)
                m = re.search(r'([\d.,]+[KMGTPE]?) / ([\d.,]+[KMGTPE]?) issued', scan)
                if m: state['done'], state['total'] = map(zbytes, m.groups())
                elif (m := re.search(r'scan: resilvered ([\d.,]+[KMGTPE]?)', scan)):
                    state['done'] = state['total'] = zbytes(m[1])
                state['approximate'] = True
            except subprocess.CalledProcessError:
                pass
        if time.monotonic()-tick >= 1: publish()
    if buffer:
        print(buffer, flush=True)
        log.write(buffer+'\n')
    code = child.wait()
state['status'] = 'complete' if code == 0 else 'failed'
if code == 0 and state['total']: state['done'] = state['total']
publish(final=True)
sys.exit(code)
