## Context
Nothing today can replay a recorded session. The plan of record defines a `SessionBundle` (frames/detections/outputs/events/calibration JSONL plus video) and a `SessionReplay` package that replays it byte-exact on Linux.

## Scope
New package `Packages/SessionReplay` (Codable schema types, `SessionBundleReader/Writer`, `RecordedDetectionProvider`, `ReplayRunner`, `AccuracyReport`), a `FrameSourcing` protocol in `Packages/ARExperience` (pure file), `PerceptionPipeline.processFrame(_:) async -> PerceptionOutput?` (actor-isolated, awaited inline, nil on detector error), and the determinism items: injected clock for the ingest throttle and the stick-aim hold, `nearestEvent`/tracker iteration sorted by id, stick grace in seconds. `project.yml` may list the new package (that makes the PR tier B; expected).

## Out of scope
On-device recording (separate issue), video decoding, the Simulator view, CueSyncCore changes (`CapturedFrame` is frozen — use a `RecordedFrameMeta` type).

## Acceptance
- [ ] A scripted 5-ball, 30-frame bundle generated in-test replays through `ReplayRunner` and the emitted `outputs.jsonl` is byte-equal across two runs.
- [ ] `AccuracyReport` computes position RMS / recall / churn against the bundle's `truth.json`.
- [ ] The scripted bundle is committed under `Fixtures/Sessions/scripted-5ball/` and a test asserts byte-equality against its committed `outputs.jsonl` (this becomes the `Replay golden (Linux)` job's input).

## Verification
verify:replay — `swift test --package-path Packages/SessionReplay` green on Linux; golden byte-equal.

## Device follow-up
none.
