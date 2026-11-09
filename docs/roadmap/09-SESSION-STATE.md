# 09 — Session State & Handoff

**Purpose:** land the *current working state* in the repo so any fresh agent
(or human) can resume without a prior chat session. Update this file whenever
a work session ends or a major finding lands.

**2026-11-09 — Simulation-first validation of the shot advisor (brief:
`12-GOAL-SIM-FIRST.md`). Integration branch `claude/shot-advisor`. Simulation
only: nothing here is device-verified.** What landed, each re-run on the Mac:

- **A, synthetic table in the Simulator.** `App/Sources/DebugSeed.swift`
  (compiled only for `DEBUG && targetEnvironment(simulator)`; the Release
  iphoneos binary has no seed symbols): launch arg `-seedTable open|blocked|rack`
  or `GET /cmd?action=seed&layout=...` on the mirror (port 8787 is reachable from
  the host). `GET /cmd?action=nextShot` then changes `advisedShot` in
  `/state.json` and the card (3-ball → top-right corner, 7° cut, became 5-ball →
  bottom-right corner, 22° cut). `Scripts/sim-hud.sh` launches and screenshots.
- **D, display quality.** Captured on iPhone 17 Pro, iPhone SE (3rd gen) and
  iPad Pro 13" (simulators `CueSync-iPhone17Pro`, `CueSync-iPhoneSE`,
  `CueSync-iPad`, all iOS 26.3), light/dark, normal and accessibility XXXL type
  (`Scripts/sim-matrix.sh`; evidence in `docs/validation/sim-hud/`). Fixed:
  truncated status capsule, wrapping mirror capsule, bottom bar clipping at
  large type (HUD capped at accessibility1, icon-only model picker), tiny
  mini-map on iPad, and the seed racing the slow detector load on iPad.
  `App/UITests/ShotAdvisorHUDUITests.swift` (XCUITest) asserts
  `shot-advisor-card` and `next-shot-button` are reachable, cycling changes the
  card, and the blocked layout shows "No clean shot". Run:
  `xcodebuild test -project CueSyncAR.xcodeproj -scheme CueSyncAR -destination id=<udid> -only-testing:CueSyncARUITests`.
  The T3 `agent-device snapshot` runner failed to start on this Mac
  ("Runner did not accept connection (xcodebuild exited early)", then daemon
  timeout), so accessibility was verified with XCUITest instead.
- **C, planner hardening** (`Packages/CoachKit`). Seeded property tests replay
  every planned shot through `AnalyticSolver` (4 m/s): 96.2% of 1,804 options
  pot; the rest are explained (43 underpowered, 24 cue ball rests in the object
  lane, 1 target already inside the capture circle, 0 unexplained). This found a
  real bug, now fixed: lanes through a pocket mouth (scratch or wrong pocket).
  Lane clearance, ordering/determinism/permutation and hysteresis properties
  pass. Speed budget: ~0.03 ms per 16-ball plan in release (budget 5 ms).
  **Jaw cones kept at 42° corner and 29° side on purpose.** The solver sweep
  gives corner ≥ 43° and side 79°, but the solver models a pocket as an ideal
  capture circle, so 79° would offer side shots real jaws reject. Table data
  decides (device checklist item 4). Known gap: a shot that sits 0.4 mm
  outside a lane flickers in and out under 2 mm jitter; needs viability
  hysteresis in the planner (not built).
- **E, offscreen overlay.** Works: `Tools/OverlayRender` renders the real
  RealityKit entities with `RealityRenderer` on macOS and composites them over a
  background (`overlay-render --out x.png --layout open|blocked
  [--background y.png]`). Entity building moved to
  `ARExperience/OverlayEntityBuilder.swift`; `OverlayRenderer` calls it
  (the iOS path is unchanged by construction, not seen on a device). 28 new
  geometry cases in `OverlaySuggestionGeometryTests`. Mac quirk: on this Intel +
  AMD Mac the render target read back all zeros until blitted private→managed.
- **G, lint.** The two TableSpace `force_cast` errors are fixed. `SessionModel`
  lost its `file_length` and `line_length` errors (mirror JSON moved to
  `SessionModel+Mirror.swift`). Still open: `type_body_length` on
  `SessionModel` (class body over 600 lines); splitting it is optional Mac work
  (branch `origin/claude/sessionmodel-split` exists).
