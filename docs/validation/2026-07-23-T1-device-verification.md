# T1 device verification — 2026-07-23 (late night session)

Device: Christopher's iPad (2), iPad 9th gen, iOS 26, at the home table
(8 ft, black cloth). All observations via the debug mirror over Tailscale
(`http://ipad-9th-gen-wifi:8787`, tailnet IP 100.117.151.65) with the app
driven remotely via `devicectl` — no hands on the device except where noted.

## T1.2 Relocalize-or-recalibrate — VERIFIED

- Build: `5a124cd` (+ `a117c2f`/rollback commit for the model swap).
- Three consecutive remote relaunches (`devicectl device process launch
  --terminate-existing`), device stationary on a stand seeing the table
  from a normal standing angle:

  | relaunch | locked | relocalizationSeconds | restored size |
  |---|---|---|---|
  | 1 | yes | 2 | 2.34 × 1.17 m, "8 ft +6.8 cm" |
  | 2 | yes | 2 | 2.34 × 1.17 m, "8 ft +6.8 cm" |
  | 3 | yes | 2 | 2.34 × 1.17 m, "8 ft +6.8 cm" |

  Bar was ≤15 s: **passed at 2 s** each time. The measured pre-snap size
  survives the AnchoredCalibration round-trip (the +6.8 cm readout after
  restore is the fix in `5a124cd`… persisted measured fields).
- Caveat learned on the way: the FIRST relocalization of a freshly saved
  world map took ~90–150 s (two observations) — subsequent ones are ~2 s.
  The 15 s deadline's fallback reconfigure does NOT cancel relocalization
  (ARKit retains the loaded map), so the stopwatch keeps running past it.
- Human-experience data point: manual corner pins of the same table
  measured -7.7 cm, then ~7 ft (shallow-angle raycast, 20% short!), then
  +6.8 cm across three attempts — tap-accuracy spread is real and the
  live pre-lock readout + saved table spec (commit `5a124cd`) exist to
  contain it. The 7 ft mis-lock was restored by relocalization before the
  spec feature landed; the spec now prevents that class of error.

## T1.4 ARFrame retention — instrumented, no pile-up in our paths

frameDiag steady-state after minutes of live tracking (two samples):

    seen 11796 delivered 440 copyFailures 0 snapshots 243 avg 120 ms inflight 0
    seen  1215 delivered  69 copyFailures 0 snapshots  19 avg  95 ms inflight 0

- Delegate hands out ~1 frame per 27 seen (pull model working as designed),
  zero deep-copy failures, snapshot completion ~100 ms at 1 Hz with never
  more than one in flight — no evidence of frame pinning in app code.
- First `arView.snapshot` after launch: 3.9 s (cold RealityKit pipeline).
- Remaining step to close T1.4: one console-attached run to correlate the
  "retaining N ARFrames" warning count with snapshot on/off (toggle the
  mirror), now trivial with the counters in `/state.json`.

## T1.3 ANE un-pin — NEGATIVE RESULT, rolled back same night

- iOS16/CoreML6 re-export (fp32 pipeline outputs, spec bumped to 7) still
  SIGABRTs in `MPSGraphExecutable applyOptimizationPassesWithDevice…` at
  first inference with `.all` — crash-looped the app; logs archived from
  the device (2026-07-23 ~00:00). `.cpuOnly` re-pinned in the same hour.
- The retrained model itself (val mAP50 0.893) shipped anyway on CPU:
  parity-checked against the old model via Tools/DetectionEval — same true
  detections on the live-table frame, fewer false positives.
- Next candidate staged: iOS17/CoreML7 export, parity-checked on macOS,
  in the export container at `/work/best_ios17_fixed.mlpackage`. Test only
  with a human at the device expecting a possible crash.

## T1.1 bank-line ground truth — ready to run

Everything it needs is now in place: correct 8 ft calibration locked,
prediction rendering, remote designate/callPocket via `/cmd`, frame
capture via `/frame.jpg`. Needs the [HUMAN] step: lay a cue along the
predicted bank path and hold position for one mirror screenshot.

## T1.1 Bank-line ground truth — first data point (same night)

Shot: one-cushion bank of the red 3 toward the far-right corner
(cornerTopRight in table space), medium speed, shot by Chris. Cue ball
started (-0.17, -0.02), red at (0.13, -0.29). All coordinates from the
live tracker over the mirror (state.json at pipeline cadence — the
per-tick publishing added for this test).

Observed (table space, meters):
- Red rest position: (1.10, 0.60) — in the jaw of the corner pocket
  (1.17, 0.585), ~9 cm short. Chris: "just missed".
- Mid-roll sample at (0.89, 0.58): red reached the far cushion line
  ~28 cm BEFORE the pocket, then rolled along the rail into the jaw.
- Cue ball rest: (0.37, -0.16).

Bank-angle comparison (contact point inferred from intended line —
±5°-ish uncertainty):
- Ideal mirror exit: ~35° from cushion normal → arrives at the pocket.
- Actual exit: ~25° — the real cushion shortened the bank by ~10°.
- AnalyticSolver's current model (cushionRestitution 0.75, tangential
  retention 0.7) shortens by only ~2° (tan ratio 0.93). Direction of the
  model error is confirmed; magnitude suggests the tangential/normal
  ratio should be nearer ~0.66 at medium speed. ONE data point — do not
  retune from this alone; repeat per the 3-canonical-shots plan.

Instrument findings that block a tighter measurement (fix before rerun):
1. **Stick-aim rail false positive**: the pipeline's stick pick locked
   onto the table's far rail edge (classified "cue" at ~74%) — its quad
   projects OFF the playing surface (y 0.83–1.35 on a 0.585 half-height
   table), so StickAim correctly rejects and aim never leaves devicePose.
   Sticks need the same on-table observation gate balls already have,
   plus "prefer quad nearest the cue ball" over raw confidence.
2. **No mid-flight tracking**: the entire pre-bank leg produced zero
   track updates (motion blur at medium speed + ~2–4 Hz CPU cadence);
   only the slow tail of the roll was sampled. The predicted-vs-actual
   CONTACT POINT therefore has to be inferred. Higher detection cadence
   (T1.3's ANE work) or slower calibration shots would fix this.
3. During Chris's address, his hand/body occlusions dropped the cue-ball
   track repeatedly; tracks recovered in seconds each time.

Also observed this session: full AR-session freeze (camera, delegate
frames, and snapshots all stopped; NO ARKit session event) after ~80k
frames seen / ~6k delivered / 1215 snapshots — recovered by app relaunch
(2.2 s relocalization). Strongest T1.4 lead yet: silent capture-pool
starvation, not an ARKit-reported interruption.
