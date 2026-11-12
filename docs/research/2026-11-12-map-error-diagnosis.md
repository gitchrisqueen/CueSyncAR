# Ball map error on the diamond grid: diagnosis (2026-11-12)

Question: the app places the 14 tracked grid balls 3.1-4.9 cm rms from their
diamond spots. What causes this, and can a change to the pocket lock bring it
to 2.0 cm rms or less, shown offline?

Short answer: **no single cause explains it, and none of the tested corrections
reaches 2.0 cm from data a normal lock has.** The error splits into three
parts (largest first):

1. A shift that changes from lock to lock (1.1-3.8 cm).
2. A rotation that changes from lock to lock (0.0-1.2 deg).
3. A shape error repeated in every lock: about 2.5 % compression and a shear.

The 0.9 deg plane tilt that the pocket fit finds is not a mistake. The balls
need more tilt relative to ARKit's gravity, not less. No code change is
committed with this note: no candidate change showed a gain offline.

Data: five locks of the same hand-placed layout, all with the iPad on its stand:

| Lock | Build | Camera position |
|---|---|---|
| state2 | 3e3b3e8 | different from the other four |
| state3, state_final | 32ccb6f | the stand position |
| snapshot | 564f8b2 | the stand position |
| merged lock | 34acd56 | the stand position |

The run data stays local and is not committed. The analysis scripts are local
too: pure Python with numpy, run outside the repo.

## 1. Rebuilding the chain offline

**The frame is not the pipeline's buffer.** `/frame.jpg` is an ARView
snapshot: 2160 x 1620, which is the 1080 x 810 pt view at 2x. The capture
buffer is 1440 x 1080. Both are 4:3, so normalised image coordinates are the
same in both and no crop applies. The snapshot has the app's overlays drawn
into it: ball rings, aim lines and the ghost ball. The detector run on it
returns boxes that merge with the rings, or come out about 20 % smaller than
the ball disc. The clean boxes the pipeline used were never saved.

**The camera, recovered from the overlays.** Each grey ball ring is drawn at
the app's world position for that ball, 2 mm above the cloth. ARKit's own
camera projects it. I measured 12 ring centres in the frame. I then fitted the
camera to them, with the recorded iPad intrinsics held fixed (f = 1303.06 px
at 1440 x 1080, principal point at the image centre).

| | yaw (deg) | pitch (deg) | roll (deg) | position (m) |
|---|---|---|---|---|
| Ring fit, 0.6 px rms (max 1.4 px) | -0.03 | -16.12 | -0.68 | (0.001, 0.013, -0.002) |
| `cameraRaw` + hold transform, from state.json | +0.01 | -16.06 | n/a | (-0.003, 0.018, -0.004) |

The second row comes from a 2-D rigid fit of `ballsWorld` raw against
corrected positions (residual 1.1 mm max). The two estimates agree to 0.06 deg
and 5 mm. The four other locks use the second method.

**The pipeline's own rays.** `PerceptionPipeline` casts the box-centre ray
onto the cloth plane lifted by one ball radius, then drops the hit to the
cloth. So the ray it used for each ball is the line from the camera to
(`ballsWorld` point + R x normal). Rebuilding the lock from `calibration.corners`
and re-intersecting those rays gives back the `pose.ballsWorld` positions
exactly. Re-scoring them against the grid gives 3.96 cm rms. fit.py gives
3.97 cm for the same lock.

**Ball discs against the pipeline's pixels.** Six coloured balls in the frame
are clean enough to measure. Their disc centres sit 2-3 px from the pixel the
pipeline used. For one near ball the gap is 8 px. The measurement is coarse
because of JPEG halo, so I do not use it to correct anything.

**Pockets.** The snapped pocket pixels are not saved. The pocket rays below
are rebuilt as camera to fitted nose point. These are within the fit's
4.3 mm rms of the real sightings, but this method loses that residual pattern.
So leave-one-out tests cannot be done offline with this data.

## 2. Candidates, one at a time

Method: apply the correction, refit the pocket lock the app's way, then
re-score the 14 balls against the grid. The app's way is `solveTilted`:
height and tilt free, near corners along-free, size 2.34 x 1.17 m.

