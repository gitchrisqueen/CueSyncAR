# 01 — Tech Modernization (Phase 0 / Milestone M0)

Everything in this document happens **before** feature work fans out. It turns
the 2023 scaffold into a 2026-standard, CI-verified, agent-friendly codebase.
Tasks here map to milestone **M0** in [06-MILESTONES.md](06-MILESTONES.md).

## Current state (what we are migrating away from)

- Xcode starter project from Oct 2023: Swift 5.0 mode, UIKit `AppDelegate`
  hosting SwiftUI, iOS 17.0 target.
- `AppDelegate.swift` **does not compile** — it contains an unexpanded Xcode
  placeholder (`<#T##UIImage#>`) and calls an `async` method without `await`.
- CocoaPods 1.13 with `Pods/` committed; `Podfile` says iOS 15.4 while the
  project says 17.0.
- A live Roboflow API key hardcoded in `BallDetect.swift` (compromised — it is
  in git history on a public host).
- No `.gitignore`, no CI, no lint, no meaningful tests.

## Target state

### Toolchain & language

- **Xcode 26.x**, **Swift 6.3**, Swift 6 language mode with
  `SWIFT_STRICT_CONCURRENCY = complete`. All new code is concurrency-clean
  (`Sendable` correctness, actors for shared mutable state, `@MainActor` UI).
- **Minimum deployment iOS 26.0.** Rationale: iOS 26 runs on iPhone 11 (2019)
  and later — effectively the entire ARKit-capable installed base worth
  targeting in 2026 — and gives us the modern design system ("Liquid Glass"
  materials), the Observation framework everywhere, Swift Testing in Xcode's
  test plans, and the on-device Foundation Models framework for the post-MVP
  LLM coach with zero API cost. If a concrete distribution need for iOS 18
  support emerges, only the app shell is affected; core packages compile for
  older targets anyway.
- App lifecycle: replace `AppDelegate` + `UIHostingController` with a SwiftUI
  `@main struct CueSyncApp: App`. Keep a small `UIApplicationDelegateAdaptor`
  only if a UIKit hook is genuinely needed (external display scenes — see
  DisplayKit module).

### Dependencies: SwiftPM only

- Delete `Podfile`, `Podfile.lock`, `Pods/`, and the CocoaPods-generated
  workspace. The Xcode **project** (or better: the project + local packages)
  becomes the entry point.
- **Amendment (M0 implementation):** the Xcode project is *generated* by
  [XcodeGen](https://github.com/yonaskolb/XcodeGen) from a committed
  `project.yml`; `CueSyncAR.xcodeproj` is gitignored. Rationale: hand-edited
  `.pbxproj` files are the single worst merge-conflict source for parallel
  agents, and a declarative YAML definition is reviewable and diffable.
  `Scripts/bootstrap.sh` regenerates the project (`brew install xcodegen`).
- Repository restructure — app shell stays thin; logic lives in local SwiftPM
  packages under `Packages/` (full layout in
  [02-ARCHITECTURE.md](02-ARCHITECTURE.md)).
- Third-party policy: exact-version pins in `Package.resolved` (committed);
  each dependency wrapped behind a protocol we own; prefer zero-dependency
  pure-Swift libraries. Initial allowed set:
  - `swift-collections`, `swift-numerics` (Apple, as needed by physics/math)
  - `swift-snapshot-testing` (Point-Free) for rendering/UI snapshots
  - Roboflow iOS SDK **only** inside `DetectionRoboflow` adapter package,
    if we keep cloud-assisted detection at all (default detection is local
    Core ML — see 02).

### Repo hygiene

- Add a proper Swift/Xcode `.gitignore` (`xcuserdata/`, `DerivedData/`,
  `.build/`, `*.xcuserstate`, `.DS_Store`, `Secrets.xcconfig`).
- Remove committed `Pods/` and `xcuserdata` from the tree.
- Add `CONTRIBUTING.md` (points to `docs/roadmap/07-AGENT-PLAYBOOK.md`),
  `LICENSE` (MIT — README already claims it).
- Update `CLAUDE.md` and `README.md` to reflect the new structure.

### Secrets

- **Revoke and rotate the exposed Roboflow API key** in the Roboflow dashboard
  (human action — flagged for the maintainer; agents cannot do this).
- Pattern going forward: keys live in an untracked `Config/Secrets.xcconfig`
  (template `Config/Secrets.example.xcconfig` committed) surfaced through
  `Info.plist` build settings; read at runtime via a `SecretsProviding`
  protocol so tests can inject fakes. No key is required for the MVP path
  (detection is on-device Core ML).
- Add a CI secret-scanning step (gitleaks) so a leaked key fails the build.

### CI (GitHub Actions)

Two workflows, both required on PRs to `main`:

1. **`ci-core.yml`** — runs on every push. **Linux runner with the official
   `swift:` container** (amended from macOS: free-tier fast, and doubles as a
   cross-platform check that pure packages stay ARKit-free): `swift test` for
   every package under `Packages/`, plus SwiftLint and gitleaks jobs.
2. **`ci-app.yml`** — macOS runner (Xcode 26.x): regenerates the project via
   XcodeGen, builds the app for iOS Simulator, and re-runs package tests on
   the Apple toolchain (catches SwiftUI/Apple-only code paths Linux can't
   see). AR/camera behavior is device-only and covered by the device
   checklist in [04-TESTING-STRATEGY.md](04-TESTING-STRATEGY.md).

### Formatting & lint

- `.swiftlint.yml` and `.swift-format` checked in at repo root; CI enforces,
  local `Scripts/format.sh` fixes. Agents run the script before committing.

## M0 task list (details & IDs in 06-MILESTONES.md)

| ID | Task | Depends on |
|----|------|-----------|
| M0-01 | Add `.gitignore`; remove `Pods/`, `xcuserdata` from tree | — |
| M0-02 | Remove CocoaPods; migrate project to SwiftPM-only; create `Packages/` skeleton with empty targets + placeholder tests | M0-01 |
| M0-03 | Upgrade project settings: Swift 6 mode, strict concurrency, iOS 26 min, SwiftUI `App` lifecycle; delete `AppDelegate` placeholder-token code | M0-02 |
| M0-04 | CI workflows + SwiftLint/swift-format + gitleaks | M0-02 |
| M0-05 | Secrets: xcconfig pattern, `SecretsProviding`, remove hardcoded key; **maintainer rotates the key** | M0-02 |
| M0-06 | Docs refresh: README, CLAUDE.md, CONTRIBUTING, LICENSE | M0-03 |

Exit criteria: `main` builds green in CI from a fresh clone with no CocoaPods
installed, all placeholder tests pass, no secrets in tree, lint clean.
