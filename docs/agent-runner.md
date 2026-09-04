# Autonomous agent runner

CueSync AR is developed by an unattended Claude Code loop (adapted from the author's existing
issue-driven agent runner) plus a human owner who merges everything public-facing. This page is
the operator's reference; the design rationale lives in the plan of record kept outside the repo.

## How work flows

```
owner files an issue (template) and labels it  agent:ready
        │
runner tick (systemd user timer, every 5 min; at most ONE Claude run, nights/weekends)
        │  trust: issue author = OWNER · last labeler ∈ {owner, runner bot} · PR head in this repo
        ▼
MODE=start  → branch claude/issue-<N>-<slug> → tests → commit → public-lint → push → PR (agent:working)
        │
CI: ci-core (Linux tests, lint, gitleaks, Coverage gate, Replay golden) · ci-app · verify-sim
        │   red → MODE=fix (≤3)   ·   metric below bar → MODE=iterate (≤4, reads screenshots + metrics.json)
        ▼
MODE=selfreview (adversarial, posts "Self-review checklist (head <sha7>)")
        │
tier A diff → runner squash-merges          tier B diff → parked needs-human + a tracker task for the owner
```

Tier A = `Packages/*` except CueSyncCore, `App/Sources/**`, tests, `Tools/**`, CI-verified metrics
files, and images/thresholds the owner approved by sha256. Tier B = README, docs, workflows,
runner scripts, CueSyncCore, model files, `project.yml`, lint/secrets config, dependencies, any
unapproved image. The runner may never author `.github/**`, `.claude/**`, `.mcp.json`,
`Scripts/agent-runner/**`, `Scripts/verify/**`, signing keys, `.gitleaks.toml`, `App/Config/**`.

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

When a run needs the owner it posts one comment headed **Human decision needed** with lettered
options (recommended first, one evidence line, the cost in minutes or dollars) and mirrors it
into the owner's tracker. The owner replies `ok`, `1A 2B`, or `decision: …`; the next tick routes
`MODE=revise`. A reply containing "hold", "not yet" or a trailing question keeps the item parked.

## Runner layout on the host

```
$AGENT_BASE/  (outside any home directory and any git work tree)
  tick.sh RUNBOOK.md status.sh install.sh seed-issues.sh lib/ rulesets/
  config.env            committed defaults          runner.env   untracked: busy hours, tz, poll cadence
  secrets.env (0600)    App id/installation/key path, tracker token+ids
  claude-config/        dedicated CLAUDE_CONFIG_DIR: deny rules only, no rules/, no host hooks
  gh-config/ gitconfig  empty on purpose — the App token is the only credential
  repo/  work/<branch>/ state/ locks/ logs/ artifacts/<pr>/<sha7>/ build-cache/  PAUSED
```

Identity: a GitHub App (Contents/Issues/PRs read-write, Actions read-write, Checks/Metadata read,
no Workflows permission). Tokens are minted per tick and the tick aborts if minting fails; there
is no fallback credential. The App can merge tier-A PRs but cannot approve its own.

Budget and safety: `MAX_AGENTS=1`; `MAX_RUNS_PER_DAY`, `MAX_MINUTES_PER_WEEK`, `MAX_PRS_PER_DAY`,
`MAX_OPEN_AGENT_PRS`; busy-hours window; per-PR ledgers (`fix` 3, `iterate` 4, `selfreview` 2);
stale-claim reaper (120 min, 3 requeues); usage-limit auto-pause (2 h); a pre-dispatch capacity
probe; `timeout -k 60s 40m` around every run; Docker test containers are named, capped and
removed by the reaper. Plateau rule: three PRs on one metric without ≥ 5 % movement park the
work with a Decision Comment.

## Operating

```bash
# install / update (as the runner user; $AGENT_BASE pre-created by root, e.g. /opt/cuesync-agent)
Scripts/agent-runner/install.sh            # first time: PAUSED
Scripts/agent-runner/install.sh --sync     # later: refuses host-edited files

DRY_RUN=1 $AGENT_BASE/tick.sh              # full pass, no Claude, no writes
$AGENT_BASE/tick.sh probe                  # identity, loaded hooks, deny rules, rulesets, docker test
rm $AGENT_BASE/PAUSED                      # go live (refused by the tick until rulesets are active)
$AGENT_BASE/status.sh
```

STOP NOW (any shell as the runner user):

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
touch $AGENT_BASE/PAUSED; systemctl --user stop cuesync-tick.timer cuesync-tick.service cuesync-watch.timer
pkill -u "$(id -un)" -f 'claude -p'; docker rm -f $(docker ps -q -f name=cuesync-swift) 2>/dev/null
```

On restart the reaper returns any `agent:working` issue to `agent:ready`.

## Public-lint

Before any push, PR body, comment or issue, `lib/public-lint.sh` scans the whole `main..HEAD`
range (diffs and messages, never author headers) and binary blobs for tailnet/LAN addresses,
device identifiers, token shapes, e-mail addresses, absolute home paths, and unapproved images.
Host and name patterns live only in an untracked file on the host. A hit aborts the push and
parks the item.
