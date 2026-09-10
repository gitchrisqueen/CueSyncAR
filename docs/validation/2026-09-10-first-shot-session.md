# First recorded session containing real shots

**Bundle:** `device-20260910T144906Z` — 778 frames, 181.6 s, 136 MB, iPad
(iPad12,1), build `8b467ba`, daylight (luminance ~0.54).
Local only: `Sessions/` is gitignored, and the video is 136 MB of the
owner's room.

Until this recording, **no bundle in this project contained a single real
shot.** Every fixture was either synthetic or a static table. Shot
detection — the thing all of Phase F rests on — had never been tested
against a shot.

The owner rolled one ball, then played roughly ten shots including
misses, a scratch, a re-rack and reaching in to move a ball by hand.

## The headline: keying on the cue ball is what makes it work

`FrameChangeGate`'s premise and `ShotDetector`'s central rule were both
tested here, and the second one produced the result worth keeping.

| discriminator | events found | against ~10 shots |
|---|---|---|
| any ball moved > 10 cm between rest states | **32** | 3× over-count |
| **the CUE BALL moved > 10 cm** | **10 raw → 7 clustered** | right order |

Clustering merges jumps within 5 s, because one shot can produce several
(re-acquisition after the ball is lost mid-travel).

So the design decision in the Phase F plan — *"without a cue-ball
position before and after, there is no shot claim"* — is **confirmed on
real data**. The naive "something moved" rule over-counts by 3:1 and
would have made drill scoring useless.

## The limiting factor, stated plainly

**The cue ball is identified in only 41 % of frames** (320 of 778).

That is the risk to Phase F, and it is larger than the shot-detection
question. `ShotDetector` marks an observation `.unusable` when it has no
cue-ball position on both sides of a disturbance. At 41 % availability a
meaningful share of shots will land there and have to be scored by hand —
which is survivable (the design already requires one-tap correction) but
sets a ceiling on how automatic drills can feel.

## Other measurements from the same session

- **81 % of frames are "quiet"** (every ball within 2 cm of the previous
  frame, ball count unchanged). This independently confirms the premise
  behind `FrameChangeGate`: a pool table is at rest most of the time.
- **Ball count ranged 0–7, median 4**, on a table with 6 balls. Recall
  flaps hard; several of the 32 naive "episodes" are recall flapping
  (counts moving 3→1→3) rather than anything physical.
- **`FrameChangeGate` behaved exactly as designed**, watched live:
  - static table: 57–70 % of frames skipped
  - during the ball roll: `skipped` froze for ~1.3 s while `pipelineHz`
    rose 1.2 → 1.8
  - during shots: `skipped` froze for 10+ s at a time, `pipelineHz`
    4.6–5.0, latency 108–129 ms
  That is the one case the unit tests could not cover, and it is now
  covered on hardware.
- **The bundle replays byte-equal** through `DeviceBundleReplayTests` —
  the acceptance check that had never run on real data.

## What this does NOT establish

- **No ground truth.** Nobody measured where the balls were, so this says
  nothing about positional accuracy or recall against truth. That still
  needs the tape measure.
- **No shot outcomes.** `events.jsonl` is empty: no designate, no called
  pocket, no markers. Which shot was a pot, a miss or a scratch is not
  recoverable from this bundle, so it cannot score outcome classification
  — only shot DETECTION.
- **One table, one light, one device.**

## Next

1. Trim a video-less slice into `Packages/SessionReplay/.../Fixtures/` as
   the first committed fixture containing shots (F12), after grepping for
   hostnames and paths.
2. Re-record with per-shot markers so outcomes can be scored.
3. Raise cue-ball identification, which is now the binding constraint on
   Phase F rather than the detector's shot-speed blindness.
