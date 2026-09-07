# Autonomous agent runner

CueSync AR is developed by an unattended Claude Code loop (adapted from the author's existing
issue-driven agent runner) plus a human owner who merges everything public-facing. This page is
the operator's reference; the design rationale lives in the plan of record kept outside the repo.

Every guarantee on this page names the code that implements it. Where a control is only partly
implemented, it is listed under **Residual risks**, not claimed.

## How work flows

```
owner files an issue (template) and labels it  agent:ready
        │
runner tick (systemd user timer, every 5 min; at most ONE Claude run; outside BUSY_HOURS,
        │  default 09-18 Mon-Fri in BUSY_TZ — i.e. nights and weekends)
        │  trust: issue author = OWNER · last labeler ∈ {owner, runner bot} · PR head in this repo
        ▼
MODE=start  → branch claude/issue-<N>-<slug> → tests → commit → [runner] never-touch check →
        │     public-lint → push → PR (agent:working)
        │
CI: ci-core (Linux tests, lint, gitleaks) · ci-app (Simulator build, macOS tests)
        │   red → MODE=fix (≤3)   ·   metric below bar → MODE=iterate (≤4, reads screenshots + metrics.json)
        ▼
MODE=selfreview (adversarial; the runner posts "Self-review checklist (head <sha7>)")
        │
owner-started review threads open → MODE=review (owner's words only)
        │
tier A diff → runner squash-merges          tier B diff → parked needs-human + a tracker task for the owner
```

Tier A = `Packages/*` except CueSyncCore, `App/Sources/**`, tests, CI-verified metrics files,
and images/thresholds the owner approved by sha256. Tier B = README, docs, workflows, runner
scripts, CueSyncCore, model files, images, `project.yml`, lint/secrets config, dependencies
(`Package.swift`, `Package@swift-*.swift`, `Package.resolved`), `.gitmodules`, anything the owner
runs on his own machine (`Scripts/*.sh`, `Tools/**`). The runner may never author `.github/**`,
`.claude/**`, `.mcp.json`, `.gitmodules`, `Scripts/agent-runner/**`, `Scripts/verify/**`, signing
keys, `.gitleaks.toml`, `App/Config/**`. Path matching is case-insensitive (`lib/policy.sh`), and
`.github/CODEOWNERS` lists the same tier-B set so GitHub enforces the owner's review.

## Trust shape (what the model can and cannot do)

