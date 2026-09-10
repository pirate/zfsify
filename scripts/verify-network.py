#!/usr/bin/env python3
"""Run only on a disposable test VM; uses isolated Linux netns."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
from network import render


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True, **kwargs).stdout


def check_case(label, prefix, gateway_protocol=None, onlink=False, ipv6=False):
    ns = 'zfsify-net-' + uuid.uuid4().hex[:8]
    family = '-6' if ipv6 else '-4'
    address = '2001:db8:1::2' if ipv6 else '192.0.2.2'
    gateway = '2001:db8:2::1' if ipv6 else ('198.51.100.1' if prefix == 32 else '192.0.2.1')
    probe = '2001:db8:3::1' if ipv6 else '203.0.113.1'

    def ip(*args):
        return run('ip', '-n', ns, *args)

    run('ip', 'netns', 'add', ns)
    try:
        ip('link', 'add', 'net0', 'type', 'dummy')
        ip('link', 'set', 'net0', 'mtu', '1400', 'up')
        # Keep DAD from delaying this isolated test; no outside network is attached.
        run('ip', 'netns', 'exec', ns, 'sysctl', '-qw', 'net.ipv6.conf.net0.accept_dad=0')
        ip('addr', 'add', f'{address}/{prefix}', 'dev', 'net0')
        if gateway_protocol:
            ip(family, 'route', 'add', gateway, 'dev', 'net0', 'scope', 'link', 'proto', gateway_protocol)
        ip(family, 'route', 'add', 'default', 'via', gateway, 'dev', 'net0', 'metric', '123',
           *(['onlink'] if onlink else []))
        links = [link for link in json.loads(ip('-j', 'address', 'show')) if link['ifname'] == 'net0']
        routes = {('net0', fam): json.loads(ip('-j', fam, 'route', 'show', 'dev', 'net0'))
                  for fam in ['-4', '-6']}
        script = render(links, routes)
        ip(family, 'route', 'flush', 'dev', 'net0')
        ip('addr', 'flush', 'dev', 'net0', 'scope', 'global')
        ip('link', 'set', 'net0', 'mtu', '1500')
        if prefix == 32 and gateway_protocol:
            # The old default-first replay hits the same kernel error as issue #1.
            ip('addr', 'add', f'{address}/{prefix}', 'dev', 'net0')
            failed = subprocess.run(['ip', '-n', ns, family, 'route', 'add', 'default',
                                     'via', gateway, 'dev', 'net0'], text=True, capture_output=True)
            assert failed.returncode != 0 and 'invalid gateway' in failed.stderr, failed
            ip('addr', 'flush', 'dev', 'net0', 'scope', 'global')
        run('ip', 'netns', 'exec', ns, 'bash', '-eu', input=script)
        # Replay a second time too: recovery must tolerate already restored routes.
        run('ip', 'netns', 'exec', ns, 'bash', '-eu', input=script)
        result = json.loads(ip('-j', family, 'route', 'get', probe))[0]
        assert result['gateway'] == gateway and result['dev'] == 'net0', result
        assert result['prefsrc'] == address, result
        default = json.loads(ip('-j', family, 'route', 'show', 'default'))[0]
        assert default['metric'] == 123, default
        assert ('onlink' in default.get('flags', [])) == onlink, default
        assert json.loads(ip('-j', 'link', 'show', 'net0'))[0]['mtu'] == 1400
        print(f'PASS: {label} (kernel route lookup, repeat replay, MTU)', flush=True)
    finally:
        run('ip', 'netns', 'delete', ns)


check_case('IPv4 /32 with DHCP gateway host route', 32, 'dhcp')
check_case('IPv4 /32 with kernel gateway host route', 32, 'kernel')
check_case('IPv4 directly connected /24 gateway', 24)
check_case('IPv4 /32 explicitly onlink gateway', 32, onlink=True)
check_case('IPv6 /128 with gateway host route', 128, 'static', ipv6=True)
check_case('IPv6 /128 explicitly onlink gateway', 128, onlink=True, ipv6=True)

# Exercise the CLI capture path with the VM's real multi-NIC state. Replay on
# renamed dummy NICs in a namespace, leaving the VM's SSH network untouched.
ns = 'zfsify-net-' + uuid.uuid4().hex[:8]
run('ip', 'netns', 'add', ns)
try:
    links = [link for link in json.loads(run('ip', '-j', 'address', 'show'))
             if Path('/sys/class/net', link['ifname'], 'device').exists()]
    for i, link in enumerate(links):
        name = f'renamed{i}'
        run('ip', '-n', ns, 'link', 'add', name, 'address', link['address'], 'type', 'dummy')
        run('ip', 'netns', 'exec', ns, 'sysctl', '-qw', f'net.ipv6.conf.{name}.accept_dad=0')
    with tempfile.TemporaryDirectory() as tmp:
        script = Path(tmp) / 'network.sh'
        run(sys.executable, str(Path(__file__).resolve().parents[1] / 'src/network.py'), str(script))
        run('ip', 'netns', 'exec', ns, 'bash', str(script))
        run('ip', 'netns', 'exec', ns, 'bash', str(script))
    for family, probe in [('-4', '1.1.1.1'), ('-6', '2606:4700:4700::1111')]:
        if json.loads(run('ip', '-j', family, 'route', 'show', 'default')):
            original = json.loads(run('ip', '-j', family, 'route', 'get', probe))[0]
            restored = json.loads(run('ip', '-n', ns, '-j', family, 'route', 'get', probe))[0]
            assert original.get('gateway') == restored.get('gateway'), restored
            assert original.get('prefsrc') == restored.get('prefsrc'), restored
    print(f'PASS: live capture of {len(links)} hardware NICs; MAC matching after rename, IPv4/IPv6 replay', flush=True)
finally:
    run('ip', 'netns', 'delete', ns)
