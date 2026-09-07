## Context
Recording a session on the device is the one thing that makes every later iteration table-free.

## Scope
`Packages/ARExperience` (frame tap after `nextFrame()`, `lastDeliveredFrameMeta` side channel with per-frame table-anchor transform, display transform and interface orientation; bracketed 1 Hz snapshots with `arView.project` of every marker; metric-palette flag on `OverlayRenderer`), `Packages/SessionReplay` (`VideoFrameWriter` behind `#if canImport(AVFoundation)`), `App/Sources` (HUD record button, mirror `startRecording/stopRecording`, `/sessions` listing and file serving, `events.jsonl`), `Scripts/pull-session.sh` (resumable, sha256-verified).

## Out of scope
Uploading anywhere; any image committed to the repo; changes to CueSyncCore.

## Acceptance
- [ ] Records exactly the frames the pipeline processes (video ≡ detections 1:1), `frames.jsonl` written before the buffer is handed to the writer, `videoDropped` flagged on back-pressure; 5-minute cap.
- [ ] `manifest.json` records device scale, native resolution, tick rate, app SHA and model sha256, plus sha256 of every file.
- [ ] Snapshot JSON carries before/after poses and per-marker projected points.
- [ ] A 20 s recording on any flat surface with 3 balls replays byte-equal on Linux through `ReplayRunner` (owner runs the recording; the agent verifies the pull and replay).

## Verification
verify:unit for the writer/reader; verify:device for the home recording (owner task).

## Device follow-up
Owner: 5-minute home recording with 3 balls on any flat surface; keep the app foregrounded until the pull completes; confirm `frameDiag` shows `inflight 0`.
