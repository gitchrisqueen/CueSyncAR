# UX review: the real iPad screens (2026-11-10)

Reviewer: Claude (agent), from ten stills captured on a physical iPad 9th
generation in landscape, development build `1.0 (1) · e1081c8` (branch
`claude/ui-snapshot`), through the debug mirror's `GET /ui.jpg`. The stills sit in
the owner's local run folder and are **not** in git; they show a living room and
are not described further here. A teammate is reviewing the simulator and the
code in parallel; this document judges only what the device pixels show, plus
read-only `GET /state.json` from the same session and the repo docs cited inline.

Measurement method: the stills are 2160 x 1620 px for 1080 x 810 pt (2 px = 1 pt).
The iPad 9th gen panel is 264 ppi, so 1 px = 0.096 mm on the glass. Contrast
ratios were computed from sampled sRGB pixels (WCAG relative luminance). The
backgrounds are translucent material over a live camera, so every contrast
figure is **an estimate for this frame and this lighting**; it moves with the
scene behind it.

| file | state |
|---|---|
| `s01-launch.jpg` (and `ui0.jpg`, same state) | cold launch, not calibrated |
| `s02-calibration-begin.jpg` | calibration started |
| `s03-after-lock.jpg` | calibrated, tracking |
| `s04-tracking-shot-card.jpg` | tracking, shot card, cue-ball guide, aim lines, pocket discs |
| `s05-more-sheet.jpg` | "More" sheet |
| `s06-settings-sheet.jpg` | Settings sheet |
| `s07-recording.jpg` | recording |
| `s08-called-shot-mode.jpg` | intended: called-shot mode (see the caveat in §6) |
| `s09-pocket-called.jpg` | a pocket called |
| `s10-back-to-free-play.jpg` | free play again |

---

## 1. Verdict

**Not yet a polished arcade-style assist app. Polish score for the shipped screens: 34 / 100.**

What the stills show is a competent engineering build with a calm, restrained
HUD and a working AR overlay, wearing a developer's clothes. The overlay does
the core job: in `s04` a thin line runs from the cue ball to a green ghost disc
beside the blue ball, and a second thin line runs on to a green disc at the
right side pocket. A player who already knows ghost-ball aiming can read that.
Everything around it works against the "arcade" goal:

- **Nothing on screen celebrates, scores or reacts.** No score, streak, tier,
  make/miss state or reward appears in any of the ten screens.
- **The headline number is not trustworthy.** The same static four-ball
  layout reads 73, 69, 75, 81, 82, 88, 89 and 92 % across the ten captures, and
  the live state reports 95 % for a 48.3 degree side-pocket cut rated "easy".
  The colour of the number flips from orange to green somewhere between 73 and
  75 %, so the colour flips as well.
- **Developer surface is always visible.** A monospace build badge
  `1.0 (1) · e1081c8` sits under the bottom bar on every screen. The More sheet
  leads with "Debug mirror" and a raw LAN URL. Settings leads with "Detector",
  "Running on", "Detector compute" and "Pin detector to CPU".
- **Text is too small to read from where the player stands.** The secondary
  text is about 1.5 mm tall on the glass. That is below normal acuity at the
  1.5 to 3 m distance of a tripod at the table (§3h).
- **The overlay is thin and under-labelled.** It uses three to six colours with
  no legend. The card names neither the ball nor the pocket in words a player
  uses. In `s07` (recording) the overlay switches to a saturated
  red/magenta/cyan/yellow/purple palette.

Why 34: the restraint and the working overlay earn real points. A dark
translucent HUD that leaves the cloth clear, a single green accent, sheets that
use stock iOS components, and correct ghost-ball geometry in the stills are
worth roughly 30 to 35 of the 100. The missing arcade layer (feedback, scoring,
tiers) is worth about 30, and none of it is visible. The trust problems with the
percentage and the developer exposure take away the rest.

---

## 2. Per-screen findings

Severity: **blocker** stops a first-time player or breaks trust; **major** hurts most
sessions; **minor** is a visible flaw; **polish** is finish.

