#!/usr/bin/env bash
# Self-test for lib/public-lint.sh: every generic pattern must fire on a realistic positive and
# stay quiet on a realistic negative; the denylist must fail closed. Runs anywhere with perl+git:
#   Scripts/agent-runner/tests/public-lint-test.sh
# Exit 0 = all pass. Installed to $AGENT_BASE/tests/ so the operator can re-run it on the host.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export AGENT_BASE="$TMP/base"; mkdir -p "$AGENT_BASE"
log() { :; }
# shellcheck disable=SC1091
. "$HERE/lib/policy.sh"
# shellcheck disable=SC1091
. "$HERE/lib/public-lint.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); printf 'FAIL: %s\n' "$*"; }
must_hit()  { if printf '%s\n' "$2" | public_lint_text - >/dev/null 2>&1; then bad "no hit  [$1]: $2"; else ok; fi; }
must_pass() { if printf '%s\n' "$2" | public_lint_text - >/dev/null 2>&1; then ok; else bad "false hit [$1]: $2"; fi; }

# ---- fail closed without a denylist --------------------------------------------------------------
printf 'nothing private here\n' | public_lint_text - >/dev/null 2>&1 && bad "lint proceeded with NO denylist" || ok
printf '# only a comment\n\n' > "$AGENT_BASE/public-denylist"
printf 'nothing private here\n' | public_lint_text - >/dev/null 2>&1 && bad "lint proceeded with an EMPTY denylist" || ok
printf '# owner patterns\n(?i)\\bexampleowner\\b\nmyipad\n' > "$AGENT_BASE/public-denylist"
must_hit  denylist  "tested by ExampleOwner at the table"
must_hit  denylist  "seen on myipad"
must_pass baseline  "Add ball tracker hysteresis test"

# ---- hosts and addresses --------------------------------------------------------------------------
must_hit  ts.net    "mirror at ipad-9.tail1234.ts.net"
must_hit  ts.net-uc "reachable via IPAD.TAIL1234.TS.NET"
must_pass ts.net    "packets over the ts protocol .net assembly"
must_hit  cgnat     "device at 100.101.102.103"
must_pass cgnat     "score 100.5 vs 100.4 baseline"
must_hit  lan192    "http://192.168.50.12/state.json"
must_hit  lan10     "vpn peer 10.8.0.2"
must_hit  lan172    "docker bridge 172.17.0.3 and 172.31.255.1"
must_pass lan172    "172.32.0.1 is public space; 172.15.1.1 too"
must_hit  ts6       "tailnet v6 fd7a:115c:a1e0:ab12:4843:cd96:6250:1"
must_hit  mdns      "open http://ipad-of-someone.local:8787"
must_hit  mdns      "ping livingroom-ipad.local"
must_pass mdns      "edit .claude/settings.local.json and local.swift"
must_pass mdns      "the localhost fallback"
must_hit  mirror    "served at http://ipad:8787"
must_pass mirror    "served at http://localhost:8787 and http://127.0.0.1:8787"

# ---- identifiers ----------------------------------------------------------------------------------
must_hit  uuid-uc   "udid 1A2B3C4D-5E6F-7A8B-9C0D-1E2F3A4B5C6D"
must_hit  uuid-lc   "udid 1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"
must_pass uuid      "sha 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b"
must_hit  ecid      "device 00008030-001A2B3C4D5E6F78"

# ---- tokens ---------------------------------------------------------------------------------------
must_hit  ghs       "ghs_$(printf 'a%.0s' {1..40})"
must_hit  gho       "gho_$(printf 'b%.0s' {1..40})"
must_hit  ghu       "ghu_$(printf 'c%.0s' {1..40})"
must_hit  ghr       "ghr_$(printf 'd%.0s' {1..40})"
must_hit  ghp       "ghp_$(printf 'e%.0s' {1..40})"
must_pass gh-short  "ghs_short and ghx_$(printf 'f%.0s' {1..40})"
must_hit  pat       "github_pat_11ABCDEFG0123456789_abcdefghij"
must_hit  anthropic "sk-ant-api03-abcdefghijklmnop"
must_hit  clickup   "pk_12345678_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"
must_pass clickup   "pk_12345678_short and pk_x_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"
# Assembled at runtime, never stored as a literal: a whole JWT sitting in the
# tree trips the repo's own gitleaks scan (rule `jwt`) on every push, and
# allowlisting the path would blunt the scanner for real tokens.
jwt_h="$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '=\n' | tr '/+' '_-')"
jwt_p="$(printf '%s' '{"iat":1700000000}' | base64 | tr -d '=\n' | tr '/+' '_-')"
jwt_s="$(printf 'S%.0s' {1..43})"
must_hit  jwt       "Bearer ${jwt_h}.${jwt_p}.${jwt_s}"
must_pass jwt       "eyJ alone is not a token; neither is eyJab.cd.ef"

# ---- paths ----------------------------------------------------------------------------------------
must_hit  home      "see /home/runner-user/notes.txt"
must_hit  users     "see /Users/someone/Library/Logs"
must_pass users     "github.com/Users/ is a path segment inside a URL, not a home"
must_hit  scratch   "wrote /private/tmp/claude-501/-Users-someone-workspace-Repo/8db9/scratchpad/x"
must_hit  scratch2  "path claude-501/-Users-someone-workspace"
must_pass scratch   "the claude-3 model family"

