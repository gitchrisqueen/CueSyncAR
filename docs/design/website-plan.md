# Public website — plan, evidence, and review

Draft of a one-page public site for CueSync AR, to be served from GitHub Pages.
**Nothing in this branch is live.** Pages is not enabled on the repository, and
the deploy workflow is not installed. See "What the owner must do" below.

Files:

| Path | What it is |
|---|---|
| `docs/site/index.html` | The page. No JS, no frameworks, no trackers, no cookies. |
| `docs/site/styles.css` | All styling. System font stack; no webfont. |
| `docs/site/cuesync-icon.svg` | Byte-copy of `Design/cuesync-icon.svg` (the app icon master). |
| `docs/design/pages.yml` | The deploy workflow, **staged, not installed** — see below. |

---

## Content decisions, and why

**Section order: what it is → how it works → where it stands → how it is built
→ build from source → repo and licence.**

The ordering rule was: *a visitor should hit the disappointing news before they
hit the impressive news.* A reader who arrives hoping to install a pool-coaching
app should learn it does not exist as an installable product within the first
screen, not after being sold on Core ML and ARKit. So the "in development, not
on the App Store, build it yourself" pill sits in the hero above the fold, the
candid status section comes *before* the tech section, and the tech section is
framed as "how it is built" (a description of the engineering) rather than
"features" (a description of what you get).

**"Where it actually stands" is three columns, not one list.** The distinction
that matters for an in-development project is not done/not-done — it is
*implemented* versus *verified at a real table*. Collapsing those into one list
is how honest projects accidentally overstate. So: what is wired into the app,
what a single July device session actually demonstrated, and what is neither.
The middle column carries the negative result (the detector could not see a ball
at shot speed) with the same weight as the positive ones, because the repository
does.

**Numbers appear only where a run produced them.** Three numbers survive onto
the page — 2 s relocalization, 86 % stick-aim duty cycle, mAP@50 0.896 — and
each is stated with its scope and its caveat. Every one of them is qualified in
place: the 2 s is paired with the 90–150 s first-run figure, and the mAP is
explicitly labelled a property of the model, not of the app's aiming accuracy.

**The privacy story is told with its exceptions attached.** "On-device, no
cloud, no account" is true of the default path and is the honest headline, but
the repository also contains a debug mirror that is **on by default** and serves
the screen *and any session recordings* over the LAN unauthenticated, plus an
optional hosted-detection adapter. Both are disclosed in a dedicated box inside
the tech section rather than buried, because a privacy claim with an undisclosed
open port behind it is worse than no privacy claim.

**Visual language is the app's, not a new brand.** Palette values are lifted
from `Packages/CueSyncUI/Sources/CueSyncUI/Theme.swift`, `BallStyle.swift` and
`TableSceneView.swift` (cloth green, cue amber, chalk blue, ball white) and are
cited in a comment at the top of `styles.css`. The hero mark is the shipping app
icon, unmodified.

## Deliberately left out

| Left out | Why |
|---|---|
| Screenshots and video of the app | Every candid image in the repository (`docs/validation/*.jpg`, session recordings) was shot in a room. Publishing them would publish the room. A staged, room-free capture is the right fix, and only the owner can take one. |
| Any accuracy claim for the overlay | Overlay positions are still centimetres off and the fixes are unconfirmed at a table. There is no number worth publishing yet. |
| A feature list of the product vision | The README's feature list describes intent. On a public page, intent phrased as capability reads as a claim. |
| "Coming soon", roadmap dates, ETAs | The repository commits to no dates. |
| Download / install / TestFlight call to action | None exists. |
| Testimonials, user counts, stars, "trusted by" | Nothing to cite. |
| Analytics, cookie banner, fonts from a CDN, any external asset | The page makes a privacy claim; it must be able to keep it. The page loads exactly three same-origin files and nothing else. |
| Contact details of any kind | GitHub issues is the only contact route, as in the README. No email address appears on the page. |
| Anything about how the project is developed internally | Out of scope for a public page. |

## What the owner must do to turn it on

Two steps, both owner-only. Until **both** are done, the site does not exist at
a URL.

1. **Install the workflow.** `.github/**` is an owner-merged surface in this
   repository (`CLAUDE.md`: agents never author `.github/**`), and the agent
   that drafted this branch was correctly blocked from writing there. The
   workflow is therefore staged at `docs/design/pages.yml`. Move it:

   ```sh
   git mv docs/design/pages.yml .github/workflows/pages.yml
   git commit -m "Install the Pages deploy workflow"
   ```

   Review it first — it is short, and it is the only file in this branch that
   can cause anything to be published.