- **B, video replay.** `Tools/VideoReplay` (macOS; `swift test --package-path
  Tools/VideoReplay` = 16 tests) replays frame folders through the real
  `CoreMLDetectionProvider`, `BallTracker` and `ShotPlanner`, mapping balls to the
  table by a homography from 4 hand-marked cushion corners (video has no ARKit
  intrinsics). Three YouTube Shorts (fixed cameras; URLs and licence note in
  `Tools/VideoReplay/clips/clips.md`; footage stays in `~/CueSyncClips/`, never
  committed). Full list with frame numbers:
  `docs/validation/2026-11-09-video-replay-findings.md`. Headline: the detector's
  cue-ball class is the weak link on this footage. Frames with exactly one cue
  ball: pub 15.0%, speedpool 16.7%, home 0.0% (60 frames each, 2 fps), and the
  planner only runs with one. The cue ball is boxed `color-ball` or missed;
  speedpool frames 55 and 58 draw a shot from a yellow ball boxed `white-ball`;
  the `cue` (stick) class is mostly rail/wall false positives; scoreboard and
  title boxes on speedpool and people/furniture on home are only kept out by the
  on-table gate. Planner labels "top"/"bottom" follow table space and can look
  mirrored on screen. Caveats: no ground-truth labels (frame claims are by
  eye); clips are vertical Shorts from fixed cameras, not a handheld phone, so
  domain shift is part of the result; 7 ft sizes for two clips are estimates.
  Takeaway for the advisor: it depends on a correct cue ball, so tap-to-designate
  (CLAUDE.md) is load-bearing; the device checklist item 5 retests this.
- **Access and process notes.** QuinVPS now has Swift 6.4.2 and swiftlint
  0.65.1, can push, and its git identity must be set per agent (clone default is
  `tester`). `delegate_task` rejects `isolation: "worktree"` for linked
  environments, so QuinVPS agents shared one checkout and ran one at a time.
  `playwright_chrome` MCP still fails to connect (not needed).
- **Gates at this point:** `Scripts/test-all.sh` exit 0 (10 packages);
  `xcodebuild -sdk iphoneos` Debug and Release `BUILD SUCCEEDED`.
- **Still `needs-device-run`:** RealityKit overlay on a real table and
  relocalization, `.cpuAndNeuralEngine` behind a crash-safe probe, BallTracker
  phantom-track fix, real-shot accuracy and jaw tuning. Checklist:
  `docs/validation/device-checklist-shot-advisor.md`.

**2026-11-07 — Shot advisor (sandbox session, NOT device-verified).** New
`CoachKit.ShotPlanner` ranks every (object ball × pocket) shot by ghost-ball
geometry, lane-blocking, pocket-jaw cone and a difficulty heuristic;
cross-checked in tests against `AnalyticSolver` (planned shots pot). Surfaced
as: neon-magenta AR layer (`OverlayLayout.suggestion` + `OverlayRenderer`),
`ShotAdvisorCard` (tap to cycle options), a 2D mini-map, a bulb toggle in the
HUD bar, and mirror state `advisedShot` / commands `nextShot`, `advisor`.
Verified: all package tests green, app compiles for the iphoneos AND
iphonesimulator SDKs, visuals reviewed via `Tools/SceneSnapshot` (macOS
render of the real views). NOT verified: RealityKit rendering on device
(`needs-device-run`), jaw-acceptance constants (42° corner / 29° side are
approximations — tune from table data), and the iOS Simulator (no runtime
installed; Mac data volume has ~12 GB free, runtime is ~10 GB). Public
version: none yet (portfolio candidate: SceneSnapshot + planner, synthetic data).

