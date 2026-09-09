# Ball identity: telling solids from stripes, and naming the number

**Status:** Measured spike, design proposed. Written 2026-09-09 against `main` @ `b99dc10`.
**Evidence:** `Sessions/device-20260909T014006Z` — 571 frames, on-device detector,
the owner's 8 ft table, black cloth, warm indoor light at night.
**Scope:** perception only. No `CueSyncCore` change; `BallGroup` and the ranking
that consumes this already exist in CoachKit (PR #38).

## The problem, stated

`Ball.Kind` has carried `.solid(Int)`, `.stripe(Int)` and `.eight` since M0. Nothing
ever produces them. The bundled detector emits exactly three classes —

```
{0: 'color-ball', 1: 'cue', 2: 'white-ball'}
```

(read out of `App/Resources/BallDetector.mlpackage`), where `cue` is the cue *stick*.
`Ball.Kind(classLabel:)` maps `color-ball` to `.unknown`, so every object ball on the
table is anonymous. A player cannot say "I'm on stripes", the app cannot filter a
ranking to their group, and voice commands have no vocabulary.

## What a ball actually looks like to this app

A ball is **22–36 px across** (median diameter 31.8 px at the owner's shooting
distance). Two consequences settled by looking rather than assuming:

1. **The printed number cannot be read.** At 30 px the digit is 3–4 px tall, motion
   blurred, and facing away half the time. No classifier recovers it and none should
   try.
2. **The colour is perfectly legible.** Which is sufficient, because on a standard
   set colour *is* the number:

   | hue | solid | stripe |
   |---|---|---|
   | yellow | 1 | 9 |
   | blue | 2 | 10 |
   | red | 3 | 11 |
   | purple | 4 | 12 |
   | orange | 5 | 13 |
   | green | 6 | 14 |
   | maroon | 7 | 15 |
   | black | 8 | — |

   Group + hue gives the number without reading a digit.

## Measurements

Seven real balls, hand-labelled from the recording, each sampled over 6–47 frames
during the still period (frames 0–150). Sampled as a disc at 0.75 of the ball's
projected radius; `hue` is of the mean RGB, white-balanced against the cue ball.

| ball | raw hue | white-balanced hue | verdict |
|---|---|---|---|
| purple stripe | — | **271°** | purple ✓ |
| blue solid | 25° | **233°** | blue ✓ |
| yellow solid | 34° | **38°** | yellow ✓ |
| red solid | 2° | **356°** | red ✓ |
| eight | 25° | 18°, chroma 0.01 | black ✓ |
| cue | — | neutral | white ✓ |

The raw column is the finding. **Under this room's light every ball reads as orange**
— hues bunch into 19–34° regardless of the ball's actual colour, because the
illuminant is warm and the camera does not correct for it. Blue reads as 25°. Without
white balance, hue is worthless here.

White-balancing against the cue ball fixes it completely. The cue ball is a known
white, it is already identified two ways (the detector's own `white-ball` class and
the player's tap designation), and it is in frame whenever a shot is being aimed. Its
measured RGB was `(95, 83, 76)`, giving gains `(0.87, 1.00, 1.09)`. Applying those
recovers every hue correctly, as the table shows.

**This is the load-bearing design decision: every appearance feature is measured
relative to the cue ball, never in absolute terms.**

## Two things that do not work, measured

### Absolute brightness is not a signal

The cue ball sampled at median V = 0.24. The floor behind the table sampled at
V = 0.49. A white ball in shadow is darker than a beige tile in light, so no absolute
threshold separates them. Ratios against the cue ball do.

Related: a bare "brightest connected blob in the box" segmentation picks the *rail*
rather than a dark ball. It reported the blue 2-ball as beige `(185, 158, 135)` with
chroma 0.03. Any sampler must use the ball's known projected geometry, not
image-derived saliency.

### Stripe-vs-solid does not survive a single frame

White-pixel fraction inside the disc, by ball:

| ball | white fraction |
|---|---|
| eight | 0.18 |
| cue | 0.15–0.19 |
| solid blue | 0.08–0.12 |
| stripe red | 0.05 |
| stripe purple | 0.03 |

The stripes score *below* the solids. Two causes, both real:

1. **A stripe's band is randomly oriented.** A ball can present its solid pole to the
   camera; the band is simply not visible from where the player stands.
2. **The lower half of every ball is in shadow**, so a disc sample mixes lit and
   unlit pixels and the fraction means little.

The conclusion is not "harder thresholds". It is that **stripe detection needs
temporal aggregation**: a ball rotates as it rolls, and over a few seconds a striped
ball shows its band. A per-frame verdict should not be attempted.

The eight-ball is the exception and is easy — near-zero chroma with a white number
patch is unlike anything else on the table.

## Proposed design

Three pieces, in dependency order.

### 1. `BallAppearance` — pure, in PerceptionKit

Takes a feature vector, returns a classification with a confidence. No pixels, no
platform types; testable on Linux against the vectors measured above, committed as a
fixture.

```swift
public struct BallPatch: Sendable, Codable, Equatable {
    var meanRGB: SIMD3<Double>       // linear, 0...1
    var chromaFraction: Double
    var whiteFraction: Double
    var sampleCount: Int             // low counts are not trusted
}

public struct WhiteReference: Sendable, Equatable {   // the cue ball
    var meanRGB: SIMD3<Double>
    var gains: SIMD3<Double> { ... }
}

public struct BallAppearance {
    public static func classify(_ patch: BallPatch,
                                reference: WhiteReference?) -> Observation
}

public struct Observation {
    var family: ColorFamily          // yellow/blue/red/purple/orange/green/maroon/black/white
    var confidence: Double
    var whiteFraction: Double        // handed to the aggregator, not decided here
}
```

Without a `reference` it returns low confidence rather than a guess — the measured
hue collapse is exactly why.

### 2. `BallIdentity` — temporal aggregation, in PerceptionKit

Per track id, accumulates `Observation`s and decides:

- **family** by weighted vote over the window (stable within a frame or two)
- **group** from the *maximum* white fraction seen, not the mean — one clear look at
  the band is proof of a stripe; never seeing it is not proof of a solid
- **number** = (family, group) via the table above, emitted only when both are
  confident
- ties to the existing track ids from `BallTracker`, so it survives the same way
  `CueBallIdentity` does

Reports `.unknown` freely. An unnamed ball is already handled everywhere downstream:
`BallGroup.includes` admits `.unknown` into both halves of the rack precisely so the
ranking does not go blank on a player who has picked a side.

### 3. `BallPatchSampler` — the only platform-specific piece, in the app

Samples the live pixel buffer at each tracked ball's **projected** centre and radius,
computed from the table plane and camera intrinsics the pipeline already has — the
same reprojection `SnapshotReprojectionReport` performs. Not the detector's box: the
boxes in this recording are not reliably centred on the ball, and a brightness search
for the true centre runs away to the rail.

Samples the **upper** portion of the disc, where the ball is lit.

## Verification plan

Everything except the sampler is checkable offline against recordings already on
disk. The fixture is the seven labelled balls above with their measured vectors.

Bars to hold:

- every ball's colour family correct with a `WhiteReference` present
- no ball assigned a family without one
- the eight never classified as a stripe, and no stripe ever classified as the eight
  (in eight-ball this is the difference between winning and losing)
- the floor false-positive (`white 0.15`, no chroma, V 0.49 — brighter than the cue
  ball) never classified as a ball at all

The sampler needs a device run: whether the projected centre lands on the ball is
exactly the ring-accuracy question Phase 3 of plan v5 is already chasing, and the two
should be measured together.

## Correction the player can make

The classifier will be wrong sometimes, and the design assumes it. A tap on a ball
cycles its identity, and the correction pins to the track for the rest of the
session — the same mechanism `CueBallIdentity` already uses for tap-to-designate.
Showing a dim, tappable guess beats showing a confident wrong one.

## What this does not attempt

Reading printed numbers, distinguishing two balls of the same colour when the group
is unknown, or identifying a non-standard set (the owner's measle practice cue ball
already classifies as `color-ball`, which is why tap-to-designate exists). Ball colour
conventions vary by manufacturer; the table above is the standard American set.
