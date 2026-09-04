#!/usr/bin/env bash
# Dispatch gates, cheapest first. dispatch_allowed <mode> -> 0 when a Claude run may start now.
# Order: PAUSED -> busy hours -> daily cap -> weekly minute cap -> host soft-pause -> live probe.

_now_local() { TZ="${BUSY_TZ:-UTC}" date +"%u %H"; }

in_busy_hours() {
  local dow hour h1 h2 days
  read -r dow hour <<<"$(_now_local)"
  [ -n "${BUSY_HOURS:-}" ] || return 1
  h1="${BUSY_HOURS%-*}"; h2="${BUSY_HOURS#*-}"; days="${BUSY_DAYS:-1-5}"
  case "$days" in
    *-*) [ "$dow" -ge "${days%-*}" ] && [ "$dow" -le "${days#*-}" ] || return 1 ;;
    *)   case " $days " in *" $dow "*) ;; *) return 1 ;; esac ;;
  esac
  [ "$((10#$hour))" -ge "$((10#$h1))" ] && [ "$((10#$hour))" -lt "$((10#$h2))" ]
}

dispatch_allowed() {
  local mode="$1"
  [ -f "$AGENT_BASE/PAUSED" ] && { log "GATE: PAUSED."; return 1; }
  in_busy_hours && { log "GATE: busy hours — no new runs."; return 1; }
  [ "$(runs_today)" -ge "${MAX_RUNS_PER_DAY:-6}" ] && { log "GATE: MAX_RUNS_PER_DAY reached."; return 1; }
  [ "$(usage_week_minutes)" -ge "${MAX_MINUTES_PER_WEEK:-600}" ] && { log "GATE: weekly minute cap reached."; return 1; }
  if [ -n "${HOST_SOFT_PAUSE_FILE:-}" ] && [ -e "$HOST_SOFT_PAUSE_FILE" ]; then log "GATE: host soft-pause present."; return 1; fi
  if [ -f "$AGENT_BASE/state/claude-paused-until" ]; then
    local until; until="$(cat "$AGENT_BASE/state/claude-paused-until")"
    [ "$(date +%s)" -lt "${until:-0}" ] && { log "GATE: paused until $until after a usage limit."; return 1; }
  fi
  # Last gate, the only one that spends a turn: prove the account is not already rate-limited.
  if [ "${CAPACITY_PROBE:-1}" = "1" ]; then
    local out
    out="$(timeout 90s claude -p "Reply with the single word ok." --max-turns 1 --model "${PROBE_MODEL:-sonnet}" 2>&1 || true)"
    if printf '%s' "$out" | grep -qiE "usage limit|rate limit|limit reached|429"; then
      date -d '+2 hours' +%s > "$AGENT_BASE/state/claude-paused-until" 2>/dev/null || true
      log "GATE: capacity probe hit a usage limit; pausing 2 h."; return 1
    fi
  fi
  return 0
}

# note_usage_limit "<run output file>" -> pause 2 h when the run ended on a usage limit.
note_usage_limit() {
  grep -qiE "usage limit|rate limit|limit reached" "$1" 2>/dev/null || return 0
  date -d '+2 hours' +%s > "$AGENT_BASE/state/claude-paused-until" 2>/dev/null || true
  log "usage limit detected in run output; pausing 2 h."
}
