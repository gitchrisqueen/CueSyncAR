#!/usr/bin/env bash
# GitHub App installation-token minting — the runner's IDENTITY.
#
# The runner never acts as the repository owner. A GitHub App can author and merge but cannot
# approve its own pull requests, so a prompt-injected run can never green the review gate it is
# supposed to pass. Installation tokens live ~1 h, so a leaked token has an hour of life.
#
# FAIL-CLOSED: unlike the runner this was adapted from, a mint failure aborts the tick. There is
# deliberately no fallback to any stored login on the host.
#
# RS256 is signed with `openssl dgst`; no Python dependency. The minted token is cached in
# $AGENT_BASE/state/gh-app-token (0600) with its expiry and reused while it still outlives one
# full agent run (GH_APP_TOKEN_SKEW). Never logged, never echoed except by gh_app_token().

: "${AGENT_BASE:?AGENT_BASE must be set}"
# shellcheck disable=SC1091
[ -f "$AGENT_BASE/secrets.env" ] && . "$AGENT_BASE/secrets.env" 2>/dev/null
GH_APP_KEY="${GH_APP_KEY:-$AGENT_BASE/secrets/github-app.pem}"
GH_APP_TOKEN_CACHE="${GH_APP_TOKEN_CACHE:-$AGENT_BASE/state/gh-app-token}"
# Refresh 50 min before expiry so the shortest usable token outlives the longest (40 min) run.
GH_APP_TOKEN_SKEW="${GH_APP_TOKEN_SKEW:-3000}"

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

gh_app_token() {
  local now exp tok jwt inst resp
  now="$(date +%s)"
  if [ -s "$GH_APP_TOKEN_CACHE" ]; then
    exp="$(cut -d' ' -f1 < "$GH_APP_TOKEN_CACHE" 2>/dev/null)"
    tok="$(cut -d' ' -f2- < "$GH_APP_TOKEN_CACHE" 2>/dev/null)"
    case "$exp" in ''|*[!0-9]*) exp=0 ;; esac
    if [ -n "$tok" ] && [ "$now" -lt "$(( exp - GH_APP_TOKEN_SKEW ))" ]; then
      printf '%s' "$tok"; return 0
    fi
  fi
  jwt="$(_gh_app_jwt)" || return 1
  inst="$(_gh_app_installation_id)" || return 1
  resp="$(curl -sS --max-time 15 -X POST \
            -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" \
            "https://api.github.com/app/installations/$inst/access_tokens" 2>/dev/null)"
  tok="$(printf '%s' "$resp" | jq -r '.token // empty')"
  [ -n "$tok" ] || return 1
  exp="$(date -d "$(printf '%s' "$resp" | jq -r '.expires_at // empty')" +%s 2>/dev/null || echo 0)"
  [ "${exp:-0}" -gt "$now" ] || exp="$(( now + 3300 ))"
  mkdir -p "$(dirname "$GH_APP_TOKEN_CACHE")"
  ( umask 077; printf '%s %s\n' "$exp" "$tok" > "$GH_APP_TOKEN_CACHE.new" )
  mv "$GH_APP_TOKEN_CACHE.new" "$GH_APP_TOKEN_CACHE"
  printf '%s' "$tok"
}

# gh_app_export_token -> exports GH_TOKEN + git auth for every child process, or returns 1.
# The caller MUST treat 1 as fatal for the tick.
gh_app_export_token() {
  local tok login
  tok="$(gh_app_token)" || return 1
  export GH_TOKEN="$tok"
  # git over https uses the same token through an extra header; no credential helper, no
  # stored login is ever consulted (GH_CONFIG_DIR/GIT_CONFIG_GLOBAL are empty by design).
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0="http.https://github.com/.extraheader"
  export GIT_CONFIG_VALUE_0="AUTHORIZATION: bearer $tok"
  export GH_APP_IDENTITY_ACTIVE=1
  login="$(_gh_app_bot_login)" && export GH_APP_BOT_LOGIN="$login"
  return 0
}

# gh_identity_is_installation -> 0 when `gh api user` is NOT a human login (installation tokens
# get 403 on /user). Used by MODE=probe and by every tick before any write.
gh_identity_is_installation() {
  local login
  login="$(gh api user --jq .login 2>/dev/null || true)"
  [ -z "$login" ]
}
