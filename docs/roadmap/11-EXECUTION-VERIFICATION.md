# 11 — Remaining Work: Execution & Verification Plan

**Method** (the "Karpathy recipe", adapted from neural-net training to this
codebase): (1) become one with the data — look at real frames, real logs,
real residuals before theorizing; (2) get the smallest END-TO-END slice
working before generalizing; (3) overfit one example first — one canonical
shot, one drill, one venue — then scale out; (4) instrument everything and
visualize inputs/outputs at every stage (our instruments: the two-way debug
mirror, `com.cuesync.ar` logs, golden fixtures, the replay suite once it
exists); (5) hold a FIXED eval set and ratchet — a change ships only when it
moves a measurement without regressing the suite; (6) add complexity one
knob at a time. Every item below states its slice, its instrument, and its
"verified" bar. Status date: 2026-07-22.

The autonomous loop that executes this plan (proven end-to-end): edit →
Linux package tests → commit → Xcode build to device → observe via mirror
(`/state.json`, `/frame.jpg`) → drive the app via mirror commands
(`/cmd?action=designate|callPocket|resetTracking|guideSpeed|setMode`) →
iterate. Human hands are needed ONLY where flagged **[HUMAN]**.

---

## Tier 1 — In flight now (close these before opening anything new)

### T1.1 Bank-line ground truth (M3-06 row + physics Layer 3)
- **Slice:** one 45° one-cushion bank on the real table.
- **How:** device at the table with calibration locked → remotely designate
  cue ball via mirror → screenshot mirror with the drawn bank line → lay a
  cue stick along the actual bank path **[HUMAN, 2 min]** → compare exit
  points on the mirror image.
- **Verified when:** predicted vs actual exit point within ~1 ball width at
  mid-speed, logged in `docs/validation/` with the mirror screenshot.
  Repeat for a straight pot and a two-rail kick (the 3 canonical shots).

### T1.2 Relocalize-or-recalibrate UX (measurement truth, Layer 1.1)
- **Slice:** app relaunch at the table reaches "locked + tracking" with zero
  taps (saved venue) or one guided calibration (new venue).
- **How:** cushion-nose hint text in the calibration HUD; show the locked
  size delta vs nearest standard size; log relocalization time.
- **Verified when:** mirror state shows `calibrationLocked: true` within
  15 s of the device seeing the table from a normal standing angle, three
  relaunches in a row **[HUMAN: carry the device once per test]**.

### T1.3 ANE model swap (perf: un-pin `.cpuOnly`)
- **Slice:** the iOS16-target fp16 re-export (recipe in 09-SESSION-STATE)
  running one inference on device without the MPSGraph crash.
- **How:** regenerate the export in the sandbox, swap
  `App/Resources/BallDetector.mlpackage`, flip `.cpuOnly` → `.all`, build,
  watch the console for the crash signature and the mirror for detections.
- **Verified when:** `rawDetections` flow with `onDeviceDetection: true`,
  no crash across a 10-minute run, and pipeline frame cadence measurably up
  (log timestamps; expect ≥2× the CPU-only rate). Rollback = revert pin.

### T1.4 ARFrame-retention warning root-cause
- **Slice:** reproduce with one instrumented run; count where frames pin.
- **How:** temporarily log delegate entry/exit + copy counts; correlate
  with mirror snapshot cadence (the `arView.snapshot` path is the prime
  suspect — it retains drawables, not our delegate).
- **Verified when:** warning stops appearing, or the cause is documented as
  benign RealityKit-internal with a profiling note (M5-01 will re-check).

## Tier 2 — Perception data flywheel (M2-04 → M2-05)

### T2.1 M2-04 fixture capture through the mirror
- **Slice:** 10 labeled frames from ONE venue/lighting.
- **How:** the mirror already serves camera frames + tracked state; add
  `/cmd?action=captureFixture` that saves frame JPEG + detections +
  table-space truth into the app's Documents, served back at
  `/fixtures.zip`. Label check happens in the sandbox (render boxes over
  the JPEG, eyeball, correct).
- **Verified when:** 30+ frames across 2 lighting setups committed under
  `Packages/PerceptionKit/Tests/.../Fixtures/RealTable/` with a manifest.
  **[HUMAN: rearrange balls twice]**
- *Karpathy note: this is "become one with the data" — every later
  detection/projection claim gets judged against these frames.*

### T2.2 M2-05 replay suite
- **Slice:** replay ONE captured fixture through PerceptionPipeline on
  Linux and assert ball-position error bounds.
