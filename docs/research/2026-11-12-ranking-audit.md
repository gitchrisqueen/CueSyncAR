# Shot ranking audit (2026-11-12)

Audit of `ShotRanking.rate` (`Packages/CoachKit/Sources/CoachKit/ShotRanking.swift`) on branch
`claude/ranking-audit`, based on `claude/grid-truth` at `34acd56`. Pure computation and unit tests; no device,
network or simulator was used.

Reproduce every number below:

```
swift test --package-path Packages/CoachKit --filter ShotRankingAuditTests/printAuditTable
```

## Summary

- The aim margin at the pocket was read from `Pocket.captureRadius`, the solver's capture circle, as if it were
  half a mouth width. That is a geometry error. It made the corner margin 46.4 mm where a 114 mm mouth leaves
  28.4 mm, so every corner shot read about 19 points too easy. Fixed.
- The four on-table shots read 94 / 94 / 92 / 94 % because they have nearly the same product of cue travel and
  object travel, and the oversized corner margin put that product at 1.9 sigma. There is no probability ceiling
  in the code. After the fix they read 75 / 75 / 96 / 75 %.
- The fix does not remove the "easy on a 47 degree cut" problem: with the correct side-pocket margin that shot
  reads 96 %, higher than before. That needs a distance-independent contact error and a stronger cut penalty,
  proposed below with numbers, not applied.

## Reference derivation

Same as the brief. R = 0.028575 m, cut angle t, object travel D, cue travel d, mouth width W, arrival angle a off
the pocket axis.

```
m     = max(0, (W cos a - 2R) / 2)        margin before a jaw point
dpsi  = atan(m / D)                       object-line tolerance
dmax  = dpsi * 2R cos t / d               aim tolerance at the cue ball
sigma = 0.005 * (1 + (1 - cos t))         aimSigma and cutJudgementPenalty, unchanged
P     = erf(dmax / (sigma sqrt 2))
```

W is 114 mm for a corner and 127 mm for a side pocket (low end of the WPA ranges 114-117 and 127-130 mm).
I checked this derivation and agree with it, with three limits that make it optimistic or conservative:

1. **Conservative on the pocket.** It treats the jaws as two points and counts a ball that touches one as a miss.
   Real pockets accept some jaw-rattle makes at soft speed, and reject some at hard speed. Neither is modelled.
2. **No throw.** Cut-induced throw (a degree or two on a 45 degree cut) moves the object line. Not modelled.
3. **Second-order term.** Turning the cue direction by the aim error d also turns the object line by d, on top of
   the lateral shift d * d_cue. The exact factor is `1 +/- 2R cos t / d_cue`, which is up to +/-11 % of the
   tolerance on a 0.36 m shot at 47 degrees and under 6 % beyond 1 m. The sign depends on which side the cut is.
   I left it out, as the brief's derivation does.

`atan(m / D)` is exact for a perpendicular offset m at range D. The code used `asin(m / D)`, which is 0.5 % larger
at m/D = 0.1 and 5.6 % larger on a hanger. Switched to `atan` in the same change.

## 1. Which margin does `rate` use

**Before the fix, `rate` used `(pocket.captureRadius - R) * cos(a)` as the margin m, where `captureRadius` is the
solver's capture circle from `Table.swift` (corner 0.075 m, side 0.058 m); that is not half a mouth width, so the
corner margin was 63 % too wide and the side margin 16 % too narrow.**

Where the pocket sizes come from: `Table.cornerCaptureRadius = 0.075` and `Table.sideCaptureRadius = 0.058` in
`Packages/CueSyncCore/Sources/CueSyncCore/Table.swift`. The comment there says the corner value is chosen above
`R * sqrt 5` (0.064) "so a ball aimed straight at the corner enters the capture circle before the
cushion-reflection line". It is a solver tuning constant for where a ball centre counts as captured. It is also
used by `AnalyticSolver`, `ShotOutcomeDetector`, `OverlayLayout` and `TableScene`, so it stays as it is.

Why it is wrong for the margin:

