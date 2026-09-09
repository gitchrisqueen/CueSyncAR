# 09 — Session State & Handoff

**Purpose:** land the *current working state* in the repo so any fresh agent
(or human) can resume without a prior chat session. Update this file whenever
a work session ends or a major finding lands.

**Last update: 2026-09-09 (agent session, `main` @ `8a1f96d`).** Twelve PRs
merged across three sessions. All four device-visible symptoms the operator
reported now have fixes, each measured against recordings of his own table
rather than argued from the code; every one of them still needs a table run
to confirm. Read "2026-09-09" below first — it supersedes the 2026-09-07
notes, which are kept for context.

**The finding of that session:** every guide line had been rendering at the
wrong heading on any table whose axes are not the session's world axes — a
right angle on the operator's table. `OverlayLayout` emitted a TABLE-space
heading and `OverlayRenderer` applied it about the anchor's LOCAL Y, on the
belief that the table anchor rotates with the table. It does not:
`placeTableAnchor` builds it from an identity rotation plus a translation.
Midpoints were correct, so the strips traced the right path with every bar
pointing the wrong way. The ARExperience test fixture has table +x equal to
world +x, the one basis where the bug is invisible.

**The single most important finding of that session:** the sphere-centre
projection had never run on device. `raycastToTablePlane(...planeHeightOffset:)`
was declared only in the `PlaneRaycasting` protocol EXTENSION, so the
pipeline's call through `any PlaneRaycasting` bound statically to the
no-lift fallback. Every ball projected `r / tan(elevation)` long — 6.1 cm at
25 degrees of camera elevation, 2.9 cm at 45. Fixed in #8 by promoting the
method to a protocol requirement; guarded by `PlaneRaycastingDispatchTests`.
Commit `cc37d92` ("Locate balls by sphere center") had shipped inert.


## Where the project stands

Working on device (iPhone 16 Pro, iPad 9th gen):

- AR camera feed, calibration flow (tap 4 corners → drag → lock, custom sizes
  allowed with 8% snap to standard), ARWorldMap persistence + relocalization,
  anchor-rooted overlays (drift fix), camera flip, auto box orientation.
