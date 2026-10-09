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
import textwrap
import unicodedata
from itertools import zip_longest

STATE = Path('/run/zfs-on-boot-progress.json')
LOG = Path('/var/log/zfs-on-boot/progress.log')
ANSI = re.compile(r'\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))')


def clean(value):
    return ''.join(c for c in ANSI.sub('', str(value)) if c.isprintable())


def cells(text):
    return sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1
               for c in clean(text))


def bounded(text, width):
    if cells(text) <= width:
        return text
    # Strip styling only for clipped lines; never cut an ANSI escape sequence.
    result, used = '', 0
    for char in clean(text):
        used += cells(char)
        if used > width:
            break
        result += char
    return result


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


def phase_header(phase, width=88, color=False, complete=False, compact=False, kind="root"):
    """Wrap whole phase segments, keeping every stage visible on narrow terminals."""
    lines = ['  zfsify  ⚡  Ubuntu → ZFS', '']
    row = ''
    titles = PHASES if kind == 'root' else (*PHASES[:3], 'Finish disk + mounts', 'Growth + ready')
    for number, title in enumerate(('Plan', 'Prepare', 'Convert', 'Configure', 'Ready') if compact else titles, 1):
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


# Only presentation context is persisted here; never credentials or backup URLs.
CONTEXT = Path('/etc/zfs-on-boot/ui-context.json')
METHODS = {
    'preserve': ('Keep everything · 50/50', 'Copy, verify, then replace ext4.',
                 'Needs room for two copies. The original stays until verification.'),
    'inplace': ('Keep everything · slice-by-slice', 'Reuse space as files are verified.',
                'Experimental. Original data is released in 64 MiB batches; no full second copy.'),
    'backup': ('Keep everything · external backup', 'Archive elsewhere, rebuild, restore.',
               'Needs a destination you explicitly approve. The archive is retained.'),
    'erase': ('Start fresh · ERASE', 'Discard data and build fresh ZFS.',
              'Root: retain limited settings only. Data volume: retain no files.'),
}
# Operations are supplied by the installer, never guessed from human-readable logs.
STEPS = {
    'preserve': [('shrink', 'Shrink ext4 offline'), ('copy', 'Copy to ZFS at disk end'),
                 ('verify', 'Verify files + metadata'), ('mirror', 'Mirror ZFS to disk start'),
                 ('grow', 'Remove tail; grow ZFS')],
    'inplace': [('reserve', 'Reserve rescue + journal'), ('copy', 'Copy / verify / release'),
                ('verify', 'Verify complete ZFS image'), ('remap', 'Relocate image blocks'),
                ('grow', 'Grow native ZFS partition')],
    'backup': [('backup', 'Archive + read-back verify'), ('erase', 'Rebuild disk as ZFS'),
               ('restore', 'Restore saved archive'), ('verify', 'Verify restored files')],
    'erase': [('prepare', 'Save limited root settings'), ('erase', 'Rebuild disk as ZFS'),
              ('restore', 'Install fresh Ubuntu')],
}


def context():
    try:
        return json.loads(Path(os.environ.get('ZFSIFY_UI_CONTEXT', CONTEXT)).read_text())
    except (OSError, ValueError):
        return {}


def tint(text, code, color):
    return f'\033[{code}m{text}\033[0m' if color else text


def wrapped(text, width):
    return textwrap.wrap(clean(text), max(1, width), break_long_words=True, break_on_hyphens=False) or ['']


def columns(left, right, width, color=False):
    """Join already bounded, styled rows without counting ANSI as visible columns."""
    left_width = width - 45
    return [a + ' ' * max(0, left_width - cells(a)) + tint(' │ ', '90', color) + b
            for a, b in zip_longest(left, right, fillvalue='')]


