# Goal 14 - polished, trustworthy shot assist (iPad, remote)

Replaces goal 13 (done: iPad calibrated, recorded, replayed). Same rules: the
owner is NOT at the iPad (tripod, other room). Drive it through the debug
mirror (`http://<ipad-host>:8787`, `/state.json`, `/frame.jpg`, `/ui.jpg`,
`/logs`, `/cmd`). Install with `Scripts/device-push.sh --device "<iPad name>"`.
This repo is public: the host and the device name stay out of it. They are in
the session memory `arcade-pass-branch-map` and in `~/.cuesync/mirrors`.
No PRs, no media committed, never touch `Packages/CueSyncCore` (contract-change
PR only), `SessionModel.swift` stays at 1000 lines (new code in extensions).
Read `CLAUDE.md`, `.claude/rules/dev-environments.md`, memory `arcade-pass-branch-map`.

## Ground truth now on the table
15 object balls on the diamond-line intersections (rows x = k*L/8 for k in
3,2,0,-2,-3; columns y = j*L/8 for j in 1,0,-1; rows k=+-1 empty) plus a cue
ball. `Scripts/grid-truth.py` (branch `claude/grid-harness`) scores any lock:
rms and max error in cm, free-fit spacing. Every accuracy claim must quote it.

## Measured starting point (build 564f8b2, 2026-11-11/12)
- Pocket fit 3-5 mm rms (six pockets), but ball positions are 3.6-3.8 cm rms
  (max 6.8) against the grid with the 2.34 x 1.17 m model, 2.8-2.9 cm (max 4.9)
  with a custom 2.235 x 1.118 m (88 x 44 in) table. Spacing along the length
  fits 2.24-2.26 m. True table size is UNCONFIRMED: owner to measure.
- Failure seen live: after the view changed, the app kept a stale lock and
  showed "Tracking 1 balls" with 15 of 17 detections `offTable`, no warning.
- Five balls named `eight`; 14 of 15 object balls tracked (one missing).
- Camera was out of focus for a while (balls blurred).

## Measured after the merge (2026-11-12, iPad still on 564f8b2)
- `Scripts/grid-truth.py <ipad-host>`: n=14, rms 3.9 cm, max 5.9 cm, mean shift
  (+2.3, +2.1) cm, free fit x 0.982, y 1.022.
- Error split over four locks on the 2.34 m model (fit of measured vs grid):
  raw 3.7-4.9 cm, after a translation 2.4-3.4, similarity 2.0-2.3, affine
  1.3-1.6, homography 1.1-1.3. So about 1.2 cm is noise (detector jitter plus
  hand placement) and the rest is a smooth map error. The same in every lock:
  x scale 0.956-0.982, shear -0.04 to -0.055. The shift moves about 2 cm from
  lock to lock. Six pockets fit to 3-5 mm, so the pockets and the balls are
  not being mapped by the same plane. Two cloth heights disagree in the app:
  -0.620 m (pocket spans) against -0.589 m (ball sizes).
- The grid test cannot measure table size: diamonds sit at fractions of the
  table, so a wrong size with a matching plane height scores the same.
- Camera is about 0.6 m above the cloth, 10.7 degrees above the far row: 1 cm
  of height error there moves a ball 5.3 cm. A higher mount cuts every error.
- 4 balls named `eight`, constant for 60 s. Track ids stable for 60 s.
- Pipeline 2.3 Hz and 330 ms overlay latency with 15 balls (4.6 Hz with 1).
- With "device is parked" on, `aimSource` is still `devicePose` (3600 s): the
  thin lines and the second ghost ball are an aim drawn from the tripod.
- Live log: `detections=18 projected=14 offTable=1`. The steady `offTable=1`
  is a lit appliance beside the table that the detector calls a ball.
- The missing ball (dark blue, far centre, behind the orange one) is never
  detected: 0 of 148 recorded frames at confidence 0.25 or more. The 0.35
  floor is not the cause. The cue ball's confidence dips to 0.27, so the
  floor does cost cue-ball frames.
- Accuracy floor: with the balls on known spots the best fit is 1.74-1.86 cm
  rms, so "2 cm" is the floor for this camera position, not a margin.

## Tasks (in order; each ends with a grid-truth number or a /ui.jpg still)
1. DONE 2026-11-12: `claude/grid-harness`, `claude/calib-health`,
   `claude/ball-identity-2`, `claude/missing-ball-diagnosis` and
   `claude/ux-rescore` merged at `8bd2dbb`. From clean:
   `Scripts/test-all.sh` exit 0 (11 test runs passed), Release iphoneos
   `** BUILD SUCCEEDED **`, swiftlint 0 serious, 25 Python tests OK.
   Not yet on the iPad.
2. Table size: once the owner confirms the diamond spacing (11.0 in = 88 x 44,
   11.5 in = 92 x 46), add the size via a CueSyncCore contract-change PR
   branch (not merged without the owner) and re-lock; target ball rms <= 2 cm,
   max <= 3.5 cm on the grid. If the owner has not answered, keep the custom
   size path (`calibrateFromPockets v=<L>,<W>`).
3. Remaining error: if rms stays above 2 cm, split it into pose error vs model
   error (lock-to-lock repeatability, near/far bias) and fix the largest.
4. Missing ball and identity: all 15 balls tracked, at most one `eight`,
   colour names stable for 60 s.
5. Design: top gaps from `docs/design/2026-11-12-ux-rescore.md`; each fix proven
   by a before/after `/ui.jpg` stored locally in `~/CueSyncRuns/ui/` (never committed).
6. Motion pass (hero-line cross-fade, corner flash) - code + unit tests; mark
   `needs-device-run` for anything a still cannot show.
7. Feedback and made/missed detection: still `needs-device-run` until the owner
   shoots; record a session when asked and replay it.

8. Parked hold: turning "device is parked" off and on (or any hold re-arm)
   on a locked table must not move the table. Measured 2026-11-12: 3.1 cm rms
   became 12.8 cm with no warning (09-SESSION-STATE has the detail). Either
   keep the lock-time reference across a re-arm while the IMU says the device
   has not moved, or drop the lock and ask for a new one. Add a health signal
   for shifts that leave the balls on the table.

## Done when
Grid-truth rms <= 2 cm, 16/16 balls tracked, one eight, stale-lock banner
verified by moving the view (or simulated), design re-score >= 70/100 by the
independent reviewer, `Scripts/test-all.sh` exit 0 from clean, branch pushed,
`docs/roadmap/09-SESSION-STATE.md` updated, memory updated.
