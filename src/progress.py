#!/usr/bin/python3
"""Dependency-free migration dashboard, live Linux telemetry and durable plain logs."""
import argparse
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import time

STATE = Path('/run/zfs-on-boot-progress.json')
LOG = Path('/var/log/zfs-on-boot/progress.log')
ANSI = re.compile(r'\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))')


def clean(value):
    return ''.join(c for c in ANSI.sub('', str(value)) if c.isprintable())


def amount(n):
    for unit in ('B', 'KB', 'MB', 'GB', 'TB', 'PB'):
        if abs(n) < 1000 or unit == 'PB':
            return f'{n:,.1f} {unit}'
        n /= 1000


def duration(seconds):
    seconds = max(0, int(seconds))
    return f'{seconds//3600}h {seconds%3600//60:02d}m' if seconds >= 3600 else f'{seconds//60:02d}:{seconds%60:02d}'


PHASES = ('Scan disk + choose method', 'Prepare disk', 'Convert ext4 to ZFS',
          'Finish disk + boot setup', 'Snapshots + recovery + growth')


def phase_header(phase, width=88, color=False, complete=False):
    """Wrap whole phase segments, keeping every stage visible on narrow terminals."""
    lines = ['  zfsify  ⚡  Ubuntu → ZFS', '']
    row = ''
    for number, title in enumerate(PHASES, 1):
        mark = '✓ ' if number < phase or complete else ''
        segment = f'{mark}{number}. {title}'
        if number == phase:
            segment = '[' + segment + ']'
        if row and len(row) + len(segment) + 3 > width - 2:
            lines.append('  ' + row)
            row = ''
        row += (' | ' if row else '') + segment
    lines.append('  ' + row)
    lines = [line[:width] for line in lines]
    if color:
        lines = [re.sub(r'(\[[^]]+\])', r'\033[1;36m\1\033[0m', line) for line in lines]
        lines[0] = '\033[1;36m' + lines[0] + '\033[0m'
    return lines


