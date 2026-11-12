# 13 - Goal: calibrate and record on the iPad, remotely

Written 2026-11-10. Base: `origin/claude/dryrun-on-main` (main + mirror `/logs`
+ simulator tooling + ranking fixes, build `70e8b30`+). Do NOT use
`claude/shot-advisor` (stale, see 09-SESSION-STATE).

## Situation

The iPad (iPad 9th gen, `<ipad-host>`; address in `~/.cuesync/mirrors`) is on a
stand at the head rail of Christopher's table (black cloth, 4 balls: red, orange,
white, blue; a cue stick lying on the cloth). The app `CQC.CueSync-AR` runs build
`70e8b30` in the foreground. All four pockets are in view. The table is NOT
calibrated. Christopher is not at the device: everything goes through the debug
mirror on port 8787 (`/state.json`, `/frame.jpg`, `/logs`, `/cmd?action=...`).
WIRELESS INSTALL NOW WORKS (fixed 2026-11-10: Wi-Fi sync and Wi-Fi debugging were
enabled over USB with pymobiledevice3, `~/.cuesync/pmd/bin/pymobiledevice3`). To
ship a build to the iPad with no human: `Scripts/device-push.sh --device
"<iPad name>"` (builds, installs over Wi-Fi, launches, verifies the
commit over the mirror). The iPad currently runs `1a008d5` (dirty build of
`claude/dryrun-on-main`). A fresh install can leave the mirror down for up to a
minute; relaunch with `xcrun devicectl device process launch --device
D8DEB85E-71BC-5543-A755-7B9DEE565FD9 --terminate-existing CQC.CueSync-AR`. There
is still no way to tap the screen: calibration and everything else goes through
mirror commands. If the iPad stops appearing, see "Wireless install recovery".

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
   then `Scripts/pull-session.sh <ipad-host> latest ~/CueSyncRuns/ipad-session`.
   Replay it per `docs/skills/device-session-analysis/SKILL.md` and quote the
   `StabilityReport` line. Footage and bundles stay OUTSIDE git.
5. **Harness evidence.** Run `Scripts/device-dryrun.py <ipad-host>
   --expect-sha 70e8b30 --seconds 120 --strict --out ~/CueSyncRuns/ipad-cal`,
   keep the report, and say which checks fail and why.
6. **Findings doc.** Write `docs/validation/2026-11-10-ipad-remote-run.md`
   (text only, no images, no room photos): what was done, commands used,
   numbers, failures with frame evidence, and a ranked list of next fixes. Push
   it on branch `claude/ipad-remote-run` cut from `origin/claude/dryrun-on-main`.
   No PR.

## Rules

- The mirror, `Scripts/device-push.sh`, and files on this Mac. Installing a new
  build is allowed if a finding needs app code (small, reviewed diffs, tests in
  the same change, device-verified only by a dry-run report). If the mirror stops
  answering after a relaunch, say so and stop.
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

## Wireless install recovery

If `xcrun devicectl list devices` shows the iPad `unavailable`: the Wi-Fi flags
were reset. Needs one USB connection, then `~/.cuesync/pmd/bin/pymobiledevice3
lockdown wifi-connections on --udid 00008030-001435C60260C02E` and
`lockdown set True com.apple.mobile.wireless_lockdown EnableWifiDebugging --udid
00008030-001435C60260C02E`. Do not ask Christopher for anything else first.
iPad settings he keeps: Auto-Lock Never, Low Power Mode off, Private Wi-Fi Address
Fixed (fine), power connected.

## Carried over from goal 12 (`12-GOAL-SIM-FIRST.md`): nothing is dropped

Goal 12 is finished for its own branch: `claude/shot-advisor` (pushed, stale
base: never install or merge it). Its ported pieces live on
`claude/sim-tooling-on-main` (seed, XCUITest, large-type HUD fixes, three
`ShotRanking` fixes, ranking property tests). This goal's base
`claude/dryrun-on-main` already contains it. Still open, in this order of
relevance to this run:

1. Device phase of goal 12, partly covered here: overlay sits on the real cloth
   (checklist row 6, 13), tracking identities and phantom rings after a shot
   (rows 5, 8), detector compute (row 19 is already verified on main; do not
   redo), jaw-cone tuning from real shots (`docs/validation/
   device-checklist-shot-advisor.md` item 4: only needs a person shooting, so
   list it as `needs-device-run`, do not fake it).
2. Findings from video replay (`docs/validation/2026-11-09-video-replay-findings.md`
   on `claude/shot-advisor`): cue-ball class weak, stick class fires on rails and
   windows, 8-ball lost on dark cloth. Compare with what the iPad shows and say
   whether the same failures appear on the real table.
3. `ShotPlanner` viability hysteresis (a shot 0.4 mm outside a lane flickers):
   applies to `ShotSelection` on main too; test it on real jitter from the
   session and note it, fix only if cheap and tested.
4. Remaining items for Christopher, NOT for this run: open a PR for
   `claude/sim-tooling-on-main` and `claude/device-dryrun` (he said no PRs for
   now); approve wiring `Scripts/device-dryrun.py` into
   `.github/workflows/verify-sim.yml` (`.github/**` is owner-merged); decide the
   Ops Manager thread message on worktree isolation for linked environments
   (text kept in the chat); `type_body_length` lint on `SessionModel` (optional).
5. Process notes: QuinVPS agents share one checkout (no worktree isolation),
   identity is `tester` until set; `agent-device` runner needs `prepare ios-runner`
   first; two simulators cannot both serve port 8787.

Close this goal when the six goals above hold AND items 1 to 3 each have a line
in the findings doc (done, measured, or `needs-device-run` with the reason).
