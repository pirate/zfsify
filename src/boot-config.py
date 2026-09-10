#!/usr/bin/env python3
"""Retain existing boot options while replacing the old root/initramfs contract."""
from pathlib import Path
import re
import shlex
import sys

# These identify the old filesystem or a one-shot boot mode, not the hardware.
REPLACED = {
    'BOOT_IMAGE', 'BOOTIF', 'root', 'rootfstype', 'rootflags', 'rootdelay',
    'rootwait', 'resume', 'resume_offset', 'initrd', 'init', 'rdinit', 'boot',
    'ro', 'rw', 'single', 'emergency', 'rescue', 'rd.break', 'break',
    'systemd.unit', 'rd.systemd.unit',
}


def commandlines(text, consoles=('tty0',)):
    # Linux command lines use double quotes, not shell evaluation. Retain their
    # spelling, including quoted values containing spaces, for the final kernel.
    tokens = re.findall(r'(?:[^\s"]|"[^"]*")+', text)
    kept = []
    for token in tokens:
        if token == '--':
            break  # Following words are init arguments, not kernel options.
        key = token.split('=', 1)[0].strip('"')
        if key in REPLACED or key.startswith(('zbm.', 'systemd.run')):
            continue
        kept.append(token)
    if not any(t.split('=', 1)[0].strip('"') == 'console' for t in kept):
        kept += ['console=' + console for console in consoles]
    # Keep diagnostics visible and leave the RAM/ZBM init program in control.
    # All other existing CPU, PCI, I/O, display and driver options pass through.
    rescue = [t for t in kept if t.split('=', 1)[0].strip('"') not in
              {'quiet', 'splash', 'vt.handoff', 'panic'}
              and not t.split('=', 1)[0].strip('"').startswith(('systemd.', 'rd.', 'zfs.', 'spl.'))]
    return {'ubuntu': ' '.join(kept), 'rescue': ' '.join(rescue),
            'grub': ' '.join(shlex.quote(t) for t in rescue)}


if __name__ == '__main__':
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    active = Path('/sys/class/tty/console/active')
    consoles = active.read_text().split() if active.exists() else ['tty0']
    for name, value in commandlines(Path('/proc/cmdline').read_text(), consoles or ['tty0']).items():
        (out / ('cmdline-' + name)).write_text(value + '\n')
