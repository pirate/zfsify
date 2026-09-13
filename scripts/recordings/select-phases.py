#!/usr/bin/env python3
"""Select real terminal excerpts; keep ANSI output and never insert title cards."""
import argparse
import json
from pathlib import Path
import re


def excerpt(header, events, begin, end, slow=False):
    first, last = events[begin][0], events[end-1][0]
    middle = (first+last)/2
    ranges = [(first, first+12), (middle, middle+8), (last-5,last)] if last-first > 30 else [(first,last)]
    selected = [header]
    cursor, clock = 0, 0.0
    for left, right in ranges:
        prefix = []
        # Replay omitted output at the cut to restore the exact terminal state.
        while cursor < end and events[cursor][0] < left:
            if events[cursor][1] == 'o':
                prefix.append(events[cursor][2])
            cursor += 1
        if prefix:
            selected.append([round(clock,3), 'o', ''.join(prefix)])
        previous = left
        while cursor < end and events[cursor][0] <= right:
            event = events[cursor]
            clock += min(max(0, event[0]-previous), 3 if slow else .5) * (2 if slow else 1)
            selected.append([round(clock,3), event[1], event[2]])
            previous = event[0]
            cursor += 1
        clock += .5
    return selected


p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--name', help='Write one named clip instead of five phase clips')
p.add_argument('--start', help='Begin at the first output containing this text')
p.add_argument('--end', help='Stop before the next output containing this text')
p.add_argument('output', type=Path)
p.add_argument('captures', nargs='+', type=Path)
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=True)
found = set()
for source in a.captures:
    recording = [json.loads(line) for line in source.read_text().splitlines()]
    header, events = recording[0], recording[1:]
    if a.name:
        begin = next((i for i,e in enumerate(events) if not a.start or a.start in e[2]), None)
        if begin is None:
            continue
        end = next((i for i in range(begin+1,len(events)) if a.end and a.end in events[i][2]), len(events))
        parts = [(begin, end, a.name, False)]
    else:
        starts = []
        phase = None
        for index, event in enumerate(events):
            match = re.search(r'\[(?:✓ )?([1-5])\. ', event[2]) if event[1] == 'o' else None
            if match and int(match[1]) != phase:
                phase = int(match[1])
                starts.append((index, phase))
        parts = [(begin, starts[i+1][0] if i+1<len(starts) else len(events), f'phase-{phase}', phase==1)
                 for i,(begin,phase) in enumerate(starts)]
    for begin, end, name, slow in parts:
        if name in found:
            continue
        target = a.output / f'{name}.cast'
        selected = excerpt(header, events, begin, end, slow)
        target.write_text('\n'.join(json.dumps(e, ensure_ascii=False) for e in selected)+'\n')
        found.add(name)
        print(target)
expected = {a.name} if a.name else {f'phase-{i}' for i in range(1,6)}
if missing := expected - found:
    raise SystemExit(f'Missing recordings: {sorted(missing)}')
