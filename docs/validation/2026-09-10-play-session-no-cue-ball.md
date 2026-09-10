# 2026-09-10 — a five-minute play session that produced no guidance at all

**Bundle:** `device-20260910T190306Z`, 1301 frames over 299.8 s, stopped by
the 5-minute cap. Recorded on `iPad12,1` against `main` @ `98f66c6` — the
build with the fixed calibration. Called-shots mode.

The small files are committed beside this note
(`2026-09-10-play-session-no-cue-ball/`); the full bundle (228 MB with
video) was pulled to the Mac and is on the device. It is **not** committed
as a fixture — see "Why this is not a fixture" below.

## What happened

Nothing was aimed. Not once, in five minutes.

| | |
|---|---|
| stick visible | **90.8 %** of frames |
| pocket called | **79.4 %** of frames (one `callPocket` event, frame 268, `cornerBottomLeft`) |
| tracked balls | mean **10.8** per frame, zero on 3 frames |
| **cue ball identified** | **0.0 %** |
| **aim line present** | **0.0 %** |
| prediction present | 0.0 % |
| called shot on line | 0.0 % |

The calibration was fine: `cloth y = -0.502`, eight-foot, solved from the
taps. The detector was working — 18,650 `color-ball` and 4,367 `cue`
(stick) detections. The surface gate clamped 243 and rejected 385, which
is ordinary.

## Why

**The cue ball was a measle (dotted) practice ball.** Extracted frame 268
shows it plainly. This is the documented case in `CLAUDE.md`:

> Dotted/measle practice cue balls classify as `color-ball` — the app
> covers this with tap-to-designate (`SessionModel.designateCueBall`).

The detector emitted `white-ball` **31 times in 1301 frames** (2.4 %),
mean confidence 0.39, and the tracker adopted a cue ball on **none** of
them. Every one of the 13,986 tracked balls came out `kind: unknown`.

**This is not a replay artefact.** The same code path, on the committed
fixtures recorded at the same table with a plain white cue ball:

| bundle | frames with a cue ball |
|---|---|
| `device-lying-cue` | 298 / 300 — **99.3 %** |
| `device-aimed-cue` | 164 / 300 — **54.7 %** |
| `scripted-frozen-pair` | 88 / 90 — 97.8 % |
| **`device-20260910T190306Z`** | **0 / 1301 — 0.0 %** |

Swapping a plain cue ball for a measle one takes cue-ball identification
from 55–99 % to zero, and with it every aim line, ghost ball and
called-shot check.

## What the app did right

It said so, continuously. With balls tracked and no cue ball,
`HUDStatus.awaitingCueBall` shows:

> **"Place the cue ball — or tap a ball to mark it"**

That is accurate, it names the fix, and it was on screen for the whole
five minutes. The recorder's own start toast says the same thing
(`"re-tap the cue ball if its ring isn't white"`).

So this is not a silent failure. It is a **loud failure that was not
acted on**, which is a different and more interesting problem: the
sentence is a small capsule at the top of a screen belonging to someone
who is holding a cue and talking, and one tap would have fixed the entire
session.

## What this is evidence for

1. **The measle ball is the default failure mode on this owner's own
   table** — the one most likely to be hit in a first demo, by the person
   demoing it.
2. **Auto-designation is worth attempting.** When exactly one tracked ball
   is unmatched and predominantly white, designating it is a better
   default than waiting. Filed as an issue rather than built, because it
   needs a table to validate and cannot be judged from this bundle alone.
3. **`awaitingCueBall` should escalate.** Five minutes in that state with a
   pocket called and a stick visible is not a status, it is a stuck
   session, and it should get louder — or the app should offer the tap
   itself.

## Why this is not a fixture

At 5.4 MB of text it is four times the largest committed fixture
(`device-lying-cue`, 1.3 MB), and its stability bars would assert almost
nothing: `minAimedFrameRate` is a **floor**, and this bundle's floor is
zero. A golden whose bars are all zero pins nothing and costs CI time.

The evidence that matters — the manifest, the single event, the
calibration and the measured numbers above — is committed here instead,
at a few kilobytes. To work with the real thing:

```bash
Scripts/pull-session.sh <device-ip> device-20260910T190306Z
```

It is still on the iPad. Recordings are never purged (see below).

## Recording retention, checked in the code and on the device

- Bundle ids are `device-<UTC timestamp>` derived from the clock
  (`SessionRecorder.makeSessionID`), so **a new recording can never
  overwrite an old one**.
- There is **no purge, prune or cleanup path anywhere** in the recorder.
  Bundles accumulate in `Documents/Sessions/` until deleted by hand
  (Files.app, or deleting the app).
- The device carried **11 bundles, 955 MB**, going back to 2026-09-08 when
  this was checked.
- The only guards are at the *start* of a recording: it refuses to begin
  with under 400 MB free (`requiredFreeMegabytes`) and caps one recording
  at 5 minutes / ~225 MB (`capSeconds`).

## No audio, of any kind

The recorder captures **no audio at all**. There is no
`AVAudioRecorder`/`AVAudioEngine`/`AVCaptureAudio` anywhere in the app, no
`NSMicrophoneUsageDescription` in `Info.plist`, and `VideoFrameWriter`
creates a single `AVAssetWriterInput(mediaType: .video)`. Confirmed
against the file itself:

```
$ ffprobe -show_entries stream=index,codec_type,codec_name video.mp4
0,h264,video
```

One stream. Spoken commentary during a recording is not captured, and the
app's own spoken guidance (TTS) is not captured either.
