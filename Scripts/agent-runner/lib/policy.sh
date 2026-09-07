#!/usr/bin/env bash
# Merge tiers and the never-touch set.
#   never_touch_path <path>        -> 0 when the runner may NOT author changes to <path>
#   tier_for_paths <paths…>        -> prints A or B
#   refuse_never_touch <paths…>    -> 1 (and logs) when any path is in the never-touch set
#   changed_paths <base> <head>    -> every path touched between <base> and <head>, unbounded,
#                                     rename-blind (a rename is a delete + an add), cwd = a repo
# Tier A = tested code the runner may merge itself; tier B = claims, images, models, automation,
# contracts, anything the owner runs on his own machine — the owner merges. The lists are
# deliberately conservative; widen them only in a PR the owner merges (this file is itself
# never-touch).
#
# Matching is CASE-INSENSITIVE: the owner's macOS checkout is case-insensitive, so a PR that adds
# `.Claude/settings.local.json` or `.MCP.json` lands on the real file there. GitHub's CODEOWNERS
# (.github/CODEOWNERS) mirrors the tier-B set so that GitHub, not this script, enforces the
# owner's review on tier-B paths; keep the two in step.

_lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

never_touch_path() {
  case "$(_lc "$1")" in
    .github/*|.claude/*|.mcp.json|scripts/agent-runner/*|scripts/verify/*|.gitleaks.toml|app/config/*) return 0 ;;
    .github|.claude|scripts/agent-runner|scripts/verify|app/config) return 0 ;;
  esac
  return 1
}

_tier_b_path() {
  local p; p="$(_lc "$1")"
  case "$p" in
    readme.md|claude.md|contributing.md|license|project.yml|.swiftlint.yml|.gitmodules) return 0 ;;
    package.resolved|*/package.resolved) return 0 ;;
    packages/cuesynccore/*) return 0 ;;
    docs/roadmap/09-session-state.md) return 1 ;;
    docs/validation/metrics.json|docs/validation/coverage-floors.json) return 1 ;;
    docs/*) return 0 ;;
    *.mlpackage/*|*.mlmodel|*.jpg|*.jpeg|*.png|*.heic|*.mov|*.mp4) return 0 ;;
    package.swift|*/package.swift|package@swift-*.swift|*/package@swift-*.swift) return 0 ;;   # may add a dependency: owner reads it
    scripts/*.sh|tools/*) return 0 ;;   # the owner runs these on his own machine
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

refuse_never_touch() {
  local p bad=0
  for p in "$@"; do
    if never_touch_path "$p"; then log "POLICY: '$p' is never-touch for the runner."; bad=1; fi
  done
  return $bad
}

# changed_paths <base> <head> — computed LOCALLY from git, never from `gh pr view --json files`
# (which stops at 100 files and reports only the new side of a rename). Prints one path per line;
# returns 1 when git cannot compute the diff, so an unreadable diff never reads as "no paths".
changed_paths() {
  git diff --name-only --no-renames "$1...$2" 2>/dev/null
}
