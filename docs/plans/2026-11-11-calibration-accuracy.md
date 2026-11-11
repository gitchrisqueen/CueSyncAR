# 2026-11-11 - Pocket calibration accuracy and table size

Status: implemented and measured on the real iPad (branch
`claude/calibration-accuracy`, built from `origin/claude/integration-2`).
Follows `docs/plans/2026-11-11-calibration-drift-plan.md` (on
`claude/calibration-drift`), next steps 1 and 3.

Device: iPad 9th generation on a tripod at the head rail of an 8 ft class table
with black cloth and four balls, driven only through the debug mirror. Captures
and logs are in `~/CueSyncRuns/accuracy/` (not committed).

## 1. What was wrong

Before this branch, a lock from four pocket picks fitted 24-30 mm rms with the
worst pocket at 34-36 mm. Today's first state read, on build `112c745`, was
"fit 26 mm rms, worst cornerBottomRight 36 mm". The size check said "8 ft
decisive" on one lock and "7 ft (not decisive)" on another lock of the same
table.

Three causes, each measured offline from probe rays and the mirror frame
before any code was written:

1. **The picks were not the geometry the solver wants.** The solver needs the
   corners of the cushion-nose rectangle and the middles of the side-pocket
   jaw gaps. The hand picks and the pattern search landed on the pocket
   holes. Snapping to the dark hole was tried first and made things worse.
   Seen from the head rail, the far pockets are only a sliver of their back
   wall. The blob centroid sits 10-15 view points short of the mouth, which
   is 10-15 cm along the table. The fit went from 27 to 80 mm rms. The near
   pockets have grey liners, so there is no dark blob there at all.
2. **The table plane is tilted relative to ARKit's gravity.** With the same
   four picks, a horizontal plane fitted 26.7 mm rms. A plane free to tilt
   fitted 9.1 mm rms, with a tilt of 0.5 degrees. From the head rail the far
   pockets are seen about 10 degrees above grazing. So 1 mm of plane height
   under them moves them about 6 mm along the table. Half a degree of tilt
   over 2.3 m is 20 mm of height. Every device lock since then has measured
   0.8-0.97 degrees of tilt.
3. **The size check used detector boxes as a ruler.** It gets the depth of
   the cloth from the balls' apparent size, and a box a few pixels loose is
   10 % of the range. It also compared nose-height sightings against the
   cloth height. Both errors push the reading around by more than the 15 %
   that separates 7 ft from 8 ft.

## 2. What was done

