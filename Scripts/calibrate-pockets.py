#!/usr/bin/env python3
"""Refine hand-picked pocket sightings on a parked device through the debug mirror.

    Scripts/calibrate-pockets.py <host> --size eightFoot \
        --pocket cornerTopLeft:81:602 --pocket cornerTopRight:378:350 ...

Why: the solver wants each pocket MOUTH centre (a corner of the cushion-nose
rectangle), which is hard to point at on a photo. This sends the sightings to
`/cmd?action=calibrateFromPockets`, reads the height-solve residual the app
reports in `lastProbe` ("... N mm rms"), and does a pattern search over the
view-point coordinates, keeping any change that lowers it. It stops as soon as
the app locks the table (`calibrationLocked`), or after --max-evals.

Coordinates are VIEW POINTS: mirror-image pixels divided by 2 on an iPad.
Standard library only. The device keeps whatever the last request produced:
re-run `cancelCalibration` first if you want a different size.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import urllib.parse
import urllib.request


def get(base: str, path: str, **q: str) -> bytes:
    url = base + path + ("?" + urllib.parse.urlencode(q) if q else "")
    with urllib.request.urlopen(url, timeout=20) as r:
        return r.read()


def attempt(base: str, pockets: dict[str, list[float]], size: str, height: str | None,
            settle: float) -> tuple[float | None, dict]:
    spec = ";".join(f"{k}:{v[0]:.1f}:{v[1]:.1f}" for k, v in pockets.items())
    q = {"action": "calibrateFromPockets", "pockets": spec, "v": size}
    if height:
        q["h"] = height
    get(base, "/cmd", **q)
    time.sleep(settle)
    s = json.loads(get(base, "/state.json"))
    m = re.search(r"(\d+(?:\.\d+)?) mm rms", s.get("lastProbe") or "")
    score = float(m.group(1)) if m else None
    if s.get("calibrationLocked"):
        score = 0.0 if score is None else score
    return score, s


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("host")
    ap.add_argument("--size", default="eightFoot")
    ap.add_argument("--h", help="force the cloth height (m); omit to solve it")
    ap.add_argument("--pocket", action="append", required=True, metavar="ID:X:Y")
    ap.add_argument("--step", type=float, default=8.0)
    ap.add_argument("--min-step", type=float, default=1.0)
    ap.add_argument("--max-evals", type=int, default=120)
    ap.add_argument("--settle", type=float, default=2.5)
    args = ap.parse_args()
    base = f"http://{args.host}:8787"
    pockets = {p.split(":")[0]: [float(p.split(":")[1]), float(p.split(":")[2])]
               for p in args.pocket}

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
    print(json.dumps({"residual_mm": best, "locked": state.get("calibrationLocked"),
                      "evals": evals, "pockets": pockets,
                      "pocketFit": state.get("pocketFit"), "tableSize": state.get("tableSize"),
                      "sizeVsStandard": state.get("sizeVsStandard")}, indent=2))
    return 0 if state.get("calibrationLocked") else 1


if __name__ == "__main__":
    sys.exit(main())
