#!/usr/bin/env python3
"""render-icon-preview.py / CueSync AR

Builds Design/preview.png, the contact sheet used to judge the app icon.
Called by Scripts/render-icon.sh; not meant to be run by hand.

    render-icon-preview.py <AppIcon.appiconset dir> <preview.png>

Every small icon on the sheet is the 1024 px PNG downsampled with Lanczos,
which is how iOS derives the home-screen sizes from the single 1024 source,
so the 40 px cell is what a Settings-list row actually shows. Nothing is
sharpened or re-rendered at size: the sheet is meant to be honest, not
flattering.

Rows:
  1. default appearance on a light home-screen ground: 1024 + 180/120/80/60/40
  2. the same on a dark ground
  3. iOS rounded-rect (squircle) mask at 180 and 60, then the dark and
     tinted appearance variants at 180 and 60 (tinted shown on the flat
     dark ground iOS uses, with a neutral gray tint applied).
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

SIZES = [180, 120, 80, 60, 40]
PAD = 28
LIGHT = (242, 242, 247, 255)   # iOS systemGroupedBackground
DARK = (0, 0, 0, 255)


def squircle_mask(size, n=5.0, supersample=4):
    """iOS icon mask: a superellipse |x|^n + |y|^n = 1 with n ~ 5."""
    big = size * supersample
    mask = Image.new("L", (big, big), 0)
    pts = []
    steps = 720
    import math
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        x = math.copysign(abs(c) ** (2 / n), c)
        y = math.copysign(abs(s) ** (2 / n), s)
        pts.append(((x + 1) * big / 2, (y + 1) * big / 2))
    ImageDraw.Draw(mask).polygon(pts, fill=255)
    return mask.resize((size, size), Image.LANCZOS)


def masked(icon, size):
    im = icon.resize((size, size), Image.LANCZOS)
    im.putalpha(squircle_mask(size))
    return im


def label(draw, xy, text, fill):
    try:
        font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 22)
    except OSError:
        font = ImageFont.load_default()
    draw.text(xy, text, fill=fill, font=font)


def main(icon_dir, out_path):
    icon_dir = Path(icon_dir)
    default = Image.open(icon_dir / "AppIcon.png").convert("RGBA")
    dark = Image.open(icon_dir / "AppIcon-dark.png").convert("RGBA")
    tinted = Image.open(icon_dir / "AppIcon-tinted.png").convert("RGBA")

    row_w = 1024 + PAD * 2 + sum(SIZES) + PAD * len(SIZES)
    row_h = 1024 + PAD * 2 + 30
    variant_h = 180 + PAD * 2 + 30
    sheet = Image.new("RGBA", (row_w, row_h * 2 + variant_h), LIGHT)
    draw = ImageDraw.Draw(sheet)

    # Rows 1-2: raw 1024 plus downsampled sizes on light / dark grounds.
    for row, ground in enumerate([LIGHT, DARK]):
        y0 = row * row_h
        draw.rectangle([0, y0, row_w, y0 + row_h], fill=ground)
        text = (60, 60, 67, 255) if ground == LIGHT else (174, 174, 178, 255)
        sheet.alpha_composite(default, (PAD, y0 + PAD))
        label(draw, (PAD, y0 + PAD + 1024 + 4), "1024", text)
        x = 1024 + PAD * 2
        for s in SIZES:
            sheet.alpha_composite(default.resize((s, s), Image.LANCZOS),
                                  (x, y0 + PAD + 1024 - s))
            label(draw, (x, y0 + PAD + 1024 + 4), str(s), text)
            x += s + PAD

    # Row 3: squircle-masked default, then the dark and tinted variants.
    y0 = row_h * 2
    draw.rectangle([0, y0, row_w, y0 + variant_h], fill=(200, 200, 205, 255))
    text = (60, 60, 67, 255)
    x = PAD
    cells = [
        ("masked 180", masked(default, 180)),
        ("masked 60", masked(default, 60)),
        ("dark 180", masked(dark, 180)),
        ("dark 60", masked(dark, 60)),
    ]
    # Tinted: iOS composites the grayscale art over its own dark ground and
    # tints it; approximate with a neutral gray tint on near-black.
    tint_ground = Image.new("RGBA", (1024, 1024), (28, 28, 30, 255))
    tint_ground.alpha_composite(tinted)
    cells += [("tinted 180", masked(tint_ground, 180)),
              ("tinted 60", masked(tint_ground, 60))]
    for name, im in cells:
        sheet.alpha_composite(im, (x, y0 + PAD + 180 - im.height))
        label(draw, (x, y0 + PAD + 180 + 4), name, text)
        x += max(im.width, 120) + PAD  # never narrower than the label

    sheet.convert("RGB").save(out_path, optimize=True)
    print(f"wrote {out_path} ({sheet.width}x{sheet.height})")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
