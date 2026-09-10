# CueSync AR — handover

**Written 2026-09-10, at `main` @ the merge of #129. This is the state the
project was left in, what is actually true about it, and what the next
person should do first.**

Read this before `docs/roadmap/`. The roadmap describes a plan; this
describes reality.

---

## What it is

An iOS augmented-reality billiards coach. Point an iPhone or iPad at a
pool table, calibrate it, and the app tracks the balls and draws the aim
line, the ghost ball and the pocket it would go in.

Swift 6 strict concurrency, SwiftUI, ARKit + RealityKit, Core ML/Vision
on device. Eleven local SwiftPM packages hold the real code; `App/` is a
thin shell that wires them together. The `.xcodeproj` is generated from
`project.yml` by XcodeGen and is gitignored.

**26,051 lines of source against 16,046 lines of tests. 874 package tests
pass on Linux and macOS.** The pure core — physics, calibration geometry,
tracking, replay — has no device dependencies and is where most of the
value is.

---

## Where it actually stands

### Works, and has been measured

| | evidence |
|---|---|
| **Calibration from four taps** | 5–8 mm rms on the owner's 8 ft table, driven remotely over the debug mirror. Locks at 2.34 × 1.17 m, reported as *"8 ft +1.0 cm"* |
| **Cloth height from tap geometry** | Two independent pocket pairs agreed to 1.5 mm |
| **Relocalizing a saved table** | ~2 s on three consecutive relaunches (2026-07-23) |
| **Aim line engaging off the cue stick** | 86 % duty cycle after the hold fix |
| **Ball tracking identity** | churn 6 → 0 and 11 → 7 on the two committed device recordings |
| **Frame gate** | 57–58 % of frames skipped on a static table with no loss of responsiveness |
| **Camera** | 60 fps, thermal nominal, on `iPad12,1` |

### Known not to work, measured rather than assumed

- **The detector is blind at shot speed.** Every recorded shot is a
  rest→rest teleport with zero mid-flight samples. This is a *documented
  negative result*, and Phase F's whole architecture is built around it
  (score from rest transitions, never from seeing the ball move).
- **The cue ball is identified in only 41 % of frames.** This is the
  binding constraint on shot detection, not the shot detector itself.
- **Guide availability is 42 % of aimed frames.** The aim line is off
  screen more often than on. Nothing gates on it. `StabilityReport.swift`
  already computes the number.
- **Overlay accuracy has no real-data number.** Only the two *synthetic*
  fixtures carry `truth.json`. Nothing has ever been tape-measured.
- **The bundled Core ML model runs CPU-only** on iOS 26 — the mlprogram
  export crashes MPSGraph on GPU/ANE. Re-export recipe is in
  `09-SESSION-STATE.md`.
- **TV output does not exist in the app.** `DisplayKit` is a real package
  and is referenced by **zero lines** of `App/Sources`.
- **There is no onboarding.** Blank launch screen, then "Point at the
  table", and you have to know what a cushion nose is.
- **Nothing accumulates.** No shot record, no session summary, no
  make-percentage. There is no reason to open the app twice.
- **It has never run on an iPhone.** `00-OVERVIEW.md:34` names a physical
  iPhone as the MVP platform; every artifact in the repo is `iPad12,1`.

---

## Four things that will surprise you

These cost days to find. They are in the code comments too, but they are
the ones worth knowing before you start.

### 1. The cloth height is solved, not measured

The obvious way to find the playing surface is to measure it from the
balls: a ball is a sphere of known size, so its silhouette gives its
range. That was the design, and it is **not accurate enough**, in a way
that hides itself.

Measured on one table in one session, the ball estimator reported:

```
-0.349    -0.370    -0.512    -0.229      (truth: -0.528)
```

283 mm of range, settling 158 mm wrong, while reporting 8–15 mm of
"spread" throughout. Spread measures whether the balls agree with *each
other*; the error is systematic — at 2.4–4 m a ball is ~16 px across, so
one pixel of box error is 6 % of range and 3 cm of cloth. Every sample
moves together. **Adding balls tightens the spread and does not touch the
error.**

The height never needed measuring. It is determined by the tap rays
(exact) and the table size (the user picks it): rays from one place fan
out, so exactly one depth cuts a 2.34 × 1.17 m shape out of them. See
`Packages/TableSpace/Sources/TableSpace/ClothHeightFromPockets.swift`.

### 2. Pocket geometry cannot tell you the table size

Every standard table is exactly 2:1 — 1.98×0.99, 2.34×1.17, 2.54×1.27.
So a nine-foot table's pockets are a **uniform scaling** of an eight-foot
table's, and moving the plane is exactly a uniform scaling. Solving for
the wrong size fits *perfectly*, at a proportionally wrong height, with a
residual of zero.

