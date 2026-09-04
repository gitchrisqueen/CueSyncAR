#!/usr/bin/env bash
# Installer / updater for the CueSync AR agent runner. Run as the runner user on the agent host.
#   ./install.sh            first install into $AGENT_BASE (PAUSED), render systemd units, pre-pull
#   ./install.sh --sync     update an existing install; refuses files edited on the host
#   ./install.sh --sync --force   overwrite host-edited files after reading the diff
# Refuses to install under $HOME or inside any git work tree: the runner must not inherit a home
# directory's Claude configuration or sit inside another repository.
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

FIRST=1; [ -f "$DEST/tick.sh" ] && FIRST=0
[ "$SYNC" = 1 ] && [ "$FIRST" = 1 ] && { echo "--sync requested but nothing installed yet" >&2; exit 2; }
mkdir -p "$DEST"/{logs,work,lib,rulesets,state,locks,artifacts,gh-config,build-cache,claude-config}
chmod 0700 "$DEST/gh-config" "$DEST/claude-config"

if [ "$SYNC" = 1 ]; then
  updated=0; skipped=(); same=0
  while IFS= read -r rel; do
    if [ ! -f "$DEST/$rel" ]; then place "$rel"; updated=$((updated+1)); continue; fi
    if [ "$(sha "$SRC/$rel")" = "$(sha "$DEST/$rel")" ]; then same=$((same+1)); continue; fi
    if [ "$FORCE" != 1 ] && [ "$(sha "$DEST/$rel")" != "$(manifest_sha "$rel")" ]; then skipped+=("$rel"); continue; fi
    place "$rel"; updated=$((updated+1))
  done < <(files)
  write_manifest ${skipped[@]+"${skipped[@]}"}
  echo "sync: $updated updated, $same current, ${#skipped[@]} refused."
  for rel in ${skipped[@]+"${skipped[@]}"}; do echo "  REFUSED (host-edited): diff $DEST/$rel $SRC/$rel"; done
  [ "${#skipped[@]}" -eq 0 ] || exit 1
  exit 0
fi

while IFS= read -r rel; do place "$rel"; done < <(files)
write_manifest
[ -f "$DEST/config.env" ]  || cp "$SRC/config.env.example"  "$DEST/config.env"
[ -f "$DEST/runner.env" ]  || { cp "$SRC/runner.env.example" "$DEST/runner.env"; chmod 0600 "$DEST/runner.env"; }
[ -f "$DEST/mcp.json" ]    || cp "$SRC/mcp.json.example"     "$DEST/mcp.json"
[ -f "$DEST/claude-config/settings.json" ] || cp "$SRC/claude-settings.example.json" "$DEST/claude-config/settings.json"
touch "$DEST/gitconfig"
[ -d "$DEST/repo/.git" ] || { . "$DEST/config.env"; git clone -q "https://github.com/${SLUG}.git" "$DEST/repo"; }
[ "$FIRST" = 1 ] && touch "$DEST/PAUSED"

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

cat <<EOT
Installed to $DEST $([ "$FIRST" = 1 ] && echo '(PAUSED)' || echo '(PAUSED untouched)').
Next:
  1. Fill $DEST/secrets.env (0600) and $DEST/runner.env; put the App key at $DEST/secrets/github-app.pem.
  2. DRY_RUN=1 $DEST/tick.sh              # no Claude, no writes
  3. $DEST/tick.sh probe                  # identity, hooks, deny rules, rulesets, docker swift test
  4. systemctl --user start cuesync-tick.timer cuesync-watch.timer ; rm $DEST/PAUSED   # go live
  5. $DEST/status.sh
EOT