| Screen | Observation (what the pixels show) | Severity | Concrete fix |
|---|---|---|---|
| s01 | There are two calls to action for one job. The top capsule says "Tap anywhere to calibrate the table". The bottom bar also says "Set up table" with a dashed-square icon. The player cannot tell which one to use, or whether they differ. | major | Keep one. Capsule: "Tap to set up this table". Hide "Set up table" from the bar until a table is locked, then show it as "Re-set table" inside More. |
| s01 | "Free play" and a record button are live before there is a table. Neither can do anything useful yet. | minor | Hide the mode chip and record until calibration locks. |
| s01, all | The build badge `1.0 (1) · e1081c8` is in monospace, about 22 px (11 pt) tall, centred under the bar on every screen, at about 5.5:1 contrast. It is the only monospace text in the HUD, so it pulls the eye. | major | Show it only in Developer mode. Its single legitimate use (matching a mirror capture to a build) is already served by the More sheet row and `state.json`. |
| s02 | The capsule says "Point at the table" while the whole table is already in frame. The instruction reads as a failure to see what is plainly there. | major | When the table is in view, say "Hold still, finding the cloth…". Say "Point at the table" only when no table is detected. |
| s02 | The hint reads "Put three or four balls on the table, spread out, so it can find the cloth". It is clear, but the balls are already there. "it" has no referent for the player. | minor | "Spread 3–4 balls across the table to help me find the cloth". Hide it when 3 or more balls are already detected. |
| s02 | The "Use pockets" button is green text on a light translucent pill, at about **1.5:1** contrast. In the still it looks disabled or mid-fade. Its "X" has no label. | major | Use white text on a solid green (or dark) pill, at least 4.5:1. Label the X "Cancel". If "Use pockets" is the main path, make it the primary button. |
| s02 | Three stacked pills (hint, action pill, bar) sit in the bottom fifth of the screen with three styles of rounded rectangle. | polish | Merge the hint into the action pill as its subtitle. |
| s03 | The lock gives no visible confirmation. The screen moves from "Point at the table" to "Tracking 4 balls" with the overlay already drawn. There is no outline, no tick and no "Table locked" in the still. | major | Show a 1 s "Table locked ✓" state in the capsule, plus a rail outline that flashes once (the Autodarts Lens idiom: green outline, checkmark, haptic; competitive-ux-research.md §1.5). |
| s04 | The card headline "73 %" is orange, 44 px (about 22 pt) cap height, at about **3.0:1** on the translucent brown card. Below it, "bottom side" is 4.8:1 and "Best shot — tap any ball to override" is about **2.6:1** at about 11 pt. | major | Use 4.5:1 for every string (§3g). Replace the percentage with a tier word (§5). |
| s04 | "bottom side" names a pocket in table-frame coordinates. From the camera it is the side pocket on the right of the screen. The card never says which ball. | blocker | "Blue ball → right side pocket". Use the camera-relative side, or name the pocket with an on-overlay marker (a numbered or lettered tag on the pocket disc that matches the card). |
| s04 | The cue-ball guide tile shows a white disc with a green dot, labelled "Center ball". The tile is about 260 x 240 px, the biggest object in the HUD, and it carries the least information: centre hit is the default. | minor | Collapse it to a 56 pt chip when the advice is centre hit. Expand it only when the advice is off-centre (draw, follow, side). |
| s04 | The guide tile and the card cover the bottom-left of the screen, where the near-left corner pocket of the table sits in this framing. In `s08` an overlay line runs under the tile and a green disc pokes out at its left edge. | major | Dock the card along the bottom edge below the cushion line, or let the HUD dodge when an overlay element is under it. |
| s04 | The bottom bar reads "8-ft", "Free play", "Open", a record glyph and a "…" glyph, all in the same green weight. Three of them are states, not actions. "Open" means "open table, any group"; a player reads it as a verb. | major | Split the bar into a state line ("8 ft table · Free play · Open table") in white at reduced size, and two actions (record, more). Rename "Open" to "Any group" or "Open table". |
| s04 | Six overlay elements are drawn at once: a thick orange line from the cue ball to the far-left corner (the stick projection), a thin orange line to the ghost, a green ghost disc, a darker green disc behind the blue ball, a thin green line to the pocket disc, and a thin blue line off to the right rail. Orange rings also sit under the red and orange balls. Nothing explains them. | major | Set one hierarchy: the recommended shot is bold and the rest is faint. Name the blue line in a one-time tooltip, or hide it by default. Use one colour per meaning (§3c). |
| s04 | The pocket disc at the right side pocket is drawn about 50 px left of the pocket opening. The orange rings sit below their balls, not under them. | major (known drift, see validation doc) | This is the drift problem in docs/validation/2026-11-10-ipad-remote-run.md, not a design issue. The design fix is to fade the overlay and show "Re-locking…" when the drift estimate grows, not to draw confidently in the wrong place. |
| s05 | The sheet is titled "More". Its first section is "At the table": "Record session" and "Debug mirror" (toggle, on), then an "Address" row in monospace with the LAN URL. The footnote reads "The mirror serves the live screen and tracking state to any browser on this Wi-Fi. The recorder writes a replayable session bundle — pull it from the Files app, or over the debug mirror." | major | Move "Debug mirror" and "Address" into Settings › Developer. Rename "Record session" to "Record practice" with "Saves a video you can replay" as its subtitle. |
| s05 | The Settings row's footnote reads: "Table size, guides, tracking and practice mode — plus the Developer section, which is where the detector picker, the front-camera preview, the latency readout and the box-rotation trim moved to." This is a changelog note addressed to the team. | major | "Table size, guides and practice mode." |
| s05 | The build row is `1.0 (1) · e1081c8` with the footnote "The build this app was made from. The same string is on the HUD badge and in the mirror's header." | minor | Move it to Settings › About as "Version 1.0 (1)". Show the commit in Developer mode only. |
| s05/s06 | The "Done" button is about 83 px tall (estimated from the still), just under 88 px. The rows are about 104 px tall, which passes. | minor | Use the system toolbar button. Check the hit area in code; the pixels cannot show it. |
| s06 | Settings opens on "Table size: Use measured", then "Detection": "Detector: On-device (bundled)", "Running on: On-device (bundled)" (the same value twice), "The hosted detector needs a Roboflow API key in Secrets.xcconfig." Next comes "Detector compute": `Detector: Neural Engine, probe passed (48 runs)` in monospace, then "Pin detector to CPU" and "Retry Neural Engine on next launch" (greyed, about 2.4:1). | blocker for a player-facing build | A player sees a build-config file name and a vendor API key. Hide Detection and Detector compute behind Developer mode. Show players Table, Guides, Practice mode, Sound and voice, About. |
| s06 | The "Use measured" footnote is 3 lines of mechanism ("snapped to your remembered table when there is one … takes effect the next time you calibrate"). | minor | Picker options "Auto (from setup)", "7 ft", "8 ft", "9 ft". Footnote: "Applies next time you set up the table." |
| s07 | Recording adds a second capsule: "● REC 0:07 · 21 frames · ~5 MB". | minor | "● REC 0:07". Frames and MB are developer data. |
| s07 | **During recording the overlay palette changes** to saturated pure red (stick line), magenta (ball rings), cyan (cue ring), yellow (ghost ball), pure green (pocket disc) and purple (the side line). The s04 palette is muted orange, green and blue. Both stills came through the same capture path. | major | Whatever renders the recording overlay must use the same materials as the live one. If this is a debug "high-visibility" mode, it must not switch on silently with Record. Device check needed (§6). |
| s08 | The bar still reads "Free play". No "Called shots" label and no "Call your pocket — tap one to commit" hint (the strings in `PracticeMode.swift`) are visible. A new thick orange line runs from the cue ball to the far rail, rebounds across the left rail and ends under the HUD tile. | major (see §6) | Re-capture with the mode raw value `calledShots`. Whatever the cause, the cushion path should be clipped to the cloth and should not run across the rail or under the HUD. |
| s09 | Calling a pocket turns the right side pocket disc from green to amber/yellow. The card still reads "89 % bottom side" with "Best shot — tap any ball to override". Nothing says "Called: right side". The ball rings are also amber, so "called" and "other ball" share a colour. | major | Card: "Called: right side pocket". Give the called pocket a distinct treatment, such as a white ring with a pulsing outline. Never reuse a colour that already means something else. |
| s10 | Back in free play, the overlay matches s04 but the percentage is now 92 % (it was 73 % at s04) with no change in the balls. | blocker (trust) | See §3i and §5: drop the precise percentage. |

