# 2026-11-10 - iPad remote run (goal 13)

Device: iPad 9th generation (`iPad12,1`), parked at the head rail of an 8 ft
class table with black cloth and four balls (red, orange, white, dark blue), a
cue stick lying on the cloth. Driven only through the debug mirror; nobody
touched the screen. Build `1a008d5*` (dirty tree), branch
`claude/dryrun-on-main`, installed over Wi-Fi.

No images or footage are committed. Frames, state logs and the session bundle
are in `~/CueSyncRuns/` (`ipad-cal/`, `ipad-cal-strict/`, `ipad-session/`).

## Result in one line

All six goals were reached. The table calibrated and locked (24 mm rms), tracking
and ranking work on the real table, a session was recorded and replays byte-equal,
and the strict dry run passes every check except overlay latency (179 ms against
a 100 ms bar). Two real problems surfaced: the table frame drifted about 0.3 m in
ten minutes, leaving the overlay about 5 cm off the balls, and the app calls a
dark blue ball the 8-ball.

## 0. Wireless install (prerequisite)

`devicectl` could not see the iPad: Wi-Fi sync (`EnableWifiConnections`) and
Wi-Fi debugging were off, so it advertised neither `_apple-mobdev2._tcp` nor
`_remotepairing._tcp`. Fixed over one USB connection with `pymobiledevice3
lockdown wifi-connections on` and `lockdown set True
com.apple.mobile.wireless_lockdown EnableWifiDebugging`. After that
`xcrun devicectl device info details` reports `transportType: localNetwork`,
`tunnelState: connected`, and `Scripts/device-push.sh --device <ipad>` installed,
launched and verified the build. After a fresh install the mirror stayed down
until the app was relaunched once (about 10 s to come up).

## 1. Calibration

| step | command / result |
|---|---|
| Pocket pixels | read off `/frame.jpg` (2160x1620) with a coordinate grid; view points = pixels / 2 |
| Labels | clockwise on screen from the camera end: near-left = `cornerTopLeft`, far-left = `cornerTopRight`, far-right = `cornerBottomRight`, near-right = `cornerBottomLeft` (the long edge runs near to far) |
| First attempt | refused: "height: -0.5928 rejected, shape is 87 mm rms off a 8-foot table" (also 97 mm at 9 ft, 76 mm at 7 ft, which does not discriminate sizes) |
| Cause | the first picks were the pocket cups, a few cm outside the nose-rectangle corner the solver wants (it named `cornerTopLeft` as 10 cm out) |
| Fix | `Scripts/calibrate-pockets.py` pattern search on the "N mm rms" residual in `lastProbe`: 89 mm -> 27.8 mm in 38 evaluations, then the app locked |
| Final picks (view points) | TL 89:602, TR 386:334, BR 702:333, BL 972:594 |
| Result | `calibrationLocked: true`, 2.34 x 1.17 m, "8 ft table", cloth y = -0.533, "Pockets: 4 sighted ... fit 24 mm rms, worst cornerBottomRight 34 mm", height source "pocket geometry (6 spans, 28 mm rms)" |

Table size: the pockets cannot tell 7, 8 and 9 ft apart (they are all 2:1); `8 ft`
is the default and was not independently verified. The app did not suggest a
different size. Needs the real size from the owner.

Overlay check (looked at `/frame.jpg` right after lock): rings sat on all four
balls and the green pocket discs landed on the two side pockets.

## 2. Tracking

`liveTracking: true`, `Tracking 4 balls`, cue ball identified in 38 of 38 samples.
Per ball (table metres, at lock): red (0.30, 0.43) conf 0.72, tentative, `kind:
unknown`, colour red, group solid; "eight" (-0.25, -0.29) conf 0.67; orange
(0.54, -0.34) conf 0.48, tentative, `kind: unknown`; cue (-0.23, -0.03) conf 0.54.

Failures and oddities:

- **Wrong 8-ball.** The dark blue ball is reported as `kind: eight`, colour black,
  colourConfidence 0.9. It looks dark blue in the frame. Any group logic that
  trusts this is wrong on dark balls.
- **Red and orange stay `unknown`** (no number); only their colour and group are known.
- **Stick.** Offline detector run on a frame gave `cue` boxes at 0.93 and 0.69 on
  non-stick regions, as on the video clips. In the app `stickResting: true`,
  `aimSource: devicePose` and the resting stick did not capture the guide in the
  live view. But the recorded session shows `stick aim 20.8%` while the stick lay
  on the cloth, so checklist row 10 is only partly met.
- **Frame drift (important).** Ball table coordinates moved while nothing moved:
  cue x -0.23 -> -0.11 -> 0.04 -> 0.07 over about ten minutes (red x 0.30 -> 0.63,
  orange 0.54 -> 0.94), then held (cue 0.06-0.07, orange 0.94 for 90 s). The
  world-space calibration corners did not change, and the cue-to-blue distance
  stayed constant, so the camera pose estimate drifted on the parked, dim-room
  iPad. At the end the rings sit about 25 px (about 5 cm, one ball diameter) to
  the right of their balls, and the pocket discs have moved off the real pockets.
  `anchorDriftMm` stayed null. Likely worth: re-lock after the pose settles, or
  re-estimate from the pockets.