2. **Enable Pages.** Repository **Settings → Pages → Build and deployment →
   Source = "GitHub Actions"**. This cannot be done from a workflow or by an
   agent, by design. The site then publishes at
   `https://gitchrisqueen.github.io/CueSyncAR/` on the next push to `main` that
   touches `docs/site/**`, or on a manual **Run workflow**.

Optional third step: add the URL to the repository's About panel.

To take it down later: set Settings → Pages → Source back to "None", or delete
`.github/workflows/pages.yml`.

### Workflow shape, and why

- Triggers on `push` to `main` (path-filtered to `docs/site/**` and the workflow
  itself) and on `workflow_dispatch`. **Not** on `pull_request` — a PR, in
  particular one from a fork, must never be able to publish to the live site.
- Permissions are declared **per job**, not once for the workflow: the build job
  gets `contents: read` + `pages: write`; the deploy job, which never checks out
  the repository, gets `pages: write` + `id-token: write` and no repository read
  access at all.
- `actions/checkout` runs with `persist-credentials: false`, so no token is left
  in the runner's git config.
- All four actions are pinned to full commit SHAs, with the tag they correspond
  to in a trailing comment. The SHAs were resolved from the GitHub API against
  each action's current release tag at the time of writing (checkout v7.0.1,
  configure-pages v6.0.0, upload-pages-artifact v5.0.0, deploy-pages v5.0.1).
- `concurrency: {group: pages, cancel-in-progress: false}` — one deployment at a
  time, and an in-flight deployment is never cancelled.

---

## Every factual claim on the page, and what backs it

Claims are listed in page order. "Repo" paths are relative to the repository
root on this branch.

### Hero

| # | Claim on the page | Evidence |
|---|---|---|
| 1 | "open-source iOS app" | `LICENSE` (MIT); repository is public. |
| 2 | "watches a real pool table through the camera and draws the predicted shot on the cloth" | `README.md` overview; `App/Sources/SessionModel.swift` live loop; `Packages/ARExperience` `OverlayRenderer`. Describes what the app does, not how accurately — accuracy is qualified in §Status. |
| 3 | "In development · not on the App Store · build it yourself" | `README.md` §Status ("a work in progress, not a shipping app"); `docs/roadmap/06-MILESTONES.md` M5-04 (App Store assets / TestFlight) is `[ ]` open. |

### What it is

| # | Claim | Evidence |
|---|---|---|
| 4 | "for iPhone and iPad" | `README.md` §Compatibility; `project.yml` (app target). |
| 5 | "mark its four corners" | `docs/roadmap/06-MILESTONES.md` M3-02; `App/Sources` calibration flow. |
| 6 | "detects the balls and the cue stick" | M2-01: bundled model classes are `color-ball`, `cue` (the stick), `white-ball`; `CLAUDE.md` §Model class semantics. |
| 7 | "tracks them in a coordinate system locked to the table" | `Packages/TableSpace` (`worldToTable`); `Packages/PerceptionKit` tracker; M2-03. |
| 8 | "draws the aim line, the ghost ball, the post-impact paths and cushion rebounds" | M3-04 `OverlayLayout` + `OverlayRenderer`; `Packages/BilliardsPhysics` (`AnalyticSolver`) covers ghost ball, ball-ball, cushions, pockets (M1-02). |
| 9 | "MIT licensed" | `LICENSE`. |
| 10 | "no App Store listing, no TestFlight beta and no sign-up" | M5-04 open; no authentication code anywhere in `App/Sources` or `Packages/*/Sources` (grep for `signIn`/`OAuth`/`AuthenticationServices`: no matches). |
| 11 | "build it from source with Xcode and put it on your own device" | `README.md` §Getting Started. |

### How it works

