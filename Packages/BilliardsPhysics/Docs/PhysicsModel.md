# BilliardsPhysics — MVP model derivation

All quantities are table-space 2D (meters, m/s). Config values live in
`PhysicsConfig`; defaults are empirical MVP choices, tuned later against
device footage (M5).

## Rolling

Constant deceleration `a = rollingDeceleration`:

- stop distance from speed `v`: `d = v² / 2a`
- speed after distance `s`: `v' = √(v² − 2as)`

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

## Cushions

The ball center reflects off the playing-field rectangle inset by the ball
radius. The normal velocity component reverses scaled by
`cushionRestitution`; the tangential component is preserved:

`v_out = v_in − n·(v_in·n)·(1 + e)`

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
