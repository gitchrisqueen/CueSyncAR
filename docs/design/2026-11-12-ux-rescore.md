# UX re-score after three polish passes (2026-11-12)

Reviewer: independent design review (Claude, read-only; no source changed, no device contacted).
Baseline: `docs/design/2026-11-10-ux-review-ipad-screens.md` (34 / 100, lenses a-i, 0-5 each).
The other 34 / 100 review (`2026-11-10-ux-review.md`) uses nearly the same lenses (its c and d are swapped, its f is "error, empty and degraded states"); I score against the iPad-screens rubric because the evidence here is iPad stills.

Evidence judged (real iPad captures, 2160 x 1620, local only, none committed):
- Before the passes: `ui/s01`..`s10`, `ui/ui0.jpg` (cold launch).
- After the passes: `ui/p2-tracking`, `ui/p3-player-view`, `ui/p4-int3` (4 balls), `grid/ui_final.jpg` (current build, 15 balls), `grid/ui0.jpg` (current build, stale lock, out of focus, no overlay).
- I zoomed two crops of `ui_final.jpg` (pocket end and the 8-ball area) into /tmp to check alignment. Pixel sizes below are measured from the stills (1 px = 0.096 mm on the 264 ppi glass). Contrast was judged by eye, not sampled (no image library on this host), so every contrast statement is a visual estimate.

Judgement is only what the pixels show. The changelog was not used.

---

## 1. Re-score

Overall: **34 -> 46 / 100** (about plus or minus 6). The gain is real but sits in two places: the shot card and the removal of developer chrome. Most of the "arcade" layer is not visible in any still, so it earns no points here.

| Lens | Before | After | Evidence |
|---|---|---|---|
| a First impression / time to first shot | 2 | **2** (not re-judged) | No current-build launch, calibration or lock still exists. The only current non-calibrated state is `grid/ui0.jpg`, which reads "Tracking 1 balls" with a success tick and no re-lock message (see §3). `s01` is pre-polish. |
| b Information hierarchy | 2 | **3.5** | `ui_final`: the card now leads with a tier chip and names the ball and the pocket ("Maroon ball -> left side pocket"); the build badge and the 260 px guide tile are gone (`p2` still shows the orange build badge, `p3`/`p4`/`ui_final` do not). Still weak: the unlabelled white guide disc is the brightest object on screen, and the bar still mixes state and actions. |
| c AR overlay | 2 | **2.5** | `ui_final`: a thick light-grey hero path cue -> ghost -> pocket is easy to find, and the ghost disc sits correctly beside the maroon. Against that: 15 identical grey plates, 4 unexplained thin lines, a pocket disc that is not on the pocket (crop `b`), and a second grey sphere over the 8-ball that reads as a duplicate ghost ball (crop `a`). |
| d Arcade feel | 1 | **1.5** | Only the EASY chip (rounded outline, bold, green) is new. No score, streak, make or miss, banner or scoreboard appears in any still, because none was captured. Haptics and sound cannot be judged from stills. |
| e Copy and tone | 2 | **3** | "Blue ball -> right side pocket" (`p2`-`p4`) and "Best shot - tap a ball to pick another" (`p2`, `p4`) replace "bottom side" and "Center ball" jargon. Still wrong: "Open" and "8-ft" as bare chips, and "Tracking 1 balls" (`ui0`). The sheets were not re-captured, so the `s05`/`s06` developer copy is unverified as fixed. |
| f Sheets | 2 | **2** (not re-judged) | Only the pre-polish `s05`/`s06` exist (Debug mirror, LAN address, "Roboflow API key in Secrets.xcconfig", "Pin detector to CPU"). Developer mode off by default is plausible from the missing badge but is not shown for the sheets. |
| g Accessibility from pixels | 1 | **2.5** | Card, capsule and bar text are now white on near-black; the subtitle in `p4` is light grey on near-black, visibly high contrast. Difficulty is now a word plus a dot, not colour alone. Still colour-only: overlay lines and pocket state. Bar icons are unlabelled and the guide tile has no word. |
| h Ergonomics on a tripod | 1 | **2** | `ui_final` headline cap height is about 32 px = 3.1 mm = about 5.3 arcmin at 2 m, right at the acuity floor and **smaller than the old "73" digits (4.2 mm)**. Capsule and bar text are about 2.9 mm (about 5 arcmin). At 3 m all of it fails. The card now sits top-centre over the back wall, clear of the table, which is good. |
| i Trust and honesty | 1 | **2.5** | The raw percentage is gone, replaced by a tier word: the right fix. But `p2`-`p4` are the same four-ball layout the baseline measured as a 48 degree side cut (`cutDeg` 48.3), and it still reads EASY. Only EASY appears in every current still, so FAIR and HARD styling is unseen. `ui0` shows a tick and "Tracking 1 balls" with 14 balls on the table. |

