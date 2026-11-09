# Device checklist — shot advisor (final phase, needs the physical iPhone)

Written 2026-11-09 for the final phase of `docs/roadmap/12-GOAL-SIM-FIRST.md`.
Everything above this line in that brief was verified in simulation and by
package tests. Nothing below has been run. Each item stays `needs-device-run`
until a dated run of this checklist is committed next to this file (CLAUDE.md
hard rule 4).

## What simulation already covers (do not repeat at the table)

- Planner correctness against the solver, lane and ordering properties, speed
  budget: `swift test --package-path Packages/CoachKit` (and `-c release`).
- HUD layout on iPhone SE, iPhone 17 Pro and iPad, light/dark, large type:
  `Scripts/sim-matrix.sh`, evidence in `docs/validation/sim-hud/`.
- Advisor card, cycle button, mini-map and "No clean shot" capsule driven by a
  synthetic table: `-seedTable open|blocked|rack` launch argument or
  `GET /cmd?action=seed&layout=...` on the debug mirror (Simulator only).

## Setup

1. Build and install a Debug build on the phone (`Scripts/bootstrap.sh`, run
   from Xcode, team `8VQNRK6J32`). Debug seeds are compiled out on device.
2. Put the phone on a stand or tripod 0.6 to 1.2 m above the table, looking at
   the whole playing field. 8 ft or 9 ft table, a few object balls, one cue
   ball.
3. Turn the debug mirror on (antenna button) and note the URL. Mirror
   state is at `http://<phone-ip>:8787/state.json`.
4. Calibrate: tap the four cushion-nose corners, lock. Record the measured size
   shown by the mirror key `sizeVsStandard`.

For each item below, write the result in a dated copy of this file
(`docs/validation/YYYY-MM-DD-shot-advisor-device-run.md`): pass or fail, the
build SHA, and the evidence (mirror JSON excerpt, screenshot, or video file
name kept outside the repo).

## 1. RealityKit overlay on the real table

Pass when all hold, with the advisor on and a cue ball detected:

- [ ] The neon magenta aim line starts at the cue ball and ends at the ghost
      ball; the object line runs from the target ball to the pocket.
- [ ] The ghost ball ring sits where the cue ball would be at contact (visually
      touching the target ball, on the cloth, not floating).
- [ ] The target ring and the pocket disc are on the right ball and pocket
      (compare with the mini-map and the card text).
- [ ] Overlay error against the real cloth is under about 2 cm at the ghost
      ball. Measure with a ruler or a marked coin. Record the number.
- [ ] Walk 1 m around the table: lines stay glued to the cloth (anchor, not
      world drift).
- [ ] Relocalization: force-quit and relaunch. The table restores within 15 s
      (`relocalizationSeconds` in `state.json`) and the overlay is rotated
      correctly, not about the table center (the 2026-07-23 bug).
- [ ] Cycle shots with the card button and with
      `GET /cmd?action=nextShot`. The line, ghost ring and card change
      together, and `advisedShot` in `state.json` matches the card.
- [ ] Turn the advisor off with the bulb. The magenta layer disappears; the
      normal aim guides stay.

## 2. Core ML `.cpuAndNeuralEngine` behind a crash-safe probe

The shipped model is pinned `.cpuOnly` because `.all` (GPU/MPSGraph) crashes
("MLIR pass manager failed", see 09-SESSION-STATE). Research found the earlier
test used `.all`, never `.cpuAndNeuralEngine`.

- [ ] Add the probe first (one launch argument, runs inference once in a child
      task and records success or failure before enabling the unit for live
      tracking). Do not flip the default without it.
- [ ] Run `.cpuAndNeuralEngine`: no crash over 5 minutes of live tracking.
- [ ] Compare boxes with `.cpuOnly` on the same still through
      `Tools/DetectionEval --compute cpu` against the device result: same balls,
      confidence within 0.05.
- [ ] Record frame rate (mirror `frameDiag`) and thermal state. Keep `.cpuOnly`
      as default unless ANE is both stable and clearly faster.

## 3. BallTracker phantom-track fix

Known bug: a phantom track lingers about 3.5 s at a shot's origin after the ball
leaves. Fix by identity handoff, not by empty-neighborhood retirement (that
breaks occlusion handling). Write a replay test first (`Packages/PerceptionKit`).

- [ ] Shoot 5 shots. After each, count the seconds until `ballCount` in
      `state.json` equals the real number of balls on the table. Target: under
      1 s, never a phantom at the origin that survives 2 s.
- [ ] The advisor does not recommend a shot through the phantom (no option whose
      lane is blocked by a ball that is not there).

## 4. Real-shot accuracy and jaw-constant tuning

`ShotPlanner` defaults are 42 degrees (corner) and 29 degrees (side). In the
solver a side pocket accepts up to 79 degrees because the solver models a pocket
as an ideal capture circle (JawConeSweepTests, 9 ft, 4 m/s). Real jaws are
tighter, so the side value must come from the table.

- [ ] For each of corner and side pockets, shoot at least 15 shots at increasing
      angle off the pocket axis from about 0.6 m. Log angle and made/missed.
- [ ] Set each acceptance angle where the make rate drops below about 50 percent,
      minus a 3 degree margin. Change the two defaults in `ShotPlanner.Config`
      and update the pinned values in `ShotPlannerTests` and `JawConeSweepTests`
      in the same change, with the shot log in the doc.
- [ ] Shot-advisor accuracy: take the advised shot 20 times at medium
      difficulty. Record the make rate by rating (easy, medium, hard). The
      ranking should be monotone (easy makes more than medium makes more than
      hard). If not, retune `ShotPlanner.score` weights.
- [ ] Planner speed on device: not a concern (0.03 ms on the Mac for 16 balls),
      but confirm no frame hitch while the advisor is on (`frameDiag`).

## 5. Detection on real play (carry-over from simulation)

Simulation with video clips found failures that the table must confirm or
refute; see `docs/validation/2026-11-09-video-replay-findings.md` if present.

- [ ] Cue ball identified correctly with a dotted or "measle" practice ball
      (tap-to-designate still works).
- [ ] Balls on black cloth are tracked at the live cadence.

## Stop rule

If the overlay is wrong by more than 5 cm, or the app crashes during item 2,
stop, record the build SHA and the mirror `state.json` at the failure, and file
it in `09-SESSION-STATE.md` instead of tuning around it.
