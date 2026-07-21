# CLAUDE.md

Guidance for AI assistants working in this repository.

> **START HERE:** The adopted modernization & MVP plan lives in
> [`docs/roadmap/`](docs/roadmap/00-OVERVIEW.md). Read `00-OVERVIEW.md` and
> `07-AGENT-PLAYBOOK.md` before doing any work; claim tasks from
> `06-MILESTONES.md`.

## Project overview

**CueSync AR** is an iOS augmented-reality billiards coach: live table/ball
detection, trajectory projection with pocket alignment, TV mirroring. The M0
modernization (2026-07) replaced the 2023 CocoaPods scaffold with the
SwiftPM-modular layout below. MVP feature work is in flight per the roadmap.

## Tech stack

- **Language:** Swift 6 (tools 6.1, Swift 6 language mode, strict concurrency)
- **UI:** SwiftUI app lifecycle, Observation framework
- **AR:** ARKit + RealityKit (device only — never the Simulator)
- **ML:** Core ML/Vision on-device (default detection provider, lands in M2)
- **Project generation:** [XcodeGen](https://github.com/yonaskolb/XcodeGen) from
  `project.yml` — the `.xcodeproj` is **generated and gitignored**
- **Min deployment:** iOS 26.0 (app); packages build for iOS 18+/macOS 15+ and Linux
- **Tests:** Swift Testing (`import Testing`) in every package
- **Bundle id / team:** `CQC.CueSync-AR` / `8VQNRK6J32`

## Repository layout

```
project.yml                 ← XcodeGen definition (source of truth for the app target)
App/
  Sources/                  ← thin app shell (CueSyncApp, SessionModel, RootView)
  Resources/                ← Assets.xcassets
  Config/                   ← App.xcconfig + Secrets.example.xcconfig
Packages/                   ← local SwiftPM packages (the real code)
  CueSyncCore/              ← domain types + provider protocols (FROZEN CONTRACTS)
  BilliardsPhysics/         ← trajectory solver (pure, heavily tested)
  TableSpace/               ← calibration & coordinate math (pure)
  CueSyncTestSupport/       ← fixtures, mocks, provider contract checks
  PerceptionKit/            ← detection+tracking pipeline (M2)
  ARExperience/             ← ARKit/RealityKit shell (M3)
  DisplayKit/               ← external display / TV mode (M4)
  CueSyncUI/                ← design system (M1-05/06)
  CoachKit/                 ← LLM coaching adapters (post-MVP)
Scripts/                    ← bootstrap.sh, test-all.sh, format.sh
docs/roadmap/               ← the plan; 06-MILESTONES.md is the task board
.github/workflows/          ← ci-core (Linux package tests), ci-app (macOS build)
```

## Building & testing

- **Packages (any OS with Swift 6.1+):** `Scripts/test-all.sh` or
  `swift test --package-path Packages/<Name>`.
- **App (macOS only):** `Scripts/bootstrap.sh` → open `CueSyncAR.xcodeproj`.
  AR/camera behavior needs a physical device; see the device-checklist rules
  in `docs/roadmap/04-TESTING-STRATEGY.md`.
- CI must stay green: ci-core runs all package tests on Linux + SwiftLint +
  gitleaks; ci-app builds the app for the iOS Simulator on macOS.

## Hard rules

1. **Contracts are frozen.** Changing anything in `Packages/CueSyncCore`
   requires a dedicated contract-change PR (playbook rule 4).
2. **No secrets in source.** Use the `SecretsProviding` seam; keys go in the
   untracked `App/Config/Secrets.xcconfig`. The pre-M0 Roboflow key in git
   history is compromised and must be rotated by the maintainer — never
   reuse it, never paste it anywhere.
3. **New logic ⇒ new tests in the same PR.** Pure packages hold an 85%
   coverage bar. Never weaken a test to make it pass.
4. **Don't claim device behavior works** without a committed device-checklist
   run; agents mark such work `needs-device-run` (playbook rule 6).
5. **Match existing style:** file header comments (`// Filename / CueSync AR`),
   `UpperCamelCase` types, doc comments on public API, SwiftLint clean.

## Git workflow

- Branch per task: `claude/<task-id>-<slug>` (e.g. `claude/M2-03-tracker`).
  A pushed claim branch = a claimed task; tick the board checkbox in the
  same PR that completes the task.
- Default branch: `main`. Never push elsewhere without permission; do not
  open PRs unless asked.