Average: 1.56 -> 2.39 of 5.

---

## 2. Ten gaps to arcade polish, ranked by impact on a player at the table

Flag **[M]** = needs motion or animation, so it cannot be judged from stills.

1. **Overlay noise buries the shot.** `ui_final` has 15 grey plates, a thin green line ending at the 8-ball, two thin blue lines, an orange tick on the cue ball and a grey sphere on the 8-ball, all competing with the hero path. Fix: while a shot is recommended, draw nothing under non-involved balls (or a 1.5 pt outline ring at 25 % that does not cover the ball), hide the blue cue-ball-after-contact path and the green line by default, and show them dashed at 40 % only on a "More lines" toggle.
2. **The pocket target is not on the pocket.** Crop `b`: the green disc sits about one disc-width right of and below the left side-pocket mouth, and the hero line ends inside the disc, short of the hole. Fix: centre the target ring on the pocket mouth at 1.5 x the mouth width, end the hero line at that centre, and fade the disc (not the line) when drift grows. Needs a device check to separate drawing from calibration drift.
3. **Headline too small to read from where you shoot.** Cap height is 3.1 mm (5.3 arcmin at 2 m), smaller than the old percentage. Fix: headline at 36 pt or larger (cap about 4.7 mm, about 8 arcmin at 2 m) in uppercase "MAROON -> LEFT SIDE", tier chip at 28 pt or larger, subtitle at 20 pt or larger and shown for the first three shots only. Capsule and bar text: 22 pt minimum.
4. **No payoff moment is visible.** No still shows a make, a miss, a "+1", a streak or a scoreboard. Fix: capture and review all of them; target a 1.2 s state on a make (ring burst on the pocket, "+1" at 48 pt in the capsule, streak count ticking up) and a quiet "Missed" with the ghost kept for 2 s. **[M]**
5. **First 30 seconds unverified on the current build.** Launch, "Point at the table", the "Use pockets" button, and the lock confirmation have no current captures. Fix: "Table locked" capsule for 1 s with a rail outline flash, "Hold still - finding the cloth..." when the table is in view, "Use pockets" as white text on solid green at 4.5:1 or better. **[M]**
6. **Degraded and lost states look healthy.** `ui0.jpg`: a success tick and "Tracking 1 balls" while 14 balls sit unseen, no overlay, no "re-locking" message. Fix: below a ball-count or drift threshold, switch the capsule to amber "Table lost - hold steady, re-locking...", drop the tick, fade overlays to 40 % over 300 ms, and pluralise correctly ("1 ball"). **[M]** for the fade.
7. **EASY on a 48 degree side cut.** Fix: calibrate the tiers (for example EASY up to 30 degree cut and short distance, FAIR to 50, HARD beyond), add an icon of one, two or three bars inside the chip, and capture one FAIR and one HARD still to prove they exist.
8. **The cue-ball guide tile is the loudest thing and says nothing.** A solid white disc with a green dot, no word, in a different place in each capture (bottom-left `ui0`, left of the card `p2`-`ui_final`). Fix: when the advice is centre, hide it; otherwise show a dark 56 pt tile with the word "Draw", "Follow", "Left" or "Right" at 22 pt, never a white fill brighter than the hero line.
9. **Card position is not stable.** `p2` bottom card with subtitle, `p3` and `ui_final` top one-liner, `p4` tall top card that covers the left edge where the player's stick enters. Fix: one anchor (top-centre under the capsule, one line, fixed width, never above the stick zone) and no repositioning between frames. **[M]** to confirm no jump.
10. **Bar and sheets still read like a tool.** "8-ft" with a checkbox glyph, "Free play" and "Open" in the same weight as the two icon buttons; record and more have no labels. Fix: a 15 pt grey state line "8 ft - Free play - Any group" plus two 44 pt buttons labelled "Record" and "More", and re-capture More and Settings to prove Debug mirror, LAN address, detector rows and the build string are gone.

---

## 3. What is still clutter or confusing in `ui_final.jpg`

