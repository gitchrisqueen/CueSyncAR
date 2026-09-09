# Device checklist

The artifact every device-only claim ticks. `04-TESTING-STRATEGY.md` has
called for this file since M2 and the playbook, `CLAUDE.md` and the PR
template all reference it; it did not exist, so M3-06's "tick the rows as
they verify" had nothing to tick and no device claim in this project has
ever been recorded against a fixed list.

**How to use it.** Copy the table into a dated file under
`docs/validation/` for each run, fill the Result column, and link that file
from the PR. A row is either measured or it is open — "looked fine" is not
a result. Bars come from `04-TESTING-STRATEGY.md:66-78` and the MVP
definition in `00-OVERVIEW.md:34-59`.

**Offline proxy.** Several rows have a replay metric that moves with them.
A green proxy is evidence the row is *worth* re-running, never a substitute
for running it: replay reads recorded detections and poses, so it cannot
see the camera, the cloth, the lighting, or the renderer. Rows with no
proxy are the ones that genuinely need a person at the table.

Run `swift test --package-path Packages/SessionReplay --filter Golden` for
the proxies; every one prints its `StabilityReport` line.

## Perception and calibration

| # | Row | Bar | Offline proxy | Result |
|---|---|---|---|---|
| 1 | Calibration time, good lighting | ≤ 10 s | — | open |
| 2 | Calibration time, bar lighting | ≤ 30 s with manual assist | — | open |
| 3 | Ball detection recall, full rack | ≥ 15/16 stable | `AccuracyReport.recall` (needs `truth.json`) | open |
| 4 | Positional accuracy vs tape measure | ≤ 2 cm | `AccuracyReport.positionRMS` (needs `truth.json`) | open |
| 5 | Tracking while walking the perimeter | no identity swaps, drift ≤ 1 ball radius | `trackChurn`, `shortTracks`, `cueIDChanges` | open |
| 6 | Rings sit on the balls | on the ball at every camera angle | `SnapshotReprojectionReport` (not yet written) | open |
| 7 | Nothing renders past the cushion nose | no ball outside the playing surface | surface-gate counters (not yet in `OutputRecord`) | open |
| 8 | Phantom rings clear after a shot | ≤ ~1 s | `shortTracks` | open |

## Aim and guides

| # | Row | Bar | Offline proxy | Result |
|---|---|---|---|---|
| 9 | Guide follows the cue when aiming | one line, steady | `stickAimRate`, `headingDeltaMax` | open |
| 10 | Guide is not captured by a cue lying on the cloth | ignored | `stickPresentRate` on `device-lying-cue` | open |
| 11 | Aim source does not flap | ≤ 2 changes/min | `sourceTransitionsPerMinute` | open |
| 12 | Guide shows ≥ 1 cushion bounce | MVP item 4 | `predictionsWithoutCushionOrPocket` | open |
| 13 | Pocket highlights sit on the pockets | within a ball radius | — (needs the calibration to be right first) | open |
| 14 | Called pocket rings, and greens when on line | M6-02 | `calledShotOnLine` in the golden | open |

## Session health

| # | Row | Bar | Offline proxy | Result |
|---|---|---|---|---|
| 15 | Overlay latency, slow-motion capture | ≤ 100 ms | — | open |
| 16 | Sustained session | 15 min, no crash or thermal throttle, FPS ≥ 30 | — | **failed once informally**: AR freeze after ~80k frames, `docs/validation/2026-07-23-T1-device-verification.md:110` |
| 17 | Battery burn | ≤ 20 % per 15 min | — | open |
| 18 | Relocalization on returning to a saved venue | ≤ 15 s | — | **verified**: 2.2 s, mirror `relocalizationSeconds`, 2026-09-09 |
| 19 | Detector compute | Neural Engine, no abort | mirror `detectorCompute` | **verified**: `phase: succeeded`, 10 runs, 0 crashes, iPad12,1 |
| 20 | AirPlay connect/disconnect ×3 | AR session survives | — | not runnable: DisplayKit is linked but unused (plan v5 Phase 4) |

## What "verified" requires

A device claim needs one of: a mirror reading (`/state.json` field named,
value quoted), a `/frame.jpg` capture, or a committed recording that
replays. A build that compiles is not a device claim — playbook rule 6.
