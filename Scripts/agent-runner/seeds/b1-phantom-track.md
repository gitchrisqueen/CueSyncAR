## Context
On the real table a struck cue ball reappears as a new track at its destination while the original track stays frozen at the shot origin for ~3.5 s (`disappearanceFrames` 30 at the observed tick rate), drawing a phantom ring and a stale prediction line. Recorded in `docs/validation/2026-07-23-T1-device-verification.md` (Finding 2).

## Scope
`Packages/PerceptionKit` (`BallTracker`, `TrackerConfig`) and its tests. `BallTracker` is a pure `Sendable` struct, so a scripted observation sequence reproduces the bug without any bundle.

## Out of scope
Empty-neighbourhood retirement that would regress occlusion robustness; any change to `PerceptionPipeline` scheduling; CueSyncCore.

## Acceptance
- [ ] A replay-style test feeds a scripted observation sequence (ball at A for N frames, then only at B ≥ 0.5 m away) and asserts the A track is retired within ≤ 1.0 s of frame timestamps while `isVisible=true`.
- [ ] The same suite asserts a track still persists indefinitely while `isVisible=false` (out of view must not decay).
- [ ] Existing phantom-twin / overlap merge tests stay green.

## Verification
verify:unit — the new test fails before the fix and passes after; `swift test --package-path Packages/PerceptionKit` green; coverage floor unchanged or higher.

## Device follow-up
none (later confirmed by the S4 shot bundles).