**Last update: 2026-07-23 (post-loop, shot session), branch
`claude/T1-tier1-verification`.** Chris shot 4 balls through the mirror →
two findings (docs/validation): (1) the on-device detector is BLIND to a
ball at shot speed — every shot is a start→end teleport with zero
mid-flight detections, so predicted-vs-ACTUAL bank *path* capture is gated
on detection speed (T1.3) or lag-speed shots, not tracker tuning; (2)
phantom track lingers ~3.5 s at a shot's origin (BallTracker retires far
duplicates only within gatingDistance) — queued as task, fix via a
replay-test-driven change (identity handoff, NOT empty-neighborhood
retirement — that breaks occlusion robustness; see task). Also RESEARCH
(offline): the T1.3 crash was tested wrong — only `.all` (GPU/MPSGraph)
was tried, never `.cpuAndNeuralEngine` (the documented crash-avoider +
correct camera-app unit); next experiment is a one-line compute-unit flip
behind a crash-safe probe (see ANE section). Earlier: AR overlay
relocalization-rotation bug
FIXED (`c0e3ecf`): `OverlayRenderer` now places entities in true world
space (`setPosition(relativeTo: nil)`) instead of the `world − rootOrigin`
shortcut that ignored the relocalized anchor's yaw — overlays no longer
float off the cloth after relaunch; strip orientation kept anchor-local on
purpose (table-space heading + anchor rotates with the table). Before/after
frames in docs/validation. App on the known-good `.cpuOnly` build. Earlier
this session (autonomous loop): stick aim VERIFIED engaging on device and
its flicker fixed (2.5 s time-based hold; duty 50%→86% — `0e62a3d`); the
on-table stick gate (`b8c805a`) holds. Mirror now exposes the predicted
trajectory (`prediction` field: path + cushion/rest/pocket in table space —
`bfcd097`), so bank ground truth is numerically loggable. First numeric
bank prediction captured (docs/validation). App healthy on the `.cpuOnly`
known-good build; no new crashes. STILL OPEN and needing a human at the
table: object ball often untracked on black cloth at CPU cadence (detection
sparsity — same root as T1.3); predicted-vs-ACTUAL bank still needs real
shots [HUMAN]; T1.4 freeze not reproduced this session. Prior context from
the third session below.

That session:
`Tools/DetectionEval` offline eval CLI (runs the bundled model on stills via
the app's provider — EXIF-aware; `img/` has real-table photos, `img/upright/`
rotated copies); T1.2 (cushion-nose HUD copy, StandardSizeComparison + raw
pre-snap size on TableCalibration, relocalization stopwatch, mirror keys
`sizeVsStandard`/`relocalizationSeconds`) and T1.4 instrumentation
(FrameDiagnostics counters + `frameDiag` in the mirror state) landed
code-complete, `needs-device-run`; T1.3 retraining/export findings below.

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

## RESOLVED 2026-07-22 (late session): guides + designation work at the table

Verified live through the debug mirror: cue ball classified (white-ball →
.cue, 90%+), stick-based aiming active (aimSource "stick"), trajectory
strips + ghost ball + spin guide all rendering on the cloth. The fixes that
got there: playing-surface observation gate (phantom tracks from
frame-clipped boxes / off-table matches), tap feedback on every path
(pocket-call taps used to look dead), 0.25 m designation radius, always-on
ball rings, raw detector labels in the mirror state. Remaining polish:
overlay/ring positions sit a few cm off the real balls (foot-point
projection + calibration offset — tune with mirror screenshots); fast cue
ball movement can briefly spawn a duplicate track (gating distance 0.08 m
vs ball speed); ARSession "retaining 11 ARFrames" warning persists
harmlessly at ~11-13 — profile before M5.

## Original bug notes (kept for context)

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

**2026-07-22 late (T1.3 execution findings):** the fork has the DATASET
only — `version(1).model` is nil, so there are no downloadable weights
anywhere; best.pt must be RETRAINED before every re-export (25 epochs
YOLOv11n freeze=10 on the 1000/284/141 split ≈ 1.5 h on CPU). Chris's Mac
is **Intel x86_64**: torch wheels stop at 2.2.2 there, so the whole recipe
runs in Docker (`python:3.12-slim` linux/amd64 + `apt-get install libgl1
libglib2.0-0 libxcb1` + `pip 'numpy<2'` — ultralytics 8.3.40 still calls
`np.trapz`). Export driver: the container script monkeypatches
`ct.convert` exactly per the recipe above.
Parity gate before any swap: `Tools/DetectionEval` (macOS CLI) runs the
bundled model through the app's real `CoreMLDetectionProvider` on still
images — its CPU output matched the live iPad's rawDetections on the same
scene, so old-vs-new box diffs on `img/upright/` are a trustworthy proxy;
final ANE/crash check still needs the device.

