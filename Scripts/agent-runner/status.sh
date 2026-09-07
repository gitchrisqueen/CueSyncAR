#!/usr/bin/env bash
# Read-only status of the CueSync AR agent runner.
AGENT_BASE="${AGENT_BASE:-/opt/cuesync-agent}"
. "$AGENT_BASE/config.env" 2>/dev/null; . "$AGENT_BASE/secrets.env" 2>/dev/null
echo "runner: $AGENT_BASE  $([ -f "$AGENT_BASE/PAUSED" ] && echo PAUSED || echo LIVE)"
echo "last tick: $(ls -t "$AGENT_BASE"/logs/tick-*.log 2>/dev/null | head -1 | xargs -r tail -n 3 | sed 's/^/  /')"
echo "runs today: $(awk -F'\t' -v d="$(date -d 'today 00:00' +%s 2>/dev/null)" '$1>=d{n++}END{print n+0}' "$AGENT_BASE/state/usage-week.tsv" 2>/dev/null)   week minutes: $(awk -F'\t' '{s+=$2}END{print s+0}' "$AGENT_BASE/state/usage-week.tsv" 2>/dev/null)"
[ -f "$AGENT_BASE/state/claude-paused-until" ] && echo "usage-limit pause until: $(date -d @"$(cat "$AGENT_BASE/state/claude-paused-until")" 2>/dev/null)"
if [ -n "${SLUG:-}" ] && command -v gh >/dev/null && [ -n "${GH_TOKEN:-}" ]; then
  echo "queue:   $(gh issue list --repo "$SLUG" --label agent:ready --json number --jq length 2>/dev/null) ready, $(gh issue list --repo "$SLUG" --label agent:working --json number --jq length 2>/dev/null) working, $(gh issue list --repo "$SLUG" --label needs-human --json number --jq length 2>/dev/null) needs-human"
  echo "PRs:     $(gh pr list --repo "$SLUG" --label agent:working --json number,title --jq '.[] | "#\(.number) \(.title)"' 2>/dev/null | tr '\n' ';')"
fi
echo "worktrees: $(git -C "$AGENT_BASE/repo" worktree list 2>/dev/null | wc -l | tr -d ' ')   containers: $(docker ps -q -f name=cuesync-swift 2>/dev/null | wc -l | tr -d ' ')"