| # | Claim | Evidence |
|---|---|---|
| 12 | "runs an ARKit world-tracking session on the live camera feed" | `Packages/ARExperience/.../ARSessionCoordinator.swift`; M3-01. |
| 13 | "A physical device is required — the Simulator has no camera and shows a placeholder" | `README.md` §Getting Started; `CLAUDE.md` ("device only — never the Simulator"). |
| 14 | "Tap the four corners … drag to fine-tune, then lock" | M3-02 ("tap 4 corners → drag-adjust → lock"). |
| 15 | "a table-space coordinate system rooted to an AR anchor" | `CLAUDE.md` §AR anchoring; M3-02 anchor-relative persistence. |
| 16 | "snapping to a standard table size when your corners land within 8 %" | `docs/roadmap/09-SESSION-STATE.md` ("custom sizes allowed with 8% snap to standard"); `Packages/TableSpace` size inference (M1-04). |
| 17 | "saved along with ARKit's map of the room, so a table … can be recognised again on a later launch" | M3-02 ("world-anchor + ARWorldMap persistence with relocalize-to-locked restore"); demonstrated in `docs/validation/2026-07-23-T1-device-verification.md` §T1.2. |
| 18 | "A bundled Core ML detector … run through Vision" | `App/Resources/BallDetector.mlpackage`; `CoreMLDetectionProvider` (M2-02). |
| 19 | "a tracker gives them stable identities in table space" | M2-03 (Kalman tracking, identity association); `CLAUDE.md` ("stable track IDs from BallTracker"). |
| 20 | "a pure Swift solver" | `Packages/BilliardsPhysics` — no ARKit import; tested on Linux (`.github/workflows/ci-core.yml`). |
| 21 | "RealityKit draws the result anchored to the table" | M3-04; `CLAUDE.md` §AR anchoring. |
| 22 | "Aim comes from the cue stick when it is visible, and falls back to where the device is pointing" | M3-05 ("stick-aim with device-pose fallback"); post-MVP backlog item 2 marked done early. |
| 23 | "Tap a pocket to call a shot" | M6-02, recorded as done in `06-MILESTONES.md`. |

### Where it actually stands

| # | Claim | Evidence |
|---|---|---|
| 24 | "a claim about accuracy carries a measured number and a link to the run that produced it, or it is not made" | `README.md` §Status, verbatim policy statement. |
| 25 | Column 1, all eight bullets ("built and running in the app") | M3-01/02/03/04/05 (`[x]`), M2-02/03 (`[x]`), M4-04 settings (`[x]`), M6-02 called shots, `CLAUDE.md` §Session recorder and §Debug mirror, `App/Sources/DebugMirrorServer.swift`. The column heading says *implemented and wired in* and points at column 2 for what has actually been checked at a table — deliberately, because several of these landed after the last table session. |
| 26 | "23 July 2026 · one iPad · one 8 ft table" | `docs/validation/2026-07-23-T1-device-verification.md`; `README.md` §Status. |
| 27 | "took 2 s on each of three consecutive relaunches … first attempt after saving a fresh map took 90–150 s, in the two observations recorded" | Same file, §T1.2: the three-row relaunch table ("passed at 2 s each time") and the caveat immediately below it ("the FIRST relocalization of a freshly saved world map took ~90–150 s (two observations)"). |
| 28 | "Anchor-rooted overlays stayed flat on the cloth after relocalization (before/after photos are committed with the run)" | Same file, §"AR overlay relocalization-rotation bug — FIXED"; `docs/validation/2026-07-23-overlay-reloc-{before,after}.jpg`. Photos are cited, not published — see "Deliberately left out". |
| 29 | "86 % of the time, up from 50 %, after a hold-time fix" | Same file: "duty cycle **50% -> 86%** on device". |
| 30 | "running CPU-only, the on-device detector was blind to a ball moving at shot speed — only rest positions were recoverable" | Same file, FINDING 1; `README.md` §Status states it as a documented negative result. |
| 31 | "has since been allowed onto the Neural Engine behind a crash-safe probe, but that has not been exercised at a table" | `09-SESSION-STATE.md`: compute units are `.cpuAndNeuralEngine` behind a crash-safe probe as of 2026-09-07, marked `needs-device-run`; the iPad load on 2026-09-08 reported the probe `armed:false`. |
| 32 | "Overlay positions still sit a few centimetres off … Two causes have been found and fixed in code; neither fix has been confirmed at a table yet" | `README.md` §Status; `09-SESSION-STATE.md` §B3, which names both causes (protocol-extension dispatch; calibration frozen at lock) and marks the table run outstanding. |
| 33 | "Predicted-versus-actual bank paths: one uncalibrated data point so far" | `README.md` §Status, verbatim. |
| 34 | "External-display (TV) output exists as a tested package but is not yet wired into the app. Projector output with geometric alignment is not built at all." | M4-01 `[x]` (package + tests); `README.md` §5 ("`App/Sources` does not reference `DisplayKit` today"); projector alignment is M6-05 / post-MVP backlog item 6, unscheduled. |
| 35 | "Guided drill content, a game-rules engine, spin and english physics: all planned, none built" | M6-03 open; post-MVP backlog items 3 and 4. |
| 36 | "No performance, battery or thermal profiling. No App Store hardening. No release build of any kind." | M5-01 and M5-04 both `[ ]` open. |

