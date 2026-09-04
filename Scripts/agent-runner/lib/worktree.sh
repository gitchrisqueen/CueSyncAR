#!/usr/bin/env bash
# One git worktree per issue/PR under $WORKROOT; never removed while it holds unpushed work.

: "${REPO:?REPO must be set}"; : "${WORKROOT:?WORKROOT must be set}"

worktree_has_unsaved_work() {
  local wt="$1" br
  [ -d "$wt" ] || return 1
  git -C "$wt" rev-parse --git-dir >/dev/null 2>&1 || return 0
  [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ] && return 0
  br="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" || return 0
  [ -z "$br" ] || [ "$br" = "HEAD" ] && return 0
  if git -C "$wt" rev-parse --verify --quiet "refs/remotes/origin/$br" >/dev/null 2>&1; then
    [ -n "$(git -C "$wt" log --oneline "origin/$br..HEAD" 2>/dev/null)" ] && return 0
    return 1
  fi
  [ -n "$(git -C "$wt" log --oneline "origin/main..HEAD" 2>/dev/null)" ] && return 0
  return 1
}

release_worktree() {
  local wt="$1"
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  case "$wt" in "$WORKROOT"/*) ;; *) return 0 ;; esac
  if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then log "worktree $wt kept: uncommitted changes."; return 0; fi
  if [ "${WORKTREE_MERGED:-0}" != "1" ] && worktree_has_unsaved_work "$wt"; then log "worktree $wt kept: unpushed work."; return 0; fi
  git -C "$REPO" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
  git -C "$REPO" worktree prune >/dev/null 2>&1
}

sweep_stale_worktrees() {
  local stamp="$AGENT_BASE/locks/.worktree-sweep" now age open merged removed=0 wt br
  now="$(date +%s)"
  if [ -f "$stamp" ]; then
    age=$(( now - $(stat -c %Y "$stamp" 2>/dev/null || echo 0) ))
    [ "$age" -lt "${WORKTREE_SWEEP_INTERVAL:-3600}" ] && return 0
  fi
  : > "$stamp"
  open="$(gh pr list --repo "$SLUG" --state open --limit 200 --json headRefName --jq '.[].headRefName' 2>/dev/null)" || return 0
  merged="$(gh pr list --repo "$SLUG" --state merged --limit 400 --json headRefName --jq '.[].headRefName' 2>/dev/null || true)"
  while IFS= read -r wt; do
    [ -n "$wt" ] && [ -d "$wt" ] || continue
    case "$wt" in "$WORKROOT"/*) ;; *) continue ;; esac
    [ $(( now - $(stat -c %Y "$wt" 2>/dev/null || echo "$now") )) -lt "${WORKTREE_GRACE_SECONDS:-7200}" ] && continue
    br="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    [ -n "$br" ] && printf '%s\n' "$open" | grep -qxF "$br" && continue
    if [ -n "$br" ] && printf '%s\n' "$merged" | grep -qxF "$br"; then WORKTREE_MERGED=1 release_worktree "$wt"; else release_worktree "$wt"; fi
    [ ! -d "$wt" ] && removed=$((removed+1))
  done < <(git -C "$REPO" worktree list --porcelain | awk '/^worktree /{print $2}')
  [ "$removed" -gt 0 ] && log "worktree sweep: removed $removed stale worktree(s)."
  return 0
}

add_worktree() {  # <branch> <base ref> -> path
  local branch="$1" base="$2" wt="$WORKROOT/$1" tip
  git -C "$REPO" worktree remove --force "$wt" >/dev/null 2>&1 || true
  rm -rf "$wt"; git -C "$REPO" worktree prune >/dev/null 2>&1
  if git -C "$REPO" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    git -C "$REPO" worktree add "$wt" "origin/$branch" >/dev/null 2>&1
    git -C "$wt" checkout -B "$branch" "origin/$branch" >/dev/null 2>&1
  elif git -C "$REPO" show-ref --verify --quiet "refs/heads/$branch"; then
    tip="$(git -C "$REPO" rev-parse --verify "$branch" 2>/dev/null)" || tip=""
    if [ -n "$tip" ] && git -C "$REPO" merge-base --is-ancestor "$tip" "$base" 2>/dev/null; then
      git -C "$REPO" branch -D "$branch" >/dev/null 2>&1 || true
      git -C "$REPO" worktree add -b "$branch" "$wt" "$base" >/dev/null 2>&1
    else
      git -C "$REPO" worktree add "$wt" "$branch" >/dev/null 2>&1
    fi
  else
    git -C "$REPO" worktree add -b "$branch" "$wt" "$base" >/dev/null 2>&1
  fi
  [ -d "$wt" ] || { log "add_worktree: FAILED ($branch from $base)" >&2; return 1; }
  TICK_WORKTREE="$wt"
  echo "$wt"
}
