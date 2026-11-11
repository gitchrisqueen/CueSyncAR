# 2026-11-11 - Calibration accuracy and camera-pose drift on a parked device

Status: first fix implemented and measured on the real iPad (branch
`claude/calibration-drift`). This note holds the research, the options, the
chosen approach, the device numbers and the ranked next steps.

Device: iPad 9th generation, landscape, on a tripod at the head rail of an 8 ft
class table with black cloth, four stationary balls and a cue lying on the cloth.
Driven only through the debug mirror. Captures and JSONL logs are in
`~/CueSyncRuns/drift/` (not committed).

## 1. Findings

### 1.1 The drift is the camera-pose estimate, not the table or the anchor

Evidence from the 2026-11-10 run (`docs/validation/2026-11-10-ipad-remote-run.md`):
ball table coordinates crept up to 30-40 cm in ten minutes while the world-space
calibration corners did not change and the ball-to-ball distances stayed
constant. `anchorDriftMm` stayed null.

Two new measurements on 2026-11-11 confirm it and size it.

| run | build | what | result |
|---|---|---|---|
| A, baseline | `8c18c15` | fresh lock, 4 balls stationary, 15.2 min, ball table coords every 10 s | common-mode shift of all four balls: dx -5.8 cm, dy -10.2 cm after 15 min (about 11.7 cm); per-ball max excursion 10.2-14.2 cm |
| B, with fix | `914ea9e` | same balls, same picks, parked hold on | see section 5 |

The shift is **common mode**: every ball moved by the same vector at the same
time (for example at 9 min all four balls moved +6 cm in y between two samples
and back). Detector jitter is per ball; a pose error moves everything. Run B logs
ARKit's raw camera pose (`/state.json` `pose.cameraRaw`): on a camera bolted to a
tripod ARKit's estimated camera position moved several centimetres within the
first two minutes (y +44 mm by 1.8 min), while the IMU read 0.001-0.003 rad/s and
0.001-0.003 g (`pose.parkedHold.rotRate`, `userAccel`), that is, no motion.
`trackingState` stayed `normal` and `worldMapping` stayed `limited` the whole
time, so ARKit gave no signal that it was wrong.

Why ARKit does this: world tracking is visual-inertial odometry; the inertial
side integrates small errors and the visual side corrects them from tracked
features and parallax [1][2]. A parked device produces no parallax, so depth and
translation along the view axis are weakly observable, and this scene is the
hard case on every axis that the literature names: low light, a large dark
low-texture surface (black cloth), and content 2-3 m away. Measured hologram
drift on phones grows at low light (brightness estimate under 0.3), in regions
with low edge strength and sparse feature points, and with distance [3]. ARKit's
`worldMappingStatus` stuck at `limited` [4] is consistent with a map that never
had enough viewpoints to constrain it. Tracking state reasons [5] only report
initialising, excessive motion, insufficient features and relocalising; slow drift
under `normal` is not reported, so it must be detected by the app.

### 1.2 Calibration accuracy

- Hand-picked pocket pixels fit 87-97 mm rms; the pattern search in
  `Scripts/calibrate-pockets.py` gets 24-28 mm rms (today: 26, 24 mm rms, worst
  pocket 33-38 mm). With the cloth height forced after a relaunch: 34-70 mm rms.
- The height solve refuses above 30 mm rms, and today's first attempt sat on the
  edge at 31 mm (refused) then 27.5 mm (locked) with identical picks, so the lock
  depends on a few millimetres of pose noise between attempts.
- Four pockets fix the shape but not the scale: 7, 8 and 9 ft tables are all
  2:1, so the rays fit each one at its own depth.

### 1.3 Table size from the balls (new, independent)

A ball is a ruler of known size (57.15 mm): its apparent size gives its range
without any table assumption. For one camera position the cloth depth each table
size implies is proportional to the size (similar triangles), so

    impliedLength = length(S) * ballDepth / depth(S)

`TableSpace.TableSizeFromBalls` does this. With today's numbers (camera at y≈0,
taps-solved cloth y = -0.553 for 8 ft, balls -0.533 with 11 mm spread):
implied length 2.26 ± 0.05 m: **8 ft** (7 ft = 1.98 m, 9 ft = 2.54 m), decisive
at 2 sigma by a small margin. The device reports it as `pose.sizeFromBalls`.
The 2 cm gap between the two cloth heights is the ball estimator's known bias
(detector boxes sit slightly inside the ball silhouette) and is the main error
term; it does not change the verdict.

## 2. Options