### How it is built

| # | Claim | Evidence |
|---|---|---|
| 37 | "A fine-tuned YOLOv11n detector, exported to Core ML and bundled with the app" | M2-01, which records the fine-tune and the coremltools export to `App/Resources/BallDetector.mlpackage`. |
| 38 | "mAP@50 of 0.896 on its own validation set at export — a measure of the model, not of the app's aiming accuracy" | M2-01: "mAP50 0.896 / mAP50-95 0.765 at epoch 19". The qualifier is the page's own, and is the point: no repository artifact connects this number to overlay accuracy. |
| 39 | "World tracking, plane raycasting and world-map persistence from ARKit; overlays drawn as RealityKit entities rooted to AR anchors" | M3-01, M3-02, M3-04; `CLAUDE.md` §AR anchoring. |
| 40 | "Swift 6 language mode with strict concurrency, a SwiftUI app lifecycle, and a minimum deployment target of iOS 26" | `CLAUDE.md` §Tech stack; `project.yml`; M0-03. |
| 41 | "Eleven local Swift packages" | `Packages/` contains eleven directories with a `Package.swift`. (Note: `README.md` still says "ten" — it predates `Packages/SessionReplay`. The page is right and the README is stale; flagged for a separate fix.) |
| 42 | "They import no ARKit and are tested on both Linux and macOS in CI" | `ci-core.yml` runs package tests on Linux (`swift:6.1` container); `ci-app.yml` has a `test-packages-macos` job on `macos-26`. The no-ARKit claim covers the pure packages named in the sentence (physics, table geometry, perception, tracking, replay, UI) — `ARExperience` is the device shell and is not among them. |
| 43 | "No package manifest in the repository fetches a remote dependency" | No `Packages/*/Package.swift` contains a `url:` dependency entry. |
| 44 | "no analytics SDK, no crash reporter and no telemetry of any kind in the tree" | Grep across `App/` and `Packages/` for firebase / sentry / mixpanel / amplitude / AppsFlyer / GoogleAnalytics: no matches. M5-03 (crash/analytics decision) is open, so none has been adopted. |
| 45 | "no sign-in and no user identity anywhere in the app, and the project runs no backend of its own" | See #10. The only servers in play are the on-device debug mirror and the optional third-party hosted-detection API — both disclosed in the note, neither operated by the project. |
| 46 | "Session recordings are written to the app's own Documents folder on the device" | `CLAUDE.md` §Session recorder (`Documents/Sessions/<id>/`); `docs/recording-a-session.md`. |
| 47 | "The debug mirror is on by default in the current development build" | `Packages/CoachKit/Sources/CoachKit/SettingsModel.swift`: `public var debugMirrorEnabled = true`. |
| 48 | "serves the rendered screen and tracking JSON over your local network on port 8787, with no authentication, to anyone on the same LAN" | `App/Sources/DebugMirrorServer.swift` — `static let port: UInt16 = 8787`, `NWListener` bound to that port with no credential check; `CLAUDE.md` §Debug mirror ("for any browser on the LAN"). |
| 49 | "over that same port it will list and serve any session recordings held on the device" | `App/Sources/DebugMirrorServer+Sessions.swift` — `GET /sessions` (listing) and `GET /sessions/<id>/<file>` (the file). |
| 50 | "A hosted-detection adapter … only used if you deliberately pick a hosted model in the debug model picker and supply your own API key in an untracked local config file. No key ships with the repository." | `Packages/DetectionRoboflow`; `App/Sources/SessionModel.swift` constructs `RoboflowRemoteProvider` only inside the model-selection path, keyed from `secrets.secret(for: .roboflowAPIKey)`; `App/Config/Secrets.xcconfig` is untracked (`Secrets.example.xcconfig` is the committed template); `CLAUDE.md` hard rule 2 and M0-05 record the historical key as rotated and revoked. |
| 51 | "Left alone, detection runs entirely on the device" | M2-02: "SessionModel loads the bundled BallDetector at bootstrap and live tracking prefers it over the hosted evaluation API"; `CLAUDE.md` §Tech stack ("Core ML/Vision on-device (default detection provider)"). |

### Build it from source, and footer

