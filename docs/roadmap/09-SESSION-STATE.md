# 09 — Session State & Handoff

**Purpose:** land the *current working state* in the repo so any fresh agent
(or human) can resume without a prior chat session. Update this file whenever
a work session ends or a major finding lands.

**Last update: 2026-11-12.** Work resumed on 2026-11-09 after the pause of
2026-09-10. The live brief is [`14-GOAL-POLISHED-APP.md`](14-GOAL-POLISHED-APP.md);
the newest entry is directly below.

**Read [`docs/HANDOVER.md`](../HANDOVER.md) first.** It supersedes this
file as the entry point: it says where the project actually stands, the
four findings worth knowing before touching anything, and what to do
first. This file remains the running log of how each finding was reached,
newest first, and is worth reading for the reasoning rather than the
status.

### 2026-11-12, 20:30 — resumed; the iPad is locked, the Simulator boots again

The timer woke the thread on time and removed itself.

- **iPad:** on the network and paired, but locked. The device link answers
  "The device has not been unlocked recently" and the app's mirror refuses
  connections. Nothing can be installed, launched or measured until the
  owner unlocks it. A watcher checks once a minute for two hours and
  resumes the device checks when it unlocks.
- **Simulator:** boots again without a Mac restart (the stuck helper
  processes had gone by evening). `claude/state-gallery` is capturing the 42
  scenes and running the three unrun UI test files.
- Next, with no device needed: an independent design re-score from the
  gallery and the device stills of 2026-11-11 and 12.

**22:45.** `claude/state-gallery` (`bf1a9d1`) merged at `e957ee8`: 160 stills
of 43 scenes on the iPad and iPhone SE simulators (kept locally), 20 of 20
UI tests passing on the SE, and the layout defects the stills showed fixed
(a headline breaking inside a word, a truncated label, a tier chip wrapping
at the largest text size, a called pocket that looked like no call, a
"table moved" capsule that did not look tappable, mixed "9-ft" and "9 ft").
From clean: `Scripts/test-all.sh` exit 0 (11 test runs), Release iphoneos
`** BUILD SUCCEEDED **`, swiftlint 16 violations, 0 serious. Pushed. Not on
the iPad: it was still locked at 22:30, so the iPad runs `65c86a8`. The
design re-score is in flight on `claude/ux-rescore-2`.

**23:15. Design re-score: 63/100** (`docs/design/2026-11-12-ux-rescore-2.md`,
merged at `c3d872d`). The baseline's lens scores add up to 48, not the 46 it
printed, so the comparison is 48 to 63. Target 70. Two of the eight checks
pass (overlay clutter, no developer text). Trust did not move (2.5) because
the HUD says things that are not true: a tick and a shot card beside "Lost
the table", "On line" when the shot is off line or no pocket is called, and
ball counts that include the cue ball in one message and not in another.
The object leg to the pocket is the faintest mark (11 px at 3.4-3.7:1; the
cue leg is 14 px at 9.9:1). Status text misses the size floor by 1 px.

In flight on that report, neither needs the device:
- `claude/hud-truth`: the ten HUD items (one truth when tracking is lost,
  "On line" only when true, one counting rule, a make as an event in the
  card slot, 28 pt status text, HARD distinct from BLOCKED, number-first
  ball names when the number is known, Settings copy, footnote contrast).
- `claude/overlay-contrast`: the object leg as the strongest mark, one hue
  per meaning, and contrast held on black, green and blue cloth.
After both merge: a third independent re-score.

**2026-11-13, 01:30. Both merged at `299ffce`, green and pushed.** From clean:
`Scripts/test-all.sh` exit 0 (11 test runs), Release iphoneos
`** BUILD SUCCEEDED **`, swiftlint 16 violations, 0 serious.
- `claude/overlay-contrast` (`8c1229a`): the object leg is white and 26 mm
  wide, the cue leg cyan and 16 mm, the pocket ring pink and larger, every
  role its own hue, each on a dark casing so it holds at least 6.8:1 on
  black, green and blue cloth. It edited the four golden replay fixtures;
  a token-by-token comparison shows only the three recorded colour values
  changed. Nothing of this has been seen on real cloth.
- `claude/hud-truth` (`c08cab0`): one amber capsule when tracking is lost
  (no tick, no count, no card, no pill), "On line" only with a called
  pocket and a matching aim, object-ball counts everywhere, a made shot as
  a 1.2 s event in the card slot, 28 pt status text on iPad, HARD orange
  and BLOCKED red, number-first ball names when the tracker has a number,
  Settings in player words. 24 of 24 UI tests pass on the SE; the gallery
  is re-captured (182 stills, 46 scenes).
The third re-score is in flight on `claude/ux-rescore-3`. It can judge the
HUD from the gallery, but not the new overlay: the iPad stayed locked all
evening, so no device still of the current build exists.

**02:15. Third re-score: 70.0/100, plus or minus 6**
(`docs/design/2026-11-13-ux-rescore-3.md`, merged at `5473712`). Three
scores on one rubric: 48, 63, 70. Four of the eight checks pass (size,
overlay clutter, no developer text, state coverage). Trust 2.5 to 3.5.
**This does not show the target is met.** The score rests on Simulator
stills for the HUD and on an OLD device still for the overlay (the
reviewer kept that lens at 3.5 and says the old still alone would earn 3,
which would make 69). Its first recommendation is a capture of the
current build on the iPad in a dim and a bright room.

New defects it found, in flight on `claude/hud-called`: a called shot can
name two different pockets on one card; the called card is four rows tall;
the card jumps 9 px when the aim goes off line; the blocked card's reason
does not match what is drawn; Settings picker values under 4.5:1; "Open"
in Settings against "Any group" in the bar; "cushion-nose" in setup words.

Blocked on the owner: unlocking the iPad (it runs `65c86a8`), the
accuracy-target decision, and the tape measurement of the table.

### 2026-11-12, 04:00 — `65c86a8` green and on the iPad; the Simulator will not boot

`claude/state-gallery` (`2f8aa8d`) is merged: 42 seeded HUD scenes behind
`-seedScene <name>`, Debug Simulator builds only, plus a new UI test file
(`docs/design/state-gallery.md` lists the scenes and the three states the
Simulator cannot reach). **None of it has been seen running.** Every
simulator on the Mac hangs at boot (`xcrun simctl boot` does not answer
within 120 s, a fresh device included). Restarting CoreSimulatorService did
not help. The owner needs to restart the Mac; then build the Simulator app
and run the capture scripts kept in `~/CueSyncRuns/goal14/gallery-tools/`.
The three UI test files edited this week are still unrun.

Also in `65c86a8`: the shot card is hidden while tracking is degraded
("Hold steady", "Re-finding the table", "Need more light"); it used to keep
a confident tier word (`HUDStatus.allowsShotAdvice`).