---

## 3. Lens scores

Scores are 0–5, with evidence from the stills.

### (a) First impression and time-to-first-shot: **2 / 5**
`s01` opens on the live camera, which is right (guideline 1 in
competitive-ux-research.md §7). The capsule copy is plain English. Against that,
there are two competing calls to action (capsule and "Set up table"). `s02` says
"Point at the table" when the table fills the frame. The secondary action is at
1.5:1 contrast, and `s03` shows no lock confirmation. Lock took 5.7 s
(`health.calibrationSeconds` in `state.json`), which is quick; the stills cannot
show how many taps it took. The capsule and "Set up table" are enough to start.
They do not tell the player that the phone should stay parked, or where.

### (b) Information hierarchy on s04: **2 / 5**
The status capsule is the correct size and in the correct place. Of the HUD
elements, **essential:** the recommended shot (ball and pocket) and an
easy/hard read. **Useful:** the cue-ball hit point, but only when it is not
centre. **State, should be quiet:** "Tracking 4 balls", "8-ft", "Free play",
"Open". **Developer noise:** the build badge. The hierarchy runs backwards. The
largest tile is the centre-ball guide (least information). The most important
noun, which ball, is missing. The percentage takes the visual weight a tier word
should have. "73 %" is not meaningful to a player: it is not a make rate they
can check, and §3i shows it is not stable.

