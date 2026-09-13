#!/usr/bin/env python3
"""Render an ANSI asciicast as a bare terminal GIF (tooling deps: Pillow, pyte)."""
import argparse
import json
from pathlib import Path

import pyte
from PIL import Image, ImageColor, ImageDraw, ImageFont


def render(source, output, font_path=None, fps=8):
    capture = [json.loads(line) for line in source.read_text().splitlines()]
    width, height = capture[0]['width'], capture[0]['height']
    font_file = next((p for p in (font_path, '/System/Library/Fonts/Menlo.ttc',
                                '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf')
                      if p and Path(p).is_file()), None)
    if not font_file:
        raise SystemExit('Provide --font with a monospace font.')
    font = ImageFont.truetype(font_file, 16)
    cell_width, cell_height, padding = round(font.getlength('M')), 22, 14
    colors = dict(default='#e6edf3', black='#0d1117', red='#ff7b72', green='#7ee787',
                  brown='#d29922', blue='#79c0ff', magenta='#d2a8ff', cyan='#76e3ea', white='#e6edf3',
                  brightblack='#6e7681', brightred='#ffa198', brightgreen='#aff5b4', brightbrown='#e3b341',
                  brightblue='#a5d6ff', brightmagenta='#e2c5ff', brightcyan='#b3f0ff', brightwhite='#ffffff')
    screen = pyte.Screen(width, height)
    stream = pyte.Stream(screen)
    images = []
    events = iter(capture[1:]); event = next(events, None)
    for index in range(int((capture[-1][0] + 1.5) * fps)):
        while event and event[0] <= index / fps:
            if event[1] == 'o': stream.feed(event[2])
            event = next(events, None)
        if not any(line.strip() for line in screen.display):
            continue
        picture = Image.new('RGB', (width*cell_width+padding*2, height*cell_height+padding*2), '#0d1117')
        draw = ImageDraw.Draw(picture)
        for row in range(height):
            for column in range(width):
                cell = screen.buffer[row][column]
                color = colors.get(cell.fg, '#'+cell.fg if len(cell.fg) == 6 else '#e6edf3')
                draw.text((padding+column*cell_width, padding+row*cell_height), cell.data, font=font, fill=color)
        images.append(picture)
    if not images:
        raise SystemExit('No visible terminal output in capture.')
    # One palette and retained frames avoid color pumping / clear-frame flashes.
    background = ImageColor.getrgb('#0d1117')
    entries = []
    for value in colors.values():
        foreground = ImageColor.getrgb(value)
        for step in range(12):
            shade = tuple(round(background[c] + (foreground[c]-background[c])*step/11) for c in range(3))
            if shade not in entries: entries.append(shade)
    assert len(entries) <= 256
    palette = Image.new('P', (1, 1))
    palette.putpalette([channel for entry in entries + [background]*(256-len(entries)) for channel in entry])
    frames = [picture.quantize(palette=palette, dither=Image.Dither.NONE) for picture in images]
    frames[0].save(output, save_all=True, append_images=frames[1:],
                   duration=round(100/fps)*10, loop=0, disposal=1, optimize=False)
    print(f'{output}: {len(frames)} terminal frames')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--font')
    args = parser.parse_args()
    render(args.source, args.output, args.font)
