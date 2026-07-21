#!/usr/bin/env bash
# Fix lint/format issues locally before pushing (best effort: each tool runs
# only if installed). CI runs SwiftLint in report-only mode; keep it clean.
set -uo pipefail
cd "$(dirname "$0")/.."

if command -v swiftlint >/dev/null 2>&1; then
  swiftlint lint --fix --quiet || true
  swiftlint lint
else
  echo "swiftlint not installed — skipping (brew install swiftlint)"
fi
