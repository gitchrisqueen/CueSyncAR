# Ball detection and identification: what to change, measured

**Status:** research, 2026-11-10. Branch `claude/research-ball-detection` (base
`origin/claude/ipad-remote-run` @ `c7ee941`). No app or `CueSyncCore` code changed.
**Data:** no imagery committed. Frames live in `~/CueSyncClips/`, `~/CueSyncRuns/`,
scratch output in `~/CueSyncResearch/`. Hand labels (coordinates only) are in this
folder: `ball-labels-2026-11-10.json` (9 frames, 79 balls), `ball-labels-ipad-session.json`
(22 frames, 88 ball instances), `stick-labels-2026-11-10.json` (27 frames).
**Scripts:** `Tools/research/` (Python; deps `pillow numpy opencv-python-headless`,
plus a release build of `Tools/DetectionEval`).

## (a) Verdict

The cheapest material wins are not a new model. Three changes, each measured here on
real frames, fix most of the failures reported from the iPad run and the video clips:

1. **Identity (colour):** deciding "black" from the chroma of the ball's *mean*
   white-balanced colour, relative to the cue ball, instead of from the fraction of
   individually chromatic pixels, removes the "dark blue is the 8-ball" error
   (17 of 22 real iPad frames wrong today, 0 of 22 with the change), fixes the
   8-ball that is called blue today (3 of 8 eights missed today, 0 missed), and fixes red
   read as maroon on the iPad (15 of 22 frames today, 0 of 22).
2. **Stick (geometry):** a plain line-segment detector (LSD) on the table, *anchored at
   the cue ball*, finds the stick axis within 3 degrees in 26 of 27 labelled frames (median
   error 0.8 degrees), where the detector's `cue` box never gives an axis and, on the video clips,
   misses the stick in every frame it fires (0 of 5). Unanchored, the same LSD is useless
   (0 of 27): the anchor is the whole idea.
3. **Input scale (detector):** the current model wants balls about **20-24 px, the same on
   both axes**, at its 640x640 input. Sizing a square window on the calibrated table to
   that scale raises ball recall on the video clips from **0.52 to 0.96** (precision
   0.95 to 0.97, 8-ball 1/8 to 8/8). **But it does not help the iPad's own landscape
   framing:** on 22 real iPad frames the full frame already finds 87 of 88 balls, and
   the windowed input finds fewer (62 at 20 px, 80 at 24 px). Crop-and-stretch to the
   table rectangle alone is harmful when the table is wide (iPad: 2 of 4 balls). So:
   choose the input window from calibration, and only when the full-frame ball size
   falls far from about 20 px or is badly squashed. It is not a blanket "crop is better".

A retrained detector is the next step (more classes, cue ball and 8-ball as classes,
better stick behaviour), but it needs labelled data from this app's own sessions first,
and the licence must change: the shipped model is an Ultralytics export (AGPL-3.0 unless
an Enterprise licence is bought). RF-DETR-Nano or D-FINE-N (Apache-2.0) are the
candidates. None of that was trainable or device-timed here.

## (b) Experiments run

