# CLAUDE.md

Guidance for AI assistants working in this repository.

> **START HERE:** The adopted modernization & MVP plan lives in
> [`docs/roadmap/`](docs/roadmap/00-OVERVIEW.md). Read `00-OVERVIEW.md` and
> `07-AGENT-PLAYBOOK.md` before doing any work; claim tasks from
> `06-MILESTONES.md`. **Resuming a work session?** Read
> `09-SESSION-STATE.md` first — it carries the live status, the bug being
> chased, and the remote-debugging setup, so no prior chat context is needed.
> Practice-modes / projector / auto-table plans: `08-PRACTICE-MODES.md`.

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
  CoachKit/                 ← shot coaching (ShotGuide today; LLM adapters post-MVP)
  DetectionRoboflow/        ← hosted-API detection provider (A/B eval tooling)
Scripts/                    ← bootstrap.sh, test-all.sh, format.sh
docs/roadmap/               ← the plan; 06-MILESTONES.md is the task board,
                              09-SESSION-STATE.md the live status/handoff
.github/workflows/          ← ci-core (Linux package tests), ci-app (macOS build)
.gitleaks.toml              ← CI secrets-scan allowlist (rotated legacy key only)
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
   untracked `App/Config/Secrets.xcconfig`. The pre-M0 Roboflow key that
   leaked into git history was **rotated and revoked (2026-07-21)** — the
   historical copies are inert and allowlisted in `.gitleaks.toml`; never
   reuse or paste any key anywhere in the tree.
3. **New logic ⇒ new tests in the same PR.** Pure packages hold an 85%
   coverage bar. Never weaken a test to make it pass.
4. **Don't claim device behavior works** without a committed device-checklist
   run; agents mark such work `needs-device-run` (playbook rule 6).
5. **Match existing style:** file header comments (`// Filename / CueSync AR`),
   `UpperCamelCase` types, doc comments on public API, SwiftLint clean.

## Device debugging & hard-won findings

Read `docs/roadmap/09-SESSION-STATE.md` for the current state; these are the
durable lessons that must not be re-learned:

- **Diagnostics:** everything logs under os.Logger subsystem
  `com.cuesync.ar` (categories `session`, `pipeline`, `mirror`) — filter the
  Xcode console on "cuesync". Never add a silent failure path: guards that
  swallow user actions (taps) must log AND surface HUD feedback.
- **Debug mirror:** antenna button in the HUD serves the rendered screen +
  tracking JSON at `http://<device-ip>:8787` for any browser on the LAN
  (`App/Sources/DebugMirrorServer.swift`). This is the standard way to see
  the device when it's at the table away from the Mac.
- **Camera buffers:** ARKit's capture pool is tiny. Frames are PULL-based
  (`nextFrame()`); the delegate hands out only deep-copied pixel buffers
  (`ARSessionCoordinator.copyPixelBuffer`). Never retain ARFrames or their
  buffers; the "delegate is retaining N ARFrames" console warning is the
  first symptom, a frozen/black camera the second.
- **Core ML on iOS 26:** the bundled BallDetector (coremltools-9 mlprogram)
  crashes MPSGraph on GPU/ANE ("MLIR pass manager failed") — it runs
  `.cpuOnly` until the iOS16-target re-export lands (recipe in
  09-SESSION-STATE.md). Inference must run on a dedicated queue, never on
  the pipeline actor (synchronous `handler.perform` starves the cooperative
  pool → frozen camera).
- **Model class semantics:** `cue` = cue STICK, `white-ball` = cue ball,
  `color-ball` = object balls. Dotted/measle practice cue balls classify as
  color-ball — the app covers this with tap-to-designate
  (`SessionModel.designateCueBall`, stable track IDs from BallTracker).
- **AR anchoring:** all spatial content roots under ARAnchors (table anchor
  for overlays, one shared cluster anchor for calibration corners). Raw
  world coordinates drift with ARKit's map refinements.
- **Coordinate flow:** detections → bounding-box *foot point* → intrinsics
  unprojection (`PlaneGeometryRaycaster`) → table plane → `worldToTable`.
  Vision boxes are bottom-left origin (`VisionBoxMapping` flips);
  `imageCropAndScaleOption = .scaleFill` matches the dataset's
  Stretch-to-640 preprocessing — do not "fix" either.

## Git workflow

- Branch per task: `claude/<task-id>-<slug>` (e.g. `claude/M2-03-tracker`).
  A pushed claim branch = a claimed task; tick the board checkbox in the
  same PR that completes the task.
- Default branch: `main`. Never push elsewhere without permission; do not
  open PRs unless asked.
