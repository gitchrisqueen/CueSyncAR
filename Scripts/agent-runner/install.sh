#!/usr/bin/env bash
# Installer / updater for the CueSync AR agent runner. Run as the runner user on the agent host.
#   ./install.sh            first install into $AGENT_BASE (PAUSED), render systemd units, pre-pull
#   ./install.sh --sync     update an existing install; refuses files edited on the host
#   ./install.sh --sync --force   overwrite host-edited files after reading the diff
# Refuses to install under $HOME or inside any git work tree: the runner must not inherit a home
# directory's Claude configuration or sit inside another repository.
#
# Two uids: the RUNNER user (runs this script and tick.sh; owns secrets/, secrets.env, state/)
# and the MODEL user (AGENT_RUN_AS in runner.env; runs `claude`; must NOT be able to read those).
# This script sets the permissions that make that true and refuses to finish when it cannot
# verify them. What it cannot verify (sudoers, docker group) it prints; tick.sh probe re-checks.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="${AGENT_BASE:-/opt/cuesync-agent}"
MANIFEST="$DEST/.installed.sha256"
SYNC=0; FORCE=0
for a in "$@"; do case "$a" in --sync) SYNC=1 ;; --force) FORCE=1 ;; -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; *) echo "unknown option $a" >&2; exit 2 ;; esac; done

