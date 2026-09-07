#!/usr/bin/env bash
# Seed GitHub issues from the roadmap's open tasks. Two batches; every title/body passes
# public-lint; --apply refuses unless SEED_APPROVED=1 (the owner read the dry run).
#   seed-issues.sh --dry-run [--batch 1|2]     print what would be filed
#   SEED_APPROVED=1 seed-issues.sh --apply --batch 1
set -euo pipefail
AGENT_BASE="${AGENT_BASE:-/opt/cuesync-agent}"; export AGENT_BASE
. "$AGENT_BASE/config.env"; . "$AGENT_BASE/lib/public-lint.sh"
MODE=dry; BATCH=1
for a in "$@"; do case "$a" in --apply) MODE=apply ;; --dry-run) MODE=dry ;; --batch) ;; 1|2) BATCH=$a ;; esac; done
[ "$MODE" = apply ] && [ "${SEED_APPROVED:-0}" != 1 ] && { echo "refusing --apply: SEED_APPROVED=1 required after the owner read the dry run" >&2; exit 2; }
SEEDS="${SEEDS:-$AGENT_BASE/repo/Scripts/agent-runner/seeds/batch-$BATCH.tsv}"
[ -f "$SEEDS" ] || { echo "no seed file $SEEDS" >&2; exit 2; }
labels_ensure() {
  for l in agent:ready agent:working agent:revise agent:blocked needs-human priority:high priority:medium priority:low \
           verify:unit verify:synthetic verify:replay verify:snapshot verify:sim-smoke verify:device \
           risk:contract risk:model risk:workflow risk:docs-claims risk:dependency needs-device-run needs-table-session \
           physics perception ar ui tv infra docs; do
    gh label create "$l" --repo "$SLUG" --force >/dev/null 2>&1 || true
  done
}
# TSV columns: milestone \t title \t labels(comma) \t body-file(relative to seeds/)
while IFS=$'\t' read -r ms title labels bodyf; do
  [ -n "$title" ] || continue; case "$title" in \#*) continue ;; esac
  body="$(cat "$(dirname "$SEEDS")/$bodyf")"
  printf '%s\n%s\n' "$title" "$body" | public_lint_text - || { echo "LINT refused: $title" >&2; exit 1; }
  if [ "$MODE" = dry ]; then printf '\n=== [%s] %s  (%s)\n%s\n' "$ms" "$title" "$labels" "$body"; continue; fi
  labels_ensure
  gh api "repos/$SLUG/milestones" --jq ".[] | select(.title==\"$ms\") | .number" 2>/dev/null | grep -q . || gh api -X POST "repos/$SLUG/milestones" -f title="$ms" >/dev/null
  gh issue create --repo "$SLUG" --title "$title" --body "$body" --milestone "$ms" --label "$labels" 
done < "$SEEDS"