| piece | file | what it does |
|---|---|---|
| luminance image | `Packages/TableSpace/Sources/TableSpace/LumaImage.swift` | 8-bit Y plane, bilinear sampling (pure; Linux-testable) |
| snap | `Packages/TableSpace/Sources/TableSpace/PocketSnap.swift` | Between the corner taps it fits the **rail edge** (bright rail cap against the dark cushion) and then the **cushion nose** (lit cushion top dropping into the shadowed face). Each line is a consensus fit over 80 samples and fits to 0.3-1.3 px rms. The far corners snap to the intersection of two nose lines (`noseCorner`). The side pockets snap to the middle of the dark jaw gap on the long nose line (`jawGap`). The near corners, whose end nose faces away from the camera, are moved onto the long nose line (`ontoNose`). If a search fails, or a snap would move a tap more than 70 px, the raw tap is kept and labelled `raw`. |
| tilted fit | `Packages/TableSpace/Sources/TableSpace/TiltedPocketFit.swift` | Fits the plane height, and from five pockets up the two tilts, with a closed-form rigid fit inside a search. Pockets known only across the table (`alongFree`: the `ontoNose` near corners) slide along the long axis, so they constrain the fit across the table only. The fit also reports each pocket's leave-one-out error. With six pockets it drops a pocket that sits more than 3 cm off the other five, but only when at least three coordinates of redundancy are left; it names the dropped pocket. The result is lowered to the cloth by the nose height (36.3 mm). |
| size | `Packages/TableSpace/Sources/TableSpace/TableSizeFromImage.swift` | Measures the table's width with a ball laid across it: `width = chord(row) / ballWidth(row) * 57.15 mm`. `chord` is the distance between the two long nose lines along the ball's row. `ballWidth` is the ball's own silhouette, measured from half-maximum to half-maximum. No depth and no box size are involved. A 7.7 mm nose-versus-ball-centre range correction is applied. Only light balls (contrast of at least 80) are measured. The size is applied only when the result is decisive at 2 sigma; otherwise the user's setting is kept and reported as "size unverified". |
| depth ruler fix | `TableSizeFromBalls.classify(..., sightingsAboveCloth:)` | Compares the balls at the sightings' own level. It is still reported as `pose.sizeFromBalls`, but it no longer decides anything (see section 4). |
| app wiring | `App/Sources/SessionModel+PocketSnap.swift`, `SessionModel+PocketCalibration.swift` | Four or more pockets now take the new path, both for in-app taps and for the mirror's `calibrateFromPockets`. The app grabs one camera frame (stopping the live pipeline briefly, because the pipeline's frames carry no pixels) and runs the detector on it. It maps view points to image pixels through the frame's pose and intrinsics, snaps, and builds world rays from the snapped pixels. It then sizes, fits, lowers and locks. A bad fit is refused with the pocket to re-tap ("Re-tap the far-left corner"). A dropped pocket is announced and never left out silently. The pocket prompt asks for all six. |
| pixels | `Packages/PerceptionKit/Sources/PerceptionKit/PixelBufferSampling.swift` | `PixelBufferImage.lumaImage()` copies the Y plane |
| mirror | `SessionModel+DriftDiagnostics.swift` | Adds `pose.pocketSnap` (method and shift per pocket), `pose.pocketFitDetail` (rms, worst, leave-one-out, tilt, dropped pocket), `pose.sizeFromImage` and `pose.sizeStatus` |
| offline tool | `Tools/PocketSnap` (Swift CLI) | Runs the same snap and size check on a grayscale `/frame.jpg` on the Mac. `Scripts/calibrate-pockets.py --preview` uses it. By default the script now sends the rough picks once and prints the device's answer. The old pattern search is behind `--search`. |

Tests (TableSpace, all synthetic): `PocketSnapTests` (rendered head-rail table
with noise: far corners within 0.6 px, side pockets within 1 px, stable across
different rough taps, featureless image keeps the taps, all-six prompt),
`TiltedPocketFitTests` (tilt recovery, flat fit centimetres out, noise within
10 mm, bad sixth pocket dropped and named, no drop without redundancy,
along-free near corners), `TableSizeFromImageTests` (7, 8 and 9 ft identified
and decisive, repeat noise agrees, dark ball skipped, off-table ball ignored,
halfway not decisive, like-for-like depth ruler, view names).

## 3. Numbers on the real iPad

Build `6441c95`, three consecutive fresh locks with the app relaunched before
each one. Every lock used the same rough picks, the old four plus two rough
side picks: `TL 89:602, TR 386:334, BR 702:333, BL 972:594, sT 285:419,
sB 788:408` (view points). All six pockets snapped every time.

| lock | fit rms | worst pocket | leave-one-out max | tilt | cloth y | image size check | verdict applied |
|---|---|---|---|---|---|---|---|
| before (`112c745`, 4 picks, pattern search) | 26 mm | 36 mm (cornerBottomRight) | - | 0 (flat) | -0.567 | depth ruler: "2.15 m, 7 ft (not decisive)" | none |
| 1 | 4.9 mm | 7.2 mm (sideBottom) | 29.7 mm (cornerTopRight) | 0.85 deg | -0.638 | 1.128 +/- 0.018 m wide: 8 ft | 8 ft (measured) |
| 2 | 2.4 mm | 3.6 mm (sideBottom) | 14.5 mm (cornerTopRight) | 0.87 deg | -0.639 | 1.127 +/- 0.014 m wide: 8 ft | 8 ft (measured) |
| 3 | 3.9 mm | 5.6 mm (sideBottom) | 24.6 mm (cornerTopRight) | 0.83 deg | -0.637 | 1.126 +/- 0.014 m wide: 8 ft | 8 ft (measured) |