All detector runs use the app's own `CoreMLDetectionProvider` through
`Tools/DetectionEval` (Vision, `scaleFill`, `--compute cpu`), confidence floor 0.35
(the pipeline's `confidenceFloor`), detections gated to the table quad grown by one ball
(as the app's `PlayingSurfaceGate` does). A detection matches a label when its box centre is
within 0.6 of a ball diameter (minimum 8 px). Labels were read off upscaled crops with a
pixel grid (`Tools/research/gridview.py`) and checked by overlaying them back (error about
2 px).

Build: `swift build -c release --package-path Tools/DetectionEval`.

### Q1. Input resolution

Command (per label file):

```
python Tools/research/crop_eval.py docs/research/ball-labels-2026-11-10.json \
  --eval-bin Tools/DetectionEval/.build/release/detection-eval \
  --model App/Resources/BallDetector.mlpackage --work ~/CueSyncResearch/q1 \
  --modes full,crop,tiles,scaled16,scaled20,scaled24,scaled28,scaled32
```

**Set A: 9 frames, 79 balls.** 1 iPad still (`ipad-cal/f1.jpg`, 2160x1620, 4 balls) and
3 frames each (f0005/f0030/f0055; `home` uses f0030/f0055 because f0005 is a tight rack)
from the green, blue-cloth and 9 ft clips (720 px wide, balls 22-25 px). 9 cue balls,
8 eight-balls.

| mode | inferences | ball px at model input (w x h, clips) | recall | precision | 8-ball found | cue ball labelled `white-ball` |
|---|---|---|---|---|---|---|
| full frame (today) | 9 | 21 x 12 | **0.519** (41/79) | 0.953 | 1/8 | 1/9 |
| crop to table bbox (stretched) | 9 | 24 x 51 | 0.924 | 0.839 | 8/8 | 3/9 |
| crop, split into square tiles | 16 | 45 x 51 | 0.658 | 0.812 | 6/8 | 1/9 |
| square windows, ball = 16 px | 10 | 16 x 16 | 0.873 | 0.958 | 6/8 | 2/9 |
| **square windows, ball = 20 px** | 10 | 20 x 20 | **0.962** (76/79) | **0.974** | **8/8** | 2/9 |
| square windows, ball = 24 px | 15 | 24 x 24 | 0.911 | 0.923 | 7/8 | 5/9 |
| square windows, ball = 28 px | 25 | 28 x 28 | 0.899 | 0.877 | 8/8 | 2/9 |
| square windows, ball = 32 px | 25 | 32 x 32 | 0.899 | 0.887 | 7/8 | 3/9 |

The three misses at 20 px: a red half-hidden behind a yellow, a cue ball in motion blur, a
cue ball at a cluster. Mean centre error of matched boxes 1.0-2.6 px.

**Set B: the real iPad session, 22 frames, 88 ball instances** (every 8th frame of
`device-20261111T021910Z/video.mp4`, 1440x1080, static scene, 4 balls: red, orange,
white, dark blue; same labels on all frames, checked by eye on frames 1 and 21).

| mode | inferences | recall | precision | cue ball labelled `white-ball` | misses |
|---|---|---|---|---|---|
| **full frame (today)** | 22 | **0.989** (87/88) | 1.000 | 22/22 | blue x1 |
| crop to table bbox (3.0:1, stretched) | 22 | 0.795 | 0.753 | 11/22 | mixed |
| square windows, ball = 20 px | 44 | 0.705 | 1.000 | 20/22 | orange x20 (far rail) |
| square windows, ball = 24 px | 44 | 0.909 | 1.000 | 22/22 | blue x8 |

Reading: the model is scale- *and* context-sensitive. On portrait 9:16 clips the full-frame
stretch squashes balls to about 12 px tall and recall collapses; fixing the aspect
recovers it. On the iPad's landscape 4:3 view, the table fills the frame, balls are already
12x16 px, and the full frame is best on this 4-ball scene. Neither set contains a full
rack at the far rail of a real table, which is where the iPad full-frame path is most likely
to fail; that is untested.

Cost: the model input is fixed at 640x640, so cost scales with the number of windows. Warm
CoreML CPU inference on this Mac (Intel i9-9880H, coremltools `predict`, 20 runs) is
**152 ms per window**; the cropping itself is negligible. On-device per-inference time is
not logged by the app (only `pipelineHz` 2.7-3.3 and overlay latency 179-202 ms on the
iPad 9th gen), so device cost per extra window is not measured here.

### Q4. Identification (colour, 8-ball, cue ball)

```
python Tools/research/ball_colour.py docs/research/ball-labels-2026-11-10.json      # features
python Tools/research/ball_colour.py --score docs/research/ball-labels-2026-11-10.json
python Tools/research/ball_colour.py --score docs/research/ball-labels-ipad-session.json
```

The script samples the inset disc as `BallPatchSampler` does (0.80 of radius, specular
>= 0.97 dropped) and ports `BallAppearance.classify` with its default config, white-balanced
on the frame's cue ball. Candidate fix (`proposed_classify`):

- `chromaRel` = (max - min) of the disc's **mean** white-balanced RGB / cue-ball value.
  Averaging hundreds of pixels removes the sensor noise that made per-pixel relative
  saturation fail on the eight (the reason the shipped code uses an absolute per-pixel
  chroma floor), and dividing by the cue ball, not by the ball's own value, keeps a
  dim blue from falling under an absolute floor.
- black if `chromaRel < 0.15` and value/cue < 0.6; white if `chromaRel < 0.15` otherwise;
  else hue as today; red vs maroon on value **relative to the cue ball** (< 0.75), not absolute
  value (< 0.55).

Why the blue ball fails today: its per-pixel chroma fraction is 0.17 on the 2160 px
still (just above the 0.15 ceiling, so it reads blue there) and below 0.15 in most
H.264 session frames, where it reads black at 0.9 confidence. The feature that separates
it is the mean colour: **blue `chromaRel` 0.24-0.30, CIELAB b* -22 to -28; the seven 8-ball
samples across three clips `chromaRel` 0.020-0.079, b* -0.8 to -8.2.** The margin is about
3x on each side of 0.15.

| set | non-cue balls | current correct | proposed correct | eights missed (current / proposed) | non-eights called black (current / proposed) |
|---|---|---|---|---|---|
| A (clips + iPad still) | 70 | 56 | 59 | **3 / 0** | 0 / 0 |
| B (iPad session) | 66 | 34 | **66** | - | **17 / 0** |

Set B errors today: blue as black 17 times, red as maroon 15 times; the change fixes both.
Set A errors the change does not fix: purple-stripe and purple read blue (2), orange read
yellow (2, the 9 ft clip's warm light), green read blue/yellow (3, dark green in shadow),
red vs maroon both ways (4). **Red vs maroon is not separable by brightness across sets**:
the blue-cloth clip's reds (value/cue 0.72-0.92) overlap the green clip's maroon (0.78-0.90).
That pair needs temporal voting plus the game prior (a UK set has no maroon; a standard set has
exactly one of each), not a better threshold.

The 0.15 threshold was chosen after looking at these numbers, on only 3 distinct 8-balls and
one blue ball. It needs the eval set in (d) before it ships.

**Cue ball without the detector's class.** The detector labels the cue ball `white-ball` in
only 1-5 of 9 clip frames (it finds it as `color-ball`). Picking, per frame, the ball with the
highest raw value x (1 - saturation) picked the cue ball in **31 of 31 frames** (9 set A + 22
set B). This uses labelled positions, so it tests the rule, not the detector, and no frame had a
second white-ish object (a measle/spotted cue ball, the white disc of a nearby 8-ball facing the
camera) on the cloth.

### Q5. The stick

```
python Tools/research/stick_lines.py docs/research/stick-labels-2026-11-10.json ~/CueSyncResearch/dets
```

27 frames with a labelled stick axis: 22 iPad session frames (stick lying on the cloth near
the cue ball) and 5 clip frames (stick in a stance or stroke). Hit = angle error <= 3 degrees and the
labelled tip within one ball diameter of the found line.

| method | hits | median angle error |
|---|---|---|
| detector `cue` class (best box >= 0.35) | no axis, only a box. The box overlaps the stick in 22/27 frames: all 22 iPad frames (box 409x222 px, about a quarter of the table) and **0 of 5 clip frames**. 59 `cue` boxes over 27 frames (2.2 per frame) | - |
| LSD, longest segment on the table | **0/27** | 27.6 degrees (picks a cushion edge) |
| **LSD, anchored at the cue ball** (line within 1 diameter of the ball, near end within 8 diameters) | **26/27** | **0.8 degrees** |

The one miss (`home-f0055`): the stick ends 2 diameters short of the ball and is partly
over the rail. Negative check: on 3 frames where no stick is near the cue ball, the
anchored rule returned nothing (0 false sticks), though 3 frames is a small check. The cost
of `cv2.createLineSegmentDetector` on this Mac: 180 ms on a 1440x1080 frame, 71 ms on the
table crop, 22 ms on a half-scale crop (half-scale accuracy not measured).

## (c) Ranked recommendations

| # | change | expected gain (evidence) | cost | risk | first concrete step |
|---|---|---|---|---|---|
| 1 | **Black/white from mean-colour chroma relative to the cue ball; red/maroon from value relative to the cue ball** (`BallAppearance`) | Set B 34 to 66/66 correct; eights missed 3 to 0; dark balls called 8 17 to 0 | 0.5-1 day incl. Linux tests from the measured vectors | Low. Threshold fitted on few eights; keep the "never call a non-eight the eight" bar in tests | Add `chromaRel` (mean-colour chroma / reference value) to `BallPatch`, fixture the 7 eight and 22 blue vectors from `ball_colour.py`, switch the black rule |
| 2 | **Cue ball = brightest, least saturated ball** when no `white-ball` box, before the white reference is taken; keep tap-to-designate | 31/31 frames right (labelled positions); unblocks #1 on clips where the detector never says `white-ball` | 0.5 day | Medium: measle cue ball, 8-ball disc facing camera. Gate on temporal agreement | Implement in `CueBallIdentity` as a fallback vote with low weight; log disagreements |
| 3 | **Stick from LSD anchored at the cue ball**; drop the `cue` class as an aim source | 26/27 within 3 degrees vs no axis; the `cue` box missed every clip stick | 2-3 days (LSD on a downscaled table crop, plane projection, temporal smoothing via `AimStabilizer`) | Medium: rails and the cue ball's own edge can fake a line; needs a sign (which end is the tip) and occlusion handling by the hand | Port the anchored rule to a Swift prototype in `Tools/` on the recorded sessions; measure on `device-20260909*` bundles with real strokes |
| 4 | **Calibration-driven input window**: from intrinsics + table pose, predict ball px at model input; if the full frame gives < about 14 px on either axis or > 2:1 squash, run square windows sized to about 20-24 px | Clips 0.52 to 0.96 recall; iPad framing: no gain (keep full frame) | 1-2 days | Medium: window count multiplies inference cost; at 20 px the iPad lost the far ball | Add the predicted px to the mirror state; run `crop_eval.py` on a full-rack iPad session before switching |
| 5 | **Retrain the detector (Apache-2.0)**: RF-DETR-Nano or D-FINE-N, classes {ball, cue ball, 8-ball, stick tip/butt keypoints optional}, trained at the window scale of #4 | Unknown until trained; fixes the licence (current model is an Ultralytics export: AGPL-3.0) | 2-4 weeks incl. data | High: ANE export of DETR-class models is unproven on iOS 26 (the shipped YOLO already needed the `.cpuOnly` pin until the ANE probe passed) | Licence decision first (Christopher). Then convert RF-DETR-N to Core ML and run `DetectorComputeProbe` on the iPad before any training |
| 6 | **Temporal identity voting + game prior** (one of each number on a standard set; a pocketed number cannot reappear) | Needed for red/maroon, purple/blue and stripe vs solid, which no single-frame rule here separates | 2-3 days in `BallIdentity` | Low | Add an inventory constraint step after per-track votes (assignment, like the snooker cue-ball paper) |
| 7 | **Fast balls**: predict with the solver between detections, re-acquire in a gated window around the prediction, and use frame differencing on the table ROI to find blurred balls | Not measured. The 9 ft clip's moving balls were the misses at every scale | 3-5 days | Medium | Measure miss rate vs ball speed on a shot recording first |

## (d) Staged plan

**This week (current model, no new data):** #1, #2 in `PerceptionKit` with fixtures from
these labels; #3 as an offline prototype on recorded sessions; add predicted ball px at
model input to the mirror state so #4 can be decided from data; record one iPad session
with a full 15-ball rack (break position and spread) at the far end.

**Needs new data and training (2-6 weeks):** label 300-600 frames from `SessionRecorder`
bundles (frames + detections are already paired: pre-label with the current model, a person
corrects boxes and identity, the corrections become training data). Public sets to seed it:
Roboflow Universe pool/billiards sets (most CC BY 4.0, attribution needed) and pix2pockets
(195 images, 5,748 boxes). Synthetic renders (black/blue/green cloth, warm low light, motion
blur) for the 8-ball-on-black-cloth case, which no real frame here contains. Rough size
estimate, not measured: fine-tuning a COCO-pretrained small detector to a narrow domain
typically needs on the order of a few hundred to 1,500 labelled images per scene type; start
with 500 real frames across 3 cloths and check the learning curve at 100/250/500.

**Needs new hardware or OS features:** none required. Higher frame rates under ARKit are
limited to the formats in `ARWorldTrackingConfiguration.supportedVideoFormats` (60 fps HD
class; 4K is 30 fps), so blur at shot speed cannot be solved by the camera while ARKit owns
it. A newer device (A15+/M-class ANE) buys more windows per frame, not better identity.

**On-device budget (estimate, not measured):** the iPad 9th gen runs today's single
640 inference with the pipeline at about 3 Hz and overlay latency about 180 ms. Every
extra window costs one more inference, so #4 at 2 windows would roughly halve the detect rate
unless detection moves to "detect at a lower rate on the table window, track in between"
(predict positions from the tracker/solver each 60 fps frame, refresh with the detector).
The 100 ms overlay bar is a tracking-and-render problem, not a detector problem: it is
met by drawing from the tracked state every frame, not by detecting faster. Needed
first: log per-inference ms on the device (it is not in the mirror state today).

**Acceptance metrics and eval set.** Eval set: these 31 labelled frames plus, before any
model change, at least 3 iPad sessions (black cloth with the real 8-ball, a full 15-ball rack,
one with shots), 30 labelled frames each, labels in the same JSON shape. Metrics:

| metric | today (measured here) | bar |
|---|---|---|
| ball recall, all 15 + cue | clips 0.52; iPad 4-ball 0.99 | >= 0.95 on every set |
| ball precision on the table | 0.95-1.00 | >= 0.95 |
| cue ball identified (any route) | detector class 1/9 clips, 22/22 iPad | >= 0.98 of frames |
| 8-ball correct / non-8 called 8 | 5/8 eights; 17/22 frames blue called 8 | 100 % / 0 |
| colour family accuracy (non-cue) | 56/70 and 34/66 | >= 0.95 after temporal vote |
| solid/stripe/8 accuracy (per track, after 3 s) | not measured | >= 0.95 |
| stick axis within 3 degrees | no axis | >= 0.9 of frames with a stick |
| positional error | centre error 1-3 px in image; cm not measured | <= 1 cm on the table |
| detector ms per frame on the iPad 9th gen | not logged | logged; overlay latency <= 100 ms |

## (e) Sources

- Ultralytics licence (AGPL-3.0 or Enterprise): https://www.ultralytics.com/license
- Ultralytics Core ML export (YOLO26, `nms` option, INT8): https://docs.ultralytics.com/integrations/coreml
- YOLO26 overview: https://www.ultralytics.com/yolo/yolo26
- RF-DETR (Apache-2.0 for Nano-Large; COCO numbers, 384 px nano): https://github.com/roboflow/rf-detr and paper https://arxiv.org/pdf/2511.09554
- D-FINE (Apache-2.0): https://github.com/Peterande/D-FINE
- SAHI, sliced inference for small objects: https://arxiv.org/pdf/2202.06934, code https://github.com/obss/sahi
- pix2pockets (8-ball shot suggestion from one image, dataset 195 images / 5,748 boxes): https://arxiv.org/html/2504.12045v1
- Rule-constrained cue-ball identification in snooker (inventory constraints): https://arxiv.org/pdf/2609.23450
- Attention-Pool (9-ball video analytics): https://www.mdpi.com/2073-431X/14/9/352
- Roboflow Universe pool datasets (CC BY 4.0), e.g. https://universe.roboflow.com/billiard-ball-data-set/billiard-pool and https://universe.roboflow.com/capjamesg/pool-ball-detection-wplun
- ARKit video formats and 4K at 30 fps: https://developer.apple.com/documentation/arkit/arconfiguration/recommendedvideoformatfor4kresolution, https://developer.apple.com/videos/play/wwdc2022/10126/
- LSD in OpenCV: https://docs.opencv.org/4.x/db/d73/classcv_1_1LineSegmentDetector.html
- Vision trajectory detection (candidate for fast balls, not tested): https://developer.apple.com/documentation/vision/vndetecttrajectoriesrequest

## (f) Honest limits

- **Small, partly re-used data.** 31 frames; the iPad scene is static with 4 balls, so set B
  is 22 views of the same layout, not 88 independent balls. Only 3 distinct 8-balls, one
  blue, one maroon. No 8-ball on black cloth exists in any frame I had.
- **Thresholds were fitted after seeing the data** (0.15 chroma, 0.6/0.75 value, window
  sizes). They need the larger eval set before shipping.
- **No device timing.** All ms are an Intel Mac CPU; there is no ANE here, and the app does not
  log per-inference time. The A13 budget in (d) is an estimate.
- **Not run:** any new model (no training, no export, no RF-DETR/D-FINE conversion), synthetic
  rendering, tracking of fast balls (Q6 is literature and reasoning only), positional error in cm,
  stripe/solid accuracy, LSD at half scale for accuracy, and the anchored stick rule with the hand
  occluding the tip.
- **The clips are compressed web video** at 720 px wide, not ARKit buffers; scale effects
  may differ from the device.
- The cue-ball rule and the colour rule used hand-labelled ball positions, not detector boxes;
  `BallPatchSampler` samples the detector box, which was measured robust to plus or minus 3 px in
  `docs/design/ball-identity.md`.