- On-device detection: bundled `App/Resources/BallDetector.mlpackage`
  (YOLOv11n fine-tune, mAP50 0.896 — see M2-01 in 06-MILESTONES). Compute
  units: **`.cpuAndNeuralEngine` behind a crash-safe probe** since
  2026-09-07 (merged as #20, `e3e2581`; needs-device-run) —
  the `.cpuOnly` pin comes back automatically if the ANE path aborts (see
  "ANE re-export" below). Never `.all`: GPU/MPSGraph crashes with "MPSGraph
  MLIR pass manager failed" on iOS 26.
- Live loop: pipeline → tracker → TableState → aim (stick-based with
  device-pose fallback) → AnalyticSolver → RealityKit overlays; ShotGuide
  tip-contact coaching card; pocket calling (M6-02); tap-to-designate cue
  ball (for measle/practice balls the detector can't classify).
- Diagnostics (2026-07-22): os.Logger subsystem `com.cuesync.ar` (categories
  `session`, `pipeline`, `mirror`); every tap gives on-screen feedback;
  tracked-ball rings always render during live tracking (cue = white).

## B3 (2026-09-07): overlays a few cm off — two causes, sized honestly

The residual "rings/guides sit a few cm off the real balls" has a DOMINANT
cause and a second-order one; they landed on separate branches:

1. **Dominant — sphere-centre lift never dispatched** (task C's finding,
   fixed on `claude/C-synthetic-harness`): `raycastToTablePlane(…,
   planeHeightOffset:)` was only a `PlaneRaycasting` extension method, so
   the pipeline's call through `any PlaneRaycasting` bound to the fallback
   that drops the lift. Every ball projected LONG by r/tan(elevation):
   61 mm at 25°, 29 mm at 45° (harness-measured). Direction follows the
   camera — exactly the observed symptom.
2. **Second-order — calibration frozen at lock vs ARKit's refined anchor**
   (this branch, `claude/B3-anchor-calibration`): the pipeline and every
   app consumer used the lock-time world calibration while camera poses
   arrive in ARKit's continuously refined world frame. The error equals
   the anchor's refinement since lock: horizontal/yaw refinement shifts
   the TABLE-space coordinates (cushions, pockets, trajectory relative to
   the ball); a vertical refinement δy shifts the ring itself by
   δy/tan(elevation). Package test: 20 mm anchor drift → frozen path
   18.9 mm (top-down) / 25.9 mm (35° oblique) off; followed path 0.02 mm /
   ~0 mm (`AnchorFollowingTests`). How much ARKit actually refines the
   table anchor in a session is NOT yet measured on device — the mirror
   now reports it as `anchorDriftMm` (translation since lock).

Live path: `PerceptionConfig.followsTableAnchor` (default ON) —
`PerceptionPipeline.ingest(_:tableAnchorTransform:)` re-derives the
calibration per frame from `AnchoredCalibration`; `SessionModel` mirrors
that for overlays/aim/taps (`SessionModel+AnchorFollowing.swift`), fed by
`ARSessionCoordinator.currentTableAnchorTransform`. A/B at the table:
mirror buttons "Follow anchor ON/OFF" (`/cmd?action=followAnchor&v=0|1`;
OFF = pre-B3 frozen behaviour, rebuilds the pipeline). **Device run
needed:** watch `anchorDriftMm` over a few minutes of walking around the
table and across a relocalization; if it stays at a few mm, this fix is
a guard rail and C's is the whole story; if it climbs to 1–3 cm (loop
closures, post-relocalization refinement), the A/B should show pockets
and cushion lines snapping back onto the physical table with ON.

## 2026-09-07 session — what landed, and what it needs from the table

Nine PRs merged to `main` (`83bd090` → `77f097d`), plus #16 (SessionReplay)
in flight. Everything below is `needs-device-run` unless stated otherwise.

**Fixes aimed at what the operator actually saw**

- **#8 PlaneRaycasting dispatch** — see the header. This is the bulk of the
  "overlays sit a few cm off" symptom. Found independently by two
  workstreams (the synthetic harness and the replay work), reproduced
  end-to-end through the real pipeline before the fix.
- **#7 phantom tracks** — `BallTracker` retired unmatched tracks on a frame
  COUNT (`disappearanceFrames` 30). Frame counts are not a clock: at the
  observed ~8.7 Hz that is 3.45 s, exactly the reported phantom lifetime.
  Added `TrackerConfig.visibleMissGrace` (0.75 s, time-based, visibility
  gated). The out-of-view occlusion guarantee is structurally preserved —
  neither counter moves while nobody is looking. **0.75 s is a judgement
  call, not a measurement**: if the detector drops a visible ball for
  longer than that on real cloth, rings will flicker. That is the knob.
- **#11 off-table tracks** — the surface gate only ever checked incoming
  OBSERVATIONS; the tracker's output (what becomes `TableState`) was never
  checked at all. The gate also admitted `halfExtents + 2r` while a real
  ball centre cannot exceed `halfExtents − r` — 8.6 cm of physically
  impossible space, a margin tuned while #8's bug was inflating every
  projection. New `PlayingSurfaceGate` runs at both ends: observations are
  admitted within a 4.5 cm slack band and CLAMPED onto the envelope (a rail
  ball renders on the rail, never clipped), and tracker output is filtered.
  Note the Kalman filter itself cannot overshoot — its update is a convex
  combination — so tracks were off-table because the gate let them in, not
  through filter drift. The output gate is enforced anyway because a
  future velocity-state filter WOULD predict through cushions.
- **#13 anchor following** — the pipeline held calibration frozen at lock
  while overlays used the anchor's current transform. Now re-derived per
  frame behind `PerceptionConfig.followsTableAnchor` (default on,
  A/B via `/cmd?action=followAnchor&v=0|1`). **Sized honestly: this is
  second-order next to #8.** For a horizontal table, horizontal and yaw
  refinement do not move a ball ring at all; only vertical refinement does,
  by `δy/tan(elevation)`. The mirror now reports `anchorDriftMm` — that
  number is what decides whether this matters at all.

**Instruments that make iteration table-free**

- **#9 synthetic pinhole harness** (`CueSyncTestSupport`) — exact ground
  truth, no hardware. Ideal round trip closes to 0.343 mm at 3.3 m. It is
  what found #8. Any projection change is now measurable in millimetres on
  Linux. It also measured a second, independent error source: rail-top
  calibration taps at a realistic pose shift the ORIGIN by 48.5 mm.
- **#16 SessionReplay** (in flight) — byte-exact replay on Linux, verified
  in a `swift:6.1` container against a macOS-authored golden. Canonical
  JSON writer, `Date()` purged from the ingest throttle, dictionary
  iteration removed from `nearestEvent`. `SessionModel` runs the same value
  types with an injectable clock, so replay judges the SHIPPED decision
  logic rather than a copy.
- **Session recorder** — the missing half. Nothing can yet produce a bundle
  from the real table. Until one exists, the replay loop runs only on
  synthetic and scripted data.

**Product surface**

- **#10 settings** (`SettingsModel` in CoachKit, `UserDefaults` seam typed
  by value kind because `UserDefaults` bridges through `NSNumber` and an
  untyped API reads a guide speed of `1.0` back as `true`). `visibleMissGrace`
  is exposed and persisted but **the tracker does not read it yet** — a
  one-line follow-up, and the UI says so rather than pretending.
