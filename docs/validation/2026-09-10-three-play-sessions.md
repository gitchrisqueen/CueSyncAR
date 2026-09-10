# 2026-09-10 — three real play sessions, and what they say

Fifteen minutes of actual play on the owner's table, recorded back to back
on `main` @ `98f66c6` (the build with the fixed calibration), `iPad12,1`.
The owner played; nobody drove the app from the Mac.

The small files for each are committed beside this note. The full bundles
(≈227 MB each, with video) are on the device and were pulled to the Mac.
Re-pull any of them with:

```bash
Scripts/pull-session.sh <device-ip> device-20260910T191147Z
```

## The three sessions

| bundle | frames | mode | app touched | **cue ball** | **aim** | prediction | stick | balls/frame |
|---|---|---|---|---|---|---|---|---|
| `…190306Z` | 1301 | calledShots | 1 call-pocket | **0.0 %** | **0.0 %** | 0.0 % | 90.8 % | 10.8 |
| `…191147Z` | 1057 | freePlay | **3 × designate**, 2 call-pocket | **53.6 %** | **53.6 %** | 53.6 % | 57.1 % | 4.7 |
| `…192012Z` | 1295 | freePlay | **nothing** | **0.0 %** | **0.0 %** | 0.0 % | 71.4 % | 7.7 |

All three ran the full five-minute cap. All three had a good calibration
(cloth solved from taps, eight-foot).

## The one thing that is airtight

**Aim, prediction and cue-ball identification are the same number, to one
decimal place, in all three sessions.** 0.0 / 0.0 / 0.0, 53.6 / 53.6 /
53.6, 0.0 / 0.0 / 0.0.

Cue-ball identity is not *a* constraint on guidance. It is *the*
constraint. The stick was visible 57–91 % of the time and contributed
nothing without it; the calibration was good in all three and contributed
nothing without it. **Ten of these fifteen minutes produced no guidance of
any kind**, on a correctly calibrated table, with a real player shooting.

## What is NOT established, and must not be claimed

The obvious reading — "designating the cue ball is what fixed it" — is
**not supported by these three bundles**, because two variables differ.

- In `…190306Z` the cue ball is visibly a **measle (dotted) practice
  ball** (extracted frame 268, unambiguous at this zoom). The model
  classifies dotted cue balls as object balls; this is the documented case
  in `CLAUDE.md`.
- In `…191147Z` the cue ball **looks plain white** in an extracted frame,
  but it is small, far and motion-blurred, and a measle ball's dots are
  easy to miss at that scale. The rack state also differs (4.7 vs 10.8
  balls per frame).
- In `…192012Z` the cue ball could not be located clearly in the frames
  sampled.

So the honest statement is: **the only session that produced guidance is
the only session in which the cue ball was designated — and the ball may
also have been different.** Separating the two needs one controlled pair:
the same ball, one session designated and one not. That is ten minutes at
the table and it is the first thing to do if anyone picks this up.

Supporting but not conclusive: the detector emitted `white-ball` 31 times
in `…190306Z`'s 1301 frames at mean confidence 0.39, and the tracker
adopted a cue ball on none of them. All 13,986 tracked balls came out
`kind: unknown`.

For contrast, through the same code path on the committed fixtures
recorded at this table with a plain white cue ball: `device-lying-cue`
99.3 %, `device-aimed-cue` 54.7 %, `scripted-frozen-pair` 97.8 %. Note
that `…191147Z`'s 53.6 % sits almost exactly on `device-aimed-cue`'s
54.7 % — whatever ceiling applies to a person standing over the table
applies to both.

## What the app did right

It was never silent. With balls tracked and no cue ball,
`HUDStatus.awaitingCueBall` shows:

> **"Place the cue ball — or tap a ball to mark it"**

Accurate, names the fix, on screen for ten of the fifteen minutes.

So this is **not a silent failure. It is a loud failure that was not acted
on**, which is a different and harder problem: that sentence is a small
capsule at the top of a screen belonging to someone holding a cue. One tap
fixes an entire five-minute session, and in two sessions out of three it
was not made. The person most likely to hit this is whoever is giving a
demo. Filed as #131.

## Shot dynamics — the useful new number

`…192012Z` is the first bundle of a real player taking real shots with
the camera watching the whole table and nobody touching the app. Measured
over its 1295 frames at 4.32 Hz:

| | |
|---|---|
| consecutive-frame steps measured | 9,819 |
| median step | **0.1 cm** |
| p99 step | **1.6 cm** |
| largest step | **2.5 cm** |
| steps larger than 10 cm | **0** |
| distinct track ids | **128**, for ~8 balls a frame |

**The tracker never once observed a ball in motion.** A ball rolling at
even 1 m/s covers 23 cm between frames at this rate; the largest movement
ever seen between two consecutive frames, in five minutes of real play,
was 2.5 cm — which is jitter, not travel.

This sharpens the constraint Phase F is built on. It was already known
that a shot is a rest→rest teleport with no mid-flight samples. What this
adds is that **the teleport is not even within one track**: 128 track ids
for roughly eight balls on the cloth means a struck ball is lost and comes
back as a *new identity*. So shot detection cannot follow a ball through a
shot, and it cannot follow a ball's *id* through one either. It has to
work on the set of rest positions across identity changes.

Anything built on "watch the cue ball leave and see where it goes" will
not work on this hardware at this frame rate. That is not a tuning
problem.

## Why none of these is committed as a fixture

Each is ~5 MB of text, four times the largest committed fixture
(`device-lying-cue`, 1.3 MB), and their stability bars would assert
almost nothing: `minAimedFrameRate` is a **floor**, and two of the three
have a floor of zero. A golden whose bars are all zero pins nothing and
costs CI time on every run.

The evidence that matters — each manifest, its events, its calibration
and the measured numbers above — is committed here at 32 KB. If #131
lands, trimming ~300 frames of `…192012Z` into a fixture becomes
worthwhile, because the aim rate would then have somewhere to go.

## Recording retention — checked in the code and on the device

- Bundle ids are `device-<UTC timestamp>` from the clock
  (`SessionRecorder.makeSessionID`), so **a new recording can never
  overwrite an old one**.
- There is **no purge, prune or cleanup path anywhere** in the recorder.
  Bundles accumulate in `Documents/Sessions/` until deleted by hand
  (Files.app, or deleting the app).
- The device was carrying **13 bundles, roughly 1.4 GB**, back to
  2026-09-08.
- The only guards are at the *start*: it refuses to begin with under
  400 MB free (`requiredFreeMegabytes`) and caps one recording at five
  minutes / ~225 MB (`capSeconds`).

## No audio, of any kind

The recorder captures **no audio**. There is no
`AVAudioRecorder`/`AVAudioEngine`/`AVCaptureAudio` anywhere in the app, no
`NSMicrophoneUsageDescription` in `Info.plist`, and `VideoFrameWriter`
creates a single `AVAssetWriterInput(mediaType: .video)`. Confirmed
against the files themselves:

```
$ ffprobe -show_entries stream=index,codec_type,codec_name video.mp4
0,h264,video
```

One stream. **Spoken commentary during a recording is not captured**, and
neither is the app's own spoken guidance. Two of these three sessions were
narrated aloud; none of that audio exists. If talk-through is wanted as a
development input it has to be built — a microphone input, a usage
string, an audio track on the writer, and a privacy decision about
recording bystanders in a room.
