## Context
A synthetic pinhole-camera harness pins the projection chain (box → sphere-centre raycast → table) with exact ground truth and no table.

## Scope
`Packages/CueSyncTestSupport` (`SyntheticCamera`, `SyntheticBallImager`, `SyntheticDetectionProvider`, `CalibrationPerturbation`; gains a TableSpace dependency — acyclic) and `Packages/PerceptionKit/Tests` (`ProjectionRoundTripTests`), plus a `synthetic-mini` bundle generator (60 frames) for the Simulator smoke.

## Out of scope
Rendering real images; detector accuracy claims; more than the four cases below.

## Acceptance
- [ ] Case 1: silhouette-box-centre vs projected sphere centre bias documented in a table (off-axis, second order).
- [ ] Case 2: rail-top corners (+4 cm) ⇒ field +8 cm, error ≈ 1.7 % of distance from centre, `TableSize.inferred` still snaps at 8 %.
- [ ] Case 3: intrinsics/resolution/orientation mismatch ⇒ error > 10 cm caught.
- [ ] Case 4: elevation < 7° returns nil.

## Verification
verify:synthetic — all four cases green on Linux; ideal round trip ≤ 2 mm at ≤ 3 m.

## Device follow-up
none.