| Control | Where | What it guarantees |
|---|---|---|
| Two tokens per tick | `lib/gh_app_token.sh` `gh_app_token write\|read` | The write token exists only in `tick.sh`'s process. The model's environment gets a separately minted installation token with `contents/pull_requests/issues/actions/metadata: read`; a token that comes back with any write grant is refused. |
| Environment built from nothing | `tick.sh` `_child_env`, `claude_exec` | `claude` is started with `env -i` and an explicit list: PATH, a dedicated empty HOME, `CLAUDE_CONFIG_DIR`, the read token, the bot git identity, the Claude credential. No `secrets.env` values, App id, key path or tracker token reach it. |
| Separate uid | `tick.sh` `run_as_ok`, `install.sh` `check_run_as`/`lockdown` | With `AGENT_RUN_AS` set, `claude` runs via `sudo -n -u <user>` in the runner's group; `secrets/`, `secrets.env`, `state/` (token caches), `gh-config/`, `logs/` are 0700/0600 to the runner uid. `tick.sh` refuses to dispatch when `AGENT_RUN_AS` is empty unless `ALLOW_SAME_UID=1`. `install.sh` and `tick.sh probe` verify the model uid cannot read those paths. |
| The model never publishes | `tick.sh` `post_outbox`, `finish_run`, RUNBOOK "Hand-off files" | Pushes, PR creation, comments, labels, thread resolution and merges happen only in `tick.sh`, each after public-lint. The model writes `.agent-outbox/*` (git-ignored); a lint hit posts nothing and parks the item. |
| Only owner text becomes work | `lib/ci.sh` `owner_unresolved_threads`, `owner_thread_bodies`; `tick.sh` §2 | `MODE=review` fires only for unresolved threads whose first comment is by the owner, hands the model those ids and the owner's comment bodies in `.agent-inbox/review-threads.md`; thread resolution is honoured only for dispatched ids. `MODE=revise` hands the owner's verified reply as `.agent-inbox/owner-answer.md`. Strangers' comments neither trigger work nor block merges (`required_review_thread_resolution` is off). |
| Paths from git, unbounded | `lib/policy.sh` `changed_paths`; `tick.sh` §3 and `lint_and_push` | `git diff --name-only --no-renames origin/main...<head>` — every file, renames as delete+add — feeds both the never-touch refusal and the tier decision, before every push and every merge. The PR API (100-file cap, rename-blind) is not used for paths. |
| No host name in commits | `lib/gh_app_token.sh` `gh_app_export_token`; `lib/public-lint.sh` | Author/committer are `<app>[bot]` / `<id>+<app>[bot]@users.noreply.github.com` in the runner and the child; public-lint scans `%an <%ae>` / `%cn <%ce>` of every commit in the range. |
| GitHub enforces tier B | `rulesets/main-integrity.json`, `.github/CODEOWNERS`, `tick.sh` `rulesets_live` | Code-owner review required with zero approvals otherwise, squash only, linear history, required checks. The only bypass actor is the **repository-admin role in `pull_request` mode** — the owner merging his own tier-B PRs, which nobody else could approve. `rulesets_live` (checked before starting work AND before every merge) refuses any other bypass actor and requires `require_code_owner_review`. |
| Deny rules (defence in depth only) | `claude-settings.example.json` | `git push`, `gh` write verbs, `curl`/`wget`/`ssh`, `sudo`, `env`/`printenv`/`declare -p`, edits under never-touch paths. These are advisory: the credential and uid split above are the actual controls. |

## Labels (the state machine)

| Family | Labels |
|---|---|
| Flow | `agent:ready` → `agent:working` → `agent:revise` / `agent:blocked` / `needs-human` |
| Priority | `priority:high` `priority:medium` `priority:low` |
| Verification (≥ 1 required) | `verify:unit` `verify:synthetic` `verify:replay` `verify:snapshot` `verify:sim-smoke` `verify:device` |
| Risk (owner merges) | `risk:contract` `risk:model` `risk:workflow` `risk:docs-claims` `risk:dependency` |
| Device | `needs-device-run` `needs-table-session` |

An issue without `agent:ready` does not exist to the runner. `verify:device` alone is not
agent-completable.

## Decision Comments

When a run needs the owner it writes one comment headed **Human decision needed** with lettered
options (recommended first, one evidence line, the cost in minutes or dollars) to
`.agent-outbox/issue-comment.md`; the runner lints it, posts it, parks the item `needs-human`
and mirrors it into the owner's tracker. The owner replies `ok`, `1A 2B`, or `decision: …`; the
next tick verifies the reply is the owner's, writes it to `.agent-inbox/owner-answer.md` and
routes `MODE=revise`. A reply containing "hold", "not yet" or a trailing question keeps the item
parked.

## Runner layout on the host

```
$AGENT_BASE/  (outside any home directory and any git work tree; 0750, group = runner's group)
  tick.sh RUNBOOK.md status.sh install.sh seed-issues.sh lib/ rulesets/ tests/
  config.env            committed defaults          runner.env (0600)  untracked: AGENT_RUN_AS, busy hours, tz
  secrets.env (0600)    App id/installation/key path, tracker token+ids   — runner uid only
  secrets/ (0700)       github-app.pem                                    — runner uid only
  state/ (0700)         token caches, ledgers                             — runner uid only
  public-denylist (0600) owner's name / device / tailnet patterns; public-lint FAILS CLOSED without it
  claude-config/ (1770, sticky) dedicated CLAUDE_CONFIG_DIR: settings.json (runner-owned 0644: the model can neither edit nor replace it), model session state
  claude-home/          the model's empty HOME (group-writable)
  gh-config/ gitconfig  empty on purpose — the App token is the only credential
  repo/ (shared, group) work/<branch>/ (group-writable) artifacts/<pr>/<sha7>/ build-cache/ logs/ PAUSED
```

