#!/usr/bin/env bash
# Pull a recorded session bundle off the device over the LAN.
#
#   Scripts/pull-session.sh <device-ip> [session-id | latest] [destination]
#
# Talks to the app's debug mirror (port 8787, the antenna button in the HUD):
# lists /sessions, downloads every file of the chosen bundle with curl
# (resumable — re-run after a Wi-Fi hiccup and it continues where it
# stopped), then verifies each file's sha256 against manifest.json so the
# bytes on the Mac are the bytes the device wrote. Needs curl, python3 and
# shasum — all present on a stock Mac.
#
# Default destination: ./Sessions/<session-id>/ — gitignored. A bundle
# becomes a committed fixture only deliberately (copy the text files, never
# the video, under Packages/SessionReplay/Tests/SessionReplayTests/Fixtures).
set -euo pipefail

HOST="${1:-}"
SESSION="${2:-latest}"
DEST_ROOT="${3:-Sessions}"
PORT=8787

if [ -z "$HOST" ]; then
  echo "usage: $0 <device-ip> [session-id | latest] [destination-dir]" >&2
  echo "  the device IP is on the HUD next to 'Mirror:' while the mirror is on" >&2
  exit 2
fi

BASE="http://${HOST}:${PORT}"

listing=$(curl -fsS --connect-timeout 5 "${BASE}/sessions") || {
  echo "cannot reach ${BASE}/sessions — is the debug mirror on (antenna button) and the Mac on the same Wi-Fi?" >&2
  exit 1
}

if [ "$SESSION" = "latest" ]; then
  SESSION=$(python3 -c '
import json, sys
sessions = json.load(sys.stdin)["sessions"]
done = [s for s in sessions if s.get("complete") and not s.get("active")]
print(done[0]["id"] if done else "")
' <<<"$listing")
  if [ -z "$SESSION" ]; then
    echo "no finished recording on the device yet (stop the recording first)" >&2
    exit 1
  fi
fi

session_json=$(python3 -c '
import json, sys
wanted = sys.argv[1]
for s in json.load(sys.stdin)["sessions"]:
    if s["id"] == wanted:
        print(json.dumps(s)); break
' "$SESSION" <<<"$listing")
if [ -z "$session_json" ]; then
  echo "session '${SESSION}' not on the device. Available:" >&2
  python3 -c 'import json,sys; [print("  ", s["id"], "(recording…)" if s.get("active") else "", round(s["bytes"]/1e6), "MB") for s in json.load(sys.stdin)["sessions"]]' <<<"$listing" >&2
  exit 1
fi
if [ "$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("active", False))' <<<"$session_json")" = "True" ]; then
  echo "session '${SESSION}' is still recording — stop it on the device first" >&2
  exit 1
fi

DEST="${DEST_ROOT}/${SESSION}"
mkdir -p "$DEST"
echo "pulling ${SESSION} from ${BASE} into ${DEST}"

# name<TAB>bytes, one per line
python3 -c '
import json, sys
for f in json.load(sys.stdin)["files"]:
    # %-format, not an f-string: nested same-type quotes inside an
    # f-string only parse on Python 3.12+, and macOS ships 3.9/3.10.
    print("%s\t%s" % (f["name"], f["bytes"]))
' <<<"$session_json" | while IFS=$'\t' read -r name bytes; do
  target="${DEST}/${name}"
  have=0
  exists=0
  if [ -f "$target" ]; then
    exists=1
    have=$(stat -f%z "$target" 2>/dev/null || stat -c%s "$target")
  fi
  # The existence test is load-bearing for EMPTY files. A legitimately
  # 0-byte artifact (events.jsonl, when the session recorded no taps) has
  # bytes=0, and a missing file also reports have=0 — so a size-only check
  # declared it "already complete" and skipped the fetch, leaving nothing
  # on disk for the manifest to verify against.
  if [ "$exists" = "1" ] && [ "$have" = "$bytes" ]; then
    echo "  ${name}: already complete (${bytes} bytes)"
    continue
  fi
  echo "  ${name}: ${have}/${bytes} bytes, fetching…"
  # -C - resumes from the local file's size; the mirror honours Range.
  curl -fsS --retry 5 --retry-delay 2 --retry-all-errors -C - \
    -o "$target" "${BASE}/sessions/${SESSION}/${name}"
done

echo "verifying sha256 against manifest.json"
status=0
while IFS=$'\t' read -r name expected; do
  if [ ! -f "${DEST}/${name}" ]; then
    echo "  MISSING ${name}"; status=1; continue
  fi
  actual=$(shasum -a 256 "${DEST}/${name}" | cut -d' ' -f1)
  if [ "$actual" = "$expected" ]; then
    echo "  ok      ${name}"
  else
    echo "  BAD     ${name}: expected ${expected}, got ${actual}"; status=1
  fi
done < <(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
for name, digest in sorted(m.get("files", {}).items()):
    print(f"{name}\t{digest}")
' "${DEST}/manifest.json")

if [ "$status" -ne 0 ]; then
  echo "verification FAILED — re-run this script to resume/repair, do not use the bundle" >&2
  exit 1
fi

frames=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["frameCount"])' "${DEST}/manifest.json")
echo "done: ${DEST} (${frames} frames, all files verified)"
# ABSOLUTE path: the replay test resolves the bundle relative to the
# package directory, not the repo root, so the relative form printed here
# used to fail with missingFile("manifest.json").
ABS_DEST=$(cd "$DEST" && pwd)
echo "replay it (writes outputs.jsonl the first time; byte-compares on every later run / platform):"
echo "  CUESYNC_REPLAY_BUNDLE=${ABS_DEST} swift test --package-path Packages/SessionReplay --filter DeviceBundleReplay"
