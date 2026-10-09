#!/usr/bin/env python3
"""Read-only strategy discovery and deliberate choices; never format or mount disks."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

MARGIN = 256 * 1024**2


def recommended(size, used, preserve_capacity, inplace_capacity):
    # Leave working room for filesystem metadata instead of treating 49.9% as a guarantee.
    required = used * 11 // 10 + MARGIN
    preserve = used * 2 < size and required <= preserve_capacity
    inplace = required <= inplace_capacity
    default = 'preserve' if preserve else 'inplace' if inplace else 'backup'
    return default, preserve, inplace


def backup_candidates(disk, used):
    """Only writable ext4 mounts on a single, different disk with ample space."""
    def command(*args):
        return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL)
    try:
        mounts = json.loads(command('findmnt', '--json', '--list', '-t', 'ext4',
                                    '-o', 'TARGET,SOURCE,OPTIONS'))['filesystems']
    except (OSError, subprocess.CalledProcessError, ValueError, KeyError):
        return []
    found = []
    for mount in mounts:
        try:
            target, source = mount['target'], mount['source']
            if 'rw' not in mount['options'].split(',') or not source.startswith('/dev/'):
                continue
            # Bind mounts/subvolumes cannot be mounted by UUID at the same path in rescue.
            if '[' in source or not Path(source).is_block_device():
                continue
            parents = {line.split()[0] for line in command('lsblk', '-snrpo', 'NAME,TYPE', source).splitlines()
                       if line.split()[-1] == 'disk'}
            if len(parents) != 1 or os.path.realpath(disk) in map(os.path.realpath, parents):
                continue
            space = os.statvfs(target)
            if space.f_bavail * space.f_frsize >= used * 12 // 10 + MARGIN:
                found.append(dict(path=target, device=source, disk=next(iter(parents)),
                                  free=space.f_bavail * space.f_frsize,
                                  total=space.f_blocks * space.f_frsize))
        except (OSError, subprocess.CalledProcessError, KeyError, ValueError):
            continue
    unique = {item['device']: item for item in found}
    return sorted(unique.values(), key=lambda item: (-item['free'] / max(1, item['total']),
                                                     -item['free'], item['path']))


def choose(prompt, default, options, *, title='Choose your next step', items=None, plan=None, unavailable=None, danger=()):
    """Controlling-TTY input; arrows preview, Enter confirms. Never timed consent."""
    from progress import Display, context, disk_picture, columns, tint, wrapped, clean, METHODS, bounded
    import select
    import signal
    import termios
    import tty as terminal
    if items is None:
        items = [(key, key, '') for key in options]
    unavailable = unavailable or {}
    plan = plan or context()
    keys = list(options)
    selected = keys.index(default)
    try:
        with open('/dev/tty', 'r') as tty:
            if not sys.stderr.isatty() or os.environ.get('TERM') == 'dumb':
                print(title + '\n' + prompt, file=sys.stderr, flush=True)
                for key, label, explanation in items:
                    print(f'  {key}) {label}\n     {explanation}', file=sys.stderr)
                while True:
                    print(f'Enter = {default}; waiting for your selection (no timeout): ',
                          end='', file=sys.stderr, flush=True)
                    line = tty.readline()
                    if not line:
                        raise ValueError('Terminal closed; cancelled.')
                    answer = line.strip().lower() or default
                    if answer in options:
                        if answer not in unavailable:
                            return answer
                        print(unavailable[answer], file=sys.stderr)
                        continue
                    print('Choose one of: ' + ', '.join(options), file=sys.stderr)
            display = Display(stream=sys.stderr)
            previous = termios.tcgetattr(tty.fileno())
            def terminate(signum, _frame):
                raise SystemExit(128 + signum)
            previous_signal = signal.signal(signal.SIGTERM, terminate)
            message = ''
            sequence = ''
            number = ''
            def draw(width, frame, color, unicode):
                wide = bool(plan) and width >= 104
                w = width - 45 if wide else width
                left = [tint(title, '1;36', color), '']
                for key, label, explanation in items:
                    active = key == keys[selected]
                    marker = '›' if unicode else '>'
                    prefix = f'{marker if active else " "} {key}  '
                    rows = wrapped(label, w-5)
                    left += [tint(prefix + rows[0], '1;31' if key in danger else '1;36' if active else '1', color)]
                    left += ['     '+row for row in rows[1:]]
                    if explanation:
                        left += ['     '+tint(row, '90', color) for row in wrapped(explanation, w-6)]
                    left += ['']
                preview = dict(plan)
                if keys[selected] in options and isinstance(options, dict) and options[keys[selected]] in ('preserve', 'inplace', 'backup', 'erase'):
                    preview['mode'] = options[keys[selected]]
                if wide:
                    body = columns(left, disk_picture(preview, preview=True, frame=frame//4, color=color, unicode=unicode), width, color)
                else:
                    body = left
                    if preview:
                        body += wrapped('Disk: '+preview.get('disk', '')+' · '+preview.get('mode', '')+' plan', width)
                        body += wrapped('Preview: '+ METHODS[preview['mode']][1], width)
                footer = [tint(message or '↑ ↓ preview · number to select · Enter to confirm · Ctrl-C cancels', '33' if message else '90', color),
                          f'Enter = {keys[selected]}; waiting for your selection (no timeout): ']
                # Keep the consent control visible on small consoles; shorten
                # explanations before losing options or the selected drive.
                height = os.get_terminal_size(sys.stderr.fileno()).lines or 24
                if len(body) + 4 > height:
                    body = [line for line in body if clean(line).strip()]
                if len(body) + 4 > height:
                    count = max(1, height-10)
                    start = max(0, min(selected-count//2, len(items)-count))
                    body = [tint(title, '1;36', color)] + [
                        tint(('> ' if key == keys[selected] else '  ')+key+' '+clean(label),
                             '1;31' if key in danger else '1;36' if key == keys[selected] else '0', color)
                        for key, label, _ in items[start:start+count]]
                    chosen = next((ex for key, _, ex in items if key == keys[selected]), '')
                    body += wrapped(chosen, width)
                    if preview:
                        body += wrapped('Disk: '+preview.get('disk', ''), width)
                        body += disk_picture(preview, preview=True, color=color, unicode=unicode, width=width)[4:7]
                return '\n'.join(bounded(line, width)
                                 for line in ['zfsify  /  SETUP', ''] + body + footer)
            try:
                terminal.setcbreak(tty.fileno())
                while True:
                    display.paint(draw)
                    if not select.select([tty], [], [], .125)[0]:
                        continue
                    data = os.read(tty.fileno(), 1)
                    if not data or b'\x04' in data:
                        raise ValueError('Terminal closed; cancelled.')
                    for char in data.decode(errors='ignore'):
                        if sequence or char == '\x1b':
                            sequence += char
                            if sequence in ('\x1b[A', '\x1b[B'):
                                selected = (selected + (1 if sequence.endswith('B') else -1)) % len(keys)
                                sequence = ''
                                number = message = ''
                            elif len(sequence) >= 3:
                                sequence = ''
                            continue
                        if char in '\r\n':
                            if keys[selected] in unavailable:
                                message = unavailable[keys[selected]]
                            if not message:
                                return keys[selected]
                            number = ''
                            continue
                        if char.isdigit():
                            number += char
                            if number in keys:
                                selected = keys.index(number)
                                message = ''
                            else:
                                message = 'Choose ' + ', '.join(keys) + ', then press Enter.'
                            continue
                        if char in ('\x7f', '\b'):
                            number = number[:-1]
                            message = ''
                            if number in keys:
                                selected = keys.index(number)
                            continue
                        number = ''
                        if char.lower() in keys:
                            selected = keys.index(char.lower())
                            message = ''
                        else:
                            message = 'Choose ' + ', '.join(keys) + ', then press Enter.'
            finally:
                signal.signal(signal.SIGTERM, previous_signal)
                termios.tcsetattr(tty.fileno(), termios.TCSADRAIN, previous)
                display.close()
                print(file=sys.stderr, flush=True)
    except OSError:
        raise ValueError('Manual confirmation requires a terminal. Re-run in an interactive SSH session.') from None


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest='action', required=True)
    menu = sub.add_parser('menu')
    menu.add_argument('--kind', choices=['root', 'volume'], required=True)
    menu.add_argument('--disk', required=True)
    menu.add_argument('--source', default='')
    menu.add_argument('--platform', default='')
    menu.add_argument('--fstype', default='ext4')
    menu.add_argument('--size', type=int, required=True)
    menu.add_argument('--used', type=int, required=True)
    menu.add_argument('--preserve-capacity', type=int, required=True)
    menu.add_argument('--inplace-capacity', type=int, default=0)
    menu.add_argument('--yes', action='store_true')
    menu.add_argument('--mode', choices=['auto', 'preserve', 'inplace', 'backup', 'erase'], default='auto')
    menu.add_argument('--backup', default='')
    menu.add_argument('--erase-only', action='store_true')
    confirm = sub.add_parser('confirm')
    confirm.add_argument('--yes', action='store_true')
    confirm.add_argument('--label', required=True)
    confirm.add_argument('--mode', choices=['preserve', 'inplace', 'backup', 'erase'], required=True)
    destination = sub.add_parser('destination')
    destination.add_argument('--disk', required=True)
    destination.add_argument('--used', type=int, required=True)
    sub.add_parser('transport')
    args = p.parse_args()
    if args.action == 'destination':
        candidates = backup_candidates(args.disk, args.used)
        options = {str(i): item['path'] for i, item in enumerate(candidates, 1)}
        options.update(p='path', r='', q='q')
        choice = choose('Choose a backup destination. Free space is not permission to use a disk.',
                        '1' if candidates else 'r', options, title='Choose a disk for the backup', items=[
                            (str(i), item['path'] + (' [suggested; confirm use]' if i == 1 else ''),
                             f"{item['device']} on {item['disk']} · {item['free']/1e9:.1f}/{item['total']/1e9:.1f} GB free")
                            for i, item in enumerate(candidates, 1)] + [
                            ('p', 'Enter another directory', 'Choose the mount point of your backup volume.'),
                            ('r', 'Refresh disks', 'Attach and mount a volume, then refresh this list.'),
                            ('q', 'Back', '')])
        print(options[choice])
        return
    if args.action == 'confirm':
        if args.yes:
            print('Explicit non-interactive consent: proceeding with the selected plan.', file=sys.stderr)
            print('1')
            return
        from progress import METHODS
        precaution = ('ERASE: existing data will be deleted. ' if args.mode == 'erase' else '') + METHODS[args.mode][2]
        print('Make a full offsite backup before proceeding. This software is experimental.', file=sys.stderr)
        answer = choose(args.label, 'q', ['1', '2', 'q'], title='Ready to change this disk?', items=[
            ('1', 'Start conversion', precaution + ' ' + args.label + ' Make a full offsite backup first; conversion can destroy data.'),
            ('2', 'Go back · choose another method', 'No conversion starts until you confirm.'),
            ('q', 'Cancel [default]', 'Leave the disk as it is.')], danger=['1'] if args.mode == 'erase' else [])
        if answer == 'q':
            raise ValueError('Cancelled.')
        print(answer)
        return
    if args.action == 'transport':
        print(choose('Choose backup setup', '1', ['1', '2', '3', 'q'], title='Where should your backup live?', items=[
            ('1', 'An attached disk or cloud volume', 'Next: choose a mounted directory and explicitly approve its use.'),
            ('2', 'Set up cloud storage with rclone', 'Open rclone configuration, then choose your remote.'),
            ('3', 'Use an existing rclone remote', 'You provide remote:path; the archive stays there after conversion.'),
            ('q', 'Cancel', '')]))
        return
    backup = args.backup if args.backup not in ('', 'ask') else 'ask'
    default, preserve, inplace = recommended(args.size, args.used, args.preserve_capacity,
                                            args.inplace_capacity if args.kind == 'root' else 0)
    available = {'preserve': preserve, 'inplace': inplace and args.kind == 'root', 'backup': True, 'erase': True}
    if args.erase_only:
        available.update(preserve=False, inplace=False, backup=False)
    if args.mode != 'auto':
        default = args.mode
    from progress import METHODS
    labels = {key: value[0] for key, value in METHODS.items()}
    keys = {'1': 'preserve', '2': 'inplace', '3': 'backup', '4': 'erase'}
    plan = dict(kind=args.kind, disk=args.disk, source=args.source, platform=args.platform,
                fstype=args.fstype, size=args.size, used=args.used, mode=default)
    items = []
    for key, mode in keys.items():
        reason = '' if available[mode] else ('Unavailable with --erase.' if args.erase_only else
                 'unavailable for data volumes.' if mode == 'inplace' and args.kind != 'root' else 'Not enough working space.')
        label = labels[mode] + (' [recommended]' if mode == default and args.mode == 'auto' else '')
        description = METHODS[mode][2]
        if mode == 'erase':
            description = ('Fresh Ubuntu; keep /etc, accounts and SSH keys. Other files are not guaranteed.'
                           if args.kind == 'root' else 'Delete every file on this volume. The OS disk stays unchanged.')
        items.append((key, label, reason or description))
    items.append(('q', 'Cancel · leave this disk alone', ''))
    def save_plan(mode):
        plan['mode'] = mode
        if os.environ.get('ZFSIFY_UI_CONTEXT'):
            Path(os.environ['ZFSIFY_UI_CONTEXT']).write_text(json.dumps(plan))
    print('Make a full offsite backup before proceeding. Conversion can destroy data.', file=sys.stderr)
    if not available[default]:
        raise ValueError(f'{default} does not fit this disk; use automatic selection or --backup.')
    if args.yes and default == 'backup' and backup == 'ask':
        raise ValueError('Non-interactive backup requires --backup=/mounted/directory or --backup=remote:path. No destination was selected.')
    if args.yes or args.mode != 'auto':
        save_plan(default)
        print(f'Selected: {labels[default]} on {args.disk}', file=sys.stderr)
        print(default)
        print(backup)
        return
    default_key = next(k for k, v in keys.items() if v == default)
    choice = choose('Choose a method. You will review its plan before confirming conversion.',
                    default_key, {**keys, 'q':'cancel'}, title='How would you like to move to ZFS?', items=items, plan=plan,
                    unavailable={key: reason for key, _, reason in items if key in keys and not available[keys[key]]}, danger=['4'])
    if choice == 'q':
        raise ValueError('Cancelled.')
    mode = keys[choice]
    if not available[mode]:
        raise ValueError('That strategy is unavailable; cancelled without starting conversion.')
    save_plan(mode)
    print(mode)
    print(backup or 'ask')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyboardInterrupt) as error:
        print(f'\nzfsify: {error or "Cancelled."}', file=sys.stderr)
        sys.exit(2)