- **How:** fixtures feed `FixtureDetectionProvider`; accuracy bars from
  04-TESTING-STRATEGY (position RMS ≤ 2 cm, kind accuracy, stability =
  no track churn across the clip).
- **Verified when:** suite green in ci-core; becomes the FIXED EVAL SET
  that every future perception change must not regress (the ratchet).

### T2.3 Dataset rev (measle/low-light white ball)
- **Slice:** +100 images (dotted cue balls, dim white balls) on the fork,
  one retrain, one A/B against the current model ON THE REPLAY SUITE.
- **Verified when:** white-ball recall improves on T2.1 fixtures without
  mAP regression; new model ships only after T1.3's export path is stable.

## Tier 3 — Auto table detection (M6-06, kills manual corner taps)

- **Slice 1 (proposal):** cloth-color mask on one mirror frame in the
  sandbox (Python/OpenCV prototype first — cheap iteration), largest
  contour → min-area quad → visually overlay on the frame. Verified by eye
  on 5 frames from different angles.
- **Slice 2 (on-device):** port the winning approach to Vision/CoreImage
  behind "Auto-detect table" in the calibration HUD; proposed corners
  land in the EXISTING drag-adjust flow (manual refinement stays).
- **Slice 3 (auto):** if proposal ⟂ manual lock delta < 2 cm on 5 tries,
  skip the confirm step by default.
- **Verified when:** fresh calibration on a clean table takes one tap
  **[HUMAN: one recalibration per iteration, ~30 s]**; locked size within
  1 cm of the manually-locked baseline.

## Tier 4 — Physics Solver v2 (10-PHYSICS-PLAN Layer 2, one contract PR)

- **Slice:** rolling-follow (30° rule) + two-phase slide/roll deceleration
  together, since both change `SolverOptions` (contract-change PR per
  playbook rule 4).
- **How:** pure implementation + hand-derived goldens FIRST (the fixture
  discipline from M1-03: derivation recorded in-file); then guide-speed UI
  exposes stun/roll so ShotGuide's recommendation and the drawn path agree.
- **Verified when:** goldens green; on-table check = the T1.1 canonical
  shots re-measured with a ROLLING cue ball (follow path visibly bends
  forward and matches reality within a ball width). Speed-dependent cushion
  + throw wait for T2 fixture data to fit against (don't tune blind).

## Tier 5 — Product surface (M4 + M6 remainder)

- **M4-04 Settings** — slice: one screen (table size override, provider,
  guide speed, mirror toggle, mode). Verified: persistence tests + a mirror
  screenshot tour. Mostly sandbox-writable, device-verifiable remotely.
- **M4-02 TV styling + M6-04 TV aim confirmation** — slice: ExternalTableView
  styled at 1080p with the aim line + called pocket mirrored. Verified:
  snapshot tests (scene is pure) + one AirPlay session **[HUMAN: has an
  Apple TV / external display]**.
- **M4-03 UI/snapshot/accessibility suites** — slice: snapshot the pure
  CueSyncUI components first (Linux-independent), then fixture-mode launch
  smoke on simulator in ci-app. Verified: suites in CI.
- **M6-03 Drills v1** — slice: ONE drill (straight-in pot, 3 spots) driving
  ghost-ball targets through the existing overlay renderer; progression =
  called-pocket satisfied + object ball vanishing near the called pocket
  (tracker already knows). Verified: drill completable end-to-end on device
  via mirror observation; step logic pure + tested.
- **M6-05 Projector + homography** — after M6-04; needs the projector
  hardware **[HUMAN]**; homography math is pure and testable first.

## Tier 6 — Ship gate (M5)

M5-01 perf/thermal profiling (after T1.3, on 3 device classes **[HUMAN:
owns the devices]**), M5-02 two-venue checklist **[HUMAN]**, M5-03
analytics decision **[HUMAN: policy]**, M5-04 TestFlight assets
**[HUMAN: App Store Connect]**, M5-05 toolchain re-check.

---

## Standing human-action list (everything the plan needs from a person)

1. Push branches via SourceTree after each work session (CI verifies the
   lint fixes on the next push).
2. One-time golden review: M1-03 fixtures incl. the 3 cushion re-derivations.
3. T1.1/T1.2: minutes of table-side hands per verification round.
4. T2.1: rearrange balls twice for fixture variety.
5. M5/M6-05 hardware + App Store items.

Everything else runs through the autonomous loop.
