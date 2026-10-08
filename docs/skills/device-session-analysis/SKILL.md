---
name: device-session-analysis
description: Turn a session recorded on the device into evidence - pull the bundle with Scripts/pull-session.sh, replay it through the real pipeline with the DeviceBundleReplay and RealBundleStability suites, slice the behaviour under study with Scripts/make-replay-fixture.py, and, when it should gate future changes, commit the slice as a golden with measured stability bars.
when_to_use: Use after the owner records a session at the table ("pull the latest session", "analyse last night's recording", "make a replay fixture from this clip", "turn this bug into a golden"), or when a perception, tracking or physics change needs numbers from a real table. Not for recording itself (the owner follows docs/recording-a-session.md) and not for regenerating existing goldens.
allowed-tools: Read, Edit, Bash(Scripts/pull-session.sh *), Bash(python3 Scripts/make-replay-fixture.py *), Bash(python3 -c *), Bash(CUESYNC_REPLAY_BUNDLE=* swift test --package-path Packages/SessionReplay *), Bash(swift test --package-path Packages/SessionReplay *), Bash(du -sh *), Bash(git status:*)
---

# Device session analysis

Background: `CLAUDE.md` ("Session recorder", "Table-free iteration"),
`docs/recording-a-session.md` (how the owner records), and
`Packages/SessionReplay/Tests/SessionReplayTests/GoldenReplayTests.swift`
(the fixed eval set). Rules for the whole run:

- Pulled bundles live in `Sessions/` at the repo root (gitignored). Only
  text files of a deliberate slice are ever committed; never the video,
  never a whole bundle.
- Run `Scripts/pull-session.sh` and `Scripts/make-replay-fixture.py`; do
  not edit them, or anything under `.github/**`, `.claude/**`,
  `Scripts/agent-runner/**`, `Scripts/verify/**`, `App/Config/**` or
  `.gitleaks.toml`. Those are owner-merged surfaces.
- Do not regenerate an existing golden (`CUESYNC_REGENERATE_FIXTURES=1`)
  as part of this skill. That is a deliberate change with its own PR.
- Replay numbers are offline evidence. Device behaviour is claimed only
  after a `docs/device-checklist.md` run; until then mark the work
  `needs-device-run`. Keep the device's LAN address out of commits and PRs.

## Steps

1. **Pull (10 min).** With the app in the foreground, the Debug mirror on
   and the recording stopped: `Scripts/pull-session.sh <device-ip>
   [session-id | latest]`. Verify: it prints `done: Sessions/<id> (N
   frames, all files verified)` (a replay hint follows it). On `BAD`, `MISSING` or a dropped
   connection, re-run the same command; it resumes. Never use a bundle
   whose verification failed.

2. **Replay the whole bundle (15 min; the first build takes a few
   minutes).** Use the absolute path the script printed:
   `CUESYNC_REPLAY_BUNDLE=<abs>/Sessions/<id> swift test --package-path
   Packages/SessionReplay --filter "DeviceBundleReplay|RealBundleStability"`.
   The first run writes `outputs.jsonl` into the bundle; a second run
   byte-compares against it. Verify: both suites pass and the
   `StabilityReport [<id>]` block is printed. Copy the
   `StabilityReport [<id>]` line and the two lines under it (frames,
   seconds and dropped count; then the stability summary); together they
   are the baseline.

3. **Find the window (15 min).** Read `Sessions/<id>/manifest.json`
   (`recording`: app commit and dirty flag, detector, model hash,
   duration). List taps and resets with
   `python3 -c "import json,sys; [print(json.loads(l)) for l in open(sys.argv[1]) if l.strip()]" Sessions/<id>/events.jsonl`,
   and use the same one-liner on `snapshots.jsonl` to see when the guide
   moved. Pick a frame window `<lo>`..`<hi>` around the behaviour,
   about 300 frames like the existing device fixtures. Verify: you can say
   in one sentence what the window shows, and its frame range.

4. **Slice to scratch (5 min).** `python3 Scripts/make-replay-fixture.py
   Sessions/<id> Sessions/slices/<slug> <lo> <hi>`. Verify: the printed
   `frames.jsonl` count is `hi - lo + 1` (fewer means the recorder dropped
   frames in the window; pick another window if this will become a
   golden), `detections.jsonl` is non-zero, and there is no video file.

5. **Replay the slice (5 min).** Step 2's command with
   `CUESYNC_REPLAY_BUNDLE=<abs>/Sessions/slices/<slug>`, run twice.
   Verify: both suites pass on both runs, and the second run reports no
   golden write. Quote the slice's `StabilityReport [<slug>]` line and
   the two lines under it when reporting findings; that block is the
   analysis deliverable if nothing is committed.

6. **Promote to a golden, only if it should gate future changes (20
   min).** Slice again into
   `Packages/SessionReplay/Tests/SessionReplayTests/Fixtures/Sessions/device-<slug>`
   with the same `<lo> <hi>`, then run the step 2 command against that
   absolute path once to write its `outputs.jsonl`. With Edit, add a
   `GoldenBundle(name: "device-<slug>", stability: StabilityBars(...))`
   entry to `goldenBundles` in `GoldenReplayTests.swift`: bars at the
   measured values rounded outward (floors down, ceilings up), and a
   comment saying what the clip measures and which bar is the ratchet.
   A fixture directory without an entry fails
   `fixtureDirectoryMatchesManifest`.

7. **Verify the eval set (10 min).** `swift test --package-path
   Packages/SessionReplay --filter Golden` and then `swift test
   --package-path Packages/SessionReplay`. Verify: all pass;
   `du -sh` on the new fixture is about the size of
   `device-aimed-cue`; `git status` shows only the fixture's text files and
   the test file. Linux byte-equality is proved by `ci-core` on the PR.

8. **Report (5 min).** In the PR or the note: session id, app commit,
   window, the before and after `StabilityReport` blocks (each the
   `StabilityReport [...]` line and the two lines under it), and what is still
   `needs-device-run`. New logic needs new tests in the same PR (hard
   rule 3).