From clean: `Scripts/test-all.sh` exit 0 (11 test runs), Release iphoneos
`** BUILD SUCCEEDED **`, swiftlint 16 violations, 0 serious. Pushed, and
installed on the iPad (dark room, on a charger, battery 45, not calibrated).

Nothing is running now. The thread resumes at 20:30.

### 2026-11-12, 03:00 — green again at `1509e4a`, installed on the iPad

`claude/far-recall` (`3ba1522`) put the sparse-track behaviour behind
`TrackerConfig.gapGraceMultiple`: 0 by default, 6 when the far tile is in
use. The committed recordings have no tile, so the golden replays match
again without being regenerated and the stability bar holds. It also paces
the tile to a 45 ms detection budget. `claude/overlay-latency` (`c86c9c7`)
added a pooled renderer, a detached frame hand-in and more latency stages.

Merged at `1509e4a`. From clean: `Scripts/test-all.sh` exit 0 (11 test
runs), Release iphoneos `** BUILD SUCCEEDED **`, swiftlint 16 violations, 0
serious. Pushed, then installed on the iPad (the room is dark, so nothing
on it is verified: it shows "Tap anywhere to calibrate the table"). The
iPad is on a charger (battery rose from 35 to 40).

Not measured on a device yet: the pooled renderer's cost, the detached
hand-in, the tile's real period and detection time, and whether 16 of 16
still holds with the tile on every fourth frame.

### 2026-11-12, night — head `e898b55` is NOT green

`claude/far-recall` (tracker fix for sparse balls, tile on every frame),
`claude/overlay-latency` and `claude/ball-names` were merged at `e898b55`.
`Scripts/test-all.sh` from clean then exited 1: SessionReplay's golden suite
fails with 3 issues (`replayMatchesTheCommittedGolden` for
`device-aimed-cue` and `device-lying-cue`; `stabilityClearsTheBars` for
`device-aimed-cue`, `planChangedRate` 0.237 against a 0.23 bar). The cause
is the tracker change in `claude/far-recall` (the suite fails on that branch
alone and passes on `claude/ball-names`). The other ten packages pass and
the Release build succeeds.

`e898b55` was pushed and installed on the iPad before that result was read.
That was the orchestrator's error: the push was chained behind the gate
command. The fix is in flight on `claude/far-recall`; the stability bar is
not to be raised. The last green head is `8f1e2d7`.

Provisional numbers from that build on the iPad (to be repeated on a green
head):
- 16 of 16 balls tracked, 24 of 24 samples over 60 s, every id present in
  every sample, one cue id, one eight, no name changes.
- The card reads "Maroon ball" for the maroon 7 (it said "Orange"). Four
  balls carry no colour name: both purples (by design), the green 6 and the
  blue stripe 10 (not expected).
- Camera to drawn, from the new `health.latency` meter: median 254 ms, worst
  341. Stages: ARKit delivery 43, resume 3, pipeline 127, hop 26, wait 14,
  render 49. The tile on every frame took `detect` from 27 ms to 85 ms.
  `overlayLatencyMs`, quoted until now, stops when the result reaches the
  main actor and never included the wait or the draw.

**Paused for the night (01:00, 2026-11-12).** The owner turned the pool
room lights off and asked for device work to resume at 20:30 the same day.
A one-shot timer on the Mac wakes the orchestrator thread then. No device
check is possible in the dark.

Running overnight, none needs the device:
- `claude/far-recall`: make the golden replays and the stability bar pass
  again, then bring tile detection under 45 ms.
- `claude/overlay-latency`: pooled renderer (the 49 ms render), the 38 ms of
  unaccounted pipeline time, the 26 ms hop.
- `claude/state-gallery`: every HUD state reachable in the Simulator from a
  launch argument, captured on the iPad and iPhone SE simulators, layout
  defects fixed, the edited UI tests run.

On each completion: merge, run the full gate, READ its result in its own
step, and only then push and install.

First things with the lights on: install the newest green head, lock, and
repeat the checks on it (16 of 16 balls, latency stages, ball names, why the
green 6 and the blue stripe 10 had no name, the stale-lock banner on the new
HUD, the parked hold). Then an independent design re-score from the gallery
and fresh device stills (baseline 46/100, target 70).

### 2026-11-12, later — seven more branches merged, build `20eab26` verified on the iPad

Merged into `claude/grid-truth` and gated from clean (`Scripts/test-all.sh`
exit 0, 11 test runs; Release iphoneos `** BUILD SUCCEEDED **`; swiftlint 0
serious): `claude/ranking-audit`, `claude/overlay-hero`, `claude/map-error`,
`claude/hold-rearm`, `claude/pipeline-truth`, `claude/hud-read`,
`claude/far-recall`.

**Verified on the iPad over the mirror (build `20eab26`):**

| check | result |
|---|---|
| phantom aim | `hasPrediction` false at launch with "device is parked" saved; no thin lines |
| overlay | white cue leg, green object leg ending in a ring on the pocket mouth, no plates under other balls (still `/ui.jpg`); the cross-fade and pulse are not judged |
| shot percentages | 97 / 93 / 77 / 74 / 69 / 67 on the grid layout (was 93-94 for every shot) |
| parked hold | with 1.16 degrees of ARKit drift held, `parked` off and on left the grid shift unchanged within 0.3 cm (the old build moved 10-15 cm) |
| stale-lock banner | still raised by the simulated 0.9 m shift on the earlier build; not repeated here |
| lock evidence | present under `pose.lockEvidence` after a real lock |
| HUD | headline, bar and state line read as designed; the card was 93 % of the screen wide and is 780 pt from `20ad8f9` |

**Where the time goes** (`health.stageMs`, 15 balls): detect 27 ms, pipeline
total 30 ms, ranking 0.6 ms, hand-off to the main actor 35-42 ms. The rate
was capped by a fixed 150 ms sleep in the AR loop, added on top of the work:
3.8 ticks a second, 165 ms overlay latency. `20ad8f9` paces the loop to a
100 ms period (`LoopPacing`). Measured on the iPad on `20e742d`: 8.1-9.0
ticks a second, thermal nominal, tracking unchanged (15 balls, one eight,
one cue id over 30 s). Overlay latency did NOT move: 157-207 ms, worst 239.
A finished result seems to wait for the next loop tick before it is drawn,
and the mirror's once-a-second JPEG takes 100 ms on the main actor. In
flight on `claude/overlay-latency`. The CPU detector is not the bottleneck,
so the Neural Engine re-export is not needed for speed.

