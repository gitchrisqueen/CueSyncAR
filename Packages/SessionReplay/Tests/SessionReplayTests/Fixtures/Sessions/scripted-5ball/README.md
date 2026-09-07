# scripted-5ball — the first fixed-eval-set bundle

A **generated** session bundle: every input file here is the byte-exact output
of `ScriptedFiveBall.makeBundle()` in `Tests/SessionReplayTests/ScriptedFiveBall.swift`,
and `outputs.jsonl` is what `ReplayRunner` produced from these inputs (read back
from this text, so the golden is judged from the six-decimal values CI reads).
`GoldenReplayTests` asserts both facts; nothing here is hand-edited.

## Scene (table space, meters; 8-ft table, 2.34 × 1.17 m play field)

| Ball | Truth position | Notes |
|---|---|---|
| 0 | (−0.62, 0.05) | **cue ball — a measle/practice ball**, so the detector labels it `color-ball` like the rest; the user designates it by tap at frame 5 (`designateCueBall` at (−0.60, 0.06)) |
| 1 | (0.15, 0.10) | |
| 2 | (0.42, −0.22) | |
| 3 | (0.58, 0.31) | **drops out of detection on frames 12–16** (must persist: visibility-gated misses; 0.5 s is inside the 0.75 s `visibleMissGrace` and the 30-frame disappearance gate) |
| 4 | (0.05, −0.40) | |

- **Calibration:** origin (0.3, −0.45, −1.6) in AR world space, x = (1,0,0),
  y = (0,0,−1) → cloth normal +y.
- **Camera:** 1.35 m above the cloth, 1.9 m from the table center on the
  head-rail side, sweeping a −25°…+25° arc over the 45 frames while looking at
  table point (0.10, 0) — a slow walk-around, so every frame has a different
  pose and the projection math is exercised end to end. Intrinsics
  1920 × 1440, f = 1450 px, principal point (960, 720).
- **Timestamps:** 100.0 s + 0.1 s per frame (10 Hz).
- **Detections:** exact forward projections of each ball's sphere center
  (lifted one radius) through `PlaneGeometryRaycaster.projectToImage`, box size
  from the true pixel radius, ±1.5 px box-center noise and 0.80–0.97
  confidence from a seeded SplitMix64 (seed 20260907).
- **Cue stick:** a `cue` detection addresses the cue ball on frames 8–14
  (butt (−1.55, −0.07) → tip (−0.72, 0.04): the butt overhangs the head rail,
  the tip end is on the cloth — what `StickAim.quadOnTable` accepts). The
  2.5 s stick hold (the value measured at the table, see `AimResolver`) then
  keeps the stick aim through frame 39; the device-pose model returns on
  frame 40, which is why the bundle runs 45 frames.
- **Spurious box:** frame 20 carries a 22 %-confidence `color-ball` box in the
  middle of the table — below the 0.35 floor, must never be tracked.
- **Events:** a `note` at frame 0, the designation at frame 5, and
  `callPocket cornerTopRight` at frame 18.
- **No video** — a bundle without pixels is fully valid; nothing in the replay
  needs them.

## What the golden asserts

`GoldenReplayTests` (run in CI by `Scripts/verify/replay-golden.sh`, on Linux):

1. `committedInputsMatchTheGenerator` — these input files equal the generator's
   output byte for byte.
2. `replayIsByteIdenticalAcrossRunsInOneProcess` — two runs agree exactly.
3. `replayMatchesTheCommittedGolden` — the replay equals `outputs.jsonl`, which
   was written by a different process on macOS: the cross-process,
   cross-platform byte-equality proof.
4. `accuracyClearsTheBars` — after the 3-frame appearance gate: position RMS
   ≤ 2 cm, recall and precision ≥ 0.98, zero identity switches, zero track churn.
5. `scriptedScenarioPlaysOutAsWritten` — designation, stick → hold → device
   pose, the dropout ball persisting, the spurious box ignored, the pocket call.

## Golden history

- v1 (B2 branch, pre-rebase): 30 frames, 1.2 s stick hold.
- v2 (rebase onto `main` after #7 tracker timestamps, #8 dispatch fix, #11
  playing-surface gate): regenerated — 45 frames so the 2.5 s hold adopted from
  `main`'s device measurement still expires inside the bundle. Because the
  camera arc is sampled over 45 frames, every frame index now has a slightly
  different pose, so per-frame positions differ from v1 by ≤ 0.7 mm; the
  pipeline changes from `main` themselves leave five static in-field balls
  untouched. Aim sources: `devicePose` 5–7, `stick` 8–39, `devicePose` 40–44.

## Regenerating (deliberately, never silently)

```
CUESYNC_REGENERATE_FIXTURES=1 swift test --package-path Packages/SessionReplay --filter Golden
```

rewrites every file here from the generator and the current code, and records
a test issue on purpose so the run cannot pass green. Review the diff of
`outputs.jsonl` and explain the change in the PR (04-TESTING-STRATEGY: goldens
are never regenerated without a note saying why the outputs changed).
