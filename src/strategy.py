#!/usr/bin/env python3
"""Read-only strategy discovery and timed choices; never format or mount disks."""
import argparse
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import time

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


def choose(prompt, default, options, seconds=15):
    """Read /dev/tty, never the curl pipe. Invalid/partial input never means consent."""
    print(prompt, file=sys.stderr, flush=True)
    try:
        tty = open('/dev/tty', 'r')
    except OSError:
        tty = None
    try:
        if seconds is None:
            if tty is None:
                raise ValueError('Manual confirmation requires a terminal. Re-run in an interactive SSH session.')
            print(f'Enter = {default}; waiting for your selection (no timeout): ',
                  end='', file=sys.stderr, flush=True)
            line = tty.readline()
            if not line:
                raise ValueError('Terminal closed; cancelled.')
            answer = line.strip().lower() or default
            if answer not in options:
                raise ValueError('Unknown choice; cancelled.')
            return answer
        deadline = time.monotonic() + seconds
        while True:
            left = max(0, deadline - time.monotonic())
            print(f'\rEnter = {default}; starting in {int(left + .999):2d}s (Ctrl-C cancels). ',
                  end='', file=sys.stderr, flush=True)
            if tty and select.select([tty], [], [], min(1, left))[0]:
                answer = tty.readline().strip().lower()
                print(file=sys.stderr)
                if not answer:
                    return default
                if answer not in options:
                    raise ValueError('Unknown choice; cancelled without starting conversion.')
                return answer
            if not tty:
                time.sleep(min(1, left))
            if time.monotonic() >= deadline:
                # A partially typed answer must not be silently ignored at timeout.
                if tty:
                    import termios
                    old = termios.tcgetattr(tty)
                    new = old.copy(); new[3] &= ~termios.ICANON
                    try:
                        termios.tcsetattr(tty, termios.TCSANOW, new)
                        if select.select([tty], [], [], 0)[0]:
                            raise ValueError('Unfinished choice; cancelled without starting conversion.')
                    finally:
                        termios.tcsetattr(tty, termios.TCSANOW, old)
                print(file=sys.stderr)
                return default
    finally:
        if tty:
            tty.close()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest='action', required=True)
    menu = sub.add_parser('menu')
    menu.add_argument('--kind', choices=['root', 'volume'], required=True)
    menu.add_argument('--disk', required=True)
    menu.add_argument('--size', type=int, required=True)
    menu.add_argument('--used', type=int, required=True)
    menu.add_argument('--preserve-capacity', type=int, required=True)
    menu.add_argument('--inplace-capacity', type=int, default=0)
    menu.add_argument('--mode', choices=['auto', 'preserve', 'inplace', 'backup', 'erase'], default='auto')
    menu.add_argument('--backup', default='')
    menu.add_argument('--erase-only', action='store_true')
    menu.add_argument('--explicit', action='store_true')
    confirm = sub.add_parser('confirm')
    confirm.add_argument('--label', required=True)
    confirm.add_argument('--explicit', action='store_true')
    confirm.add_argument('--mode', choices=['preserve', 'inplace', 'backup', 'erase'], required=True)
    destination = sub.add_parser('destination')
    destination.add_argument('--disk', required=True)
    destination.add_argument('--used', type=int, required=True)
    transport = sub.add_parser('transport')
    args = p.parse_args()
    if args.action == 'destination':
        candidates = backup_candidates(args.disk, args.used)
        print('Candidate destinations (space available does not mean a disk is reserved for backups):', file=sys.stderr)
        for i, item in enumerate(candidates, 1):
            print(f"  {i}) {item['path']} — {item['device']} on {item['disk']}; "
                  f"{item['free']/1e9:.1f}/{item['total']/1e9:.1f} GB free"
                  + (' [recommended by free-space ratio; confirm ownership/use]' if i == 1 else ''), file=sys.stderr)
        options = {str(i): item['path'] for i, item in enumerate(candidates, 1)}
        options.update(p='path', r='', q='q')
        choice = choose('  p) Enter another directory  r) Refresh disks  q) Back',
                        '1' if candidates else 'r', options, seconds=None)
        print(options[choice])
        return
    if args.action == 'confirm':
        if args.explicit:
            print('1')
            return
        answer = choose(args.label + '\n  1) Proceed with this plan\n  2) Review all strategies\n  q) Cancel', '1', ['1', '2', 'q'], seconds=15 if args.mode in ('preserve', 'inplace') else None)
        if answer == 'q':
            raise ValueError('Cancelled.')
        print(answer)
        return
    if args.action == 'transport':
        print(choose('Choose backup setup: 1) attached Volume  2) rclone config  3) existing remote  q) cancel',
                     '1', ['1', '2', '3', 'q'], seconds=None))
        return
    backup = args.backup if args.backup not in ('', 'ask') else 'ask'
    default, preserve, inplace = recommended(args.size, args.used, args.preserve_capacity,
                                            args.inplace_capacity if args.kind == 'root' else 0)
    available = {'preserve': preserve, 'inplace': inplace and args.kind == 'root', 'backup': True, 'erase': True}
    if args.erase_only:
        available.update(preserve=False, inplace=False, backup=False)
    if args.mode != 'auto':
        default = args.mode
    labels = {'preserve': '50/50: keep ext4 until the ZFS copy is verified',
              'inplace': 'Slice-by-slice: recycle verified ext4 blocks (experimental)',
              'backup': 'External backup: verify an independent archive, then restore',
              'erase': 'ERASE: discard data; root gets limited settings restoration'}
    keys = {'1': 'preserve', '2': 'inplace', '3': 'backup', '4': 'erase'}
    print(f'\nMigration options for {args.disk} ({args.used/1e9:.2f}/{args.size/1e9:.2f} GB used):', file=sys.stderr)
    for key, mode in keys.items():
        reason = '' if available[mode] else (' — rerun without --erase to assess preservation' if args.erase_only else ' — unavailable for data volumes' if mode == 'inplace' and args.kind != 'root'
                  else ' — unavailable: insufficient working space')
        print(f'  {key}) {labels[mode]}{reason}' + (' [default]' if mode == default else ''), file=sys.stderr)
    print('  q) Cancel\nExternal backup always requires manual destination selection and confirmation.', file=sys.stderr)
    if not available[default]:
        raise ValueError(f'{default} does not fit this disk; use automatic selection or --backup.')
    if args.explicit:
        print(default)
        print(backup)
        return
    default_key = next(k for k, v in keys.items() if v == default)
    choice = choose('Choose a strategy. Erase requires --erase or explicit confirmation.', default_key, [*keys, 'q'],
                    seconds=15 if default in ('preserve', 'inplace') else None)
    if choice == 'q':
        raise ValueError('Cancelled.')
    mode = keys[choice]
    if not available[mode]:
        raise ValueError('That strategy is unavailable; cancelled without starting conversion.')
    if mode == 'erase' and args.mode != 'erase':
        try:
            with open('/dev/tty', 'r') as tty:
                print('Type y and press Enter to confirm data loss: ', end='', file=sys.stderr, flush=True)
                if tty.readline().strip() != 'y':
                    raise ValueError('Erase cancelled.')
        except OSError:
            raise ValueError('Erase needs explicit --erase or terminal confirmation.') from None
    print(mode)
    print(backup or 'ask')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyboardInterrupt) as error:
        print(f'\nzfsify: {error or "Cancelled."}', file=sys.stderr)
        sys.exit(2)