Columns:
- raw = rms against the grid.
- minus shift = rms after removing the mean offset.
- Shift = mean (dx, dy). +x is the far end; +y is the left side as seen from
  the camera.

All rows are for the 564f8b2 snapshot unless the row says otherwise.

| Candidate | Predicted error field | raw (cm) | minus shift (cm) | shift (cm) |
|---|---|---|---|---|
| **Baseline (app lock)** | | **3.96** | **2.39** | (+2.4, +2.0) |
| Plane tilt forced level, height free | shape error grows, far end pushed out | 6.29 | 3.66 | (+4.5, +2.5) |
| Plane tilt forced level, all 5 locks | same | 5.2-8.3 | 3.6-5.9 | |
| Plane tilt set to the balls' own slopes, all 5 locks | the shape barely changes | 2.6-4.3 | 2.3-3.3 | |
| Cloth -0.589 m (`clothFromBalls`), tilt kept | homothety about the camera foot: everything pulled 10 cm toward the camera | 10.98 | 5.01 | (-9.6, +1.8) |
| Cloth -0.610 m | same, smaller | 3.82 | 2.99 | (-1.4, +1.9) |
| Cloth -0.630 m | the other way | 7.16 | 2.29 | (+6.5, +2.1) |
| Pockets sighted at cloth (0 mm) | the cloth comes out 3.6 cm high | 13.21 | 5.61 | (-11.8, +1.8) |
| Pockets sighted at 20 mm | | 5.65 | 3.55 | (-4.0, +1.9) |
| Pockets sighted at 50 mm (rail-like) | | 8.46 | 2.40 | (+7.8, +2.1) |
| Nose height left free in a joint fit with the balls, 5 locks | | | | fitted 33-45 mm (model 36.3 mm) |
| Side-pocket point 20 mm outward / inward | small change of tilt | 3.79 / 4.18 | 2.31 / 2.52 | |
| Side-pocket point 20 mm toward / away from the camera | changes the far-end tilt | 3.09 / 5.40 | 2.25 / 2.70 | (+0.7 / +4.2, +2.0) |
| Side and far-corner offsets left free in a joint fit, 5 locks | | | | each ±10-20 mm, signs differ between locks |
| Sphere-centre lift 0 / 14.3 / 42.9 mm (app 28.6) | x shift 5.5 cm per 14 mm of lift | 14.29 / 8.68 / 5.00 | 3.45 / 2.42 / 3.37 | |
| Focal length -2 % / +2 % | | 4.35 / 3.64 | 2.69 / 2.15 | |
| Principal point y ±20 px (2160 frame) | absorbed by tilt (1.44 / 0.51 deg) | 4.01 / 3.91 | 2.43 / 2.35 | |
| Principal point x ±20 px | | 3.92 / 4.00 | 2.41 / 2.37 | |
| Radial distortion k1 from -0.06 to +0.06, 5 locks | | ±0.1 at most | ±0.1 at most | |
| Detector box centre biased vertically by c x radius, c from -0.1 to 0.5, 5 locks | only moves the x shift | best 2.9-4.9 | worse in every lock | |
| Parked hold: ball rays turned ±2.13 deg about the camera | full hold correction undone | 7.24 / 11.42 | 2.78 / 4.13 | |
| Ball rays turned to the best yaw, per lock | rotation and y shift | 2.87-3.77 (state2 3.63) | | best yaw -0.30 to -0.95 deg |
| Table 2.235 x 1.118 m (88 x 44 in) | grid and pockets both rescaled | 3.87 | 2.27 | (+2.5, +1.9) |
| Table 2.337 x 1.168 m (92 x 46 in) | | 3.96 | 2.38 | (+2.4, +2.0) |

How the error splits in each lock. "Rigid" removes the shift and a rotation.
"Similarity" also removes a uniform scale. The last three columns leave out
the four black balls.

