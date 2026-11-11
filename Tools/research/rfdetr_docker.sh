#!/bin/sh
# rfdetr_docker.sh
# CueSync AR - research only (2026-11-10, model-licence study)
#
# The development Mac is Intel x86_64: PyTorch wheels stop at 2.2.2 there and
# rfdetr 1.12 needs transformers 5 (torch >= 2.6). This runs the RF-DETR
# proof of concept in a linux/amd64 container instead. Core ML conversion
# works on Linux; Core ML prediction does not, so timing runs on the Mac
# afterwards (coreml_time.py).
#
# Usage: Tools/research/rfdetr_docker.sh <repo-root> <out-dir> [rfdetr_poc.py args...]
# Frames are mounted read-only from ~/CueSyncRuns, ~/CueSyncClips, ~/CueSyncResearch.
set -eu
REPO="$1"; OUT="$2"; shift 2
mkdir -p "${OUT}/pip-cache" "${OUT}/hf-cache"
docker run --rm --platform linux/amd64 \
  -v "${REPO}/Tools/research:/scripts:ro" \
  -v "${REPO}/docs/research:/labels:ro" \
  -v "${HOME}/CueSyncRuns:/root/CueSyncRuns:ro" \
  -v "${HOME}/CueSyncClips:/root/CueSyncClips:ro" \
  -v "${HOME}/CueSyncResearch/session:/root/CueSyncResearch/session:ro" \
  -v "${OUT}:/out" -w /out \
  -e PIP_CACHE_DIR=/out/pip-cache -e HF_HOME=/out/hf-cache \
  python:3.12-slim sh -c "
    apt-get update -qq && apt-get install -y -qq libgl1 libglib2.0-0 libxcb1 >/dev/null &&
    pip install -q --extra-index-url https://download.pytorch.org/whl/cpu 'rfdetr[coreml]' &&
    pip list 2>/dev/null | grep -i -E '^(rfdetr|torch|torchvision|transformers|coremltools|numpy) ' &&
    python -I /scripts/rfdetr_poc.py $*"
