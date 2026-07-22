# 08 — Practice Modes, Called Shots, Projection (M6 plan)

Adopted 2026-07-21 (maintainer request). Extends the MVP into a practice
system: the user improves their game through structured drills, confirms
aim on a TV or projector, and gets out of setup friction via automatic
table detection. Everything here builds on the MVP loop (M3-05): tracked
`TableState` → aim → `ShotPrediction` → overlays.

## Design principles

1. **The table is the interface** (05-UX-DESIGN) — modes change what the
   overlays teach, not the screen chrome. One mode button in the HUD bar
   opens a glass sheet; no nav stacks.
2. **Honesty rule carries over** — drills score only what the tracker
   actually observed; predictions never claim spin effects the solver
   can't simulate (until TrajectorySolving v2).
3. **Pure-core discipline** — every mode's rules/scoring is a pure,
   Linux-tested type (`Packages/` logic); device layers only render.

## M6-01 — Session modes framework  ✅ LANDED 2026-07-22

*Implemented: `CoachKit.PracticeMode` (freePlay / calledShots / guidedDrill)
with pure `ModeConfiguration` flags + pending-hint logic (5 tests); HUD mode
menu; persisted selection; remote-settable via the debug mirror
(`/cmd?action=setMode&mode=...`). guidedDrill honestly announces that drill
content lands with M6-03.*

`SessionMode` enum + mode sheet (glass) from the HUD: **Free Play**
(today's live tracking), **Called Shot**, **Guided Practice** (drill
picker), plus per-mode HUD adjustments. Mode state lives in
`SessionModel`; rules live in a new pure `PracticeKit` package (or
CoachKit growth — decide at implementation; no CueSyncCore change
needed).

## M6-02 — Called shot (pocket selection & confirmation)

Tap a pocket during live tracking to call it (tap again to clear; only
one called at a time). The called pocket renders a distinct amber ring;
when the current prediction sends an object ball into the called pocket
the ring fills green and the HUD confirms ("On line — corner right").
Foundation for drills scoring and TV confirmation. *(Being implemented
now, ahead of the rest of M6 — it needs no new packages.)*

## M6-03 — Guided practice drills v1

Drill = pure value: name, setup diagram (ball placements in table
space), target (called pocket / cue-ball rest zone), success criteria,
progression. The app renders SETUP GHOSTS — translucent ball markers on
the cloth where the user should place balls (reusing OverlayRenderer
markers); the tracker confirms placement (ball within tolerance of
ghost), then the drill arms and scores the shot from the next tracked
state change. v1 drill library (standard practice canon):

- **Stop shot ladder** — straight shots at increasing distance; cue ball
  must stop within a zone at contact.
- **Follow / draw control** — same, but cue ball must finish in a marked
  forward/backward zone (scored by tracked rest position — no spin
  simulation needed, the TABLE tells us what happened).
- **Cut-angle ladder** — 15°→60° cuts to a called pocket.
- **Ghost-ball drill** — the app places the ghost at the correct contact
  point; user shoots "through" it; scored on pocketing.
- **Speed control lag** — cue ball to far rail, finish in zone.

Scoring: per-drill make %, streaks, session summary card. Persistence:
local JSON per drill (no accounts).

## M6-04 — Aim confirmation on TV (extends M4 Table View)

Mirror/Table View already planned (M4). Add: called pocket + aim line +
"on line" state rendered in the broadcast Table View so a phone
projected to a TV (AirPlay) becomes an aim-confirmation display for a
second observer/coach. Mostly DisplayKit styling once M6-02 lands.

## M6-05 — Projector mode (guides on the real cloth)

A projector mounted above/beside the table displays the guides ON the
table: trajectory lines, ghost balls, drill setup spots.

- **Output**: a dedicated `ProjectorOutput` (DisplayOutput seam) renders
  a 2D guide scene warped by a projector↔table homography
  (`AffineTransform2D`/full 3×3 homography in TableSpace — new pure
  `Homography` type, tested).
- **Auto-calibration** (required): the projector displays a known
  calibration pattern (4+ high-contrast markers at known table-space
  target positions); the PHONE CAMERA — already calibrated to the table
  — detects the projected markers on the cloth (Vision contour/blob
  detection), giving marker positions in table space; solve the
  homography (DLT least squares, pure + tested). Re-run automatically
  when drift is detected (markers re-shown briefly between shots).
- **Degradation**: no projector → feature hidden; homography solve
  failure → guided manual 4-corner drag on the projector image.

## M6-06 — Automatic table calibration (auto-detect corners)

Replace manual corner tapping as the PRIMARY path (manual taps stay as
fallback and for fine-tuning — the M3-02 flow):

1. **Vision rectangle pass (no new model)**: during calibration, run
   `VNDetectRectanglesRequest` on captured frames; candidate rectangles
   are raycast onto the detected plane; the largest stable
   plane-consistent rectangle whose aspect is table-plausible (1.9–2.1)
   is auto-proposed into the existing `adjusting` state — the user sees
   the glowing rectangle land by itself, adjusts if needed, locks.
2. **Model-assisted pass (later)**: a table-detection model (the
   evaluation slot already reserved in DetectionModelCatalog) proposes
   the playing-field polygon directly — better on cluttered/covered
   tables; same auto-propose entry point.
3. **Auto size**: `TableSize.inferred` snap already handles size; the
   badge stays tappable to override (05-UX).

`CalibrationController` already supports `cornersProposed` from any
source — auto-detect plugs in without state-machine changes.

## Sequencing & dependencies

```
M6-02 Called shot            ← now (no deps beyond M3-05)
M6-06 Auto table calibration ← next (Vision pass; model pass later)
M6-01 Modes framework        ← before M6-03
M6-03 Drills v1              ← needs M6-01, M6-02
M6-04 TV aim confirmation    ← needs M6-02 + M4-01/02
M6-05 Projector mode         ← needs M6-04's scene + homography type;
                               auto-cal needs a locked table (M3-02)
```

On-device Core ML detection (M2-01/02, in flight) benefits everything:
15 Hz tracking makes drill scoring and stick-aim materially better.