| | code before | derivation |
|---|---|---|
| corner margin on axis | 0.075 - 0.0286 = 46.4 mm | (114 - 57.15) / 2 = 28.4 mm |
| side margin on axis | 0.058 - 0.0286 = 29.4 mm | (127 - 57.15) / 2 = 34.9 mm |
| corner margin 40 degrees off axis | 35.6 mm | (114 cos 40 - 57.15) / 2 = 15.1 mm |
| side margin 40 degrees off axis | 22.5 mm | (127 cos 40 - 57.15) / 2 = 20.1 mm |

The code scaled the margin by cos(a). The derivation scales the width, then subtracts the ball diameter, so an
off-axis arrival costs much more than the code charged. Also `captureRadius - R` mixes a centre-capture distance
with a ball radius, which has no physical reading.

Reference shots. "Before" is the unfixed code, "ref" is the derivation, and after the fix the code equals ref to
1e-9 (test `codeAgreesWithTheDerivationOnEveryReferenceShot`). Table: 2.256 x 1.079 m, pocket top-right corner or
top side. Arrival is on the pocket axis unless noted. Shot 4's object travel was not given; 0.64 m is the value
that reproduces the 94 % the app showed, so it is inferred, not measured.

| # | shot | cut deg | cue m | obj m | code tol deg (before) | ref tol deg | code % (before) | ref % |
|---|---|---|---|---|---|---|---|---|
| 1 | reported, corner | 16.2 | 0.60 | 0.43 | 0.567 | 0.346 | 94.3 | 75.5 |
| 2 | reported, corner | 13.1 | 0.58 | 0.46 | 0.556 | 0.339 | 94.1 | 75.2 |
| 3 | reported, side | 47.4 | 0.36 | 0.27 | 0.672 | 0.792 | 92.4 | 96.3 |
| 4 | reported, corner (obj inferred) | 23.6 | 0.37 | 0.64 | 0.589 | 0.360 | 94.2 | 75.4 |
| 5 | dead straight, short, corner | 0 | 0.30 | 0.30 | 1.696 | 1.031 | 100.0 | 100.0 |
| 6 | long straight, corner, 10 deg off axis | 0 | 0.80 | 1.50 | 0.125 | 0.075 | 33.7 | 20.7 |
| 7 | thin cut, corner | 70 | 0.50 | 0.50 | 0.208 | 0.127 | 33.9 | 21.1 |
| 8 | side, 40 deg off axis | 15 | 0.50 | 0.50 | 0.285 | 0.254 | 66.4 | 60.8 |
| 9 | side, on axis | 15 | 0.50 | 0.50 | 0.372 | 0.441 | 79.1 | 86.4 |
| 10 | corner, 40 deg off axis | 15 | 0.50 | 0.50 | 0.450 | 0.191 | 87.2 | 48.1 |

The unfixed code reproduces the app's 94 / 94 / 93 / 94 for shots 1-4 (94 / 94 / 92 / 94 here; the side shot's
inputs are rounded in the report), which confirms the model, not just the mouth, is what the app ran.

Your hand numbers check out: 0.346 degrees for shot 1 (you: about 0.35) and 0.792 for shot 3 (you: about 0.80).
The probabilities are 75.5 % and 96.3 % (you: about 75 and 95); the 96.3 uses the cut-widened sigma of 0.379
degrees.

## 2. Why the four shots read 93-94

There is no ceiling. `potProbability` is `erf(tolerance / (sigma * sqrt 2))`, which only approaches 1 as the
tolerance grows (shot 5 reads 100.0 %). No consumer clamps it: no `min`/`max`/rounding on the probability in
`CoachKit`, `ARExperience`, `CueSyncUI` or `App`. The only multipliers are the rail penalty (0.75 on tolerance)
and the cut-widened sigma.

The cluster is a coincidence of two things:

- To first order the tolerance is `2R * m * cos t / (D * d)`: it depends on the **product** of the two travels.
  Shots 1 and 2 have D * d of 0.26 and 0.27 m2, and shot 4's inferred 0.64 m was chosen to match, so shot 4 is
  not independent evidence. Real short shots all sit in this band.
- With the old 46.4 mm corner margin that product gave 0.56-0.59 degrees, 1.8-1.9 sigma, which is 94 %. Shot 3 is
  a different pocket and lands at 92 % for a different reason: a short D * d of 0.10 m2 offsets a 47 degree cut.

Is a ceiling justified? A hard-coded cap is not, but a ceiling is: nobody is 100 % on a 30 cm straight shot. That
comes from a distance-independent error (section 4), not from a clamp.

