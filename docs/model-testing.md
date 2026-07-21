# Detection model testing & selection (task M2-01)

How to A/B the candidate Roboflow models with the in-app **Detection
Preview**, and how to turn the winner into the bundled on-device Core ML
model the MVP ships with.

## 1. Set up once

1. Make sure your key is in `App/Config/Secrets.xcconfig`
   (`ROBOFLOW_API_KEY = …`; see `Secrets.example.xcconfig`).
2. Check each candidate's **version number**: open the Universe project →
   Model tab; the URL ends in `/model/N`. Fix the `version:` values in
   `App/Sources/DetectionModelCatalog.swift` if they aren't `1`.
3. `Scripts/bootstrap.sh` → open the project → run on your iPhone.

## 2. Compare models at the table

1. In the bottom HUD bar tap **Model** and pick a candidate. Detections from
   the hosted API draw as colored boxes with class + confidence; the HUD
   shows request latency and the status capsule shows the detection count.
2. If boxes look 90° off from the balls, tap the **rotate** button until they
   line up (camera-sensor orientation differs per device orientation; the
   setting persists).
3. Record your screen while panning across the table (Control Center →
   Screen Recording; add it via Settings → Control Center; long-press to
   enable the mic for notes). Capture for each model:
   - full rack from the head of the table,
   - close-up of 3–4 balls,
   - a walk around the table,
   - your worst lighting.
4. Judge: how many of 16 balls hold a stable box; does it distinguish
   cue vs others; false boxes on pockets/reflections; latency is irrelevant
   to quality here (on-device will be ~50× faster).

Expect hosted-API latency of 200–800 ms — that's fine for evaluation. The
table-detection model won't box balls; it's included only to see whether its
table box could later auto-propose rail corners (M3-02 enhancement).

## 3. Train + export the winner to Core ML

Roboflow doesn't export `.mlmodel` directly — the path is YOLO weights →
Ultralytics converter:

1. Fork the winning project into your Roboflow workspace (Universe → Fork).
2. **Train** → Custom Training → architecture **YOLOv11**, size **Nano**
   (fast on-device; Small if Nano underperforms) → Start Training.
   Avoid RF-DETR / Roboflow 3.0 here: their weights aren't portable to
   Core ML — they lock you to Roboflow's SDK.
3. When training finishes, download the weights (`.pt`) from the version
   page (Export/Download Weights).
4. On your Mac:
   ```sh
   python3 -m pip install ultralytics
   yolo export model=path/to/weights.pt format=coreml imgsz=640 nms=True
   ```
   This produces a `.mlpackage`.
5. Rename it `BallDetector.mlpackage`, put it at
   `App/Resources/BallDetector.mlpackage`, commit, push, and note the
   model's class label list — `CoreMLDetectionProvider` is already written
   and gets wired to the bundle in M3-05.

## Notes

- The remote provider (`Packages/DetectionRoboflow`) is evaluation
  tooling: the MVP must work offline on the bundled Core ML model. Never
  make a shipped feature depend on the hosted API.
- Rate limits: the preview throttles to ~2 requests/second; Roboflow's free
  tier is fine for evaluation sessions.