| Lock | raw | shift only | rigid (rotation) | similarity (scale) | non-black raw | non-black rigid | non-black similarity |
|---|---|---|---|---|---|---|---|
| state2 | 3.64 | 2.99 | 2.99 (+0.02 deg) | 2.20 (0.971) | 3.86 | 2.81 | 1.88 |
| state3 | 3.96 | 3.48 | 3.38 (+0.68 deg) | 2.00 (0.961) | 3.53 | 3.17 | 1.55 |
| state_final | 4.85 | 3.12 | 2.75 (+1.22 deg) | 2.03 (0.973) | 4.75 | 2.46 | 1.60 |
| snapshot 564f8b2 | 3.97 | 2.39 | 2.20 (+0.78 deg) | 2.02 (0.987) | 4.20 | 1.66 | 1.52 |
| merged 34acd56 | 3.13 | 2.40 | 2.34 (+0.45 deg) | 1.89 (0.980) | 3.18 | 2.21 | 1.71 |

What this shows:

- **The shift is the largest term, and it is not repeatable.**
  - Shifts per lock: (+2.1, -0.3), (-1.5, +1.1), (+0.7, +3.7), (+2.4, +2.0)
    and (+1.7, +1.1) cm.
  - The app's own leave-one-out error says the same thing. Its worst pocket is
    18-27 mm off in every lock, so the lock's position is good to about 2 cm.
  - No candidate correction removes the shift in all locks.
- **The rotation is not repeatable either.** It ranges from 0.0 to 1.2 deg.
  For balls about 2.4 m away, 0.5 deg of yaw is 2 cm of y shift.
- **The repeated part is a scale of 0.961-0.987 plus a shear.** Some of it is
  in the grid itself: the balls were placed by hand once and never moved, so
  any placement error repeats in every lock.

## 3. Plane and pose from the balls and the pockets together

Fitting the 14 balls with the plane and table pose free (6 unknowns, size
2.34 m) gives 1.74-1.86 cm in every lock. That is better than a similarity
fit (4 unknowns) and worse than an affine fit. Slopes are the change in plane
height per metre along world x (across the table) and world z (along the
table).

| Lock | App: cloth y / tilt / slope x / slope z / heading | Balls only: same, rms | Balls + pockets: same, ball rms, pocket rms |
|---|---|---|---|
| state2 (different camera) | -0.572 / 1.49 / -0.002 / 0.026 / -3.36 | -0.570 / 2.11 / 0.008 / 0.036 / -3.60, 1.74 | -0.576 / 1.75 / 0.001 / 0.031 / -3.46, 2.05 cm |
| state3 | -0.618 / 0.92 / 0.009 / 0.014 / +0.15 | -0.632 / 1.46 / 0.018 / 0.018 / +0.57, 1.77 | -0.627 / 1.07 / 0.012 / 0.015 / +0.34, 2.54 cm |
| state_final | -0.627 / 0.94 / 0.008 / 0.015 / -1.95 | -0.635 / 1.45 / 0.017 / 0.019 / -0.98, 1.79 | -0.633 / 1.17 / 0.012 / 0.017 / -1.55, 2.44 cm |
| snapshot 564f8b2 | -0.620 / 0.92 / 0.008 / 0.014 / -0.66 | -0.624 / 1.29 / 0.016 / 0.016 / -0.11, 1.86 | -0.623 / 1.10 / 0.011 / 0.016 / -0.41, 2.12 cm, 16.5 mm |
| merged 34acd56 | -0.636 / 0.96 / 0.010 / 0.014 / -0.50 | -0.642 / 1.30 / 0.016 / 0.016 / -0.23, 1.80 | -0.641 / 1.12 / 0.012 / 0.016 / -0.38, 1.94 cm |

Tilt and heading are in degrees; cloth y is in metres.

- **The tilt is real relative to ARKit's gravity.**
  - From the stand position the balls need 1.24-1.46 deg. With 1 cm of
    placement noise per coordinate the fit's uncertainty is ±0.15 deg.
  - A level plane fits the balls at 2.9-3.2 cm, against 1.8 cm with the tilt
    free.
  - So the camera-relative cloth plane tilts about 1.3 deg against ARKit's
    gravity. Either the table really is out of level, or ARKit's attitude is
    off by that much. This data cannot tell the two apart. Either way, a lock
    that forces level is worse (table in section 2).
  - The pocket fit finds about 0.9 deg. It underestimates mainly the
    cross-table slope: 0.008-0.010 against 0.016-0.018, about 0.45 deg.
