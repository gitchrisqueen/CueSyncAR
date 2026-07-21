# CueSync AR — 2026 Modernization & MVP Roadmap

**Status:** Adopted plan · Last updated 2026-07-21
**Audience:** Human maintainers **and** AI agents (Claude instances, possibly many in parallel).

This directory is the single source of truth for how CueSync AR gets from its
current three-file prototype to a shipping MVP on a modern 2026 toolchain.
Every document is written so that an agent with no prior context can pick up a
task, implement it against a frozen interface contract, test it, and merge it
without colliding with other agents.

## Document index

| Doc | Contents |
|-----|----------|
| [00-OVERVIEW.md](00-OVERVIEW.md) | Vision, MVP definition, tech baseline, guiding principles (this file) |
| [01-TECH-MODERNIZATION.md](01-TECH-MODERNIZATION.md) | Phase 0: toolchain upgrade, SwiftPM migration, repo hygiene, secrets, CI |
| [02-ARCHITECTURE.md](02-ARCHITECTURE.md) | Modular architecture, plug-in provider protocols, data flow, concurrency model |
| [03-MODULES.md](03-MODULES.md) | Per-module specs: public API, dependencies, tests, acceptance criteria |
| [04-TESTING-STRATEGY.md](04-TESTING-STRATEGY.md) | Unit / integration / replay / device testing, CI gates, performance budgets |
| [05-UX-DESIGN.md](05-UX-DESIGN.md) | 2026 UX & visual design: AR HUD, calibration flow, external-display experience |
| [06-MILESTONES.md](06-MILESTONES.md) | Milestones M0–M5 with task IDs, dependencies, and exit criteria |
| [07-AGENT-PLAYBOOK.md](07-AGENT-PLAYBOOK.md) | How parallel Claude agents claim tasks, branch, test, and merge safely |

## Product vision (from README, unchanged)

An iOS AR app that watches a real billiards table through the phone camera and
coaches the player in real time: detects the table and balls, projects shot
trajectories that update live as the player aims, shows where balls will
collide and whether they line up with pockets, and mirrors the experience to a
TV or projector for spectators and instruction. Future targets: iPadOS,
visionOS, tvOS, games/drills, projector-aligned output.

## MVP definition (what "done" means)

A player can, on a physical iPhone:

1. **Launch** the app and point the camera at a real billiards table.
2. **Calibrate** in under ~10 seconds: the app finds the table surface and rails
   (auto-detect + one confirmation gesture) and locks a table-space coordinate
   system to it.
3. **See detected objects**: every ball on the table is detected, classified
   (cue / solid / stripe / 8-ball at minimum cue vs. object), and tracked with
   stable world positions while the player walks around.
4. **Aim**: an aiming line is projected from the cue ball that updates in real
   time as the player moves and sights the shot. The line shows:
   - first object-ball contact point (ghost ball),
   - post-impact paths of cue ball and object ball,
   - cushion rebounds (≥ 1 bounce),
   - pocket alignment: the target pocket highlights when the object ball's
     projected path enters it.
5. **Mirror to a TV**: via AirPlay/external display, spectators see either a
   mirror of the phone or a clean dedicated "table view".
6. **Experience quality**: ≥ 30 FPS camera feed, overlay latency under ~100 ms,
   no crashes across a 15-minute session, modern iOS 26 visual design.

Explicitly **out of MVP** (post-MVP backlog, architecture must not preclude
them): spin/english physics, cue-stick detection, LLM shot coaching, drills &
game modes, visionOS/tvOS targets, projector geometric alignment, multiplayer.

## Tech baseline (verified July 2026)

| Item | Decision |
|------|----------|
| Xcode | **26.x** (stable; 26.6 current). Do **not** adopt Xcode 27 betas until GM. |
| Swift | **6.3** (bundled with Xcode 26), Swift 6 language mode, strict concurrency |
| Min deployment | **iOS 26.0** (iPhone 11 and later; simplifies design-system + API story). See rationale in 01. |
| UI | SwiftUI app lifecycle (`@main App`), Observation framework (`@Observable`) |
| AR | ARKit + RealityKit (ARView with world tracking; RealityKit entities for overlays) |
| ML | Core ML + Vision on-device as the default detection provider; Roboflow-trained model exported to Core ML. Any provider is swappable (see 02). |
| Packages | **Swift Package Manager only.** CocoaPods and `Pods/` are removed in M0. |
| Tests | **Swift Testing** (`import Testing`) for unit/integration; XCTest only for UI tests |
| CI | GitHub Actions, macOS runner with Xcode 26.x |
| Lint/format | SwiftLint + swift-format, enforced in CI |

When Xcode 27 / iOS 27 go stable (expected ~Sept 2026), a single tracked task
(M5) re-evaluates the baseline; nothing else in this plan depends on it.

## Guiding principles

1. **Stable over bleeding-edge.** Only shipped, GM tooling and first-party
   frameworks in the critical path. Open-source dependencies are welcome but
   must be pinned by exact version, actively maintained, and wrapped behind a
   protocol we own.
2. **Everything replaceable is behind a protocol.** Detection models, physics
   solvers, LLM coaches, and display outputs are *providers* conforming to
   small protocols defined in `CueSyncCore`. Swapping Roboflow for a custom
   YOLO export, or Apple's on-device Foundation Models for Claude, is a
   one-file registration change, never a refactor.
3. **The simulator-safe core is where the logic lives.** Physics, geometry,
   game state, and coordinate mapping are pure Swift packages with zero ARKit
   imports — fully unit-testable in CI without a device. Device-only code
   (camera, ARSession) is a thin shell.
4. **Agent-parallel by construction.** Module boundaries are the parallelism
   boundaries. Interface contracts are frozen before implementation fans out;
   each task in 06-MILESTONES lists its contract, its tests, and what it may
   not touch.
5. **No secrets in source, ever.** The historical Roboflow key is treated as
   compromised (see 01, task M0-05).