**Far tile (`/cmd?action=farTile&v=1`, off by default).** Offline on 50
recorded frames a zoomed pass over the table finds the dark blue ball in
98 % (0 % at full frame) and lifts the cue ball from 38 % to 100 % above
the 0.35 floor. On the iPad the ball is detected (confidence 0.31-0.56) but
its track restarts every few seconds (ids 47, 51, 55 in 24 s) with the tile
on every second frame. In flight on `claude/far-recall`: every frame, the
region from the locked table, and a tracker fix.

**Accuracy.** Ten locks from the recording agree to 0.3 cm and 0.1 degree,
so the lock is repeatable. What remains is a fixed bias: the pockets and
rails fit a cloth tilt of about 1.0 degree and the balls need 1.45. Best
candidate 2.62 cm (not implemented), floor 1.82 cm with the balls on known
spots, locks on the device 2.6-3.9 cm. A spirit level on the slate, a ball
on a tape-measured spot, or a higher camera would separate the causes.

**Ball names are wrong in places.** The card called the maroon 7 "Orange".
In flight on `claude/ball-names`, measured against the recording.

**Confidence floor.** At 0.35 the detector's weak balls drop out on some
frames (11 below-floor detections in 14 samples); at 0.25 none did and no
false ball appeared in 30 s. The default is still 0.35.

### 2026-11-12 — goal 14: five branches merged, merged build verified on the iPad

Integration branch: `claude/grid-truth`. `claude/shot-advisor` is a stale
base; do not build on it.

**Merged at `8bd2dbb`** (from clean: `Scripts/test-all.sh` exit 0, Release
iphoneos `** BUILD SUCCEEDED **`, swiftlint 0 serious, 25 Python tests OK):
`claude/grid-harness`, `claude/calib-health`, `claude/ball-identity-2`,
`claude/missing-ball-diagnosis`, `claude/ux-rescore`.

**Verified on the iPad, build `34acd56`, driven over the mirror:**

| check | result |
|---|---|
| six-pocket lock | fit 5.0 mm rms, tilt 0.96 deg, cloth y -0.636 |
| `Scripts/grid-truth.py` | n=14, rms 3.0-3.1 cm, max 5.8 cm |
| balls named `eight` | 1 in 24 of 24 samples over 60 s (was 4 on `564f8b2`) |
| track ids | all 15 present in every sample |
| colour names | one ball flipped between maroon and orange |
| stale-lock banner | `/cmd?action=nudgeOrigin&dy=0.9` (table shifted 0.9 m): `suspect` at 1 s, `stale:offTable` at 3.3 s, capsule "Table moved? Re-calibrate", no overlay, no shot card; healthy again after `dy=-0.9` |

The banner is verified against a simulated shift only. A physical bump of
the device is still `needs-device-run`.

**Not fixed yet (measured on the same build):**
- Ball error is about 3 cm rms. A fit of measured against grid positions
  leaves 1.2-1.5 cm after an affine or homography map, so that much is noise
  and the rest is a smooth map error (x scale 0.956-0.982 in every lock).
  The pocket fit lands on about 0.9 degrees of tilt whichever table size is
  used. Diagnosis in flight on `claude/map-error`.
- 14 of 15 object balls tracked. The missing one is the dark blue ball at
  the far centre, next to the orange ball in the image.
- Pipeline 2.3 Hz, overlay latency about 335 ms with 15 balls.
- "Device is parked" is on, yet `aimSource` stays `devicePose`: the thin
  lines and the second ghost ball are an aim drawn from the tripod.
- Every offered shot reads 93-94% "Easy".

**Found while testing, 2026-11-12: re-arming the parked hold moves the table.**
Sending `/cmd?action=parked&v=0` and then `v=1` on a table locked 30 minutes
earlier left every ball 10-15 cm sideways: `Scripts/grid-truth.py` went from
3.1 cm rms to 12.8 cm rms (max 17.8), one grid point claimed twice. The HUD
still read "Tracking 15 balls", calibration health stayed `healthy`, and the
card offered a shot at 99%. Cause: turning "device is parked" off drops the
hold's correction, and turning it on again freezes the camera at ARKit's
current pose, which has drifted since the lock. The stale-lock monitor only
sees gross shifts (most balls off the table), so this one is silent. A fresh
lock repaired it (3.2 cm rms). Until it is fixed: after any `parked` or
`parkedHold` change, lock again. Not yet fixed in code.

The same test confirmed the phantom aim's cause: once the parked setting was
applied again, `hasPrediction` went false and the thin lines disappeared. The
setting stored from the last run is not applied at launch.

**Map-error diagnosis (merged, `docs/research/2026-11-12-map-error-diagnosis.md`).**
No single cause. The largest part is a shift (1.1-3.8 cm) and a rotation
(0-1.2 degrees) that change with every lock: noise in the pocket sightings,
the same size as the leave-one-out error the app reports (18-27 mm). The 0.9
degree tilt is not the cause, a level plane is worse, and `clothFromBalls` is
off by at least 30 mm. With the balls on known spots the best possible is
1.74-1.86 cm, so the 2.0 cm target sits on the floor for this camera position.
Table size cannot be read from this data.

**The missing ball is never detected.** A 148-frame recording of the grid
(kept locally) has 0 detections on the dark blue far-centre ball at any
confidence of 0.25 or more. It sits directly behind the orange ball as the
camera sees it. Lowering the 0.35 floor cannot bring it back. The same
recording shows the cue ball at a median confidence of 0.43 and a minimum of
0.27, so the floor does drop the cue ball on some frames.

**In flight (one branch each, all on the Mac).** Cut from `34acd56`:
`claude/pipeline-truth`, `claude/overlay-hero`, `claude/hud-read`,
`claude/ranking-audit`. Cut from `581d8a8`: `claude/hold-rearm` (the parked
hold must not move the table), `claude/far-recall` (detector recall on small
far balls), and `claude/map-error` continues with lock precision (pocket
snaps over many frames, cushion-nose lines) against the recording.

**QuinVPS was not used.** `delegate_task` to it failed on 2026-11-12 with
`capability_denied` ("The linked environment no longer accepts this link"),
so the pure-package task ran on the Mac too. The link needs renewing by the
owner.

**Owner actions open:** measure the playing surface with a tape (diamond
spacing 11.0 in means 88 x 44, 11.5 in means 92 x 46); put the iPad on a
charger (battery 45%, falling about 5 points per 25 minutes); a higher
camera mount would cut every position error (the camera is about 0.6 m
above the cloth, and at the far row 1 cm of height error moves a ball 5 cm).

**Owner ruling, 2026-11-12:** goals 13 and 14 once carried the device's
address and name; both now use placeholders. The older commits keep them
and the history is left as it is. No force-push.

Local evidence, never committed: `~/CueSyncRuns/goal14/`.

### 2026-09-10 — calibration finished, and the reason it was wrong

The last working session. Both calibration paths were driven remotely
against the parked iPad over the debug mirror, which is how the cause was
found rather than argued about.