### (c) AR overlay: **2 / 5**
Good: the ghost-ball disc is in the right place relative to the blue ball, and
the thin path from ghost to pocket reads as "this ball goes there". Bad: the
lines are about 3–4 px wide (about 0.35 mm, or 2 pt), thinner than the cushion
edges and hard to find on black cloth from 2 m. In `s04` orange means three
different things: the stick projection line, the cue-to-ghost line and the rings
under non-target balls. In `s09` amber also means "called pocket". The meaning of
the blue line, and of the thick green line in `s03`, `s07` and `s10`, cannot be
read from the screen; a player cannot read it either. The darker green disc behind the
blue ball looks like a rendering artefact next to the flat ghost disc. Which ball
and which pocket: inferable from geometry by an experienced player, never stated.

### (d) Arcade feel: **1 / 5**
The only colour language is one green accent (consistent across the bar, the
Settings link and the toggle: good) plus the orange-to-green flip on the number.
Typography is the system font at body sizes; nothing is display-weight except the
percentage. No screen shows a score, streak, difficulty tier, make or miss
state, combo, animation trail or reward. The benchmark in the research is not
arcade at all: the closest references are Miniclip's *8 Ball Pool*, where the
guideline length is an explicit, upgradeable assistance level
(competitive-ux-research.md §4.3), and the DigiCue three named presets
(Beginner / Intermediate / Advanced). The research's strongest product claim,
that "the table scores the drill" (§4.2), has no visible surface yet. The stills
cannot show motion; the shift of the percentage between captures suggests the
number is live, but not whether it animates (§6).

### (e) Copy and tone: **2 / 5**
The player-facing strings are mostly plain and short. Quoted verbatim from the
stills:

- **Fine:** "Tap anywhere to calibrate the table", "Tracking 4 balls", "Put three or
  four balls on the table, spread out, so it can find the cloth".
- **Jargon or ambiguity:** "Center ball" (pool players say "centre ball hit", so
  this is close), "bottom side" (table-frame, not player-frame), "Open" (reads
  as a verb), "8-ft" (fine for players, but shown as a toggle-like chip),
  "Use pockets" (unexplained alternative method).
- **Developer tooling:**
  - "Debug mirror"
  - "Address http://…:8787"
  - "The mirror serves the live screen and tracking state to any browser on this Wi-Fi."
  - "…the detector picker, the front-camera preview, the latency readout and the box-rotation trim moved to."
  - "The hosted detector needs a Roboflow API key in Secrets.xcconfig."
  - "Detector: Neural Engine, probe passed (48 runs)"
  - "Pin detector to CPU"
  - "Retry Neural Engine on next launch"
  - "21 frames · ~5 MB"
  - "The same string is on the HUD badge and in the mirror's header."

The research says it directly: "Do not print ARKit vocabulary… a raw model
picker [is a] debug-harness artifact" (§6.5).

### (f) Sheets (s05/s06): **2 / 5**
Built from stock grouped-list components, dark mode, with section headers and
footnotes. Rows are about 104 px tall (pass). Body text in the footnotes is
about 6.2:1 (pass). The greyed "Retry Neural Engine on next launch" row is about
2.4:1. If it is a disabled control, WCAG exempts it, but it still cannot be
read. By count of visible rows: More has 4 rows, and 1 (Record) is for a player.
Settings, above the fold, has 6 rows, and 1 (Table size) is for a player. About
80 % of the visible sheet content serves a developer. The More sheet also
dims the HUD behind it but leaves the build badge readable.

