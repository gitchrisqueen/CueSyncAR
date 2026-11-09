# Video replay findings (2026-11-09)

Workstream B of `docs/roadmap/12-GOAL-SIM-FIRST.md`: real pool video replayed
through the app's own `CoreMLDetectionProvider` (shipped `BallDetector.mlpackage`,
cpuOnly), the real `BallTracker` and the real `ShotPlanner.plan` + `select`,
with the advised shot drawn over each frame. Tool: `Tools/VideoReplay`
(branch `claude/B-video-replay`). Footage, frames and annotated renders stay
outside the repo in `~/CueSyncClips/`; nothing visual is committed.

Bottom line: on this footage the detector's cue-ball class is the failure.
The cue ball was identified in 0 to 17 percent of frames, so the planner had
no usable input for most of each clip. Where it did have input, the geometry
(homography, ghost ball, pocket rings) behaved sensibly. Domain shift from
the phone-at-table training set is large: the three clips are fixed cameras
across a room or high over a table, with people, background clutter and
burnt-in overlays.

## How the replay maps to the app

| App stage | In the replay |
| --- | --- |
| `PlaneGeometryRaycaster` (ARKit intrinsics) | Plane homography from 4 hand-marked cushion corners (`clips/*/corners.json`), solved in `Homography.swift`. Default anchor is the box foot point (bottom-center), per the brief; `--anchor center` was also run and changed none of the metrics below. |
| `PerceptionPipeline` gates | Reproduced in `FrameAnalyzer`: confidence floor 0.35, cue stick detections are not balls, observations farther than 2 ball radii outside the field are rejected. `PerceptionPipeline` itself is not used (it needs `PlaneRaycasting` and camera poses). |
| `BallTracker` | The real type, fed `BallObservation`s directly. No adapter, no contract change. |
| Cue ball | Exactly one confirmed `white-ball` track, else no plan and a banner `NO CUE BALL` / `AMBIGUOUS CUE xN`. Ambiguous never happened. The app instead lets the player tap-designate the cue ball; this replay has no equivalent. |
| Planner | `ShotPlanner.plan(state:)` then `select(previous:among:)` with the previous frame's id. |

Tracker timing: the app confirms a ball after 3 frames and drops it after 30
misses at about 15 Hz (0.2 s and 2 s). Clips are 2 fps, so the default replay
uses 2 and 4 frames. The app's literal 3 and 30 were also run (`out-apptracker`);
at 2 fps they keep stale tracks for 15 s, which inflates "cue ball present"
and tracked-ball counts (numbers below).

Calibration scale check: median of detector box width over the ball diameter
the homography predicts at that spot is 0.93 (pub), 1.30 (speedpool), 1.28 (home).
The boxes include the shadow, so a little above 1 is expected. All three clips
are therefore consistent with the marked corners and table-size label; the
7 ft labels for the two bar tables are estimates.

## Per-clip numbers (default settings, 60 frames each at 2 fps)

| metric | pub-green-7ft-topdown | speedpool-bluecloth | home-9ft-breakrun |
| --- | --- | --- | --- |
| frames processed | 60 | 60 | 60 |
| mean detections (conf >= 0.25) | 7.5 | 25.9 | 14.2 |
| mean ball observations used (floor + on-table) | 5.2 | 6.6 | 4.2 |
| mean tracked (confirmed) balls | 5.3 | 6.7 | 4.5 |
| frames with a `white-ball` box passing the gates | 11.7% | 13.3% | 1.7% |
| frames with exactly one cue ball (plan possible) | 15.0% | 16.7% | 0.0% |
| frames with >= 1 viable shot | 15.0% | 16.7% | 0.0% |
| selection swaps / dropouts (consecutive frames) | 0 / 2 | 1 / 1 | 0 / 0 |
| selection changes per 10 frame transitions | 0.3 | 0.3 | 0.0 |
| frames with a stick box >= 0.3 | 98.3% | 91.7% | 83.3% |
| of those, quad passes `StickAim.quadOnTable` | 28.3% | 86.7% | 23.3% |
| observations rejected off the table | 2 | 540 | 277 |

With the app's literal tracker (3 / 30 frames, `out-apptracker`): cue ball
present 58.3% / 13.3% / 0.0%, viable shot 58.3% / 13.3% / 0.0%, tracked balls
9.1 / 9.5 / 6.2, changes per 10 transitions 0.5 / 0.2 / 0.0. The pub jump from
15% to 58% is stale tracks (9.1 tracked on a table with at most 7 balls), not
better detection. A run with `--min-confidence 0.25` (`out-floor25`) did not
help: cue-ball frames stayed at 15.0% (pub) and 0.0% (home).

Flicker caveat: low selection churn here is not evidence that the hysteresis
works. Selections only exist while the cue ball is identified (9 to 10 frames
per clip), and nearly every change is the selection appearing or vanishing
with the cue track (dropouts). The only real swap (speedpool, frame 58) and
the dropout timing are listed per clip below. A usable flicker number needs a clip where the cue
ball is detected throughout.

