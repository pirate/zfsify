#!/usr/bin/python3
"""Build a small disk-independent boot shim; execute only on the target Ubuntu VPS."""
from pathlib import Path
import hashlib
import re
import shutil
import subprocess
import sys
root, shim, source = map(Path, sys.argv[1:4])
kernel, uuid = sys.argv[4:6]
shim.mkdir()
for name in ['bin', 'sbin', 'usr/bin', 'usr/sbin', 'dev', 'proc', 'sys']:
    (shim/name).mkdir(parents=True, exist_ok=True)
def copy(path):
    dest = shim/path.lstrip('/')
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root/path.lstrip('/'), dest)
copy('/usr/bin/busybox')
shutil.copy2(shim/'usr/bin/busybox', shim/'bin/busybox')
for binary, alias in [('/usr/bin/kmod', '/sbin/modprobe'), ('/usr/sbin/blkid', '/sbin/blkid')]:
    copy(binary)
    shutil.copy2(shim/binary.lstrip('/'), shim/alias.lstrip('/'))
    ldd = subprocess.check_output(['chroot', str(root), 'ldd', binary], text=True)
    for path in re.findall(r'(/[^\s()]+)', ldd): copy(path)
modules = []
required = ['ext4', 'loop', 'squashfs', 'overlay']
controllers = ['virtio_pci', 'virtio_blk', 'virtio_scsi', 'scsi_mod', 'sd_mod', 'nvme', 'nvme_core', 'ahci', 'libata', 'hv_vmbus', 'hv_storvsc']
for module in controllers + required:
    deps = subprocess.run(['chroot', str(root), 'modprobe', '--show-depends', '--set-version', kernel, module], text=True, capture_output=True)
    if deps.returncode:
        if module in required: raise RuntimeError('Missing required rescue module: '+module)
        continue
    modules.append(module)
    for line in deps.stdout.splitlines():
        if line.startswith('insmod '): copy(line.split()[1])
for path in (root/'lib/modules'/kernel).glob('modules.*'):
    if path.is_file(): copy('/lib/modules/'+kernel+'/'+path.name)
shutil.copy2(source/'ram-boot.sh', shim/'init')
(shim/'init').chmod(0o755)
image = root.parent/'rescue.squashfs'
with image.open('rb') as stream:
    hasher = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024*1024), b''): hasher.update(chunk)
    digest = hasher.hexdigest()
(shim/'config').write_text(f'SOURCE_UUID={uuid}\nRESCUE_SHA={digest}\nMODULES="{" ".join(modules)}"\n')
