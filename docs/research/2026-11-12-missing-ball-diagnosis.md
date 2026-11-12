# Missing far-centre ball: diagnosis (2026-11-12)

Read-only investigation on `claude/grid-truth` (base `564f8b2`). Evidence: `state2/3/final.json`,
`sess.log`, `frame2.jpg`, `ui_final.jpg` from the grid run. No device was contacted.

## Verdict

One ball never became a track. It is the dark-blue ball at the far-row centre, about
**table (0.87, 0.03) m**. The cause is almost certainly **upstream of the tracker**. The detector
either never emits it, or emits it below the pipeline's 0.35 confidence floor
(`PerceptionPipeline.swift:330`). Nothing in the files proves which. Tracker, gate and NMS
explanations are each contradicted by data we hold.

## Where the ball is

Count in `ui_final.jpg`: 16 balls (15 object + cue). Tracked: 15 including the cue (`ballCount 15`).

The tracked balls form a 5-row by 3-column grid. Table x runs along the long axis, and the near
row is at -0.85 (orange, id 0). Table y runs across it.

| row (x) | left y~+0.33 | centre y~+0.03 | right y~-0.26 |
|---|---|---|---|
| far, 0.87 | id14 yellow (0.86, 0.35) | **MISSING** | id6 red (0.87, -0.24) |
| 0.55 | id10 (0.54, 0.34) | id7 orange (0.57, 0.04) | id12 (0.60, -0.25) |
| -0.03 | id9 maroon (-0.02, 0.33) | id1 eight (-0.03, 0.04) | id8 yellow (0.02, -0.27) |
| -0.56 | id3 blue (-0.57, 0.33) | id2 red (-0.56, 0.03) | id4 (-0.55, -0.27) |
| -0.85 | id0 orange (-0.85, 0.32) | id5 green (-0.83, 0.03) | id11 (-0.82, -0.27) |

Cue ball is at (-0.27, 0.04). The missing centre is **(0.87 ± 0.02, 0.03 ± 0.02) m**.
- That is 0.30 m from the far cushion nose (half-length 1.17), and 2.04 m from the near nose.
  The brief's "0.88 m" is the distance from table centre.
- It is 0.30 m from the orange ball, 0.32 m from id14 and 0.27 m from id6.
- Cross-check: world z is about -3.14, the same as id6's `pose.ballsWorld` z of -3.14.
- The "30 px above the orange" in the brief is perspective foreshortening, not 3D proximity.

## Ranked hypotheses

1. **Detector emits it below the floor, or not at all (e + floor).** Most likely.
   - Floor: `PerceptionKit.swift:80` (0.35), applied at `PerceptionPipeline.swift:330` before
     projection. A dropped detection increments no counter.
   - Model: the bundled NMS pipeline has a baked-in confidence threshold of 0.25 and IoU of 0.45
     (`BallDetector.mlpackage/.../model.mlmodel` metadata strings). So the floor band is 0.25-0.35.
   - Size: the far-row ball is about 32 px wide in the 2160-wide frame. With the stretch-to-640
     scale (`CoreMLDetectionProvider.swift:96`) that is about 9.5 x 12.6 px in the model input.
     It is dark blue on black cloth.
   - The far row is the weakest we can see: id14 has confidence 0.52 and 11 looks against 14
     for the rest. The lowest overall are 0.46 and 0.48.
   - Evidence it is systematic, not flaky:
     - Three dumps, two builds, all show the same 15 balls.
     - The final run is ~589 s (`aimSourceRunSeconds`) at about 2.3 Hz.
     - Flicker would confirm within that time. At 10 % per-tick detection, a track confirms in
       roughly 280 ticks (~2 min). So the per-tick rate is closer to 0.
   - Confirms with: new `belowFloor` and `maxSubFloorConf` fields (see below), plus `detections=` minus stick minus `projected` greater than 0.

2. **Detector labels it `cue` (stick).** Plausible, cheap to test.
   - `Providers.swift:84` drops any `cue` label.
   - The shipped model is known to confuse classes (dotted cue balls).
   - `PerceptionPipeline.swift:329` drops it silently.
   - Confirms with: a `stickDetections` count above 1 in the log. Today `rawDetections` is
     sorted and cut to 12 (`:432`), so a stick below the top 12 is invisible.

3. **Raycast returns nil.** Unlikely.
   - `PerceptionPipeline.swift:337-340` drops silently. Ids 6 and 14, at the same depth, project
     fine, so the ray geometry is not the issue.
   - Confirms with: a `noRay` counter.

4. **Playing-surface gate rejects it (c).** Ruled out.
   - `PlayingSurfaceGate.swift:90-91` rejects only when |x| > 1.14 + 0.045 = 1.186. The ball is
     at 0.87, so calibration would have to be off by 0.3 m.
   - Same-row neighbours pass. The `rejected` counter is already logged as `offTable=K`.

