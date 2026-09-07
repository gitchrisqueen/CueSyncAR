#!/usr/bin/env bash
# GitHub App installation-token minting — the runner's IDENTITY.
#
# The runner never acts as the repository owner. A GitHub App can author and merge but cannot
# approve its own pull requests, so a prompt-injected run can never green the review gate it is
# supposed to pass. Installation tokens live ~1 h, so a leaked token has an hour of life.
#
# TWO tokens are minted per tick from the same installation:
#   write  — the App's full installation permissions. Lives ONLY in tick.sh's own process; it
#            pushes, merges, comments, labels and opens PRs after public-lint.
#   read   — minted with an explicit `permissions` body (contents/pull_requests/issues/actions:
#            read, metadata: read). This is the ONLY GitHub credential the `claude` child ever
#            sees (tick.sh builds the child's environment from scratch, see run_claude).
# The model therefore cannot push, merge, comment, label or exfiltrate a write credential from
# inside a run, whatever its Bash tool is talked into.
#
# FAIL-CLOSED: unlike the runner this was adapted from, a mint failure aborts the tick. There is
# deliberately no fallback to any stored login on the host.
#
# RS256 is signed with `openssl dgst`; no Python dependency. Minted tokens are cached in
# $AGENT_BASE/state/gh-app-token{,-read} (0600) with their expiry and reused while they still
# outlive one full agent run (GH_APP_TOKEN_SKEW). Never logged, never echoed except by
# gh_app_token().

: "${AGENT_BASE:?AGENT_BASE must be set}"
# shellcheck disable=SC1091
[ -f "$AGENT_BASE/secrets.env" ] && . "$AGENT_BASE/secrets.env" 2>/dev/null
GH_APP_KEY="${GH_APP_KEY:-$AGENT_BASE/secrets/github-app.pem}"
GH_APP_TOKEN_CACHE="${GH_APP_TOKEN_CACHE:-$AGENT_BASE/state/gh-app-token}"
# Refresh 50 min before expiry so the shortest usable token outlives the longest (40 min) run.
GH_APP_TOKEN_SKEW="${GH_APP_TOKEN_SKEW:-3000}"
# Permissions requested for the model-facing token. Must be a subset of the App's own grants.
GH_APP_READ_PERMISSIONS='{"contents":"read","pull_requests":"read","issues":"read","actions":"read","metadata":"read"}'

_b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

_gh_app_jwt() {
  local now hdr pl sig
  [ -r "$GH_APP_KEY" ] || return 1
  [ -n "${GH_APP_ID:-}" ] || return 1
  now="$(date +%s)"
  hdr="$(printf '{"alg":"RS256","typ":"JWT"}' | _b64url)"
  pl="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$GH_APP_ID" | _b64url)"
  sig="$(printf '%s.%s' "$hdr" "$pl" | openssl dgst -sha256 -sign "$GH_APP_KEY" -binary 2>/dev/null | _b64url)"
  [ -n "$sig" ] || return 1
  printf '%s.%s.%s' "$hdr" "$pl" "$sig"
}

_gh_app_installation_id() {
  local jwt f id acct
  f="$AGENT_BASE/state/gh-app-installation-id"
  acct="${GH_APP_ACCOUNT:-${SLUG:-}}"; acct="${acct%%/*}"
  if [ -z "${GH_APP_INSTALLATION_ID:-}" ] && [ -s "$f" ]; then GH_APP_INSTALLATION_ID="$(cat "$f")"; fi
  [ -n "${GH_APP_INSTALLATION_ID:-}" ] && { printf '%s' "$GH_APP_INSTALLATION_ID"; return 0; }
  jwt="$(_gh_app_jwt)" || return 1
  id="$(curl -sS --max-time 10 -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" \
        https://api.github.com/app/installations 2>/dev/null \
        | jq -r --arg a "$acct" '[.[] | select((.account.login // "") == $a) | .id] | first // (.[0].id // empty)' 2>/dev/null)"
  [ -n "$id" ] || return 1
  printf '%s' "$id" > "$f"
  printf '%s' "$id"
}

# "<app slug>[bot]" — the login the trust boundary recognises as the runner's own writes.
_gh_app_bot_login() {
  local jwt f slug
  f="$AGENT_BASE/state/gh-app-bot-login"
  [ -n "${GH_APP_BOT_LOGIN:-}" ] && { printf '%s' "$GH_APP_BOT_LOGIN"; return 0; }
  if [ -s "$f" ]; then cat "$f"; return 0; fi
  jwt="$(_gh_app_jwt)" || return 1
  slug="$(curl -sS --max-time 10 -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" \
          https://api.github.com/app 2>/dev/null | jq -r '.slug // empty')"
  [ -n "$slug" ] || return 1
  printf '%s[bot]' "$slug" > "$f"
  printf '%s[bot]' "$slug"
}

