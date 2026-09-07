#!/usr/bin/python3
"""Select complete optional files for erase mode within a conservative RAM budget."""
import os
from pathlib import Path
import stat
import sys
budget = int(sys.argv[1]); output = Path(sys.argv[2]); rootdev = os.stat('/').st_dev
excluded = ('/var/lib/zfs-on-boot', '/var/lib/dpkg', '/var/lib/apt', '/var/cache/apt',
            '/var/lib/cloud', '/var/lib/systemd', '/var/log/zfs-on-boot', '/root/.cache')
used = logical = omitted = 0
seen = set(); parents = set(); preview = []
def paths(base):
    try: info = os.lstat(base)
    except FileNotFoundError: return
    if info.st_dev != rootdev or any(base == p or base.startswith(p+'/') for p in excluded): return
    if stat.S_ISDIR(info.st_mode):
        with os.scandir(base) as entries:
            for entry in entries: yield from paths(entry.path)
    elif stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
        yield base, info
with output.open('wb') as selected, output.with_suffix('.manifest').open('w') as manifest:
    priority = ('/root', '/home', '/var', '/opt', '/srv', '/usr/local')
    skip = {'etc','root','home','var','opt','srv','usr','bin','sbin','lib','lib32','lib64','libx32','boot','dev','proc','sys','run','tmp','mnt','media','lost+found','swapfile','swap.img','vmlinuz','vmlinuz.old','initrd.img','initrd.img.old'}
    additional = [entry.path for entry in os.scandir('/') if entry.name not in skip]
    for base in (*priority, *additional):
        for name, info in paths(base):
            # Account SSH contents are captured as mandatory identity, independently.
            if '/.ssh/' in name: continue
            key = info.st_dev, info.st_ino
            cost = 4096 + (info.st_blocks*512 if stat.S_ISREG(info.st_mode) and key not in seen else 0)
            ancestry = [str(p) for p in Path(name).parents if str(p) != '/' and str(p) not in parents]
            cost += 4096 * len(ancestry)
            if used + cost > budget:
                omitted += info.st_size
                manifest.write('OMIT\t'+name+'\n'); continue
            used += cost; logical += info.st_size; seen.add(key)
            for parent in reversed(ancestry):
                selected.write(os.fsencode(parent.lstrip('/'))+b'\0'); parents.add(parent)
            selected.write(os.fsencode(name.lstrip('/'))+b'\0')
            manifest.write('KEEP\t'+name+'\n')
            if len(preview) < 30: preview.append(name)
print(f'Priority restore: {logical/1e9:.3f} GB of {((logical+omitted)/1e9):.3f} GB eligible optional logical file data selected.')
print(f'Archive budget: {budget/1e6:.1f} MB; conservative selected allocation: {used/1e6:.1f} MB.')
print('Accounts, SSH contents, and /etc are mandatory and retained separately.')
print('Fresh Ubuntu supplies core libraries, kernels, and package databases. Omitted files will be lost.')
print('First selected files:\n'+'\n'.join(preview))
print('Complete KEEP/OMIT preview:', output.with_suffix('.manifest'))