Development locks on earlier builds of the same code gave 4.1, 4.5, 3.4 and
3.2 mm rms. One gave 1.2 mm after wrongly dropping a far corner, which led to
the redundancy rule in `6441c95`. Before near corners were allowed to slide
along the rail, the fit was 14.4 mm rms with the worst pocket at 23 mm. The
snapped picks gave 7.7 mm in the offline analysis with tilt free.

On `/frame.jpg` after each lock, the ball shadow discs sit under the balls and
the bank line meets the far cushion at its nose. On `/ui.jpg` the HUD reads
"Tracking 4 balls" and "8-ft".

**How to read the rms.** The near corners count only across the table, so
the rms covers ten measured coordinates against six unknowns. It is the
agreement of the snapped geometry. The leave-one-out column is the stricter
figure: where the fit to the other five puts a far corner, 15-30 mm. Removing
one far corner leaves the tilt poorly fixed. The near corners are the weak
direction (section 5).

**Size.** All three locks measured 8 ft decisively from the two light balls,
1.126-1.135 m wide. The red and blue balls fall below the contrast floor;
where they were measured on earlier builds they read 1.25-1.40 m. The width
comes out about 3 % under the 1.17 m that the app's 8 ft model uses. A home
"8 ft" table is 88 x 44 in (2.235 x 1.118 m), which would fit the measurement
better. Measure the table with a tape before trusting distances to better
than 3 %. The old depth ruler (`pose.sizeFromBalls`) reads "7 ft" on these
locks (1.80-1.95 m long). That is why it no longer decides anything.

## 4. Drift re-check (15 min)

The check ran after lock 3 with the parked hold on. It used the same method
as run B in the drift plan:

- Ball table coordinates were sampled from `/state.json` every 10 s for
  15.7 min.
- The first 60 s were excluded.
- The reference is the mean of the next three samples.

| metric | result | target |
|---|---|---|
| per-ball max excursion (4 balls, 89 samples, 60-944 s) | 0.7-1.0 cm (the mirror rounds to 1 cm) | <= 1 cm |
| common-mode shift | max 0.8 cm, 0.3 cm at the end | - |
| hold | `holding` true and table locked for the whole run; ARKit drift held out 16.4-19.6 mm | - |

The drift fix still holds on the new calibration. The tilted table plane does
not interact with the parked hold.

## 5. What remains

1. **Near corners along the rail.** The near end's nose is not visible from
   the head rail, so the near corners are known only across the table. Two
   ways to pin them: the jaw tip where the long cushion's lit top ends at a
   corner pocket (it sits about 80-90 mm, mouth / sqrt 2, along the rail from
   the nose corner), or the near rail edge plus a measured cushion width.
   Either would turn the leave-one-out figure into a real per-pocket accuracy.
2. **Table model.** The image says 1.13 m wide, against 1.17 m for the model.
   Add the 88 x 44 in home 8 ft to `TableSize` (in `CueSyncCore`, which needs
   a contract-change PR), or confirm the table with a tape.
3. **Size check with more balls.** Only the light balls clear the contrast
   floor on black cloth. A colour (chroma) silhouette would admit red and
   blue. Measuring over several frames would also tighten the 1.2 % floor.
4. **In-app frame for tapping.** The app grabs a frame when pocket sighting
   starts. If the camera moves a lot during tapping, the snap still maps
   through that frame's own pose (the mapping goes through world space), but
   a pocket hidden in that frame stays `raw`.
5. Plan steps 2, 4 and 5 from the drift plan are untouched: the homography
   drift cross-check, ARKit configuration trials, and recording the hold
   correction in sessions.