- **#12 build identity** — SHA/branch/dirty/built in the HUD, the mirror
  and the startup log. `ENABLE_USER_SCRIPT_SANDBOXING` is `NO` on the app
  target as a deliberate trade-off (the sandbox blocks both reading git and
  writing the built plist); accepted by the owner 2026-09-07.
- **#15 app icon** — and a silent failure fixed: the app had NEVER shipped
  an icon. The catalog was wired in `project.yml` but empty, so `actool`
  emitted no `Assets.car` and the build stayed green. Verify icon changes
  by inspecting the built bundle (`assetutil --info Assets.car`), never by
  a green build alone.
- **#3 agent runner** — merged, but installed PAUSED and inert until the
  GitHub App, host setup and an explicit go (CS-01/02/04). An adversarial
  review found five blocking issues (write token reachable from the model's
  shell, public review threads dispatched as work, a 100-file path check,
  host FQDN in commit authors, and three defects that stopped it completing
  a cycle); all were remediated, but **the remediation has not been
  independently re-reviewed** — do that before clearing PAUSED.

**Hazards worth not re-learning**

- `App/Sources/SessionModel.swift` sits near SwiftLint's 1000-line
  `file_length` ERROR. Three separate problems in one session traced to it,
  including a CI break when two agents independently moved the same block to
  different files (duplicate `PixelBufferImage` conformance). A proper split
  is queued.
- **`Scripts/test-all.sh` does not compile the app target.** A branch went
  red in CI on the Simulator build while every package test was green.
  Always run `xcodegen generate && xcodebuild -scheme CueSyncAR
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
  build` before claiming a change is verified.
- Running `swift test` and `xcodebuild` concurrently in one worktree
  produces spurious "cannot find type" failures from stale artifacts.

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
mirror**: it is on by default; read its address under **⋯ → Debug mirror →
Address** (also in Settings → Developer, and said once on the HUD when the
switch is flipped by hand) → open that URL in any browser on the same
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
YOLOv11n freeze=10 on the 1000/284/141 split ≈ 1.5 h on CPU). The development Mac
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
sandbox container (outside the repo) — test ONLY in a
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
- The fp16-outputs-vs-NMS issue and the iOS16+ FLOAT32 requirement solved
  by hand are exactly what Ultralytics' exporter already encodes
  (`minimum_deployment_target >= iOS16` ⇒ `compute_precision=FLOAT32`
  because no CoreML NMS spec accepts fp16 input). YOLOv11 uses SiLU (well
  supported), NOT Mish — so this is not the Mish/Softplus fp16 bug.

