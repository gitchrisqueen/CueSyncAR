# Onboarding & app shell — design

**Status:** Proposal, not adopted. Written 2026-09-09 against `main` @ `5683886`.
**Scope:** what a person sees from cold launch to a drawn aim line, and how the
shell around the AR session is organised. No engine, solver, perception or
`CueSyncCore` change is proposed anywhere in this document.

**Read with:** [05-UX-DESIGN.md](../roadmap/05-UX-DESIGN.md) (the visual system
this obeys), [08-PRACTICE-MODES.md](../roadmap/08-PRACTICE-MODES.md) (where
modes are going), [09-SESSION-STATE.md](../roadmap/09-SESSION-STATE.md) (what
actually works on device today).

## Where the app is now, stated plainly

The build works. It is also, as a product, a control panel. Concretely, from
reading `App/Sources/RootView.swift`:

- **The bottom bar carries up to nine controls**: camera flip, calibrate (or a
  table-size badge), debug mirror, record, practice-mode menu, model picker,
  settings gear, a latency readout in milliseconds, and a box-rotation nudge
  button. Seven are icon-only with no label. Four of the nine exist to serve
  development, not play.
- **The top of the screen is a log, not a status area.** Above the `Spacer()`
  RootView can stack, independently and simultaneously: the status capsule, the
  recording badge, a camera-denied line, `sessionEvent`, `previewStats.lastError`,
  tap feedback, the mirror URL, and the practice-mode pending hint. Eight
  capsules, in red, orange, green, yellow and primary, with no priority order
  between them. On a bad frame the status capsule — the one line that tells the
  player what to do — is pushed down by four diagnostics.
- **The AR session is the launch destination and the only destination.** There
  is no screen that says what the app is. A first-time user gets a camera feed
  and the capsule "Point at the table", and the only way to learn that the app
  wants four cushion-nose taps is to press the dashed-rectangle icon and read
  the capsule that appears afterwards.
- **`HUDStatus.degraded` is unreachable.** `RootView.hudStatus` never returns it
  (verified by grep: the only non-test references are its own definition). So
  "Need more light" and "Hold steady…" — the two honest failure messages the
  design system already ships — have never been shown to anyone. What the user
  gets instead is `sessionEvent`, which
  `ARSessionCoordinator.session(_:cameraDidChangeTrackingState:)` fills with
  `"Tracking limited: \(String(describing: reason))"`. The player reads
  **"Tracking limited: insufficientFeatures"** in an orange capsule.
- **`ModeConfiguration` is dead.** `showsShotGuides`, `requiresCalledPocket` and
  `showsDrillTargets` are read only by `PracticeModeTests`. Nothing in the app
  branches on them. (`PracticeMode.pendingHint` *is* read, in RootView and
  SettingsView — so the mode selector today changes one hint string and nothing
  else.)
- **`deviceParked` — the single most product-relevant flag in the codebase — is
  reachable only from the debug web server.** It is in `SettingsModel`, it is
  honoured (`AimResolver.Config(allowDevicePose: !parked)`, and
  `SessionModel.swift:476`), it is settable at `/cmd?action=parked`, and it is
  **not in `SettingsView`**. Every use the owner named except solo handheld
  practice requires it.

Those five facts are what this design is mostly about. The rest is packaging.

---

## 1. What the app is, and the screens it needs

### One sentence

> **Point your phone at a pool table and CueSync draws the line your shot will
> actually take — on the cloth, live, as you aim.**

That is the whole promise and it is testable: if a player cannot see a line on
the cloth within a minute of installing, the sentence is a lie. Everything
below is in service of shortening the distance to that line.