# Numeric user id of "<slug>[bot]" for the noreply address "<id>+<slug>[bot]@users.noreply.github.com".
# Empty when unreadable; the caller then uses the id-less noreply form (still no host name).
_gh_app_bot_uid() {
  local f login id tok
  f="$AGENT_BASE/state/gh-app-bot-uid"
  if [ -s "$f" ]; then cat "$f"; return 0; fi
  login="$(_gh_app_bot_login)" || return 1
  tok="$(gh_app_token write)" || return 1
  id="$(curl -sS --max-time 10 -H "Authorization: Bearer $tok" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/users/$login" 2>/dev/null | jq -r '.id // empty')"
  case "$id" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$id" > "$f"
  printf '%s' "$id"
}

# gh_app_token [write|read] -> prints a cached-or-fresh installation token of that scope.
gh_app_token() {
  local scope="${1:-write}" cache now exp tok jwt inst resp body
  case "$scope" in
    write) cache="$GH_APP_TOKEN_CACHE"; body="" ;;
    read)  cache="$GH_APP_TOKEN_CACHE-read"; body="{\"permissions\":$GH_APP_READ_PERMISSIONS}" ;;
    *) return 1 ;;
  esac
  now="$(date +%s)"
  if [ -s "$cache" ]; then
    exp="$(cut -d' ' -f1 < "$cache" 2>/dev/null)"
    tok="$(cut -d' ' -f2- < "$cache" 2>/dev/null)"
    case "$exp" in ''|*[!0-9]*) exp=0 ;; esac
    if [ -n "$tok" ] && [ "$now" -lt "$(( exp - GH_APP_TOKEN_SKEW ))" ]; then
      printf '%s' "$tok"; return 0
    fi
  fi
  jwt="$(_gh_app_jwt)" || return 1
  inst="$(_gh_app_installation_id)" || return 1
  if [ -n "$body" ]; then
    resp="$(curl -sS --max-time 15 -X POST \
              -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" \
              -H "Content-Type: application/json" -d "$body" \
              "https://api.github.com/app/installations/$inst/access_tokens" 2>/dev/null)"
  else
    resp="$(curl -sS --max-time 15 -X POST \
              -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" \
              "https://api.github.com/app/installations/$inst/access_tokens" 2>/dev/null)"
  fi
  tok="$(printf '%s' "$resp" | jq -r '.token // empty')"
  [ -n "$tok" ] || return 1
  if [ "$scope" = read ]; then
    # Refuse a "read" token that came back with any write grant (a misconfigured App would
    # otherwise hand the model push rights while every log says "read-only").
    printf '%s' "$resp" | jq -e '[.permissions // {} | to_entries[] | select(.value != "read")] | length == 0' >/dev/null 2>&1 || return 1
  fi
  exp="$(date -d "$(printf '%s' "$resp" | jq -r '.expires_at // empty')" +%s 2>/dev/null || echo 0)"
  [ "${exp:-0}" -gt "$now" ] || exp="$(( now + 3300 ))"
  mkdir -p "$(dirname "$cache")"
  ( umask 077; printf '%s %s\n' "$exp" "$tok" > "$cache.new" )
  mv "$cache.new" "$cache"
  printf '%s' "$tok"
}

# gh_app_export_token -> exports the WRITE token + git auth + the bot's git identity into the
# CALLING process (tick.sh), or returns 1. The caller MUST treat 1 as fatal for the tick.
# The model's child process never inherits this environment (run_claude builds its own).
gh_app_export_token() {
  local tok login uid
  tok="$(gh_app_token write)" || return 1
  export GH_TOKEN="$tok"
  # git over https uses the same token through an extra header; no credential helper, no
  # stored login is ever consulted (GH_CONFIG_DIR/GIT_CONFIG_GLOBAL are empty by design).
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0="http.https://github.com/.extraheader"
  export GIT_CONFIG_VALUE_0="AUTHORIZATION: bearer $tok"
  export GH_APP_IDENTITY_ACTIVE=1
  login="$(_gh_app_bot_login)" || return 1
  export GH_APP_BOT_LOGIN="$login"
  # Author/committer identity: without this git derives "<user>@<fqdn>" and every commit leaks
  # the host name (on a tailnet host, the tailnet name). Same values go to the child.
  uid="$(_gh_app_bot_uid 2>/dev/null || true)"
  export GIT_AUTHOR_NAME="$login" GIT_COMMITTER_NAME="$login"
  if [ -n "$uid" ]; then
    export GIT_AUTHOR_EMAIL="${uid}+${login}@users.noreply.github.com"
  else
    export GIT_AUTHOR_EMAIL="${login}@users.noreply.github.com"
  fi
  export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
  # Read-scoped token for the model's environment; minted now so a mint failure is fatal here,
  # not half-way through a dispatch.
  GH_TOKEN_READONLY="$(gh_app_token read)" || return 1
  export GH_TOKEN_READONLY
  return 0
}

# gh_identity_is_installation -> 0 when `gh api user` is NOT a human login (installation tokens
# get 403 on /user). Used by MODE=probe and by every tick before any write.
gh_identity_is_installation() {
  local login
  login="$(gh api user --jq .login 2>/dev/null || true)"
  [ -z "$login" ]
}
