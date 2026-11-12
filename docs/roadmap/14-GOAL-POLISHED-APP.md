# Goal 14 - polished, trustworthy shot assist (iPad, remote)

Replaces goal 13 (done: iPad calibrated, recorded, replayed). Same rules: the
owner is NOT at the iPad (tripod, other room). Drive it through the debug
mirror (`http://192.168.50.188:8787`, `/state.json`, `/frame.jpg`, `/ui.jpg`,
`/logs`, `/cmd`). Install with `Scripts/device-push.sh --device "Christopher’s iPad (2)"`.
No PRs, no media committed, never touch `Packages/CueSyncCore` (contract-change
PR only), `SessionModel.swift` stays at 1000 lines (new code in extensions).
Read `CLAUDE.md`, `.claude/rules/dev-environments.md`, memory `arcade-pass-branch-map`.

## Ground truth now on the table
15 object balls on the diamond-line intersections (rows x = k*L/8 for k in
3,2,0,-2,-3; columns y = j*L/8 for j in 1,0,-1; rows k=+-1 empty) plus a cue
ball. `Scripts/grid-truth.py` (branch `claude/grid-harness`) scores any lock:
rms and max error in cm, free-fit spacing. Every accuracy claim must quote it.

## Measured starting point (build 564f8b2, 2026-11-11/12)
- Pocket fit 3-5 mm rms (six pockets), but ball positions are 3.6-3.8 cm rms
  (max 6.8) against the grid with the 2.34 x 1.17 m model, 2.8-2.9 cm (max 4.9)
  with a custom 2.235 x 1.118 m (88 x 44 in) table. Spacing along the length
  fits 2.24-2.26 m. True table size is UNCONFIRMED: owner to measure.
- Failure seen live: after the view changed, the app kept a stale lock and
  showed "Tracking 1 balls" with 15 of 17 detections `offTable`, no warning.
- Five balls named `eight`; 14 of 15 object balls tracked (one missing).
- Camera was out of focus for a while (balls blurred).

## Tasks (in order; each ends with a grid-truth number or a /ui.jpg still)
1. Merge the agent branches the owner has approved (each verified clean:
   `rm -rf Packages/*/.build; Scripts/test-all.sh`, Release iphoneos build,
   swiftlint): `claude/grid-harness`, `claude/calib-health`,
   `claude/ball-identity-2`; read `claude/missing-ball-diagnosis` and
   `claude/ux-rescore` (text only) and act on them.
2. Table size: once the owner confirms the diamond spacing (11.0 in = 88 x 44,
   11.5 in = 92 x 46), add the size via a CueSyncCore contract-change PR
   branch (not merged without the owner) and re-lock; target ball rms <= 2 cm,
   max <= 3.5 cm on the grid. If the owner has not answered, keep the custom
   size path (`calibrateFromPockets v=<L>,<W>`).
3. Remaining error: if rms stays above 2 cm, split it into pose error vs model
   error (lock-to-lock repeatability, near/far bias) and fix the largest.
4. Missing ball and identity: all 15 balls tracked, at most one `eight`,
   colour names stable for 60 s.
5. Design: top gaps from `docs/design/2026-11-12-ux-rescore.md`; each fix proven
   by a before/after `/ui.jpg` stored locally in `~/CueSyncRuns/ui/` (never committed).
6. Motion pass (hero-line cross-fade, corner flash) - code + unit tests; mark
   `needs-device-run` for anything a still cannot show.
7. Feedback and made/missed detection: still `needs-device-run` until the owner
   shoots; record a session when asked and replay it.

## Done when
Grid-truth rms <= 2 cm, 16/16 balls tracked, one eight, stale-lock banner
verified by moving the view (or simulated), design re-score >= 70/100 by the
independent reviewer, `Scripts/test-all.sh` exit 0 from clean, branch pushed,
`docs/roadmap/09-SESSION-STATE.md` updated, memory updated.