- **Height.** Within each lock the ball, joint and app cloth heights agree to
  4-14 mm.
- **Heading.** The ball fit's heading differs from the app's by +0.3 to +1.0
  deg in every stand lock.
- **The pockets and balls do not fit one plane.** A joint fit leaves the
  pockets 12-25 mm off the ball-derived table, and the balls 1.9-2.5 cm off
  the grid. None of the pocket-model offsets in section 2 closes that gap.

## 4. Table size

**This data cannot measure the size.**

- **The grid cannot.** Every spot is a fraction of L. Re-scoring at 2.235 m
  and at 2.337 m gives 3.87 and 3.96 cm, the same within noise.
- **The pockets cannot.** A different size gives the same fit at a different
  cloth height (a homothety about the camera foot). That is why the four
  alternating-model locks moved the cloth by 2-3 cm and kept a 3.5-4.4 mm fit.
- **The ball images cannot, at the needed precision.**
  - 88 x 44 in and 92 x 46 in differ by 4.5 % in scale, so the ball image
    size would have to be known to well under 4.5 %.
  - One pixel of box size is 1.4 % of a near ball's diameter (70 px) and 3 %
    of a far ball's (34 px). Box size errors here are several pixels: on this
    frame the boxes are about 20 % smaller than the disc. My own disc
    measurements are biased by JPEG halo, 0.96-1.28 times the predicted
    diameter.
  - The app's two ball-size estimates disagree with each other: "balls say
    2.12 ± 0.09 m long" and "image says 1.341 ± 0.076 m wide", which implies
    2.68 m long.
  - The honest range from ball size is 2.1-2.7 m. It cannot pick between the
    two candidates.

**`clothFromBalls` has an error bar of at least ±30 mm.**

- At the far rows 1 px of box diameter is 3 % of range, about 18 mm of height.
- Its -0.585/-0.589 against the pockets' -0.620 is a 5 % range bias, which
  2-3 px of box size explains.
- Using it as the cloth height costs 11 cm rms (section 2).
- This matches the 2026-09-10 finding in 09-SESSION-STATE.md: cloth height
  from ball size is systematically wrong, so the pocket fit must set it.

**What would settle it.** A tape-measured cushion-nose length, or the diamond
spacing (11.0 in or 11.5 in), then a re-lock at that size.

## 5. Fix

**No pocket-lock change tested here reaches 2.0 cm, so none is committed.**

| Candidate fix | Best raw (cm) | Limit |
|---|---|---|
| Balls-only plane fit with known spots | 1.74-1.86 | needs balls on known spots, which a player never has |
| Pocket lock with the balls' slopes (tilt from elsewhere) | 2.6-4.3 | |
| Joint lock with free pocket-model offsets | 1.9-2.5 | needs known spots |
| Lock-time yaw tweak, per lock | 2.87 at best | the yaw is unknown at lock time |

What the data does support:

1. **Do not force the plane level, and do not trust `clothFromBalls`.** Both
   make every lock worse.
2. **The largest error is the pocket lock's own noise.** It is a shift and a
   rotation that change between locks, the same size as the leave-one-out
   errors the app already reports (18-27 mm). Reducing it needs more
   independent evidence of the table's position and heading, for example:
   - snapping and averaging each pocket over several frames;
   - adding the long cushion-nose lines (`PocketSnap.sideLines` already finds
     them) as constraints on the fit.

   Neither can be tested offline: the snapped pixels and the nose lines of
   these locks were not saved. A next lock should record them in
   `/state.json`.
3. **A higher camera mount reduces every term above.** At 10.7 deg above the
   far row, 1 px is about 9 mm along the table.

## Not verified

- Clean pipeline boxes. The rebuild uses the rays the pipeline must have used,
  recovered from its outputs. It does not re-run the detector on the clean
  buffer.
- Pocket residual patterns. The pocket rays are rebuilt from the fitted lock,
  so the real 4.3 mm residual pattern is lost.
- Whether the table is level. needs-device-run: a spirit level on the slate
  would separate a real table tilt from an ARKit attitude bias.
- The table size. needs-device-run: tape-measure the cushion-nose length.
