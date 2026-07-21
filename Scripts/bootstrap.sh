#!/usr/bin/env bash
# Generate the Xcode project (macOS only). Requires XcodeGen:
#   brew install xcodegen
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen not found. Install with: brew install xcodegen" >&2
  exit 1
fi

xcodegen generate
echo
echo "Generated CueSyncAR.xcodeproj — open it with:"
echo "  open CueSyncAR.xcodeproj"
