# Contributing to CueSync AR

All contribution process — for humans **and** AI agents — is defined by the
roadmap documents:

1. Start with [`docs/roadmap/00-OVERVIEW.md`](docs/roadmap/00-OVERVIEW.md).
2. Follow the workflow rules in
   [`docs/roadmap/07-AGENT-PLAYBOOK.md`](docs/roadmap/07-AGENT-PLAYBOOK.md)
   (task claiming, branch naming, frozen contracts, testing obligations).
3. Claim tasks from [`docs/roadmap/06-MILESTONES.md`](docs/roadmap/06-MILESTONES.md).

Quick local loop:

```sh
Scripts/bootstrap.sh   # macOS: generate CueSyncAR.xcodeproj (needs XcodeGen)
Scripts/test-all.sh    # macOS or Linux: run every package's tests
Scripts/format.sh      # fix lint before pushing
```

Never commit secrets; see `App/Config/Secrets.example.xcconfig`.