The residual checks the shape, and the shape is right either way. The
crude ball estimate is the only measurement in the app independent of
that choice, which is now the single thing it is asked for.

This is why the verification overlay matters: it draws the eighteen
diamonds, which are geometry the fit never used.

### 3. A protocol extension is not a protocol requirement

The pipeline holds `any PlaneRaycasting`. A method that exists only in a
protocol *extension* dispatches **statically** to the default through that
existential. The height-aware raycast was silently never called — every
ball landed ~4 cm toward the camera — until it became a requirement.

Any capability a conformer overrides must be a protocol requirement.

### 4. ARKit's world origin resets every launch

It is the device pose at session start. A world-space number measured in
one session means nothing in the next. This invalidated a measurement
mid-session during the calibration work and is easy to repeat.

Also: ARKit's plane *detection* needs parallax, and a device parked beside
a table never provides any. `searchingPlane` can persist forever with the
table filling the frame. Every path that needs a plane must have a way
through without one.

---

## What to do first

Ranked by value per hour, not by phase order.

### 1. Fix the replay-smoke workflow (5 minutes, owner)

**[PR #117](https://github.com/gitchrisqueen/CueSyncAR/pull/117) is
finished and blocked on two lines.** It adds the app target's first UI
tests. Adding them flips `verify-sim.yml` into a branch that has never
executed and does not work:

```
xcodebuild: error: invalid option '-ReplayBundle'
```

The workflow hands the app's launch arguments to `xcodebuild`, which
exits 64 before a test runs. The fix is in the PR body verbatim. The test
half is already merged into that branch and verified 4/4 across four
local runs.

`.github/**` is owner-only per `CLAUDE.md`, which is why this is here and
not done.

### 2. Take the table trip ("Session Zero")

**This blocks more than anything else in the repo** — F12, G1, G3, G4 and
every accuracy number the project could claim. One evening:

1. **One tape-measured static layout** → `truth.json`, committed as a
   fixture → the first real `AccuracyReport` this project has ever had.
2. **~30 marked shots**: 10 makes, 5 misses, 5 scratches, 5 with a hand
   reaching in, 5 re-racks. Zero real shots exist in any bundle.
3. Two lighting conditions, one walked-perimeter pass, one cue-in-hand
   pass.

Truth cannot be retro-fitted to the existing fixtures — those balls are
long gone.

### 3. Look at the verification overlay on a real table

[#129](https://github.com/gitchrisqueen/CueSyncAR/pull/129) draws the
eighteen diamonds derived from the candidate calibration. Nobody has seen
it. `/frame.jpg` is an ARView snapshot with no SwiftUI in it, so it
cannot be photographed remotely.

If the diamonds line up, the calibration is verified by something no
number in the app can verify. If they do not, that is the most valuable
bug report the project could receive.

### 4. Then Phase F — guided drills

The research says twice that tracker-scored drills, not the aim line, are
the commercial wedge. Bullseye Billiards charges $69.99/yr and makes
users log positions *by hand*. A drill that scores itself is a product.

12 issues, [#79](https://github.com/gitchrisqueen/CueSyncAR/issues/79)–[#90](https://github.com/gitchrisqueen/CueSyncAR/issues/90), ordered by perception risk, lowest first. Two
measured constraints are load-bearing and are written into the issues:
score from rest transitions only, and `moveThreshold` must be ≥ 0.10 m
because a ball that never moved produced a 4.9 cm excursion.

---

## Everything still open

40 issues, labelled. `agent-ready` means a competent developer can finish
it alone; `needs-table` means it cannot be done without standing at one;
`needs-chris` means it needs the repo owner's accounts or permissions.

| phase | issues | state |
|---|---|---|
| **B** — gates that assert something | [#63](https://github.com/gitchrisqueen/CueSyncAR/issues/63), [#64](https://github.com/gitchrisqueen/CueSyncAR/issues/64), [#65](https://github.com/gitchrisqueen/CueSyncAR/issues/65) | #64 is PR #117, blocked above |
| **C** — product shell | [#72](https://github.com/gitchrisqueen/CueSyncAR/issues/72), [#74](https://github.com/gitchrisqueen/CueSyncAR/issues/74)–[#77](https://github.com/gitchrisqueen/CueSyncAR/issues/77) | #73 and #78 are done |
| **D** — automatic table detection | [#91](https://github.com/gitchrisqueen/CueSyncAR/issues/91)–[#93](https://github.com/gitchrisqueen/CueSyncAR/issues/93) | not started |
| **E** — TV output | [#94](https://github.com/gitchrisqueen/CueSyncAR/issues/94)–[#99](https://github.com/gitchrisqueen/CueSyncAR/issues/99) | not started |
| **F** — guided drills | [#79](https://github.com/gitchrisqueen/CueSyncAR/issues/79)–[#90](https://github.com/gitchrisqueen/CueSyncAR/issues/90) | not started; the wedge |
| **G** — device verification | [#100](https://github.com/gitchrisqueen/CueSyncAR/issues/100)–[#104](https://github.com/gitchrisqueen/CueSyncAR/issues/104) | all need a table |
| **H** — tell the truth about it | [#105](https://github.com/gitchrisqueen/CueSyncAR/issues/105)–[#108](https://github.com/gitchrisqueen/CueSyncAR/issues/108) | this document is part of #105 |

### Needs the owner specifically

- **Rotate the Roboflow API key.** A key leaked into a build manifest
  during this work. The branch was abandoned and the commit closed, but
  `refs/pull/112/head` still resolves, so **the key must be treated as
  public**. This is outstanding and is the only item here with a security
  consequence.
- App Store Connect, signing and a privacy manifest, for the TestFlight
  build ([#108](https://github.com/gitchrisqueen/CueSyncAR/issues/108))
- Applying the branch ruleset ([#65](https://github.com/gitchrisqueen/CueSyncAR/issues/65)) — repo-admin; the JSON edit alone changes nothing
- The public site going live ([#107](https://github.com/gitchrisqueen/CueSyncAR/issues/107))
- Deleting the `detector-parity` job ([#63](https://github.com/gitchrisqueen/CueSyncAR/issues/63)) — it needs pixels the repo does not have and has never run

---

## How to work on it

```bash
Scripts/bootstrap.sh          # XcodeGen, then open CueSyncAR.xcodeproj
Scripts/test-all.sh           # every package, any OS with Swift 6.1+
swift test --package-path Packages/TableSpace
```

CI must stay green: package tests on Linux and macOS, SwiftLint, gitleaks,
an iOS Simulator build, and the golden replay.

### Iterating without a table

**`Packages/SessionReplay` is the point.** A recorded session bundle
(frames, detections, events, calibration, truth) replays through the real
pipeline → `ShotPlanner` → solver on any platform:

```bash
swift test --package-path Packages/SessionReplay --filter Golden
```

Judge every perception, tracking or physics change against it *before*
anyone stands at a table. Regenerate goldens only deliberately
(`CUESYNC_REGENERATE_FIXTURES=1`) and explain the diff in the PR.

### Driving a device you cannot see

Turn on the debug mirror (⋯ → Debug mirror, or Settings → Developer). It
serves the rendered screen and tracking JSON on port 8787 to any browser
on the LAN:

- `/state.json` — everything the app knows, including `lastTapNote` and
  `lastProbe`
- `/frame.jpg` — the ARView snapshot. **Contains no SwiftUI**, so no
  overlay, no HUD, no calibration marks
- `/cmd?action=…` — remote control: `beginCalibration`, `placeCorner`,
  `calibrateFromPockets`, `probe`, `startRecording`

`probe` is the one to know: `/cmd?action=probe&x=311&y=171` unprojects one
view point and reports the world point, its range and the plane used.
Coordinates are **view points = mirror image pixels ÷ 2**. That command is
how the 158 mm cloth-height error was found.

---

## Rules that are not negotiable

From `CLAUDE.md`, and they exist for reasons the history records:

1. **`Packages/CueSyncCore` is frozen.** Changing it needs a dedicated
   contract-change PR.
2. **No secrets in source.** Keys go in the untracked
   `App/Config/Secrets.xcconfig` via the `SecretsProviding` seam. Never
   `git add -A` after a build — that is how the key above leaked, out of a
   derived-data manifest.
3. **New logic ⇒ new tests in the same PR.** 85 % coverage bar on the pure
   packages. Never weaken a test to make it pass.
4. **Do not claim device behaviour works** without a committed
   device-checklist run.
5. **`.github/**`, `.claude/**`, `Scripts/verify/**`,
   `Scripts/agent-runner/**` and `App/Config/**` are owner-authored.**

And one that is not written down anywhere else: **a confident number is
not a correct number.** Three separate bugs in this project's history —
the 429 mm pocket fit, the 158 mm cloth height, the "8 mm spread" that was
158 mm wrong — all reported high confidence while being badly wrong. Every
estimate in this codebase that carries a quality signal should be asked
what would happen if it were systematically biased, because twice now the
answer has been "the signal would not notice."
