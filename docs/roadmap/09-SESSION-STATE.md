# 09 — Session State & Handoff

**Purpose:** land the *current working state* in the repo so any fresh agent
(or human) can resume without a prior chat session. Update this file whenever
a work session ends or a major finding lands. Last update: **2026-07-22**,
branch `claude/M3-02-calibration-flow` (all local branches — `main`,
`claude/ar-billiards-2026-roadmap-n1asv8`, this one — point at the same
consolidated commit; push all three from SourceTree, each fast-forwards).

## Where the project stands

Working on device (iPhone 16 Pro "CDQ iPhone", iPad "Christopher's iPad (2)"):

- AR camera feed, calibration flow (tap 4 corners → drag → lock, custom sizes
  allowed with 8% snap to standard), ARWorldMap persistence + relocalization,
  anchor-rooted overlays (drift fix), camera flip, auto box orientation.
- On-device detection: bundled `App/Resources/BallDetector.mlpackage`
  (YOLOv11n fine-tune, mAP50 0.896 — see M2-01 in 06-MILESTONES). **Pinned to
  `.cpuOnly`** in `SessionModel.loadBundledDetector` — GPU/ANE crashes with
  "MPSGraph MLIR pass manager failed" on iOS 26 (see "ANE re-export" below).
- Live loop: pipeline → tracker → TableState → aim (stick-based with
  device-pose fallback) → AnalyticSolver → RealityKit overlays; ShotGuide
  tip-contact coaching card; pocket calling (M6-02); tap-to-designate cue
  ball (for measle/practice balls the detector can't classify).
- Diagnostics (2026-07-22): os.Logger subsystem `com.cuesync.ar` (categories
  `session`, `pipeline`, `mirror`); every tap gives on-screen feedback;
  tracked-ball rings always render during live tracking (cue = white).

## Open bug being chased (top priority)

**Symptom (user report at the table):** tapping a ball to mark it as cue did
nothing, and no trace paths/guides appeared.

**Diagnosis so far (from the first instrumented run):** the detector runs and
the pipeline emits outputs, but **zero ball detections survive the
confidence/projection gate** (`frame #N: detections=8 projected=0
confirmed=0` while the stick quad projects fine). With no tracked balls there
is nothing to tap and no cue ball → `updateAim` correctly produces no
guides. That run was an iPhone pointed at a random room, so rejection may
have been correct; **needs a run on the iPad at the real table.** Knobs to
inspect with the new logs: `PerceptionConfig.confidenceFloor` (0.35 vs
Vision NMS pipeline confidences), `Detection2D.isCueStick` filter,
`PlaneGeometryRaycaster` foot-point projection, and the logged ball table
positions vs reality (worldToTable sanity).

**Watch item:** "ARSession delegate retaining 11–13 ARFrames" warnings
reappeared during the iPhone run (camera kept delivering; count plateaued).
The delegate itself drops/deep-copies correctly — if the count climbs on the
iPad, profile before shipping anything.

## Remote debugging setup (no cable needed)

The iPad sits at the table, out of reach of the Mac. Use the **debug
mirror**: tap the antenna button in the bottom HUD bar → the HUD shows
`Mirror: http://<ipad-ip>:8787` → open that URL in any browser on the same
Wi-Fi. It serves the *rendered* screen (camera + AR overlays, ~1 Hz) plus a
live tracking-state JSON (`/state.json`: balls with table coords, cue/stick
state, calibration, guide, errors). Implementation:
`App/Sources/DebugMirrorServer.swift` (NWListener, LAN-only, off by
default). QuickTime USB mirroring still works when the device is at the Mac.

## ANE re-export (to un-pin from .cpuOnly)

Findings from a sandbox export session (2026-07-22): the deployed export is
spec 6 (iOS15 target) because ultralytics passes no deployment target; that
opset forces fp32↔fp16 boundary casts, the likely MPSGraph-MLIR crash
trigger. **Recipe for the fix candidate** (Linux/macOS, ultralytics + torch
2.7.0 + coremltools 9; torch ≥2.8 breaks the nms=True export):
monkeypatch `coremltools.convert` to inject
`minimum_deployment_target=coremltools.target.iOS16` while running
`YOLO("best.pt").export(format="coreml", nms=True)` — this keeps the NMS
pipeline (outputs `confidence`/`coordinates`, required by
`CoreMLDetectionProvider`'s `VNRecognizedObjectObservation` path) and drops
the boundary-cast ops. Fallback if it still crashes: same with iOS17;
GPU-only fallback: `quantize=32` fp32 variant (ANE is fp16-only). After
swapping the model in, remove the `.cpuOnly` pin and verify boxes on device.
Training artifacts: dataset fork `cqc/pool-ball-agzev-tekpn` (Roboflow);
best.pt regenerable per `docs/model-testing.md` (freeze=10, 640px, ~epoch 19).

## Device-session working notes (for agents driving the Mac remotely)

- Xcode/Terminal are click-only; QuickTime is full-tier. Build = click Run.
- The `.xcodeproj` is generated (XcodeGen) and gitignored, but in remote
  sessions it is **hand-patched** (synthetic IDs `CA11B0A7C0DE...`) because
  Terminal can't be typed into. Added so far: CalibrationOverlayView,
  CalibrationStore, FrontCameraPreviewView, DebugMirrorServer,
  BallDetector.mlpackage (Sources phase). `project.yml` carries the same
  entries, so a real `xcodegen generate` reproduces them.
- git on the mounted repo cannot unlink: move stale `.git/*.lock` (and
  `ORIG_HEAD`) into `_to_delete/` before every git op; `git merge` cannot
  run at all (double index-lock cycle) — create merge commits with
  `commit-tree` + `update-ref` instead. Pushes go through the maintainer's
  SourceTree (network push from the session is blocked).
- `device_stage_files` snapshots can be **stale**; verify against
  `git show HEAD:<path>` / `md5sum` before trusting file reads.

## Next steps (ordered)

1. Run the instrumented build on the iPad at the table; read
   `com.cuesync.ar` logs + debug mirror; fix the ball-observation rejection
   (this closes the designation/guides bug). → then tick M3-06 checklist
   rows as they verify.
2. Swap in the iOS16-target ANE export; un-pin `.cpuOnly`; measure Hz.
3. M2-04 fixture capture tool (debug menu) — capture real-table fixtures;
   M2-05 replay suite over them.
4. M6-06 auto table detection (Vision rectangle pass over cloth mask →
   corner proposal; manual flow stays as fallback) — answers "should the
   table edge be detected".
5. M6-01 practice-modes framework, then M6-03 guided drills
   (08-PRACTICE-MODES.md). M4-02/03/04 polish as parallel work.
6. Dataset rev: add dotted/measle cue-ball images; retrain per
   `docs/model-testing.md`.

## Human-action checklist

- [x] Rotate/revoke pre-M0 Roboflow key (done 2026-07-21; new key in
  untracked `App/Config/Secrets.xcconfig`).
- [ ] Push `main`, `claude/M3-02-calibration-flow`,
  `claude/ar-billiards-2026-roadmap-n1asv8` via SourceTree (all fast-forward).
- [ ] One-time review of the M1-03 golden fixtures (then tick M1-03's
  "human-reviewed" exit criterion in 06-MILESTONES.md).
- [ ] Delete `_to_delete/` at the repo root whenever convenient.
