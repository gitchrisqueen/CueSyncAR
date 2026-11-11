#!/usr/bin/env bash
# Build CueSync AR once and install + launch it on the paired iPhone/iPad,
# then confirm over the debug mirror that the device runs THIS commit.
#
#   Scripts/device-push.sh [--build-only] [--config Debug|Release]
#                          [--device "<name or UDID>"]... [--no-verify]
#
# Install path: `devicectl` reaches a device over USB or the same Wi-Fi
# (CoreDevice tunnel). It cannot address a Tailscale IP, so a device that is
# off the home network cannot be pushed to; it is reported, not guessed at.
# After install, the mirror (port 8787) IS reachable over Tailscale, which is
# how this script and Scripts/device-dryrun.py read state and logs back.
#
# Mirror hosts are looked up in ~/.cuesync/mirrors (untracked: device names
# and addresses stay out of this public repo), one per line:
#     <device UDID or name>=<LAN or tailnet host>
# With no entry the script tells you to read `Mirror:` off the HUD.
#
# Needs: Xcode signed in with the project's team (automatic signing), the
# device unlocked, trusted, Developer Mode on. Exit 0 only if every selected
# device was installed, launched and verified.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG=Debug
BUILD_ONLY=0
VERIFY=1
WANT=()
while [ $# -gt 0 ]; do
  case "$1" in
    --build-only) BUILD_ONLY=1 ;;
    --no-verify) VERIFY=0 ;;
    --config) CONFIG="$2"; shift ;;
    --device) WANT+=("$2"); shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

BUNDLE=CQC.CueSync-AR
DD="${HOME}/.cuesync/dd-device-${CONFIG}"
SHA="$(git -C "${REPO}" rev-parse --short=7 HEAD)"
MAP="${HOME}/.cuesync/mirrors"
mkdir -p "${HOME}/.cuesync"

echo "== build ${SHA} (${CONFIG}) for iOS devices"
( cd "${REPO}" && xcodegen generate >/dev/null ) || { echo "xcodegen failed" >&2; exit 1; }
if ! xcodebuild -project "${REPO}/CueSyncAR.xcodeproj" -scheme CueSyncAR \
      -configuration "${CONFIG}" -destination 'generic/platform=iOS' \
      -derivedDataPath "${DD}" -allowProvisioningUpdates build > "${DD}.log" 2>&1; then
  echo "BUILD FAILED, tail of ${DD}.log:" >&2
  grep -E "error:|Signing|provisioning|No account" "${DD}.log" | sort -u | head -8 >&2
  exit 1
fi
APP="$(find "${DD}/Build/Products" -maxdepth 2 -name CueSyncAR.app | head -1)"
echo "built: ${APP}"
[ "${BUILD_ONLY}" = 1 ] && exit 0

LIST="$(mktemp)"
xcrun devicectl list devices --json-output "${LIST}" >/dev/null 2>&1
# name|udid|state|model
ROWS="$(python3 -I - "${LIST}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["result"]["devices"]
for x in d:
    hw, dp, cp = x.get("hardwareProperties", {}), x.get("deviceProperties", {}), x.get("connectionProperties", {})
    if hw.get("platform") not in ("iOS", "iPadOS"):
        continue
    print("|".join([dp.get("name", "?"), hw.get("udid", x.get("identifier", "?")),
                    cp.get("tunnelState", "unknown"), hw.get("marketingName", "")]))
PY
)"
rm -f "${LIST}"

mirror_host() { # udid name -> host or empty
  [ -f "${MAP}" ] || return 0
  grep -E "^($1|$2)=" "${MAP}" | head -1 | cut -d= -f2-
}

RC=0
printf '\n%-28s %-12s %s\n' DEVICE STATE RESULT
while IFS='|' read -r NAME UDID STATE MODEL; do
  [ -n "${NAME}" ] || continue
  if [ ${#WANT[@]} -gt 0 ]; then
    hit=0
    for w in "${WANT[@]}"; do
      if [ "$w" = "${NAME}" ] || [ "$w" = "${UDID}" ]; then hit=1; fi
    done
    [ "${hit}" = 1 ] || continue
  fi
  # `disconnected` is an idle CoreDevice tunnel that devicectl wakes on demand;
  # only `unavailable` means the device cannot be found at all.
  if [ "${STATE}" = unavailable ]; then
    printf '%-28s %-12s %s\n' "${NAME}" "${STATE}" \
      "SKIPPED: not reachable. Same Wi-Fi as this Mac (or USB), screen unlocked, then re-run."
    RC=1; continue
  fi
  if ! xcrun devicectl device install app --device "${UDID}" "${APP}" >/tmp/cs-install.log 2>&1; then
    why="$(grep -iE 'error|failed' /tmp/cs-install.log | head -1)"
    printf '%-28s %-12s %s\n' "${NAME}" "${STATE}" "INSTALL FAILED: ${why}"
    RC=1; continue
  fi
  if ! xcrun devicectl device process launch --device "${UDID}" --terminate-existing \
        "${BUNDLE}" >/tmp/cs-launch.log 2>&1; then
    why="$(grep -iE 'error|locked' /tmp/cs-launch.log | head -1)"
    printf '%-28s %-12s %s\n' "${NAME}" "${STATE}" "LAUNCH FAILED (unlock the device?): ${why}"
    RC=1; continue
  fi
  HOST="$(mirror_host "${UDID}" "${NAME}")"
  if [ "${VERIFY}" = 1 ] && [ -n "${HOST}" ]; then
    sleep 6
    if "${REPO}/Scripts/device-dryrun.py" "${HOST}" --expect-sha "${SHA}" \
         --out "${HOME}/CueSyncRuns/push-${SHA}-${UDID}" >/tmp/cs-verify.log 2>&1; then
      printf '%-28s %-12s %s\n' "${NAME}" "${STATE}" "OK: running ${SHA}, mirror + logs verified (${HOST})"
    else
      why="$(grep -E '^RESULT|FAIL\*' /tmp/cs-verify.log | tr '\n' ' ')"
      printf '%-28s %-12s %s\n' "${NAME}" "${STATE}" "INSTALLED, VERIFY FAILED: ${why}"
      RC=1
    fi
  else
    printf '%-28s %-12s %s\n' "${NAME}" "${STATE}" \
      "INSTALLED + launched ${SHA}. No host mapped in ${MAP}: read 'Mirror:' on the HUD."
  fi
done <<<"${ROWS}"
exit ${RC}
