# 10 — Physics & Real-World Accuracy Plan

Goal: **solid, defensible physics and geometry** — every constant sourced,
every model choice documented, every claim pinned by a test, and the whole
chain validated against the real table through the debug mirror and captured
fixtures. Drafted 2026-07-22 after the first table sessions surfaced
jumping/short/missing ricochet lines; the P0 items below landed the same day.

Grounding sources: Dr. Dave Alciatore's pool physics corpus
(billiards.colostate.edu / drdavepoolinfo.com), Mathavan et al. 2010
(*A theoretical analysis of billiard ball dynamics under cushion impacts*),
the pooltool simulator's theory notes (ekiefl.github.io), WPA equipment
specs, and the earlier POOL-AID project report kept in `docs/pool-aid.pdf`
(ghost-ball + 90°-rule shot recommendation over OpenCV detection — same
core recommendation geometry this project uses, useful as prior art for the
auto table-isolation pipeline planned in M6-06).

## Layer 0 — DONE (2026-07-22): audited baseline

- **Cushion rebound** was a perfect mirror (tangential speed fully kept):
  real banks rebound **short** of mirror. Model now: normal COR
  `cushionRestitution = 0.7` + `cushionTangentialRetention = 0.7`
  (`tanθ_out = (f/e)·tanθ_in`), both inside measured bands; retention 1.0
  reproduces the legacy mirror for regression goldens.
- **Rail-lip clamp**: a ball detected at/beyond the reflection inset could
  get a negative event distance and teleport backward — clamped, regression
  test pinned.
- **Constants sourced + band-pinned by tests**: ball radius 28.575 mm; WPA
  playing fields (9ft 2.54×1.27 / 8ft 2.34×1.17 / 7ft 1.98×0.99); effective
  rolling deceleration 0.5 m/s² (documents that it folds the unmodeled
  sliding phase into cloth roll — a pure μr≈0.01 would predict 20 m of
  travel); ball-ball transfer 0.96 reinterpreted as the (1+e)/2 fraction of
  a phenolic COR ≈ 0.92; pocket capture radii vs WPA mouth widths (corner
  must also beat the reflection-line race: > r·√5).
- **90° stun separation + ghost-ball geometry** verified exact.
- 14 new real-world tests (`RealWorldPhysicsTests.swift`), goldens
  re-derived where the cushion model changed (fixture derivations carry the
  hand math; maintainer review of those three fixtures requested).
- **Guide speed**: predictions now solve at 3.5 m/s so trajectories reach
  rails and show their ricochets (a 2 m/s lag shot dies mid-table and the
  drawn line "just stops").

## Layer 1 — Measurement truth (the real current error source)

The largest real-world error today is not the solver — it's the INPUTS.

1. **Calibration accuracy bar**: corners must be tapped at the cushion
   NOSES (playing-surface boundary), not the rail tops. Locked sizes off by
   >3 cm from a standard size skew every pocket/bank line. Add an on-screen
   hint + show the delta vs nearest standard size at lock. *(S)*
2. **Auto table detection (M6-06, now P1)**: cloth-color mask → largest
   contour → Hough/min-area rectangle → propose the 4 corners; manual
   drag stays as refinement. POOL-AID's §3.2 pipeline is the template; ours
   runs on the calibrated ARKit plane so scale is metric from day one. *(L)*
3. **Ball-position residuals**: with sphere-center projection landed, add a
   debug-mirror overlay diff — tap a ball on the mirror page, mark its true
   spot, log the residual; collect a table of residual vs distance/angle to
   quantify remaining projection bias. *(M)*
4. **M2-04/05 fixture capture + replay** (already on the board): record
   real frames + hand-labeled truth from THIS table; replay suite bars
   detection + projection jointly. *(M, device)*

## Layer 2 — Solver v2 (contract change, one PR)

Extend `SolverOptions`/solver internals — CueSyncCore contract-change PR:

1. **Rolling cue-ball follow (30° rule)** — ranked #1 visible realism gap.
   Add cue-ball state (stun fraction / natural roll) so the post-impact cue
   path bends forward off the tangent line at rolling speeds. ShotGuide
   already recommends stun/draw/follow — the solver must honor it: solve
   the predicted path FOR the recommended tip contact, not always stun.
2. **Two-phase deceleration** (slide μ≈0.2 → 2/7 natural-roll transition →
   roll μr≈0.01): replaces the effective 0.5 m/s²; speeds along early
   segments become honest, which matters once speed-sensitive cushion
   models land.
3. **Speed-dependent cushion retention/COR** (Mathavan curve shape):
   banks shorten more at speed. Config scalars become curves; calibrate
   from Layer-1 fixtures.
4. **Cut-induced throw** (μ≈0.03–0.08, ≤ ~5°): add once Layer-1 residuals
   drop under ~2° so it isn't noise-tuning.
5. Later (needs full spin state): english/side-spin + rail spin coupling,
   side-pocket jaw-angle rejection, moving-vs-moving kisses, masse/jump
   (out of 2D scope).

## Layer 3 — Continuous validation loop

- Real-world tests stay the spec: any constant change must move a band test
  or it's a typo, not a tune.
- Golden fixtures: never edit numbers without re-deriving the math in the
  fixture's `derivation` block; model changes rename fixtures whose names
  encode falsified behavior (precedent: `threeFourFiveBankFortyFiveExit` →
  `threeFourFiveBankShortExit`).
- Device loop: mirror screenshot + `/state.json` before/after each physics
  change; keep a `docs/validation/` log of observed vs predicted bank exits
  on the real table (3 canonical shots: straight pot, 45° one-cushion bank,
  two-rail kick).

## Sequencing

P0 (done) → Layer 1.1 + 1.3 (this week, small) → M2-04/05 fixtures →
Layer 2.1 contract PR (30° rule + two-phase decel together) → M6-06 auto
table detection → Layer 2.3/2.4 with fixture-fitted curves.
