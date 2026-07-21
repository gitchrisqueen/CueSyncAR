# 04 — Testing Strategy

The core constraint: **ARKit and the camera do not run in CI.** The strategy
is therefore layered so that ~90% of logic is verified without a device, and
the device-only remainder is a short, explicit, repeatable checklist.

## Layer 1 — Unit tests (Swift Testing, every package, runs in `ci-core`)

- Framework: **Swift Testing** (`import Testing`, `@Test`, `#expect`) — not
  XCTest — for all new unit/integration tests. Parameterized tests for
  geometry/physics cases; `.tags()` to group `fast` vs `fixture` suites.
- Every public function in pure packages (`CueSyncCore`, `BilliardsPhysics`,
  `TableSpace`) has direct unit coverage. Coverage floor enforced in CI:
  **85% lines for pure packages**, tracked per-package.
- Property-based suites (seeded pseudo-random, deterministic in CI) for the
  physics invariants listed in 03-MODULES.

## Layer 2 — Contract tests (shared protocol suites)

Each provider protocol has one reusable conformance suite run against every
implementation **and every mock**, so plug-ins can't drift:

```swift
func assertDetectionProviderContract(_ make: () -> any DetectionProviding)
// invoked from CoreMLDetectionProvider tests, FixtureDetectionProvider tests,
// DetectionRoboflow tests (stubbed network), and any future adapter.
```

Contract suites live in a `CueSyncTestSupport` package product so all packages
share them. Adding a provider without passing its contract suite fails review.

## Layer 3 — Fixture/replay integration tests (runs in `ci-core`)

The bridge between "pure math works" and "works on a real table":

- **Detection fixtures:** on-device capture tool (debug menu in the app) dumps
  per-frame JSON: camera intrinsics/transform, detector output boxes, and the
  raycast results. Committed under `Fixtures/` (small, text, diffable) with a
  short README describing the physical scene (e.g. `9ft-8ball-rack-walkaround/`).
- **Replay harness:** feeds fixtures through `PerceptionPipeline` with
  `FixtureDetectionProvider` + `FixtureRaycaster` and asserts the emitted
  `TableState` stream: ball count stability, identity persistence, positional
  error vs. hand-measured ground truth (< 2 cm), no flicker.
- **End-to-end (sim-safe):** fixture → pipeline → solver → assert
  `ShotPrediction` goldens, and render the 2D Table View of the result as a
  snapshot test. This exercises the full MVP data path minus camera/ARKit.

## Layer 4 — Snapshot tests (`swift-snapshot-testing`, runs in `ci-app`)

- CueSyncUI components and DisplayKit Table View: light/dark, Dynamic Type,
  iPhone + iPad + 1080p/4K external sizes.
- Overlay geometry: `ShotPrediction` → 2D projected overlay image snapshots
  (catches "trajectory drawn through a cushion" class bugs without a device).

## Layer 5 — UI tests (XCUITest, simulator, `ci-app`)

Minimal and stable by design: app launch with `-UITestFixtureMode` argument
(fixture providers registered, camera bypassed) → calibration screen appears →
complete mock calibration → HUD shows 16 tracked balls → settings round-trip.
No pixel assertions; accessibility-identifier driven.

## Layer 6 — Device checklist (manual, gated, per-milestone)

A versioned markdown checklist (`docs/device-checklist.md`, created in M2) run
on a physical iPhone at a real table before any milestone is declared done.
Includes:

| Check | Bar |
|-------|-----|
| Calibration time, good lighting | ≤ 10 s |
| Calibration time, bar lighting | ≤ 30 s with manual corner assist |
| Ball detection recall (full rack) | ≥ 15/16 stable |
| Positional accuracy vs tape measure | ≤ 2 cm |
| Tracking while walking table perimeter | no identity swaps, no overlay drift > 1 ball radius |
| Overlay latency (slow-mo camera on screen) | ≤ 100 ms |
| Sustained session | 15 min, no crash, no thermal shutdown, FPS ≥ 30 |
| AirPlay connect/disconnect ×3 | AR session survives |
| Battery burn | ≤ 20%/15 min on iPhone 13-class |

Results are committed with the milestone PR (a filled-in copy of the checklist),
so device status is auditable by agents who cannot run devices.

## Model evaluation (offline, scripted)

`Scripts/eval-model.swift` (or notebook in `Tools/`): runs the bundled Core ML
model against a labeled held-out image set (committed via Git LFS or fetched by
script), reports mAP/precision/recall per class. Run whenever the model file
changes; results table committed alongside the model version. Bar: mAP@50 ≥
0.85 balls, ≥ 0.9 cue-ball classification.

## CI gates summary (required to merge)

1. `ci-core`: build + unit + contract + fixture suites for all packages; lint;
   format check; gitleaks. Target wall time < 10 min.
2. `ci-app`: simulator build, snapshot suite, XCUITest smoke. Target < 20 min.
3. Coverage floors (pure packages 85%) enforced via `xccov` diff.
4. No new warnings (`SWIFT_TREAT_WARNINGS_AS_ERRORS` in CI config for app +
   packages).

## What agents must do (normative)

- New logic ⇒ new tests in the same PR; a PR that lowers coverage fails.
- Bug fix ⇒ regression test that fails before the fix.
- Anything touching physics/geometry ⇒ update or extend golden fixtures, never
  silently regenerate them (regeneration requires a PR note explaining why
  outputs changed).
- Device-only claims ("tracking feels stable") are **not** completable by
  agents: mark the task's device-checklist item as `needs-device-run` and hand
  off per 07-AGENT-PLAYBOOK.md.
