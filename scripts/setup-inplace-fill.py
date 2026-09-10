#!/usr/bin/env python3
"""Fill a disposable root fixture beyond 50% with incompressible file data."""
import hashlib
import os
from pathlib import Path
import subprocess

fixture = Path('/root/migration-fixture')
assert fixture.is_dir() and Path('/root/migration-fixture.SHA256SUMS').is_file()
assert subprocess.check_output(['findmnt', '-no', 'FSTYPE', '/']).strip() == b'ext4'
size, used = map(int, subprocess.check_output(
    ['df', '-B1', '--output=size,used', '/'], text=True).splitlines()[-1].split())
# Keep the installer's staging allowance even on a 10 GB machine.
desired = min(size * 70 // 100, size - 3_900_000_000)
assert desired > size // 2, 'Test disk too small to fill beyond 50% and stage rescue'
remaining = max(0, desired - used)
path = fixture / 'large.bin'
h = hashlib.sha256()
with path.open('xb') as stream:
    while remaining:
        data = os.urandom(min(4 * 1024**2, remaining))
        stream.write(data)
        h.update(data)
        remaining -= len(data)
    stream.flush()
    os.fsync(stream.fileno())
with open('/root/migration-fixture.SHA256SUMS', 'a') as stream:
    stream.write(f'{h.hexdigest()}  {path}\n')
subprocess.run(['df', '-B1', '/'], check=True)