### (g) Accessibility from pixels: **1 / 5** (detail in the accessibility section)
Body text is too small and too low-contrast over a live camera. The
"73 %" orange is about 3.0:1, "Best shot…" about 2.6:1, "Use pockets" about
1.5:1. The bar greens are about 3.0–3.2:1 at about 12 pt. Colour carries
meaning on its own (orange vs green percentage, green vs amber pocket, coloured
lines). The two icon buttons in the bar sit 72 px centre-to-centre, so they
cannot both be 88 px wide.

### (h) Ergonomics on a tripod: **1 / 5**
The device is parked at the head rail (`settings.deviceParked: true`). The
player shoots from anywhere around a 2.34 m table, so reading distance is about
1.5–3 m. On a 264 ppi panel, the measured glyph heights convert as below:

| Text | Cap height on glass | Angle at 2 m | Readable at 2 m? |
|---|---|---|---|
| "73" digits (44 px) | 4.2 mm | about 7 arcmin | barely |
| capsule "Tracking 4 balls" (about 23 px) | 2.2 mm | about 4 arcmin | no (below the 5 arcmin acuity floor) |
| "Center ball", "bottom side", "Best shot…" (14–16 px) | 1.4–1.5 mm | about 2.5 arcmin | no |

So from the shooting position only the number is legible, and it is the
least useful thing on the card. On reach: the bar is bottom-centre and the
card is bottom-left. On a tripod, reach depends on where the tripod stands, so
it cannot be judged from stills. The research's mounted-posture point (§4.1)
applies: the HUD is designed for arm's length, but the app is used from across
the table.

### (i) Trust and honesty: **1 / 5**
Over ten captures of a layout where the balls did not move, the headline read
73, 69, 75, 81, 82, 88, 89, 92 %, and then 95 % live (`ranking.active.headline`
"95% into the bottom side", `cutDeg` 48.3, `difficulty` "easy"). The validation
run recorded the same pattern: a 54 degree side-pocket cut rated "easy" at 78 %,
then 100 % after drift (docs/validation/2026-11-10-ipad-remote-run.md §3). A
48–54 degree cut into a side pocket is not an easy shot for most players. The
same validation run measured overlay latency at a median of 179 ms against a
100 ms bar, and about 5 cm of overlay drift after 10 minutes. It also found the
dark blue ball reported as the 8-ball (`kind: "eight"`, colour "black"). The
8 ft size is unverified, because pockets cannot tell 7, 8 and 9 ft apart.
`8-ft` still shows as a ticked chip on the HUD. The research warns about exactly
this: "Do not show a confidence meter that reads green while detection fails"
(§6.5). The build badge is exposure, not dishonesty, but it tells any viewer
that this is a test build.

---

## 4. Top 10 changes, ranked by polish gained per hour

Effort is an agent-hours estimate for UI-layer work. "Polish" is the expected
rise in the 0–100 score above.

