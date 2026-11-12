# Ground-truth grid: ball-position accuracy

A repeatable check of where the app puts balls, using balls placed by hand on
known spots. It measures the whole chain (calibration, detection, unprojection,
table frame) in one number, in centimetres, with no reference instrument other
than the table's own diamonds.

## Layout

Table frame: `x` along the long axis, `y` across. With playing-surface length
`L` (m), width is `L/2` and the diamond spacing is `s = L/8` along both axes.

- 15 object balls go on diamond-line intersections.
- Occupied rows: `x = k*s` for `k` in `{3, 2, 0, -2, -3}`.
- Occupied columns: `y = j*s` for `j` in `{1, 0, -1}`.
- Rows `k = +1` and `k = -1` stay **empty**.
- The cue ball is a 16th ball: put it anywhere clear of the grid. The scorer
  ignores it (`kind == "cue"`).

```
            y = +s     y = 0     y = -s
 x=+3s       (o)        (o)        (o)
 x=+2s       (o)        (o)        (o)
 x=+1s        .          .          .      <- empty row
 x= 0        (o)        (o)        (o)
 x=-1s        .          .          .      <- empty row
 x=-2s       (o)        (o)        (o)
 x=-3s       (o)        (o)        (o)

 plus one cue ball, anywhere else (ignored by the scorer)
```

For the app's 8 ft model (2.34 x 1.17 m) `s = 29.25 cm`, so the rows sit at
x = +87.75, +58.5, 0, -58.5, -87.75 cm and the columns at y = +29.25, 0, -29.25 cm.

## Run it

Pull the state from the device and score it (read-only; exit 0 always):

```
Scripts/grid-truth.py <device-host>                  # app's 8 ft model, 2.34 m
Scripts/grid-truth.py <device-host> --size 2.235     # custom table length in metres
Scripts/grid-truth.py state.json --json              # a saved /state.json, as JSON
Scripts/grid-truth.py <device-host> --max-rms-cm 4   # exit 1 when rms > 4 cm
```

`--length` and `--size` are the same flag: `sevenFoot|eightFoot|nineFoot`, metres
(`2.235`) or `<length>,<width>` (the width is ignored: it is always `L/2`).
Pulling from a host uses a 45 s timeout and retries (`--retries`, default 3).
Exit codes: 0 scored, 1 `--max-rms-cm` exceeded, 2 input unreadable.

As an advisory dry-run check: `Scripts/device-dryrun.py <host> --grid`
(`--grid-length M` overrides the table length, which otherwise comes from the
app's own `tableSize`, else 2.34). It records `grid_error` in `report.md`,
`report.json` (with a `metrics` object) and the JUnit file. It is never
required and never fails the run.

To compare table models on the device, relock with
`Scripts/calibrate-pockets.py <host> --size 2.235,1.118 --pocket ...` (it resets
the parked-pose hold first), wait for the balls to settle, then run
`grid-truth.py` with the matching `--size`.

Tests: `python3 -m unittest discover -s Scripts/tests`.

## Read the numbers

| Output | Meaning |
|---|---|
| per-ball `dx`, `dy`, `err` (cm) | tracked position minus its nearest occupied grid point |
| `rms`, `max` | overall error, the headline numbers |
| `mean dx`, `mean dy` | a systematic shift of the whole table frame (calibration offset) |
| `claimed twice` | two balls snapped to one grid point: the error is larger than half a spacing somewhere, so the other numbers are optimistic |
| `grid points with no ball` | a ball was missed, or sat closer to another point |
| `free fit x`/`y` | least-squares spacing fitted with no model (`x = ox + sx*k`); a ratio far from 1.000 means the table model's size is wrong, not the pose |

A good lock with the right size model shows both free-fit ratios near 1.000
and an rms close to the detector's own noise. A wrong size shows up as a ratio
that is not 1, even when the mean dx/dy are small.

## Results

Measured 2026-11-11 on the owner's iPad, build `564f8b2`. Two locks per model.
Balls on the grid, 14 or 15 tracked.

| Table model | Ball rms | Ball max |
|---|---|---|
| App's 8 ft: 2.34 x 1.17 m | 3.6-3.8 cm | up to 6.8 cm |
| Custom 88 x 44 in: 2.235 x 1.118 m | 2.8-2.9 cm | 4.9 cm |

Free-fit spacing along x was 2.24-2.26 m per 8 steps, i.e. about 4% under the
8 ft model's 2.34 m and close to the 2.235 m custom model.

**The true table size is unconfirmed.** The custom model scores better, which
is evidence the playing surface is shorter than 2.34 m, but it is not a
measurement. Pending: the owner measures the playing surface (cushion nose to
cushion nose) with a tape measure. Until then do not change the default size
on this evidence alone.
