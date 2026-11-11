# Detector licence: keep Ultralytics or move to an Apache-2.0 model

**Status:** research, 2026-11-10 (web pages read 2026-11-10/11, dates below). Branch
`claude/research-model-licence` (base `origin/claude/research-ball-detection`). No app or
package code changed. No weights, data or footage committed. Scripts: `Tools/research/rfdetr_poc.py`,
`Tools/research/rfdetr_docker.sh`.

**This is research, not legal advice.** It records what the licensors' own pages say and
what was measured. Points marked **[lawyer]** need a lawyer before the app is distributed.

## Verdict

The app can move off Ultralytics, and it should do so **before** any public App Store
release, but not this week. Three facts drive this:

1. **Ultralytics says the shipped model itself is AGPL-3.0.** Its licence page says "All
   Ultralytics YOLO trained models fall under the AGPL-3.0 License by default" and that the
   licence "covers the training code and the models produced by that training code". Its
   Enterprise-licence list names "Using custom-trained or fine-tuned YOLO models in a
   proprietary or commercial setting". So a weights-only `.mlpackage` trained on our own
   data is still covered, in Ultralytics' stated view. The Enterprise price is **not
   published** ("Custom", "contact us").
2. **A permissive replacement with a working Apple export exists.** RF-DETR Nano/Small/Medium/
   Large: code and checkpoints Apache-2.0 (the PML-licensed sizes are Atto/Femto/Pico/XL/2XL,
   which we must not use). Its own docs show a Core ML export with 592 of 599 ops on the
   Neural Engine and 20.8 ms on an M3 Pro (fp16, `CPU_AND_NE`). Our proof of concept
   (below) {{POC_ONE_LINE}}
3. **The cost of switching is mostly data and a decoder, not money.** GPU time for a
   fine-tune is tens of dollars (estimate, RunPod A100 80 GB at $1.79/h). The real cost
   is about 2-3 engineer-weeks plus 10-20 hours of label correction, and one unknown that
   only the iPad can answer: RF-DETR at a ball-friendly 576-640 px input on the A13
   Neural Engine (estimate 60-150 ms per inference; not measured).