case "$DEST" in "$HOME"/*|"$HOME") echo "refusing: AGENT_BASE ($DEST) is under \$HOME" >&2; exit 2 ;; esac
if git -C "$DEST" rev-parse --show-toplevel >/dev/null 2>&1; then echo "refusing: AGENT_BASE ($DEST) is inside a git work tree" >&2; exit 2; fi
[ -d "$DEST" ] && [ -w "$DEST" ] || { echo "AGENT_BASE $DEST must exist and be writable (root: install -d -o \$(id -un) -g \$(id -gn) -m 0750 $DEST)" >&2; exit 2; }

files() {
  for f in tick.sh RUNBOOK.md status.sh seed-issues.sh; do [ -e "$SRC/$f" ] && echo "$f"; done
  for f in "$SRC"/lib/*.sh; do echo "lib/$(basename "$f")"; done
  for f in "$SRC"/rulesets/*.json; do echo "rulesets/$(basename "$f")"; done
  for f in "$SRC"/tests/*.sh; do [ -e "$f" ] && echo "tests/$(basename "$f")"; done
}
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
manifest_sha() { [ -f "$MANIFEST" ] && awk -v f="$1" '$2==f{print $1}' "$MANIFEST" || true; }
place() { local rel="$1" tmp; mkdir -p "$DEST/$(dirname "$rel")"; tmp="$DEST/$(dirname "$rel")/.$(basename "$rel").new"; cp "$SRC/$rel" "$tmp" && mv "$tmp" "$DEST/$rel"; case "$rel" in *.sh) chmod +x "$DEST/$rel" ;; esac; }
write_manifest() {
  local rel arg refused prev; : > "$MANIFEST.new"
  while IFS= read -r rel; do
    refused=0; for arg in "$@"; do [ "$arg" = "$rel" ] && refused=1; done
    if [ "$refused" = 1 ]; then prev="$(manifest_sha "$rel")"; [ -n "$prev" ] && printf '%s %s\n' "$prev" "$rel" >> "$MANIFEST.new"; continue; fi
    printf '%s %s\n' "$(sha "$DEST/$rel")" "$rel" >> "$MANIFEST.new"
  done < <(files); mv "$MANIFEST.new" "$MANIFEST"
}

# ---- permissions: what the model uid may and may not reach ------------------------------------
# Private to the runner uid (0700 / 0600): secrets/, secrets.env, state/ (token caches), gh-config/,
# logs/, runner.env, public-denylist. Group-readable (the model uid is in the runner's group):
# repo/, work/, build-cache/, claude-config/, claude-home/ (group-writable where the model writes).
lockdown() {
  local grp; grp="$(id -gn)"
  chmod 0750 "$DEST" 2>/dev/null || true
  mkdir -p "$DEST/secrets"; chmod 0700 "$DEST/secrets" "$DEST/state" "$DEST/gh-config" "$DEST/logs" "$DEST/locks"
  chmod -R g+rX "$DEST/artifacts" 2>/dev/null || true   # MODE=iterate reads CI artifacts from here
  for f in "$DEST/secrets.env" "$DEST/runner.env" "$DEST/public-denylist" "$DEST"/secrets/*; do [ -e "$f" ] && chmod 0600 "$f"; done
  # claude-config: the model must write its session state here, but must not be able to replace
  # settings.json (the deny rules): sticky bit + runner-owned 0644 file = create yes, delete/rename no.
  chmod 1770 "$DEST/claude-config"; chmod 0644 "$DEST/claude-config/settings.json" "$DEST/gitconfig" "$DEST/RUNBOOK.md" "$DEST/mcp.json" 2>/dev/null || true
  chgrp -R "$grp" "$DEST/repo" "$DEST/work" "$DEST/build-cache" "$DEST/claude-home" 2>/dev/null || true
  chmod -R g+rwX "$DEST/work" "$DEST/build-cache" "$DEST/claude-home" 2>/dev/null || true
  find "$DEST/work" "$DEST/build-cache" "$DEST/claude-home" -type d -exec chmod g+s {} + 2>/dev/null || true
  # The shared object store: commits made by the model uid land in repo/.git/objects.
  if [ -d "$DEST/repo/.git" ]; then
    git -C "$DEST/repo" config core.sharedRepository group
    chmod -R g+rwX "$DEST/repo/.git"; find "$DEST/repo/.git" -type d -exec chmod g+s {} + 2>/dev/null || true
    chmod -R g+rX "$DEST/repo"
  fi
}

# check_run_as — reads AGENT_RUN_AS from runner.env and verifies what a shell script can verify.
check_run_as() {
  local u; u="$(sed -n 's/^AGENT_RUN_AS="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$DEST/runner.env" 2>/dev/null | head -1)"
  if [ -z "$u" ]; then
    echo "WARNING: AGENT_RUN_AS is empty in $DEST/runner.env. tick.sh will refuse to dispatch the model until it is set"
    echo "         (or ALLOW_SAME_UID=1 is set on purpose, which lets the model read secrets/). See docs/agent-runner.md."
    return 0
  fi
  local rc=0
  id "$u" >/dev/null 2>&1 || { echo "ERROR: AGENT_RUN_AS user '$u' does not exist (root: useradd -r -M -s /usr/sbin/nologin -G $(id -gn) $u)"; return 1; }
  [ "$u" != "$(id -un)" ] || { echo "ERROR: AGENT_RUN_AS must differ from the runner user"; return 1; }
  id -nG "$u" | tr ' ' '\n' | grep -qx "$(id -gn)" || { echo "ERROR: '$u' is not in the runner's group '$(id -gn)' (root: usermod -aG $(id -gn) $u)"; rc=1; }
  if ! sudo -n -u "$u" -- /usr/bin/env true >/dev/null 2>&1; then
    echo "ERROR: 'sudo -n -u $u /usr/bin/env' is refused. Add to /etc/sudoers.d/cuesync-agent (root, mode 0440):"
    echo "         $(id -un) ALL=($u) NOPASSWD: /usr/bin/env"
    rc=1
  else
    for s in "$DEST/secrets" "$DEST/secrets.env" "$DEST/state" "$DEST/gh-config" "$DEST/logs"; do
      [ -e "$s" ] || continue
      sudo -n -u "$u" -- /usr/bin/env test -r "$s" 2>/dev/null && { echo "ERROR: '$u' can read $s"; rc=1; }
    done
    sudo -n -u "$u" -- /usr/bin/env test -w "$DEST/work" 2>/dev/null || { echo "ERROR: '$u' cannot write $DEST/work"; rc=1; }
    sudo -n -u "$u" -- /usr/bin/env sh -c 'command -v claude >/dev/null' 2>/dev/null || echo "WARNING: 'claude' is not on PATH for '$u' (install it system-wide, e.g. /usr/local/bin, not under the runner's HOME)."
  fi
  if id -nG "$u" | tr ' ' '\n' | grep -qx docker; then
    echo "WARNING: '$u' is in the docker group. That is root-equivalent (it can bind-mount / and read secrets/);"
    echo "         the uid separation is VOID until you use rootless Docker or native Swift for '$u'. probe reports FAIL."
  fi
  return $rc
}

FIRST=1; [ -f "$DEST/tick.sh" ] && FIRST=0
[ "$SYNC" = 1 ] && [ "$FIRST" = 1 ] && { echo "--sync requested but nothing installed yet" >&2; exit 2; }
mkdir -p "$DEST"/{logs,work,lib,rulesets,tests,state,locks,artifacts,gh-config,build-cache,claude-config,claude-home,claude-home/gh-config,secrets}

if [ "$SYNC" = 1 ]; then
  updated=0; skipped=(); same=0
  while IFS= read -r rel; do
    if [ ! -f "$DEST/$rel" ]; then place "$rel"; updated=$((updated+1)); continue; fi
    if [ "$(sha "$SRC/$rel")" = "$(sha "$DEST/$rel")" ]; then same=$((same+1)); continue; fi
    if [ "$FORCE" != 1 ] && [ "$(sha "$DEST/$rel")" != "$(manifest_sha "$rel")" ]; then skipped+=("$rel"); continue; fi
    place "$rel"; updated=$((updated+1))
  done < <(files)
  write_manifest ${skipped[@]+"${skipped[@]}"}
  # Files this version no longer ships.
  [ -e "$DEST/rulesets/main-review.json" ] && { rm -f "$DEST/rulesets/main-review.json"; echo "removed rulesets/main-review.json (folded into main-integrity; delete the GitHub ruleset of that name)"; }
  echo "sync: $updated updated, $same current, ${#skipped[@]} refused."
  for rel in ${skipped[@]+"${skipped[@]}"}; do echo "  REFUSED (host-edited): diff $DEST/$rel $SRC/$rel"; done
  lockdown; check_run_as || true
  [ "${#skipped[@]}" -eq 0 ] || exit 1
  exit 0
fi

while IFS= read -r rel; do place "$rel"; done < <(files)
write_manifest
[ -f "$DEST/config.env" ]  || cp "$SRC/config.env.example"  "$DEST/config.env"
[ -f "$DEST/runner.env" ]  || { cp "$SRC/runner.env.example" "$DEST/runner.env"; chmod 0600 "$DEST/runner.env"; }
[ -f "$DEST/secrets.env" ] || { cp "$SRC/secrets.env.example" "$DEST/secrets.env"; chmod 0600 "$DEST/secrets.env"; }
[ -f "$DEST/mcp.json" ]    || cp "$SRC/mcp.json.example"     "$DEST/mcp.json"
[ -f "$DEST/claude-config/settings.json" ] || cp "$SRC/claude-settings.example.json" "$DEST/claude-config/settings.json"
# public-lint FAILS CLOSED without this file: it must carry the owner's name and device names.
[ -f "$DEST/public-denylist" ] || { printf '# One Perl regex per line; lines starting with # are ignored.\n# public-lint refuses every push and post until at least one real pattern is here:\n# the owner'"'"'s name(s), device host names, tailnet name, venue names.\n' > "$DEST/public-denylist"; chmod 0600 "$DEST/public-denylist"; }
touch "$DEST/gitconfig"
[ -d "$DEST/repo/.git" ] || { . "$DEST/config.env"; git clone -q "https://github.com/${SLUG}.git" "$DEST/repo"; }
[ "$FIRST" = 1 ] && touch "$DEST/PAUSED"
lockdown

# systemd user units rendered from templates (nothing host-specific is committed).
UNITS="$HOME/.config/systemd/user"; mkdir -p "$UNITS"
for t in "$SRC"/systemd/*.tmpl; do
  u="$(basename "$t" .tmpl)"
  sed -e "s|@AGENT_BASE@|$DEST|g" -e "s|@PATH@|$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin|g" "$t" > "$UNITS/$u"
done
if systemctl --user daemon-reload 2>/dev/null; then
  systemctl --user enable cuesync-tick.timer cuesync-watch.timer >/dev/null 2>&1 || true
  if ! systemctl --user show ai-agents.slice -p MemoryMax 2>/dev/null | grep -qE 'MemoryMax=[0-9]'; then
    echo "note: ai-agents.slice has no user-scope memory limit; cuesync-tick.service carries its own MemoryMax/CPUQuota."
  fi
else
  echo "note: systemctl --user unavailable in this shell (set XDG_RUNTIME_DIR / DBUS_SESSION_BUS_ADDRESS); units written to $UNITS."
fi
command -v docker >/dev/null && docker image inspect swift:6.1 >/dev/null 2>&1 || docker pull -q swift:6.1 || echo "note: docker pull swift:6.1 failed; swift-test.sh will retry."
check_run_as || echo "FIX THE ERRORS ABOVE before removing PAUSED; tick.sh probe re-checks them."

cat <<EOT
Installed to $DEST $([ "$FIRST" = 1 ] && echo '(PAUSED)' || echo '(PAUSED untouched)').
Next:
  1. Fill $DEST/secrets.env (0600) and $DEST/runner.env (AGENT_RUN_AS, busy hours); put the App key
     at $DEST/secrets/github-app.pem (0600); put the owner's name / device / tailnet patterns in
     $DEST/public-denylist (0600) — public-lint refuses everything until it has at least one.
  2. Apply the ruleset once:  gh api -X POST repos/\$SLUG/rulesets --input $DEST/rulesets/main-integrity.json
  3. DRY_RUN=1 $DEST/tick.sh              # no Claude, no writes
  4. $DEST/tick.sh probe                  # identity, read-only token, uid split, deny rules, rulesets, docker swift test
  5. systemctl --user start cuesync-tick.timer cuesync-watch.timer ; rm $DEST/PAUSED   # go live
  6. $DEST/status.sh
EOT
