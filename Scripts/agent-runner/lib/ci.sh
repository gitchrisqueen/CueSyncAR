#!/usr/bin/env bash
# CI state and artifact round-trip for a PR.
#   ci_state <pr>            -> green | red | pending | unknown
#   ci_fetch_artifacts <pr>  -> downloads the newest completed run's artifacts into
#                               $AGENT_BASE/artifacts/<pr>/<sha7>/ and prints that path
#   verify_metrics_ok <dir>  -> 0 when every metrics.json in <dir> reports "pass": true

ci_state() {
  local n="$1" json
  json="$(gh pr checks "$n" --repo "$SLUG" --json name,state 2>/dev/null)" || { echo unknown; return 0; }
  [ -n "$json" ] || { echo unknown; return 0; }
  if printf '%s' "$json" | jq -e 'any(.[]; .state=="FAILURE" or .state=="ERROR" or .state=="CANCELLED")' >/dev/null; then echo red; return 0; fi
  if printf '%s' "$json" | jq -e 'all(.[]; .state=="SUCCESS" or .state=="SKIPPED" or .state=="NEUTRAL")' >/dev/null; then echo green; return 0; fi
  echo pending
}

ci_fetch_artifacts() {
  local n="$1" sha run dir
  sha="$(gh pr view "$n" --repo "$SLUG" --json headRefOid --jq .headRefOid 2>/dev/null)" || return 1
  [ -n "$sha" ] || return 1
  dir="$AGENT_BASE/artifacts/$n/${sha:0:7}"
  mkdir -p "$dir"
  for run in $(gh run list --repo "$SLUG" --commit "$sha" --status completed --json databaseId --jq '.[].databaseId' 2>/dev/null); do
    gh run download "$run" --repo "$SLUG" -D "$dir" >/dev/null 2>&1 || true
  done
  echo "$dir"
}

verify_metrics_ok() {
  local f ok=0 any=0
  while IFS= read -r f; do
    any=1
    jq -e '.pass == true' "$f" >/dev/null 2>&1 || ok=1
  done < <(find "$1" -name metrics.json 2>/dev/null)
  [ "$any" = 1 ] || return 0   # no metrics yet (smoke form) -> not a failure
  return $ok
}

# review_present <pr> -> 0 when the adversarial self-review marker exists on the CURRENT head.
review_present() {
  local n="$1" sha
  sha="$(gh pr view "$n" --repo "$SLUG" --json headRefOid --jq .headRefOid 2>/dev/null)"
  gh pr view "$n" --repo "$SLUG" --json comments --jq '.comments[].body' 2>/dev/null \
    | grep -qF "Self-review checklist (head ${sha:0:7})"
}

unresolved_threads() {  # <pr> -> count
  gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100){nodes{isResolved}}}}}' \
    -f o="${SLUG%%/*}" -f r="${SLUG#*/}" -F n="$1" --jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved|not)] | length' 2>/dev/null || echo 0
}
