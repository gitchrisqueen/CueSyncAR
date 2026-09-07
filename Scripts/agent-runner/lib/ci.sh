#!/usr/bin/env bash
# CI state and artifact round-trip for a PR.
#   ci_state <pr>            -> green | red | pending | unknown
#   ci_fetch_artifacts <pr>  -> downloads the newest completed run's artifacts into
#                               $AGENT_BASE/artifacts/<pr>/<sha7>/ and prints that path
#   verify_metrics_ok <dir>  -> 0 when every metrics.json in <dir> reports "pass": true
#   owner_unresolved_threads <pr>   -> owner-STARTED unresolved review threads (id, path, line)
#   owner_thread_bodies <pr> <ids…> -> owner-authored comment bodies of those threads (markdown)
#   resolve_review_thread <id>      -> resolves one thread (write token; tick.sh only)

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

# owner_unresolved_threads <pr> -> one line per UNRESOLVED review thread whose FIRST comment was
# written by the repository owner: "<thread id>\t<path>\t<line>". Threads started by anyone else
# are ignored on purpose: the repository is public, and a stranger's review comment must never
# become work (or a merge blocker) for the runner. Paginates; fails closed (prints nothing and
# returns 1) when the API is unreadable, so a network error never reads as "no threads".
owner_unresolved_threads() {
  local n="$1" cursor="" page more
  while :; do
    page="$(gh api graphql \
      -f query='query($o:String!,$r:String!,$n:Int!,$c:String){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100,after:$c){pageInfo{hasNextPage endCursor}nodes{id isResolved path line comments(first:1){nodes{author{login}}}}}}}}' \
      -f o="${SLUG%%/*}" -f r="${SLUG#*/}" -F n="$n" -f c="$cursor" 2>/dev/null)" || return 1
    printf '%s' "$page" | jq -e '.data.repository.pullRequest.reviewThreads' >/dev/null 2>&1 || return 1
    printf '%s' "$page" | jq -r --arg owner "$OWNER" '
      .data.repository.pullRequest.reviewThreads.nodes[]
      | select(.isResolved|not)
      | select((.comments.nodes[0].author.login // "") == $owner)
      | "\(.id)\t\(.path // "")\t\(.line // "")"'
    more="$(printf '%s' "$page" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')"
    [ "$more" = true ] || break
    cursor="$(printf '%s' "$page" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor')"
    [ -n "$cursor" ] || break
  done
  return 0
}

# owner_thread_bodies <pr> <thread id>... -> markdown: for each thread, the OWNER-authored comments
# only (any reply by another account is dropped). This is what the model is handed as work.
owner_thread_bodies() {
  local n="$1" ids; shift
  ids="$(printf '%s\n' "$@" | jq -R . | jq -s .)"
  gh api graphql \
    -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100){nodes{id path line comments(first:50){nodes{author{login} body}}}}}}}' \
    -f o="${SLUG%%/*}" -f r="${SLUG#*/}" -F n="$n" 2>/dev/null \
  | jq -r --arg owner "$OWNER" --argjson ids "$ids" '
      .data.repository.pullRequest.reviewThreads.nodes[]
      | select(.id as $i | $ids | index($i))
      | "### Thread \(.id) — \(.path // "?"):\(.line // "?")\n"
        + ([.comments.nodes[] | select((.author.login // "") == $owner) | .body] | join("\n\n"))
        + "\n"'
}

# resolve_review_thread <thread id> -> resolves one thread with the WRITE token (tick.sh only).
resolve_review_thread() {
  gh api graphql -f query='mutation($t:ID!){resolveReviewThread(input:{threadId:$t}){thread{isResolved}}}' \
    -f t="$1" --jq '.data.resolveReviewThread.thread.isResolved' 2>/dev/null | grep -qx true
}
