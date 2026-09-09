#!/usr/bin/env python3
"""Slice a recorded session bundle into a committable replay fixture.

A full device bundle is ~200 MB, nearly all of it H.264 that replay never
reads (frames carry poses and intrinsics; the detector output is already in
detections.jsonl). This takes a frame window, drops the video, and rewrites
the manifest so `SessionBundleIntegrity.verify` still passes — it hashes
exactly the files named in `manifest.files`, so the video must leave both
the directory and that list together.

Frame indices are preserved, not renumbered, so events.jsonl keeps lining
up with frames.jsonl.

Usage: make-replay-fixture.py <src-bundle> <dst-dir> <first-frame> <last-frame>
"""
import hashlib
import json
import pathlib
import sys

# Which key carries the FRAME index in each file. Explicit per file on
# purpose: snapshots.jsonl has BOTH `index` (its own 0..n sequence, one per
# ~1 s snapshot) and `frame` (the frame it was taken on). Guessing "index
# first" silently sliced snapshots by the wrong number and produced a
# fixture whose snapshots belonged to a different part of the recording.
FRAME_KEY = {
    "frames.jsonl": "index",
    "detections.jsonl": "frame",
    "snapshots.jsonl": "frame",
    "events.jsonl": "frame",
}
JSONL = list(FRAME_KEY)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    lo, hi = int(sys.argv[3]), int(sys.argv[4])
    dst.mkdir(parents=True, exist_ok=True)

    kept = {}
    for name in JSONL:
        source = src / name
        lines = source.read_text().splitlines() if source.exists() else []
        key = FRAME_KEY[name]
        out = []
        for line in lines:
            if not line.strip():
                continue
            record = json.loads(line)
            if key not in record:
                sys.exit(f"{name}: expected a '{key}' field; schema changed?")
            if lo <= record[key] <= hi:
                out.append(line)
        (dst / name).write_text("\n".join(out) + ("\n" if out else ""))
        kept[name] = len(out)

    (dst / "calibration.json").write_bytes((src / "calibration.json").read_bytes())

    manifest = json.loads((src / "manifest.json").read_text())
    manifest["files"] = {
        name: sha256(dst / name)
        for name in sorted(JSONL + ["calibration.json"])
    }
    manifest["frameCount"] = kept["frames.jsonl"]
    manifest.pop("video", None)
    manifest["description"] = (
        f"{manifest.get('source', 'device')} fixture sliced from "
        f"{manifest.get('sessionID')} frames {lo}-{hi}; video omitted"
    )
    # The `video` BLOCK goes (it names a file that is no longer here, and
    # integrity would look for it). The video counters inside `recording`
    # stay: they are required by the decoder, and they honestly describe
    # the recording this was sliced from — which is what `recording` is.
    (dst / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")

    print(f"{dst}: " + ", ".join(f"{k} {v}" for k, v in kept.items()))


if __name__ == "__main__":
    main()