**The finding.** Every calibration path rested on a cloth height measured
from the apparent size of the balls. On one table in one session that
estimate reported `-0.349`, `-0.370`, `-0.512` and `-0.229` — 283 mm of
range — against a truth of `-0.528`, while reporting 8–15 mm of "spread"
throughout. Spread measures whether the balls agree with *each other*,
and the error is systematic: at 2.4–4 m a ball is about sixteen pixels
across, so one pixel of box error is six per cent of range and three
centimetres of cloth. Every sample moves together, and adding balls
tightens the spread without touching the error.

That is both symptoms the owner reported — the quad floating above the
cloth, and the lines sliding when the device angle changed.

**The fix.** The height never needed measuring. It is determined by the
tap rays (exact) and the table size (chosen from a list): rays from one
place fan out, so exactly one depth cuts a 2.34 × 1.17 m shape out of
them. Height became an *output* of the calibration, with a residual.

| path | result, driven over `/cmd` |
|---|---|
| pockets, four corners tapped | cloth solved to 6 mm rms, table fit **5 mm rms** |
| corners, tapped **out of order** | tightened **-144 mm**, locked 2.34 × 1.17 m — *"8 ft +1.0 cm"* |

**What the pockets cannot do, and why the balls stay.** Every standard
table is exactly 2:1, so a nine-foot table's pockets are a uniform
scaling of an eight-foot table's — and moving the plane is a uniform
scaling. Solving for the wrong size fits perfectly at a proportionally
wrong height, residual zero. The ball estimate is the only measurement
independent of that choice, and is now asked for nothing else.

