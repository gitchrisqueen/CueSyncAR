# 12 — Goal: simulation-first validation of the shot advisor

Written 2026-11-09. This is the brief for the next working thread. Do the bulk
of the verification in simulation on the Mac and with sub-agents on QuinVPS;
leave the physical iPhone for the final phase (section 6).

## 1. Product goal

The player points the phone at their real table and quickly sees how to shoot:
an arcade-style overlay (aim line, ghost ball, target ring, pocket ring,
difficulty card, mini-map) drawn over the real table. All displays, physics and
AR features should behave correctly. The shot advisor already exists on branch
`claude/shot-advisor` (`ShotPlanner` in CoachKit, `TableScene.Advice`,
`OverlayLayout.Suggestion`, `ShotAdvisorCard`, `RootView` wiring). It is
verified only by package tests, compile checks and macOS-rendered PNGs. It has
never been seen in the app or on a real table.

## 2. Read first

1. `CLAUDE.md` and `.claude/rules/dev-environments.md` (where work runs).
2. `docs/roadmap/09-SESSION-STATE.md` (live status; the 2026-11-07 "Shot advisor" note).
3. `docs/roadmap/10-PHYSICS-PLAN.md`, `11-EXECUTION-VERIFICATION.md`, `04-TESTING-STRATEGY.md`.
4. Remote branches `origin/claude/B2-session-replay` and
   `origin/claude/C-synthetic-harness`: they may already hold a replay or
   synthetic harness. Inspect and reuse before building anything new.

## 3. How to work across hosts

- Run the orchestrating thread on the Mac environment
  (`91b7bbef-d603-45db-ae75-7aeba95c01e8`), directory
  `/Users/christopherqueen/workspace/CueSyncAR`. Apple tooling lives only here.
- The Mac owns: simulators, `xcodebuild`, `xcodegen`, `scene-snapshot`, video
  and replay work, screenshot review, anything touching SwiftUI rendering,
  ARKit or RealityKit.
- QuinVPS (`db6c270c-761f-4124-a5ba-08bef3cebbe8`, repo at
  `/home/quin/repos/CueSyncAR`, T3 project
  `mcp:538d6634-d40a-44ab-b045-95863fe5eda2`) owns pure-package work
  (BilliardsPhysics, TableSpace, CoachKit, CueSyncTestSupport, non-UI
  PerceptionKit), tests, docs.
- Step 0, verify access before any other work, and report each result in one
  line:
  1. `device_list` works (T3 Agent device access for the Mac environment). It
     must list `CueSync-iPhone17Pro`. If it errors, tell the user and continue
     with `xcrun simctl` from Bash.
  2. `t3_environment_links` shows QuinVPS (`db6c270c-...`) reachable.
  3. Delegate a read-only check to QuinVPS: with
     `eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"`, `swift --version`
     (needs 6.1+), `swiftlint --version`, and
     `swift test --package-path Packages/CoachKit` on branch
     `claude/shot-advisor`. If Swift is missing, do not install it; do the
     Mac-only workstreams, tell the user, and say so in `09-SESSION-STATE.md`.
  4. `xcrun simctl list runtimes` shows iOS 26.3.
  5. `ffmpeg`, `yt-dlp`, `gh` are on the Mac PATH; WebSearch or WebFetch works
     for finding clips.
  6. The `playwright_chrome` MCP connected (known failing on 2026-11-09; not
     required, report only).
  Only then start the workstreams. Each QuinVPS sub-agent must set the real
  git identity (`user.name`, `user.email`) in its worktree before committing;
  the clone's default is the placeholder `tester`.
- Delegate with `delegate_task`: `target.environmentId` = the QuinVPS id,
  `isolation: "worktree"` for parallel writers, `claude-sonnet-5-5` for code
  and `claude-haiku-5-5` for mechanical checks. Call
  `orchestrator_capabilities` once first. Every brief must be self-contained:
  goal, files, branch, exact test command, "no PR, push your branch, report the
  head SHA".
- Branches: integration branch `claude/shot-advisor`. Each task branch is
  `claude/<task-id>-<slug>` cut from it, one owner per file set, no two agents
  on the same files. VPS agents push their branch. The Mac pulls, runs the
  checks, merges into the integration branch, and pushes it. Do not open PRs
  unless the user asks.
- Report every result with the exact command and its last output line. A
  sub-agent's claim is not evidence until the Mac re-runs the check.
