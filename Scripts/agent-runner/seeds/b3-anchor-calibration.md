## Context
After the overlay world-space fix a few-centimetre marker offset remains. Candidate cause: `PerceptionPipeline` holds the calibration frozen from lock time while overlay entities are converted into the table anchor's CURRENT transform, which ARKit keeps refining. `AnchoredCalibration.worldCalibration(anchorTransform:)` already exists.

## Scope
`Packages/PerceptionKit` (calibration update path), `Packages/ARExperience` (`advanceLiveTracking` inputs), `App/Sources/SessionModel.swift` (pass the current anchor transform each tick).

## Out of scope
Renderer changes; CueSyncCore.

## Acceptance
- [ ] A replay test with a scripted per-frame `tableAnchorTransform` that drifts by 2 cm shows the frozen-calibration path diverging and the re-derived path staying within 2 mm of truth.
- [ ] Live path re-derives calibration from the current anchor each tick behind a config flag defaulting ON, with the old behaviour selectable for A/B.

## Verification
verify:replay — test above; existing PerceptionKit suites green.

## Device follow-up
S6 relocalization bundle expected to show the largest improvement; owner re-check at the table (card A, 45 s).
