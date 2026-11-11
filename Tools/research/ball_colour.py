#!/usr/bin/env python3
# ball_colour.py / CueSync AR research
#
# Question 4 of docs/research/2026-11-10-ball-detection-and-identity.md:
# why the app calls the dark blue ball the 8-ball, and what feature fixes
# it without breaking the real 8-balls.
#
# For every hand-labelled ball it samples the inset disc the way
# PerceptionKit/BallPatchSampler does (disc 0.80 of the inscribed radius,
# specular pixels >= 0.97 dropped, absolute chroma floor 0.12), runs a
# Python port of PerceptionKit/BallAppearance.classify (white-balanced on
# the frame's cue ball), and prints the candidate features for a fix:
#
#   meanChromaRel  chroma (max-min) of the disc's MEAN white-balanced RGB,
#                  divided by the cue ball's value. Averaging ~1000 pixels
#                  kills the per-pixel sensor noise that made relative
#                  saturation useless on the eight, while dividing by the
#                  cue ball (not by the ball's own value) keeps a dim blue
#                  ball's colour from vanishing under an absolute floor.
#   labB           CIELAB b* of the mean white-balanced colour (blue < 0).
#   valueRel       the ball's value relative to the cue ball's.
#
# Deps: pip install pillow numpy
# Usage: ball_colour.py LABELS.json [LABELS2.json ...]
import json
import math
import os
import sys

import numpy as np
from PIL import Image

HUE_CENTRES = {"yellow": 48, "orange": 25, "red": 356, "maroon": 348,
               "purple": 275, "blue": 228, "green": 130}


def disc_pixels(image, x, y, diameter, fraction=0.80):
    radius = diameter / 2 * fraction
    x0, x1 = int(x - radius), int(x + radius) + 1
    y0, y1 = int(y - radius), int(y + radius) + 1
    patch = image[max(0, y0):y1, max(0, x0):x1]
    ys, xs = np.mgrid[max(0, y0):y1, max(0, x0):x1]
    mask = (xs + 0.5 - x) ** 2 + (ys + 0.5 - y) ** 2 <= radius ** 2
    pixels = patch[mask]
    return pixels[pixels.max(axis=1) < 0.97]


def hue(rgb):
    r, g, b = rgb
    high, low = max(rgb), min(rgb)
    chroma = high - low
    if chroma <= 1e-6:
        return None
    if high == r:
        raw = 60 * ((g - b) / chroma)
    elif high == g:
        raw = 60 * (2 + (b - r) / chroma)
    else:
        raw = 60 * (4 + (r - g) / chroma)
    return raw % 360


def hue_distance(a, b):
    d = abs(a - b) % 360
    return min(d, 360 - d)


def current_classify(pixels, gains):
    """Port of BallAppearance.classify with default Config."""
    if len(pixels) < 40:
        return "nil", 0
    chroma = pixels.max(axis=1) - pixels.min(axis=1)
    value = pixels.max(axis=1)
    chroma_fraction = float((chroma >= 0.12).mean())
    white_fraction = float(((chroma <= 0.10) & (value >= 0.25)).mean())
    balanced = np.minimum(1, pixels.mean(axis=0) * gains)
    balanced_value = balanced.max()
    if white_fraction >= 0.55 and chroma_fraction <= 0.15:
        return "white", 0.9
    if chroma_fraction <= 0.15 and balanced_value <= 0.45:
        return "black", 0.9
    h = hue(balanced)
    if h is None:
        return "nil", 0
    scored = sorted(((max(0, 1 - hue_distance(h, c) / 40), f) for f, c in HUE_CENTRES.items()),
                    reverse=True)
    fit, family = scored[0]
    if fit <= 0:
        return "nil", 0
    if family in ("red", "maroon"):
        family = "maroon" if balanced_value < 0.55 else "red"
    return family, round(fit - scored[1][0], 2)


def srgb_to_lab(rgb):
    def lin(c):
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(float(c)) for c in rgb)
    x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
    y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883

    def f(t):
        return t ** (1 / 3) if t > 0.008856 else 7.787 * t + 16 / 116
    return 116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))


def proposed_classify(balanced, reference_value):
    """Candidate fix: decide black/white on the chroma of the MEAN colour
    relative to the cue ball, not on the fraction of individually chromatic
    pixels; red vs maroon on brightness relative to the cue ball."""
    value_rel = balanced.max() / reference_value
    chroma_rel = (balanced.max() - balanced.min()) / reference_value
    if chroma_rel < 0.15:
        return "black" if value_rel < 0.6 else "white"
    h = hue(balanced)
    scored = sorted(((max(0, 1 - hue_distance(h, c) / 40), f) for f, c in HUE_CENTRES.items()),
                    reverse=True)
    family = scored[0][1]
    if family in ("red", "maroon"):
        family = "maroon" if value_rel < 0.75 else "red"
    return family