| # | Change | Effort | Polish gain | Why it ranks here |
|---|---|---|---|---|
| 1 | **Developer-mode gate.** Hide the build badge, Debug mirror, Address, the Detection and Detector compute sections, and the "frames · MB" recording detail unless Developer mode is on (7 taps on Version, or a launch argument). | 2–3 h | +10 | Removes the most "test build" signal for the least work. No geometry changes. |
| 2 | **Replace "73 %" with a three-tier read.** Show "Easy / Fair / Hard" from `difficulty`, which the ranking already returns, with hysteresis so it changes only when the tier changes for more than about 1 s. Keep the percentage in Developer mode. | 2–3 h | +8 | Fixes the trust problem on the surface the player looks at most, and gives the arcade layer a vocabulary. |
| 3 | **Name the ball and the pocket on the card**, camera-relative: "Blue → right side". Put a matching tag on the pocket disc. | 3–4 h | +7 | Fixes the one blocker in comprehension. |
| 4 | **Contrast and size pass on the HUD.** All text at least 4.5:1. Use a darker, more opaque card material, or white text on solid chips. Shot-card title at least 34 pt; secondary text at least 20 pt; capsule at least 22 pt. | 3 h | +6 | Makes the HUD readable from 2 m, and meets WCAG AA. |
| 5 | **Overlay hierarchy.** Recommended path 3× thicker with a soft glow. Fix one colour per meaning: white = cue ball path, green = shot path and target pocket, grey = other balls, amber reserved for "called". Hide or label the blue line. | 4–6 h | +6 | Makes "which ball, which pocket" readable on black cloth. |
| 6 | **Success and miss feedback.** On a pot in the target pocket: a ring burst on the pocket, a +1, a haptic, and a short sound (sound is off by default; respect it). On a miss: a quiet "Missed — try again" with the ghost left in place for 2 s. | 6–8 h | +6 | The first visible "arcade" moment. Needs make/miss detection from tracking. Gate it on that detection being reliable. |
| 7 | **Session scoreboard chip.** "3 / 5 · streak 2" in the capsule area after the first scored shot, with one-tap "That wasn't real" (competitive-ux-research.md §6.1 and §7 rule 11). | 4–6 h | +5 | The table scoring the drill is the product claim (§4.2). |
| 8 | **Calibration lock moment.** The capsule shows "Table locked ✓" with a rail outline flash and a haptic. Fix the s02 copy ("Point at the table" only when no table is seen) and the "Use pockets" contrast. | 2–3 h | +4 | Improves the first 30 seconds. |
| 9 | **Bottom bar rework.** One quiet state line ("8 ft · Free play · Open table") and two 44 pt icon buttons (record, more). Remove "Set up table" once locked. | 2 h | +3 | Removes the verb/state confusion and the < 88 px targets. |
| 10 | **Recording palette and called-shot fixes.** The recording overlay uses the live materials. The called-shot mode shows its label and hint. The called pocket gets its own treatment and appears on the card. | 2–4 h | +3 | Removes visible inconsistency. The s08 cause needs checking first (§6). |

Items 1–4 total about 10–13 h and should take the score from 34 to roughly 65.
Items 5–10 are the remaining path toward 80+. The overlay accuracy problems
(latency, drift, the 8-ball misread) are engineering work outside this list; no
HUD polish survives an overlay that sits 5 cm off the ball.

---

## 5. Minimal "arcade pass" using only the existing elements

No new screens. Every item reuses a visible element.

- **Shot card → shot call.** Replace `73 %` and `bottom side` with two lines:
  - **"BLUE → RIGHT SIDE"**: heavy weight, about 34 pt, white.
  - A tier chip: **EASY** (green), **FAIR** (amber) or **HARD** (red). The chip
    carries an icon as well as a colour (one, two or three filled bars), so
    colour is not the only signal.

  Replace "Best shot — tap any ball to override" with "Tap a ball to pick
  another". Show it only for the first 3 shots of a session.
- **Cue-ball guide → hit chip.** When the advice is centre, show a 56 pt chip
  with the dot and no label. When it is off-centre, expand to today's tile with
  "Draw", "Follow", "Left" or "Right" in 22 pt.
- **Status capsule → state and score.** Before lock: "Tap to set up this
  table". At lock: "Table locked ✓" for 1 s. In play: "Shots 3/5 · Streak 2" as
  soon as a shot has been scored, otherwise "Ready".
- **Pocket discs → targets.** The target pocket disc pulses gently, about 1 Hz
  at low amplitude. A potted ball triggers a one-shot ring burst and a haptic.
  A called pocket gets a white outline plus "CALLED" on the card. Other pockets
  get no disc.
- **Lines → one bold path.** Draw cue ball → ghost → pocket as one 3× weight
  line in white then green. The stick projection becomes a dashed grey line,
  shown only while the stick is moving. Hide the blue line unless a "Show cue
  ball path" toggle is on.
- **Bottom bar → quiet.** "8 ft · Free play · Open table" in 15 pt grey, and two
  icon buttons. Mode changes go through a three-preset picker:
  - "Practice": free play.
  - "Call it": called shots.
  - "Drill": guided drill.

  This follows research rule 8: the mode is a named preset.
- **Hide outside Developer mode:** the build badge, Debug mirror, Address, the
  Detection and Detector compute sections, and the REC frames/MB detail.
