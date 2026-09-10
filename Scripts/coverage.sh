#!/usr/bin/env bash
# Per-package line coverage for the pure SwiftPM packages, measured with llvm-cov and counted
# over each package's OWN sources only (dependency sources compiled into a test binary are
# excluded, as are Tests/ and .build/).
#
#   Scripts/coverage.sh                 measure every package, print a table
#   Scripts/coverage.sh --check         also compare against docs/validation/coverage-floors.json
#                                       (exit 1 when any package is below its floor)
#   Scripts/coverage.sh --lcov DIR      also write DIR/<Package>.lcov per package
#   Scripts/coverage.sh --only Name     restrict to one package
#
# Works on Linux (swift:6.1 image + jq) and macOS (Xcode toolchain, `xcrun llvm-cov`).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLOORS="$ROOT/docs/validation/coverage-floors.json"
CHECK=0; LCOV=""; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;; --lcov) LCOV="$2"; shift ;; --only) ONLY="$2"; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac; shift
done
command -v jq >/dev/null || { echo "coverage.sh needs jq" >&2; exit 2; }
if command -v xcrun >/dev/null 2>&1; then LLVM_COV="xcrun llvm-cov"; else LLVM_COV="llvm-cov"; fi

status=0; rows=()
for manifest in "$ROOT"/Packages/*/Package.swift; do
  pkg="$(dirname "$manifest")"; name="$(basename "$pkg")"
  [ -n "$ONLY" ] && [ "$ONLY" != "$name" ] && continue
  echo "==> $name" >&2
  mkdir -p "$pkg/.build"
  swift test --package-path "$pkg" --enable-code-coverage >/dev/null 2>"$pkg/.build/coverage-test.log" || { echo "tests FAILED in $name (see $pkg/.build/coverage-test.log)" >&2; status=1; continue; }
  prof="$pkg/.build/debug/codecov/default.profdata"
  bin="$(ls -d "$pkg"/.build/debug/*.xctest 2>/dev/null | head -1)"
  if [ -d "$bin/Contents/MacOS" ]; then bin="$bin/Contents/MacOS/$(basename "$bin" .xctest)"; fi
  [ -f "$prof" ] && [ -e "$bin" ] || { echo "no coverage data for $name" >&2; status=1; continue; }
  json="$($LLVM_COV export -summary-only -instr-profile "$prof" "$bin" -ignore-filename-regex='(/Tests/|/\.build/|/checkouts/)')"
  read -r covered count <<<"$(printf '%s' "$json" | jq -r --arg p "/Packages/$name/Sources/" \
      '[.data[0].files[] | select(.filename | contains($p))] | "\(map(.summary.lines.covered)|add // 0) \(map(.summary.lines.count)|add // 0)"')"
  pct="$(awk -v c="$covered" -v n="$count" 'BEGIN{ if (n==0) print "0.0"; else printf "%.1f", c*100/n }')"
  floor="$(jq -r --arg n "$name" '.floors[$n] // empty' "$FLOORS" 2>/dev/null || true)"
  verdict="-"
  if [ "$CHECK" = 1 ]; then
    if [ -z "$floor" ]; then
      # A package with no floor entry used to leave verdict="-", leave
      # `status` untouched, and exit 0 — so anything added to Packages/ was
      # exempt from the gate by default, silently, with the ratchet policy
      # in the floors file enforced only by whoever happened to read the PR.
      echo "no floor for $name in $FLOORS — add one (see the note field)" >&2
      verdict="NO FLOOR"; status=1
    elif awk -v p="$pct" -v f="$floor" 'BEGIN{exit !(p+0 < f+0)}'; then
      verdict="BELOW FLOOR $floor"; status=1
    else
      verdict="ok (floor $floor)"
    fi
  fi
  rows+=("$(printf '%-20s %6s%%  %5s/%-5s  %s' "$name" "$pct" "$covered" "$count" "$verdict")")
  if [ -n "$LCOV" ]; then
    mkdir -p "$LCOV"
    $LLVM_COV export -format=lcov -instr-profile "$prof" "$bin" -ignore-filename-regex='(/Tests/|/\.build/|/checkouts/)' \
      | awk -v p="/Packages/$name/Sources/" 'BEGIN{keep=0} /^SF:/{keep=index($0,p)>0} keep{print} /^end_of_record/{keep=0}' > "$LCOV/$name.lcov"
  fi
done
printf '%s\n' "${rows[@]}"
exit $status
