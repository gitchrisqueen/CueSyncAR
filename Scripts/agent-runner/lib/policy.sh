#!/usr/bin/env bash
# Merge tiers and the never-touch set.
#   never_touch_path <path>   -> 0 when the runner may NOT author changes to <path>
#   tier_for_paths <paths…>   -> prints A or B
# Tier A = tested code the runner may merge itself; tier B = claims, images, models, automation,
# contracts — the owner merges. The lists are deliberately conservative; widen them only in a PR
# the owner merges (this file is itself never-touch).

never_touch_path() {
  case "$1" in
    .github/*|.claude/*|.mcp.json|Scripts/agent-runner/*|Scripts/verify/*|.gitleaks.toml|App/Config/*) return 0 ;;
  esac
  return 1
}

_tier_b_path() {
  case "$1" in
    README.md|CLAUDE.md|CONTRIBUTING.md|LICENSE|project.yml|.swiftlint.yml|Package.resolved) return 0 ;;
    Packages/CueSyncCore/*) return 0 ;;
    docs/roadmap/09-SESSION-STATE.md) return 1 ;;
    docs/validation/metrics.json|docs/validation/coverage-floors.json) return 1 ;;
    docs/*) return 0 ;;
    *.mlpackage/*|*.mlmodel|*.jpg|*.jpeg|*.png|*.heic|*.mov|*.mp4) return 0 ;;
    */Package.swift) return 0 ;;   # a manifest change may add a dependency: owner reads it
  esac
  never_touch_path "$1" && return 0
  return 1
}

# Approved-by-sha256 image/threshold files (one "<sha256>  <path>" per line, untracked on the host)
# are tier A even though their pattern is tier B.
_approved_file() {
  local f="$AGENT_BASE/approved-files.sha256" want have
  [ -f "$f" ] && [ -f "$WORKTREE/$1" ] || return 1
  want="$(awk -v p="$1" '$2==p{print $1}' "$f")"
  [ -n "$want" ] || return 1
  have="$(sha256sum "$WORKTREE/$1" | cut -d' ' -f1)"
  [ "$want" = "$have" ]
}

tier_for_paths() {
  local p
  for p in "$@"; do
    if _tier_b_path "$p" && ! _approved_file "$p"; then echo B; return 0; fi
  done
  echo A
}

# refuse_never_touch <paths…> -> 1 (and logs) when any path is in the never-touch set.
refuse_never_touch() {
  local p bad=0
  for p in "$@"; do
    if never_touch_path "$p"; then log "POLICY: '$p' is never-touch for the runner."; bad=1; fi
  done
  return $bad
}