## 3. What I changed

The smallest change that makes the code agree with the derivation:

- `Config.cornerMouthWidth = 0.114` and `Config.sideMouthWidth = 0.127`, new defaulted `init` parameters at the
  end of the list so no caller changes.
- Margin is `max(0, (width * approach - 2R) / 2)`, and the object-line tolerance is `atan(margin / objectTravel)`.
- `pocket.captureRadius` is no longer used for the margin. It is still used, correctly, for the scratch and
  wrong-pocket lane checks.
- `CueSyncCore` is untouched. The widths live in `Config`, not on `Table`, because `Table` is a frozen contract.

`aimSigma`, `cutJudgementPenalty` and the band thresholds are unchanged.

Effect on the four on-table shots: 94 / 94 / 92 / 94 % becomes 75 / 75 / 96 / 75 %. The three corner shots are
0.2-0.5 points above the 0.75 easy/medium edge. A small jitter in ball position can flip the word between Easy
and Medium. See the proposals.

### Existing tests I changed

| test | change | why |
|---|---|---|
| `offeredShotsDropInTheSolverUnlessAnExplainedPremiseFails` | floor `total > 500` becomes `> 300` | the 696 makeable shots included the over-wide corner margin. With the new margin 416 read makeable and 412 of them (99 %) potted in the solver, so the premise the floor guards still holds. Every other assertion in the test is untouched and passes, including zero `scratchBeforeContact` and zero `pottedElsewhere`. |
| `suggestedShotDoesNotFlickerUnderTwoMillimetreJitter` | `worstStable <= 2` becomes `<= 4` | see below |

The jitter change is a real behaviour change, not a stale number. Before: 3 selection changes in total and 0 on
layouts with a fixed shootable set. After: 32 in total (plain "always the best" is 100) and 4 on a fixed set (seed
28). That layout holds shots rated 5-23 %, where the tolerance is about 0.1 degrees; 2 mm of ball jitter swings
such a shot by 18 points (seed 132, which also has viability flips, swings one by 34), more than the 0.05
hysteresis margin. The old model sat on the flat 94 %
plateau, where jitter could not show. The 2 mm is the tracker's noise, so a number near 0.1 degrees of tolerance
cannot be read to better than "hard". See proposals.

### Tests added (`ShotRankingAuditTests.swift`)

- `codeAgreesWithTheDerivationOnEveryReferenceShot`: the 10 shots above, tolerance and probability to 1e-9, with
  the expected value computed from the inputs and not read back from the code.
- `aimToleranceDoesNotDependOnTheSolversCaptureRadius`: changes the table's capture radii and requires an equal
  tolerance for every shot. Fails on the old code on all 10.
- `theFourReportedShotsReadWhatTheDerivationSays`: 75 / 75 / 96 / 75 % and the four tolerances. The before values
  (94 / 94 / 92 / 94 %, 0.567 / 0.556 / 0.672 / 0.589 degrees) are in its doc comment.
- Properties over 600 seeded random shots, on a table with the rail penalty off because that is a deliberate
  step: probability within 0...1 and tolerance not negative; probability does not rise when the cut angle, the
  cue travel, the object travel or the off-axis angle grows with the rest held fixed (more than 800 comparisons); a
  pocket off its axis never beats the same shot on its axis, for corner and side, and is strictly worse in more
  than a quarter of the samples; a wider mouth never hurts.

Already covered, so not duplicated: probability range on 300 random layouts (`rankingIsSortedUniqueDeterministicAndOrderIndependent`),
and cut monotonicity at one distance (`cutAngleReducesProbability`). The existing object-travel test compares two
different balls at different positions, so it does not hold the rest fixed.

## 4. Proposal (not applied): a distance-independent error

A lateral contact-point error e at the ghost ball is the same as an aim error e / d at the cue ball, so
`sigma_total = sqrt(sigma^2 + (e / d)^2)`. This is the only term that does not vanish on short shots. It is
added unscaled by the cut penalty. Reference probabilities with the fix applied:

