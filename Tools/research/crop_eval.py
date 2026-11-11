#!/usr/bin/env python3
# crop_eval.py / CueSync AR research
#
# Question 1 of docs/research/2026-11-10-ball-detection-and-identity.md:
# does feeding the CURRENT BallDetector a crop of the calibrated table (or
# tiles of it) instead of the whole frame stretched to 640x640 find more
# balls?
#
# For every labelled frame it builds the input images for each mode, runs
# Tools/DetectionEval (the app's own CoreMLDetectionProvider: Vision,
# scaleFill), maps boxes back to frame pixels, merges tile overlaps, gates
# to the table quad (as the app's PlayingSurfaceGate does) and scores
# against the hand labels.
#
# Modes
#   full   whole frame (what the app does today)
#   crop   bounding box of the table quad plus one ball of margin
#   tiles  that crop split into near-square tiles with two balls of overlap
#   scaledN  square windows over the crop, sized so a ball is N px at the
#          model's 640 input on both axes (N in 16, 20, 24, 28, 32)
#
# Deps: pip install pillow  (plus a release build of Tools/DetectionEval)
# Usage: crop_eval.py LABELS.json --eval-bin PATH --model PATH --work DIR
#                     [--modes full,crop,tiles] [--floor 0.35] [--compute cpu]
import argparse
import json
import math
import os
import subprocess
import sys

from PIL import Image

BALL_LABELS = {"color-ball", "white-ball"}


def load_quad(frame):
    if frame["quad"] == "corners.json":
        folder = os.path.dirname(os.path.dirname(os.path.expanduser(frame["path"])))
        with open(os.path.join(folder, "corners.json")) as handle:
            return json.load(handle)["corners"]
    return frame["quad"]


def crop_box(quad, diameter, width, height):
    xs = [p[0] for p in quad]
    ys = [p[1] for p in quad]
    margin = diameter * 1.0
    return (max(0, int(min(xs) - margin)), max(0, int(min(ys) - margin)),
            min(width, int(max(xs) + margin)), min(height, int(max(ys) + margin)))


def tile_boxes(box, diameter):
    x0, y0, x1, y1 = box
    width, height = x1 - x0, y1 - y0
    columns = max(1, round(width / height)) if width >= height else 1
    rows = max(1, round(height / width)) if height > width else 1
    overlap = 2 * diameter
    tiles = []
    for row in range(rows):
        for column in range(columns):
            tx0 = x0 + column * width / columns - (overlap / 2 if column else 0)
            tx1 = x0 + (column + 1) * width / columns + (overlap / 2 if column < columns - 1 else 0)
            ty0 = y0 + row * height / rows - (overlap / 2 if row else 0)
            ty1 = y0 + (row + 1) * height / rows + (overlap / 2 if row < rows - 1 else 0)
            tiles.append((int(tx0), int(ty0), int(tx1), int(ty1)))
    return tiles


def scaled_windows(box, diameter, target, width, height):
    """Square windows sized so a ball lands at `target` px in the 640 model
    input on BOTH axes, tiled over the table box with two balls of overlap.
    A box smaller than one window gets one window centred on it (more
    context, not more magnification)."""
    side = 640 * diameter / target
    overlap = 2 * diameter
    windows = []
    x0, y0, x1, y1 = box

    def spans(lo, hi, limit):
        length = hi - lo
        if length <= side:
            centre = (lo + hi) / 2
            start = min(max(0, centre - side / 2), max(0, limit - side))
            return [(int(start), int(min(limit, start + side)))]
        count = math.ceil((length - overlap) / (side - overlap))
        step = (length - side) / (count - 1) if count > 1 else 0
        return [(int(lo + i * step), int(lo + i * step + side)) for i in range(count)]

    for ya, yb in spans(y0, y1, height):
        for xa, xb in spans(x0, x1, width):
            windows.append((xa, ya, xb, yb))
    return windows


def run_eval(eval_bin, model, image_path, compute):
    output = subprocess.run([eval_bin, "--model", model, "--image", image_path,
                             "--compute", compute, "--min-confidence", "0.1"],
                            capture_output=True, text=True, check=True).stdout
    return json.loads(output)


def detections_for(region, frame_image, eval_bin, model, compute, scratch):
    x0, y0, x1, y1 = region
    frame_image.crop(region).save(scratch)
    report = run_eval(eval_bin, model, scratch, compute)
    width, height = x1 - x0, y1 - y0
    found = []
    for entry in report["detections"]:
        found.append({
            "label": entry["classLabel"], "confidence": entry["confidence"],
            "cx": x0 + (entry["x"] + entry["width"] / 2) * width,
            "cy": y0 + (entry["y"] + entry["height"] / 2) * height,
            "w": entry["width"] * width, "h": entry["height"] * height,
        })
    return found, report["inferenceSeconds"]


def merge(detections, diameter):
    """Greedy cross-tile NMS on centre distance."""
    kept = []
    for detection in sorted(detections, key=lambda d: -d["confidence"]):
        if any(math.hypot(detection["cx"] - k["cx"], detection["cy"] - k["cy"]) < 0.6 * diameter
               and (detection["label"] in BALL_LABELS) == (k["label"] in BALL_LABELS)
               for k in kept):
            continue
        kept.append(detection)
    return kept


