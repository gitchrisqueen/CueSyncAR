#!/usr/bin/env python3
# gridview.py / CueSync AR research
#
# Hand-labelling aid: crops a region of a frame, upscales it and draws a
# labelled pixel grid in ORIGINAL frame coordinates, so ball centres can be
# read off by eye. Optional --points draws already-labelled centres back on
# top for checking.
#
# Deps: pip install pillow
# Usage: gridview.py IMAGE OUT.png --box x0,y0,x1,y1 [--scale 2] [--step 20]
#                    [--points "x,y;x,y"]
import argparse

from PIL import Image, ImageDraw


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("image")
    parser.add_argument("out")
    parser.add_argument("--box", required=True)
    parser.add_argument("--scale", type=float, default=2.0)
    parser.add_argument("--step", type=int, default=20)
    parser.add_argument("--points", default="")
    args = parser.parse_args()

    x0, y0, x1, y1 = (int(v) for v in args.box.split(","))
    image = Image.open(args.image).convert("RGB").crop((x0, y0, x1, y1))
    s = args.scale
    image = image.resize((int((x1 - x0) * s), int((y1 - y0) * s)), Image.NEAREST)
    draw = ImageDraw.Draw(image)
    first_x = x0 + (-x0) % args.step
    for gx in range(first_x, x1, args.step):
        major = gx % (args.step * 5) == 0
        px = (gx - x0) * s
        draw.line([(px, 0), (px, image.height)], fill=(255, 255, 0) if major else (90, 90, 0))
        if major:
            draw.text((px + 2, 2), str(gx), fill=(255, 255, 0))
    first_y = y0 + (-y0) % args.step
    for gy in range(first_y, y1, args.step):
        major = gy % (args.step * 5) == 0
        py = (gy - y0) * s
        draw.line([(0, py), (image.width, py)], fill=(0, 255, 255) if major else (0, 90, 90))
        if major:
            draw.text((2, py + 2), str(gy), fill=(0, 255, 255))
    for token in filter(None, args.points.split(";")):
        px, py = (float(v) for v in token.split(","))
        cx, cy = (px - x0) * s, (py - y0) * s
        draw.ellipse([cx - 4, cy - 4, cx + 4, cy + 4], outline=(255, 0, 255), width=2)
    image.save(args.out)


if __name__ == "__main__":
    main()
