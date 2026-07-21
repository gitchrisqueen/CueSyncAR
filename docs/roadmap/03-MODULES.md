# 03 — Module Specifications

One section per module: purpose, public surface, dependencies, test
obligations, and acceptance criteria. Task IDs reference
[06-MILESTONES.md](06-MILESTONES.md). "Pure" = no Apple-framework imports
beyond Foundation/simd → fully CI-testable on any runner.

---

## CueSyncCore (pure)

**Purpose:** Domain types (`Ball`, `Table`, `TableState`, `AimRay`,
`ShotPrediction`), provider protocols (`DetectionProviding`,
`TrajectorySolving`, `CoachProviding`, `DisplayOutput`), `ProviderRegistry`,
`SecretsProviding`, shared errors and units.

**Dependencies:** none.
**Consumers:** every other package.

**Tests (unit):** value-type invariants (ball kind classification from model
class labels, table geometry derivation — pocket positions from `TableSize`),
registry registration/resolution, Codable round-trips for persisted types.

**Acceptance:** 100% of public API documented (DocC comments); no
`import UIKit/ARKit/RealityKit` anywhere; ≥ 90% line coverage (it's cheap here).

---

## BilliardsPhysics (pure)

**Purpose:** Analytic 2D trajectory solver. Given `TableState` + `AimRay`,
produce `ShotPrediction`: ghost-ball contact, elastic ball-ball collision
(equal-mass, friction-free MVP model: object ball departs along center line,
cue ball along tangent line), cushion reflections with restitution coefficient,
pocket capture test (ball path intersects pocket mouth within capture radius),
segment-by-segment rollout with rolling-friction deceleration.

**Public surface:**
```swift
struct AnalyticSolver: TrajectorySolving { init(config: PhysicsConfig = .standard) }
struct PhysicsConfig { var restitutionCushion, rollingFriction, ballBallRestitution: Double; var maxEvents: Int }
```

**Dependencies:** CueSyncCore.

**Tests (unit — this module lives or dies by them):**
- Straight shot, no obstacles → straight segment, correct stop distance.
- Head-on collision → object ball takes full velocity direction; cue ball stops
  (stun) in MVP model.
- Cut shots at known angles (30°, 45°, 60°) → object-ball direction matches the
  ghost-ball geometry to 1e-9; tangent-line cue path 90° from impact line.
- Cushion reflection: incidence = reflection scaled by restitution; corner
  cases at pocket mouths.
- Pocket capture: center-pocket hit → `pocketedBalls` contains target; near
  miss by > capture radius → does not.
- Property-based tests (seeded): energy never increases; balls never exit the
  rail rectangle; solver terminates ≤ `maxEvents`.
- Golden-file scenario suite: ~20 JSON fixtures (`state + aim → expected
  prediction`) reviewed by a human once, then frozen as regressions.

**Performance budget:** `predict` < 1 ms for 16 balls, 8 events (asserted by a
performance test).

**Acceptance:** golden suite green; property suite 10k iterations green; docs
include the math derivation in `Docs/PhysicsModel.md` inside the package.

---

## TableSpace (pure)

**Purpose:** Calibration math and coordinate transforms. Homography/similarity
transform between the ARKit plane and 2D table space; image→world→table
mapping helpers; `TableCalibration` persistence model; table-size inference
from measured rail rectangle (snap to nearest standard size with tolerance).

**Dependencies:** CueSyncCore. (simd only; the ARKit raycast itself lives in
PerceptionKit/ARExperience — this package just does the math on the results.)

**Tests (unit):** transform round-trips (table→world→table = identity within
1e-6); size inference (measured 2.51 × 1.29 m → `.nineFoot`); corner-handle
adjustment recompute; serialization round-trip.

**Acceptance:** all mapping functions total (no force-unwraps), documented
error bounds.

---

## PerceptionKit (Vision/CoreML; simulator-safe seams)

**Purpose:** The perception pipeline: frame intake, detection scheduling,
image→table-space projection (using injected raycast + TableSpace math),
multi-frame tracking (per-ball Kalman filter + Hungarian-style identity
association), stability gating (a ball must persist N frames to appear, M to
disappear — no flicker).

**Public surface:**
```swift
actor PerceptionPipeline {
    init(detector: any DetectionProviding, calibration: TableCalibration,
         raycaster: any PlaneRaycasting, config: PerceptionConfig = .default)
    var states: AsyncStream<TableState> { get }
    func ingest(_ frame: CapturedFrame)
}
protocol PlaneRaycasting: Sendable { /* injected; ARExperience provides the ARKit impl */ }
struct CoreMLDetectionProvider: DetectionProviding { init(model: MLModel) }
struct FixtureDetectionProvider: DetectionProviding { init(fixture: DetectionFixture) }
```

**Detection model:** Roboflow-trained pool-ball dataset exported to **Core ML**
(Roboflow supports CoreML export) or an open-source YOLO (v11/12-class family)
fine-tuned on the same dataset, converted with `coremltools`. Bundled in the
app; runs on ANE. The cloud Roboflow SDK becomes an optional adapter package
(`DetectionRoboflow`), not the default — MVP works offline.

**Tests:**
- Unit: tracker association (two crossing balls keep identities), Kalman
  smoothing convergence, stability gating, latest-wins frame dropping.
- Integration (fixture-based): recorded frame sequences (JSON detections +
  camera transforms captured on-device once) replayed through the full
  pipeline → assert `TableState` streams match goldens within tolerance.
- Model evaluation harness (script, not app code): precision/recall on a held-
  out labeled image set; minimum bar mAP@50 ≥ 0.85 for balls on typical cloth.

**Acceptance:** pipeline holds 15 Hz detection on iPhone 12-class hardware
(device checklist); fixture integration suite green in CI.

---

## DetectionRoboflow (optional adapter)

**Purpose:** `DetectionProviding` adapter over the Roboflow iOS SDK (SwiftPM),
for teams that want cloud-managed model iteration. Never imported by default;
registered only when a key is present via `SecretsProviding`.

**Tests:** contract tests shared with all `DetectionProviding` impls (same
protocol-conformance test suite, injected with a stubbed network layer).

---

## ARExperience (device-centric)

**Purpose:** ARKit/RealityKit shell: `ARSessionCoordinator` (session config,
frame stream, plane anchors, ARKit raycast impl of `PlaneRaycasting`),
`CalibrationController` (flow from 05-UX-DESIGN), `AimEngine` (device-pose →
`AimRay`), `OverlayRenderer` (RealityKit entities: trajectory tubes with
animated dash flow, ghost-ball, pocket glow, ball halo markers).

**Dependencies:** CueSyncCore, TableSpace, BilliardsPhysics, PerceptionKit, CueSyncUI.

**Tests:**
- Unit (sim-safe): `AimEngine` math (camera transform fixtures → expected
  rays); entity-graph builders return correct hierarchies for a given
  `ShotPrediction` (RealityKit entities can be constructed off-device).
- Snapshot: `TableViewOutput`-style 2D projection of overlay geometry.
- Device checklist items (04-TESTING-STRATEGY.md) for tracking quality,
  latency, relocalization.

**Acceptance:** overlay update ≤ one render frame behind solver output; no
main-thread stalls > 8 ms from entity updates (Instruments-verified, device).

---

## DisplayKit

**Purpose:** External display support. Handles `UIScreen`/`UIWindowScene`
external-display lifecycle: when an AirPlay/HDMI display connects, offer
(a) **system mirroring** (zero code, always works) or (b) **Table View** — a
dedicated scene rendering the clean 2D top-down table with live ball positions
and predictions (built in SwiftUI Canvas from `TableState`/`ShotPrediction`,
no camera feed), styled for 10-foot viewing.

**Dependencies:** CueSyncCore, CueSyncUI.

**Tests:** unit for scene-routing state machine (connect/disconnect/reconnect);
snapshot tests of the Table View across sizes (1080p/4K) and light/dark.

**Acceptance:** hot-plug (connect/disconnect mid-session) never crashes or
tears down the AR session; Table View readable from 3 m (design review).

---

## CueSyncUI (pure-ish: SwiftUI only)

**Purpose:** Design system per [05-UX-DESIGN.md](05-UX-DESIGN.md): color/typography
tokens, glass HUD components (status pill, calibration coach marks, ball-count
chip, FPS/quality indicator), the 2D table renderer (shared by DisplayKit and
a mini-map), haptics wrappers, accessibility modifiers.

**Tests:** snapshot tests (light/dark, Dynamic Type XS–XXL, iPhone/iPad),
component unit tests for state logic.

---

## CoachKit (post-MVP)

**Purpose:** `CoachProviding` adapters: `FoundationModelsCoach` (Apple
on-device Foundation Models framework — default: private, offline, free) and
`ClaudeCoach` (Anthropic Swift SDK; key via `SecretsProviding`). Prompt
assembly from `TableState`+`ShotPrediction` (structured JSON, never images),
response schema (`CoachAdvice`: recommended shot, difficulty, explanation),
guardrails (advice is advisory UI, never mutates state).

**Tests:** prompt-assembly goldens; schema decoding with recorded responses;
contract tests with a `MockCoach`. Live-API tests are opt-in (env-gated), never
in required CI.

---

## App shell

**Purpose:** `@main` SwiftUI App, `SessionModel` (@Observable composition
root), provider registration, scene routing (main AR scene + external scene),
permissions flow (camera), settings screen (table size override, provider
selection, debug HUD toggle).

**Tests:** launch UI test (XCUITest) on simulator with fixture provider:
app reaches "calibration" state without camera; settings toggles persist.
