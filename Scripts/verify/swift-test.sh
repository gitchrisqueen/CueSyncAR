#!/usr/bin/env bash
# Run one package's tests with native Swift when present, else inside the swift:6.1 container.
#   Scripts/verify/swift-test.sh <PackageName> [extra swift test args]
# The container is named, time-boxed, resource-capped, and uses a bind-mounted build cache.
set -euo pipefail
pkg="${1:?package name}"; shift || true
root="$(cd "$(dirname "$0")/../.." && pwd)"
[ -d "$root/Packages/$pkg" ] || { echo "no such package: $pkg" >&2; exit 2; }
if command -v swift >/dev/null 2>&1; then
  exec swift test --package-path "$root/Packages/$pkg" "$@"
fi
cache="${AGENT_BASE:-/tmp}/build-cache"; mkdir -p "$cache"
name="cuesync-swift-$$-$(date +%s)"
exec timeout -k 60 35m docker run --rm --name "$name" \
  --memory 8g --cpus 4 --pids-limit 2048 --security-opt no-new-privileges \
  -u "$(id -u):$(id -g)" -e HOME=/tmp/home \
  -v "$root:/src" -v "$cache:/build" -w /src swift:6.1 \
  swift test --package-path "Packages/$pkg" --scratch-path "/build/$pkg" --cache-path /build/spm-cache "$@"
