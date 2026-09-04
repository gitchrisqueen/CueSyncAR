## Context
Agents need to see overlays on recorded frames without a device: a Simulator replay mode driven over the same mirror HTTP loop, plus a rendered-marker metric.

## Scope
`App/Sources/ReplayCameraView.swift`, `SessionModel` (`-ReplayBundle <id>` bootstrap, `useDetector(_:)`, `-UITestFixtureMode` alias), `Packages/ARExperience/ProjectedOverlay.swift` (pure), mirror `seek/play/pause/step` + `replay{…}` in `/state.json`, `Packages/SessionReplay` marker segmentation (HSV window → components → ellipse centroid; contact-point height convention: label on the camera frame, drop to the marker plane = cloth + strip lift, re-project through the recorded display transform), a `CueSyncARUITests` XCUITest target in `project.yml` (tier B, expected).

## Out of scope
RealityKit `.nonAR` parity view; any new dependency.

## Acceptance
- [ ] `-ReplayBundle synthetic-mini` launches in the Simulator and `/state.json` reports `replay.medianMarkerErrorCm < 1.0`.
- [ ] XCUITest smoke attaches screenshots at frames 0/30/60 and writes `metrics.json` with `pass: true/false`.
- [ ] `renderedMarkerErrorPt` is computed on bracket-accepted snapshots only and reported with accepted/total counts.

## Verification
verify:sim-smoke — `verify-sim.yml` artifact contains the screenshots and `metrics.json`.

## Device follow-up
none.