- **The thin blue lines.** The design doc (`05-UX-DESIGN.md`, Aiming experience) says `chalkBlue` dashed is the cue-ball path after contact. Here they are solid hairlines, unlabelled. One runs from the ghost ball up to the top rail (plausibly the post-contact tangent). The other runs right from the cue-ball tip toward the right rail and does not line up with the stick, so its meaning is not readable. A player cannot decode either. The thin green line from the top rail ending at the 8-ball is likewise unexplained.
- **The grey discs under balls: noise with 15 balls.** All 15 are the same pale grey ellipse, wider than the ball, drawn over its lower third, covering the stripe and number on the blue-stripe and red-stripe balls (crop `a`). They carry no information: not which ball is the target, not which are tracked, not which are in the line of the shot. They are also lighter than the felt, so together they form a 15-spot pattern brighter than the hero line. With 4 balls (`p3`) they were tolerable; with 15 they are the loudest layer.
- **A ghost ball that is not one.** The grey sphere over the 8-ball (crop `a`) is the same colour and size as the real ghost sphere beside the maroon, so the table appears to show two ghost balls.
- **The hero line reads at arm's length, partly at 2 m.** It is about 14 px wide (about 1.4 mm), light grey on near-black cloth, with a clear kink at the ghost ball. In this dim room that is visible at 2 m. Two weaknesses: the cue-ball segment and the object-ball segment are the same colour, and it is grey, not the "white then green" scheme the earlier review proposed, so "green = the shot" is carried only by a faint pocket disc. Bright rooms are untested.
- **The pocket disc is off the pocket** (gap 2), so the line appears to aim at cloth.
- **The cue-ball tick.** A small orange line on the cue ball is the only orange on the table, with no meaning given.
- **The top of the screen is calm, the bottom is not.** The capsule ("Tracking 15 balls", white on near-black) is clean. The bar's checkbox glyph before "8-ft" looks like a toggle, and "Open" still reads as a verb.

---

## 4. "Done" for design: eight checks a future session can run on `/ui.jpg` stills alone

Stills are 2160 x 1620 (1 pt = 2 px). Take each still on the iPad at 264 ppi, one dim and one bright scene.

1. **Size.** On the tracking still, the shot-card headline cap height is at least 46 px, the tier chip text at least 36 px, and every other persistent HUD string at least 32 px.
2. **Contrast.** Sample the foreground and background pixels of every HUD string (capsule, card, bar, sheet rows) on both scenes; each pair is at least 4.5:1, and tier meaning is carried by a word or icon, not by colour alone.
3. **Overlay budget.** With a shot card showing on a 15-ball table, count overlay primitives not belonging to the recommended shot (lines, discs, rings). The count is at most 2, and no marker covers more than 10 % of any ball face.
4. **Hero line.** At least 12 px wide, at least 7:1 against the cloth, and its end point lies within one ball diameter of the pocket mouth centre (measured on a still with the pocket mouth marked).
5. **One colour per meaning.** Sample the cue path, object path, post-contact path, target pocket and "called" pocket; no two roles share a hue, and each role is the same hue across at least three stills.
6. **Card copy and stability.** The card names a ball (colour or number) and a camera-relative pocket in at most 40 characters, the named ball is the highlighted one in the same still, and the card top-left stays within 8 px across three consecutive stills of the same state.
7. **No developer strings.** Run OCR over the tracking, More and Settings stills; none of: a commit hash, "Debug", "mirror", "Address", "Detector", "xcconfig", "probe", "frames", "MB", or a raw ID; and no "1 balls" (the pattern `\b1 balls\b` has zero matches).
8. **State coverage.** One passing still each for: launch, calibrating, locked (with lock confirmation), tracking with a shot, no clean shot, a make (score or streak visible), a miss, called shot with the called pocket labelled, and tracking lost (capsule amber, tick gone, overlay opacity at most 40 % by pixel comparison with the live still).

---

## 5. Screens I could not judge (not captured on the current build)

- Cold launch and calibration begin, steps and corner taps, the pocket flow, and the lock confirmation (`s01`-`s03` are pre-polish; `ui0.jpg` is only a stale-lock, out-of-focus state).
- The shot scoreboard, banners (made, missed, any toast), streak and "That wasn't real" correction.
- The called-shot flow and the called-pocket treatment (`s08`-`s10` were mis-sent and show free play).
- Recording state, the REC capsule and the recording overlay palette.
- More and Settings on the current build (only the pre-polish `s05`/`s06` exist).
- No-shot, blocked and break layouts, and the FAIR and HARD tier chips.
- Tracking-lost fade, light scenes or glare, Dynamic Type, Reduce Motion, left-handed layout.
- Everything motion: line draw-in, pulses, number transitions, ring bursts, haptics and sound.
