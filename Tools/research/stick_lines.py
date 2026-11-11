#!/usr/bin/env python3
# stick_lines.py / CueSync AR research
#
# Question 5 of docs/research/2026-11-10-ball-detection-and-identity.md:
# can plain line-segment geometry, restricted to the table and anchored at
# the cue ball, find the cue stick where the detector's `cue` box fails?
#
# For each frame with a hand-labelled stick (two points along its axis):
#   1. LSD (cv2.createLineSegmentDetector) on the grey frame, inside the
#      table quad grown by one ball (a stick's shaft crosses the rail).
#   2. Keep segments at least 3 ball diameters long.
#   3. unanchored: the longest such segment.
#      anchored:   the longest whose infinite line passes within 1 ball
#                  diameter of the cue-ball centre and whose nearer end is
#                  within 8 diameters of it (the tip addresses the ball).
#   4. Score: angle error to the labelled axis (degrees) and the distance
#      of the labelled tip from the found line (px); a hit is <= 3 degrees
#      and the tip within one ball diameter of the line.
# It also scores the detector's own `cue` boxes saved by crop_eval.py
# (mode full): how many fire at >= 0.35 and whether the best one even
# overlaps the labelled stick.
#
# Deps: pip install opencv-python-headless numpy
# Usage: stick_lines.py STICKS.json DETECTIONS_DIR
import json
import math
import os
import sys

import cv2
import numpy as np


def inside(point, quad, grow):
    centre = (sum(p[0] for p in quad) / 4, sum(p[1] for p in quad) / 4)
    for index in range(4):
        a, b = quad[index], quad[(index + 1) % 4]
        ex, ey = b[0] - a[0], b[1] - a[1]
        length = math.hypot(ex, ey)

        def cross(p):
            return (ex * (p[1] - a[1]) - ey * (p[0] - a[0])) / length
        side = 1 if cross(centre) > 0 else -1
        if side * cross(point) < -grow:
            return False
    return True


def line_distance(point, a, b):
    ax, ay = a
    bx, by = b
    length = math.hypot(bx - ax, by - ay)
    return abs((bx - ax) * (ay - point[1]) - (ax - point[0]) * (by - ay)) / length


def angle(a, b):
    return math.degrees(math.atan2(b[1] - a[1], b[0] - a[0])) % 180


def angle_error(first, second):
    d = abs(first - second) % 180
    return min(d, 180 - d)


def box_hits_segment(box, a, b):
    """Does the box contain any of 20 points along the labelled stick?"""
    x0, y0 = box["cx"] - box["w"] / 2, box["cy"] - box["h"] / 2
    x1, y1 = x0 + box["w"], y0 + box["h"]
    for t in np.linspace(0, 1, 20):
        x, y = a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1])
        if x0 <= x <= x1 and y0 <= y <= y1:
            return True
    return False


def main():
    with open(sys.argv[1]) as handle:
        frames = json.load(handle)["frames"]
    detections_dir = sys.argv[2]
    lsd = cv2.createLineSegmentDetector()
    print("frame\tmethod\tangleErrDeg\ttipOffPx\tlengthPx")
    summary = {"unanchored": [], "anchored": []}
    detector = {"frames": 0, "boxes": 0, "bestHits": 0, "anyHits": 0}
    for frame in frames:
        image = cv2.imread(os.path.expanduser(frame["path"]))
        grey = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
        d = frame["ballDiameterPx"]
        quad = frame["quad"]
        tip, butt = frame["stick"]["tip"], frame["stick"]["butt"]
        truth = angle(tip, butt)
        cue = frame["cueBall"]
        segments = lsd.detect(grey)[0]
        candidates = []
        for x1, y1, x2, y2 in (segments.reshape(-1, 4) if segments is not None else []):
            a, b = (x1, y1), (x2, y2)
            length = math.hypot(x2 - x1, y2 - y1)
            if length < 3 * d:
                continue
            middle = ((x1 + x2) / 2, (y1 + y2) / 2)
            if not inside(middle, quad, d):
                continue
            candidates.append((length, a, b))
        anchored = []
        for length, a, b in candidates:
            near_end = min(math.hypot(a[0] - cue[0], a[1] - cue[1]),
                           math.hypot(b[0] - cue[0], b[1] - cue[1]))
            if line_distance(cue, a, b) <= d and near_end <= 8 * d:
                anchored.append((length, a, b))
        for method, pool in (("unanchored", candidates), ("anchored", anchored)):
            if not pool:
                print(f"{frame['id']}\t{method}\tnone\t-\t-")
                summary[method].append(None)
                continue
            length, a, b = max(pool)
            error = angle_error(angle(a, b), truth)
            offset = line_distance(tip, a, b)
            summary[method].append((error, offset, d))
            print(f"{frame['id']}\t{method}\t{error:.1f}\t{offset:.1f}\t{length:.0f}")
        path = os.path.join(detections_dir, f"{frame['detId']}-full.json")
        if os.path.exists(path):
            with open(path) as handle:
                boxes = [b for b in json.load(handle)
                         if b["label"] == "cue" and b["confidence"] >= 0.35]
            detector["frames"] += 1
            detector["boxes"] += len(boxes)
            if boxes:
                best = max(boxes, key=lambda b: b["confidence"])
                detector["bestHits"] += box_hits_segment(best, tip, butt)
                detector["anyHits"] += any(box_hits_segment(b, tip, butt) for b in boxes)
    for method, results in summary.items():
        found = [r for r in results if r]
        good = [r for r in found if r[0] <= 3 and r[1] <= r[2]]
        print(json.dumps({"method": method, "frames": len(results), "found": len(found),
                          "within3degAndTip": len(good),
                          "medianAngleErr": round(float(np.median([r[0] for r in found])), 2)
                          if found else None}))
    print(json.dumps({"detectorCueBoxes": detector}))


if __name__ == "__main__":
    main()