Identity: a GitHub App (Contents/Issues/PRs read-write, Actions read-write, Checks/Metadata read,
no Workflows permission). Two tokens are minted per tick (write for `tick.sh`, read-only for the
model); the tick aborts if either mint fails; there is no fallback credential. The App can merge
tier-A PRs but cannot approve its own.

Budget and safety: `MAX_AGENTS=1`; `MAX_RUNS_PER_DAY`, `MAX_MINUTES_PER_WEEK` (charged at the
40-minute ceiling per run; only an overrun is added afterwards), `MAX_PRS_PER_DAY`,
`MAX_OPEN_AGENT_PRS`; busy-hours window; per-PR ledgers (`fix` 3, `iterate` 4, `selfreview` 2);
stale-claim reaper (120 min, 3 requeues); usage-limit auto-pause (2 h); a pre-dispatch capacity
probe; `timeout -k 60s 40m` around every run; Docker test containers are named, capped and
removed by the reaper. Plateau rule: three PRs on one metric without ≥ 5 % movement park the
work with a Decision Comment.

## Operating

```bash
# one-time on the host, as root: the model uid, in the runner's group, with one sudo rule
useradd -r -M -s /usr/sbin/nologin -G <runner-group> cuesync-model
printf '%s ALL=(cuesync-model) NOPASSWD: /usr/bin/env\n' <runner-user> > /etc/sudoers.d/cuesync-agent; chmod 0440 /etc/sudoers.d/cuesync-agent
install -d -o <runner-user> -g <runner-group> -m 0750 /opt/cuesync-agent
# `claude` must be on PATH for cuesync-model (system-wide install, not under the runner's HOME)

# install / update (as the runner user)
Scripts/agent-runner/install.sh            # first time: PAUSED; sets permissions, prints what it cannot verify
Scripts/agent-runner/install.sh --sync     # later: refuses host-edited files

# fill runner.env (AGENT_RUN_AS=cuesync-model, BUSY_TZ), secrets.env, secrets/github-app.pem, public-denylist
gh api -X POST repos/<owner>/<repo>/rulesets --input $AGENT_BASE/rulesets/main-integrity.json   # once
$AGENT_BASE/tests/public-lint-test.sh      # lint self-test (also runs on any dev machine)
DRY_RUN=1 $AGENT_BASE/tick.sh              # full pass, no Claude, no writes
$AGENT_BASE/tick.sh probe                  # identity, read-only token, uid split, deny rules, rulesets, docker test
rm $AGENT_BASE/PAUSED                      # go live (refused by the tick until rulesets are active)
$AGENT_BASE/status.sh
```

The ruleset requires the five checks that exist today (`Swift package tests (Linux)`, `SwiftLint`,
`gitleaks`, `Build iOS app (Simulator)`, `Swift package tests (macOS)`). `Coverage gate`,
`Replay golden (Linux)` and `Replay smoke (Simulator)` do not exist yet; the PR that adds those
workflows must add them to `rulesets/main-integrity.json` in the same change — adding a check
that does not exist locks `main` for everyone, admins included.