- `CueSyncCore` is frozen: no changes outside a dedicated contract-change PR.
  New logic needs new tests in the same change. Never weaken a test to pass it.
- Commits end with `Co-Authored-By: Claude <model used> <noreply@anthropic.com>`.

## 4. Workstreams and acceptance checks

**A. Seed a synthetic table into the app (Mac).** Add a debug-only way
(launch argument and/or a debug-mirror command) to load a fixed layout into
`SessionModel` so the Simulator renders the real HUD: mini-map, advisor card
with the cycle button, the "No clean shot" capsule. Accept when
`xcrun simctl io <udid> screenshot` shows the advisor card and mini-map with the
magenta advised line, and a scripted `GET /cmd?action=nextShot` against the
mirror (port 8787, reachable from the host) changes the card and the line.
Simulator: `CueSync-iPhone17Pro`, UDID `26306759-ACAD-4488-BCF6-A93416909690`.
Debug-only code must not ship in release builds.

**B. Video-driven replay (Mac).** Take 3 or more pool clips. Fetch them with
`yt-dlp` into a git-ignored folder and keep them local; never commit footage.
Extract frames with `ffmpeg`, mark the table corners per clip in a small JSON
file, run the Core ML detector and the existing pipeline to a `TableState`,
call `ShotPlanner.plan`, and draw the advised shot over each frame into PNGs
plus a contact sheet. Reuse `Tools/DetectionEval` and anything found on the B2
and C branches. Accept when the output frames for each clip are reviewed by
looking at them, and a short written list names what fails (missed balls,
wrong cue ball, bad calibration) with example frames.

**C. Planner and physics hardening (QuinVPS).** Add property tests on random
legal layouts: a planned shot, replayed through `AnalyticSolver`, pockets the
target; no returned option has a blocked lane; ordering and hysteresis are
stable. Replace the constant jaw cones (corner 42 degrees, side 29 degrees)
with values derived from solver sweeps, or document the measured difference.
Add a speed budget test: planning 16 balls under 5 ms in release. Accept when
`swift test --package-path Packages/CoachKit` and BilliardsPhysics pass on
QuinVPS and the Mac re-run agrees.

**D. Display quality across devices (Mac).** Create iPhone SE and iPad
simulators from the installed iOS 26.3 runtime. Capture the HUD in light and
dark mode and at larger Dynamic Type sizes. Fix clipping, contrast and overlap
(card, mini-map, cue-ball guide, bottom bar). Accept when the screenshots are
reviewed and the accessibility identifiers `shot-advisor-card` and
`next-shot-button` are reachable.

**E. AR overlay without ARKit (Mac, time-boxed).** Try rendering the
`OverlayRenderer` entities offscreen on macOS with RealityKit's
`RealityRenderer`, composited over a video frame, so the AR strips, ghost
sphere and rings are visible without a device. If it works, commit it as a
tool. If not, record why and move the pure geometry into `OverlayLayout` tests.

**G. Lint baseline (QuinVPS, small).** `swiftlint lint` (the `ci-core` lint job)
exits 2 on pre-existing errors that this work did not add: two `force_cast`
errors in `Packages/TableSpace/Tests/TableSpaceTests/MeasuredSizeTests.swift`
(lines 33, 65), and in `App/Sources/SessionModel.swift` one 284-character line
(line 238) and a class body over 600 lines. Fix the TableSpace ones on
QuinVPS. Splitting `SessionModel` is Mac work and optional. Accept when
`swiftlint lint --quiet` shows no new errors.

**F. Handoff.** Update `09-SESSION-STATE.md`. Write
`docs/validation/device-checklist-shot-advisor.md` for the final phase.

## 5. Stop condition

A, B, C and D accepted, E either working or documented, F written, G done, all
package tests green (`Scripts/test-all.sh`), the device-SDK build green
(`xcodebuild ... -sdk iphoneos build`), and the integration branch pushed.
Then stop and report. Do not start the device phase.

## 6. Final phase, needs the physical iPhone (do not mark done in simulation)

- RealityKit overlay rendering on the real table, including relocalization.
- Core ML `.cpuAndNeuralEngine` test behind a crash-safe probe.
- BallTracker phantom-track fix.
- Real-shot accuracy and tuning of the jaw constants.
- Mark these `needs-device-run` until a committed device-checklist run exists.

## 7. Known missing access (user is arranging)

Swift toolchain, `swiftlint` and git push auth on QuinVPS; Agent device access
for the Mac environment in T3; the `playwright_chrome` MCP.
