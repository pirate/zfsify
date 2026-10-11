#!/usr/bin/env python3
"""Run on a disposable DO VM: boot argument filtering and GRUB serialization."""
import importlib.util
from pathlib import Path
import shlex
import subprocess

source = Path(__file__).resolve().parents[1] / 'src/boot-config.py'
spec = importlib.util.spec_from_file_location('boot_config', source)
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)

original = ('BOOT_IMAGE=/boot/vmlinuz root=UUID=old rootfstype=ext4 rootflags=discard '
            'resume=UUID=oldswap resume_offset=123 ro initrd=/old/initrd '
            'console=hvc0 console=ttyS1,57600n8 earlycon=uart8250,io,0x2f8 '
            'nomodeset video=1024x768 pci=nomsi iommu=soft clocksource=tsc '
            'nvme_core.default_ps_max_latency_us=0 mitigations=auto '
            'audit=1 quiet splash panic=10 systemd.unit=emergency.target '
            'rd.break zbm.timeout=0 test.value="two words" -- init-argument')
result = config.commandlines(original)
args = shlex.split(result['ubuntu'])
for arg in ['console=hvc0', 'console=ttyS1,57600n8', 'earlycon=uart8250,io,0x2f8',
            'nomodeset', 'video=1024x768', 'pci=nomsi', 'iommu=soft',
            'clocksource=tsc', 'nvme_core.default_ps_max_latency_us=0',
            'mitigations=auto', 'audit=1', 'test.value=two words']:
    assert arg in args, arg
for arg in args:
    assert arg.split('=', 1)[0] not in config.REPLACED
    assert arg not in ['zbm.timeout=0', 'init-argument']
assert 'console=ttyS0,115200n8' not in args
assert 'quiet' in args and 'panic=10' in args
assert 'quiet' not in shlex.split(result['rescue'])
assert 'panic=10' not in shlex.split(result['rescue'])
assert shlex.split(config.commandlines('root=/dev/vda1 ro', ['tty0', 'ttyAMA0'])['ubuntu']) == [
    'console=tty0', 'console=ttyAMA0']
assert config.commandlines('console="ttyS1,57600n8"')['ubuntu'] == 'console="ttyS1,57600n8"'

# Dual-console cloud images must expose passphrase/menu input to VNC. Keep
# serial diagnostics and leave the installed Ubuntu's original console order.
dual = 'console=tty1 console=ttyS0,115200 net.ifnames=0'
visible = config.commandlines(dual, ['tty1', 'ttyS0'], display=True)
assert visible['ubuntu'] == dual
assert shlex.split(visible['rescue'])[-1] == 'console=tty1'
assert 'console=ttyS0,115200' in visible['rescue']
assert shlex.split(visible['grub']) == shlex.split(visible['rescue'])
assert config.commandlines(dual, ['tty1', 'ttyS0'], display=False)['rescue'] == dual
assert config.commandlines(dual, ['ttyS0'], display=True)['rescue'] == dual
serial = 'console=ttyAMA0,115200 console=hvc0'
assert config.commandlines(serial, ['ttyAMA0', 'hvc0'], display=True)['rescue'] == serial
assert config.commandlines('console="tty1" console=ttyS0', ['tty1', 'ttyS0'], display=True)['rescue'].endswith('console="tty1"')

# Verify GRUB accepts the command containing quoted kernel values.
for options in (result, visible):
    script = ('menuentry test {\n linux /vmlinuz ' + options['grub'] + ' rdinit=/init panic=0\n}\n')
    subprocess.run(['grub-script-check'], input=script, text=True, check=True)
print('PASS: inherited hardware options; display-console preference and serial fallback; old root/resume/init removed; GRUB syntax and quoted values')