| # | Claim | Evidence |
|---|---|---|
| 52 | "macOS with Xcode 26 or newer, XcodeGen, and a physical iPhone or iPad running iOS 26" | `README.md` §Getting Started. |
| 53 | "The Xcode project is generated from `project.yml` and is not committed" | `CLAUDE.md` §Tech stack; `.gitignore`. |
| 54 | The four clone/bootstrap/open commands | `README.md` §Getting Started; `Scripts/bootstrap.sh` exists. |
| 55 | "on any machine with Swift 6.1 or newer, including Linux, this runs every package's test suite" (`Scripts/test-all.sh`) | `README.md`; `Scripts/test-all.sh`; `ci-core.yml` runs it on the `swift:6.1` Linux container. |
| 56 | "© 2023–2026 Christopher Queen" | `LICENSE` copyright line. |
| 57 | "This page has no analytics, no cookies, no trackers and loads nothing from anywhere but this domain" | `docs/site/index.html` contains no `<script>` and no off-origin `href`/`src` except plain outbound anchor links; the only sub-resources are `styles.css` and `cuesync-icon.svg`, both same-origin. |

---

## Adversarial review

Four personas reviewed the draft. Findings and fixes below; every fix is in this
branch.

### A — Claims auditor

**Verdict: CHANGES REQUIRED (now: PASS).** Four sentences overstated what the
repository supports. Two of them were the kind of error the project's own rules
exist to prevent.

- **A1 — "no server the app phones home to" was false as written.** The tech
  section asserted the app talks to nothing, while the box directly beneath it
  described a hosted-detection API the app can be pointed at. A reader skimming
  the bolded fact would carry away the wrong claim. **Fixed:** rewritten to "no
  sign-in and no user identity anywhere in the app, and the project runs no
  backend of its own", with an explicit pointer to the note.
- **A2 — "Session recordings … go nowhere unless you copy them off yourself"
  was false.** `DebugMirrorServer+Sessions.swift` serves `GET /sessions` and
  `GET /sessions/<id>/<file>`: while the mirror is on — which is the default —
  recordings are downloadable by anyone on the LAN. This was the single worst
  sentence on the page: a privacy assurance contradicted by code the page
  itself mentions two paragraphs later. **Fixed:** the assurance is gone, and
  the note now states outright that the mirror will list and serve recordings
  over the same open port.
- **A3 — "TV / projector output exists as a tested package"** conflated
  `DisplayKit` (real, tested, M4-01 merged) with projector geometric alignment
  (M6-05, not started). **Fixed:** split into two sentences, the second saying
  projector output "is not built at all".
- **A4 — the CPU-only detector result was presented without noting it is now
  stale in one direction.** Compute units moved to `.cpuAndNeuralEngine` behind
  a crash-safe probe on 2026-09-07. Omitting that let a reader assume the
  blindness finding describes today's binary; stating it without a caveat would
  have implied the problem is solved. **Fixed:** both halves are on the page —
  the change happened, it has not been exercised at a table, the July number
  stands as the last one measured.
- **A5 — "Runs on device today" as a column heading** claimed device-verified
  status for a list that includes work merged after the last table session
  (session recorder, anchor-following). **Fixed:** heading is now "Built and
  running in the app", with a subhead pointing at the verification column.
- **Checked and left alone:** the hero's "draws the predicted shot on the
  cloth" describes behaviour, not accuracy, and sits directly above the
  "in development" pill; "tested on both Linux and macOS in CI" is true
  (`ci-app.yml` has a `test-packages-macos` job — I checked, expecting to
  file this as a finding); "eleven packages" is correct against the tree,
  and it is the README that is stale.

### B — Pool player, has never heard of this

**Verdict: PASS WITH FINDINGS (now: PASS).** The first sentence does the job:
"watches a real pool table through the camera and draws the predicted shot on
the cloth" is instantly clear, and the amber pill answers "can I get it?"
before I have to hunt.

- **B1 — I could not tell whether I personally could use this.** "Build it from
  source" reads as an option next to a download, not as the only door. **Fixed:**
  "If you do not write software, there is nothing here for you to install yet."
  Blunt, and it saves the wrong reader five minutes.
- **B2 — jargon in the status section.** "Relocalizing a saved calibration",
  "world map", "anchor-rooted", "duty cycle" mean nothing to me. **Fixed** for
  the two that carry the load: the calibrate step and the status bullet now say
  "the app re-recognising the room and restoring the measurement" and "a table
  you have already set up can be recognised again … instead of re-measured".
  "Anchor-rooted" and "duty cycle" survive in the verified column, which is
  visibly the technical evidence column and reads as such.
