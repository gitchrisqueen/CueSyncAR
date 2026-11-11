# rfdetr_poc.py
# CueSync AR - research only (2026-11-10, model-licence study)
#
# Sanity check for an Apache-2.0 detector: run the public COCO RF-DETR
# checkpoint on the hand-labelled frames and count how many labelled balls the
# COCO "sports ball" class finds, using the same match rule as the
# 2026-11-10 ball-detection research (box centre within 0.6 of a ball
# diameter, minimum 8 px). Optionally exports to Core ML and times it.
#
# Usage (temp venv, never inside the repo):
#   python -I Tools/research/rfdetr_poc.py --labels docs/research/ball-labels-2026-11-10.json \
#       --labels docs/research/ball-labels-ipad-session.json --size nano --threshold 0.3
#   python -I Tools/research/rfdetr_poc.py --size nano --export-dir ~/CueSyncResearch/licence/export
#
# No imagery or weights are written to the repo.

import argparse
import json
import os
import sys
import time

import numpy as np
from PIL import Image


def load_frames(label_files):
    frames = []
    for path in label_files:
        with open(path) as handle:
            data = json.load(handle)
        for frame in data["frames"]:
            frame["path"] = os.path.expanduser(frame["path"])
            frames.append(frame)
    return frames


def make_model(size):
    import rfdetr

    cls = {"nano": rfdetr.RFDETRNano, "small": rfdetr.RFDETRSmall, "medium": rfdetr.RFDETRMedium}[size]
    return cls()


def sports_ball_ids(model):
    # Gotcha found in this study: for the pretrained COCO checkpoint,
    # predict() returns ORIGINAL COCO category ids (1-90, with gaps;
    # "sports ball" = 37), while model.class_names is the 0-indexed
    # 80-name list. Indexing that list with class_id mislabels every box
    # (37 reads as "surfboard"). Use the id-keyed COCO_CLASSES dict.
    from rfdetr.assets.coco_classes import COCO_CLASSES

    return {k for k, v in COCO_CLASSES.items() if v == "sports ball"}, dict(COCO_CLASSES)


def evaluate(model, frames, threshold):
    ball_ids, names = sports_ball_ids(model)
    total = found = false_pos = 0
    class_hist = {}
    times = []
    for frame in frames:
        image = Image.open(frame["path"]).convert("RGB")
        start = time.perf_counter()
        dets = model.predict(image, threshold=threshold)
        times.append(time.perf_counter() - start)
        centres = []
        for box, cid in zip(dets.xyxy, dets.class_id):
            label = names.get(int(cid), str(cid))
            class_hist[label] = class_hist.get(label, 0) + 1
            if int(cid) in ball_ids:
                centres.append(((box[0] + box[2]) / 2, (box[1] + box[3]) / 2))
        used = set()
        for ball in frame["balls"]:
            total += 1
            diameter = ball.get("d", frame.get("ballDiameterPx", 20))
            radius = max(8.0, 0.6 * diameter)
            best = None
            for idx, (cx, cy) in enumerate(centres):
                if idx in used:
                    continue
                dist = ((cx - ball["x"]) ** 2 + (cy - ball["y"]) ** 2) ** 0.5
                if dist <= radius and (best is None or dist < best[1]):
                    best = (idx, dist)
            if best is not None:
                used.add(best[0])
                found += 1
        false_pos += len(centres) - len(used)
    return {
        "frames": len(frames),
        "balls": total,
        "sports_ball_matched": found,
        "sports_ball_unmatched": false_pos,
        "class_histogram": dict(sorted(class_hist.items(), key=lambda kv: -kv[1])),
        "median_predict_ms": float(np.median(times) * 1000) if times else None,
    }


def export_and_time(model, export_dir, precision, neural_engine, runs):
    import coremltools as ct

    start = time.perf_counter()
    path = model.export(output_dir=export_dir, format="coreml", coreml_precision=precision,
                        coreml_neural_engine=neural_engine)
    result = {"export_path": str(path), "export_s": round(time.perf_counter() - start, 1)}
    spec_model = ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.CPU_ONLY)
    spec = spec_model.get_spec()
    inputs = {i.name: i for i in spec.description.input}
    result["inputs"] = {n: str(i.type).replace("\n", " ") for n, i in inputs.items()}
    result["outputs"] = [o.name for o in spec.description.output]
    if sys.platform != "darwin":
        result["timing"] = "skipped: Core ML prediction runs only on macOS (use coreml_time.py on the Mac)"
        return result
    for unit_name in ("CPU_ONLY", "CPU_AND_GPU"):
        mlmodel = ct.models.MLModel(str(path), compute_units=getattr(ct.ComputeUnit, unit_name))
        feed = {}
        for name, inp in inputs.items():
            if inp.type.WhichOneof("Type") == "imageType":
                feed[name] = Image.new("RGB", (inp.type.imageType.width, inp.type.imageType.height))
            else:
                shape = list(inp.type.multiArrayType.shape)
                feed[name] = np.random.rand(*shape).astype(np.float32)
        mlmodel.predict(feed)  # warm-up / compile
        samples = []
        for _ in range(runs):
            start = time.perf_counter()
            mlmodel.predict(feed)
            samples.append(time.perf_counter() - start)
        result[f"median_ms_{unit_name}"] = round(float(np.median(samples) * 1000), 1)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--labels", action="append", default=[])
    parser.add_argument("--size", default="nano")
    parser.add_argument("--threshold", type=float, default=0.3)
    parser.add_argument("--export-dir")
    parser.add_argument("--precision", default="float16")
    parser.add_argument("--neural-engine", action="store_true")
    parser.add_argument("--runs", type=int, default=10)
    args = parser.parse_args()

    model = make_model(args.size)
    report = {"size": args.size, "threshold": args.threshold}
    for path in args.labels:
        for threshold in sorted({args.threshold, 0.1}):
            report[f"eval {os.path.basename(path)} @{threshold}"] = evaluate(model, load_frames([path]), threshold)
    if args.export_dir:
        try:
            report["coreml"] = export_and_time(model, os.path.expanduser(args.export_dir), args.precision,
                                               args.neural_engine, args.runs)
        except Exception as error:  # record the exact failure, the point of the probe
            report["coreml"] = {"error": f"{type(error).__name__}: {error}"}
    print(json.dumps(report, indent=1, default=str))


if __name__ == "__main__":
    main()