# ---- e-mail ---------------------------------------------------------------------------------------
must_hit  gmail     "mail someone@gmail.com"
must_hit  email     "mail someone@example-corp.io"
must_hit  email-sub "mail first.last+tag@mail.some-company.co.uk"
must_pass noreply   "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
must_pass noreply   "12345+cuesync-agent[bot]@users.noreply.github.com"
must_pass gitssh    "git@github.com:owner/repo.git"
must_pass example   "user@example.com is the placeholder"
must_pass decorator "@main struct App {} and @Observable class Model {}"

# ---- first person ---------------------------------------------------------------------------------
must_hit  fp-I      "I fixed the tracker and I'm confident"
must_hit  fp-my     "on my table the red ball"
must_hit  fp-Ive    "I've verified the fix"
must_pass fp-quote  "the spec (\"my table is this size\") is venue-independent"
must_pass fp-code   "let myValue = I.O.count; case .myCase: return I.self"
must_hit  fp-hunk   "+I have added the tracker"
must_pass fp-io     "I/O bound work and IEEE754"
must_pass fp-words  "Icon myths, mystery, myself.swift, imy"

# ---- author headers and added-lines-only (git range) --------------------------------------------
R="$TMP/repo"; git init -q "$R"; cd "$R" || exit 1
git -c user.name=base -c user.email=base@example.com commit -q --allow-empty -m "base"
git branch -q -M main
git -c user.name=base -c user.email=base@example.com checkout -q -b feature
printf 'existing line with I in it\n' > f.txt
git add f.txt; git -c user.name=base -c user.email=base@example.com commit -q -m "add f"
git checkout -q main; git merge -q --ff-only feature 2>/dev/null || true
git checkout -q feature
printf 'existing line with I in it\nclean added line\n' > f.txt
git add f.txt
git -c user.name="cuesync-agent[bot]" -c user.email="1+cuesync-agent[bot]@users.noreply.github.com" commit -q -m "clean commit"
public_lint_range main HEAD >/dev/null 2>&1 && ok || bad "range: clean commit with clean author was refused"
git -c user.name="runner" -c user.email="runner@vps-01.tail1234.ts.net" commit -q --allow-empty -m "leaky author"
public_lint_range main HEAD >/dev/null 2>&1 && bad "range: tailnet AUTHOR header not caught" || ok
git reset -q --hard HEAD~1
git -c user.name="cuesync-agent[bot]" -c user.email="1+cuesync-agent[bot]@users.noreply.github.com" commit -q --allow-empty -m "message mentions 192.168.1.9"
public_lint_range main HEAD >/dev/null 2>&1 && bad "range: commit BODY not caught" || ok
git reset -q --hard HEAD~1
printf 'clean added line\n' > f.txt   # removes the pre-existing first-person line: must NOT fire
git add f.txt; git -c user.name="cuesync-agent[bot]" -c user.email="1+cuesync-agent[bot]@users.noreply.github.com" commit -q -m "remove line"
public_lint_range main HEAD >/dev/null 2>&1 && ok || bad "range: a REMOVED line was linted"
printf '\x00\x01binary-ish 192.168.7.7\n' > blob.bin
git add blob.bin; git -c user.name="cuesync-agent[bot]" -c user.email="1+cuesync-agent[bot]@users.noreply.github.com" commit -q -m "blob"
public_lint_range main HEAD >/dev/null 2>&1 && bad "range: binary-looking file skipped (--text missing)" || ok

# ---- policy: case-insensitive never-touch and tier B ---------------------------------------------
never_touch_path ".Claude/settings.local.json" && ok || bad "policy: .Claude not never-touch"
never_touch_path ".MCP.json" && ok || bad "policy: .MCP.json not never-touch"
never_touch_path "Packages/X/Sources/A.swift" && bad "policy: source file never-touch" || ok
[ "$(tier_for_paths Packages/X/Package@swift-6.1.swift)" = B ] && ok || bad "policy: Package@swift manifest not tier B"
[ "$(tier_for_paths Package.swift)" = B ] && ok || bad "policy: root Package.swift not tier B"
[ "$(tier_for_paths .gitmodules)" = B ] && ok || bad "policy: .gitmodules not tier B"
[ "$(tier_for_paths Scripts/bootstrap.sh)" = B ] && ok || bad "policy: Scripts/*.sh not tier B"
[ "$(tier_for_paths Tools/DetectionEval/eval.py)" = B ] && ok || bad "policy: Tools/ not tier B"
[ "$(tier_for_paths Packages/BilliardsPhysics/Sources/X.swift App/Sources/Y.swift)" = A ] && ok || bad "policy: tier A misread"
# rename-blind paths: a rename of a never-touch file must show its old path
git -c user.name=b -c user.email=b@example.com mv f.txt moved.txt 2>/dev/null; git -c user.name=b -c user.email=b@example.com commit -q -m mv
changed_paths main HEAD | grep -qx f.txt && ok || bad "changed_paths hides the old side of a rename"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
