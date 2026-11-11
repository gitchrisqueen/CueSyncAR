# 13 - Goal: calibrate and record on the iPad, remotely

Written 2026-11-10. Base: `origin/claude/dryrun-on-main` (main + mirror `/logs`
+ simulator tooling + ranking fixes, build `70e8b30`+). Do NOT use
`claude/shot-advisor` (stale, see 09-SESSION-STATE).

## Situation

The iPad (iPad 9th gen, `192.168.50.188`, tailnet `ipad-9th-gen-wifi`) is on a
stand at the head rail of Christopher's table (black cloth, 4 balls: red, orange,
white, blue; a cue stick lying on the cloth). The app `CQC.CueSync-AR` runs build
`70e8b30` in the foreground. All four pockets are in view. The table is NOT
calibrated. Christopher is not at the device: everything goes through the debug
mirror on port 8787 (`/state.json`, `/frame.jpg`, `/logs`, `/cmd?action=...`).
`devicectl` cannot reach the iPad (see memory note device-push-and-dryrun-tooling),
so no install and no tapping on the device: mirror commands only.
New builds can only reach the iPad by the over-the-air page (needs Christopher
to tap Install), so do NOT plan on shipping new app code this run.

Known from the first frame pull: the bundled detector sees the white (0.47) and
the coloured balls but mislabels or misses some, and boxes window or furniture as
`cue` (stick) with high confidence. The black 8-ball is invisible on black cloth.
Treat that as data, not as something to fix in the app tonight.

## Goal (stop when all of these hold)

1. **Calibrated.** `/state.json` shows `calibrationLocked: true`, a table size
   and `sizeVsStandard`, with the residual from the pocket fit (`pocketFit` /
   `calibration`) recorded. Use `calibrateFromPockets` (see
   `SessionModel+PocketCalibration.swift`, `handlePocketCalibrationCommand`) with
   pocket pixel coordinates read off `/frame.jpg`, or `placeCorner` x4 plus
   `lockCalibration`. Use `/cmd?action=probe` to check that known points land
   where expected. Try `tableSize` for the right size (likely 8 ft or 9 ft: ask
   the fit, do not guess). Overlay check: render the calibrated pocket and ball
   positions back onto the frame (Python or `Tools/`) and LOOK at the image.
2. **Tracking works or its failure is explained.** After lock, `liveTracking`
   is true. Record per ball: kind, position, confidence from `balls` in state,
   against what the frame shows. Designate the cue ball with `designate` if the
   white is not labelled. Write what is missed or wrong (8-ball on black cloth,
   stick false positives) with frame evidence.
3. **Shot ranking is observed.** `ranking.shots` and `activeShot` appear in state
   for the real layout. Cycle `ballGroup` / choose shots by command, and compare
   the offered shots with the frame by eye. Note any shot that looks impossible.
4. **One recorded session.** `startRecording`, hold still 30 s, `stopRecording`,
   then `Scripts/pull-session.sh 192.168.50.188 latest ~/CueSyncRuns/ipad-session`.
   Replay it per `docs/skills/device-session-analysis/SKILL.md` and quote the
   `StabilityReport` line. Footage and bundles stay OUTSIDE git.
5. **Harness evidence.** Run `Scripts/device-dryrun.py 192.168.50.188
   --expect-sha 70e8b30 --seconds 120 --strict --out ~/CueSyncRuns/ipad-cal`,
   keep the report, and say which checks fail and why.
6. **Findings doc.** Write `docs/validation/2026-11-10-ipad-remote-run.md`
   (text only, no images, no room photos): what was done, commands used,
   numbers, failures with frame evidence, and a ranked list of next fixes. Push
   it on branch `claude/ipad-remote-run` cut from `origin/claude/dryrun-on-main`.
   No PR.

## Rules

- Only the mirror, Bash, and files on this Mac. If the mirror stops answering,
  say so and stop; do not try to wake the device another way.
- Do not run `resetTracking`, `cancelCalibration` or recalibrate over a good
  lock without saying why. Do not change settings that persist on the device
  (`updateSettings`) except `tableSize`, and report it.
- Frames show Christopher's home: keep them in `~/CueSyncRuns` and `/tmp`, never
  in git, never in the findings doc. No device addresses in committed files.
- Never weaken a test. Do not touch `Packages/CueSyncCore`. Commit with the
  `Co-Authored-By: Claude <model> <noreply@anthropic.com>` trailer. No PRs.
- Report each claim with the exact command and its last output line.

## If calibration will not lock

Try in order: `calibrateFromPockets` with all 4 visible pockets; `calibrateRails`;
`calibrateEndRail`; `placeCorner` x4. After each, read `pocketSighting`,
`calibrationState` and `lastTapNote`/`lastProbe` in `/state.json` and `/logs`.
If none locks, the finding is the reason, with the log lines, plus what camera
position would make it work. That still counts as done for item 1 if documented.
