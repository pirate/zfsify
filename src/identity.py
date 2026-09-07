#!/usr/bin/python3
"""Restore account configuration without breaking the fresh OS's system ownership."""
import os
from pathlib import Path
import stat
import subprocess
import sys
import tarfile

root = Path(sys.argv[1])
archive = Path(sys.argv[2])
with tarfile.open(archive) as tar:
    old = {name: tar.extractfile('etc/'+name).read().decode().splitlines()
           for name in ('passwd','group','shadow','gshadow')}
fresh = {name: (root/'etc'/name).read_text().splitlines() for name in old}

def records(lines): return {line.split(':')[0]: line.split(':') for line in lines if line and not line.startswith('#')}
new_ids = {}
for db in ('group','passwd'):
    original = records(old[db]); base = records(fresh[db])
    occupied = {int(row[2]) for row in original.values()}
    for name, row in base.items():
        if name not in original:
            number = int(row[2])
            if number in occupied: number = next(n for n in range(100, 1000) if n not in occupied)
            occupied.add(number)
            added = row.copy(); added[2] = str(number)
            if db == 'passwd': added[3] = str(new_ids['group'].get(int(row[3]), int(row[3])))
            old[db].append(':'.join(added)); original[name] = added
    new_ids[db] = {int(row[2]): int(original[name][2]) for name, row in base.items()}
for db in ('shadow','gshadow'):
    existing = records(old[db])
    old[db] += [line for line in fresh[db] if line.split(':')[0] not in existing]

# Translate ownership by account name before restoring /etc. Preserve modes and
# capabilities that chown can otherwise clear, and handle hard-linked files once.
seen = set()
for directory, dirs, files in os.walk(root, followlinks=False):
    for path in [Path(directory), *(Path(directory)/name for name in files),
                 *(Path(directory)/name for name in dirs if (Path(directory)/name).is_symlink())]:
        st = path.lstat(); key = (st.st_dev, st.st_ino)
        if key in seen: continue
        seen.add(key)
        uid = new_ids['passwd'].get(st.st_uid, st.st_uid)
        gid = new_ids['group'].get(st.st_gid, st.st_gid)
        if (uid, gid) == (st.st_uid, st.st_gid): continue
        try: cap = os.getxattr(path, 'security.capability', follow_symlinks=False)
        except OSError: cap = None
        os.chown(path, uid, gid, follow_symlinks=False)
        if not stat.S_ISLNK(st.st_mode): os.chmod(path, stat.S_IMODE(st.st_mode))
        if cap is not None: os.setxattr(path, 'security.capability', cap, follow_symlinks=False)

subprocess.run(['tar','--numeric-owner','--acls','--xattrs',
                '--exclude=etc/alternatives','--exclude=etc/ld.so.cache',
                '-xpf',str(archive),'-C',str(root)],check=True)
for name, lines in old.items(): (root/'etc'/name).write_text('\n'.join(lines)+'\n')
# Original software selection links cannot point into an erased OS. Keep its
# configuration, but disable local service definitions until their app is restored.
units = root/'etc/systemd/system'
for link in units.glob('*.wants/*'):
    if link.is_symlink() and (units/link.name).is_file() and not (units/link.name).is_symlink():
        print('Disabled carried-over local unit:', link.name)
        link.unlink()
print('Restored /etc and account records; translated fresh system-file ownership.')