| # | option | expected gain | cost | risk |
|---|---|---|---|---|
| 1 | **Parked pose hold** (chosen): when the IMU says the device is still, hold the camera at the pose it had when stillness began; ARKit's drift goes into a correction applied at the one ARKit boundary (`ARSessionCoordinator`: frames, rays, raycasts, projection, anchor placement, overlay root) | removes all pose drift while parked, for balls AND overlay, with no change to the pipeline, solver or overlay layout | small: one pure type + one box + about 40 lines at the boundary | a real bump while "still" below the IMU limits would be held out (limits are 10x the tripod noise); anchor following must be off while held |
| 2 | Image-space homography for ball positions (pixel -> table from the pocket sightings) | same immunity for ball positions; no pose at all | medium: the pipeline unprojects through intrinsics + pose today (`PlaneGeometryRaycaster`); a homography raycaster is a new `PlaneRaycasting` | the RealityKit overlay still uses the drifting pose, so overlay and balls would disagree unless the overlay is also redrawn in 2D; ball centre vs foot point needs the height above the plane |
| 3 | Periodic re-fit from pockets/rails seen in the image | corrects drift and residual calibration error | large: needs automatic pocket detection on black cloth (no detector class for pockets today) | wrong re-fits move a good table |
| 4 | ARKit configuration (`isAutoFocusEnabled = false`, no `environmentTexturing`, no plane detection after lock, higher-res video format) | may slow the drift | small to try | does not remove the cause (no parallax); focus hunting and texturing are not the observed failure; each change needs a 15 min device run |
| 5 | Drift detection plus a visible "re-calibrating" state | honesty; no accuracy gain | small | user friction |
| 6 | Hybrid: 1 now, 2 as the check on 1, 3 later | best end state | staged | - |

Option 1 was chosen because it fixes the measured failure at its source, keeps
every downstream consumer (pipeline, aim, solver, overlay, mirror, recorder
projection) in one consistent world, needs no new perception, and is cheap to
switch off (`/cmd?action=parkedHold&v=0`). The drift detector (option 5) comes
free with it: `pose.parkedHold.driftMm/driftDeg` is ARKit's drift since the hold
began, and `correctionMm` is the total taken out. The homography (option 2) is
implemented as a pure, tested type (`TableSpace.Homography2D`) for the next step.

## 3. What was implemented

| file | what |
|---|---|
| `Packages/TableSpace/Sources/TableSpace/ParkedPoseHold.swift` | `StillnessDetector` (IMU limits 0.03 rad/s, 0.03 g, 1.5 s settle), `ParkedPoseHold` (correction model), `PoseDelta` |
| `Packages/TableSpace/Sources/TableSpace/Homography2D.swift` | normalised DLT homography from 4+ points, pocket helper, residual |
| `Packages/TableSpace/Sources/TableSpace/TableSizeFromBalls.swift` | ball-ruler table-size classifier |
| `Packages/ARExperience/Sources/ARExperience/ParkedPoseCorrection.swift` | `ParkedHoldBox`: CoreMotion at 30 Hz, lock-protected hold, readings |
| `Packages/ARExperience/Sources/ARExperience/ARSessionCoordinator.swift`, `ProjectionSnapshot.swift` | correction applied at the boundary; `OverlayRenderer(worldCorrected:)` hangs content off an entity whose world transform is the correction |
| `App/Sources/RootView.swift` | arm while locked and `deviceParked`; no anchor following while armed; renderer rebuilt when the mode changes |
| `App/Sources/SessionModel+DriftDiagnostics.swift` | `/state.json` `pose` block; `parkedHold` mirror switch; size check after a pocket lock |
| tests | `CalibrationDriftTests.swift` (TableSpace, 18 tests), `ParkedHoldBoxTests.swift` (ARExperience, 3 tests) |