## Clip 1: pub-green-7ft-topdown (elevated, near top-down, phone-like)

Source and segment: see `Tools/VideoReplay/clips/clips.md`. About 7 balls on
the cloth at the start, fewer as balls are potted.

What it did well: most balls on the cloth are boxed. Corner fit is good: the
quad sits on the cushion noses in the frames viewed (20, 30, 33, 55 and the
contact sheet) and the side-pocket ring lands on the real side pocket (frames
20, 30). Shot geometry in frames 17 to 25 (selected `3>sideTop`, 12 degree
cut, medium) is plausible: cue ball at upper left, object ball in the middle,
right side pocket.

Failures (pixel coordinates are in the 680x720 frame):

- Wrong class on the cue ball. The plain white cue ball is classified
  `color-ball` in most frames (boxed as `color-ball` 56 to 79 in frames 1, 6,
  12, 28, 33, 39, 44, 49, 55 and 60). `white-ball` passes the gates only in
  frames 16 to 22, so the planner has a cue ball in 9 of 60 frames (17 to 25,
  the tracker keeps the track for 3 frames past the last box). The advised
  shot exists only in those frames.
- Missed ball. The black 8-ball (about (162, 264) in frames 33 and 55, about
  (115, 187) on the 480 px contact-sheet tile of frame 1) has no box in frames
  1, 33 and 55 although it is in plain view. In frame 55 tracked balls drop to
  2 (frames 54 to 56) and only 2 of 4 balls on the cloth are boxed.
- False balls at pockets and on skin. The right side pocket (about
  (550, 225)) is boxed as one or two `color-ball` detections in frames 17, 20,
  39, 44, 49 and 55 (two stacked boxes `color-ball 32` and `28` in frame 55).
  In frame 33 the two boxes `color-ball 41` and `42` sit on the player's
  fingers next to the pocket. A phantom ball at a pocket mouth can block or
  distort any shot into that pocket.
- Stick detection. A large `cue` box (conf 0.6 to 0.9) covers the right rail in
  almost every frame (98% of frames have a stick box). It is the rail, not the
  stick. The real stick is visible in frames 12, 22, 33 and 55 and has no stick
  box in frame 55 (stick count 0); it is boxed correctly in frames 44 and 60.
  Only 28% of stick frames pass `quadOnTable`.
- Selection: the selection appears at frame 17 and vanishes at frame 26; no
  swap. `select` kept `3>sideTop` for all 9 frames, as designed.

## Clip 2: speedpool-bluecloth (bar table, low oblique fixed camera)

Frame has a burnt-in title ("SPEED POOL"), an LED scoreboard and a large
timer card.

Failures:

- The detector fires on the overlay graphics. About 9 detections per frame are
  on the title letters, scoreboard LEDs, wall logos and the timer (for example
  frame 30: `color-ball` on each LED digit, `white-ball 42` on the "0" of the
  timer). 540 observations over 60 frames were rejected only by the on-table
  gate. That gate is the single thing that keeps them out of the tracker, so it
  is load-bearing and must not be relaxed.
- Missed and misclassified cue ball. The real white cue ball is unboxed in
  frames 30 (about (478, 663), at the stick tip), 55 (about (318, 745)) and
  58 (about (490, 782)), and in frame 22 it is boxed as `color-ball 27`.
  `white-ball` passes the on-table gates in only 8 frames (11, 47, 51, 53, 54,
  55, 56, 59).
- Wrong cue ball. In frame 55 the `white-ball 41` box sits on a yellow ball at
  about (152, 770) on the left, and the planner reports `cue ok` and draws the
  shot `47>cornerBottomLeft` (43 degree cut) from that yellow ball. In frame 58
  the same left yellow ball is still the cue track and the advised shot
  `37>cornerBottomRight` (6 degree cut) starts there too. The "report, do not
  guess" rule cannot catch this: the count of cue tracks is exactly one, it is
  just the wrong ball.
- Missed balls. In frame 22, 13 balls are on the cloth and about 9 are boxed:
  the 8-ball (371, 780), a red (278, 779) and two yellows (270, 810) and
  (268, 862) have no box. Tracked balls peak at 9 (frames 10 to 23).
- Stick detection. 91.7% of frames have a stick box and 86.7% of those pass
  `quadOnTable`, but the boxes are wall and rail segments (the horizontal
  `cue 28` box on the garage-door rail in frames 55 and 58, the right rail
  `cue 69` box in frame 30). The player's stick is boxed rarely (for example
  `cue 38` in frame 6) and not in frames 22 or 55.
- Title text: planner labels follow table space, not the screen. The pocket
  the title calls "bottom-right corner" (frame 58) is the TOP-right corner
  on screen with this corner order (and in frame 55 "bottom-left corner" is the
  top-left on screen). A mirrored calibration in the app could show the same
  mismatch on the HUD card.
- Selection: the first selection appears at frame 51; one swap at frame 58
  (`47>cornerBottomLeft` to `37>cornerBottomRight`), both while the planned
  cue ball is the yellow ball.

## Clip 3: home-9ft-breakrun (9 ft home table, oblique fixed camera across a room)