Two things the sentence deliberately does not claim: that it teaches you (it
shows, it does not yet coach beyond `ShotGuide`'s tip-contact card), and that it
knows the rules of any game (it does not; there is no game state anywhere in
the tree).

### The screens

Five, and one of them is not on the phone.

| # | Screen / state | Exists for | Lifetime |
|---|---|---|---|
| **S1** | **Welcome** — the sentence, one illustration, one button | Answering "what is this" before asking for the camera. A permission prompt with no context is the highest-drop-off moment in any camera app. | First run only |
| **S2** | **Table setup** — the guided four-corner flow, on the live camera | Calibration is unavoidable, unfamiliar, and physically constrained. It needs teaching, not a status capsule. | First run, and on demand |
| **S3** | **Play** — the AR session | This is the product. | Every launch |
| **S4** | **Session sheet** — how you're using the phone right now | The owner's three uses differ in *where the phone is and who is looking*, not in what the solver does. That is a mode selector, and it is one tap deep, not a screen. | On demand |
| **S5** | **TV view** — the external display scene | Spectators need a different picture than the shooter. `DisplayKit.ExternalTableView` already renders it; nothing in `App/` mounts it. | While a display is attached |

Plus **Settings** (already a sheet, keep it) with a **Developer** section inside
it, which is section 7.

**There is no home screen and no launcher.** Argument in section 3.

---

## 2. First-run onboarding

Design rule: **every step either asks for something the OS requires, or teaches
something the user cannot infer from the camera feed.** A step that does
neither gets cut. That leaves two full screens and one guided flow.

### Step 1 — Welcome (one screen)

```
        [ static illustration: a phone held over a table,
          amber aim line running from the cue ball to a pocket ]

        CueSync AR

        Point your phone at a pool table and see the
        line your shot will actually take.

        You'll show it where your table's corners are.
        Takes about a minute, once.

                  [  Get started  ]
                     Not now
```

- The second paragraph is the honest pre-frame for calibration. Users tolerate
  setup they were warned about; they abandon setup that ambushes them.
- **"Get started" triggers the camera permission prompt directly.** No separate
  "we need your camera" screen — the sentence above already is that screen, and
  the system alert carries `NSCameraUsageDescription`, which is already written
  well in `project.yml`.
- **"Not now"** goes to S3 with the camera dark and a single button, "Turn on
  the camera". Nobody is trapped on the first screen of an app they just
  installed.

**If permission is denied:** full-screen state, not the current 60-point red
capsule. "CueSync needs the camera to see the table. Nothing is recorded or
sent anywhere." + a button that opens `UIApplication.openSettingsURLString`.
The privacy sentence is true today — `SessionRecorder` writes only on an
explicit tap, and `DebugMirrorServer` only when toggled — and it is the single
most likely reason a person says no.

### Step 2 — Stand back (one screen, over the live camera)

The camera comes up immediately behind a translucent card. This is the only
place the physical constraints get stated, and they are real, not advisory:

```
   Hold the phone about chest height, a step back from the table.

   • high enough to see the cloth, not across it   (≈ 0.5 m above the rails)
   • far enough back to get one whole end in frame (≈ 1 m)

                     [  I'm ready  ]
```

Why this earns a screen: `PlaneGeometryRaycaster.minimumIncidenceSine = 0.12`
rejects every ray flatter than 7° against the cloth. A user sighting down the
table from cue height produces almost nothing but rejected rays, and the failure
mode is silent — balls simply stop being placed. Teaching the stance once is
cheaper than explaining the silence later. **This screen dismisses on the
button or after the plane is found, whichever comes first**, so a user who was
already standing correctly loses nothing.

### Step 3 — Table setup (the calibration flow, section 5)

Not a screen — a flow with its own coaching, run inside S3's camera view. Four
taps plus a lock.

### Step 4 — First line

When the lock lands, the balls ring in and the aim line draws. One transient
toast, then silence:

> **You're set. This table is remembered — next time it's ready in a couple of
> seconds.**

That sentence exists to make the second launch feel like a reward rather than
a re-run, and it is true: `CalibrationStore` persists the anchored calibration
plus the `ARWorldMap`, and `RootView` starts relocalization at session start
with a 15-second fallback.

### Step count, argued

**Two full-screen steps, one guided flow, one toast.** I considered and cut:

- **A permission-priming screen.** The welcome screen already primes it.
- **A "what the colours mean" legend.** Amber line, green object path, blue cue
  path. Nobody reads a legend, and the shapes teach themselves in three shots.
  If it turns out they don't, the legend belongs in Settings → How to read the
  lines, not in the first sixty seconds.
- **A table-size picker.** Calibration measures the table and snaps to a
  standard size; `SettingsModel.tableSize` already overrides it. Asking up
  front is asking a question the app can answer itself.
- **An account, a tour, a sample video.** No.

### Failure copy, per failure

All of these should route through `HUDStatus`, which already has the right
cases and the right strings — they are simply never constructed.

| Situation | Detectable from | What the user sees |
|---|---|---|
| No plane after ~10 s | `calibration.state == .searchingPlane` held | "Still looking for the table. Move the phone slowly side to side." |
| `.limited(.insufficientFeatures)` | `cameraDidChangeTrackingState` | `.degraded(.lowLight)` → **"Need more light"** — never the enum dump |
| `.limited(.excessiveMotion)` | same | `.degraded(.fastMotion)` → **"Hold steady…"** |
| `.limited(.relocalizing)` | same | `.degraded(.trackingLost)` → **"Re-finding the table…"** |
| Relocalization times out (15 s) | `markRelocalizationTimeout()` | "Couldn't find your table from last time. Set it up again?" + a button |
| Corners don't form a rectangle | `CalibrationError.degenerateCorners` | Existing copy is good; keep it |
| Measured size isn't standard | `.unrecognizedTableSize` | Existing copy is good; keep it |
| Camera denied | `cameraDenied` | Full screen, per step 1 |
| Locked, tracking, no cue ball | `HUDStatus.awaitingCueBall` | Existing copy is good; keep it |

The mapping from `ARCamera.TrackingState` to `DegradedReason` is a small pure
function and belongs in `CueSyncUI` next to `HUDStatus`, tested on Linux.

---

## 3. Home screen: don't build one

**A returning user with a known venue should land in the AR session with the
camera live, no menu in between.** Reasons:

1. The venue is already remembered and relocalizes in about two seconds. A
   launcher screen would spend more of the user's attention than the setup it
   is fronting.
2. 05-UX-DESIGN's stated north star is "the table is the interface". A card
   grid contradicts it on launch, which is the worst place to contradict it.
3. **The three uses do not currently differ in what the app computes.** Free
   play, called shots and guided drill produce identical overlays today —
   `ModeConfiguration` is read by nobody. A three-card home screen would be a
   menu of three doors into the same room. Build the doors when the rooms
   differ (M6-03 drills are the first real divergence).

### What replaces it: a Session sheet, one tap from the HUD

The honest reading of the owner's three uses is that they are three **phone
placements with three audiences**, and each maps onto flags that already exist:

| Use | What actually changes | Existing flag |
|---|---|---|
| **Practice** (solo) | Phone in hand; aim may come from device pose when the stick isn't visible; full HUD | `deviceParked = false`, `practiceMode` free choice |
| **Game** (with friends) | Phone propped or on a tripod so both players shoot; **device-pose aim must be off** or the guide snaps to whatever the mount faces; quieter HUD | `deviceParked = true`, `practiceMode = .calledShots` |
| **TV** (spectators) | As Game, plus the external scene renders the broadcast table view and the phone HUD collapses to a "Showing on TV" chip | `deviceParked = true` + `ExternalDisplayRouter` in `.tableView` |

That table is the design. The presets are named bundles of flags that already
work, which is why this is cheap and why it can be honest — it invents no
behaviour.

The `deviceParked` point is not cosmetic. `SettingsModel` records that on the
operator's own recording, **571 of 712 aimed frames came from device pose**, and
every stick dropout snapped the guide onto the mount's fixed heading and back.
Any propped-phone use with that flag off will look broken. Shipping a "Game"
preset that sets it is a bug fix wearing a product hat.

**Guess, flagged as one:** I am assuming that in the "playing with friends" case
the phone gets set down and both players want to see the guides. The plausible
alternative is that the guides are considered cheating and the phone is a
spectator device only. That difference changes the Game preset materially, and
it is a question for the owner and one evening at a table, not something to
settle in a document.

### Sheet layout

```
  Session                                            [Done]

  ┌────────────┐ ┌────────────┐ ┌────────────┐
  │  Practice  │ │    Game    │ │     TV     │
  │  solo, in  │ │  propped,  │ │ big screen │
  │  your hand │ │  two up    │ │ for others │
  └────────────┘ └────────────┘ └────────────┘

  Guides
    ○ Show every shot line          (free play)
    ● Make me call the pocket       (called shots)
    ○ Guided drills                 coming soon

  Phone
    [x] Phone is propped or on a tripod
        Aim comes from the cue only. Turn this off if you're holding it.
```

The Guides rows are `PracticeMode`. The Phone row is `deviceParked`, exposed
for the first time, with the checkbox pre-set by the preset and overridable —
because a preset that cannot be argued with is a preset users learn to hate.

---

## 4. The in-session HUD, redesigned

### The top: one status, one toast, priority-ordered

Replace the eight-way stack with exactly two slots:

1. **Status capsule** — always present, always the same position, `HUDStatus`
   only. It never moves and nothing ever pushes it down.
2. **One toast slot** below it — the single highest-priority transient message,
   auto-dismissing. Priority (highest first): camera denied → calibration error
   → tap feedback → mode pending hint. `sessionEvent` and
   `previewStats.lastError` **leave the player-facing HUD entirely**: the first
   becomes `HUDStatus.degraded`, the second goes to Developer.
3. The **recording badge** stays where it is when recording — an active
   recording must be unmistakable, and it only exists while a deliberate action
   is running.
4. The **mirror URL capsule** moves to the Developer sheet, where somebody who
   needs to type an IP address into a laptop can select and copy it. It has no
   business on a player's screen.

The priority resolution is a pure function over the model's message fields and
belongs in `CueSyncUI` with tests, for the same reason `HUDStatus` does.

### The bottom: three controls

```
  [ 8-ft ✓ ]        [ Practice ]        [ ⋯ ]
    Table            Session             More
```

- **Table** — shows the locked size (existing `sizeBadge`) or "Set up table"
  when there is none. Tap re-enters calibration. This is the existing calibrate
  button, kept, because re-calibration is a genuine at-the-table action.
- **Session** — the preset name. Tap opens the Session sheet (section 3).
  Replaces the icon-only `figure.billiards` menu, which today changes nothing
  but a hint string.
- **More** — sheet containing Settings, How to read the lines, and Developer.

### Every existing control, decided

| Control | Verdict | Reason |
|---|---|---|
| Camera flip | **Developer** | The front camera is a detection preview that suspends the AR session. A player never wants it, and the button's own accessibility label has to explain that AR is back-camera-only — which is the tell. |
| Calibrate / size badge | **Keep in the bar** | Primary, physical, re-enterable. |
| Debug mirror antenna | **Developer** | It starts an HTTP server on the LAN. That is not a player control, and having it one thumb-slip away from a stranger's phone is worse than inconvenient. |
| Record | **Developer, plus a pinnable exception** | It is a development instrument (`RecordingDetectionProvider`, `SessionReplay` bundles). But it is *used at the table under time pressure* — burying it two sheets deep will cost the owner a session someday. Add a Developer toggle, "Show record button in HUD", default on for debug builds, off for release. Also stays on the mirror at `/cmd?action=startRecording`. |
| Practice-mode menu | **Becomes the Session chip** | Same function, honest label, and it now changes something. |
| Model picker | **Developer** | A/B evaluation tooling for hosted Roboflow models. It is disabled without an API key, which most builds will not have. |
| Latency `ms` readout | **Developer** | A number with no unit of meaning for a player. |
| Box-rotation nudge | **Developer** | A per-device calibration workaround for the 2D preview overlay. It should not outlive the preview path. |
| Build badge | **Keep in debug, footer in release** | Load-bearing for device work (three-places rule in CLAUDE.md), and it already sits below the bar out of the cloth. In a release build, move it to the More sheet footer. Do not delete it and do not change its format. |
| Cue-ball guide card | **Keep exactly as is** | It is the only element on screen that teaches the shot rather than reporting on the app. |

Net: **nine controls to three**, with nothing deleted — six relocated to a
surface that admits what it is.

---

## 5. Calibration, taught properly

This is the hardest screen in the app and currently the least designed. What
the user must do is genuinely strange: tap four points on rubber, from a stance
that satisfies a 7° incidence gate, in a coordinate system they cannot see.

Three things fix most of it: **say what a cushion nose is with a picture**, **say
which corner is next**, and **let the user see under their own fingertip**.

### 5a. The one thing that must be taught: the nose

Corner placement is nose-to-nose, not rail-edge-to-rail-edge —
`HUDStatus.placingCorners`' own doc comment says rail taps oversize the table,
and an oversized table draws every pocket outside the real one. So teach it
with a cross-section, not a sentence:

```
      wood rail top          ←  NOT here
      ┌────────────┐
      │            │╲
      │            │ ╲  cushion rubber
      └────────────┘  ╲
                       ●  ←  HERE: where the rubber meets the cloth
      ══════════════════════════════════════  cloth
```

A small static diagram (a `Shape`-drawn SwiftUI view in `CueSyncUI`, so it is
snapshot-testable and needs no asset), shown in a card during the first
calibration and behind an "(i)" thereafter. Caption: **"Tap where the cushion
meets the cloth — the point closest to the middle of the table. Not the top of
the wood."**

### 5b. The flow, step by step

**State `searchingPlane`** — status capsule "Point at the table". The stand-back
card from onboarding step 2 shows here on first run. After ~10 s with no plane:
"Still looking. Move the phone slowly side to side." (Slow lateral motion is
what gives ARKit parallax; "move around" does not say that.)

**State `planeFound`, 0 of 4 down** — the nose card appears with the diagram and
one button, "Got it". Dismissing it reveals the tap surface. Capsule reads
"Tap the cushion-nose corners (0/4)".

**Placing, 1–4** — three additions to what exists:

1. **A loupe.** While a finger is down, a small circular magnifier of the camera
   feed offset above the fingertip, with a crosshair at the exact tap point. The
   finger covers the corner it is trying to hit; this is the standard fix and it
   is the difference between a 1 cm placement and a 3 cm one.
2. **Placed corners get a number and stay put.** They already re-project every
   frame from world space against the cluster anchor, which means the user can
   walk. Say so, once, after the second corner: **"You can walk around the
   table — the dots stay on the cloth."** This is the single most useful thing
   the flow knows and does not say, and it directly resolves the grazing-angle
   problem: the far corners get tapped from near them, not sighted across the
   table.
3. **Order is free — say that too.** `TableSpace.CornerOrdering` sorts arbitrary
   winding, so the copy should read "in any order" rather than implying a
   sequence the user then worries about getting wrong.

**State `adjusting`** — the rectangle closes in `feltGreen` with draggable
handles (this works today and the handle-lag and grab-offset bugs are already
fixed; do not touch that code). Additions:

- The live measured-size capsule already exists (`calibrationSizePreview`) —
  keep it, and put it **immediately under the Lock button**, since it is the
  evidence for the decision the button makes.
- When the measurement is within snap distance of a standard size, say what
  will be recorded: **"Looks like an 8-ft table. Locking will record it as 8-ft."**
  Users trust a system that tells them what it is about to write down.
- Lock stays a labelled, prominent, tinted button. It is the only irreversible
  step and it should not be an icon.

**Locked** — success haptic (already wired via `sensoryFeedback`), rings appear,
line draws, the "this table is remembered" toast from onboarding step 4.

### 5c. What not to change

The corner-projection code, the drag grab-offset, the `transaction { $0.animation = nil }`
on handles, the anchor rebasing, and the three-second delay before
`saveWorldMap`. All four are recorded bug fixes with reasons in comments. This
design adds views around them and changes none of them.

---

## 6. TV / spectator view

`DisplayKit` already contains `ExternalDisplayRouter` (a tested state machine
with prompt/preference/hot-plug rules) and `ExternalTableView` (full-bleed
`TableSceneView` on black). **Nothing in `App/Sources` references either.**
M4-01 is marked landed with the note "UIWindowScene wiring lands with M3-05 app
integration"; it did not. So TV mode is a wiring job plus a styling pass, not a
design-from-scratch.

### What the TV shows that the phone does not

- **The whole table, always.** The phone shows what the camera sees, which is
  usually one end. The external scene is the rendered top-down table from
  `TableSceneView`, so it never crops and never shakes.
- **Ball identity at ten feet.** Numbers and colours drawn large, not a 40-pixel
  ring over camera noise.
- **The shot as a story.** Aim line, ghost ball, object path, cue path,
  highlighted pocket — and, once M6-02's called pocket is fed through, the
  called pocket ringed and the "on line" fill. That is the moment worth watching
  and it is the whole argument for the TV.

### What the TV must never show

- **The camera feed.** It is shaky, it is dark, it is a picture of a phone
  pointed at a table. Mirroring is a fallback the router offers, never the
  default.
- **Any HUD chrome.** No status capsule, no toasts, no bar, no cue-ball guide
  card (that is the shooter's private information).
- **Anything developer.** No build badge, no latency, no frame counters, no
  mirror URL, no detector name. A projected IP address on a bar TV is a real
  problem, not a stylistic one.
- **Anything that flickers.** Overlay fades on degraded tracking should hold the
  last good frame on the TV rather than blinking at a room. Different device,
  different honesty rule: the phone tells the shooter it is unsure; the TV goes
  quiet.

### Phone behaviour while a display is attached

Phone keeps the AR view, HUD collapses to the status capsule plus a "Showing on
TV" chip, and the Session preset flips to TV. Disconnection never modals and
never tears down the AR session — the router's rules already say this; the app
just has to honour them.

**Unresolved, needs a device and a TV:** whether AirPlay latency makes the
rendered scene feel attached to the shot or a beat behind it. Nothing in this
repo has ever driven an external display. Treat every claim in this section as
`needs-device-run`.

---

## 7. Where the developer surfaces go

**One place: Settings → Developer.** A section at the bottom of the existing
sheet, collapsed by default, containing:

- Debug mirror toggle + address (selectable, monospaced) — already in
  `SettingsView.debugSection`, keep it, it is the right home.
- Record session, plus the "Show record button in HUD" pin toggle.
- Detector: provider picker, model picker, "Running on", compute probe summary,
  CPU pin, ANE retry — the existing `detectionSection` and `computeSection`
  unchanged; the HUD model picker becomes a duplicate of a control that is
  already here.
- Camera flip (front detection preview) + box-rotation trim.
- Frame diagnostics + latency.
- Tracking tuning (`visibleMissGrace`) and guide speed — arguable; `guideSpeed`
  is a genuine player preference ("how hard is the app assuming I hit it") and
  should stay in the main body under Guides.
- Build identity, full form.

**Explicitly: nothing is deleted.** Every one of these is load-bearing for the
owner's device workflow, and two of them (mirror, recorder) are how the project
debugs a device standing at a table. They are moved, not removed, and every one
of them keeps its `/cmd` route on the mirror.

**Gating.** Section visible always in `DEBUG`; in release, behind the standard
tap-the-build-badge-a-few-times reveal. Not a compile-out — the owner will want
it on a TestFlight build, and a compiled-out surface cannot be turned on at a
table.

---

## 8. Implementation plan

Ordered, each independently shippable and independently revertible. **None
touches `Packages/CueSyncCore`** — no contract-change PR is required for any
step here. Every step that adds pure logic adds tests in the same PR
(playbook rule 3).

**PR 1 — Quiet the top of the HUD.** Adds `Packages/CueSyncUI/Sources/CueSyncUI/HUDMessage.swift`
(pure priority resolution over the transient message fields) + tests; changes
`App/Sources/RootView.swift` to render exactly one status capsule and one toast.
Ships alone and improves the current app immediately.

**PR 2 — Make degraded states reachable.** Adds a pure
`HUDStatus.DegradedReason` mapping from AR tracking-state strings in `CueSyncUI`
+ tests; changes `ARSessionCoordinator` to report a structured reason instead of
`String(describing:)` (it is in `ARExperience`, not `CueSyncCore`) and
`RootView.hudStatus` to return `.degraded`. Deletes "Tracking limited:
insufficientFeatures" from the user's world.

**PR 3 — Split the bar.** Adds `App/Sources/HUDControlBar.swift` and
`App/Sources/MoreSheet.swift`; moves the developer controls into a new
`Developer` section in `App/Sources/SettingsView.swift`; changes `RootView`. Nine
controls become three. No behaviour change, so it is safe to land before any of
the new flows.

**PR 4 — Session presets, and `deviceParked` in the UI.** Adds
`Packages/CoachKit/Sources/CoachKit/SessionPreset.swift` (pure: preset →
`PracticeMode` + `deviceParked` + HUD density + wants-external-scene) + tests;
adds `sessionPreset` to `SettingsModel`; adds `App/Sources/SessionSheet.swift`;
gates the shot guides on `ModeConfiguration.showsShotGuides` and the on-line
status on `requiresCalledPocket` in `SessionModel`/`RootView`. The gating is a
no-op today (all three modes set `showsShotGuides`), which is exactly why it is
a safe way to stop the flags being dead.

**PR 5 — Calibration teaching.** Adds
`Packages/CueSyncUI/Sources/CueSyncUI/CushionNoseDiagram.swift` (pure `Shape`
drawing, snapshot-testable) and `CalibrationStepCopy.swift` (pure per-state copy
+ tests); adds `App/Sources/CalibrationCoachCard.swift` and
`App/Sources/CornerLoupeView.swift`; changes `CalibrationOverlayView.swift` to
host them. Does not touch corner projection, drag handling, or lock.

**PR 6 — First run.** Adds `App/Sources/Onboarding/WelcomeView.swift`,
`App/Sources/Onboarding/StandBackCard.swift`, `App/Sources/OnboardingState.swift`
(UserDefaults-backed, one key), and a pure `CueSyncUI/FirstRunStep.swift` for
the copy + ordering with tests; changes `CueSyncApp.swift` to branch on
first-run and `RootView.swift` to show the camera-denied full-screen state.
Lands after PR 5 so a first-timer's calibration is already the taught one.

**PR 7 — External display wiring.** Adds
`App/Sources/ExternalDisplayHost.swift` (the `UIWindowScene` lifecycle the
package deliberately does not own) and wires the existing
`ExternalDisplayRouter` + `ExternalTableView`; changes `CueSyncApp.swift` and
`SessionModel` to publish `TableState`/`ShotPrediction` to the scene. Closes the
M4-01 wiring note. **`needs-device-run` and needs an actual TV.**

**PR 8 — TV styling (M4-02).** Broadcast pass on `ExternalTableView`: 10-foot
type, ball numbers, called-pocket rendering, hold-last-good-frame on degraded
tracking, plus the snapshot suite M4-02 already asks for. Pure `DisplayKit`
work; testable in CI.

**PR 9 — Release gating for developer surfaces.** Build-configuration gate on
the Developer section and the HUD build badge. Last, because it is the only step
that can hide something the owner needs, and it should land when the rest is
settled.

PRs 1–3 are pure cleanup of what exists and could land in a day. 4–6 are the
product change. 7–8 are the TV. Nothing after PR 3 is blocked by anything
outside this list.

---

## 9. What this does not propose

- **No accounts, no cloud, no sync.** Nothing in the tree needs a server, and
  adding one adds a privacy story the app currently does not have to tell.
- **No game rules, no scoring, no 8-ball/9-ball state.** There is no game model
  anywhere in `Packages/`, and inventing one to make a "Game" mode feel real
  would be building the deepest thing in the app to justify a button. The Game
  preset is a phone placement, and it says so.
- **No drills UI.** M6-03 defines drill content; until a `Drill` value exists,
  a drill picker would be a menu of nothing. `guidedDrill` keeps its honest
  "coming soon" hint.
- **No auto-calibration.** M6-06 plans a `VNDetectRectanglesRequest` pass into
  the existing `cornersProposed` entry point. It is the right feature and it
  will make section 5 shorter. It is also a perception change, and this document
  is deliberately only the shell. **When it lands, the four-tap flow stays as
  the fallback and the teaching stays with it** — auto-detect that is wrong on a
  cluttered table needs a user who understands what a nose is.
- **No visionOS / AR-glasses work.** Worth naming since the owner asked: the
  architecture is already in the right shape for it — pure `TableSpace`,
  `BilliardsPhysics` and `PerceptionKit` with an ARKit shell in `ARExperience`,
  and overlays that already root under an ARAnchor. So the port is a new shell,
  not a rewrite. But glasses change the *entire* interaction model this document
  is about: no touchscreen, so no four-corner tap and no tap-to-designate; the
  HUD is world-locked rather than screen-locked; and the TV/spectator case
  mostly evaporates. It is a separate design, and it should be written after
  auto-calibration exists, because a tap-free calibration is its hard
  prerequisite.
- **No visual redesign of the overlays themselves.** Colours, dash flow, ghost
  ball and pocket glow are specified in 05-UX-DESIGN and implemented in
  `OverlayLayout`/`OverlayRenderer`. Nothing here changes what is drawn on the
  cloth — only what is drawn around it.
- **No new dependencies and no new packages.** Everything above lands in
  `App/`, `CueSyncUI`, `CoachKit` and `DisplayKit`.

## Open questions for the owner

1. **Do the guides stay on during a friendly game?** This determines the Game
   preset (section 3) and I am guessing. One evening at a table with two players
   settles it.
2. **Is the record button pinned in the HUD by default in your own builds?**
   PR 3 assumes yes for debug, no for release.
3. **Is there one venue or several?** `CalibrationStore` holds exactly one saved
   calibration and one world map. A second table overwrites the first silently.
   Nothing in this design depends on the answer, but a person with a home table
   and a league table will find that out the hard way.
