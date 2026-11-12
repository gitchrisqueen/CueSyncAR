# Device dry run

A 25-minute run you can do at the table, where **nothing has to be copied or
pasted afterwards**. The app already serves its state, a live frame, recorded
session bundles and (new) its own log over the debug mirror. A script on the
Mac collects all of it into one folder and writes a pass/fail report that an
agent can read directly.

Rows refer to `docs/device-checklist.md`. This plan does not tick that
checklist by itself: a row is ticked only by copying the checklist into a dated
file under `docs/validation/` with the measured result, as that file says.

Ball-position accuracy against the diamond-grid ground truth
(`Scripts/grid-truth.py`, or `--grid` on the harness): see
`docs/validation/ground-truth-grid.md`.

## What gets collected (all automatic)

| Source | How | Lands in |
|---|---|---|
| Tracking state, HUD text, ranking, calibration, health (fps, latency, thermal, battery) | `GET /state.json`, polled every 2 s | `state.jsonl` |
| The app's own log (`os.Logger`, subsystem `com.cuesync.ar`) | `GET /logs`, tailed every 10 s | `device.log` |
| What is on screen | `GET /frame.jpg` | `frame.jpg` |
| Recorded session (frames, detections, events, outputs, manifest with commit) | `GET /sessions`, `Scripts/pull-session.sh` | `Sessions/<id>/` |
| Verdict | the harness | `report.md`, `report.json`, optional JUnit XML |

Everything goes to `~/CueSyncRuns/<UTC time>-<host>/` (outside the repo: it
holds pictures of a real room and device addresses). `~/CueSyncRuns/latest`
always points at the newest run, so you can tell an agent "analyse the latest
run" and it needs nothing else from you.

`/logs` returns the app's own recent lines as text
(`?n=300&since=900&category=session&level=notice`). It is gated by the mirror's
access policy like every other path. Values logged without `privacy: .public`
may show as `<private>`; if a line you need is redacted, mark that argument
`.public` in the code.

## 0. On the Mac, once the devices are online (2 min)

Put both devices on the same Wi-Fi as the Mac (or plug them in), unlock them,
and run:

```
Scripts/device-push.sh
```

It builds this commit once, installs and launches it on each reachable
iPhone/iPad, then checks over the mirror that the device reports this exact
commit and serves `/logs`. One line per device: `OK`, `SKIPPED: not reachable`,
or the reason it failed. Exit 0 means every selected device is verified.

- `devicectl` cannot install over Tailscale. A device that is only on Tailscale
  (for example on cellular) is reported as not reachable and skipped.
  Tailscale is for the **reading** side: state, logs and session pulls work
  over it.
- Mirror addresses live in `~/.cuesync/mirrors` (not in the repo), one per
  line: `<device UDID or name>=<LAN or tailnet host>`.
- Build only: `Scripts/device-push.sh --build-only`. One device:
  `--device "<name or UDID>"`. Release build: `--config Release` (the mirror then
  needs its per-launch token: pass `--token` to the harness).

## 1. Smoke test, no table (3 min per device)

1. Open the app. It should reach "Point at the table" (not stay on "Starting…").
2. On the Mac: `Scripts/device-dryrun.py <host>` where `<host>` is the LAN
   address from the HUD's `Mirror:` row, or the device's tailnet name.
3. Switch the phone to cellular (Wi-Fi off) and re-run the same command with
   the tailnet name. If it passes, remote observation over Tailscale works and
   an agent can watch a session you start at a venue.

Pass: `RESULT: OK`. The three required checks are `reachable`, `build_matches`
(the device runs this checkout's commit) and `logs_readable`.

## 2. Table session (15 min)

Start the collector first, in a terminal on the Mac, then do the steps below at
the table. It stops by itself after 15 minutes (`--seconds 900`) and pulls the
recorded session at the end:

```
Scripts/device-dryrun.py <host> --seconds 900 --pull-session --strict
```

At the table (the full recording procedure is in `docs/recording-a-session.md`):

| Time | You do | The harness checks | Checklist row |
|---|---|---|---|
| 0:00 | Lay out 5 to 7 balls, lights on, stand at the head rail. Open the app. | `live_tracking_seen`, `calibration_locked_seen` | 1, 18 |
| 0:00 to 2:00 | Calibrate from the pockets and lock, or let a saved table restore. Mark the cue ball if it has no white ring. | `balls_tracked`, `cue_ball_identified` | 1, 3 |
| 2:00 | Look at the shot card: it should show a percentage and a pocket for a ball. Pick a different ball. | `shot_ranked` (state `ranking.shots`) | - |
| 3:00 | Tap the red record button. Walk once around the table. Do not shoot yet. | `/sessions` shows an active bundle | 5 |
| 4:00 to 9:00 | Shoot 4 slow shots (two straight, one off a cushion, one with a called pocket). Hold still 5 s between shots. | `no_app_error`, `no_faults_in_log` | 8, 9, 12, 14 |
| 9:00 to 12:00 | Perturb: cover the cue ball for 3 s, move a ball by hand, long-press once to reset tracking. | `cue_ball_identified` recovers | 5 |
| 12:00 | Stop recording. Leave the phone on the table, screen on. | recording `last` summary present | - |
| 15:00 | Nothing: the harness ends, pulls the bundle, writes the report. | `camera_fps` >= 30, `thermal_ok`, battery drop | 16, 17 |

What "pass" means: the printed `RESULT: OK` plus every `--strict` check passing.
A failing check is a finding, not a broken run: the report says which and the
evidence is in the same folder.

## 3. After the run (no input needed from you)

Tell an agent: "analyse the latest dry run". It reads `~/CueSyncRuns/latest`:
`report.md` first, then `device.log`, `state.jsonl` and the bundle. For the
bundle it follows `docs/skills/device-session-analysis`:

```
CUESYNC_REPLAY_BUNDLE=<abs path>/Sessions/<id> swift test --package-path Packages/SessionReplay --filter "DeviceBundleReplay|RealBundleStability"
```

Replay numbers are offline evidence only. Device behaviour counts as verified
only after the checklist rows above are copied into a dated file in
`docs/validation/` with measured results.

## Same harness in CI

`Scripts/device-dryrun.py sim --seconds 0 --junit out.xml` runs the same checks
against a Simulator's mirror and writes JUnit XML, so a CI job and your device
run produce the same report format. Wiring it into
`.github/workflows/verify-sim.yml` is not done: `.github/**` is an
owner-merged surface (see the guard in `docs/skills/device-session-analysis`),
so that is a change you would approve.

## If something fails

| Symptom | Likely cause | Do |
|---|---|---|
| `SKIPPED: not reachable` | Device off the Mac's network, locked, or asleep | Same Wi-Fi or USB, unlock, re-run |
| `INSTALL FAILED` mentioning provisioning | Device not in the profile, or Xcode not signed in | Open Xcode once, sign in with the project's team; re-run |
| `LAUNCH FAILED` | Screen locked | Unlock; re-run |
| `reachable` fails but the app is open | Mirror off, or Local Network permission refused | Check the HUD `Mirror:` row and Settings, Privacy, Local Network |
| `build_matches` fails | Older build still running | Re-run `device-push.sh`; check the commit on the HUD badge |
| `logs_readable` fails with 404 | The installed build predates `/logs` | Re-run `device-push.sh` |
