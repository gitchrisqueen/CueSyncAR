#!/usr/bin/env bash
# ClickUp bridge for items that need the owner. Every id comes from secrets.env
# (CLICKUP_API_TOKEN, CLICKUP_LIST_ID, CLICKUP_ASSIGNEE_ID); nothing here is repo-specific.
# Budget: the shared API allowance is small — one list-level poll every POLL_HOURS while a
# decision is open, and one write per park/flip. Never poll otherwise.

_cu() { curl -sS --max-time 15 -H "Authorization: ${CLICKUP_API_TOKEN:-}" -H "Content-Type: application/json" "$@"; }

clickup_enabled() { [ -n "${CLICKUP_API_TOKEN:-}" ] && [ -n "${CLICKUP_LIST_ID:-}" ]; }

# clickup_create_task "<name>" "<markdown>" "<due YYYY-MM-DD|>" -> task id
clickup_create_task() {
  clickup_enabled || return 0
  local due_ms=""
  [ -n "${3:-}" ] && due_ms="$(date -d "$3 20:00" +%s000 2>/dev/null || true)"
  jq -n --arg n "$1" --arg d "$2" --arg due "$due_ms" --arg a "${CLICKUP_ASSIGNEE_ID:-}" \
     '{name:$n, markdown_description:$d, tags:["needs-chris"], priority:2}
      + (if $due != "" then {due_date:($due|tonumber)} else {} end)
      + (if $a != "" then {assignees:[($a|tonumber)]} else {} end)' \
  | _cu -X POST "https://api.clickup.com/api/v2/list/$CLICKUP_LIST_ID/task" -d @- | jq -r '.id // empty'
}

clickup_comment() { clickup_enabled || return 0; jq -n --arg t "$2" '{comment_text:$t, notify_all:true}' | _cu -X POST "https://api.clickup.com/api/v2/task/$1/comment" -d @- >/dev/null; }

# clickup_flip_ready <task> "<comment>" — the blocker cleared: comment with artifacts, due next
# business day 09:00, so the owner's own notifications fire.
clickup_flip_ready() {
  clickup_enabled || return 0
  local due; due="$(date -d 'next monday 09:00' +%s000 2>/dev/null)"
  case "$(date +%u)" in 1|2|3|4) due="$(date -d 'tomorrow 09:00' +%s000)" ;; esac
  jq -n --arg due "$due" '{due_date:($due|tonumber)}' | _cu -X PUT "https://api.clickup.com/api/v2/task/$1" -d @- >/dev/null
  clickup_comment "$1" "$2"
}

# clickup_recent_owner_comments -> lines "<task id>\t<comment text>" for tasks in the list updated
# since the last poll (one call). Caller decides what is an answer.
clickup_recent_answers() {
  clickup_enabled || return 0
  local stamp="$AGENT_BASE/state/clickup-poll" last now
  now="$(date +%s)"; last="$(cat "$stamp" 2>/dev/null || echo 0)"
  [ $(( now - last )) -ge $(( ${CLICKUP_POLL_HOURS:-2} * 3600 )) ] || return 0
  echo "$now" > "$stamp"
  _cu "https://api.clickup.com/api/v2/list/$CLICKUP_LIST_ID/task?include_closed=false&date_updated_gt=$(( last * 1000 ))" \
    | jq -r '.tasks[]? | "\(.id)\t\(.name)"'
}
