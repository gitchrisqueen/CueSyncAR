#!/usr/bin/env python3 -I
"""Score a `detection-eval --sweep-dir` run against a ground-truth ball layout.

usage: recall.py <sweep.jsonl> <truth.json> [--floor 0.35] [--match-px 10]

truth.json: {"image": [width, height], "cloth": [x0, y0, x1, y1],
             "balls": {"name": [cx, cy], ...}}   (centres normalized, top-left)

The layout is measured by hand from the capture and is NOT stored in the repo
(captures and anything derived from them stay local). For every variant it
prints, per ball, the share of frames with a detection of at least `--floor`
confidence whose centre lies within `--match-px` pixels of the ball, then the
false detections inside the cloth window and off it, and inference seconds.
Stick ("cue") boxes are ignored.
"""
import json
import statistics
import sys
from collections import defaultdict


def centre(box):
    return box["x"] + box["width"] / 2, box["y"] + box["height"] / 2


def main():
    args = sys.argv[1:]
    floor, match_px = 0.35, 10.0
    if "--floor" in args:
        i = args.index("--floor"); floor = float(args[i + 1]); del args[i:i + 2]
    if "--match-px" in args:
        i = args.index("--match-px"); match_px = float(args[i + 1]); del args[i:i + 2]
    rows = [json.loads(line) for line in open(args[0])]
    truth = json.load(open(args[1]))
    width, height = truth["image"]
    x0, y0, x1, y1 = truth["cloth"]
    balls = truth["balls"]

    def dist_px(a, b):
        return (((a[0] - b[0]) * width) ** 2 + ((a[1] - b[1]) * height) ** 2) ** 0.5

    # variant -> frames: list of detection lists
    variants = defaultdict(list)
    seconds = defaultdict(list)
    for row in rows:
        variants[(row["setting"], "full")].append(row["full"])
        seconds[(row["setting"], "full")].append(row["fullSeconds"])
        for tile in row["tiles"]:
            key = (row["setting"], "full+" + tile["tile"])
            variants[key].append(tile["merged"])
            seconds[key].append(row["fullSeconds"] + tile["tileSeconds"])

    names = list(balls)
    header = "variant".ljust(18) + "".join(n[:6].rjust(7) for n in names)
    print(f"floor {floor}, match {match_px}px, frames {len(rows) // max(1, len(set(r['setting'] for r in rows)))}")
    print(header + "   found cloth-FP offcloth-FP  sec/frame")
    for key in sorted(variants, key=lambda k: (k[0], k[1])):
        frames = variants[key]
        hits = {n: 0 for n in names}
        cloth_fp = off_fp = 0
        for dets in frames:
            kept = [d for d in dets if d["label"] != "cue" and d["confidence"] >= floor]
            for n in names:
                if any(dist_px(centre(d), balls[n]) <= match_px for d in kept):
                    hits[n] += 1
            for d in kept:
                c = centre(d)
                if any(dist_px(c, balls[n]) <= match_px for n in names):
                    continue
                if x0 <= c[0] <= x1 and y0 <= c[1] <= y1:
                    cloth_fp += 1
                else:
                    off_fp += 1
        n_frames = len(frames)
        shares = [hits[n] / n_frames for n in names]
        found = sum(1 for s in shares if s >= 0.5)
        label = f"{key[0]} {key[1]}"
        print(label.ljust(18) + "".join(f"{s * 100:6.0f}%" for s in shares)
              + f"  {found:>3}/16 {cloth_fp / n_frames:8.2f} {off_fp / n_frames:11.2f}"
              + f"  {statistics.median(seconds[key]):.3f}")


if __name__ == "__main__":
    main()
