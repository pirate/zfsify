#!/usr/bin/env python3
"""Render selected captured terminal text without frames, captions, or transitions.

Pillow is needed only to render GIFs. The asciicast uses changed-line updates and
one output event per frame, so a player never shows an intermediate blank screen.
"""
import argparse
import json
from pathlib import Path


def screen_lines(body, width):
    lines = []
    for line in body.expandtabs(8).splitlines():
        lines.extend(line[i:i + width] for i in range(0, len(line), width)) if line else lines.append('')
    return lines


def render(selection, output, font_path=None):
    from PIL import Image, ImageDraw, ImageFont

    output = Path(output)
    manifest = json.loads(Path(selection).read_text())
    width = 110
    screens = [screen_lines(frame['body'], width) for frame in manifest['frames']]
    height = max(22, max(map(len, screens)))
    font_candidates = [font_path, '/System/Library/Fonts/Menlo.ttc',
                       '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf']
    font_file = next((p for p in font_candidates if p and Path(p).is_file()), None)
    if not font_file:
        raise SystemExit('Provide --font with a monospace TrueType/OpenType font.')
    font = ImageFont.truetype(font_file, 16)
    cell_width, cell_height, padding = round(font.getlength('M')), 22, 14
    background, foreground = (13, 17, 23), (230, 237, 243)
    palette = Image.new('P', (1, 1))
    # A shared antialias palette prevents per-frame color changes in GIF players.
    palette.putpalette([round(background[c] + (foreground[c] - background[c]) * i / 255)
                        for i in range(256) for c in range(3)])
    header = {'version': 2, 'width': width, 'height': height, 'env': {'TERM': 'xterm-256color'}}
    full = output.with_name(output.name + '-full.cast')
    if full.exists():
        original = json.loads(full.read_text().splitlines()[0])
        if 'timestamp' in original:
            header['timestamp'] = original['timestamp']
    events, images, durations = [], [], []
    previous, elapsed = [''] * height, 0.0
    for frame, lines in zip(manifest['frames'], screens):
        rows = lines + [''] * (height - len(lines))
        update = '\x1b[?25l' if not events else ''
        for row, (old, new) in enumerate(zip(previous, rows), 1):
            if old != new:
                update += f'\x1b[{row};1H' + new.ljust(width)
        if update:
            events.append([round(elapsed, 3), 'o', update])
        previous = rows
        picture = Image.new('RGB', (width * cell_width + padding * 2, height * cell_height + padding * 2), background)
        draw = ImageDraw.Draw(picture)
        for row, line in enumerate(lines):
            draw.text((padding, padding + row * cell_height), line, font=font, fill=foreground)
        images.append(picture.quantize(palette=palette, dither=Image.Dither.NONE))
        durations.append(max(10, round(frame['duration'] * 100) * 10))
        elapsed += frame['duration']
    events.append([round(elapsed, 3), 'o', '\x1b[?25h'])
    output.with_suffix('.cast').write_text('\n'.join(json.dumps(event, ensure_ascii=False) for event in [header, *events]) + '\n')
    images[0].save(output.with_suffix('.gif'), save_all=True, append_images=images[1:],
                   duration=durations, loop=0, disposal=1, optimize=False)
    print(f'{output.name}: {len(images)} screens, {elapsed:.2f}s, {width} × {height} cells')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('selection', type=Path)
    parser.add_argument('output', type=Path, help='Output basename without .cast or .gif')
    parser.add_argument('--font')
    args = parser.parse_args()
    render(args.selection, args.output, args.font)


if __name__ == '__main__':
    main()