**2026-07-23 NEGATIVE RESULT: iOS16 target does NOT fix the crash.** The
retrained model (val mAP50 0.893) exported at iOS16/CoreML6 with fp32
pipeline outputs still aborts in
`MPSGraphExecutable applyOptimizationPassesWithDevice…MLIRName` (SIGABRT,
crash-looped the app at first inference with `.all`). The boundary-cast
theory is dead — MPSGraph on iOS 26 chokes on coremltools-9 mlprograms
generally. The new model SHIPPED anyway on `.cpuOnly` (equal quality,
fewer false positives). Export mechanics that had to be discovered:
(1) at iOS16+ coremltools defaults outputs to fp16 which the classic NMS
pipeline stage rejects — pin `outputs=[ct.TensorType(dtype=np.float32)]×2`
in the monkeypatch; (2) ultralytics writes the pipeline WRAPPER spec as
5/6 around a spec-7 mlProgram and the CoreML compiler rejects the package —
bump `spec.specificationVersion` (and both stage versions) to ≥7
post-export via load_spec/save_spec. Remaining candidates, in order:
iOS17/CoreML7 export (built, parity-checked on Mac CPU, staged in the
sandbox container at `/work/best_ios17_fixed.mlpackage` — test ONLY in a
controlled moment, it may crash-loop the app again); fp32 GPU-only
(`quantize=32`); file a feedback with Apple. Crash logs archived from the
device on 2026-07-23 (~00:00 local).

**2026-07-23 RESEARCH — the crash was tested WRONG; a promising untested
option remains.** Web research (incl. Ultralytics' own CoreML docs and a
detailed Reddit write-up of the identical crash) established:
- The `Error: MLIR pass manager failed` abort on **`coremltools` 9.x
  mlprograms is a KNOWN limitation of the `.all` / `.cpuAndGPU` path** —
  it's the GPU/MPSGraph compile route that trips Apple's MLIR compiler, an
  UNCATCHABLE C++ assertion (no `do/catch`, no config flag prevents it).
- **The device test only ever used `.all`** (`SessionModel.loadBundledDetector`),
  which INCLUDES the GPU → guaranteed to hit the crashing path. **We never
  tried `.cpuAndNeuralEngine`.** Ultralytics explicitly recommends
  `.cpuAndNeuralEngine` as BOTH the crash-avoider AND the right unit for a
  camera app (don't fight the AR preview for the GPU; `.all` also causes
  frame-time jitter). ANE routes differently from GPU/MPSGraph and may
  dodge the MLIR bug entirely — though on some hardware the ANE path can
  also hit it (device-specific), so it's a genuine unknown to TEST.
- The fp16-outputs-vs-NMS issue and the iOS16+ FLOAT32 requirement I solved
  by hand are exactly what Ultralytics' exporter already encodes
  (`minimum_deployment_target >= iOS16` ⇒ `compute_precision=FLOAT32`
  because no CoreML NMS spec accepts fp16 input). YOLOv11 uses SiLU (well
  supported), NOT Mish — so this is not the Mish/Softplus fp16 bug.

**NEXT EXPERIMENT (one-line, do with the device + a human watching):** flip
`SessionModel.loadBundledDetector` from `.cpuOnly` to
**`.cpuAndNeuralEngine`** (NOT `.all`) with the CURRENT bundled model — no
re-export needed. If it runs: un-pin achieved, ANE ~3× CPU, fast-ball
detection improves. If it still SIGABRTs: the ANE path is also affected on
this iPad → stay `.cpuOnly`, file Apple feedback. **Before trying it,
implement a crash-safe probe** (persist an "attempting ANE" flag before the
first inference, clear it after the first success; on launch, if the flag
is still set the last run crashed → force `.cpuOnly`). That converts the
risky test into a self-healing one — no more manual crash-loop recovery.
Retrained weights + all export variants persist at
`scratchpad/.../export-work/` (best.pt, best_ios16_fixed, best_ios17_fixed).

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