- Ball y jitters by 2-3 cm sample to sample (about 3 Hz pipeline).

## 3. Shot ranking

`ranking.shots` populated in 38 of 38 samples; active shot "78% into the bottom side"
for ball 1 (the blue ball) early on. Checked by eye against the frame: the
green line ran from the blue ball to the right side pocket, the second shot (orange to
the far-right corner) was a 0.5 degree cut, a straight line, as drawn. Concerns:

- **Side pocket optimism.** The first active shot was a 54 degree cut into a
  side pocket (ball about 40 degrees off the pocket axis), rated "easy", 78%. After
  the drift the same ball read 0.9 degrees and 100%. The percentage swings with
  calibration drift, not with the physical layout.
- Not a planner crash or a blocked lane; the three shots offered were all geometrically legal.

## 4. Recorded session

`startRecording`, 30 s hold, `stopRecording`, `Scripts/pull-session.sh <ipad>
latest ~/CueSyncRuns/ipad-session`: `device-20261111T021910Z`, 170 frames over
39.5 s, 30 MB, 0 dropped, all files verified. Replay:
`CUESYNC_REPLAY_BUNDLE=<abs>/device-20261111T021910Z swift test --package-path
Packages/SessionReplay --filter "DeviceBundleReplay|RealBundleStability"`: first run
wrote `outputs.jsonl`, the second run byte-compared and passed ("Test run with 1 test
in 1 suite passed").

```
StabilityReport [device-20261111T021910Z]
  frames 170 over 40s, dropped 0
  aimed 98.8% | stick present 100.0% | stick aim 20.8% | flips 1 (1.5/min) | heading d p95 1.20 max 1.7 | planChanged 25.3% | segs p95 2 max 3 | length p95 3.52 m | farEnd p95 2.02 m | churn 0 (4 ids, 0 short) | cue id changes 0
```

## 5. Strict dry run

`Scripts/device-dryrun.py <ipad> --expect-sha 1a008d5 --seconds 90 --strict`:
reachable, build_matches, logs_readable (154 lines), no_faults, live tracking,
calibration locked, balls tracked (4), shot ranked (38/38), cue ball (38/38), camera
fps (median 60), thermal nominal, no app error: PASS. **overlay_latency FAIL: median
179 ms (166-199), worst 267 against a 100 ms bar.** Advisory `build_clean` failed
because the build came from a dirty worktree (`1a008d5*`). The single error line in
the log is the first, refused calibration attempt. `pipelineHz` 2.7-3.3.

## 6. Carried-over items (goal 12)

| item | status |
|---|---|
| Overlay sits on the cloth (rows 6, 13) | passed at lock by eye; failed after drift (about 5 cm). No ruler measurement was possible remotely |
| Tracking identities, phantom rings after a shot (rows 5, 8) | `needs-device-run`: no shots were taken. Static churn was 0 |
| Detector compute (row 19) | consistent with main: "first Neural Engine inference returned - probe passed" |
| Jaw-cone tuning from real shots | `needs-device-run`: needs a person shooting; see `device-checklist-shot-advisor.md` item 4 |
| Video-replay failures vs real table | cue-class false positives reproduced offline (0.93); gated in the app; 8-ball on black cloth not retestable (it is now a blue ball); the dark-ball-called-8 error is new |
| Selection flicker (viability hysteresis) | 0 active-shot changes in 38 samples over 80 s with a static layout; not exercised under jitter, so not concluded |
| Left for the owner | open PRs for `claude/sim-tooling-on-main` and `claude/device-dryrun`; approve the harness in `.github/workflows/verify-sim.yml`; Ops Manager message; optional `SessionModel` lint |

## Ranked next fixes

1. Camera-pose drift on a parked device: detect it (table anchor drift is null) and
   re-lock or re-fit from the pockets once the pose settles; measure how long it takes.
2. Overlay latency 179 ms against 100 ms at a 3 Hz pipeline; check the CPU/ANE path
   and the change gate on this iPad.
3. Dark balls read as the 8-ball: a colour rule that needs the number, not just
   darkness.
4. Resting stick captured the guide 20.8% of the recording (row 10).
5. Side-pocket difficulty: rate the pocket-axis angle explicitly (54 degree cut into
   a side pocket should not be "easy").
6. `device-push.sh`: build from a clean tree so `build_clean` can pass.

## Commands used (device address omitted)

```
Scripts/device-push.sh --device "<ipad>"
curl -G <mirror>/cmd --data-urlencode action=beginCalibration
curl -G <mirror>/cmd --data-urlencode action=calibrateFromPockets \
  --data-urlencode 'pockets=cornerTopLeft:X:Y;...' --data-urlencode v=eightFoot
Scripts/calibrate-pockets.py <ipad> --size eightFoot --pocket cornerTopLeft:81:602 ...
curl -G <mirror>/cmd --data-urlencode action=startRecording   # then stopRecording
Scripts/pull-session.sh <ipad> latest ~/CueSyncRuns/ipad-session
Scripts/device-dryrun.py <ipad> --expect-sha 1a008d5 --seconds 90 --strict
```