5. **NMS or IoU merge (a).** Very unlikely.
   - Model IoU is 0.45. The two boxes are tangent: centres 30 px apart, ball ~32 px.
   - Even with 40 px boxes, IoU is about 0.14. A merge needs ~79 px boxes, 2.5x the ball.
   - There is no app-side NMS: `CoreMLDetectionProvider.swift:100-112` passes Vision results straight through.

6. **Tracker association, merge, or birth rules (b).** Ruled out.
   - Gate is 8 cm (`BallTracker.swift:277`). Duplicate distance is 4.6 cm (`:242`, `:394`).
   - The nearest neighbour is 0.27-0.32 m away, so nothing can merge with it.

7. **Tentative promotion (d).** Not the persistent cause.
   - `appearanceFrames` is 3 (`BallTracker.swift:433`). At 2 Hz (`SessionModel.swift:525`) the
     strike grace is 0.75 s (`BallTracker.swift:362-373`), so a flickering unconfirmed track dies after ~2 misses.
   - That slows confirmation, but over ~1000 ticks anything detected above a few percent confirms.
   - Ids 0-14 are contiguous in all three dumps (the id is the tracker's own `Ball.id`,
     `SessionModel+MirrorState.swift:222`), so no earlier-spawned track was lost. The blue ball
     either never spawned or spawned after id 14. This supports "never emitted", but cannot
     exclude a late one.

## What cannot be established from the files

- `rawDetections` is the top 12 only (`PerceptionPipeline.swift:432`). The brief's 17-19 per frame cannot be seen there.
- `sess.log` carries only `session`-category lines. No `pipeline` `detections=N projected=M` lines
  are in it, and they are printed only on frame 1 and every 40th frame (`:403`).
- Arithmetic: 16 balls plus 1 stick is 17 detections. 18-19 means 1-2 extras (duplicates or
  false positives), so the blue ball may well be among them, below 0.35 or labelled `cue`.
  Hypotheses 1 and 2 stay open.

## Smallest instrumentation (numbers only)

All inside `PerceptionPipeline.process` (`:324-352`). Count in the existing `compactMap`, do not change behaviour.

1. Add counters: `stickCount` (`:329`), `belowFloor` (`:330`), `noRay` (`:337`).
   Track `maxSubFloorConf` as the highest confidence among the `belowFloor` detections.
2. Extend the log summary (`:405`) with `stick=… belowFloor=… maxSubFloorConf=… noRay=… rawMin=…`.
   Also log on every frame where `belowFloor > 0` or `stick > 1`, throttled to 1 in 10.
3. Extend `SurfaceGateCounts` (`:444`) with the same fields, so /state.json can carry them.
   Add to `/state.json` `detection`: `rawCount`, `stick`, `belowFloor`, `maxSubFloorConf`,
   `noRay`, `projected`, `rejected`.
4. Replace the 12-label cap (`:432`) with `rawLabelsAll`: confidence (2 dp) and table (x, y)
   rounded to cm, for every raw detection, ordered by confidence. Numbers only. This
   directly lists any detection near (0.87, 0.03) with its confidence.
5. Add `nextTrackID` and `tentativeCount` from the tracker to /state.json.
   `nextTrackID` should equal 15 after a clean run; more means spawned-and-lost tracks.

Reading the result on one run:

| observation | meaning |
|---|---|
| `rawLabelsAll` has an entry near (0.87, 0.03) with conf in 0.25-0.35 | hypothesis 1 |
| same entry labelled `cue` | hypothesis 2 |
| entry present, above floor, `noRay` greater than 0 | hypothesis 3 |
| no entry near (0.87, 0.03) at all | model or size (1: model never emits) |

## Smallest fix, for the most likely cause

Only after the instrumentation confirms a sub-floor detection.

- Lower `PerceptionConfig.confidenceFloor` (`PerceptionKit.swift:80`) from 0.35 to 0.25, the
  model's own floor. Spurious detections are filtered by the projection gate and by 3-look
  confirmation. Alternatively keep 0.35 near the camera and use 0.25 only where the projected
  ball is farther than a set range.
- If the entry does not exist at all, the model never emits it. Then lower the model threshold at
  runtime through `VNCoreMLModel.featureProvider` with `confidenceThreshold` and `iouThreshold`
  (the model exposes both). That is a `CoreMLDetectionProvider.swift:74` change, not a retrain.
  Tiling the far half at higher resolution is the next step and is not small.

Test sketch, in `PerceptionPipelineTests` using `SyntheticDetectionProvider` or the local
`FlakyDetector` pattern at `PerceptionPipelineTests.swift:204`:
- Scene of 16 balls on the grid above, with the far-centre one at confidence 0.30.
- With floor 0.35, after 5 frames expect 15 confirmed balls. That documents the loss.
- With floor 0.25, expect 16.
- Add a case: a lone 0.28 detection that appears in only 1 of 5 frames stays unconfirmed.

## Not verified

Nothing here has been run on the device. The ranking is analytic from the files above. The
instrumentation is what turns it into a result.
