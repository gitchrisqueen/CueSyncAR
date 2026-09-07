## Context
Roadmap M2-04: first committed fixture set from a real table. Depends on the session recorder and the owner's table night 1.

## Scope
Ingest tooling: `Fixtures/Sessions/<id>/` text files + ≤ 6 keyframes cropped to the rail bounding box (images are added ONLY after the owner approves them by sha256), `truth.json` from the pre-printed layout cards, agent-labelled `pixelTruth.json` on camera frames, baseline `AccuracyReport`, `thresholds.json`, `docs/validation/baseline-<date>.md`.

## Out of scope
Any uncropped or unapproved image; videos in the repo.

## Acceptance
- [ ] Three real bundles (S1, S2, S7) ingested; `Replay golden (Linux)` promoted to `golden-S1` with absolute thresholds.
- [ ] Calibration-limited bundles tagged and excluded from the ratchet.

## Verification
verify:replay — golden job green with real data.

## Device follow-up
Owner: table night 1 (cards A/B, S0 size gate, S1 with pauses, S7).