def disk_picture(c, operation='prepare', fraction=None, frame=0, color=False,
                 unicode=True, preview=False, width=42, running=True):
    """Algorithm schematic, not invented sector telemetry. Byte tiles are logical."""
    solid, empty, head = ('█', '░', '▓') if unicode else ('#', '.', '>')
    method = c.get('mode', 'preserve')
    tiles_count = max(4, min(32, width - 4))
    half = tiles_count // 2
    def blocks(parts):
        return '  ' + ''.join(tint((empty if kind == 'free' else '▒' if kind == 'pending' and unicode else '.' if kind == 'pending' else solid) * count,
                                {'ext4':'33', 'zfs':'36', 'free':'90', 'boot':'35', 'pending':'90'}[kind], color)
                              for kind, count in parts)
    lines = [tint('YOUR DISK  /  ' + ('PLAN PREVIEW' if preview else 'LIVE OPERATION'), '1;36', color)]
    lines += wrapped(c.get('disk', 'Detecting selected disk'), width)
    if c.get('size'):
        lines += wrapped(f"{'Before: ' if not preview else ''}{amount(c['used'])} used / {amount(c['size'])} FS", width)
    lines += ['']
    if method == 'preserve':
        if operation in ('prepare', 'shrink'):
            parts = [('ext4', tiles_count)]
            caption = 'ext4 → smaller ext4 + free tail'
        elif operation in ('copy', 'verify', 'configure', 'create'):
            filled = int((tiles_count-half) * (fraction or 0)) if operation == 'copy' else 0 if operation == 'create' else tiles_count-half
            parts = [('ext4', half), ('zfs', filled), ('pending', tiles_count-half-filled)]
            caption = 'original ext4  →  temporary ZFS'
        elif operation in ('mirror', 'boot'):
            filled = int(half * (fraction or 0)) if operation == 'mirror' else 0
            parts = [('zfs', filled), ('pending', half-filled), ('zfs', tiles_count-half)]
            caption = 'new ZFS front  ←  verified ZFS tail'
        else:
            parts = [('zfs', tiles_count)]
            caption = 'front ZFS expands into freed tail'
    elif method == 'inplace':
        if operation in ('prepare', 'reserve'):
            parts = [('ext4', tiles_count-2), ('boot', 2)]
            caption = 'ext4 + 1 GiB rescue / journal'
        elif operation in ('copy', 'verify', 'create'):
            # This is logical file progress, not physical ext4 free-space layout.
            filled = int(tiles_count * (fraction or 0)) if operation in ('copy', 'create') else tiles_count
            parts = [('ext4', tiles_count-filled), ('zfs', filled)]
            caption = 'ext4 files → sparse ZFS image'
        else:
            parts = [('zfs', tiles_count)]
            caption = 'ZFS image → native ZFS partition'
    else:
        parts = [('ext4' if operation in ('prepare', 'backup') else 'zfs', tiles_count)]
        caption = ('disk → independent archive → ZFS' if method == 'backup'
                   else 'existing data → fresh filesystem')
    lines += blocks(parts), *wrapped(caption, width), ''
    if preview:
        used = round(tiles_count * min(1, max(0, c.get('used', 0) / max(1, c.get('size', 1)))))
        lines = lines[:4] + [blocks([('ext4', used), ('free', tiles_count-used)]),
                            'Current filesystem usage · shaded = free', '']
        arrow = ('›' if unicode else '>')
        flow = ' ' * (frame % 4) + arrow
        if method == 'preserve':
            stages = [('Shrink + copy + verify', [('ext4', half), ('zfs', tiles_count-half)]),
                      ('Mirror tail back to front', [('zfs', half), ('zfs', tiles_count-half)]),
                      ('Remove tail; grow front', [('zfs', tiles_count)])]
        elif method == 'inplace':
            stages = [('Copy / verify / release batches', [('ext4', half), ('zfs', tiles_count-half)]),
                      ('Verify image; relocate blocks', [('zfs', tiles_count-2), ('boot', 2)]),
                      ('Native ZFS; grow partition', [('zfs', tiles_count)])]
        elif method == 'backup':
            stages = [('Archive + verify on another disk / remote', [('ext4', tiles_count)]),
                      ('Reformat; restore + verify archive', [('zfs', tiles_count)])]
        else:
            stages = [('Discard data; create fresh ZFS', [('zfs', tiles_count)])]
        for title, parts in stages:
            lines += [tint(flow+' '+title, '36', color), blocks(parts)]
        if method == 'inplace':
            lines += ['64 MiB batches · rescue + journal: 1 GiB']
        elif method == 'backup':
            lines += ['Destination: you choose and approve it']
        elif method == 'erase':
            lines += wrapped('No files retained.' if c.get('kind') == 'volume' else
                             'Limited settings retained; other files lost.', width)
    else:
        lines += wrapped(c.get('operation_note', dict(STEPS[method]).get(operation,
                          'Verify native ZFS files' if operation == 'verify-final' else 'Prepare tools / configure system')), width)
        if operation in ('copy', 'mirror', 'remap', 'restore', 'backup'):
            n = max(4, (tiles_count//2)*2)
            filled = int(n * fraction) if fraction is not None else 0
            tiles = []
            for i in range(n):
                if fraction is not None and i < filled:
                    char, code = solid, '36'
                elif running and ((fraction is None and (i-frame) % n < 3) or
                                  (fraction is not None and i == filled)):
                    char, code = head, '1;33' if frame % 2 else '1;36'
                else:
                    char, code = empty, '90'
                tiles.append(tint(char, code, color))
            lines += ['  ' + ' '.join(tiles[:n//2]), '  ' + ' '.join(tiles[n//2:]), 'Logical bytes in this operation' if fraction is not None else 'Activity only · byte total unavailable']
        else:
            dots = '.' * (1 + frame % 4) if running else ''
            lines += [f'{"Working" if running else "Operation finished"}{dots}']
        if method == 'inplace' and operation == 'copy':
            lines += wrapped('Each batch: copy → sync → verify → release ext4 blocks.', width)
        elif method == 'preserve' and operation == 'copy':
            lines += wrapped('Original ext4 is retained until the full copy is verified.', width)
        elif method == 'backup':
            lines += wrapped('Your independent archive is retained after restoration.', width)
    lines += ['', tint('ext4 ■  ZFS ■  rescue ■', '90', color) if not color else
              tint('ext4 ■', '33', True) + '  ' + tint('ZFS ■', '36', True) + '  ' + tint('rescue ■', '35', True),
              'Schematic · not physical block positions']
    if c.get('source'):
        lines += wrapped('Source: '+c['source'], width)
    if c.get('platform'):
        lines += wrapped(c['platform'], width)
    if c.get('kind') == 'root':
        lines += wrapped('Final: boot partition + ZFS / and /boot', width)
    else:
        lines += wrapped('Final: ZFS data disk; OS disk unchanged', width)
    lines = [line.replace('ext4', clean(c.get('fstype', 'ext4'))) for line in lines]
    return [bounded(line, width) for line in lines]


def render(s, width=88, frame=0, color=False, unicode=True):
    width = max(1, width)
    c = s.get('context', {})
    height = s.get('height') or 24
    wide = bool(c) and width >= 104
    w = width - 45 if wide else width
    total, done = s.get('total', 0), s.get('done', 0)
    fraction = min(1, max(0, done / total)) if total else None
    status = s.get('status', 'running')
    running = status == 'running'
    ready = s['phase'] == 5 and s['label'].startswith('Ready') and status == 'complete'
    compact = bool(c) and (width < 104 or 0 < s.get('height', 0) < 28)
    lines = phase_header(s['phase'], width, color=color, complete=ready, compact=compact, kind=c.get("kind", "root"))
    accent = '31' if status == 'failed' else '32' if status == 'complete' else '36'
    left = [tint(status.upper() + ('  ·  All done!' if ready else ''), '1;'+accent, color)]
    left += wrapped(s['label'], w-1) + ['']
    if c:
        left += wrapped(METHODS[c['mode']][0], w-1)
    left += wrapped(f"Devices: {s.get('devices', 'detecting')}", w-1)
    if s.get('source') or s.get('target'):
        left += wrapped(f"{s.get('source') or 'source'} → {s.get('target') or 'destination'}", w-1)
    n = max(1, min(34, w-12))
    filled = int((fraction or 0)*n)
    solid, empty = ('━', '─') if unicode else ('#', '.')
    bar = solid*filled + empty*(n-filled)
    if fraction is not None:
        left += ['', tint(bar + f' {fraction*100:5.1f}%', '1;'+accent, color),
                 f"{'~' if s.get('approximate') else ''}Transfer total  {amount(done)} / {amount(total)}"]
    else:
        marker = frame % max(1, n)
        bar = empty*marker + ('●' if unicode else '>') + empty*(n-marker-1) if running else bar
        left += ['', tint(bar, accent, color), 'Byte total unavailable · ' + ('working' if running else status)]
    speed = max(0, s.get('speed', 0))
    eta = duration((total-done)/speed) if total > done and speed and running else '--'
    rate_label = ' (' + s['rate_label'] + ')' if total and s.get('rate_label') else ''
    left += [f"{amount(speed)+'/s' if total else '--'}{rate_label}  ·  ETA {eta}  ·  {duration(s.get('elapsed', 0))} elapsed"]
    if s.get('files_total'):
        left += [f"Files  {s.get('files_done', 0):,} / {s['files_total']:,}"]
    left += ['', tint('DISK ACTIVITY', '1', color)]
    for device, values in s.get('io', {}).items():
        left += wrapped(f'{device}  R {values[0]:.1f} MB/s  W {values[1]:.1f} MB/s  {values[2]:.0f} IOPS', w-1)
    if not s.get('io'):
        left += ['Waiting for device counters' if running else 'Device counters unavailable']
    left = [bounded(line, w) for line in left]
    operation = s.get('operation', 'prepare')
    if compact:
        # Recovery consoles commonly expose only 80x24. Prioritize the operation,
        # whole-transfer counters and disk diagram over repeated I/O devices.
        lines += [tint(status.upper()+' · '+clean(s['label']), '1;'+accent, color)]
        if height >= 22:
            lines += [METHODS[c['mode']][0]]
        lines += wrapped('Devices: '+s.get('devices', ''), width)[:2]
        lines += [tint(bar + (f' {fraction*100:5.1f}%' if fraction is not None else ''), accent, color)]
        lines += [f'Transfer total  {amount(done)} / {amount(total)}' if total else 'Byte total unavailable · '+status]
        lines += [f"{amount(speed)+'/s' if total else '--'}{rate_label} · ETA {eta} · {duration(s.get('elapsed', 0))} elapsed"]
        if s.get('files_total') and height >= 22:
            lines += [f"Files {s.get('files_done', 0):,} / {s['files_total']:,}"]
        for device, values in list(s.get('io', {}).items())[:1]:
            lines += [f'{device} R {values[0]:.1f} MB/s · W {values[1]:.1f} MB/s · {values[2]:.0f} IOPS']
        lines += disk_picture(c, operation, fraction, frame, color, unicode, width=width, running=running)[4:6]
        room = max(0, height-len(lines)-2)
        if room and s.get('messages'):
            lines += [tint('LATEST OUTPUT', '1', color)] + [clean(line) for line in s['messages'][-min(room, 3):]]
        lines += [tint('Log: /var/log/zfs-on-boot/progress.log', '90', color)]
        return '\n'.join(bounded(line, width) for line in lines)
    if wide:
        lines += [''] + columns(left, disk_picture(c, operation, fraction, frame, color, unicode,
                                                   running=running), width, color)
    else:
        lines += [''] + left
        if c:
            lines += [tint('DISK PLAN · '+dict(STEPS[c['mode']]).get(operation, 'Prepare / configure'), '36', color)]
            lines += disk_picture(c, operation, fraction, frame, color, unicode, width=width, running=running)[4:7]
    if s.get('messages'):
        lines += ['', tint('LATEST OUTPUT', '1', color)]
        lines += [bounded(clean(line), width) for line in s['messages'][-3:]]
    lines += [tint('Log: /var/log/zfs-on-boot/progress.log', '90', color)]
    return '\n'.join(bounded(line, width) for line in lines)


class Display:
    """A fixed dashboard in the terminal viewport; raw output stays in the log."""
    def __init__(self, animate=True, stream=None):
        self.stream = stream or sys.stdout
        self.owned = False
        if animate and not self.stream.isatty() and (os.environ.get('ZFS_PROGRESS_TTY') == '1' or os.environ.get('ZFS_PROGRESS_CONSOLE') == '1'):
            try:
                self.stream = open('/dev/console' if os.environ.get('ZFS_PROGRESS_CONSOLE') == '1' else '/dev/tty', 'w', buffering=1)
                self.owned = True
            except OSError:
                pass
        self.live = animate and self.stream.isatty() and os.environ.get('TERM') != 'dumb'
        self.color = self.live and 'NO_COLOR' not in os.environ
        self.unicode = 'UTF' in (self.stream.encoding or '').upper().replace('-', '')
        self.rows = 0
        self.content_rows = 0
        self.frame = 0
        self.width = None
        self.height = None
        self.previous = []
        self.messages = []
        if self.live:
            self.stream.write('\033[?25l')

    def draw(self, state):
        self.paint(lambda width, frame, color, unicode: render(
            {**state, "messages": state.get("messages", self.messages), "height": self.height-1 if self.height else 0}, width, frame, color, unicode))

    def paint(self, renderer):
        if not self.live:
            print(renderer(100, self.frame, False, False), file=self.stream, flush=True)
            return
        try:
            size = os.get_terminal_size(self.stream.fileno())
        except OSError:
            size = os.terminal_size((80, 24))
        width = max(1, (size.columns or 80) - 1)
        # Repaint the viewport after resize; unchanged rows otherwise stay intact.
        if self.width != width or self.height != (size.lines or 24):
            self.rows = 0
            self.width = width
            self.height = size.lines or 24
            self.previous = []
        lines = renderer(width, self.frame, self.color, self.unicode).splitlines()
        height = max(1, (size.lines or 24) - 1)
        self.content_rows = min(len(lines), height)
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
            self.stream.write(f'\033[{self.content_rows+1};1H\033[0m\033[?25h')
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
    state.update(context=context(), operation=getattr(args, 'operation', 'prepare'))
    counters = Counters(state)
    last_print = last_frame = 0
    samples = [(start, 0)]
    buffer = ''

    def publish(final=False):
        nonlocal tick, prev, last_print
        now = time.monotonic()
        dt = max(now-tick, .001)
        current = disks(names)
        state['io'] = {d: [(v[0]-prev[d][0])/dt/1e6, (v[1]-prev[d][1])/dt/1e6, (v[2]-prev[d][2])/dt]
                       for d, v in current.items() if d in prev and all(new >= old for new, old in zip(v, prev[d]))}
        samples.append((now, state['done']))
        while len(samples) > 2 and samples[1][0] <= now-5:
            samples.pop(0)
        state['speed'] = (max(0, state['done']-counters.initial)/max(now-start, .001) if final else
                          max(0, state['done']-samples[0][1])/max(now-samples[0][0], .001))
        state['rate_label'] = 'avg' if final else '5s'
        state['elapsed'] = now-start
        state['messages'] = display.messages
        prev, tick = current, now
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
                                samples[:] = [(time.monotonic(), counters.initial)]
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
    h.add_argument('--kind', choices=['root', 'volume'], default='root')
    f = sub.add_parser('watch')
    f.add_argument('--once', action='store_true')
    r = sub.add_parser('run')
    r.add_argument('--phase', type=int, choices=range(1, 6), required=True)
    r.add_argument('--label', required=True)
    r.add_argument('--devices', required=True)
    r.add_argument('--source', default='')
    r.add_argument('--target', default='')
    r.add_argument('--total', type=int, default=0)
    r.add_argument('--operation', default='prepare')
    r.add_argument('--resilver', action='store_true')
    r.add_argument('--pool', default='rpool')
    r.add_argument('command', nargs=argparse.REMAINDER)
    args = p.parse_args()
    if args.action == 'header':
        width = os.get_terminal_size().columns - 1 if sys.stdout.isatty() else 100
        print('\n'.join(phase_header(args.phase, width, color=sys.stdout.isatty() and 'NO_COLOR' not in os.environ, kind=args.kind)))
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
