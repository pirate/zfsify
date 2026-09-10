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

# Verify GRUB accepts the command containing quoted kernel values.
script = ('menuentry test {\n linux /vmlinuz ' + result['grub'] + ' rdinit=/init panic=0\n}\n')
subprocess.run(['grub-script-check'], input=script, text=True, check=True)
print('PASS: inherited console/hardware options; old root/resume/init removed; GRUB syntax and quoted values')
