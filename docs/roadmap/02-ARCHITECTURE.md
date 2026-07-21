# 02 — Architecture

Modular, protocol-first, simulator-safe-core architecture. Module boundaries
here are also the **parallel-agent work boundaries** (see 07-AGENT-PLAYBOOK).

## Repository layout (target)

```
CueSyncAR/
├── App/                          # Xcode app target — thin shell only
│   ├── CueSyncApp.swift          # @main SwiftUI App
│   ├── Config/                   # xcconfigs incl. Secrets.example.xcconfig
│   └── Resources/                # Assets.xcassets, ML model bundles
├── Packages/
│   ├── CueSyncCore/              # domain types + provider protocols (pure Swift)
│   ├── BilliardsPhysics/         # trajectory & collision solver (pure Swift)
│   ├── TableSpace/               # calibration math, homography, coordinate maps (pure Swift)
│   ├── PerceptionKit/            # detection + tracking pipeline (Vision/CoreML; sim-safe seams)
│   ├── DetectionRoboflow/        # OPTIONAL adapter: Roboflow SDK behind DetectionProviding
│   ├── ARExperience/             # RealityKit/ARKit scene, overlay entities (device-centric)
│   ├── DisplayKit/               # external display / AirPlay scenes, broadcast view
│   ├── CoachKit/                 # post-MVP: LLM coaching behind CoachProviding
│   └── CueSyncUI/                # SwiftUI design system: HUD components, theming
├── docs/roadmap/                 # this plan
├── Scripts/                      # format.sh, lint.sh, ci helpers
└── .github/workflows/            # ci-core.yml, ci-app.yml
```

Dependency rule (arrows = "may import"):

```
App ─▶ ARExperience ─▶ PerceptionKit ─▶ CueSyncCore
 │        │                 │
 │        ├─▶ BilliardsPhysics ─▶ CueSyncCore
 │        └─▶ TableSpace ──────▶ CueSyncCore
 ├─▶ DisplayKit ─▶ CueSyncCore, CueSyncUI
 ├─▶ CueSyncUI ─▶ CueSyncCore
 └─▶ CoachKit ─▶ CueSyncCore
```

`CueSyncCore` imports **nothing** but Foundation/simd. Nothing below
`ARExperience`/`DisplayKit` may import ARKit, RealityKit, or UIKit
(`PerceptionKit` may import Vision/CoreML/CoreGraphics only).

## Core domain model (`CueSyncCore`)

Value types, all `Sendable`, all in **table space** — a 2D coordinate system on
the table plane (meters, origin at table center, x along the long axis):

```swift
struct Ball: Identifiable, Sendable {
    enum Kind: Sendable { case cue, eight, solid(Int), stripe(Int), unknown }
    let id: BallID
    var kind: Kind
    var position: SIMD2<Double>   // table space, meters
    var radius: Double            // default 0.028575 (57.15 mm / 2)
    var confidence: Double        // detection confidence 0...1
}

struct Table: Sendable {
    var size: TableSize           // e.g. .sevenFoot, .eightFoot, .nineFoot(2.54 × 1.27 m play field)
    var pockets: [Pocket]         // 6, derived from size
    var cushionInset: Double
}

struct TableState: Sendable {     // one coherent snapshot per frame
    var table: Table
    var balls: [Ball]
    var timestamp: TimeInterval
}

struct AimRay: Sendable {         // where the player is aiming, in table space
    var origin: SIMD2<Double>     // cue ball position
    var direction: SIMD2<Double>  // unit vector
}

struct ShotPrediction: Sendable { // solver output, renderer input
    var segments: [TrajectorySegment]   // polyline per ball, with event tags
    var events: [CollisionEvent]        // ballBall, cushion, pocket(PocketID)
    var pocketedBalls: [BallID]
}
```

## Plug-in provider protocols (the "plug-and-play" seams)

Every replaceable capability is a protocol in `CueSyncCore`, registered in a
lightweight `ProviderRegistry` at app startup. Adapters are separate packages.

