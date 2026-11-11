#!/usr/bin/env python3
"""Lock the table from pocket sightings on a parked device through the debug mirror.

    Scripts/calibrate-pockets.py <host> --size eightFoot \
        --pocket cornerTopLeft:89:602 --pocket cornerTopRight:386:334 \
        --pocket cornerBottomRight:702:333 --pocket cornerBottomLeft:972:594 \
        --pocket sideTop:285:419 --pocket sideBottom:788:408

Coordinates are VIEW POINTS: mirror-image pixels divided by 2 on an iPad.

Default (rough picks are enough): the app snaps each pick to the cushion-nose
geometry in its own camera frame (TableSpace.PocketSnap), fits the table with
the plane's tilt free, and measures the size from the balls (it applies the
size only when the measurement is decisive). Give all six pockets: the side
pockets let a bad pick be named and left out. The script sends the picks once
and prints the fit, the snap of each pick and the size check.

--preview: also run the same snap offline on /frame.jpg first (Tools/PocketSnap,
built on demand; needs ffmpeg). The mirror frame carries the AR overlay, so
treat this as a preview of where the picks will go, not the device's answer.

--search: the old behaviour for builds without snapping: a pattern search over
the picks that keeps any change lowering the height-solve residual in
`lastProbe`, until the table locks or --max-evals.

Standard library only. The device keeps whatever the last request produced.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def get(base: str, path: str, **q: str) -> bytes:
    url = base + path + ("?" + urllib.parse.urlencode(q) if q else "")
    with urllib.request.urlopen(url, timeout=20) as r:
        return r.read()


def send(base: str, pockets: dict[str, list[float]], size: str, height: str | None) -> None:
    spec = ";".join(f"{k}:{v[0]:.1f}:{v[1]:.1f}" for k, v in pockets.items())
    q = {"action": "calibrateFromPockets", "pockets": spec, "v": size}
    if height:
        q["h"] = height
    get(base, "/cmd", **q)


def attempt(base: str, pockets: dict[str, list[float]], size: str, height: str | None,
            settle: float) -> tuple[float | None, dict]:
    send(base, pockets, size, height)
    time.sleep(settle)
    s = json.loads(get(base, "/state.json"))
    m = re.search(r"(\d+(?:\.\d+)?) mm rms", s.get("lastProbe") or "")
    score = float(m.group(1)) if m else None
    if s.get("calibrationLocked"):
        score = 0.0 if score is None else score
    return score, s


def preview(base: str, pockets: dict[str, list[float]]) -> None:
    tool = os.path.join(REPO, "Tools", "PocketSnap")
    binary = os.path.join(tool, ".build", "release", "pocket-snap")
    if not os.path.exists(binary):
        subprocess.run(["swift", "build", "-c", "release", "--package-path", tool], check=True)
    with tempfile.TemporaryDirectory() as tmp:
        jpg = os.path.join(tmp, "frame.jpg")
        gray = os.path.join(tmp, "frame.gray")
        with open(jpg, "wb") as f:
            f.write(get(base, "/frame.jpg"))
        probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                                "stream=width,height", "-of", "csv=p=0", jpg],
                               capture_output=True, text=True, check=True).stdout.strip()
        width, height = probe.split(",")
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", jpg, "-vf", "format=gray",
                        "-f", "rawvideo", gray], check=True)
        picks = [f"{k}:{v[0]}:{v[1]}" for k, v in pockets.items()]
        out = subprocess.run([binary, gray, width, height, "2", *picks],
                             capture_output=True, text=True, check=True).stdout
        print("offline snap preview (pocket:x:y method shift):\n" + out, flush=True)


def report(state: dict) -> dict:
    pose = state.get("pose") or {}
    return {"locked": state.get("calibrationLocked"), "pocketFit": state.get("pocketFit"),
            "pocketFitDetail": pose.get("pocketFitDetail"), "pocketSnap": pose.get("pocketSnap"),
            "sizeFromImage": pose.get("sizeFromImage"), "sizeStatus": pose.get("sizeStatus"),
            "tableSize": state.get("tableSize"), "heightSource": state.get("calibrationHeightSource")}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("host")
    ap.add_argument("--size", default="eightFoot",
                    help="the size to use when the image cannot measure it decisively")
    ap.add_argument("--h", help="force the cloth height (m); uses the old flat fit")
    ap.add_argument("--pocket", action="append", required=True, metavar="ID:X:Y")
    ap.add_argument("--preview", action="store_true")
    ap.add_argument("--search", action="store_true")
    ap.add_argument("--step", type=float, default=8.0)
    ap.add_argument("--min-step", type=float, default=1.0)
    ap.add_argument("--max-evals", type=int, default=120)
    ap.add_argument("--settle", type=float, default=8.0,
                    help="seconds to wait for the app (it grabs and detects a frame first)")
    args = ap.parse_args()
    base = f"http://{args.host}:8787"
    pockets = {p.split(":")[0]: [float(p.split(":")[1]), float(p.split(":")[2])]
               for p in args.pocket}

    if args.preview:
        preview(base, pockets)
    if not args.search:
        send(base, pockets, args.size, args.h)
        time.sleep(args.settle)
        state = json.loads(get(base, "/state.json"))
        print(json.dumps(report(state), indent=2))
        return 0 if state.get("calibrationLocked") else 1

    best, state = attempt(base, pockets, args.size, args.h, args.settle)
    evals = 1
    print(f"start residual {best} mm  locked={state.get('calibrationLocked')}", flush=True)
    step = args.step
    while best is not None and not state.get("calibrationLocked") and evals < args.max_evals \
            and step >= args.min_step:
        improved = False
        for name in pockets:
            for axis in (0, 1):
                for sign in (+1, -1):
                    if evals >= args.max_evals or state.get("calibrationLocked"):
                        break
                    trial = {k: list(v) for k, v in pockets.items()}
                    trial[name][axis] += sign * step
                    score, st = attempt(base, trial, args.size, args.h, args.settle)
                    evals += 1
                    if score is not None and score < best:
                        best, pockets, state, improved = score, trial, st, True
                        print(f"  {name} axis{axis} {sign * step:+.1f} -> {best} mm "
                              f"(eval {evals})", flush=True)
        if not improved:
            step /= 2
            print(f"step -> {step}", flush=True)
    result = report(state)
    result.update({"residual_mm": best, "evals": evals, "pockets": pockets})
    print(json.dumps(result, indent=2))
    return 0 if state.get("calibrationLocked") else 1


if __name__ == "__main__":
    sys.exit(main())
