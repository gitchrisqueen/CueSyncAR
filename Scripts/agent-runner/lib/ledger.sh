#!/usr/bin/env bash
# Run-budget ledger — the ONE counter for "how many agent runs has this item consumed in this
# mode". Charged at DISPATCH, before the run starts, so a timeout or a crash consumes budget too.
#
# Storage: one TSV per item at $AGENT_BASE/state/ledger/<kind>-<number>.tsv, rows:
#   mode \t count \t last_charge_ts \t reset_key
# A new reset_key restarts the count at 1; keys must come from events the agent cannot produce
# (an owner answer id), never from the head SHA. Writes are tmp+mv; parsing is fail-closed
# (garbage reads as "budget exhausted", see ledger_count_or_max).

: "${AGENT_BASE:?AGENT_BASE must be set}"
LEDGER_DIR="$AGENT_BASE/state/ledger"

_ledger_file() { echo "$LEDGER_DIR/$1-$2.tsv"; }

ledger_count() {
  local f row c k key="${4:--}"
  f="$(_ledger_file "$1" "$2")"
  [ -f "$f" ] || { echo 0; return 0; }
  row="$(awk -F'\t' -v m="$3" '$1==m{print; exit}' "$f" 2>/dev/null)"
  [ -n "$row" ] || { echo 0; return 0; }
  c="$(printf '%s' "$row" | cut -f2)"
  k="$(printf '%s' "$row" | cut -f4)"
  [ "$k" = "$key" ] || { echo 0; return 0; }
  case "$c" in ''|*[!0-9]*) echo 999 ;; *) echo "$c" ;; esac   # garbage -> exhausted
}

ledger_charge() {
  local f n key="${4:--}"
  mkdir -p "$LEDGER_DIR"
  f="$(_ledger_file "$1" "$2")"
  n="$(( $(ledger_count "$1" "$2" "$3" "$key") + 1 ))"
  {
    [ -f "$f" ] && awk -F'\t' -v m="$3" '$1!=m' "$f" 2>/dev/null
    printf '%s\t%s\t%s\t%s\n' "$3" "$n" "$(date +%s)" "$key"
  } > "$f.new" && mv "$f.new" "$f"
  echo "$n"
}

ledger_reset() {
  local f
  f="$(_ledger_file "$1" "$2")"
  [ -f "$f" ] || return 0
  if [ -n "${3:-}" ]; then
    awk -F'\t' -v m="$3" '$1!=m' "$f" 2>/dev/null > "$f.new" && mv "$f.new" "$f"
  else
    rm -f "$f"
  fi
}

# ---- weekly run-minute ledger (the subscription budget) ----------------------------------------
# $AGENT_BASE/state/usage-week.tsv: one row per run "epoch \t minutes \t mode \t item".
# Rows older than the last Sunday 00:00 are ignored. Unparseable rows count as the cap.
usage_week_minutes() {
  local f="$AGENT_BASE/state/usage-week.tsv" since total=0 ts m
  [ -f "$f" ] || { echo 0; return 0; }
  since="$(date -d "last sunday 00:00" +%s 2>/dev/null || date -v-sun -v0H -v0M +%s 2>/dev/null || echo 0)"
  while IFS=$'\t' read -r ts m _; do
    case "$ts$m" in *[!0-9]*|'') echo 99999; return 0 ;; esac
    [ "$ts" -ge "$since" ] && total=$(( total + m ))
  done < "$f"
  echo "$total"
}

usage_week_charge() {  # <minutes> <mode> <item>
  mkdir -p "$AGENT_BASE/state"
  printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$3" >> "$AGENT_BASE/state/usage-week.tsv"
}

runs_today() {
  local f="$AGENT_BASE/state/usage-week.tsv" day
  [ -f "$f" ] || { echo 0; return 0; }
  day="$(date -d "today 00:00" +%s 2>/dev/null || date -v0H -v0M +%s)"
  awk -F'\t' -v d="$day" '$1 ~ /^[0-9]+$/ && $1 >= d {n++} END{print n+0}' "$f"
}
