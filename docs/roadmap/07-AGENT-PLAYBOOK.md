# 07 — Agent Playbook (parallel Claude development)

How any Claude instance — including several running concurrently — works on
this repo without stepping on humans or each other.

## Onboarding (every session, ~2 minutes)

1. Read `CLAUDE.md`, then `docs/roadmap/00-OVERVIEW.md` and this file.
2. Read [06-MILESTONES.md](06-MILESTONES.md); find the lowest-numbered open
   milestone; pick a task whose dependencies are all `[x]`.
3. Read the module spec in [03-MODULES.md](03-MODULES.md) for the package you
   will touch, and the relevant contract section of
   [02-ARCHITECTURE.md](02-ARCHITECTURE.md).

## Rule 1 — Claim before you code

Claim a task by a **tiny, immediate PR-less commit to `main`'s task board is
not possible for agents**, so claims are branch-based: create and push branch
`claude/<task-id>-<slug>` (e.g. `claude/M1-02-physics-solver`). A pushed
branch matching a task ID **is** the claim. Before starting, fetch and check
`git ls-remote --heads origin 'claude/<task-id>-*'` — if a claim branch exists
and has commits newer than ~24 h, pick another task. Stale claims (> 24 h idle)
may be taken over; note the takeover in the PR description. In your PR, tick
the task checkbox in `06-MILESTONES.md` from `[ ]`/`[~]` to `[x]` so the merge
that completes the work also updates the board atomically.

## Rule 2 — One task, one branch, one PR

- Scope: exactly the task's deliverable + its tests + its board tick. No
  drive-by refactors outside the task's package (file an issue/backlog note
  instead).
- Commit style: imperative, descriptive; reference the task ID
  (`M1-02: implement cushion reflection with restitution`).
- PR description: what, how verified (paste test summary), any contract
  ambiguities you resolved and how.

## Rule 3 — The build must stay green

Run before pushing: `Scripts/format.sh`, then `swift test` in every package
you touched, then (if the app target changed) the simulator build. Never merge
on red CI. Never weaken a test to make it pass — fix the code or escalate.

## Rule 4 — Contracts are frozen; changing one is its own task

The protocols and domain types in `CueSyncCore` are the coordination surface
for all parallel work. If your task seems to require changing them:

1. Stop feature work.
2. Open a dedicated contract-change PR touching **only** `CueSyncCore` (+ the
   minimal ripple), explaining the need, tagged `contract-change`.
3. Wait for it to merge before resuming. Other agents rebase on it.

This is the single most important rule for parallel safety.

## Rule 5 — Mock-first across module seams

Never block on a sibling module's unfinished implementation. Depend on the
protocol and use `CueSyncTestSupport` fixtures/mocks (`FixtureDetectionProvider`,
`FixtureRaycaster`, `MockCoach`, golden `TableState`s). If the mock you need
doesn't exist, adding it to `CueSyncTestSupport` is in-scope for your task.

## Rule 6 — Know what you cannot verify

Agents (and CI) cannot run ARKit, the camera, or a real table. If your task
has physical-world acceptance criteria:

- Implement + test everything sim-safe (unit, fixture, snapshot layers).
- In the PR, add a **Device verification needed** section listing the exact
  `docs/device-checklist.md` rows to run.
- Mark the milestone board entry `[x] (needs-device-run)`. The maintainer runs
  the checklist and commits the filled-in copy; only then is the milestone
  gate satisfied.

Never claim device behavior works ("tracking is smooth") without a committed
device-checklist result to cite.

## Rule 7 — Secrets and external services

- Never commit keys, tokens, or venue photos with identifiable people.
- Anything needing a paid/external service (Roboflow cloud, Claude API) must
  degrade gracefully to a no-key state and is tested with stubs; live-service
  tests are env-gated (`CUESYNC_LIVE_TESTS=1`) and excluded from required CI.

## Rule 8 — When blocked, leave the campsite clean

If you cannot finish: push what compiles with tests green (or stash the broken
part behind a clearly-named draft commit on your claim branch), and write a
`HANDOFF.md` at the branch root: state, what remains, gotchas discovered. The
next agent starts there.

## Escalate to the human maintainer (don't guess) when…

- A contract change would alter MVP scope or UX flow.
- The physics golden fixtures need regeneration (outputs changed).
- Anything touching signing, provisioning, App Store, or key rotation.
- Two claim branches conflict on the same task with recent activity.

## Quick reference

| Thing | Where |
|---|---|
| Task board | `docs/roadmap/06-MILESTONES.md` |
| Contracts | `Packages/CueSyncCore` + `docs/roadmap/02-ARCHITECTURE.md` |
| Module spec + test bar | `docs/roadmap/03-MODULES.md` |
| Test layers & gates | `docs/roadmap/04-TESTING-STRATEGY.md` |
| Design rules | `docs/roadmap/05-UX-DESIGN.md` |
| Branch naming | `claude/<task-id>-<slug>` |
| Format/lint | `Scripts/format.sh` before every push |