- **B3 — not fixed, noted.** The page never shows me the thing. I have no
  picture of what the overlay looks like on a table. That is the right call
  while every available image is of somebody's room, but it is the biggest
  thing missing, and a staged capture would do more for this page than any
  wording change. Recorded as the owner's call.
- Would I try it? No — I do not use Xcode. Would I send it to the one friend
  who does? Yes, and I would not feel oversold on their behalf.

### C — Security / privacy reviewer

**Verdict: PASS WITH FINDINGS (now: PASS).**

- **The page itself is clean.** No `<script>` element. No external stylesheet,
  font, image, iframe, or beacon: the only sub-resources are `styles.css` and
  `cuesync-icon.svg`, both same-origin. No cookies, no storage, no forms. Every
  off-site URL is a plain anchor the reader must click.
- **C1 — outbound clicks leaked a referrer** to github.com. Minor, but a page
  that advertises a privacy stance should hold it. **Fixed:**
  `<meta name="referrer" content="no-referrer">`. (No `target="_blank"` is used
  anywhere, so `rel="noopener"` is not required.)
- **C2 — workflow permissions were broader than needed.** The original draft
  used the documented single workflow-level block, which handed the deploy job
  `contents: read` it never uses and the build job an `id-token: write` it never
  uses. **Fixed:** permissions are declared per job — build gets
  `contents: read` + `pages: write`, deploy gets `pages: write` +
  `id-token: write` and no repository read access. `persist-credentials: false`
  added to the checkout so no token is left in the runner's git config.
- **Workflow triggers correctly scoped:** `push` to `main` and
  `workflow_dispatch` only. No `pull_request`, so no fork PR can publish. All
  four actions pinned to full commit SHAs, not tags.
- **C3 — the workflow could not be installed by the agent, and that is
  correct.** `.github/**` is protected in this repository; the write was
  blocked. Staged at `docs/design/pages.yml` with install instructions rather
  than worked around. The owner should read it before moving it — it is the one
  file here with the power to publish.
- **C4 — an observation about the app, not the site, but it belongs in the
  record.** `debugMirrorEnabled` defaults to `true`, and the mirror is an
  unauthenticated HTTP server on 8787 that will serve the live screen and any
  recorded session bundle to anything on the LAN. On a pool-hall or hotel
  network that is a real exposure. The page now discloses it; the repository
  might reasonably want the default flipped, or the mirror gated to a
  DEBUG-only build. Not a site change — raised for the owner.
- **No secrets, keys, tokens, hostnames, IPs, internal URLs or personal
  contact details appear anywhere in `docs/site/`.** No images of people or
  places are published.

### D — Designer

**Verdict: PASS WITH FINDINGS (now: PASS).** Checked at 375 px, 768 px, 900 px
and 1280 px, in both colour schemes.

- Phone: single column throughout, hero mark scales down to 76 px, buttons wrap
  rather than squeeze, no horizontal scroll, code blocks scroll inside their own
  box. Desktop: steps and status cards go three-up at ≥ ~1000 px; prose is
  capped at 62 ch so the 68 rem container never produces a full-width paragraph.
- Dark mode is a real second design, not an inversion: the token block redefines
  ground, ink, rules and all three card accents. Amber is used as-is on dark and
  darkened to `#7A4E00` on light, where the raw `#F5A623` fails contrast against
  a pale ground.
- Contrast: body ink on ground is ~15:1 (dark) and ~14:1 (light); muted text
  ~7.9:1 and ~6.5:1; the three card-accent headings all clear 4.5:1 in both
  schemes. Focus rings are 3 px amber against every ground on the page.
- **D1 — card and step headings were 1.0625 rem against 1 rem body**, barely
  distinguishable, which flattened the hierarchy exactly where the page asks the
  reader to compare three columns. **Fixed:** 1.125 rem.
- **D2 — `.facts dt { font-weight: 650 }`** is not a weight most `system-ui`
  faces carry; browsers round it inconsistently. **Fixed:** 600.
- **D3 — three 16 rem step columns at ~900 px** produced tall, narrow columns of
  ragged text. **Fixed:** `minmax(17.5rem, 1fr)`, so the third column only
  appears when there is room for it.
- **D4 — a dead `prefers-reduced-motion` block.** The page has no animation or
  transition to reduce. **Fixed:** removed rather than left as decoration.
- Structure is honest HTML — one `h1`, sectioned `h2`s, `ol` for the ordered
  steps, `dl` for the facts, a skip link, a described `alt` on the only image.