def cue_pick(features):
    """Which labelled ball is the cue ball, with no reference: the
    brightest, least saturated ball (raw RGB, no white balance)."""
    def score(item):
        raw = item["raw"]
        saturation = (raw.max() - raw.min()) / max(raw.max(), 1e-6)
        return raw.max() * (1 - saturation)
    return max(features, key=score)["kind"] == "cue"


def main():
    if sys.argv[1] == "--score":
        return score_main(sys.argv[2:])
    print("frame\tcolour(truth)\tkind\tn\tchromaFrac\tvalueRel\tmeanChromaRel\tlabL\tlabA\tlabB\tcurrent")
    for path in sys.argv[1:]:
        with open(path) as handle:
            frames = json.load(handle)["frames"]
        for frame in frames:
            image = np.asarray(Image.open(os.path.expanduser(frame["path"])).convert("RGB"),
                               dtype=np.float64) / 255
            diameter = frame["ballDiameterPx"]
            cue = [b for b in frame["balls"] if b["kind"] == "cue"]
            if not cue:
                continue
            reference = disc_pixels(image, cue[0]["x"], cue[0]["y"], cue[0].get("d", diameter)).mean(axis=0)
            gains = np.array([reference[1] / reference[0], 1, reference[1] / reference[2]])
            reference_value = float(np.minimum(1, reference * gains).max())
            for ball in frame["balls"]:
                pixels = disc_pixels(image, ball["x"], ball["y"], ball.get("d", diameter))
                if len(pixels) == 0:
                    continue
                chroma_fraction = float(((pixels.max(axis=1) - pixels.min(axis=1)) >= 0.12).mean())
                balanced = np.minimum(1, pixels.mean(axis=0) * gains)
                value_rel = balanced.max() / reference_value
                mean_chroma_rel = (balanced.max() - balanced.min()) / reference_value
                lab = srgb_to_lab(balanced / reference_value * 0.9)
                family, confidence = current_classify(pixels, gains)
                print(f"{frame['id']}\t{ball['colour']}\t{ball['kind']}\t{len(pixels)}\t"
                      f"{chroma_fraction:.2f}\t{value_rel:.2f}\t{mean_chroma_rel:.3f}\t"
                      f"{lab[0]:.1f}\t{lab[1]:.1f}\t{lab[2]:.1f}\t{family} {confidence}")


def score_main(paths):
    """Family accuracy, current vs proposed, over every non-cue ball, plus
    the reference-free cue-ball pick rate per frame."""
    from collections import Counter
    totals = Counter()
    confusions = {"current": Counter(), "proposed": Counter()}
    for path in paths:
        with open(path) as handle:
            frames = json.load(handle)["frames"]
        for frame in frames:
            image = np.asarray(Image.open(os.path.expanduser(frame["path"])).convert("RGB"),
                               dtype=np.float64) / 255
            diameter = frame["ballDiameterPx"]
            features = []
            for ball in frame["balls"]:
                pixels = disc_pixels(image, ball["x"], ball["y"], ball.get("d", diameter))
                if len(pixels):
                    features.append({"kind": ball["kind"], "raw": pixels.mean(axis=0)})
            totals["frames"] += 1
            totals["cuePickRight"] += cue_pick(features)
            cue = [b for b in frame["balls"] if b["kind"] == "cue"][0]
            reference = disc_pixels(image, cue["x"], cue["y"], cue.get("d", diameter)).mean(axis=0)
            gains = np.array([reference[1] / reference[0], 1, reference[1] / reference[2]])
            reference_value = float(np.minimum(1, reference * gains).max())
            for ball in frame["balls"]:
                if ball["kind"] == "cue":
                    continue
                truth = ball["colour"].replace("-stripe", "")
                pixels = disc_pixels(image, ball["x"], ball["y"], ball.get("d", diameter))
                balanced = np.minimum(1, pixels.mean(axis=0) * gains)
                current = current_classify(pixels, gains)[0]
                proposed = proposed_classify(balanced, reference_value)
                totals["balls"] += 1
                totals["currentRight"] += current == truth
                totals["proposedRight"] += proposed == truth
                for name, guess in (("current", current), ("proposed", proposed)):
                    if guess != truth:
                        confusions[name][f"{truth}->{guess}"] += 1
                    if truth == "black" and guess != "black":
                        totals[f"{name}EightMissed"] += 1
                    if truth != "black" and guess == "black":
                        totals[f"{name}FalseEight"] += 1
                totals["eights"] += truth == "black"
    print(json.dumps(dict(totals)))
    for name, counter in confusions.items():
        print(name, dict(counter.most_common()))


if __name__ == "__main__":
    main()