STOP NOW (any shell as the runner user):

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
touch $AGENT_BASE/PAUSED; systemctl --user stop cuesync-tick.timer cuesync-tick.service cuesync-watch.timer
sudo -n -u cuesync-model /usr/bin/env pkill -f 'claude -p'; docker rm -f $(docker ps -q -f name=cuesync-swift) 2>/dev/null
```

On restart the reaper returns any `agent:working` issue to `agent:ready`.

## Public-lint

Before any push, PR body, comment or issue, `lib/public-lint.sh` scans the added lines of the
whole `main..HEAD` diff (`--text`, so binary-looking content is not skipped), every commit
message, every author and committer header, and new binary blobs for: tailnet names (any case),
Tailscale IPv4/IPv6, RFC1918 ranges including 172.16/12, mDNS `.local` hosts, the debug-mirror
port, UUIDs (any case) and ECIDs, GitHub `gh[opsur]_`/PAT tokens, Anthropic keys, tracker
`pk_` tokens, JWTs, home directories, scratchpad paths, e-mail addresses (all domains except the
noreply forms), first-person singular prose, and unapproved images. Host and name patterns live
only in `$AGENT_BASE/public-denylist`; **a missing or empty denylist refuses every lint**, hence
every push and post. `tests/public-lint-test.sh` pins each pattern with a positive and a negative.

## Residual risks (read before trusting the loop unattended)

- **The model necessarily holds its own Claude credential** (`CLAUDE_CODE_OAUTH_TOKEN` /
  `ANTHROPIC_API_KEY`, passed through from `claude-token.env`). Nothing in this design can hide a
  process's own API key from it. Limit the blast radius with a dedicated account or key.
- **uid separation depends on host configuration that a shell script cannot prove.** `install.sh`
  and `probe` verify the sudo rule works, the model uid cannot read the secret paths, and the
  model uid is not in `docker`. They cannot verify there is no other path to root (setuid
  binaries, a permissive sudoers, a world-readable backup of the key). If `AGENT_RUN_AS` is left
  empty and `ALLOW_SAME_UID=1` is set, the model runs as the runner uid and **can read the App
  private key**, which mints write tokens for the App's lifetime; `probe` reports FAIL for this.
- **Docker is root-equivalent.** `Scripts/verify/swift-test.sh` falls back to `docker run` when
  there is no native Swift. A model uid in the `docker` group can bind-mount `/` and read
  everything, voiding the uid split. Use rootless Docker for the model uid, or install a native
  Swift toolchain; `probe` fails when the model uid is in `docker`.
- **The read-only token can still read** the public repository, Actions logs and artifacts — all
  public already — and can be exfiltrated for its ~1 h life; it cannot write anywhere.
- **Deny rules in `claude-settings.example.json` are advisory.** They stop the obvious commands
  (`git push`, `gh api -X`, `curl`); they do not stop Python or Perl sockets. Exfiltration of
  anything the model can read is therefore possible; the design limits what it can read, not
  what it can send.
- **Public-lint is pattern-based.** First-person detection covers the singular forms only ("I",
  "my") and can false-positive on things like "Phase I."; a false positive parks the item, a
  false negative ships. The owner's own name, devices and venues are caught only if they are in
  `public-denylist`.
- **The admin bypass in `main-integrity` is real.** It lets a repository admin merge a PR that
  lacks the code-owner review. The App is not an admin, so the runner cannot use it; anyone who
  obtains the owner's GitHub session can. That is the pre-existing trust in the owner's account.
- **A tier-A merge trusts CI plus the model's own self-review.** No human reads tier-A code
  before it lands on `main`. `Packages/CueSyncCore` and everything the owner runs locally are
  tier B precisely so that this trust stays inside test-covered library code.
- **Owner-started threads are trusted by first-comment author only.** A stranger replying inside
  an owner thread is dropped from the inbox (`owner_thread_bodies` keeps owner comments only),
  but the owner's own later replies in a stranger-started thread are ignored too — start a new
  thread to be heard.
- **Approved-by-sha256 images are tier A to the runner but still tier B to GitHub** (`*.png`,
  `*.jpg` in CODEOWNERS), so such a PR waits for the owner's click. This is deliberate.
- **Anything this document says was not verified on the host** until `tick.sh probe` passes
  there; the self-tests that can run without the host are `bash -n`, JSON parsing and
  `tests/public-lint-test.sh`.