`pose` block fields: `cameraRaw` (x, y, z, yaw, pitch of ARKit's camera),
`trackingState`, `worldMapping`, `parkedHold` (enabled, armed, holding, still,
imuLive, rotRate, userAccel, driftMm, driftDeg, correctionMm, correctionDeg),
`tableAnchorRaw`, `ballsWorld` (each ball in the corrected and raw ARKit world),
`sizeFromBalls`.

## 4. Acceptance metrics

| metric | target |
|---|---|
| stationary-ball drift, parked, 15 min | <= 1 cm (p95 excursion from the first-minute mean) |
| overlay-to-ball offset after 15 min | <= 1.5 cm (one ring width), checked on `/frame.jpg` against t0 |
| calibration fit | <= 10 mm rms |
| table size | identified correctly, decisive |

## 5. Results on the real iPad

Same tripod, same four stationary balls, same pocket picks
(`TL 89:602, TR 386:334, BR 702:333, BL 972:594`), fresh lock each time, ball
table coordinates sampled from `/state.json` every 10 s; the first 60 s after
the lock are excluded and the reference is the mean of the next three samples.
The mirror rounds ball coordinates to 1 cm.

| metric | before (`8c18c15`, run A) | after (`914ea9e`, run B, hold on) | target | verdict |
|---|---|---|---|---|
| common-mode ball shift after 15 min | 11.7 cm (dx -5.8, dy -10.2) | 0.2 cm (max 0.4 cm) | <= 1 cm | met |
| per-ball max excursion over 15 min | 10.2-14.2 cm | 0.7-1.0 cm (one mirror quantum) | <= 1 cm | met |
| ARKit raw camera drift over the same period (`pose.parkedHold.driftMm/driftDeg`) | not measured (no `pose` block) | up to 72 mm (mostly camera height) and 1.4 degrees yaw, cancelled by the hold | - | the cause, measured |
| overlay vs t0, by eye on `/frame.jpg` 23 min after lock | rings about 5 cm off the balls after 10 min (2026-11-10 run) | ball rings within about 5 display px (about 1 cm) of their t0 position; right side-pocket disc about 10 px (1.5-2 cm) | <= 1.5 cm | met for balls; pocket disc borderline, by eye only |
| calibration fit | 24-26 mm rms (4 pockets, pattern search) | unchanged: 24 mm rms; 6 pockets with eyeballed side picks 49 mm rms | <= 10 mm rms | **not met**, next step 1 |
| table size | unverified | `pose.sizeFromBalls` on `914ea9e`: "2.24-2.29 +/- 0.06-0.07 m: 8 ft (not decisive)"; on `02270e6` with the deferred check (more ball samples): "balls say 2.25 +/- 0.03 m long: 8 ft", decisive | identified, decisive | met (8 ft) |

Why the camera height matters most: from the head rail the camera looks down at
about 13 degrees, so a 7 cm error in camera height moves the point where a ball's
foot ray meets the cloth by tens of centimetres along the long axis. That is the
2026-11-10 symptom (cue ball x -0.23 -> +0.07 m). The yaw wobble of about 1.4
degrees moves balls about 6 cm sideways at 2.5 m, which is the dy wobble in run A.

Notes from the run:

- IMU on the tripod: 0.0007-0.0035 rad/s and 0.001-0.003 g, against limits of
  0.03; `still` stayed true for the whole 16 minutes and the hold never released.
- `trackingState` stayed `normal` and `worldMapping` stayed `limited` throughout.
- First install crashed the app as soon as a table locked: `JSONSerialization`
  aborts on a non-JSON value (`BallID`) in the new `ballsWorld` list. Found from the
  device crash report (`devicectl device info files --domain-type systemCrashLogs`)
  and fixed in `914ea9e`; the mirror looked "hung" because the process was
  restarting.
- A re-lock while the hold is running keeps the correction (the new calibration is
  measured in the corrected world), which is consistent; after that re-lock the
  hold showed a 2.65 degree correction in force.

## 6. What would make me change course

- Drift reappears with the hold on while `holding` is true: the correction is not
  reaching a consumer; find it with `ballsWorld` (corrected vs raw).
- `still` drops to false on a tripod (a fan, a table knock): raise the limits or
  hold through short blips; if blips are frequent, freeze is still safe because
  the correction persists across them.
- A user re-positions the tripod: the hold releases on motion and ARKit tracks the
  move; if the overlay is off after a move, re-lock (or step 3 below).
- ARKit relocalises with a large jump while parked: the hold absorbs it (camera
  still); if it does so wrongly, gate on `trackingState`.

## 7. Ranked next steps

1. **Calibration accuracy to <= 10 mm rms**: sight all six pockets (the side
   pockets are in view from the head rail and add redundancy and a residual), and
   snap each tap to the pocket opening (dark blob in the light rail) before
   solving. `Homography2D` gives a pose-free residual for the six sightings, so a
   bad tap is named before the 3D solve.
2. Use `Homography2D` as the parked-mode check: map the ball foot pixels through
   the pocket homography and compare with the pipeline's table coordinates; a
   disagreement over 1 cm while `holding` is a drift the hold missed.
3. Snap the default table size to `sizeFromBalls` when it is decisive and the
   user has not set one; reduce the ball-estimator bias (box vs silhouette)
   first.
4. ARKit configuration trials (option 4), one change per 15 min run, now that
   the `pose` block can measure them.
5. Session recording: `DeliveredFrameMeta` still records the raw table-anchor
   transform; record the hold correction too so replay matches live.

## Sources

1. Apple, "Understanding ARKit Tracking and Detection", WWDC 2018 session 610:
   https://developer.apple.com/videos/play/wwdc2018/610
2. 6D.ai, "Why is ARKit better than the alternatives?":
   https://medium.com/6d-ai/why-is-arkit-better-than-the-alternatives-af8871889d6a
3. "Here To Stay: Measuring Hologram Stability in Markerless Smartphone
   Augmented Reality" (arXiv 2109.14757): https://arxiv.org/pdf/2109.14757
4. Apple, `ARFrame.worldMappingStatus`:
   https://developer.apple.com/documentation/arkit/arframe/worldmappingstatus-swift.property
5. Apple, `ARCamera.TrackingState`:
   https://developer.apple.com/documentation/arkit/arcamera/trackingstate
6. "An Empirical Evaluation of Four Off-the-Shelf Proprietary Visual-Inertial
   Odometry Systems" (arXiv 2207.06780): https://arxiv.org/pdf/2207.06780
7. Hartley and Zisserman, "Multiple View Geometry in Computer Vision", ch. 4
   (normalised DLT for homographies): https://www.robots.ox.ac.uk/~vgg/hzbook/
