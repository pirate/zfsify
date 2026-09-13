#!/usr/bin/env python3
"""Select verbatim output from the live Volume run for the README preview."""
import argparse,importlib.util,json,re,shutil
from pathlib import Path
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('input_directory', type=Path, help='Directory containing volume-full.cast')
parser.add_argument('output_directory', type=Path)
args=parser.parse_args()
D=args.input_directory
O=args.output_directory
O.mkdir(parents=True,exist_ok=True)
raw=[json.loads(x) for x in (D/'volume-full.cast').read_text().splitlines()]
ansi=re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')
lines=[];leftover=''
for e in raw[1:]:
    if e[1]!='o':continue
    s=leftover+ansi.sub('',e[2]).replace('\r\n','\n').replace('\r','\n')
    parts=s.split('\n');leftover=parts.pop()
    lines.extend((e[0],x) for x in parts)
text='\n'.join(s for _,s in lines)
frames=[]
def frame(title,body,seconds=2,source=None):
    assert len(body.splitlines())<=23,(title,len(body.splitlines()))
    body='\n'.join(line for line in body.splitlines() if not line.startswith(('PASS: hashes, hard links, ACLs, xattrs.', 'One command converts the volume.', 'Conversion complete. Same mount point;')))
    frames.append(dict(body=body,duration=seconds,source_time=source))
def excerpt(start,end):return text[text.index(start):text.index(end)].strip()
frame('01  A normal attached ext4 volume',excerpt('$ lsblk','$ find'),4)
frame('02  Existing application files',excerpt('$ find /mnt/data','$ curl'),2.5)
frame('03  One command; review the plan',excerpt('$ curl','Work logs:'),4)
for t,s in lines:
    if s.startswith('Starting in '):
        frame('15-second cancellation window · accelerated playback',s,.13,t)
blocks=[]
for i,(t,s) in enumerate(lines):
    if re.match(r'^\[[#-]{24}\] phase \d+/10:',s):
        b=[s]
        for _,ss in lines[i+1:i+4]:
            if ss.startswith('  '):b.append(ss)
            else:break
        if len(b)>=3:blocks.append(dict(source_time=t,text='\n'.join(b),operation=re.search(r'phase \d+/10: (.*?) \[',s)[1]))
operations=list(dict.fromkeys(b['operation'] for b in blocks))
for operation in operations:
    bs=[b for b in blocks if b['operation']==operation]
    chosen=[bs[0],bs[len(bs)//2],bs[-1]] if operation.startswith(('Copy','Resilver')) else [bs[-1]]
    seen=set()
    for b in chosen:
        if b['text'] in seen:continue
        seen.add(b['text'])
        frame('Live installer output · selected excerpts',b['text'],1.8,b['source_time'])
frame('04  Same mount point; all content verified',excerpt('$ findmnt','$ zpool list'),4)
frame('05  Healthy pool; automatic expansion enabled',excerpt('$ zpool list','$ getfattr'),4)
frame('06  Metadata preserved; no reboot needed',text[text.index('$ getfattr'):].strip(),4)
time=sum(item['duration'] for item in frames)
(O/'volume-selection.json').write_text(json.dumps(dict(description='Selected captured terminal output from volume-full.cast. Waits shortened; package output and recording annotations omitted. Source times refer to the unchanged full capture.',duration=round(time,3),frames=frames),indent=2)+'\n')
if (D/'volume-full.cast').resolve() != (O/'volume-full.cast').resolve():
    shutil.copyfile(D/'volume-full.cast',O/'volume-full.cast')
spec=importlib.util.spec_from_file_location('render_selection',Path(__file__).with_name('render-selection.py'))
renderer=importlib.util.module_from_spec(spec);spec.loader.exec_module(renderer)
renderer.render(O/'volume-selection.json',O/'volume')