Failures:

- No cue ball, no shot. `white-ball` passes the gates in exactly one frame
  (frame 8). 0 of 60 frames have a plan. The visible white cue ball is never
  boxed on the cloth (frames 30 at about (419, 705) and 49 at about (257, 833)
  are clear examples).
- Missed balls. Frame 49: the black 8-ball (360, 760) and the purple ball
  (449, 655) are missed; frame 12: two red balls at about (228, 673) and
  (244, 671) are missed. The racked cluster in frame 1 produces only 6
  detections and tracked balls stay at 0 to 1 over frames 1 to 6 (also
  partly the 2-frame confirmation delay).
- False balls off the cloth. The pendant lamp, the shirt print (QR code) on the
  player, a floor spot below the table (frames 12, 49) and furniture produce
  `color-ball` boxes (277 rejected observations over the clip). All are
  rejected by the on-table gate.
- Overlapping boxes. Clusters of touching balls give overlapping boxes (frame
  12, balls around (452 to 475, 820)). Whether any are duplicates of one ball
  was not checked.
- Stick detection. 83% of frames have a stick box; a large `cue` box over the
  right part of the table (frames 6, 12, 22, 49 and others) is a rail or the
  table edge, not a stick. The stick held by the player is boxed rarely.
- Calibration: corner fit is good (quad on the cushions in frames 12, 30, 49).
  The camera is low, so the foot-point and sphere-center bias matters more
  than in the top-down clip. Not measured (no ground-truth positions); the
  foot and center anchors gave identical metrics.

## Cross-clip conclusions

1. Cue-ball identification is the blocker (0 to 17% of frames). Classes: white
   ball labelled `color-ball` (pub, and speedpool frame 22), no box at all
   (speedpool, home), and a `white-ball` box on a yellow ball (speedpool 55,
   with the track still on it in 58). Tap to
   designate (already in the app) and stricter wrong-ball protection
   (confirm the white colour from pixels, or require the cue ball to be the
   only ball of that colour class) are the obvious fixes to evaluate.
2. The on-table gate is essential. Between 2 and 540 off-table observations per
   clip are false balls.
3. Rail and background boxes are labelled `cue` with high confidence in
   most frames. Stick-based aiming cannot trust the class without a
   position gate stronger than `quadOnTable`.
4. Tracker timing matters for replay. The app's 3 / 30 frames at 15 Hz give
   phantom tracks when frames are far apart; replay tools must rescale it.
5. Planner suggestions looked plausible whenever the cue ball and target were
   right (pub 17 to 25). In the 19 frames that had a plan (pub 17 to 25,
   speedpool 51 to 60) none looked geometrically impossible, but the planner
   cannot know about undetected balls (8-ball missed in pub 55, home 49), so
   a clear-looking lane can be blocked in reality.
6. A flicker verdict on `select` hysteresis needs a clip with continuous cue
   detection. These clips cannot give one.

## Reproduce

Clips: see `Tools/VideoReplay/clips/clips.md` (extraction commands, source
URLs, segments). Then, from the repo root:

```
swift build -c release --package-path Tools/VideoReplay
Tools/VideoReplay/.build/release/video-replay --model App/Resources/BallDetector.mlpackage \
  --clip ~/CueSyncClips/pub-green-7ft-topdown \
  --clip ~/CueSyncClips/speedpool-bluecloth \
  --clip ~/CueSyncClips/home-9ft-breakrun
# the app's literal tracker timing (stale tracks at 2 fps):
Tools/VideoReplay/.build/release/video-replay --model App/Resources/BallDetector.mlpackage \
  --out out-apptracker --appearance-frames 3 --disappearance-frames 30 --sheet-frames 4 \
  --clip ~/CueSyncClips/pub-green-7ft-topdown --clip ~/CueSyncClips/speedpool-bluecloth \
  --clip ~/CueSyncClips/home-9ft-breakrun
# lower confidence floor / box-center anchor variants:
... --out out-floor25 --min-confidence 0.25 ...
... --out out-center --anchor center ...
```

Outputs per clip, under `~/CueSyncClips/<clip>/out/` (or the `--out` name):
`fNNNN.png` annotated frames, `contact-sheet.png` (12 evenly spaced frames),
`summary.json` (stats plus a per-frame line with cue status, shots and the
selected id). Frame numbers in this note are the 1-based file numbers
(`f0055.png` is 27 s after the segment start at 2 fps).

Frame-level claims above come from reading the annotated frames by eye; no
ground-truth labels exist. The per-clip table is measured by the tool.

Tests: `swift test --package-path Tools/VideoReplay` (homography round trip,
corner mapping, known points, perspective invariants, config parsing,
selection-flicker accounting).

What was reused: nothing from `origin/claude/B2-session-replay` (it replays
recorded device detections from `detections.jsonl`, not images, and diverges on
`ShotPlanner`/`SessionModel`) or `origin/claude/C-synthetic-harness` (synthetic
pinhole camera, no corner-to-plane homography). The image loading and PNG
writing mirror `Tools/DetectionEval`.
