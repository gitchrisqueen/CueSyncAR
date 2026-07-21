#!/usr/bin/env bash
# Run every package's test suite. Works on macOS and Linux (Swift 6.1+).
set -euo pipefail
cd "$(dirname "$0")/.."

status=0
for manifest in Packages/*/Package.swift; do
  pkg=$(dirname "$manifest")
  echo "==> ${pkg}"
  if ! swift test --package-path "$pkg"; then
    status=1
  fi
done
exit $status
