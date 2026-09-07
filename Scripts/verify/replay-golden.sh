#!/usr/bin/env bash
# `Replay golden (Linux)` — replays the committed golden session bundle(s) and asserts byte-equal
# outputs plus the absolute thresholds. Until Packages/SessionReplay lands this is a skeleton
# that verifies the fixture layout only, so the required check exists from day one.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ -d "$ROOT/Packages/SessionReplay" ]; then
  exec swift test --package-path "$ROOT/Packages/SessionReplay" --filter Golden
fi
echo "Packages/SessionReplay not present yet — golden replay skeleton: checking fixture layout only."
if [ -d "$ROOT/Fixtures/Sessions" ]; then
  for m in "$ROOT"/Fixtures/Sessions/*/manifest.json; do
    [ -f "$m" ] || continue
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$m" 2>/dev/null || jq -e . "$m" >/dev/null
    echo "  ok: $m"
  done
fi
echo "golden replay skeleton passed."
