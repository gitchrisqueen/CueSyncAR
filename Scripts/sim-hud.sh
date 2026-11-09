#!/usr/bin/env bash
# Launch the Debug build on a simulator with a synthetic table seeded
# (App/Sources/DebugSeed.swift) and save a screenshot of the HUD.
#
#   Scripts/sim-hud.sh <udid> <layout:open|blocked|rack> <out.png> [extra simctl-launch args]
#
# Expects the app already built into $DERIVED (default /tmp/cuesync-dd):
#   xcodebuild -project CueSyncAR.xcodeproj -scheme CueSyncAR \
#     -destination "id=<udid>" -derivedDataPath /tmp/cuesync-dd build
# The mirror (port 8787) is on localhost only for one booted simulator at a time.
set -euo pipefail
udid="${1:?udid}"; layout="${2:?layout}"; out="${3:?out.png}"; shift 3
derived="${DERIVED:-/tmp/cuesync-dd}"
app=$(find "${derived}/Build/Products" -maxdepth 3 -name 'CueSyncAR.app' | head -1)
[ -n "${app}" ] || { echo "no built app under ${derived}" >&2; exit 1; }
bundle="CQC.CueSync-AR"

xcrun simctl bootstatus "${udid}" -b >/dev/null
[ "${SKIP_INSTALL:-0}" = 1 ] || xcrun simctl install "${udid}" "${app}"
xcrun simctl terminate "${udid}" "${bundle}" 2>/dev/null || true
xcrun simctl launch "${udid}" "${bundle}" -seedTable "${layout}" "$@" >/dev/null
sleep "${SETTLE:-4}"
xcrun simctl io "${udid}" screenshot "${out}" 2>&1 | tail -1
