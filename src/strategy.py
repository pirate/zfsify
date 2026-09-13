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


def choose(prompt, default, options):
    """Read the controlling terminal, never the curl pipe; no unattended consent."""
    print(prompt, file=sys.stderr, flush=True)
    try:
        with open('/dev/tty', 'r') as tty:
            while True:
                print(f'Enter = {default}; waiting for your selection (no timeout): ',
                      end='', file=sys.stderr, flush=True)
                line = tty.readline()
                if not line:
                    raise ValueError('Terminal closed; cancelled.')
                answer = line.strip().lower() or default
                if answer in options:
                    return answer
                print('Choose one of: ' + ', '.join(options), file=sys.stderr)
    except OSError:
        raise ValueError('Manual confirmation requires a terminal. Re-run in an interactive SSH session.') from None


def heading(title, clear=False):
    # Presentation stays in progress.py; discovery never writes migration state.
    from progress import phase_header
    color = sys.stderr.isatty() and 'NO_COLOR' not in os.environ
    width = os.get_terminal_size(sys.stderr.fileno()).columns - 1 if sys.stderr.isatty() else 100
    if clear and sys.stderr.isatty():
        print('\033[2J\033[H', end='', file=sys.stderr)
    print(('' if clear else '\n') + '\n'.join(phase_header(1, width, color=color)) + '\n\n' + title + '\n', file=sys.stderr)


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
        print('Candidate destinations (space available does not mean a disk is reserved for backups):', file=sys.stderr)
        for i, item in enumerate(candidates, 1):
            print(f"  {i}) {item['path']} — {item['device']} on {item['disk']}; "
                  f"{item['free']/1e9:.1f}/{item['total']/1e9:.1f} GB free"
                  + (' [recommended by free-space ratio; confirm ownership/use]' if i == 1 else ''), file=sys.stderr)
        options = {str(i): item['path'] for i, item in enumerate(candidates, 1)}
        options.update(p='path', r='', q='q')
        choice = choose('  p) Enter another directory  r) Refresh disks  q) Back',
                        '1' if candidates else 'r', options)
        print(options[choice])
        return
    if args.action == 'confirm':
        if args.yes:
            print('Explicit non-interactive consent: proceeding with the selected plan.', file=sys.stderr)
            print('1')
            return
        heading('⚠  Make a full offsite backup before proceeding. This software is experimental.')
        answer = choose(args.label + '\n\n  1) Confirm backup precaution and start conversion\n  2) Review all methods\n  q) Cancel [default]', 'q', ['1', '2', 'q'])
        if answer == 'q':
            raise ValueError('Cancelled.')
        print(answer)
        return
    if args.action == 'transport':
        print(choose('Choose backup setup: 1) attached Volume  2) rclone config  3) existing remote  q) cancel',
                     '1', ['1', '2', '3', 'q']))
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
    heading('Select a conversion method', clear=True)
    print('Make a full offsite backup before proceeding. Conversion can destroy data.', file=sys.stderr)
    print(f'\nMigration options for {args.disk} ({args.used/1e9:.2f}/{args.size/1e9:.2f} GB used):', file=sys.stderr)
    for key, mode in keys.items():
        reason = '' if available[mode] else (' — rerun without --erase to assess preservation' if args.erase_only else ' — unavailable for data volumes' if mode == 'inplace' and args.kind != 'root'
                  else ' — unavailable: insufficient working space')
        line = f'  {key}) {labels[mode]}{reason}' + (' ◀ RECOMMENDED' if mode == default and args.mode == 'auto' else ' ◀ SELECTED' if mode == default else '')
        if mode == default and sys.stderr.isatty() and 'NO_COLOR' not in os.environ:
            line = '\033[1;36m' + line + '\033[0m'
        print(line + '\n', file=sys.stderr)
    print('  q) Cancel\nExternal backup needs a destination you explicitly select. Review the plan before conversion.', file=sys.stderr)
    if not available[default]:
        raise ValueError(f'{default} does not fit this disk; use automatic selection or --backup.')
    if args.yes and default == 'backup' and backup == 'ask':
        raise ValueError('Non-interactive backup requires --backup=/mounted/directory or --backup=remote:path. No destination was selected.')
    if args.yes or args.mode != 'auto':
        print(default)
        print(backup)
        return
    default_key = next(k for k, v in keys.items() if v == default)
    choice = choose('Choose a method. You will review its plan before confirming conversion.',
                    default_key, [*keys, 'q'])
    if choice == 'q':
        raise ValueError('Cancelled.')
    mode = keys[choice]
    if not available[mode]:
        raise ValueError('That strategy is unavailable; cancelled without starting conversion.')
    print(mode)
    print(backup or 'ask')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyboardInterrupt) as error:
        print(f'\nzfsify: {error or "Cancelled."}', file=sys.stderr)
        sys.exit(2)