def inside(point, quad, grow):
    """Point in convex quad grown by `grow` px (signed edge distance)."""
    centre = (sum(p[0] for p in quad) / 4, sum(p[1] for p in quad) / 4)
    for index in range(4):
        a, b = quad[index], quad[(index + 1) % 4]
        ex, ey = b[0] - a[0], b[1] - a[1]
        length = math.hypot(ex, ey)
        cross = lambda p: (ex * (p[1] - a[1]) - ey * (p[0] - a[0])) / length
        side = 1 if cross(centre) > 0 else -1
        if side * cross(point) < -grow:
            return False
    return True


def score(frame, quad, detections, floor):
    diameter = frame["ballDiameterPx"]
    balls = [d for d in detections if d["label"] in BALL_LABELS and d["confidence"] >= floor
             and inside((d["cx"], d["cy"]), quad, diameter)]
    sticks = [d for d in detections if d["label"] == "cue" and d["confidence"] >= floor]
    labels = frame["balls"]
    matched = {}
    false_positives = 0
    for detection in sorted(balls, key=lambda d: -d["confidence"]):
        best, best_distance = None, max(8, 0.6 * diameter)
        for index, label in enumerate(labels):
            if index in matched:
                continue
            distance = math.hypot(detection["cx"] - label["x"], detection["cy"] - label["y"])
            if distance <= best_distance:
                best, best_distance = index, distance
        if best is None:
            false_positives += 1
        else:
            matched[best] = (detection, best_distance)
    cue_index = [i for i, label in enumerate(labels) if label["kind"] == "cue"]
    eight_index = [i for i, label in enumerate(labels) if label["kind"] == "eight"]
    return {
        "labelled": len(labels), "tp": len(matched), "fp": false_positives,
        "fn": len(labels) - len(matched),
        "cueLabelled": len(cue_index),
        "cueFound": sum(1 for i in cue_index if i in matched),
        "cueIdentified": sum(1 for i in cue_index if i in matched
                             and matched[i][0]["label"] == "white-ball"),
        "eightLabelled": len(eight_index),
        "eightFound": sum(1 for i in eight_index if i in matched),
        "whiteBallFalse": sum(1 for i, (d, _) in matched.items()
                              if d["label"] == "white-ball" and labels[i]["kind"] != "cue"),
        "meanCentreErrPx": round(sum(dist for _, dist in matched.values()) / len(matched), 2)
                           if matched else None,
        "stickBoxes": len(sticks),
        "missed": [labels[i]["colour"] for i in range(len(labels)) if i not in matched],
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("labels")
    parser.add_argument("--eval-bin", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--work", required=True)
    parser.add_argument("--modes", default="full,crop,tiles")
    parser.add_argument("--floor", type=float, default=0.35)
    parser.add_argument("--compute", default="cpu")
    args = parser.parse_args()
    os.makedirs(args.work, exist_ok=True)
    with open(args.labels) as handle:
        frames = json.load(handle)["frames"]

    totals = {}
    for frame in frames:
        image = Image.open(os.path.expanduser(frame["path"])).convert("RGB")
        quad = load_quad(frame)
        diameter = frame["ballDiameterPx"]
        crop = crop_box(quad, diameter, image.width, image.height)
        regions = {"full": [(0, 0, image.width, image.height)], "crop": [crop],
                   "tiles": tile_boxes(crop, diameter)}
        for target in (16, 20, 24, 28, 32):
            regions[f"scaled{target}"] = scaled_windows(crop, diameter, target,
                                                        image.width, image.height)
        for mode in args.modes.split(","):
            detections, seconds = [], 0.0
            for index, region in enumerate(regions[mode]):
                scratch = os.path.join(args.work, f"{frame['id']}-{mode}-{index}.png")
                found, elapsed = detections_for(region, image, args.eval_bin, args.model,
                                                args.compute, scratch)
                detections += found
                seconds += elapsed
            detections = merge(detections, diameter)
            with open(os.path.join(args.work, f"{frame['id']}-{mode}.json"), "w") as handle:
                json.dump(detections, handle)
            result = score(frame, quad, detections, args.floor)
            scale = min(640 / (r[2] - r[0]) for r in regions[mode]), min(640 / (r[3] - r[1]) for r in regions[mode])
            result.update({"frame": frame["id"], "mode": mode, "inferences": len(regions[mode]),
                           "ms": round(seconds * 1000, 1),
                           "ballPxAtModel": [round(diameter * scale[0], 1), round(diameter * scale[1], 1)]})
            print(json.dumps(result))
            sys.stdout.flush()
            bucket = totals.setdefault(mode, {})
            for key, value in result.items():
                if isinstance(value, (int, float)) and key not in ("meanCentreErrPx",):
                    bucket[key] = bucket.get(key, 0) + value
    for mode, bucket in totals.items():
        tp, fp, fn = bucket["tp"], bucket["fp"], bucket["fn"]
        print(json.dumps({"TOTAL": mode, "labelled": bucket["labelled"], "tp": tp, "fp": fp,
                          "fn": fn, "recall": round(tp / (tp + fn), 3),
                          "precision": round(tp / (tp + fp), 3) if tp + fp else None,
                          "cueIdentified": f"{bucket['cueIdentified']}/{bucket['cueLabelled']}",
                          "cueFound": f"{bucket['cueFound']}/{bucket['cueLabelled']}",
                          "eightFound": f"{bucket['eightFound']}/{bucket['eightLabelled']}",
                          "whiteBallFalse": bucket["whiteBallFalse"],
                          "stickBoxes": bucket["stickBoxes"], "inferences": bucket["inferences"]}))


if __name__ == "__main__":
    main()
