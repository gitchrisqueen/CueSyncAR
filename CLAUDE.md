# CLAUDE.md

Guidance for AI assistants working in this repository.

> **START HERE:** The adopted modernization & MVP plan lives in
> [`docs/roadmap/`](docs/roadmap/00-OVERVIEW.md). Read `00-OVERVIEW.md` and
> `07-AGENT-PLAYBOOK.md` before doing any work; claim tasks from
> `06-MILESTONES.md`. The sections below describe the **current legacy
> scaffold**, which milestone M0 of that plan replaces.

## Project overview

**CueSync AR** is an iOS augmented-reality app for billiards. The goal (per
`README.md`) is real-time detection of the table and balls, trajectory
projection, and AR overlays to coach shots — with future support for external
display/projector output and multi-platform (iPadOS / visionOS / tvOS) delivery.

**Current state: early prototype / scaffold.** Only three source files of app
code exist. The AR view still renders the Xcode starter cube, not billiards
content, and ball detection is wired up but not yet invoked with a real image.
Treat most of the README's feature list as *intended*, not *implemented*.

## Tech stack

- **Language:** Swift 5.0
- **UI:** SwiftUI (`ContentView`) hosted from a UIKit `AppDelegate` via `UIHostingController`
- **AR:** RealityKit / ARKit (`ARView`, `AnchorEntity`, plane detection)
- **ML / object detection:** [Roboflow](https://roboflow.com) iOS SDK (CocoaPods `Roboflow` 1.0.3), model `pool-ball-detection` v1
- **Dependency manager:** CocoaPods 1.13.0 (`Pods/` is committed to the repo)
- **Build system:** Xcode project + workspace
- **Deployment target:** iOS 17.0 (note: `Podfile` declares `platform :ios, '15.4'` — a mismatch; the Xcode target's `IPHONEOS_DEPLOYMENT_TARGET = 17.0` wins for the app)
- **Devices:** `TARGETED_DEVICE_FAMILY = "1,2"` (iPhone + iPad)
- **Bundle identifier:** `CQC.CueSync-AR`
- **Development team:** `8VQNRK6J32`

## Repository layout

```
CueSync AR.xcworkspace/     ← OPEN THIS (CocoaPods workspace), not the .xcodeproj
CueSync AR.xcodeproj/       ← project definition & build settings
CueSync AR/                 ← app source
  AppDelegate.swift         ← @main entry point; builds the SwiftUI window, kicks off ball detection
  ContentView.swift         ← SwiftUI view + ARViewContainer (UIViewRepresentable wrapping ARView)
  BallDetect.swift          ← Roboflow model loading + inference
  Assets.xcassets/          ← app icon, accent color
  Preview Content/          ← SwiftUI preview assets
CueSync ARTests/            ← unit tests (XCTest, @testable import CueSync_AR) — only stubs
CueSync ARUITests/          ← UI tests (XCUIApplication) — only stubs
Podfile / Podfile.lock      ← CocoaPods dependencies
Pods/                       ← vendored pods (checked in)
README.md                   ← product vision
```

Note: the module name is `CueSync_AR` (space → underscore) — see `@testable import CueSync_AR`.

## Building & running

This project uses CocoaPods, so **always open the workspace**, never the bare project:

```sh
open "CueSync AR.xcworkspace"
```

If dependencies are missing or `Podfile` changed:

```sh
pod install    # requires CocoaPods 1.13.0; regenerates the workspace/Pods
```

Then build & run in Xcode. **AR + camera features require a physical device**
(ARKit does not run in the Simulator). Running the AR view or ball detection on
the Simulator will not exercise the real functionality.

There is **no CI, linting, or formatting configuration** in this repo, and no
`.gitignore` (so `Pods/`, `xcuserdata`, etc. are tracked — be careful not to
commit editor-specific churn).

## Testing

- Unit tests: `CueSync ARTests/CueSync_ARTests.swift` (XCTest) — currently empty stubs.
- UI tests: `CueSync ARUITests/` — currently empty stubs.
- Run via Xcode (⌘U) or `xcodebuild test -workspace "CueSync AR.xcworkspace" -scheme "CueSync AR" -destination 'platform=iOS Simulator,name=iPhone 15'`.
- No tests assert real behavior yet; add meaningful coverage alongside new features.

## Known issues / gotchas (read before editing)

1. **`AppDelegate.swift` does not compile as-is.** Line ~31 contains an unfilled
   Xcode placeholder token:
   ```swift
   ballDetector.detectBalls(img: <#T##UIImage#>)
   ```
   This `<#...#>` is a code-completion placeholder, not valid Swift. It must be
   replaced with a real `UIImage` before the app will build. Also note
   `detectBalls` is `async` but is called here without `await`/`Task`.

2. **Hardcoded secret.** `BallDetect.swift` contains a hardcoded Roboflow API
   key. Do not add more secrets in source; prefer moving this to a config/secret
   mechanism. Do not paste this key into commit messages, PRs, or logs.

3. **Placeholder AR content.** `ContentView.swift` renders a generated cube on a
   horizontal plane — Xcode's default RealityKit template. Real billiards AR
   (table/ball anchoring, trajectory lines) is not implemented.

4. **Podfile vs. project deployment-target mismatch** (15.4 vs 17.0) — align
   these if you touch deployment settings.

## Conventions

- **File headers:** each source file starts with the standard Xcode header
  block (`// Filename`, author `Christopher Queen`, date). Keep this style for new files.
- **Architecture:** SwiftUI views are hosted from the UIKit `AppDelegate`
  (`@main`). ARKit surfaces come through `UIViewRepresentable` (`ARViewContainer`).
- **Naming:** types use `UpperCamelCase`; the app module is `CueSync_AR`.
- Prefer `async`/`await` for Roboflow inference (the SDK's `load`/`detect` are async).

## Git workflow

- Active development branch for AI sessions: **`claude/session-smj55k`** (create locally if absent; never push elsewhere without permission).
- Default branch: `main`.
- Commit with clear, descriptive messages; push with `git push -u origin <branch>`.
- Do **not** open a pull request unless explicitly asked.