```swift
/// Any object detector: local Core ML, Roboflow SDK, remote endpoint, test fixture.
protocol DetectionProviding: Sendable {
    func prepare() async throws
    /// Detections in image-pixel space; PerceptionKit maps them to table space.
    func detect(in frame: CapturedFrame) async throws -> [Detection2D]
}

/// Any trajectory solver (default: BilliardsPhysics; future: spin-aware, ML-assisted).
protocol TrajectorySolving: Sendable {
    func predict(state: TableState, aim: AimRay, options: SolverOptions) -> ShotPrediction
}

/// Post-MVP: any LLM/coaching backend — Apple Foundation Models (on-device),
/// Claude API, OpenAI, local server. Input is structured state, never raw video.
protocol CoachProviding: Sendable {
    func advise(state: TableState, prediction: ShotPrediction,
                skill: SkillLevel) async throws -> CoachAdvice
}

/// Any external output: AirPlay mirror, dedicated external-display scene,
/// future projector-aligned renderer.
protocol DisplayOutput: Sendable {
    var kind: DisplayOutputKind { get }
    @MainActor func attach(scene: UIWindowScene?) // DisplayKit owns UIKit specifics
}
```

Default registrations for MVP: `CoreMLDetectionProvider` (in PerceptionKit),
`AnalyticSolver` (BilliardsPhysics), `MirrorDisplayOutput` + `TableViewOutput`
(DisplayKit). `CoachKit` ships adapters post-MVP: `FoundationModelsCoach`
(on-device, default, free/private) and `ClaudeCoach` (Claude API via the
official Swift SDK) — proving the LLM seam works with both on-device and
third-party models.

## Runtime data flow (per frame)

```
ARSession frame (60 Hz)
   │  CapturedFrame (pixel buffer + camera transform + intrinsics)
   ▼
PerceptionKit.DetectionPipeline          ← runs detector at ~10–15 Hz, async
   │  [Detection2D]  (bounding boxes, class, confidence)
   ▼
PerceptionKit.Tracker                    ← raycast to table plane → table space;
   │                                        per-ball Kalman smoothing + identity
   │  TableState                            association across frames
   ▼
AimEngine (ARExperience)                 ← derives AimRay from device pose:
   │  AimRay                                camera ray through cue ball, projected
   ▼                                        onto table plane (MVP aiming model)
BilliardsPhysics.AnalyticSolver          ← pure function, < 1 ms budget
   │  ShotPrediction
   ▼
ARExperience.OverlayRenderer             ← RealityKit entities: trajectory tubes,
   │                                        ghost ball, pocket highlight
   └──▶ DisplayKit.TableViewOutput       ← same TableState/ShotPrediction drawn
                                            as clean 2D top-down broadcast view
```

Key property: **everything between `CapturedFrame` and `ShotPrediction` is
deterministic given inputs**, so the entire midsection is testable with
recorded fixtures and no device (see 04-TESTING-STRATEGY.md).

## Concurrency model

- `ARSessionCoordinator` (actor, ARExperience): owns the ARSession delegate
  stream; publishes `CapturedFrame`s via `AsyncStream`, dropping frames when
  the detector is busy (latest-wins backpressure).
- `PerceptionPipeline` (actor): detection + tracking; emits `TableState` via
  `AsyncStream`. Detector inference runs off the main actor.
- Solver: pure synchronous function, called per rendered frame on the render
  update loop (it is cheap); heavy variants can move to a task.
- UI/RealityKit mutation: `@MainActor` only. State flows into SwiftUI via a
  single `@Observable SessionModel` (the app's one source of truth).
- All cross-actor payloads are `Sendable` value types (enforced by strict
  concurrency).

## Calibration & coordinate systems (TableSpace)

Three spaces and two mappings, all owned by `TableSpace`:

1. **Image space** (pixels) — detector output.
2. **World space** (ARKit meters) — via `ARView.raycast` from the ball's
   image-space foot point to the detected table plane.
3. **Table space** (2D meters on the plane) — via the calibration transform
   (plane anchor + rail rectangle → origin/axes/extent).

Calibration flow (MVP): ARKit horizontal-plane detection on the cloth →
Vision rectangle detection of the playing-field boundary → user confirms/adjusts
4 corner handles → `TableCalibration` (a `simd_float4x4` + `TableSize`)
persisted per venue via world-anchor serialization so recalibration is instant
on return visits.

## Why this decomposition is agent-parallel

- `BilliardsPhysics`, `TableSpace`, `CueSyncCore`, and `CueSyncUI` have zero
  device dependencies — four agents can build and fully test them concurrently
  the moment the protocol contracts (this doc) are frozen.
- `PerceptionKit` develops against recorded-frame fixtures; `ARExperience`
  develops against a `FixtureDetectionProvider` that replays known states.
- Contracts change only by a dedicated "contract change" task that touches
  `CueSyncCore` alone (see 07-AGENT-PLAYBOOK.md, rule 4).
