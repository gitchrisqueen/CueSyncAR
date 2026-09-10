# 2026-09-10 — calibration driven remotely, both paths

**Device:** `iPad12,1` (iPad 9th generation), iOS 26, parked beside an
8 ft table (playing field 2.34 × 1.17 m). Driven entirely over the debug
mirror at `192.168.50.24:8787` — no one at the table.

**Builds:** `3a0b58f` through the merge of #127, each installed with
`devicectl` and relaunched between measurements.

## What was measured, and how

`/frame.jpg` was captured, six pocket mouths located in it, and their
view-point coordinates (mirror image pixels ÷ 2) issued to
`/cmd?action=calibrateFromPockets`. `/cmd?action=probe` — added during
this run — unprojects one view point against a stated plane and reports
the world point and its range, which is what made the geometry
measurable at all.

### The cloth height, solved from geometry

Probing two pockets at two trial plane heights gives, for each pair, a
linear relation between plane depth and measured separation. Solving for
the depth at which the separation equals the table's true dimension:

| pair | true length | solved cloth height |
|---|---|---|
| far-left ↔ far-right pocket | 2.34 m | **-0.5275** |
| far-left ↔ near-left pocket | 1.17 m | **-0.5290** |

Two independent pairs, **1.5 mm apart**.

### The ball-derived estimate, over the same session

| reading | samples | reported spread | ball ranges |
|---|---|---|---|
| -0.349 | 11 | 13 mm | 2.27–4.11 m |
| -0.370 | 48 | 10 mm | 2.28–4.52 m |
| -0.512 | 80 | 13 mm | 1.95–3.13 m |
| -0.229 | — | — | 2.37–3.96 m |

**283 mm of range. Settled 158 mm from truth. Never reported more than
15 mm of spread.**

The estimate is not noisy, it is systematically biased and unstable: a
ball at 2.4–4 m is about sixteen pixels across, so one pixel of box error
is six per cent of range and roughly three centimetres of cloth. Samples
move together, so agreement among them says nothing about accuracy.

## Both paths, after the fix

| path | input | result |
|---|---|---|
| **pockets** | four corner mouths, no height hint, no balls | cloth solved to 6 mm rms; table fit **5 mm rms**, worst pocket 6 mm; locked |
| **corners** | four taps **in deliberately scrambled order** | tightened **-144 mm** from a provisional height; locked **2.34 × 1.17 m** — *"8 ft +1.0 cm"* |

Before the fix, the same six pocket taps produced *"Fit is 34 cm out"* and
were refused; the corner path could not place a single corner, refusing
every tap with *"corner missed the table plane"* on a table filling the
frame, because a parked device gives ARKit no parallax and there was no
ball height to fall back on.

### Health at the end of the run

```
cameraFps 60 · thermal nominal · battery 75 % · skippedFrames 0
```

## Refusals, checked deliberately

- Six pockets including two side-pocket sightings taken from the leather
  rather than the mouth: **refused**, 55 mm rms. Correct — sighting a
  pocket mouth from across the room is harder than a corner, and the fit
  said so rather than proposing a wrong table.
- Two pockets: **refused** at the four-pocket minimum. A rigid fit through
  two points has no redundancy; an earlier two-pocket fit was 429 mm out
  and reported a near-zero residual.

## Not verified here

- **The verification overlay.** `/frame.jpg` is an ARView snapshot with no
  SwiftUI in it, so the diamonds, rings and strings cannot be
  photographed remotely. Untested against a real table's inlays.
- **Ball placement end-to-end.** The plane is now right; whether that
  puts detected balls in the right place needs a tape measure.
- **Any second table.** One table, one room, one device.
