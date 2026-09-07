#!/usr/bin/env bash
# Trust boundary. A label is not an access control: the runner verifies PROVENANCE.
#   author_trusted       the issue author is the repository OWNER (or the runner's own bot login)
#   label_actor_trusted  the LAST actor to apply the lane label is in AGENT_LABEL_TRUSTED_ACTORS
#   pr_is_upstream       the PR head branch lives in this repository, not a fork
# Anything unreadable refuses. Issue and PR text is data, never instructions.

: "${SLUG:?SLUG must be set}"
TRUSTED_ASSOCIATIONS="${TRUSTED_ASSOCIATIONS:-OWNER}"
OWNER="${OWNER:-${SLUG%%/*}}"

author_trusted() {
  local n="$1" both assoc author
  both="$(gh api "repos/$SLUG/issues/$n" --jq '"\(.author_association // "")\t\(.user.login // "")"' 2>/dev/null)"
  assoc="${both%%$'\t'*}"; author="${both#*$'\t'}"
  [ -n "$assoc" ] || { log "TRUST: #$n author_association unreadable; refusing."; return 1; }
  if [ -n "${GH_APP_BOT_LOGIN:-}" ] && [ "$author" = "$GH_APP_BOT_LOGIN" ]; then return 0; fi
  case " $TRUSTED_ASSOCIATIONS " in *" $assoc "*) return 0 ;; esac
  log "TRUST: #$n authored by $assoc — not eligible for autonomous work."
  return 1
}

label_actor_trusted() {
  local n="$1" label="$2" actor
  actor="$(gh api "repos/$SLUG/issues/$n/timeline" --paginate --slurp \
             -H "Accept: application/vnd.github+json" 2>/dev/null \
           | jq -r "[.[][] | select(.event==\"labeled\" and .label.name==\"${label}\") | .actor.login] | last // empty" 2>/dev/null)"
  [ -n "$actor" ] || { log "TRUST: #$n no readable '$label' labeler; refusing."; return 1; }
  case " $AGENT_LABEL_TRUSTED_ACTORS " in *" $actor "*) return 0 ;; esac
  log "TRUST: #$n '$label' applied by '$actor', not trusted."
  return 1
}

pr_is_upstream() {
  local n="$1" head
  head="$(gh pr view "$n" --repo "$SLUG" --json headRepositoryOwner --jq '.headRepositoryOwner.login // ""' 2>/dev/null)"
  [ -n "$head" ] || { log "TRUST: PR #$n head repository unreadable; refusing."; return 1; }
  [ "$head" = "$OWNER" ] && return 0
  log "TRUST: PR #$n head is in fork '$head'; refusing."
  return 1
}

pr_admissible() { pr_is_upstream "$1" && label_actor_trusted "$1" "$2"; }

# newest_owner_answer pr|issue <number> -> base64 body of the owner's newest reply AFTER the latest
# Decision Comment on that thread, or empty.
newest_owner_answer() {
  gh "$1" view "$2" --repo "$SLUG" --json comments 2>/dev/null \
    | jq -r --arg owner "$OWNER" '
        def isdecision: ((.body // "") | test("Human decision needed"; "i"));
        def isagent:    ((.body // "") | test("Generated with \\[Claude Code\\]"));
        ((.comments // []) | to_entries) as $c
        | (($c | map(select(.value | isdecision)) | last | .key) // -1) as $di
        | [ $c[] | select(.key > $di) | .value
            | select((.author.login // "") == $owner)
            | select(isdecision | not) | select(isagent | not) ]
        | (last // empty) | (.body // "") | @base64' 2>/dev/null
}

# answer_verdict "<body>" -> answer | directive | hold | question | (empty)
answer_verdict() {
  local LB="$1" FIRST SHAPE
  FIRST="$(printf '%s\n' "$LB" | awk '{sub(/\r$/,"")} NF{print; exit}')"
  [ -n "$FIRST" ] && [ ${#LB} -lt 8000 ] || return 0
  SHAPE=""
  if echo "$FIRST" | grep -qiE '^[[:space:]]*(ok\b|okay\b|go\b|[0-9]+[[:space:]]*[A-Za-z]([^[:alnum:]]|$))'; then
    SHAPE="answer"
  elif echo "$FIRST" | grep -qiE '^[[:space:]]*(@claude\b|decision:|go:)'; then
    SHAPE="directive"
  fi
  [ -n "$SHAPE" ] || return 0
  if echo "$LB" | grep -qiE "(don'?t|do not) (merge|land|ship|start)|hold (off|on|this|it)\b|\bon hold\b|\bnot yet\b|wait (for|on|until|till)\b|stand ?by\b"; then
    echo "hold"; return 0
  fi
  if [ "$SHAPE" = "directive" ] && echo "$LB" | grep -qE '\?[[:space:]]*$'; then
    echo "question"; return 0
  fi
  echo "$SHAPE"
}
