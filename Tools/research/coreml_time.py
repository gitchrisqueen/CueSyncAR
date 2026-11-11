# coreml_time.py
# CueSync AR - research only (2026-11-10, model-licence study)
#
# Times an exported .mlpackage with Core ML on this Mac (macOS only) and,
# optionally, decodes RF-DETR outputs on real frames to count COCO
# "sports ball" hits. Intel Macs have no Neural Engine: CPU_AND_NE falls
# back to CPU here, so never read these numbers as ANE speed.
#
# Usage:
#   python -I Tools/research/coreml_time.py <model.mlpackage> [--runs 20] [--image f1.jpg ...]

import argparse
import json
import time

import coremltools as ct
import numpy as np
from PIL import Image

MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)
COCO_SPORTS_BALL = 37  # 0-based contiguous COCO-80 index of "sports ball"


def describe(model):
    spec = model.get_spec()
    inputs = {}
    for item in spec.description.input:
        kind = item.type.WhichOneof("Type")
        if kind == "imageType":
            inputs[item.name] = ("image", (item.type.imageType.height, item.type.imageType.width))
        else:
            inputs[item.name] = ("array", tuple(item.type.multiArrayType.shape))
    return inputs, [o.name for o in spec.description.output]


def make_feed(inputs, image=None):
    feed = {}
    for name, (kind, shape) in inputs.items():
        if kind == "image":
            height, width = shape
            feed[name] = (image or Image.new("RGB", (width, height))).resize((width, height))
        elif len(shape) != 4:
            # NMS pipeline scalars (iouThreshold, confidenceThreshold)
            feed[name] = np.array([0.45 if "iou" in name.lower() else 0.35], dtype=np.float64)
        else:
            _, _, height, width = shape
            if image is None:
                feed[name] = np.random.rand(*shape).astype(np.float32)
            else:
                pixels = np.asarray(image.convert("RGB").resize((width, height)), dtype=np.float32) / 255.0
                pixels = (pixels - MEAN) / STD
                feed[name] = pixels.transpose(2, 0, 1)[None].astype(np.float32)
    return feed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("model")
    parser.add_argument("--runs", type=int, default=20)
    parser.add_argument("--image", action="append", default=[])
    parser.add_argument("--threshold", type=float, default=0.3)
    args = parser.parse_args()

    report = {"model": args.model}
    for unit_name in ("CPU_ONLY", "CPU_AND_GPU", "CPU_AND_NE"):
        start = time.perf_counter()
        model = ct.models.MLModel(args.model, compute_units=getattr(ct.ComputeUnit, unit_name))
        load_s = time.perf_counter() - start
        inputs, outputs = describe(model)
        report["inputs"], report["outputs"] = {k: list(v[1]) for k, v in inputs.items()}, outputs
        feed = make_feed(inputs)
        model.predict(feed)
        samples = []
        for _ in range(args.runs):
            start = time.perf_counter()
            model.predict(feed)
            samples.append(time.perf_counter() - start)
        report[unit_name] = {"load_s": round(load_s, 2), "median_ms": round(float(np.median(samples) * 1000), 1),
                             "p90_ms": round(float(np.percentile(samples, 90) * 1000), 1)}

    if args.image:
        model = ct.models.MLModel(args.model, compute_units=ct.ComputeUnit.CPU_ONLY)
        inputs, outputs = describe(model)
        hits = {}
        for path in args.image:
            result = model.predict(make_feed(inputs, Image.open(path)))
            arrays = sorted(result.values(), key=lambda a: a.shape[-1])
            boxes = next(a for a in arrays if a.shape[-1] == 4)[0]
            logits = next(a for a in arrays if a.shape[-1] > 4)[0]
            scores = 1 / (1 + np.exp(-logits))
            ball = scores[:, COCO_SPORTS_BALL] if scores.shape[-1] > COCO_SPORTS_BALL else scores.max(-1)
            top_class = scores.argmax(-1)
            hits[path] = {
                "sports_ball_over_threshold": int((ball >= args.threshold).sum()),
                "max_sports_ball_score": round(float(ball.max()), 3),
                "queries_over_threshold_any_class": int((scores.max(-1) >= args.threshold).sum()),
                "top_classes_over_threshold": sorted(set(int(c) for c, s in zip(top_class, scores.max(-1))
                                                         if s >= args.threshold)),
            }
        report["frames"] = hits
    print(json.dumps(report, indent=1))


if __name__ == "__main__":
    main()