**2026-09-07 SHIPPED (merged as #20, `e3e2581`; needs-device-run):
`.cpuAndNeuralEngine` behind a crash-safe probe.** `loadBundledDetector`
now asks for `.cpuAndNeuralEngine` (NOT `.all`) with the CURRENT bundled
model — no re-export. The outcome is NOT known: the Simulator has no
Neural Engine and the build proves nothing about the abort. What shipped:

- **Probe** (`DetectorComputeProbe`, PerceptionKit, 16 Linux tests): a
  marker file `Application Support/CueSync/detector-compute-probe.json` is
  written with `Data.write(.atomic)` + `fsync` BEFORE each ANE step that
  can abort (the `MLModel`/`VNCoreMLModel` inits, then the first
  `detect`) and cleared AFTER the step returns. Both are synchronous
  syscalls, so a SIGABRT between them cannot lose the marker (process
  death does not touch the page cache; the fsync covers power loss too).
  `UserDefaults` was rejected for this because its writes are proxied to
  `cfprefsd` and are not guaranteed to have left the process before an
  immediate abort. A launch that finds the marker set counts a crash,
  sets `pinnedToCPU`, and loads `.cpuOnly`. "First success" = the first
  `detect` call that RETURNS A RESULT; a thrown Swift error clears the
  marker but does not count, and the next call probes again. A normal
  exit between load and first inference leaves no marker (not a crash).
- **Owner controls**: Settings → "Detector compute" shows the probe line,
  a "Pin detector to CPU" toggle (`SettingsModel.detectorPinnedToCPU`,
  key `detectorPinnedToCPU`, wins over the probe) and "Retry Neural
  Engine on next launch" (enabled only while a crash pin is set). Mirror:
  `/cmd?action=resetComputeProbe`. Both take effect on the next launch —
  the loaded model cannot swap units in place.
- **Where to read it**: `/state.json` → `detectorCompute` block:
  `units` (`cpuAndNeuralEngine` | `cpuOnly`), `phase` (`attempting` |
  `succeeded` | `fellBack` | `optedOut` | `loadFailed`), `crashedLastRun`,
  `crashes`, `successes`, `pinnedToCPU`, `relaunchNeeded`, `summary`,
  `marker` (path). Console (filter "cuesync"): `detector compute: …` at
  notice level on every launch; `.error` when a crash was detected.

**What the owner will observe (pick one and report it):**

1. **ANE works.** App launches, calibrate, lock: rings appear. `/state.json`
   `detectorCompute.units == "cpuAndNeuralEngine"` and `phase` flips from
   `attempting` to `succeeded` within a second of lock (`successes` ≥ 1).
   Settings line reads "Detector: Neural Engine, probe passed (1 run)".
   Report: the `detectorCompute` block, plus the `frameDiag` block over ~30 s
   (`delivered` should climb faster than the CPU-era ~6-7 Hz).
2. **ANE aborts.** The app dies at calibration lock (or at launch, if the
   abort is in model load) — ONCE. Relaunch: it comes up on the CPU and
   stays up. `detectorCompute.units == "cpuOnly"`, `phase == "fellBack"`,
   `crashedLastRun == true`, `crashes == 1`. Settings line: "Detector: CPU —
   Neural Engine crashed last run (1 total); reset to retry". No reinstall.
   Report: that block + the crash log from Settings → Privacy → Analytics
   (look for `MPSGraph`/`MLIR` in the abort frame; if it is NOT MPSGraph,
   that is new information — attach it). Then file the Apple feedback.
3. **ANE was never attempted** (how to tell 2 from 3): `phase ==
   "optedOut"` means the Settings pin is on; `phase == "fellBack"` with
   `crashedLastRun == false` means an EARLIER launch crashed and the pin
   is still set from then; `units == "notLoaded"` means the bundled model
   was not found (simulator build). `phase == "loadFailed"` means Core ML
   THREW on the ANE load rather than aborting — also report that log line.
4. **Reset and retry**: Settings → Retry Neural Engine on next launch (or
   `/cmd?action=resetComputeProbe`), then relaunch. `crashes` keeps
   counting across retries; a second crash after a reset gives `crashes ==
   2` — do not retry a third time, report it.

Retrained weights + all export variants persist outside the repo
(best.pt, best_ios16_fixed, best_ios17_fixed).

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

1. **Table run on the current build** — this is the gate on everything
   perception-related. The iPad already carries it (`e3e2581`, loaded
   2026-09-08). Four questions, in order of value: (a) do the rings
   and guides sit ON the balls now (#8); (b) does anything still render past
   the cushion nose, and do rail-frozen balls still render at the contact
   line (#11); (c) do phantom rings clear within ~1 s of a shot (#7);
   (d) what does Settings → Detector compute say afterwards (#20 — a single
   crash on the first session that recovers on relaunch is the probe working
   as designed, not a regression). Do this run AS the recording in step 2:
   one trip answers all four and produces the bundle. Tick
   M3-06 rows as they verify. If rail balls clip, read the size delta the
   app shows at calibration lock BEFORE touching the slack — the 8 % snap
   keeps the measured centroid as origin, so a mis-tapped table can put the
   modelled nose line ~10 cm off the real one.
2. **Record one session** (`docs/recording-a-session.md`) — the recorder is
   the last piece of the table-free loop. One five-minute bundle converts
   every later perception change into a CI measurement. Until it exists the
   replay suite runs on synthetic data only.
3. **M2-04/M2-05** — ingest that bundle as the fixed eval set; promote
   `Replay golden (Linux)` from the scripted fixture to real data.
4. **T1.3 ANE, tested correctly** — SHIPPED and merged as #20 (`e3e2581`).
   Loaded on the iPad 2026-09-08; launch alone does NOT exercise it
   (marker read back `armed:false`, zero successes, zero crashes). What
   remains is a session at the table: lock a table, let the detector run,
   then read `detectorCompute` in `/state.json` or Settings and report per
   the four outcomes in the ANE section. Folded into step 1 — it costs
   nothing extra once the camera is on a table.
5. **Independent re-review of the agent-runner remediation** before the
   PAUSED file is cleared (#3).
6. **Connect `visibleMissGrace`** — settings persists and mirrors it; the
   tracker does not read it yet. One line in `trackerConfigFromSettings()`.
7. M6-06 auto table detection; M4-02/03 polish; dataset rev for
   dotted/measle cue balls (`docs/model-testing.md`).

## Human-action checklist

- [x] Rotate/revoke pre-M0 Roboflow key (2026-07-21; new key in untracked
  `App/Config/Secrets.xcconfig`).
- [x] Push the T1 device-verification work (2026-09-07, redacted squash
  `b9f03b2` → merged as #6).
- [ ] **Table run on the current build** — the four questions in step 1.
  Tracked as ClickUp CS-07 (https://app.clickup.com/t/86e35y0h5); the iPad
  was loaded with `e3e2581` on 2026-09-08, so nothing blocks it.
- [ ] **Record one session** — the recorder shipped (#18); walkthrough in
  `docs/recording-a-session.md`. Same trip as the row above.
- [ ] One-time review of the M1-03 golden fixtures (then tick M1-03's
  "human-reviewed" exit criterion in 06-MILESTONES.md).
- [ ] Agent-runner go/no-go: GitHub App + `/opt/cuesync-agent` + secrets
  (CS-01), rulesets (CS-02), probe read (CS-04), seeded issues (CS-05).
- [ ] Delete `_to_delete/` at the repo root whenever convenient.
