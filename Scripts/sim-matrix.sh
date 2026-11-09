#!/usr/bin/env bash
# Capture the seeded HUD across devices, appearances and Dynamic Type sizes.
#   Scripts/sim-matrix.sh <outdir> <layout> <name:udid>...
# Boots the named device if it is not already up. Other booted simulators are
# left alone (another job may be using them); only the debug mirror, which
# binds port 8787 on the host, can clash with a second booted simulator. Needs
# a built app in $DERIVED (see sim-hud.sh).
set -euo pipefail
out="${1:?outdir}"; layout="${2:?layout}"; shift 2
mkdir -p "${out}"
here="$(cd "$(dirname "$0")" && pwd)"
sizes="${SIZES:-large accessibility-extra-large accessibility-extra-extra-extra-large}"
for pair in "$@"; do
  name="${pair%%:*}"; udid="${pair##*:}"
  xcrun simctl boot "${udid}" 2>/dev/null || true
  xcrun simctl bootstatus "${udid}" -b >/dev/null
  app=$(find "${DERIVED:-/tmp/cuesync-dd}/Build/Products" -maxdepth 3 -name CueSyncAR.app | head -1)
  xcrun simctl install "${udid}" "${app}"
  for appearance in light dark; do
    for size in ${sizes}; do
      xcrun simctl ui "${udid}" appearance "${appearance}"
      xcrun simctl ui "${udid}" content_size "${size}"
      SKIP_INSTALL=1 "${here}/sim-hud.sh" "${udid}" "${layout}" "${out}/${name}-${layout}-${appearance}-${size}.png" >/dev/null
      echo "${name} ${appearance} ${size}"
    done
  done
  xcrun simctl ui "${udid}" content_size large
  xcrun simctl ui "${udid}" appearance light
done
