#!/usr/bin/env python3
"""Build a standalone curl | sh installer without external script downloads."""
from pathlib import Path
import hashlib

root = Path(__file__).resolve().parent.parent
out = root / 'dist'
out.mkdir(exist_ok=True)
script = '''#!/bin/sh
# zfsify: preserve by default; --erase retains configuration and users only.
set -eu
if [ "$(id -u)" != 0 ]; then echo 'Run as root: curl -fsSL URL | sudo sh' >&2; exit 1; fi
work=$(mktemp -d /tmp/zfs-on-boot.XXXXXXXX)
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT
'''
for name in ['stage.sh', 'network.py', 'boot-config.py', 'ram-init.sh', 'target.sh', 'progress.py', 'plan.py', 'grow.sh', 'grow.service', 'status.sh', 'identity.py', 'ram-boot.sh', 'build-rescue.py', 'zbm-install.sh', 'zbm-build.sh', 'snapshot.sh', 'volume.sh', 'backup.sh', 'priority.py']:
    content = (root / 'src' / name).read_text()
    marker = 'ZFS_ON_BOOT_' + hashlib.sha256(content.encode()).hexdigest()
    script += f"cat > \"$work/{name}\" <<'{marker}'\n{content}\n{marker}\n"
script += 'bash "$work/stage.sh" "$work" "$@" </dev/null\n'
(out / 'install.sh').write_text(script)
(out / 'install.sh').chmod(0o755)
(out / 'SHA256SUMS').write_text(hashlib.sha256(script.encode()).hexdigest() + '  install.sh\n')
(root / 'reformat.sh').write_text(script)
(root / 'reformat.sh').chmod(0o755)
(root / 'install.sh').write_text(script)
(root / 'install.sh').chmod(0o755)
(root / 'SHA256SUMS').write_text(hashlib.sha256(script.encode()).hexdigest() + '  reformat.sh\n')
print(root / 'reformat.sh')
