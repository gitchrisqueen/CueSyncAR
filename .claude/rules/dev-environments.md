# Where work runs (set 2026-11-09 by Christopher)

Split the work between the two environments whenever both are reachable.

Do the bulk of the work and verification in simulation (simulator, rendered
snapshots, video replay). The physical iPhone is the final verification phase
only. Current brief: `docs/roadmap/12-GOAL-SIM-FIRST.md`. Integration branch:
`claude/shot-advisor`.

## Mac (this machine, T3 environment `91b7bbef-d603-45db-ae75-7aeba95c01e8`)

Everything that needs Apple tooling or a simulator stays here:

- Simulation building: simulator runs, `scene-snapshot` PNG renders, video- or
  replay-driven checks, screenshot review.
- Any `xcodebuild` build (simulator SDK and `-sdk iphoneos` device-SDK compile
  checks), `xcodegen`, anything touching ARKit/RealityKit or SwiftUI rendering.
- Device debugging over the debug mirror (port 8787) when the phone is at the table.
- Simulator device for this project: `CueSync-iPhone17Pro` (iPhone 17 Pro,
  iOS 26.3 runtime), UDID `26306759-ACAD-4488-BCF6-A93416909690`.
  The Simulator cannot run ARKit, so it shows `SimulatorPlaceholderView`; use it
  for HUD/layout only. AR behavior still needs a physical device.

## QuinVPS (`srv1309772`, T3 environment `db6c270c-761f-4124-a5ba-08bef3cebbe8`, Linux x64)

All other code development goes to sub-agents here, started with
`delegate_task` (set `target.environmentId` to the QuinVPS id, and
`isolation: "worktree"` for parallel writers):

- Pure packages: `CueSyncCore` (frozen, contract-change PRs only),
  `BilliardsPhysics`, `TableSpace`, `CoachKit`, `CueSyncTestSupport`, and the
  non-UI parts of `PerceptionKit`. These build on Linux; run
  `swift test --package-path Packages/<Name>`, the same check `ci-core` runs.
- Tests, docs, roadmap updates, lint cleanup.
- Linux cannot build `CueSyncUI` rendering, `ARExperience`, `DisplayKit`, the app
  target, or `Tools/SceneSnapshot`. Do not delegate those; they are Mac work.

Setup status (2026-11-09): the repo is cloned at `/home/quin/repos/CueSyncAR`
and registered as T3 project `mcp:538d6634-d40a-44ab-b045-95863fe5eda2` on
QuinVPS. The clone tracks `origin/main`, so it lacks unpushed Mac work.
**Blocked:** `swift` is not installed on QuinVPS (`swift: command not found`).
No package test can run there until someone installs a Swift 6.1+ Linux
toolchain. Until then, sub-agents there can only do docs and non-build work;
re-check with `swift --version` before delegating code tasks, and update this
paragraph once it works.

Probe results (2026-11-09): Ubuntu 24.04 x86_64, 164 GB free. Homebrew 7.0.9 is
at `/home/linuxbrew/.linuxbrew/bin/brew` and offers bottled `swift` 6.4.2 and
`swiftlint` 0.65.1 (Linux bottle for swiftlint unconfirmed). `gh` is logged in
as `gitchrisqueen`, the git credential helper is `store`, and `git ls-remote`
and SSH to GitHub work, so pushing branches should work. The clone's git
identity is the placeholder `tester`; set `user.name`/`user.email` to the real
identity before committing there. Install, as user `quin`, no root:

```
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
brew install swift swiftlint
swift --version   # expect 6.x
```

The `swiftly` route would also need `apt-get install gnupg2 libcurl4-openssl-dev
libxml2-dev libz3-dev` as root; the brew route does not.

## Hand-off between them

- VPS sub-agents push a `claude/<task-id>-<slug>` branch and report the head SHA
  and the exact test command with its last output line. They do not open PRs
  unless asked.
- The Mac session pulls that branch, runs the simulator/snapshot/device-SDK
  checks, and is the only side that may mark UI or AR work verified.
- Device behavior still needs a committed device-checklist run (CLAUDE.md hard
  rule 4); mark such work `needs-device-run`.
- If QuinVPS is unreachable, do the work on the Mac and say so in
  `docs/roadmap/09-SESSION-STATE.md`.
