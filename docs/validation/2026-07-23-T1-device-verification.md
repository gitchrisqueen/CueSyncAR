# T1 device verification — 2026-07-23 (late night session)

Device: the iPad (9th gen), iOS 26, at the home table
(8 ft, black cloth). All observations via the debug mirror over Tailscale
(`http://<ipad-host>:8787` over the tailnet) with the app
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
  in the export container (kept outside the repo). Test only
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
  (1.17, 0.585), ~9 cm short. The shooter: "just missed".
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
3. During the shooter's address, hand/body occlusions dropped the cue-ball
   track repeatedly; tracks recovered in seconds each time.

Also observed this session: full AR-session freeze (camera, delegate
frames, and snapshots all stopped; NO ARKit session event) after ~80k
frames seen / ~6k delivered / 1215 snapshots — recovered by app relaunch
(2.2 s relocalization). Strongest T1.4 lead yet: silent capture-pool
starvation, not an ARKit-reported interruption.

## Autonomous loop follow-up (2026-07-23, later) — stick aim VERIFIED + fixed

Static setup (cue stick laid on the cloth pointing through the cue ball at
a one-cushion target; cue ball + red object ball).

**T1.1 stick aim — VERIFIED engaging, flicker fixed.** With the cue on the
table `aimSource` reaches "stick" (the on-table gate fix from `b8c805a`
holds — no rail lock). But it flickered stick<->devicePose ~50/50: the
detector emits the stick in bursts (fresh stick projections only ~7% of
frames; devicePose gaps up to 6 s), and the old fixed 8-frame grace
(~1.2-2 s at the variable frame-pull rate) lapsed mid-gap. Fixed with a
2.5 s time-based hold (`0e62a3d`): duty cycle **50% -> 86%** on device,
fallback only during genuine >2.5 s gaps. Screenshot:
`2026-07-23-stick-bank-prediction.jpg`.

**Bank prediction captured (numeric, via new mirror `prediction` field
`bfcd097`).** Predicted CUE-BALL path at guideSpeed 3.5 m/s, table space:
(-0.05,-0.05) → bottom-rail bank (0.36,-0.56) → (1.14,0.47) → (1.07,0.56)
→ rest (0.29,-0.47). Cushion contacts pass 10-12 cm from the top-right
corner pocket; correctly NOT pocketed (>7.5 cm capture radius). Bottom-rail
reflection geometry is a correct mirror-ish bounce — solver behaving. NOTE
this is the cue ball's own multi-bank (the red object ball was not tracked
this session — black-cloth/CPU detection sparsity again), so it is a clean
cue-ball bank prediction, not a cue→object bank. Predicted-vs-actual for
this exact path still needs a real shot [HUMAN]; the mirror now logs the
actual roll opportunistically.

## AR overlay relocalization-rotation bug — FIXED (2026-07-23)

Overlays (ball rings, trajectory strips, ghost ball, pocket markers)
floated off the cloth and rotated about the table center after
relocalization (every relaunch), though correct at a fresh corner-pin.

Root cause: `OverlayRenderer.render` positioned entities with the
translation-only shortcut `local(world) = world − rootOrigin` and parented
them to the table ARAnchor. That equals true world position only at
identity anchor yaw (fresh lock); the relocalized anchor carries the
session's arbitrary yaw, which RealityKit re-applies to every child.

Fix (`c0e3ecf`): drop `rootOrigin`; place entities in true world space via
`setPosition(_:relativeTo: nil)`. Strip ORIENTATION deliberately kept LOCAL
to the anchor (not world) — `strip.angle` is a table-space heading and the
anchor rotates with the table, so the anchor yaw supplies the correct
world heading post-reloc; a world-space yaw would under-rotate strips.

Verified on device via the mirror, RELOCALIZED path (reloc 2.2 s):
- before: `2026-07-23-overlay-reloc-before.jpg` — orange trajectory lines
  float up into the window glass, well off the cloth.
- after: `2026-07-23-overlay-reloc-after.jpg` — lines lie flat on the felt
  at correct angles; zoomed crop confirms the cue-ball ring sits on the
  cue ball.
Fresh-lock rendering unchanged by construction (world placement == old
local placement at identity yaw). Residual: a few-cm line-start vs
ball-center offset remains — that is the pre-existing foot-point/calibration
offset (session-state "remaining polish"), a separate issue from this
rotation bug. Package tests green (device-only RealityKit code).

## Note on the 2 unrecorded shots (recording gap)

The autonomous loop had already STOPPED when the operator took a couple of shots,
and no 5 Hz recorder was running, so the mid-roll ACTUAL paths were NOT
captured — only current rest positions are known from the live mirror
(cue ball ~(-0.04, 0.31); red near the bottom-right corner in frames).
Predicted-vs-actual for those shots is lost. FIX FOR NEXT TIME: leave a
background state recorder running whenever Chris is at the table, or have
him say "shooting now" so a recorder is armed first.

## Shot session (2026-07-23) — 4 shots, two code findings

Recorded 4 shots at ~5 Hz over the mirror. Detail:
`2026-07-23-shot-tracking-evidence.txt`.

**FINDING 1 — the detector is blind to a ball at shot speed (blocks T1.1
path capture).** Every shot is a start-rest → end-rest TELEPORT with zero
mid-flight samples. Raw detections during flight show only the stationary
object ball / stick — never the moving cue ball along its path. At ~5-9 Hz
detection with motion blur on black cloth, a ball moving ~0.3-0.4 m per
frame is simply never detected in transit. CONSEQUENCE: predicted-vs-ACTUAL
*path* (and thus cushion-by-cushion bank validation) cannot be captured
this way regardless of tracker tuning — it is gated on detection speed
(the ANE/model work, T1.3) or on shooting at lag speed so the ball stays
detectable. Only start/end rest positions are recoverable at shot speed.

**FINDING 2 — phantom track lingers at the shot origin (~3.5 s).** When the
cue ball is struck it reappears as a NEW track at the destination while the
ORIGINAL track stays frozen at the origin — two "cue balls" for ~3.5 s
(shot 1: origin (-0.27,-0.03) held from t=21.4 to t=25.0 while the real
ball rested at (-0.83,0.55)). Cause: the tracker's competition-absorption
(`BallTracker.update`) only retires a far duplicate when the winning track
is within `gatingDistance` (0.08 m); a shot puts the new track ~0.8 m away,
so the old one instead coasts for `disappearanceFrames` (30 ≈ 3.5 s) as an
in-view unobserved track. On device this shows a phantom ring (and a stale
prediction line) at the origin after every firm shot.

DECISION: Finding 2 is a real, fixable tracker bug, but the fix (faster
retirement of a track whose neighborhood is provably empty, WITHOUT
regressing occlusion robustness or the existing phantom-twin/overlap
merges) is a nuanced change to a carefully-tuned multi-mechanism tracker.
Per the project's own tracker-tuning caution and the M2-05 replay-suite
plan, it should be done deliberately with a replay TEST built from a
captured fixture (assert: no track persists >~1 s at a position the ball
has demonstrably left), not hot-patched. Queued as a task with this repro.
Finding 1 reinforces prioritizing T1.3 (on-device detection speed).
