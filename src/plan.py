#!/usr/bin/python3
"""Validate a GPT layout and calculate disjoint source, scratch and final regions."""
import json
from pathlib import Path
import sys
import re

table = json.loads(Path(sys.argv[1]).read_text())['partitiontable']
root, boot, efi = sys.argv[2:5]
assert table['label'] == 'gpt' and table['sectorsize'] == 512, 'GPT / 512-byte sectors required'
parts = table['partitions']
source = next(p for p in parts if p['node'] == root)
assert source == max(parts, key=lambda p: p['start'] + p['size']), 'Root must be the last partition on disk'
for part in parts:
    assert part['node'] in (root, boot, efi) or part['type'].upper() in (
        '21686148-6449-6E6F-744E-656564454649', 'C12A7328-F81F-11D2-BA4B-00A0C93EC93B'), 'Unrecognized data partition: '+part['node']
    assert re.search(r'(\d+)$', part['node'])[1] != '32', 'Partition 32 must be unused'
last = source['start'] + source['size'] - 1
front_start = 1050624  # 1 MiB alignment + 512 MiB ZFSBootMenu partition
split = ((last + 1 + front_start) // 2 // 2048 + 2) * 2048
assert split > source['start'] + 3*1024**3//512, 'Insufficient front space'
assert split - front_start >= last - split + 1, 'Front mirror member must be at least as large as temporary member'
number = re.search(r'(\d+)$', root)[1]
# Names from the kernel are validated without evaluating arbitrary partition labels.
assert number.isdigit()
for key, value in dict(ROOT_PART=number, ROOT_START=source['start'], ROOT_END=last,
                       SPLIT=split, ROOT_GUID=source['uuid']).items():
    assert all(c.isalnum() or c == '-' for c in str(value))
    print(f'{key}={value}')