**Recommendation: option C (hybrid).** Ship the colour, stick and input-scale fixes on the
current model now (private TestFlight-style use only, no public distribution). In
parallel, label app sessions and fine-tune RF-DETR-Nano (fallback: YOLOX, a plain CNN that
keeps today's NMS pipeline). Switch only when the new model meets the eval bar from the
2026-11-10 research doc on the iPad. Ask Ultralytics for an Enterprise quote at the same
time (free, an email), so the owner can compare a real number against the switch.

## Q1. Licence reality

Sources, all read 2026-11-10:

- Ultralytics licence page: https://www.ultralytics.com/license
- Ultralytics pricing page: https://www.ultralytics.com/pricing
- Ultralytics `LICENSE` (AGPL-3.0, 19 Nov 2007): https://github.com/ultralytics/ultralytics/blob/main/LICENSE
- GNU GPL FAQ (output of a program): https://www.gnu.org/licenses/gpl-faq.html
- FSF on GPL apps in the App Store (2010): https://www.fsf.org/news/2010-05-app-store-compliance

**(a) Ultralytics code.** AGPL-3.0. The app does not link any Ultralytics code: the
`.mlpackage` is a Core ML graph run by Apple's Vision. The Ultralytics code ran only on the
training/export machine. AGPL obligations attach when you *convey* the program (or offer
a modified version over a network). We do not ship Ultralytics code, so (a) by itself
places no obligation on the app. **[lawyer]** confirm.

**(b) Trained weights (Ultralytics' stated position).** Quotes from the licence page:

- "All Ultralytics YOLO trained models fall under the AGPL-3.0 License by default."
- "The AGPL-3.0 License covers the training code and the models produced by that training code."
- The AGPL route means releasing the complete source of the derivative work, including
  "where applicable, model weights"; and this applies even if you "Train your own model
  from scratch", "Do not use pretrained weights", or "Use YOLO only internally or for R&D".
- Uses that need an Enterprise Licence include "Any commercial product or service",
  "Proprietary / closed-source software", "Embedded deployments in hardware, edge devices,
  robotics, cameras, or appliances" and "Using custom-trained or fine-tuned YOLO models in
  a proprietary or commercial setting".

**(c) Our model.** `BallDetector.mlpackage` is YOLOv11n fine-tuned with Ultralytics
(freeze=10, 640 px) starting from Ultralytics' COCO checkpoint, exported by Ultralytics'
exporter (M2-01 in `docs/roadmap/06-MILESTONES.md`; `docs/roadmap/09-SESSION-STATE.md`
"ANE re-export"). It is a derivative of Ultralytics' AGPL weights, which is the strongest
form of the claim, and it falls squarely in what Ultralytics says the AGPL covers.
**Yes: in Ultralytics' view the weights-only mlpackage is covered.** Whether a court
would treat trained weights as a copyright derivative is an open legal question
**[lawyer]**, but a small app should not plan on winning that argument.

**What AGPL compliance would mean for the app.** Release the whole app's source under
AGPL-3.0, plus the weights and training scripts. A second problem sits on top: the FSF's
position (2010, GNU Go) is that Apple's App Store terms add restrictions the GPL forbids;
Apple removed GNU Go rather than change its terms. So "open-source the app under AGPL and
ship on the App Store" is itself legally doubtful **[lawyer]**. In practice the realistic
choices are an Enterprise licence or a model that is not Ultralytics-derived.

**App Store specifically.** The Ultralytics licence page does not mention the App Store or
mobile apps by name. "Embedded deployments ... edge devices" and "Any commercial product or
service" cover a paid or free-with-purchases iOS app in their plain reading.

**Price.** Pricing page: Free $0 (AGPL-3.0), Pro $29 per seat/month (AGPL-3.0), Enterprise
"Custom". Quote: "Platform plans and Ultralytics software licenses are separate." Only
Enterprise includes the commercial licence. **Enterprise price: not published.** The
licence page says licensing is "tailored to each organization's size and specific use
case" and offers a quote form.

**Training-data licence.** The current model was fine-tuned on Roboflow Universe dataset
`xhujustin/pool-ball-agzev` (forked to `cqc/pool-ball-agzev-tekpn`), 1,425 images, recorded
in the repo as **CC BY 4.0** (M2-01, 2026-07). I could **not** re-verify this today:
`universe.roboflow.com` returns HTTP 403 to every fetch tried (WebFetch and curl,
2026-11-10). CC BY 4.0 allows commercial use with attribution. Two caveats **[lawyer]**:
(1) the uploader may not own the underlying photos (Universe sets are often scraped or
frame-grabbed), and CC BY only passes on the rights the uploader had; (2) whether model
weights trained on CC BY data must carry the attribution is unsettled. Cheap mitigation:
credit the dataset in the app's acknowledgements anyway.

**Plain-language summary.** Ultralytics says any model trained with its tools is AGPL. Our
shipped detector is one. Shipping it in a closed-source App Store app means buying their
Enterprise licence (price on request) or taking a legal position against Ultralytics'
stated one. AGPL-compliant open-sourcing does not cleanly fix it on the App Store either.
Private use and development, as today, are not the problem; public distribution is.

**Questions for a lawyer:** (1) Is a fine-tuned weights file a derivative work of the AGPL
checkpoint, and does conveying it in an app trigger AGPL? (2) Are AGPL obligations
compatible with App Store distribution? (3) Is the CC BY 4.0 Universe dataset usable
commercially given unknown image provenance, and what attribution is required? (4) Are
labels produced by the AGPL model on our own footage free of any Ultralytics claim (see Q4)?

## Q2. Candidates

COCO numbers: AP = mAP50:95 on val2017; APs = AP on small objects. RF-DETR, D-FINE,
LW-DETR, YOLO11n APs from the RF-DETR paper table 2 (https://arxiv.org/html/2511.09554,
read 2026-11-10). Other rows from each repo page (read 2026-11-10). "Est." means my
estimate, not a measurement.

| model | code licence | weights licence | params | GFLOPs | COCO AP / APs | input | Core ML route | ANE risk | A13 latency |
|---|---|---|---|---|---|---|---|---|---|
| **RF-DETR-N** | Apache-2.0 | Apache-2.0 (N/S/M/L) | 30.5 M | 31.9 | 48.0 / 25.2 | 384 | built-in `format="coreml"` (iOS 16 mlprogram), documented | low-medium: 592/599 ops on ANE at fp16; topk on CPU | est. 40-80 ms at 384; 90-200 ms at 640 |
| RF-DETR-S | Apache-2.0 | Apache-2.0 | 32.1 M | 59.8 | 52.9 / 32.0 | 512 | same | same (650/658 on ANE) | est. 80-160 ms |
| RF-DETR Atto/Femto/Pico/XL/2XL | Apache-2.0 | **PML 1.0** (needs Roboflow plan; commercial self-hosting needs Enterprise add-on) | | | | | | | **avoid** |
| D-FINE-N | Apache-2.0 | none stated for COCO checkpoints; Objects365 ones "may be subject to the Objects365 dataset terms" | 3.8 M | 7.3 | 42.7 / 22.9 | 640 | no official export; a community `dfine-n-coco` .mlpackage exists (john-rocky/CoreML-Models) | **high**: deformable attention (`grid_sample`) is unlikely to run on ANE; a GPU fallback hits the iOS 26 MPSGraph crash we already know | est. 20-60 ms if it stays on ANE; unknown otherwise |
| D-FINE-S | as above | as above | 10.2 M | 25.2 | 50.6 / 32.6 | 640 | as above | high | unknown |
| LW-DETR-T/S | Apache-2.0 (RF-DETR's base) | not checked | 12.1 / 14.6 M | 21.4 / 31.8 | 42.9 / 22.7; 48.0 / 26.7 | | not checked | | |
| RT-DETRv2-S | Apache-2.0 | Apache-2.0 (repo) | 20 M | 60 | 48.1 / not published on page | 640 | none official | medium-high (deformable attention; v2 offers a discrete sampling option, not verified) | est. 150+ ms |
| **YOLOX-Tiny / S** | Apache-2.0 | Apache-2.0 (repo) | 5.06 / 9.0 M | 6.45 (416) / 26.8 (640) | 32.8 / n.p.; 40.5 / n.p. | 416 / 640 | plain CNN: PyTorch to coremltools is routine; can reuse today's Core ML NMS pipeline | low | est. 15-40 ms (S at 640) |
| NanoDet-Plus-m | Apache-2.0 | Apache-2.0 (repo) | 1.17 M | 0.9 (320) / 1.52 (416) | 27.0; 30.4 / n.p. | 320/416 | CNN, ONNX; Core ML conversion not documented | low | est. < 15 ms; Kirin 980 CPU 11.97-19.77 ms (published) |
| PicoDet-S | Apache-2.0 (PaddleDetection; licence not shown on the config page, not re-verified) | same | 1.18 M | 0.97-1.65 | 29.1-32.5 / n.p. | 320/416 | Paddle to ONNX to Core ML: extra hop, fragile | low-medium | est. < 15 ms; SD865 9.56-15.20 ms (published) |
| EfficientDet-Lite0-2 | not shown on the repo page (google/automl, archived 2026-05-06); not verified | not verified | 3.2-5.3 M | n.p. | 26.41-35.06 / n.p. | n.p. | TF to Core ML: legacy route | medium | "Mobile latency" 36-69 ms (published, device not named) |
| MobileNet-SSD | Apache-2.0 (TF models, not re-verified) | | | | low small-object AP | | legacy | | not recommended for 20 px balls |
| YOLO-NAS | Apache-2.0 code; **weights: "you may not use the Software for any commercial use"** (LICENSE.YOLONAS.md) | restricted | | | | | | | **avoid** (weights) |
| YOLOv5/v8/v11/YOLO26 (Ultralytics), YOLOv9/v7 (GPL-3.0 repos), YOLOv10/v12 (AGPL-3.0, built on Ultralytics) | AGPL/GPL | AGPL/GPL | | | | | | | **avoid** (licence for v7/v9/v10/v12 from memory of their repos, not re-read today) |

Reference point, the shipped model: YOLO11n 2.6 M params, 6.5 GFLOPs, COCO AP 39.5 at
640 (Ultralytics page) / 37.1, APs 17.3 (RF-DETR paper table).

**The small-object catch.** Our balls are 20-24 px at a 640 input today. RF-DETR-N's
default input is 384, which shrinks them to 12-14 px. So the right config is RF-DETR-N
trained at **576 or 640** (resolution must be divisible by `patch_size * num_windows` =
16 x 2 = 32; both are). Compute grows about with pixel count, so 640 costs about
(640/384)^2 = 2.8x the 384 graph: roughly 89 GFLOPs, ~14x the shipped YOLO11n. That is
the main latency risk. The alternatives: tile the table window (the 2026-11-10 research's
input-scale idea) at 384, or RF-DETR-S at 512.

**Latency estimates (flagged).** Published anchor: RF-DETR-N fp16 on an M3 Pro,
`CPU_AND_NE`, 384 px: 20.8 ms p50; fp32 runs CPU-only on ANE paths (73.6 ms)
(https://rfdetr.roboflow.com/latest/exports/coreml/, read 2026-11-10). No iPhone or iPad
numbers are published for any candidate. The A13 Neural Engine is older and smaller than
the M3 Pro's; third-party wikis list 6 vs 18 TOPS (Apple's own figure not verified here).
I scaled by 2-4x for the ANE gap: 40-80 ms at 384, and by the 2.8x pixel factor for 640.
**These are estimates. Only `DetectorComputeProbe` on the iPad can settle them.**

## Q3. Proof of concept

{{POC_SECTION}}

## Q4. Data and training plan

**How many images.** The current model reached mAP50 0.896 on 1,425 images (1000/284/141
split) with a frozen backbone. The RF-DETR paper argues DINOv2 initialisation "significantly
improves detection accuracy on small datasets" and reports RF-DETR-N with APs 30.1 vs 4.8 for
YOLOv8n on RF100-VL (a benchmark of 100 small real-world datasets). It does not publish a
learning curve by image count. Plan (estimate): start from the same 1,425 public images plus
300-600 app frames, and measure at 100/250/500 app frames, as the 2026-11-10 doc already
proposes.

**Public datasets.** Roboflow Universe pages refuse automated fetches (HTTP 403), so the
licences below come from search-result snippets (2026-11-10), **not from the pages
themselves. Open each page and read its licence line before download.**

| dataset | URL | licence (snippet) | images | classes |
|---|---|---|---|---|
| pool-ball-agzev (current) | https://universe.roboflow.com/xhujustin/pool-ball-agzev | CC BY 4.0 (repo record, 2026-07) | 1,425 | color-ball, cue (stick), white-ball |
| Pool Ball V4 | https://universe.roboflow.com/leonardo-wijaya-bdcih/pool-ball-v4 | CC BY 4.0 | 2,076 | 17 |
| Pool Ball Detection | https://universe.roboflow.com/capjamesg/pool-ball-detection-wplun | CC BY 4.0 | ~1,300 | 23 (ball0-15, bags, flag) |
| Pool Ball Detection V3 | https://universe.roboflow.com/billiard-acbcc/pool-ball-detection-v3-sguyh | CC BY 4.0 | 995 | 16 |
| Billiard Pool | https://universe.roboflow.com/billiard-ball-data-set/billiard-pool | CC BY 4.0 | 746 | 12 (balls 1-9, table, rack, white) |
| Pool Billiard | https://universe.roboflow.com/nidacorian-protonmail-com/pool-billiard | CC BY 4.0 | 488 | 12 |
| pool dataset | https://universe.roboflow.com/ankalash/pool-dataset | CC BY 4.0 | 497 | person, billiard-ball, triangle, cue |
| pix2pockets | https://arxiv.org/html/2504.12045v1, project https://pix2pockets.compute.dtu.dk/ | **unclear**: the paper is CC BY 4.0; no dataset licence found; frames come from championship broadcasts | 195 (+52) | per-ball |
| Billiard-dataset (FJ-Rodriguez-Lozano) | https://github.com/FJ-Rodriguez-Lozano/Billiard-dataset | CC BY-SA 4.0 (share-alike: check what it attaches to) | recordings | blackball, carom, snooker |

Several of these sets are built from broadcast or web video. CC BY only grants what the
uploader owned **[lawyer]**. The owner's own footage has no such question, which is the
strongest argument for labelling app sessions.

**Labelling app sessions.** `SessionRecorder` bundles hold `frames.jsonl`, `detections.jsonl`
and video, aligned frame by frame (`App/Sources/SessionRecorder.swift`). Workflow: sample
every Nth frame (the 2026-11-10 doc used every 8th), convert the recorded detections into
pre-labels (COCO JSON), correct in a free local tool (CVAT or Label Studio, self-hosted) or
in Roboflow, add classes the current model lacks (8-ball, stripe/solid if wanted), and keep
a held-out eval split per cloth. Effort estimate: 1-2 minutes per frame to correct ~16
balls plus the stick, so 500 frames is 8-17 hours of human time.

**Legal point on pre-labels.** The GNU FAQ: "The output of a program is not, in general,
covered by the copyright on the code of the program." Ultralytics' licence page does not
address predictions or outputs at all. So boxes the AGPL model suggests on the owner's own
footage, corrected by a person, are the owner's annotations. This is the general rule, not
a ruling on ML outputs **[lawyer]**. Practical hygiene that removes the question: a person
reviews every box, and the new model is never initialised from YOLO weights.

**GPU options (prices read 2026-11-10/11, on-demand, per GPU-hour):**

| provider | GPU | price | source |
|---|---|---|---|
| RunPod Secure | A100 80 GB PCIe / SXM | $1.79 | https://www.runpod.io/pricing (page data "updated Nov 9, 2026") |
| RunPod Secure | L40S 48 GB | $1.09 | same |
| RunPod Secure | L4 24 GB / A40 / RTX A6000 | $0.59 | same |
| RunPod Secure | RTX 4090 | $0.89 | same |
| RunPod Community | RTX 4090 / A100 80 GB | $0.34 / $1.19 (some "from") | same |
| Lambda | A100 40 GB | $1.99 | https://lambda.com/pricing (rates effective 2026-11-16) |
| Lambda | A10 24 GB / A6000 | $1.29 / $1.09 | same |
| Google Colab | any | **not published** without sign-in | https://colab.research.google.com/signup |

**Training estimate (estimate, not measured).** RF-DETR's docs use 100 epochs for
fine-tuning and publish no training times. Assume ~2,000 images at 640 px, 50-100 epochs, one
A100: about 1-3 hours per run. Budget 5-10 runs (resolution, size, class scheme) = 10-30 GPU
hours = **about $20-55 on RunPod A100 Secure, under $100 with slack.** YOLOX-S is cheaper.

**QuinVPS.** Ubuntu 24.04, x86_64, 164 GB free disk (`.claude/rules/dev-environments.md`);
CPU count and RAM are **unknown** (not in the repo docs). It has no GPU. Useful for:
dataset conversion, pre-label export from session bundles, a self-hosted labelling tool,
evaluation runs, Core ML conversion (coremltools converts on Linux; prediction needs macOS).
Not useful for training a DETR: the 1.5 h CPU figure was for YOLOv11n with a frozen backbone;
RF-DETR-N at 640 is ~14x the compute per image, so CPU training would take days per run.

## Q5. Switch cost and risk

| step | work | days (est.) |
|---|---|---|
| 1 | Export RF-DETR-N (COCO, 576/640) to Core ML fp16; run `DetectorComputeProbe` + timing on the iPad 9th gen. **Go/no-go gate before any labelling.** | 1-2 |
| 2 | Decoder: RF-DETR exports raw tensors (`dets`, `labels`; names inferred, match by position), not a Vision NMS pipeline. `CoreMLDetectionProvider` today reads `VNRecognizedObjectObservation`; add a decoder for `VNCoreMLFeatureValueObservation` (cxcywh normalised boxes, sigmoid scores, top-k, threshold, no NMS), ImageNet normalisation (check whether it is baked into the export), and the input resize (`scaleFill` must match training). Unit tests on Linux with a fixture tensor. | 2-3 |
| 3 | Class map: new labels go through `Ball.Kind(classLabel:)`; `cue` = stick semantics must be kept or renamed in one place (CueSyncCore is frozen: a contract-change PR if the mapping lives there). | 0.5-1 |
| 4 | Data: pre-label, correct 300-600 frames, merge with public data, splits. | 3-5 (8-17 h of labelling) |
| 5 | Training runs + eval with `Tools/DetectionEval` against the 2026-11-10 bars. | 2-4 |
| 6 | Calibration: DETR scores are not YOLO scores; re-pick `confidenceFloor` (0.35 today) and retune `BallTracker` gating/stability on replay bundles. | 1-2 |
| 7 | Device verification run (hard rule 4), parity vs the current model on the same scene. | 1-2 |
| **total** | | **~11-19 working days** |

**What could make the switch fail:** (1) RF-DETR at 576-640 is too slow on the A13 ANE
(more than ~150 ms) and 384 loses the balls: fall back to tiling at 384 or to YOLOX-S;
(2) the ANE path aborts on iOS 26 like the old GPU path did; the probe catches it, but then
CPU-only DETR is far too slow (73.6 ms on an M3 Pro CPU at 384); (3) fp16 accuracy loss
(COCO 48.0 to 45.1 in RF-DETR's own fp16 test); (4) public data licence turns out unusable
and app footage alone is too small; (5) set-prediction models with 300 queries can emit
duplicate boxes on touching balls without NMS at low thresholds: needs a check on racks.

**Versus buying the licence.** Enterprise price: not published. Cost to the owner: an
email and a quote. Engineering: zero days now. But each future retrain stays on Ultralytics,
the licence is per term ("during the term", per their page), and the app's core asset stays
dependent on a vendor whose price is unknown.

## Q6. Decision memo (for the owner)

**Option C (recommended): hybrid.** Ship this week's colour/stick/input-scale fixes on the
current model for private use. Start the Apache path now: step 1 gate (2 days), then data
and training. Request an Ultralytics quote in parallel.
- Cost: ~$20-100 GPU (est.), 11-19 engineer-days, 8-17 owner/labeller hours.
- Risk: medium (A13 latency of RF-DETR at 640 is unmeasured).
- Must be true: no public App Store build ships with the YOLO model unless an Enterprise
  licence is signed first.

**Option A: keep YOLO and buy the Enterprise licence.**
- Cost: unknown (not published) per term; 0 engineering days.
- Risk: low technical, open-ended financial; future model work stays tied to Ultralytics.
- Must be true: the quote is affordable for the term and covers App Store distribution of
  a fine-tuned model (ask for that wording explicitly).

**Option B: switch now, stop current-model work.**
- Cost: same money as C, but the visible fixes wait 3-4 weeks.
- Risk: medium-high: users see nothing new while the model is rebuilt.
- Must be true: no release pressure in the next month.

**Go/no-go checklist for the owner:**
- [ ] Decide: is public App Store release planned within 6 months? (If no, C with no rush.)
- [ ] Request the Ultralytics Enterprise quote (no commitment) and record the number.
- [ ] Approve step 1 (RF-DETR export + iPad probe, ~2 days, $0).
- [ ] Gate: RF-DETR-N at 576 or 640 runs on the iPad 9th gen ANE without abort, <= 150 ms.
      If no: try 384 + tiling, then YOLOX-S, before giving up on the switch.
- [ ] Approve labelling time (8-17 h) and a GPU budget cap (suggest $100).
- [ ] Gate: new model meets the 2026-11-10 eval bars (recall >= 0.95, precision >= 0.95).
- [ ] Lawyer questions 1-4 (Q1) answered before the first public build.
- [ ] Add CC BY attributions for any public dataset used to the app's acknowledgements.

## Honest limits

- No legal advice; four questions are marked **[lawyer]**.
- Roboflow Universe pages returned HTTP 403 to automated fetches: every Universe licence in
  this doc, including the current dataset's CC BY 4.0, is from the repo record or search
  snippets, not re-read on the page today.
- Ultralytics Enterprise price: not published. Colab prices: not published without sign-in.
- No A13/ANE measurement: this Mac is an Intel i9-9880H with no Neural Engine. Every A13
  number is an estimate.
- No training run; GPU hours are estimates. QuinVPS CPU/RAM unknown.
- Licences for YOLOv7/v9/v10/v12, PicoDet, MobileNet-SSD and EfficientDet-Lite were not
  re-read today (EfficientDet's repo page did not show one).
- D-FINE Core ML viability rests on a community conversion I did not run.
