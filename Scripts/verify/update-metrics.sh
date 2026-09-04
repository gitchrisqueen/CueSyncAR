#!/usr/bin/env bash
# Regenerate docs/validation/metrics.json from CI artifacts. The file is never hand-edited: the
# `Metrics consistency` CI step re-runs this against the same inputs and diffs the result.
#   Scripts/verify/update-metrics.sh [ARTIFACT_DIR] > docs/validation/metrics.json
# Every metrics.json found under ARTIFACT_DIR (written by the replay/simulator jobs) is merged
# by its "bundle" key. With no artifacts the output is the empty, schema-tagged document.
set -euo pipefail
dir="${1:-}"
command -v jq >/dev/null || { echo "needs jq" >&2; exit 2; }
if [ -z "$dir" ] || [ ! -d "$dir" ]; then
  jq -n '{schemaVersion: 1, metrics: {}}'; exit 0
fi
find "$dir" -name metrics.json -print0 | sort -z | xargs -0 -r jq -s '
  {schemaVersion: 1,
   metrics: (map(select(.bundle != null)) | map({(.bundle): (del(.bundle))}) | add // {})}'
