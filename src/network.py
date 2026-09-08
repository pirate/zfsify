#!/usr/bin/env python3
"""Capture hardware NIC addresses and main-table routes for the RAM installer."""
import json
from pathlib import Path
import shlex
import subprocess
import sys


def ip(*args):
    return json.loads(subprocess.check_output(['ip', '-j', *args]))


def render(links, routes):
    q = shlex.quote
    lines = ['#!/bin/bash', 'set -eu', 'ip link set lo up']
    for link in links:
        name, mac = link['ifname'], link['address']
        lines += [
            f'iface=$(for p in /sys/class/net/*; do if [ "$(cat "$p/address")" = {q(mac)} ]; then basename "$p"; break; fi; done)',
            '[ -n "$iface" ]',
            f'ip link set "$iface" mtu {int(link["mtu"])} up',
        ]
        for addr in link.get('addr_info', []):
            if addr['scope'] == 'global':
                lines.append(f'ip addr replace {q(addr["local"] + "/" + str(addr["prefixlen"]))} dev "$iface"')
        for family in ['-4', '-6']:
            # ip route show usually lists the default first. With a /32 address,
            # its gateway needs an explicit direct route before a via route works.
            # Keep kernel-protocol host routes too: adding the address alone does
            # not recreate a provider gateway outside the address's own prefix.
            for route in sorted(routes[(name, family)], key=lambda r: 'gateway' in r):
                if route.get('dst', '').startswith('fe80:'):
                    continue
                cmd = f'ip {family} route replace {q(route.get("dst", "default"))}'
                if 'gateway' in route:
                    cmd += ' via ' + q(route['gateway'])
                cmd += ' dev "$iface"'
                if 'scope' in route:
                    cmd += ' scope ' + q(route['scope'])
                if 'prefsrc' in route:
                    cmd += ' src ' + q(route['prefsrc'])
                if 'metric' in route:
                    cmd += ' metric ' + str(route['metric'])
                if 'onlink' in route.get('flags', []):
                    cmd += ' onlink'
                lines.append(cmd)
    return '\n'.join(lines) + '\n'


if __name__ == '__main__':
    # RAM boot recreates hardware NICs, not Docker bridges or veth pairs.
    links = [link for link in ip('address', 'show')
             if link['ifname'] != 'lo' and link.get('address')
             and Path('/sys/class/net', link['ifname'], 'device').exists()]
    routes = {(link['ifname'], family): ip(family, 'route', 'show', 'dev', link['ifname'])
              for link in links for family in ['-4', '-6']}
    Path(sys.argv[1]).write_text(render(links, routes))