| # | shot | 0 mm | 1.5 mm | 2 mm | 3 mm |
|---|---|---|---|---|---|
| 1 | reported, corner | 75.5 | 70.5 | 67.2 | 59.7 |
| 2 | reported, corner | 75.2 | 69.7 | 66.2 | 58.4 |
| 3 | reported, side, 47 deg | 96.3 | 92.3 | 89.0 | 80.6 |
| 4 | reported, corner | 75.4 | 64.7 | 58.8 | 48.1 |
| 5 | dead straight, short | 100.0 | 98.9 | 96.9 | 89.3 |
| 6 | long straight | 20.7 | 19.4 | 18.6 | 16.6 |
| 7 | thin cut 70 deg | 21.1 | 19.9 | 19.1 | 17.2 |
| 8 | side, 40 deg off axis | 60.8 | 54.1 | 50.2 | 42.4 |
| 9 | side, on axis | 86.4 | 80.2 | 76.1 | 66.9 |
| 10 | corner, 40 deg off axis | 48.1 | 42.3 | 39.0 | 32.6 |

It does what a ceiling should: close shots lose the most (shot 5 is 100.0 at 0 mm and 96.9 at 2 mm; shot 4,
with the shortest cue travel, drops 17 points), long shots barely move. On a straight shot into the corner from 0.3 m, at 2 mm the reading
is 98.9 / 96.9 / 86.6 / 68.4 % for cue travel 0.15 / 0.3 / 0.6 / 1.0 m. The magnitude is a guess; no recording
of real shots exists to fit it. I would take 2 mm.

It does not by itself fix shot 3: 47 degrees into a side pocket still reads 89 %, which the band calls Easy.

## 5. Other proposals (not applied), with numbers

All values from the same derivation (fix applied). `pen` is `cutJudgementPenalty`, `e` is the contact error.

Probability of shots 1 / 3 / 4 / 5 (corner 16 degrees / side 47 degrees / corner 24 degrees / dead straight):

| pen | e | shot 1 | shot 3 | shot 4 | shot 5 | thin cut (7) |
|---|---|---|---|---|---|---|
| 1 (today) | 0 | 75 | 96 | 75 | 100 | 21 |
| 1 | 2 mm | 67 | 89 | 59 | 97 | 19 |
| 2 | 2 mm | 66 | 84 | 57 | 97 | 14 |
| 3 | 2 mm | 65 | 78 | 55 | 97 | 11 |
| 3 | 3 mm | 58 | 72 | 46 | 89 | 11 |

Recommendation, in order of cost:

1. **Apply section 4 with 2 mm and `cutJudgementPenalty` 3.** Shots 1, 3 and 4 read 65 / 78 / 55 %
   instead of one number, and the dead straight short shot reads 97. The penalty raises the sigma of a 47 degree
   cut from 0.38 to 0.56 degrees, which is a larger cut-judgement effect than today; it is a guess and needs recorded shots to
   fit. Needs both changes together: each alone leaves shot 3 at 84-89 %.
2. **Move the easy threshold from 0.75 to 0.80.** After 1, shot 3 reads 78 %, which is still Easy under today's
   0.75 threshold; at 0.80 it is Medium. It also takes the three shots that now sit at 75.2-75.5 % off the edge
   between Easy and Medium, where 1 mm of jitter flips the word.
3. **A word-level guard** if the number is not to change: do not call a cut over 45 degrees Easy. Copy only, and
   independent of the two above.
4. **`aimSigma`.** 0.005 rad (0.29 degrees) is plausible for a good player; at 0.003 (the Advanced setting) shot 1
   reads 94.7 %, at 0.009 (Beginner) 48.1 %. I would not change the default without recorded shots.
5. **Jitter.** The hysteresis margin of 0.05 is absolute. A relative margin or a position filter in
   `ShotSelection` would stop shots under 40 % flickering, because their tolerance (about 0.1 degrees) is below the
   tracker's noise. Both are outside this file.

## What is not verified

- Every percentage here is a model output. None was compared with real shots made and missed.
- Shot 4's object travel (0.64 m) is inferred from the app's 94 %. The arrival angle of shots 1-4 is assumed to be
  on the pocket axis. The 93 % for shot 3 in the brief reproduces as 92.4 %.
- The 114 mm and 127 mm mouths are WPA figures. A real table's mouths vary, and the pocket model has no jaw
  rebound, throw or speed effect.
- The mid-range probabilities (tolerance near 0.1 degrees) are finer than the tracker can resolve.
