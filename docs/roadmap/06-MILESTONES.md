# 06 — Milestones & Task Board

Milestones are sequential gates; **tasks inside a milestone are the unit of
parallel agent work**. Each task lists: ID, deliverable, dependencies, and its
test obligation. A task is claimable when all its dependencies are merged.
Status is tracked by editing this file (see 07-AGENT-PLAYBOOK.md for the
claim/merge protocol). Legend: `[ ]` open · `[~] <branch>` claimed · `[x]` merged.

---

## M0 — Foundation Reset (sequential-ish, small)

Goal: modern toolchain, clean repo, green CI. Details in 01-TECH-MODERNIZATION.

- [ ] **M0-01** `.gitignore`; remove `Pods/` + `xcuserdata` from tree. *(deps: —)*
- [ ] **M0-02** Drop CocoaPods; SwiftPM-only project; `Packages/` skeleton (all 8 packages, empty types, placeholder Swift Testing tests). *(deps: M0-01)*
- [ ] **M0-03** Swift 6 mode + strict concurrency + iOS 26 min; SwiftUI `App` lifecycle; delete broken `AppDelegate` code. *(deps: M0-02)*
- [ ] **M0-04** CI: `ci-core.yml`, `ci-app.yml`; SwiftLint + swift-format + gitleaks; `Scripts/format.sh`. *(deps: M0-02)*
- [ ] **M0-05** Secrets pattern (`Secrets.example.xcconfig`, `SecretsProviding`); strip hardcoded key. **Maintainer: revoke old Roboflow key.** *(deps: M0-02)*
- [ ] **M0-06** Docs refresh: README, CLAUDE.md, CONTRIBUTING.md, LICENSE. *(deps: M0-03)*

**Exit:** fresh clone builds & tests green in CI without CocoaPods; no secrets.

---

## M1 — Deterministic Core (max parallelism: 4 agents)

Goal: all pure logic complete and heavily tested before any device work.

- [ ] **M1-01** `CueSyncCore` domain types + provider protocols + registry, per 02-ARCHITECTURE (this freezes the contracts). *(deps: M0-02)*
- [ ] **M1-02** `BilliardsPhysics` solver: ghost-ball, ball-ball, cushions, pockets, rollout + full unit/property suites. *(deps: M1-01)*
- [ ] **M1-03** `BilliardsPhysics` golden scenario suite (~20 JSON fixtures) + performance test. *(deps: M1-02)*
- [ ] **M1-04** `TableSpace`: transforms, calibration model, size inference + tests. *(deps: M1-01)*
- [ ] **M1-05** `CueSyncUI` design-system tokens + HUD components + snapshot suite. *(deps: M1-01)*
- [ ] **M1-06** 2D table renderer (SwiftUI Canvas) from `TableState`/`ShotPrediction` + snapshots (shared by mini-map & TV mode). *(deps: M1-01, parallel w/ M1-05)*
- [ ] **M1-07** `CueSyncTestSupport`: provider contract suites, fixture loaders, `FixtureDetectionProvider`/`FixtureRaycaster`/`MockCoach`. *(deps: M1-01)*

**Exit:** `swift test` green across packages, coverage ≥ 85%, golden physics
suite human-reviewed once and frozen.

---

## M2 — Perception (2–3 agents + one device session)

Goal: real balls become `TableState`.

- [ ] **M2-01** Model: train/export bundled Core ML pool-ball detector; eval harness + committed metrics (bar: mAP@50 ≥ 0.85). *(deps: none technically; needs dataset access)*
- [ ] **M2-02** `CoreMLDetectionProvider` (Vision request wrapper) + contract tests. *(deps: M1-07, M2-01)*
- [ ] **M2-03** `PerceptionPipeline`: scheduling, projection, Kalman tracking, identity association, stability gating + unit tests. *(deps: M1-04, M1-07)*
- [ ] **M2-04** Fixture capture tool (debug menu) + first committed fixture sets from a real table. *(deps: M2-03; **device session**)*
- [ ] **M2-05** Replay integration suite over fixtures (accuracy/stability bars from 04-TESTING-STRATEGY). *(deps: M2-04)*
- [ ] **M2-06** Optional: `DetectionRoboflow` adapter behind the same contract. *(deps: M1-07; low priority)*

**Exit:** replay suite green in CI; device checklist rows for detection filled.

---

## M3 — AR Experience (2 agents + device sessions)

Goal: the MVP core loop on a phone.

- [ ] **M3-01** `ARSessionCoordinator` + `PlaneRaycasting` impl + frame stream with latest-wins backpressure. *(deps: M2-03)*
- [ ] **M3-02** Calibration flow UI per 05-UX-DESIGN (plane → rectangle → corner handles → lock; persistence via world anchors). *(deps: M3-01, M1-04, M1-05)*
- [ ] **M3-03** `AimEngine` (device pose → `AimRay`) + unit tests on transform fixtures. *(deps: M1-01)*
- [ ] **M3-04** `OverlayRenderer`: trajectory tubes, ghost ball, pocket glow, occlusion + entity-graph unit tests + overlay snapshots. *(deps: M1-02, M3-01)*
- [ ] **M3-05** `SessionModel` composition root wiring pipeline→solver→renderer; HUD assembly; degraded-tracking states. *(deps: M3-01…04)*
- [ ] **M3-06** Device checklist run #1 at a real table; file issues; iterate. *(deps: M3-05; **device session**)*

**Exit:** MVP items 1–4 demonstrably working on device; checklist committed.

---

## M4 — TV Mode & Polish (2 agents)

- [ ] **M4-01** `DisplayKit` scene routing (connect/mirror/Table View/hot-plug) + state-machine tests. *(deps: M1-06)*
- [ ] **M4-02** Broadcast-quality Table View styling for 1080p/4K + snapshots. *(deps: M4-01)*
- [ ] **M4-03** UI test suite (fixture mode launch smoke) + accessibility pass (VoiceOver labels, Reduce Motion/Transparency). *(deps: M3-05)*
- [ ] **M4-04** Settings screen (table size override, provider selection, debug HUD) + persistence tests. *(deps: M3-05)*

**Exit:** MVP item 5 working; snapshot/UI suites green.

---

## M5 — MVP Hardening & Ship

- [ ] **M5-01** Performance/battery/thermal profiling on 3 device classes; fixes to meet 04 budgets. *(**device**)*
- [ ] **M5-02** Full device checklist (all rows) at 2 different venues/lighting. *(**device**)*
- [ ] **M5-03** Crash/analytics decision (privacy-first; opt-in only) + implementation if approved.
- [ ] **M5-04** App Store assets, privacy nutrition labels, TestFlight beta.
- [ ] **M5-05** Toolchain re-check: adopt Xcode 27/iOS 27 GM if shipped and stable; else pin and note.

**Exit:** TestFlight build meeting every MVP criterion in 00-OVERVIEW.

---

## Post-MVP backlog (ordered, not scheduled)

1. **CoachKit**: `FoundationModelsCoach` (on-device) + `ClaudeCoach`; spoken/written shot advice. *(architecture ready via `CoachProviding`)*
2. Cue-stick detection class → aim from actual cue orientation, not device pose.
3. Spin/english + speed-sensitive physics (`TrajectorySolving` v2 provider).
4. Drills & game modes (8-ball rules engine on `TableState`).
5. visionOS target (RealityKit code largely ports); tvOS companion for Table View.
6. Projector output with geometric alignment (homography from projector calibration).
7. Multi-language localization.
