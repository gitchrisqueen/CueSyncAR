# BilliardsPhysics — MVP model derivation

All quantities are table-space 2D (meters, m/s). Config values live in
`PhysicsConfig`; defaults are grounded against published pool physics
(references below), tuned later against device footage (M5).

References: D. Alciatore, *The Illustrated Principles of Pool and
Billiards* + technical proofs at billiards.colostate.edu; Mathavan,
Jackson & Parkin, "A theoretical analysis of billiard ball dynamics under
cushion impacts" (Proc. IMechE Part C, 2010); WPA/BCA equipment specs.
`RealWorldPhysicsTests` pins every constant to these bands.

## Rolling

Constant deceleration `a = rollingDeceleration`:

- stop distance from speed `v`: `d = v² / 2a`
- speed after distance `s`: `v' = √(v² − 2as)`

`a` is an **effective** value, deliberately above the ~0.1 m/s² of pure
rolling resistance (μr ≈ 0.01): the MVP has no sliding phase (real shots
start sliding at μ ≈ 0.2 → ~2 m/s² until natural roll takes over — the 2/7
rule) and no rail/collision cloth losses, so one constant absorbs them.
0.1 m/s² would send a 2 m/s ball 20 m (four 9-ft tables) — visibly wrong;
the default 0.5 m/s² stops it at 4 m (~1.6 table lengths), matching how a
firm lag-speed shot actually dies. Defensible band: 0.25–0.6 m/s².

## Ball–ball impact (ghost ball)

Sweep the moving ball's center along its ray; contact occurs when the center
is `r₁ + r₂` from a stationary ball's center (the *ghost-ball* position `G`).
For equal-mass, friction-free spheres:

- impact line `n = (P_struck − G) / ‖·‖`
- `cosθ = d̂ · n` (cut angle θ)
- struck ball: direction `n`, speed `v·cosθ·ballBallRestitution`
- moving ball: direction along the tangent `d̂ − n·cosθ` (⊥ `n`),
  speed `v·sinθ` — the stun model; follow/draw are post-MVP.

A head-on hit (`sinθ = 0`) stops the moving ball at `G`.

`ballBallRestitution` is the **normal-speed transfer fraction**
`(1 + e)/2` for true ball-ball COR `e`: phenolic balls measure
e ≈ 0.92–0.96, giving a transfer of 0.96–0.98 (default 0.96 ⇔ e = 0.92).
The cue ball's residual normal component `(1 − e)/2 · v·cosθ` (≈ 2%) is
dropped — the cue ball leaves exactly on the tangent line.

Knowingly omitted (post-MVP, needs new solver contracts):

- **90°/30° rules:** the tangent-line departure is exact only for a
  *sliding* (stun) cue ball. A naturally **rolling** cue ball bends
  forward off the tangent line, deflecting ~30° from its original path at
  typical cut angles. The MVP always predicts stun; `ShotGuide`
  compensates by recommending a stun strike on near-straight shots.
- **Throw:** ball-ball friction (μ ≈ 0.03–0.08) deflects the object ball
  up to ~3–5° off the impact line on cut shots ("cut-induced throw").
  Unmodeled; at AR-overlay scale this is below current calibration noise.

## Cushions

The ball center reflects off the playing-field rectangle inset by the ball
radius. The normal velocity component reverses scaled by the effective
cushion COR `e = cushionRestitution` (real rails: ~0.6–0.85 at play
speeds); the tangential component is scaled by the retention factor
`f = cushionTangentialRetention` (rail/cloth friction, ~0.7–0.9):

`v_out = f·(v_in − n·(v_in·n)) − e·n·(v_in·n)`

Rebound angle measured from the rail **normal**: `tanθ_out = (f/e)·tanθ_in`.
With the defaults (f = 0.7 < e = 0.75) the rebound comes off ~2° steeper
than the mirror at 45° — real **banks play short** (Alciatore). `f = 1`
restores the ideal mirror model (used by one golden fixture as a knob
regression). Speed-dependent shortening and the topspin change from the
cushion-nose contact height above ball center are post-MVP.

A ball whose detected center already sits at/beyond the reflection line
while moving outward (frozen on the rail, pocket jaws) bounces immediately
at its current position — the event distance clamps at zero so the solver
never teleports a ball backward along its ray.

## Pockets

A pocket is a capture circle at the mouth center. A moving ball whose center
enters the circle is pocketed. The corner radius (0.075) intentionally
exceeds `r·√5 ≈ 0.064`: a ball aimed exactly at the corner crosses the
cushion-reflection inset line when it is `r·√5` from the corner point, and
capture must win that race (the real mouth center sits outside the rail
rectangle in the jaw, which a single in-rectangle circle under-approximates).

Known simplification: a ball rolling flush along a rail through a side-pocket
mouth is captured; real jaws sometimes reject these. Revisit with jaw-angle
modeling post-MVP.

## Event loop

Balls are rolled out sequentially from a queue (cue first; struck balls are
appended). Each rollout repeatedly finds the earliest of {ball hit, pocket
capture, cushion crossing} within the remaining stop distance, applies it,
and continues until rest, capture, or the shared `maxEvents` budget is
exhausted. Balls at rest re-enter the static snapshot so later rollouts
collide with their *predicted* positions.

Simplification: moving-vs-moving collisions are not modeled — each rollout
sees a static world. Fine for coaching visuals; revisit if combination shots
need accurate secondary kisses.