def render(s, width=88, frame=0, color=False, unicode=True):
    """Each tile represents a share of logical bytes, not a physical disk extent."""
    width = max(1, width)
    total, done = s.get('total', 0), s.get('done', 0)
    fraction = min(1, max(0, done / total)) if total else 0
    status = s.get('status', 'running')
    running = status == 'running'
    solid, empty, active = ('█', '░', '▓') if unicode else ('#', '.', '>')
    tick, arrow, dot = ('✓', '→', '·') if unicode else ('+', '->', '.')
    pulses = '·•●•' if unicode else '|/-\\'
    spinner = pulses[frame % len(pulses)]
    badge = spinner if running else tick if status == 'complete' else '!'
    phase = s['phase']
    ready = phase == 5 and s['label'].startswith('Ready') and status == 'complete'
    lines = phase_header(phase, width, color=False, complete=ready)
    lines += ['', f'  {badge} {status.upper()}  ·  STEP: {s["label"]}', '']
    if s.get('source') or s.get('target'):
        lines.append(f"  {s.get('source') or 'source'}  {arrow}  {s.get('target') or 'destination'}")
    else:
        lines.append(f"  Devices  {s['devices']}")
    cells = max(1, min(28, (width - 12) // 2))
    bar_row = len(lines)
    if total:
        filled = int(fraction * cells)
        blocks = solid * filled + empty * (cells - filled)
        if running and filled < cells:
            blocks = blocks[:filled] + active + blocks[filled+1:]
        lines += [f'  {" ".join(blocks)}  {fraction*100:5.1f}%',
                  f"  {'~' if s.get('approximate') else ''}Transfer total  {amount(done)} / {amount(total)}"]
    else:
        head = frame % (cells + 4)
        blocks = ''.join(active if 0 <= head-i < 4 and running else empty for i in range(cells))
        lines += [f'  {" ".join(blocks)}', f'  {"Working" if running else status.capitalize()}  {dot}  total unavailable (streaming / metadata)']
    speed = max(0, s.get('speed', 0))
    eta = duration((total - done) / speed) if total > done and speed > 0 and running else '--'
    rate = f'{amount(speed)}/s' if total else '--'
    lines.append(f"  {rate}{' avg' if not running and total else ''}  {dot}  elapsed {duration(s.get('elapsed', 0))}  {dot}  ETA {eta}")
    if s.get('files_total'):
        lines.append(f"  Files  {s.get('files_done', 0):,} / {s['files_total']:,}")
    for device, values in s.get('io', {}).items():
        lines.append(f'  {device}  R {values[0]:.1f} MB/s  W {values[1]:.1f} MB/s  {values[2]:.0f} IOPS')
    if not s.get('io'):
        lines.append('  Device I/O  waiting for counters' if running else '  Device I/O  unavailable')
    if s.get('messages'):
        lines += ['', '  Recent output  ·  full log: /var/log/zfs-on-boot/progress.log']
        lines += ['  ' + line for line in s['messages'][-5:]]
    lines = [clean(line)[:width] for line in lines]
    if color:
        accent = '31' if status == 'failed' else '32' if status == 'complete' else '36'
        lines[0] = f'\033[1;{accent}m{lines[0]}\033[0m'
        for row, line in enumerate(lines):
            if '[' in line and ']' in line:
                lines[row] = re.sub(r'(\[[^]]+\])', lambda m: '\033[1;36m' + m[0] + '\033[0m', line)
        tiles = re.compile('(' + '|'.join(re.escape(c)+'+' for c in (solid, empty, active)) + ')')
        lines[bar_row] = tiles.sub(lambda match: f'\033[{"90" if match[0][0] == empty else "1;"+accent}m'
                             + match[0] + '\033[0m', lines[bar_row])
    return '\n'.join(lines)


class Display:
    """A fixed dashboard in the terminal viewport; raw output stays in the log."""
    def __init__(self, animate=True):
        self.stream = sys.stdout
        self.owned = False
        if animate and not self.stream.isatty() and os.environ.get('ZFS_PROGRESS_TTY') == '1':
            try:
                self.stream = open('/dev/tty', 'w', buffering=1)
                self.owned = True
            except OSError:
                pass
        self.live = animate and self.stream.isatty() and os.environ.get('TERM') != 'dumb'
        self.color = self.live and 'NO_COLOR' not in os.environ
        self.unicode = 'UTF' in (self.stream.encoding or '').upper().replace('-', '')
        self.rows = 0
        self.frame = 0
        self.width = None
        self.height = None
        self.previous = []
        self.messages = []
        if self.live:
            self.stream.write('\033[?25l')

    def draw(self, state):
        if not self.live:
            print(render(state, width=160, unicode=False), file=self.stream, flush=True)
            return
        size = os.get_terminal_size(self.stream.fileno())
        width = max(1, (size.columns or 80) - 1)
        # Repaint the viewport after resize; unchanged rows otherwise stay intact.
        if self.width != width or self.height != (size.lines or 24):
            self.rows = 0
            self.width = width
            self.height = size.lines or 24
            self.previous = []
        state = {**state, 'messages': state.get('messages', self.messages)}
        lines = render(state, width, self.frame, self.color, self.unicode).splitlines()
        height = max(1, (size.lines or 24) - 1)
        lines = (lines + [''] * height)[:height]
        # Replace each row's text before erasing its old suffix. One write
        # keeps redraws together; no erase-screen/erase-region blank transition.
        rows = max(self.rows, len(lines))
        update = '\033[H'
        visible = lines + [''] * (rows - len(lines))
        for row, line in enumerate(visible):
            if row < len(self.previous) and self.previous[row] == line:
                update += '\033[1B'
            else:
                update += '\r' + line + '\033[K\n'
        self.previous = visible
        self.stream.write(update)
        self.stream.flush()
        self.rows = rows
        self.frame += 1

    def message(self, text):
        self.messages = (self.messages + [clean(text)])[-5:]
        if not self.live:
            print(clean(text), file=self.stream, flush=True)

    def close(self):
        if self.live:
            self.stream.write('\033[0m\033[?25h')
            self.stream.flush()
        if self.owned:
            self.stream.close()


def disks(names):
    result = {}
    for name in names:
        try:
            fields = list(map(int, Path('/sys/class/block', Path(name).resolve().name, 'stat').read_text().split()))
            result[name] = (fields[2]*512, fields[6]*512, fields[0]+fields[4])
        except (OSError, ValueError):
            pass
    return result


def zbytes(value):
    match = re.fullmatch(r'([\d.,]+)([KMGTPE]?)', value)
    return int(float(match[1].replace(',', '')) * 1024 ** (' KMGTPE'.index(match[2]) if match[2] else 0))


class Counters:
    def __init__(self, state):
        self.state = state
        self.initial = 0

    def consume(self, line):
        s = self.state
        if match := re.match(r'^\s*([\d,]+)\s+(\d+)%\s+', line):
            s['done'] = int(match[1].replace(',', ''))
        elif match := re.fullmatch(r'ZFSIFY_(START|PROGRESS|FILES) ([0-9]{1,20}) ([0-9]{1,20})', line):
            kind, done, total = match.groups()
            if kind == 'FILES':
                s['files_done'], s['files_total'] = int(done), int(total)
            else:
                s['done'], s['total'] = int(done), int(total)
                if kind == 'START':
                    self.initial = int(done)
        else:
            return False
        return True


def process_start(pid):
    """Linux process identity; PID alone can be reused after a crashed runner."""
    try:
        return Path(f'/proc/{pid}/stat').read_text().rpartition(') ')[2].split()[19]
    except (OSError, IndexError):
        return None


def watch(args, display):
    last_version = None
    while True:
        source = STATE if STATE.exists() else Path('/var/log/zfs-on-boot/last-progress.json')
        try:
            state = json.loads(source.read_text())
            if state.get('runner_start') and state['status'] == 'running' and process_start(state['runner_pid']) != state['runner_start']:
                state.update(status='failed', messages=['Progress process stopped unexpectedly. Inspect the installer log before recovery.'])
            ready = state['label'].startswith('Ready') and state['status'] == 'complete'
            version = json.dumps(state, sort_keys=True)
            if display.live or version != last_version or args.once:
                display.draw(state)
                last_version = version
            if ready:
                next_steps = Path('/var/log/zfs-on-boot/backup-next-steps.txt')
                if next_steps.exists():
                    # Completion instructions include the backup location; do
                    # not truncate them to the live dashboard's recent lines.
                    for line in next_steps.read_text().splitlines():
                        print(clean(line), file=display.stream, flush=True)
            if args.once or state['status'] == 'failed' or ready:
                return 1 if state['status'] == 'failed' else 0
        except (OSError, ValueError):
            if last_version != 'waiting':
                display.draw(dict(phase=2, label='Waiting for the RAM installer to publish status', devices='detecting', elapsed=0))
                last_version = 'waiting'
            if args.once:
                return 1
        time.sleep(.125 if display.live else 1)


def run(args, display):
    cmd = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not cmd:
        raise ValueError('A phase command is required')
    LOG.parent.mkdir(parents=True, exist_ok=True)
    start = tick = time.monotonic()
    names = list(dict.fromkeys(args.devices.split(',')))
    prev = disks(names)
    state = dict(phase=args.phase, label=args.label, devices=','.join(names), total=args.total,
                 source=args.source, target=args.target, runner_pid=os.getpid(), runner_start=process_start(os.getpid()), done=0, speed=0, elapsed=0, status='running', io={})
    counters = Counters(state)
    last_done = last_print = last_frame = 0
    buffer = ''

    def publish(final=False):
        nonlocal tick, prev, last_done, last_print
        now = time.monotonic()
        dt = max(now-tick, .001)
        current = disks(names)
        state['io'] = {d: [(v[0]-prev[d][0])/dt/1e6, (v[1]-prev[d][1])/dt/1e6, (v[2]-prev[d][2])/dt]
                       for d, v in current.items() if d in prev and all(new >= old for new, old in zip(v, prev[d]))}
        state['speed'] = max(0, state['done']-counters.initial)/max(now-start, .001) if final else max(0, state['done']-last_done)/dt
        state['elapsed'] = now-start
        state['messages'] = display.messages
        prev, tick, last_done = current, now, state['done']
        tmp = STATE.with_suffix('.tmp')
        tmp.write_text(json.dumps(state))
        tmp.replace(STATE)
        if final or now-last_print >= 5:
            message = render(state, width=160, unicode=False)
            with LOG.open('a') as log:
                log.write(message+'\n')
            if not display.live:
                display.draw(state)
            last_print = now
        if final:
            if display.live:
                display.draw(state)

    publish()
    child = None
    try:
        with LOG.open('a') as log, selectors.DefaultSelector() as selector:
            log.write('COMMAND: '+repr(cmd)+'\n')
            child = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     stdin=subprocess.DEVNULL, env={**os.environ, 'LC_ALL':'C'})
            selector.register(child.stdout, selectors.EVENT_READ)
            eof = False
            while not eof:
                for key, _ in selector.select(timeout=.125 if display.live else 1):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        eof = True
                        break
                    buffer += chunk.decode(errors='replace')
                    lines = re.split('[\r\n]', buffer)
                    buffer = lines.pop()
                    # Bound output from tools that emit very long unterminated lines.
                    if len(buffer) > 65536:
                        lines.append(buffer)
                        buffer = ''
                    for line in lines:
                        if counters.consume(line):
                            if line.startswith('ZFSIFY_START '):
                                last_done = counters.initial
                        elif line:
                            display.message(line)
                            log.write(clean(line)+'\n')
                    log.flush()
                now = time.monotonic()
                if now-tick >= 1:
                    if args.resilver:
                        try:
                            scan = subprocess.check_output(['zpool', 'status', '-p', args.pool], text=True)
                            match = re.search(r'([\d.,]+[KMGTPE]?) / ([\d.,]+[KMGTPE]?) issued', scan)
                            if match:
                                state['done'], state['total'] = map(zbytes, match.groups())
                            elif match := re.search(r'scan: resilvered ([\d.,]+[KMGTPE]?)', scan):
                                state['done'] = state['total'] = zbytes(match[1])
                            state['approximate'] = True
                        except subprocess.CalledProcessError:
                            pass
                    publish()
                if display.live and now-last_frame >= .125:
                    display.draw(state)
                    last_frame = now
            if buffer and not counters.consume(buffer):
                display.message(buffer)
                log.write(clean(buffer)+'\n')
            code = child.wait()
            child.stdout.close()
    except BaseException:
        if child is not None and child.poll() is None:
            child.terminate()
            child.wait()
        state['status'] = 'failed'
        publish(final=True)
        raise
    state['status'] = 'complete' if code == 0 else 'failed'
    if code == 0 and state['total']:
        state['done'] = state['total']
    publish(final=True)
    return code


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest='action', required=True)
    h = sub.add_parser('header')
    h.add_argument('--phase', type=int, choices=range(1, 6), required=True)
    h.add_argument('--label', required=True)
    f = sub.add_parser('watch')
    f.add_argument('--once', action='store_true')
    r = sub.add_parser('run')
    r.add_argument('--phase', type=int, choices=range(1, 6), required=True)
    r.add_argument('--label', required=True)
    r.add_argument('--devices', required=True)
    r.add_argument('--source', default='')
    r.add_argument('--target', default='')
    r.add_argument('--total', type=int, default=0)
    r.add_argument('--resilver', action='store_true')
    r.add_argument('--pool', default='rpool')
    r.add_argument('command', nargs=argparse.REMAINDER)
    args = p.parse_args()
    if args.action == 'header':
        width = os.get_terminal_size().columns - 1 if sys.stdout.isatty() else 100
        print('\n'.join(phase_header(args.phase, width, color=sys.stdout.isatty() and 'NO_COLOR' not in os.environ)))
        print('\n  ' + args.label + '\n', flush=True)
        return 0
    def terminate(signum, _frame):
        raise SystemExit(128 + signum)
    previous = signal.signal(signal.SIGTERM, terminate)
    display = Display(animate=not getattr(args, 'once', False))
    try:
        return watch(args, display) if args.action == 'watch' else run(args, display)
    except KeyboardInterrupt:
        return 130
    finally:
        display.close()
        signal.signal(signal.SIGTERM, previous)


if __name__ == '__main__':
    sys.exit(main())
