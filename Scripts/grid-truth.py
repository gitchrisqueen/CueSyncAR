#!/usr/bin/env python3
"""Score tracked ball positions against the diamond-intersection ground-truth grid.

    Scripts/grid-truth.py <host | url | state.json> [--length 2.34 | --size eightFoot | 2.235]
                          [--json] [--max-rms-cm N]

Layout (see docs/validation/ground-truth-grid.md): 15 object balls sit on the
diamond-line intersections of the table. Table frame: x along the long axis,
y across. With playing-surface length L, width L/2 and diamond spacing
s = L/8 along both axes, the occupied rows are x = k*s for k in {3, 2, 0, -2, -3}
and the columns y = j*s for j in {1, 0, -1}. Rows k = +-1 are EMPTY. The cue
ball (kind == "cue") is a 16th ball and is ignored.

Each non-cue ball is assigned to its nearest grid point. The report gives the
per-ball dx/dy/err (cm), rms, max, mean dx/dy, the number of grid points
claimed twice and the grid points nobody claimed. It also fits the spacing
freely (least squares, x = ox + sx*k and y = oy + sy*j): when the table model
is wrong the fitted spacing differs from L/8 even if the offsets are good.

The input is a host (pulls http://<host>:8787/state.json, 45 s timeout,
retries), a full URL, or a saved state.json. Exit 0 always, except 2 when the
input is unreadable; with --max-rms-cm N exit 1 when rms > N (or no ball could
be scored). Standard library only. Nothing is written anywhere.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
import urllib.error
import urllib.request

PORT = 8787
TIMEOUT_S = 45
STANDARD_LENGTHS_M = {"sevenFoot": 1.98, "eightFoot": 2.34, "nineFoot": 2.54}
DEFAULT_LENGTH_M = 2.34
OCCUPIED_ROWS = (3, 2, 0, -2, -3)   # k, in units of s along x
OCCUPIED_COLS = (1, 0, -1)          # j, in units of s along y


# --------------------------------------------------------------------------
# Pure scoring


def parse_length(text: str) -> float:
    """`eightFoot`, `2.34`, or `<length>,<width>` (metres; the width is ignored)."""
    text = text.strip()
    if text in STANDARD_LENGTHS_M:
        return STANDARD_LENGTHS_M[text]
    try:
        value = float(text.split(",")[0])
    except ValueError:
        value = 0.0
    if not 0.5 < value < 5.0:
        raise argparse.ArgumentTypeError(
            f"table length {text!r}: use sevenFoot|eightFoot|nineFoot or metres such as 2.235")
    return value


def grid_points(length: float) -> list[tuple[int, int, float, float]]:
    """(k, j, x, y) for every occupied intersection."""
    s = length / 8
    return [(k, j, k * s, j * s) for k in OCCUPIED_ROWS for j in OCCUPIED_COLS]


def fit_line(ks: list[int], values: list[float]) -> tuple[float, float] | None:
    """Least squares value = offset + slope*k. None without two distinct k."""
    n = len(ks)
    if n < 2 or len(set(ks)) < 2:
        return None
    mk, mv = sum(ks) / n, sum(values) / n
    sxx = sum((k - mk) ** 2 for k in ks)
    slope = sum((k - mk) * (v - mv) for k, v in zip(ks, values)) / sxx
    return mv - slope * mk, slope


def score(balls: list[dict], length: float) -> dict:
    """Assign each non-cue ball to its nearest grid point and summarise."""
    grid = grid_points(length)
    rows = []
    for b in balls:
        if b.get("kind") == "cue":
            continue
        k, j, gx, gy = min(grid, key=lambda g: math.hypot(g[2] - b["x"], g[3] - b["y"]))
        dx, dy = b["x"] - gx, b["y"] - gy
        rows.append({"k": k, "j": j, "grid_x": gx, "grid_y": gy, "x": b["x"], "y": b["y"],
                     "dx_cm": dx * 100, "dy_cm": dy * 100, "err_cm": math.hypot(dx, dy) * 100,
                     "colour": b.get("colour", "?")})
    rows.sort(key=lambda r: (-r["k"], -r["j"]))
    n = len(rows)
    claimed = {(r["k"], r["j"]) for r in rows}
    result: dict = {
        "length_m": length, "spacing_m": length / 8, "n": n, "balls": rows,
        "rms_cm": None, "max_cm": None, "mean_dx_cm": None, "mean_dy_cm": None,
        "claimed_twice": n - len(claimed),
        "unclaimed": [{"k": k, "j": j} for k, j, _, _ in grid if (k, j) not in claimed],
        "fit_x": None, "fit_y": None,
    }
    if n:
        result["rms_cm"] = math.sqrt(sum(r["err_cm"] ** 2 for r in rows) / n)
        result["max_cm"] = max(r["err_cm"] for r in rows)
        result["mean_dx_cm"] = sum(r["dx_cm"] for r in rows) / n
        result["mean_dy_cm"] = sum(r["dy_cm"] for r in rows) / n
    fx = fit_line([r["k"] for r in rows], [r["x"] for r in rows])
    if fx:
        result["fit_x"] = {"offset_m": fx[0], "spacing_m": fx[1], "length_m": fx[1] * 8,
                           "ratio": fx[1] / (length / 8)}
    fy = fit_line([r["j"] for r in rows], [r["y"] for r in rows])
    if fy:
        result["fit_y"] = {"offset_m": fy[0], "spacing_m": fy[1], "length_m": fy[1] * 8,
                           "ratio": fy[1] / (length / 8)}
    return result


def format_report(r: dict) -> str:
    lines = [f"table model {r['length_m']:.3f} x {r['length_m'] / 2:.3f} m, "
             f"diamond spacing {r['spacing_m'] * 100:.2f} cm"]
    for b in r["balls"]:
        lines.append(f"grid ({b['grid_x']:+.3f},{b['grid_y']:+.3f})  "
                     f"got ({b['x']:+.2f},{b['y']:+.2f})  dx {b['dx_cm']:+5.1f} "
                     f"dy {b['dy_cm']:+5.1f} cm  err {b['err_cm']:4.1f} cm  {b['colour']}")
    if r["n"]:
        lines.append(f"n={r['n']} rms {r['rms_cm']:.1f} cm  max {r['max_cm']:.1f} cm  "
                     f"mean dx {r['mean_dx_cm']:+.1f} cm  mean dy {r['mean_dy_cm']:+.1f} cm")
    else:
        lines.append("n=0: no non-cue balls in the state")
    lines.append(f"grid points claimed twice: {r['claimed_twice']}")
    if r["unclaimed"]:
        lines.append("grid points with no ball: "
                     + ", ".join(f"(k={u['k']:+d},j={u['j']:+d})" for u in r["unclaimed"]))
    for axis, key in (("x", "fit_x"), ("y", "fit_y")):
        f = r[key]
        if f:
            lines.append(f"free fit {axis}: spacing {f['spacing_m'] * 100:.2f} cm "
                         f"(model {r['spacing_m'] * 100:.2f} cm, ratio {f['ratio']:.3f}), "
                         f"= {f['length_m']:.3f} m per 8 steps, offset {f['offset_m'] * 100:+.1f} cm")
        else:
            lines.append(f"free fit {axis}: not enough distinct grid lines")
    return "\n".join(lines)


# --------------------------------------------------------------------------
# Input


def load_state(source: str, retries: int = 3, timeout: float = TIMEOUT_S) -> dict:
    """A state.json path, a URL, or a mirror host. Raises OSError/ValueError."""
    if os.path.isfile(source):
        with open(source, encoding="utf-8") as f:
            return json.load(f)
    if "://" in source:
        url = source if source.rstrip("/").endswith(".json") else source.rstrip("/") + "/state.json"
    else:
        url = f"http://{source}:{PORT}/state.json"
    last: Exception = OSError("no attempt made")
    for attempt in range(max(1, retries)):
        try:
            with urllib.request.urlopen(url, timeout=timeout) as r:
                return json.loads(r.read())
        except (urllib.error.URLError, OSError, ValueError) as exc:
            last = exc
            if attempt + 1 < retries:
                time.sleep(3)
    raise OSError(f"cannot read {url}: {last}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("source", help="mirror host, URL, or a saved state.json")
    ap.add_argument("--length", "--size", dest="length", type=parse_length,
                    default=DEFAULT_LENGTH_M, metavar="L",
                    help="playing-surface length: metres (2.34), `<length>,<width>`, or "
                         "sevenFoot|eightFoot|nineFoot (default 2.34 = eightFoot)")
    ap.add_argument("--json", action="store_true", help="print the result as JSON")
    ap.add_argument("--max-rms-cm", type=float, metavar="N",
                    help="exit 1 when rms exceeds N cm")
    ap.add_argument("--retries", type=int, default=3, help="attempts when pulling from a host")
    args = ap.parse_args(argv)

    try:
        state = load_state(args.source, retries=args.retries)
        balls = state["balls"]
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"grid-truth: cannot read balls from {args.source}: {exc}", file=sys.stderr)
        return 2
    try:
        result = score(balls, args.length)
    except (KeyError, TypeError) as exc:
        print(f"grid-truth: ball entry without numeric x/y ({exc})", file=sys.stderr)
        return 2

    print(json.dumps(result, indent=2) if args.json else format_report(result))
    if args.max_rms_cm is not None and (result["rms_cm"] is None
                                        or result["rms_cm"] > args.max_rms_cm):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
