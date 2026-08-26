#!/usr/bin/env python3
"""Key, split and pad the nano-banana source sheet into the two new assets.

  scripts/art/source/gozu_sheet.png  (one row: sumo wrestler | card back)
    -> data/sumo_token.png   96x96    ink-on-transparent, amber mawashi
    -> data/card_back.png    120x168  the prize deck's back

Gemini does not return alpha and the "pure green" comes back as *some* green
with a tinted edge, so the backdrop colour is taken as the MEDIAN of the image
border and flood-filled from the border inwards (green accents inside an
object survive). The sumo is then keyed a second time against the cream panel
it was drawn on, from the panel's own border inwards, so the wrestler keeps
his cream body fill and loses the card he was standing on.

  python3 -m pip install --user pillow
  python3 scripts/art/split_gozu_sheet.py
"""

import os
from collections import deque

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SHEET = os.path.join(HERE, "source", "gozu_sheet.png")
OUT = os.path.join(ROOT, "data")

BACKDROP_TOLERANCE = 72
PANEL_TOLERANCE = 34
# (file name, output size, strip the cream panel the object was drawn on)
PARTS = [
    ("sumo_token.png", (96, 96), True),
    ("card_back.png", (120, 168), False),
]


def median_border(pixels, width, height):
    samples = []
    for x in range(width):
        samples.append(pixels[x, 0])
        samples.append(pixels[x, height - 1])
    for y in range(height):
        samples.append(pixels[0, y])
        samples.append(pixels[width - 1, y])
    channels = []
    for index in range(3):
        values = sorted(sample[index] for sample in samples)
        channels.append(values[len(values) // 2])
    return tuple(channels)


def near(a, b, tolerance):
    return (abs(a[0] - b[0]) + abs(a[1] - b[1]) + abs(a[2] - b[2])) <= tolerance


def flood_clear(image, colour, tolerance):
    """Make every border-connected pixel near `colour` transparent."""
    width, height = image.size
    pixels = image.load()
    seen = bytearray(width * height)
    queue = deque()

    def push(x, y):
        if 0 <= x < width and 0 <= y < height and not seen[y * width + x]:
            seen[y * width + x] = 1
            current = pixels[x, y]
            if current[3] == 0 or near(current, colour, tolerance):
                pixels[x, y] = (current[0], current[1], current[2], 0)
                queue.append((x, y))

    for x in range(width):
        push(x, 0)
        push(x, height - 1)
    for y in range(height):
        push(0, y)
        push(width - 1, y)
    while queue:
        x, y = queue.popleft()
        push(x + 1, y)
        push(x - 1, y)
        push(x, y + 1)
        push(x, y - 1)
    return image


def flood_bright(image, threshold=96):
    """Clear border-connected pixels lighter than `threshold`.

    The anti-aliased ring where the cream panel met the green backdrop is
    neither cream nor green, so a colour key leaves a halo. Everything in
    that halo is LIGHT and everything the wrestler is drawn with is either
    dark ink or amber and is enclosed by his own outline, so a brightness
    flood from the border removes the halo and nothing else.
    """
    width, height = image.size
    pixels = image.load()
    seen = bytearray(width * height)
    queue = deque()

    def push(x, y):
        if 0 <= x < width and 0 <= y < height and not seen[y * width + x]:
            seen[y * width + x] = 1
            r, g, b, a = pixels[x, y]
            if a == 0 or (r * 299 + g * 587 + b * 114) // 1000 > threshold:
                pixels[x, y] = (r, g, b, 0)
                queue.append((x, y))

    for x in range(width):
        push(x, 0)
        push(x, height - 1)
    for y in range(height):
        push(0, y)
        push(width - 1, y)
    while queue:
        x, y = queue.popleft()
        push(x + 1, y)
        push(x - 1, y)
        push(x, y + 1)
        push(x, y - 1)
    return image


def column_runs(image, gap=12):
    """The x-ranges that carry opaque pixels, merged across small gaps."""
    width, height = image.size
    pixels = image.load()
    filled = []
    for x in range(width):
        hit = False
        for y in range(0, height, 2):
            if pixels[x, y][3] > 24:
                hit = True
                break
        filled.append(hit)
    runs = []
    start = None
    empty = 0
    for x, hit in enumerate(filled):
        if hit:
            if start is None:
                start = x
            empty = 0
        elif start is not None:
            empty += 1
            if empty > gap:
                runs.append((start, x - empty))
                start = None
    if start is not None:
        runs.append((start, width - 1))
    return [run for run in runs if run[1] - run[0] > 20]


def fit(image, size):
    """Contain the object in `size` on a transparent canvas, centred."""
    box = image.getbbox()
    if box:
        image = image.crop(box)
    scale = min(size[0] / image.width, size[1] / image.height)
    scaled = image.resize(
        (max(1, int(image.width * scale)), max(1, int(image.height * scale))),
        Image.LANCZOS,
    )
    canvas = Image.new("RGBA", size, (0, 0, 0, 0))
    canvas.paste(scaled, ((size[0] - scaled.width) // 2,
                          (size[1] - scaled.height) // 2))
    return canvas


def main():
    sheet = Image.open(SHEET).convert("RGBA")
    backdrop = median_border(sheet.load(), *sheet.size)
    flood_clear(sheet, backdrop, BACKDROP_TOLERANCE)
    runs = column_runs(sheet)
    if len(runs) != len(PARTS):
        raise SystemExit(f"expected {len(PARTS)} objects, found {len(runs)}: "
                         f"{runs}")
    os.makedirs(OUT, exist_ok=True)
    for (name, size, strip_panel), (x0, x1) in zip(PARTS, runs):
        part = sheet.crop((x0, 0, x1 + 1, sheet.height))
        box = part.getbbox()
        part = part.crop(box)
        if strip_panel:
            # The cream card the wrestler was drawn on: keyed from the panel's
            # own border inwards, so the ink outline keeps its cream fill.
            panel = part.load()[part.width // 2, 4]
            flood_clear(part, panel[:3], PANEL_TOLERANCE)
            flood_bright(part)
        out = os.path.join(OUT, name)
        fit(part, size).save(out)
        print(f"wrote {out} {size[0]}x{size[1]}")


if __name__ == "__main__":
    main()