**Also landed** (#127, #128, #129): a four-pocket minimum with a fit that
can be refused; refusals that name the bad pocket instead of guessing
"stand closer"; drift tracking, so an estimate still converging cannot
read as settled; `/cmd?action=probe`, which unprojects one view point and
reports the world point and range — the command the 158 mm was found
with; multi-table storage, so a second venue stops silently destroying
the first; and the verification overlay, which draws the eighteen
diamonds the candidate calibration implies back onto the cloth.

**Not verified:** that the diamonds *look* right on a real table.
`/frame.jpg` is an ARView snapshot with no SwiftUI in it, so the overlay
cannot be photographed remotely. First person at the table sees it first.

---

**Previous update: 2026-09-09 (agent session, `main` @ `8a1f96d`).**
Twelve PRs merged across three sessions. All four device-visible symptoms
the operator reported have fixes, each measured against recordings of his
own table rather than argued from the code. Read "2026-09-09" below —
it supersedes the 2026-09-07 notes, which are kept for context.

## Track identity (Phase 3.1) — what landed, and the knob NOT turned

Branch `fix/track-identity-churn`. Measured on the two committed device
bundles through `Packages/SessionReplay`; no device needed, and both
bundles' `outputs.jsonl` were regenerated deliberately.

| bundle | ids before → after | churn before → after | cue id changes |
|---|---|---|---|
| `device-lying-cue` (static layout, 66 s) | 14 → **8** | 6 → **0** | 0 → 0 |
| `device-aimed-cue` (active play, 66 s) | 18 → **14** | 11 → **7** | 4 → 4 |
| `scripted-5ball` | 5 → 5 | 0 → 0 | byte-identical golden |

**Two causes fixed, both about what a ball is CALLED, neither a threshold.**

1. **Retired ids were never re-used.** A grace period cannot solve identity:
   on the aiming recording the detector loses a given ball for tens of
   seconds (it sees 2–4 of 7 balls per frame while the operator stands over
   the table), and no budget large enough to bridge that is compatible with
   clearing a pocketed ball's ring in ~1 s. `BallTracker` now remembers a
   CONFIRMED track's identity when it retires (`DormantIdentity`) and a new
   observation within 1.6 ball radii of that spot reclaims the id, radius
   and kind votes. It does NOT reclaim confirmation, so a one-frame phantom
   over a remembered spot still earns nothing. On `device-lying-cue` the
   entire churn was ONE flickering rail detection reborn seven times; it
   now keeps its own id and the bar is ratcheted to zero.
2. **Absorption used the association gate, which is wider than a ball.**
   An unmatched track next to a matched one within `gatingDistance` (8 cm)
   was absorbed as a duplicate — but two distinct ball centres can be
   5.7 cm apart (frozen, in contact). So the first frame the detector
   missed one of a frozen pair, its identity was destroyed outright, with
   no retirement and therefore no chance of re-identification. Duplicates
   are now judged by `BallTracker.duplicateDistance` (1.6 r, below one
   diameter), which cannot conflate two real balls. Found BY the new
   fixture, not before it.

**New regression fixture `scripted-frozen-pair`** — two stationary balls in
contact plus a cue ball, one of the pair dropped from detection for 3.1 s
(longer than the 2.5 s grace, so its track really retires). Three balls,
three ids, zero churn, and the id on the far side of the gap is the same
id. Its `minRecall` bar is 0.96 rather than 0.98 because the dropout is the
scenario; `maxTrackChurn: 0` is what the fixture actually asserts.

**The knob deliberately NOT turned, with its numbers.** `strikeMissGrace`
(0.75 s) is armed by a position-blind test — "did ANY observation this
frame match no track?" — so a ball re-acquired anywhere, at any distance,
at any point in a track's silence, collapses every occluded ball's budget
from the 2.5 s the owner chose to 0.75 s. Measured on `device-aimed-cue`:
**25 of 29 retirements ran on the short budget**, and the flag fired on
observations up to **2.05 m away on a 2.34 m table**. Restricting it to the
track's FIRST missed frame was implemented and measured, then reverted,
because the trade is the owner's to make and not obviously good:

- it buys guide availability — aimed frames 42.0 % → 46.3 %;
- it costs guide steadiness — worst per-frame heading swing 6.0° → **20.1°**,
  `planChanged` 21.0 % → 24.7 %, `farEndShift` p95 1.23 → 1.28 m;
- it buys **almost no identity**: churn 11 → 10 on its own.

Distance cannot rescue it: a struck ball is unexplained only on the single
frame it reappears, and at the device's ~5 Hz tick any reachability bound
loose enough for a real shot (0.65 m in 0.115 s = 5.7 m/s, the existing
`struckBallDoesNotLeaveAPhantomTrackAtTheShotOrigin` test) spans most of
the table. **Decision for the owner:** more guide, twitchier guide, or
leave it. Nothing in this branch depends on the answer.

**Still open, and honestly stated:** `cueIDChanges` on `device-aimed-cue`
stays at 4. All four are the operator physically MOVING the cue ball
between shots with the detector losing it for seconds in between — the
positions are 0.4–1.5 m apart. Nothing offline can tie those together, and
nothing should. `needs-device-run`: none of this has been seen at a table.

**The finding of that session:** every guide line had been rendering at the
wrong heading on any table whose axes are not the session's world axes — a
right angle on the operator's table. `OverlayLayout` emitted a TABLE-space
heading and `OverlayRenderer` applied it about the anchor's LOCAL Y, on the
belief that the table anchor rotates with the table. It does not:
`placeTableAnchor` builds it from an identity rotation plus a translation.
Midpoints were correct, so the strips traced the right path with every bar
pointing the wrong way. The ARExperience test fixture has table +x equal to
world +x, the one basis where the bug is invisible.

**The single most important finding of that session:** the sphere-centre
projection had never run on device. `raycastToTablePlane(...planeHeightOffset:)`
was declared only in the `PlaneRaycasting` protocol EXTENSION, so the
pipeline's call through `any PlaneRaycasting` bound statically to the
no-lift fallback. Every ball projected `r / tan(elevation)` long — 6.1 cm at
25 degrees of camera elevation, 2.9 cm at 45. Fixed in #8 by promoting the
method to a protocol requirement; guarded by `PlaneRaycastingDispatchTests`.
Commit `cc37d92` ("Locate balls by sphere center") had shipped inert.


## Where the project stands

Working on device (iPhone 16 Pro, iPad 9th gen):

- AR camera feed, calibration flow (tap 4 corners → drag → lock, custom sizes
  allowed with 8% snap to standard), ARWorldMap persistence + relocalization,
  anchor-rooted overlays (drift fix), camera flip, auto box orientation.
- On-device detection: bundled `App/Resources/BallDetector.mlpackage`
  (YOLOv11n fine-tune, mAP50 0.896 — see M2-01 in 06-MILESTONES). Compute
  units: **`.cpuAndNeuralEngine` behind a crash-safe probe** since
  2026-09-07 (merged as #20, `e3e2581`; needs-device-run) —
  the `.cpuOnly` pin comes back automatically if the ANE path aborts (see
  "ANE re-export" below). Never `.all`: GPU/MPSGraph crashes with "MPSGraph
  MLIR pass manager failed" on iOS 26.
- Live loop: pipeline → tracker → TableState → aim (stick-based with
  device-pose fallback) → AnalyticSolver → RealityKit overlays; ShotGuide
  tip-contact coaching card; pocket calling (M6-02); tap-to-designate cue
  ball (for measle/practice balls the detector can't classify).
- Diagnostics (2026-07-22): os.Logger subsystem `com.cuesync.ar` (categories
  `session`, `pipeline`, `mirror`); every tap gives on-screen feedback;
  tracked-ball rings always render during live tracking (cue = white).

## B3 (2026-09-07): overlays a few cm off — two causes, sized honestly

The residual "rings/guides sit a few cm off the real balls" has a DOMINANT
cause and a second-order one; they landed on separate branches:

1. **Dominant — sphere-centre lift never dispatched** (task C's finding,
   fixed on `claude/C-synthetic-harness`): `raycastToTablePlane(…,
   planeHeightOffset:)` was only a `PlaneRaycasting` extension method, so
   the pipeline's call through `any PlaneRaycasting` bound to the fallback
   that drops the lift. Every ball projected LONG by r/tan(elevation):
   61 mm at 25°, 29 mm at 45° (harness-measured). Direction follows the
   camera — exactly the observed symptom.
2. **Second-order — calibration frozen at lock vs ARKit's refined anchor**
   (this branch, `claude/B3-anchor-calibration`): the pipeline and every
   app consumer used the lock-time world calibration while camera poses
   arrive in ARKit's continuously refined world frame. The error equals
   the anchor's refinement since lock: horizontal/yaw refinement shifts
   the TABLE-space coordinates (cushions, pockets, trajectory relative to
   the ball); a vertical refinement δy shifts the ring itself by
   δy/tan(elevation). Package test: 20 mm anchor drift → frozen path
   18.9 mm (top-down) / 25.9 mm (35° oblique) off; followed path 0.02 mm /
   ~0 mm (`AnchorFollowingTests`). How much ARKit actually refines the
   table anchor in a session is NOT yet measured on device — the mirror
   now reports it as `anchorDriftMm` (translation since lock).

Live path: `PerceptionConfig.followsTableAnchor` (default ON) —
`PerceptionPipeline.ingest(_:tableAnchorTransform:)` re-derives the
calibration per frame from `AnchoredCalibration`; `SessionModel` mirrors
that for overlays/aim/taps (`SessionModel+AnchorFollowing.swift`), fed by
`ARSessionCoordinator.currentTableAnchorTransform`. A/B at the table:
mirror buttons "Follow anchor ON/OFF" (`/cmd?action=followAnchor&v=0|1`;
OFF = pre-B3 frozen behaviour, rebuilds the pipeline). **Device run
needed:** watch `anchorDriftMm` over a few minutes of walking around the
table and across a relocalization; if it stays at a few mm, this fix is
a guard rail and C's is the whole story; if it climbs to 1–3 cm (loop
closures, post-relocalization refinement), the A/B should show pockets
and cushion lines snapping back onto the physical table with ON.

## 2026-09-07 session — what landed, and what it needs from the table

Nine PRs merged to `main` (`83bd090` → `77f097d`), plus #16 (SessionReplay)
in flight. Everything below is `needs-device-run` unless stated otherwise.

**Fixes aimed at what the operator actually saw**

- **#8 PlaneRaycasting dispatch** — see the header. This is the bulk of the
  "overlays sit a few cm off" symptom. Found independently by two
  workstreams (the synthetic harness and the replay work), reproduced
  end-to-end through the real pipeline before the fix.
- **#7 phantom tracks** — `BallTracker` retired unmatched tracks on a frame
  COUNT (`disappearanceFrames` 30). Frame counts are not a clock: at the
  observed ~8.7 Hz that is 3.45 s, exactly the reported phantom lifetime.
  Added `TrackerConfig.visibleMissGrace` (0.75 s, time-based, visibility
  gated). The out-of-view occlusion guarantee is structurally preserved —
  neither counter moves while nobody is looking. **0.75 s is a judgement
  call, not a measurement**: if the detector drops a visible ball for
  longer than that on real cloth, rings will flicker. That is the knob.
- **#11 off-table tracks** — the surface gate only ever checked incoming
  OBSERVATIONS; the tracker's output (what becomes `TableState`) was never
  checked at all. The gate also admitted `halfExtents + 2r` while a real
  ball centre cannot exceed `halfExtents − r` — 8.6 cm of physically
  impossible space, a margin tuned while #8's bug was inflating every
  projection. New `PlayingSurfaceGate` runs at both ends: observations are
  admitted within a 4.5 cm slack band and CLAMPED onto the envelope (a rail
  ball renders on the rail, never clipped), and tracker output is filtered.
  Note the Kalman filter itself cannot overshoot — its update is a convex
  combination — so tracks were off-table because the gate let them in, not
  through filter drift. The output gate is enforced anyway because a
  future velocity-state filter WOULD predict through cushions.
- **#13 anchor following** — the pipeline held calibration frozen at lock
  while overlays used the anchor's current transform. Now re-derived per
  frame behind `PerceptionConfig.followsTableAnchor` (default on,
  A/B via `/cmd?action=followAnchor&v=0|1`). **Sized honestly: this is
  second-order next to #8.** For a horizontal table, horizontal and yaw
  refinement do not move a ball ring at all; only vertical refinement does,
  by `δy/tan(elevation)`. The mirror now reports `anchorDriftMm` — that
  number is what decides whether this matters at all.

**Instruments that make iteration table-free**

- **#9 synthetic pinhole harness** (`CueSyncTestSupport`) — exact ground
  truth, no hardware. Ideal round trip closes to 0.343 mm at 3.3 m. It is
  what found #8. Any projection change is now measurable in millimetres on
  Linux. It also measured a second, independent error source: rail-top
  calibration taps at a realistic pose shift the ORIGIN by 48.5 mm.
- **#16 SessionReplay** (in flight) — byte-exact replay on Linux, verified
  in a `swift:6.1` container against a macOS-authored golden. Canonical
  JSON writer, `Date()` purged from the ingest throttle, dictionary
  iteration removed from `nearestEvent`. `SessionModel` runs the same value
  types with an injectable clock, so replay judges the SHIPPED decision
  logic rather than a copy.
- **Session recorder** — the missing half. Nothing can yet produce a bundle
  from the real table. Until one exists, the replay loop runs only on
  synthetic and scripted data.

**Product surface**

- **#10 settings** (`SettingsModel` in CoachKit, `UserDefaults` seam typed
  by value kind because `UserDefaults` bridges through `NSNumber` and an
  untyped API reads a guide speed of `1.0` back as `true`). `visibleMissGrace`
  is exposed and persisted but **the tracker does not read it yet** — a
  one-line follow-up, and the UI says so rather than pretending.
- **#12 build identity** — SHA/branch/dirty/built in the HUD, the mirror
  and the startup log. `ENABLE_USER_SCRIPT_SANDBOXING` is `NO` on the app
  target as a deliberate trade-off (the sandbox blocks both reading git and
  writing the built plist); accepted by the owner 2026-09-07.
- **#15 app icon** — and a silent failure fixed: the app had NEVER shipped
  an icon. The catalog was wired in `project.yml` but empty, so `actool`
  emitted no `Assets.car` and the build stayed green. Verify icon changes
  by inspecting the built bundle (`assetutil --info Assets.car`), never by
  a green build alone.
- **#3 agent runner** — merged, but installed PAUSED and inert until the
  GitHub App, host setup and an explicit go. An adversarial
  review found five blocking issues (write token reachable from the model's
  shell, public review threads dispatched as work, a 100-file path check,
  host FQDN in commit authors, and three defects that stopped it completing
  a cycle); all were remediated, but **the remediation has not been
  independently re-reviewed** — do that before clearing PAUSED.

**Hazards worth not re-learning**

- `App/Sources/SessionModel.swift` sits near SwiftLint's 1000-line
  `file_length` ERROR. Three separate problems in one session traced to it,
  including a CI break when two agents independently moved the same block to
  different files (duplicate `PixelBufferImage` conformance). A proper split
  is queued.
- **`Scripts/test-all.sh` does not compile the app target.** A branch went
  red in CI on the Simulator build while every package test was green.
  Always run `xcodegen generate && xcodebuild -scheme CueSyncAR
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
  build` before claiming a change is verified.
- Running `swift test` and `xcodebuild` concurrently in one worktree
  produces spurious "cannot find type" failures from stale artifacts.

## RESOLVED 2026-07-22 (late session): guides + designation work at the table

Verified live through the debug mirror: cue ball classified (white-ball →
.cue, 90%+), stick-based aiming active (aimSource "stick"), trajectory
strips + ghost ball + spin guide all rendering on the cloth. The fixes that
got there: playing-surface observation gate (phantom tracks from
frame-clipped boxes / off-table matches), tap feedback on every path
(pocket-call taps used to look dead), 0.25 m designation radius, always-on
ball rings, raw detector labels in the mirror state. Remaining polish:
overlay/ring positions sit a few cm off the real balls (foot-point
projection + calibration offset — tune with mirror screenshots); fast cue
ball movement can briefly spawn a duplicate track (gating distance 0.08 m
vs ball speed); ARSession "retaining 11 ARFrames" warning persists
harmlessly at ~11-13 — profile before M5.

## Original bug notes (kept for context)

**Symptom (user report at the table):** tapping a ball to mark it as cue did
nothing, and no trace paths/guides appeared.

**Diagnosis so far (from the first instrumented run):** the detector runs and
the pipeline emits outputs, but **zero ball detections survive the
confidence/projection gate** (`frame #N: detections=8 projected=0
confirmed=0` while the stick quad projects fine). With no tracked balls there
is nothing to tap and no cue ball → `updateAim` correctly produces no
guides. That run was an iPhone pointed at a random room, so rejection may
have been correct; **needs a run on the iPad at the real table.** Knobs to
inspect with the new logs: `PerceptionConfig.confidenceFloor` (0.35 vs
Vision NMS pipeline confidences), `Detection2D.isCueStick` filter,
`PlaneGeometryRaycaster` foot-point projection, and the logged ball table
positions vs reality (worldToTable sanity).

**Watch item:** "ARSession delegate retaining 11–13 ARFrames" warnings
reappeared during the iPhone run (camera kept delivering; count plateaued).
The delegate itself drops/deep-copies correctly — if the count climbs on the
iPad, profile before shipping anything.

## Remote debugging setup (no cable needed)

The iPad sits at the table, out of reach of the Mac. Use the **debug
mirror**: it is on by default; read its address under **⋯ → Debug mirror →
Address** (also in Settings → Developer, and said once on the HUD when the
switch is flipped by hand) → open that URL in any browser on the same
Wi-Fi. It serves the *rendered* screen (camera + AR overlays, ~1 Hz) plus a
live tracking-state JSON (`/state.json`: balls with table coords, cue/stick
state, calibration, guide, errors). Implementation:
`App/Sources/DebugMirrorServer.swift` (NWListener, LAN-only, off by
default). QuickTime USB mirroring still works when the device is at the Mac.

## ANE re-export (to un-pin from .cpuOnly)

Findings from a sandbox export session (2026-07-22): the deployed export is
spec 6 (iOS15 target) because ultralytics passes no deployment target; that
opset forces fp32↔fp16 boundary casts, the likely MPSGraph-MLIR crash
trigger. **Recipe for the fix candidate** (Linux/macOS, ultralytics + torch
2.7.0 + coremltools 9; torch ≥2.8 breaks the nms=True export):
monkeypatch `coremltools.convert` to inject
`minimum_deployment_target=coremltools.target.iOS16` while running
`YOLO("best.pt").export(format="coreml", nms=True)` — this keeps the NMS
pipeline (outputs `confidence`/`coordinates`, required by
`CoreMLDetectionProvider`'s `VNRecognizedObjectObservation` path) and drops
the boundary-cast ops. Fallback if it still crashes: same with iOS17;
GPU-only fallback: `quantize=32` fp32 variant (ANE is fp16-only). After
swapping the model in, remove the `.cpuOnly` pin and verify boxes on device.
Training artifacts: dataset fork `cqc/pool-ball-agzev-tekpn` (Roboflow);
best.pt regenerable per `docs/model-testing.md` (freeze=10, 640px, ~epoch 19).

**2026-07-22 late (T1.3 execution findings):** the fork has the DATASET
only — `version(1).model` is nil, so there are no downloadable weights
anywhere; best.pt must be RETRAINED before every re-export (25 epochs
YOLOv11n freeze=10 on the 1000/284/141 split ≈ 1.5 h on CPU). The development Mac
is **Intel x86_64**: torch wheels stop at 2.2.2 there, so the whole recipe
runs in Docker (`python:3.12-slim` linux/amd64 + `apt-get install libgl1
libglib2.0-0 libxcb1` + `pip 'numpy<2'` — ultralytics 8.3.40 still calls
`np.trapz`). Export driver: the container script monkeypatches
`ct.convert` exactly per the recipe above.
Parity gate before any swap: `Tools/DetectionEval` (macOS CLI) runs the
bundled model through the app's real `CoreMLDetectionProvider` on still
images — its CPU output matched the live iPad's rawDetections on the same
scene, so old-vs-new box diffs on `img/upright/` are a trustworthy proxy;
final ANE/crash check still needs the device.

**2026-07-23 NEGATIVE RESULT: iOS16 target does NOT fix the crash.** The
retrained model (val mAP50 0.893) exported at iOS16/CoreML6 with fp32
pipeline outputs still aborts in
`MPSGraphExecutable applyOptimizationPassesWithDevice…MLIRName` (SIGABRT,
crash-looped the app at first inference with `.all`). The boundary-cast
theory is dead — MPSGraph on iOS 26 chokes on coremltools-9 mlprograms
generally. The new model SHIPPED anyway on `.cpuOnly` (equal quality,
fewer false positives). Export mechanics that had to be discovered:
(1) at iOS16+ coremltools defaults outputs to fp16 which the classic NMS
pipeline stage rejects — pin `outputs=[ct.TensorType(dtype=np.float32)]×2`
in the monkeypatch; (2) ultralytics writes the pipeline WRAPPER spec as
5/6 around a spec-7 mlProgram and the CoreML compiler rejects the package —
bump `spec.specificationVersion` (and both stage versions) to ≥7
post-export via load_spec/save_spec. Remaining candidates, in order:
iOS17/CoreML7 export (built, parity-checked on Mac CPU, staged in the
sandbox container (outside the repo) — test ONLY in a
controlled moment, it may crash-loop the app again); fp32 GPU-only
(`quantize=32`); file a feedback with Apple. Crash logs archived from the
device on 2026-07-23 (~00:00 local).

**2026-07-23 RESEARCH — the crash was tested WRONG; a promising untested
option remains.** Web research (incl. Ultralytics' own CoreML docs and a
detailed Reddit write-up of the identical crash) established:
- The `Error: MLIR pass manager failed` abort on **`coremltools` 9.x
  mlprograms is a KNOWN limitation of the `.all` / `.cpuAndGPU` path** —
  it's the GPU/MPSGraph compile route that trips Apple's MLIR compiler, an
  UNCATCHABLE C++ assertion (no `do/catch`, no config flag prevents it).
- **The device test only ever used `.all`** (`SessionModel.loadBundledDetector`),
  which INCLUDES the GPU → guaranteed to hit the crashing path. **We never
  tried `.cpuAndNeuralEngine`.** Ultralytics explicitly recommends
  `.cpuAndNeuralEngine` as BOTH the crash-avoider AND the right unit for a
  camera app (don't fight the AR preview for the GPU; `.all` also causes
  frame-time jitter). ANE routes differently from GPU/MPSGraph and may
  dodge the MLIR bug entirely — though on some hardware the ANE path can
  also hit it (device-specific), so it's a genuine unknown to TEST.
- The fp16-outputs-vs-NMS issue and the iOS16+ FLOAT32 requirement solved
  by hand are exactly what Ultralytics' exporter already encodes
  (`minimum_deployment_target >= iOS16` ⇒ `compute_precision=FLOAT32`
  because no CoreML NMS spec accepts fp16 input). YOLOv11 uses SiLU (well
  supported), NOT Mish — so this is not the Mish/Softplus fp16 bug.

**2026-09-07 SHIPPED (merged as #20, `e3e2581`; needs-device-run):
`.cpuAndNeuralEngine` behind a crash-safe probe.** `loadBundledDetector`
now asks for `.cpuAndNeuralEngine` (NOT `.all`) with the CURRENT bundled
model — no re-export. The outcome is NOT known: the Simulator has no
Neural Engine and the build proves nothing about the abort. What shipped:

- **Probe** (`DetectorComputeProbe`, PerceptionKit, 16 Linux tests): a
  marker file `Application Support/CueSync/detector-compute-probe.json` is
  written with `Data.write(.atomic)` + `fsync` BEFORE each ANE step that
  can abort (the `MLModel`/`VNCoreMLModel` inits, then the first
  `detect`) and cleared AFTER the step returns. Both are synchronous
  syscalls, so a SIGABRT between them cannot lose the marker (process
  death does not touch the page cache; the fsync covers power loss too).
  `UserDefaults` was rejected for this because its writes are proxied to
  `cfprefsd` and are not guaranteed to have left the process before an
  immediate abort. A launch that finds the marker set counts a crash,
  sets `pinnedToCPU`, and loads `.cpuOnly`. "First success" = the first
  `detect` call that RETURNS A RESULT; a thrown Swift error clears the
  marker but does not count, and the next call probes again. A normal
  exit between load and first inference leaves no marker (not a crash).
- **Owner controls**: Settings → "Detector compute" shows the probe line,
  a "Pin detector to CPU" toggle (`SettingsModel.detectorPinnedToCPU`,
  key `detectorPinnedToCPU`, wins over the probe) and "Retry Neural
  Engine on next launch" (enabled only while a crash pin is set). Mirror:
  `/cmd?action=resetComputeProbe`. Both take effect on the next launch —
  the loaded model cannot swap units in place.
- **Where to read it**: `/state.json` → `detectorCompute` block:
  `units` (`cpuAndNeuralEngine` | `cpuOnly`), `phase` (`attempting` |
  `succeeded` | `fellBack` | `optedOut` | `loadFailed`), `crashedLastRun`,
  `crashes`, `successes`, `pinnedToCPU`, `relaunchNeeded`, `summary`,
  `marker` (path). Console (filter "cuesync"): `detector compute: …` at
  notice level on every launch; `.error` when a crash was detected.

**What the owner will observe (pick one and report it):**

1. **ANE works.** App launches, calibrate, lock: rings appear. `/state.json`
   `detectorCompute.units == "cpuAndNeuralEngine"` and `phase` flips from
   `attempting` to `succeeded` within a second of lock (`successes` ≥ 1).
   Settings line reads "Detector: Neural Engine, probe passed (1 run)".
   Report: the `detectorCompute` block, plus the `frameDiag` block over ~30 s
   (`delivered` should climb faster than the CPU-era ~6-7 Hz).
2. **ANE aborts.** The app dies at calibration lock (or at launch, if the
   abort is in model load) — ONCE. Relaunch: it comes up on the CPU and
   stays up. `detectorCompute.units == "cpuOnly"`, `phase == "fellBack"`,
   `crashedLastRun == true`, `crashes == 1`. Settings line: "Detector: CPU —
   Neural Engine crashed last run (1 total); reset to retry". No reinstall.
   Report: that block + the crash log from Settings → Privacy → Analytics
   (look for `MPSGraph`/`MLIR` in the abort frame; if it is NOT MPSGraph,
   that is new information — attach it). Then file the Apple feedback.
3. **ANE was never attempted** (how to tell 2 from 3): `phase ==
   "optedOut"` means the Settings pin is on; `phase == "fellBack"` with
   `crashedLastRun == false` means an EARLIER launch crashed and the pin
   is still set from then; `units == "notLoaded"` means the bundled model
   was not found (simulator build). `phase == "loadFailed"` means Core ML
   THREW on the ANE load rather than aborting — also report that log line.
4. **Reset and retry**: Settings → Retry Neural Engine on next launch (or
   `/cmd?action=resetComputeProbe`), then relaunch. `crashes` keeps
   counting across retries; a second crash after a reset gives `crashes ==
   2` — do not retry a third time, report it.

Retrained weights + all export variants persist outside the repo
(best.pt, best_ios16_fixed, best_ios17_fixed).

## Device-session working notes (for agents driving the Mac remotely)

- Xcode/Terminal are click-only; QuickTime is full-tier. Build = click Run.
- The `.xcodeproj` is generated (XcodeGen) and gitignored, but in remote
  sessions it is **hand-patched** (synthetic IDs `CA11B0A7C0DE...`) because
  Terminal can't be typed into. Added so far: CalibrationOverlayView,
  CalibrationStore, FrontCameraPreviewView, DebugMirrorServer,
  BallDetector.mlpackage (Sources phase). `project.yml` carries the same
  entries, so a real `xcodegen generate` reproduces them.
- git on the mounted repo cannot unlink: move stale `.git/*.lock` (and
  `ORIG_HEAD`) into `_to_delete/` before every git op; `git merge` cannot
  run at all (double index-lock cycle) — create merge commits with
  `commit-tree` + `update-ref` instead. Pushes go through the maintainer's
  SourceTree (network push from the session is blocked).
- `device_stage_files` snapshots can be **stale**; verify against
  `git show HEAD:<path>` / `md5sum` before trusting file reads.

## Next steps (ordered)

1. **Table run on the current build** — this is the gate on everything
   perception-related. The iPad already carries it (`e3e2581`, loaded
   2026-09-08). Four questions, in order of value: (a) do the rings
   and guides sit ON the balls now (#8); (b) does anything still render past
   the cushion nose, and do rail-frozen balls still render at the contact
   line (#11); (c) do phantom rings clear within ~1 s of a shot (#7);
   (d) what does Settings → Detector compute say afterwards (#20 — a single
   crash on the first session that recovers on relaunch is the probe working
   as designed, not a regression). Do this run AS the recording in step 2:
   one trip answers all four and produces the bundle. Tick
   M3-06 rows as they verify. If rail balls clip, read the size delta the
   app shows at calibration lock BEFORE touching the slack — the 8 % snap
   keeps the measured centroid as origin, so a mis-tapped table can put the
   modelled nose line ~10 cm off the real one.
2. **Record one session** (`docs/recording-a-session.md`) — the recorder is
   the last piece of the table-free loop. One five-minute bundle converts
   every later perception change into a CI measurement. Until it exists the
   replay suite runs on synthetic data only.
3. **M2-04/M2-05** — ingest that bundle as the fixed eval set; promote
   `Replay golden (Linux)` from the scripted fixture to real data.
4. **T1.3 ANE, tested correctly** — SHIPPED and merged as #20 (`e3e2581`).
   Loaded on the iPad 2026-09-08; launch alone does NOT exercise it
   (marker read back `armed:false`, zero successes, zero crashes). What
   remains is a session at the table: lock a table, let the detector run,
   then read `detectorCompute` in `/state.json` or Settings and report per
   the four outcomes in the ANE section. Folded into step 1 — it costs
   nothing extra once the camera is on a table.
5. **Independent re-review of the agent-runner remediation** before the
   PAUSED file is cleared (#3).
6. **Connect `visibleMissGrace`** — settings persists and mirrors it; the
   tracker does not read it yet. One line in `trackerConfigFromSettings()`.
7. M6-06 auto table detection; M4-02/03 polish; dataset rev for
   dotted/measle cue balls (`docs/model-testing.md`).

## Human-action checklist

- [x] Rotate/revoke pre-M0 Roboflow key (2026-07-21; new key in untracked
  `App/Config/Secrets.xcconfig`).
- [x] Push the T1 device-verification work (2026-09-07, redacted squash
  `b9f03b2` → merged as #6).
- [ ] **Table run on the current build** — the four questions in step 1.
  The iPad was loaded with `e3e2581` on 2026-09-08, so nothing blocks it.
- [ ] **Record one session** — the recorder shipped (#18); walkthrough in
  `docs/recording-a-session.md`. Same trip as the row above.
- [ ] One-time review of the M1-03 golden fixtures (then tick M1-03's
  "human-reviewed" exit criterion in 06-MILESTONES.md).
- [ ] Agent-runner go/no-go: GitHub App + `$AGENT_BASE` + secrets,
  rulesets, probe read, seeded issues.
- [ ] Delete `_to_delete/` at the repo root whenever convenient.
