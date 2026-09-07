#!/usr/bin/env python3
"""Minimal DO test resource lifecycle. Token is read only from the environment.

create --key-file /path/key.pub --state /private/path/state.json
status --state /private/path/state.json
destroy --state /private/path/state.json
"""
import argparse
import json
import os
from pathlib import Path
import urllib.request
import urllib.error
import uuid

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('action', choices=['create', 'status', 'destroy'])
p.add_argument('--state', type=Path, required=True)
p.add_argument('--key-file', type=Path)
p.add_argument('--region', default='sfo3')
p.add_argument('--size', default='s-1vcpu-1gb')
p.add_argument('--image', default='ubuntu-24-04-x64')
args = p.parse_args()
token = os.environ.get('DIGITALOCEAN_TOKEN')
if not token:
    p.error('DIGITALOCEAN_TOKEN must be set')

def api(path, method='GET', body=None):
    req = urllib.request.Request('https://api.digitalocean.com/v2' + path,
        data=json.dumps(body).encode() if body is not None else None,
        headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'},
        method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        if method == 'DELETE' and e.code == 404:
            return {}
        raise RuntimeError(f'DigitalOcean returned HTTP {e.code}') from None

def save(state):
    args.state.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(args.state, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        json.dump(state, f, indent=2)

if args.action == 'create':
    if args.state.exists():
        p.error('State file already exists; inspect/destroy its resources first')
    if not args.key_file:
        p.error('--key-file is required')
    name = 'zfs-on-boot-test-' + uuid.uuid4().hex[:10]
    key = api('/account/keys', 'POST', {'name': name, 'public_key': args.key_file.read_text().strip()})['ssh_key']
    state = {'name': name, 'ssh_key_id': key['id']}
    save(state)  # Record ownership before creating another billable resource.
    d = api('/droplets', 'POST', {'name': name, 'region': args.region,
        'size': args.size, 'image': args.image, 'ssh_keys': [key['id']],
        'ipv6': True, 'backups': False, 'monitoring': False})['droplet']
    state['droplet_id'] = d['id']
    save(state)
    print(json.dumps(state, indent=2))
elif args.action == 'status':
    state = json.loads(args.state.read_text())
    d = api('/droplets/' + str(state['droplet_id']))['droplet']
    print(json.dumps({'id': d['id'], 'name': d['name'], 'status': d['status'], 'networks': d['networks']}, indent=2))
else:
    state = json.loads(args.state.read_text())
    if 'droplet_id' in state:
        d = api('/droplets/' + str(state['droplet_id']))['droplet']
        if d['name'] != state['name'] or not d['name'].startswith('zfs-on-boot-test-'):
            p.error('Refusing deletion: test resource identity does not match state')
        api('/droplets/' + str(state['droplet_id']), 'DELETE')
        del state['droplet_id']
        save(state)
    if 'ssh_key_id' in state:
        api('/account/keys/' + str(state['ssh_key_id']), 'DELETE')
        del state['ssh_key_id']
        save(state)
    print('Deleted recorded test resources.')