- **Success and miss states:**
  - **Make:** "+1", the pocket ring burst, a haptic, and the streak count ticks
    up.
  - **Miss:** "So close — 2 cm left". Show this only if the tracker can back the
    number; otherwise just "Missed".
  - Either way, a 2 s pause before the next recommendation appears.

---

## 6. What could not be judged from stills

- **Motion and juice:** whether anything animates (number transitions, line
  draw-in, disc pulses), and how the 179 ms overlay latency feels while the stick
  moves.
- **Haptics and sound:** `speech.level` is "off" in `state.json`; no audio was observed.
- **Tap targets in code:** only the visible extents were measured. SwiftUI hit
  areas can be larger than the drawing, so the ball-tap override (balls are about
  43 px, or 22 pt, across in these stills) and the "Done" button need a code check.
- **The calibration gestures:** corner and pocket taps, and the ball-picking tap,
  need a person at the device (INDEX.md).
- **Called-shot mode:** `s08` and `s09` still show "Free play" in the bar, and
  the mode's hint string is absent. The capture used `mode=calledShot`, while the
  enum raw value is `calledShots`. The mode may never have changed, so the
  called-shot UI is **not reviewed** here. If the device accepted an unknown mode
  silently, that is its own defect: CLAUDE.md says no silent failure paths.
- **The recording palette:** whether the player sees the s07 palette on glass,
  or only the mirror composite does. Both stills used the same capture path,
  which points to the device, but a direct look is needed.
- **Dynamic Type, VoiceOver, Reduce Motion:** cannot be seen in a still.
- **Glare, ambient light, distance:** the measurements in §3h are arithmetic, not a
  test with a person at the table.
- **Whether the drift seen in s04 (pocket disc about 50 px left of the pocket)
  is calibration or pose drift:** that needs the validation run's method, not
  pixels.

---

## Voices

### Art director (brand, type, colour)
The base is better than most first builds. It uses one accent green, dark
translucent material, system type and rounded capsules, and it does not shout.
It is also anonymous. Nothing on screen says "CueSync"; it could be any
utility. There are three type registers: system text, a heavier percentage, and
a monospace badge. The monospace one is the badge, which does not belong. The
percentage is the only display moment, and it is spent on a number I would
delete. The overlay colours look picked per feature, not designed as a set: a
warm orange, a muted green, a mid blue, and then in s07 a full RGB primary set.
Fix one overlay palette (white, green, amber, grey), one display weight for the
shot call, and one recognisable motif. A rounded-square "target" mark built from
the pocket disc would do. The green is a good brand anchor; use it only for
"go".

### Accessibility reviewer (WCAG 2.2 AA from the pixels)

| WCAG criterion | Finding | Result |
|---|---|---|
| 1.4.3 Contrast (Minimum) | "Best shot…" about 2.6:1; "73 %" about 3.0:1 (large text, so 3:1 applies; borderline); "Tracking 4 balls" about 3.0:1 against a light wall (large, borderline); bar labels about 3.0–3.2:1 at about 12 pt (normal text, fail); "Use pockets" about 1.5:1. Every value is an estimate over a moving camera background, so the worst case is lower. | fail |
| 1.4.1 Use of Colour | The orange/green percentage and the green/amber pocket state carry meaning by colour only. | fail |
| 1.4.11 Non-text Contrast | The 2 pt overlay lines, such as blue on black cloth, are visually weak. AR overlays are a grey zone for WCAG; treat them as fail. | fail (grey zone) |
| 2.5.8 Target Size (Minimum, 24 pt) | Likely passes for most controls. | pass (likely) |
| Apple HIG 44 pt | The bar's record and more icons are 72 px (36 pt) centre-to-centre, so they fall short. | fail |
| 1.4.4 Resize Text | Not testable from stills. | not tested |

Plain language: "calibrate", "Neural Engine", "Secrets.xcconfig" and "probe
passed" fail the plain-language bar for a consumer screen.

### First-time player (10-second read)
"OK, it sees my table and says it's tracking 4 balls. There's a line from the
white ball to… something near the blue? A green blob near the right pocket, so
I guess blue into the right middle pocket. What's 73 %? My chance? Now it says
92 % and I didn't touch anything. 'bottom side', bottom of what? 'Open', open
what? Why is there a version number? The 'More' button is all Wi-Fi addresses
and detector stuff. I can't read the small grey text from over here anyway."
