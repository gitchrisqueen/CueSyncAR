# Competitive & UX research — making CueSync a product, not a debug harness

**Date:** 2026-09-09 · **Status:** research input, not an adopted plan · **Scope:** competitor
landscape, onboarding patterns, calibration UX, the three named modes, glasses realism,
anti-patterns.

This document exists because of a specific complaint: a new user who opens CueSync sees a camera
feed, a status capsule, and eight icon buttons (camera flip, calibrate, mirror, record, practice
mode, model picker, settings, box-rotation nudge, plus a latency readout) and has no idea what to
do. Nothing in the app says what it is for or what to do first. This is research toward fixing
that. It does not change any code and does not supersede `docs/roadmap/05-UX-DESIGN.md`, which
already describes a first-run flow that has not been built.

## How to read this

Claims carry a marker. Nothing here is invented; where a fact could not be established, it says so.

- **[F]** — confirmed by fetching and reading the cited page.
- **[S]** — seen only in a search-result snippet; not verified against the source.
- **[U]** — searched for and could not confirm. Treat as unknown, not as false.

Prices, ratings and dates were read on 2026-09-09 and will drift.

---

## 1. The competitive landscape

### 1.1 The short version

**No shipping consumer app today draws a live aiming line on a real pool table.** The category has
been attempted and abandoned on phones, and it survives only as expensive fixed installations.

- **BilliardRadar** (Crudebyte) is the direct precedent and it is **dead**. It described itself as
  "The first augmented reality app for mobile devices which assists you playing on a real billiard
  table," supported pool/snooker/carom, required an initial calibration to learn the table surface,
  and let the user span a shot with two touches while the trajectory recalculated as they walked
  around. Minimum iOS 5.0 / Android 2.2, so roughly 2012 vintage. Its own developer now lists it
  under **Discontinued Apps**; no discontinuation date is published. **[F]**
  <https://crudebyte.com/billiardradar/> · <https://crudebyte.com/mobile/>
- Everything else that ever projected aim lines onto a real table was a **fixed overhead camera plus
  a projector**: PoolLiveAid (Univ. of the Algarve) **[S]**, Cassapa (GPL-3, 52 stars, Windows-only,
  appears unmaintained) **[F]** <https://github.com/aporto/cassapa>, OpenPool (two Kinects,
  self-build cost cited around $10,000) **[S]**, Obscura CueLight (installed at Hard Rock Las Vegas
  2009; quoted $25k–$80k depending on source — effects, not aiming) **[S]**, MyWebSport (ceiling
  camera at 50 fps plus a laser marker module, carom-focused) **[F]**, MagixPool **[S]**, and the
  personal project BilliardsOverlay (Raspberry Pi + projector; 0 stars) **[F]**.
- This repo already carries one of the academic ancestors: `docs/pool-aid.pdf` — POOL-AID, UCSD
  Spring 2016 (Bauza, Choi, Huang, Souverneva; mentor Ryan Kastner). Overhead GoPro, OpenCV colour
  subtraction and blob detection, physics overlay on a rotated video. Its own related-work section
  notes that similar systems already existed in published literature and the hobbyist community.

**The pattern is unambiguous: every system that worked well solved calibration once, from a fixed
mount, and never moved.** The handheld version is the one that died. CueSync is attempting the hard
variant. That is the opportunity and also the risk.

### 1.2 The live CV competitors — both do the *opposite* of CueSync

Two iOS apps today point a camera at a real table. Neither predicts; both audit.

**DrillRoom: AI Pool Trainer** — OrangeLoops, iOS/iPadOS only. Free with IAP at **$14.99/month,
$89.99/year**. **4.6★ from 258 ratings**. **[F]**
<https://apps.apple.com/us/app/drillroom-ai-pool-trainer/id1539827505>

- Setup instruction is one sentence: "All you need is your iPhone or iPad, a tripod, and a well-lit
  billiard table. Simply set up your device 5 feet above the ground." No corner tapping — detection
  is meant to be automatic. **[F]**
- It shows live quality meters; a reviewer describes running with "4 bars for framing and 5 for
  lighting." **[F]**
- Core loop: 80+ drills, a drill editor, "Live Capture" (turn a real table layout into a repeatable
  drill), heat maps by table region, Apple Watch companion.
- Praise: automatic scorekeeping, shot video clips, and the value frame — "At a annual subscription
  price less than an hour with a coach." **[F]**
- Complaints, and they are all one theme — **detection under real play conditions**: "detection of
  pocketed shots, as an example, is very spotty. You will likely manually tag about half"
  (2025-12-27); "The next shots usually fail with the error, 'I can't see the cue ball'"
  (2024-10-21); "walking around the table in front of the camera causes issues"; "it doesn't see
  balls touch other balls or suddenly ends drill thinking you missed." **[F]**
- **The most useful single fact in this whole section:** those complaints come from users whose
  framing and lighting meters read green. A quality meter that says "good" while detection fails
  destroys trust faster than showing no meter at all.

**Railbird Pool** — Railbird LLC, iOS + Android. Free with IAP; **Plus $10.99/mo or $80.00/yr, Pro
$16.99/mo or $131.99/yr**. **3.9★ from 20 ratings**, updated Sept 2026. **[F]**
<https://apps.apple.com/us/app/railbird-pool/id6469274937>

- Setup: "set your phone up at the table, hit record." No documented calibration wizard found. **[U]**
- Records a session, detects makes/misses/runs/players, condenses hours to minutes of shots.
- Praise: "While I'll admit it is not 100% accurate, I'm still loving it!" Complaint: "There's a few
  shots I make that it counts as misses… I would say 5-10% of the shots are incorrect." **[F]**

**Neither claims trajectory projection.** They answer *did you make it?* CueSync answers *where do I
aim?* On the AZBilliards forum a player asked for apps that analyse shots and was told DigiCue and
DigiBall "both require hardware" and "neither analyze the actual shot." **[F]**
<https://forums.azbilliards.com/threads/pool-apps.581925/> The gap is one players have named
unprompted.

### 1.3 The crowded, low-value tier: diagram trainers with no camera

The App Store is full of ghost-ball calculators and drill libraries. They are the incumbents CueSync
will be shelved next to, and they set the price expectation.

| App | Developer | Price | Notes |
|---|---|---|---|
| **Bullseye Billiards** | Razor Pool, LLC | Free + IAP: **$9.99/mo, $69.99/yr, $199.99 lifetime** | **4.6★ / 210 ratings**. 400 structured drills; the only pool training app carrying the **BCA Seal of Approval**; a "Coach" feature recommends shots from practice history. **The user logs cue-ball position after each attempt by hand.** **[F]** <https://apps.apple.com/us/app/bullseye-billiards/id1219867352> |
| **WPB: Pool Training & Drills** | Parrent Ventures LLC | $10.99/mo, $79.99/yr, **$249.99 lifetime** | 4.4★ / 249 ratings; 200+ drills, ghost-ball calculator, no camera. Complaint: "free app that you have to pay to use at all." **[F]** |
| **Cueist** | — | Freemium | iOS + Android, skill assessment + drills, no CV. **[F]** |
| **Billiards Aiming Assistant** | Efstratios Kantzelis | **$1.99** | Carom geometry calculator, **3.0★ from 2 ratings**, no camera. **[F]** |
| **Aim Master 8 Ball Pool** | Sonu Kumar Gupta | Free | **1.0★ from 10 ratings**. **Not a real-table tool** — an aim overlay for Miniclip's *8 Ball Pool* video game; the description says it "does not change the game itself." **[F]** |
| **AR Cue Sports** | Yoshihiro Masuda / AI BLACKSMITH | Free | Virtual AR table game, last updated 2020-12-20, too few ratings to display. **[F]** |

Two positioning consequences:

1. **Bullseye Billiards is the real competitor for the practice-mode ambition** (roadmap M6-03), and
   its weakness is that scoring is manual. CueSync's whole reason to exist in drills is that the
   table tells you what happened — the tracker scores it. That is a sharper wedge than the aim line.
2. **App Store search for "pool aim" is polluted by cheat overlays for Miniclip's game.** The name,
   icon, and screenshots must make "real table, your camera" unmistakable in the first screenshot.

### 1.4 Hardware trainers — what pool players actually already buy

- **DigiCue BLUE** (OB Cues / Nathan Rhoades) — module on the cue butt, vibrates on a stroke fault,
  streams per-shot stats to a free app; sold via Amazon, price not published on the vendor site.
  Notably it ships **three named presets — Beginner / Intermediate / Advanced — usable with no app at
  all**. **[F]** <https://www.digicue.net/digicue.php>
- **DigiBall** — instrumented cue ball detecting tip contact point, spin RPM and speed. The vendor
  page says "coming soon… currently not yet for sale" while forum threads suggest units shipped;
  price could not be confirmed. **[U]**
- **Ghost Ball Aim Trainer** (PoolDawg) — a **$30 plastic template** that teaches ghost-ball aiming,
  sold with a lesson booklet. **[F]** <https://www.pooldawg.com/ghost-ball-aim-trainer>
  This is the cheapest proof that the ghost ball is the thing players want. CueSync renders it live.

### 1.5 Adjacent CV sports coaching — the apps to actually copy

**HomeCourt** (NEX Team) is the canonical phone-camera CV coach. **$7.99/month, $69.99/year**,
**4.8★ from ~15,000 ratings**, 2019 Apple Design Award. **[F]**
<https://www.homecourt.ai/pricing> · <https://apps.apple.com/us/app/homecourt-basketball-training/id1258520424>

Its onboarding is four steps and the ordering is the lesson: **[F]**
<https://www.homecourt.ai/in-app/gettingstarted> · <https://www.homecourt.ai/faq/setup>

1. **"Check your setup"** — before any camera step, tell the user what *hardware* to get: a selfie
   stick with a built-in stand, or a tripod with a device mount.
2. **"Set up your shot"** — "make sure your device has a clear view of the hoop, the court and the
   shooter," on a tripod "at least 3-5 feet in height," positioned "along the sideline near half
   court." The requirement is stated **semantically** (what must be in frame), not numerically.
3. **"Detect the court"** — "when set up properly, HomeCourt will automatically detect the court and
   hoop." **The user never taps a corner.** Visual confirmation appears on screen.
4. **Record** — live stats overlay.

Its documented preconditions are equally concrete: well-lit, clear court lines, a hoop *with a net*,
one shooter, a normally-coloured ball. Its complaints mirror DrillRoom's exactly: unreliable in dim
or very bright light and at steep camera angles; "the app may say you missed even if you made it";
occlusion when "someone is standing in between the camera and the shooter"; battery drain; and an
incoming phone call ending a workout. **[S]** Its own FAQ describes **no error state and no recovery
path** when detection fails. **[F]**

**Autodarts Lens** is the closest structural analogue to CueSync's problem and the best calibration
UX found anywhere in this research. Phone camera, on-device NN inference (iOS 18+ / Android NPU),
free tier of 5 Lens matches per 30 days, **Plus £5.99/mo or £59.99/yr**; Winmau sells an official
device stand at **$39.99**, or stand plus a year of Plus at **$99.95**. **[F]**
<https://docs.autodarts.com/getting-started/detection/lens/> · <https://winmau.com/en-us/pages/autodarts-x-lens>

Its on-screen guidance is four live, plain-language pose corrections that steer the user into a
working camera position, then an unambiguous lock: **[F]**

| State | What the app says |
|---|---|
| Whole board not in frame | "Ensure the entire board is visible" |
| Too far to the side | "View more from the front" |
| Too square-on | "View from the side" |
| Correct | "Ready to play" + **green outline + checkmark + haptic** |

Then a persistent **"Detecting"** status pill during play, and — critically — **if the phone is
knocked or the light changes, you reposition without restarting the game.** Recovery is
non-destructive.

The DIY multi-camera Autodarts is the manual contrast: the user **drags four yellow markers onto four
named physical landmarks** (the wire intersections 3-19, 6-10, 11-14, 20-1) per camera, with an
"Auto" button available, and then presses a button that **overlays the derived segment edges back
onto the board image** so the user can see whether the edges line up with the real wires. If they do
not, the docs say camera distortion is probably the cause and "even than the recognition is also
working very well. Just give it a try :)" **[F]**
<https://github.com/Saturi92/autodarts-docs/blob/main/README.md>

**Scolia Home 2** is the premium counter-argument: a rigid two-camera rig screwed to the wall, and
because the geometry is fixed it "calibrates its cameras completely automatically within a few
seconds on every start-up. You don't have to worry about tiresome manual calibration processes."
Unlimited lifetime use is included with the hardware — no subscription. **[F]**
<https://scoliadarts.com/scolia-home2/> The lesson: *rigid geometry buys automatic calibration, and
they sell that as the premium feature.* CueSync's software equivalent is persisted calibration —
"remember this table" — which the repo already has via ARWorldMap relocalization.

**SwingVision** (tennis) is the model for honesty about degradation. It recommends a top-of-fence
mount and sells one (~$60), with a tripod explicitly the third-choice fallback; free tier is up to
2 hours/month of analysis with **Pro at $179.99/year** (single-reviewer figures). It states plainly
that "Line call accuracy might decrease with a sub-optimal configuration, such as differing zoom
settings, a tripod, or when the device faces the sun." **[F]** <https://techinthesun.com/swingvision/>
Naming your failure conditions up front converts a future bug report into a setup instruction.

**Sportsbox 3DGolf** is the counter-example in setup guidance: unusually prescriptive numbers ("No
more than 12 feet away from the golfer's toe line with standard zoom, 7ft with 0.5x zoom"; tripod
"no higher than three-and-a-half feet"), but its help page describes **no on-screen guide and no
calibration confirmation** — the user is expected to get it right from a document. **[F]**

Other adjacent reference points, sensor- rather than camera-based, useful only for price anchoring:
Arccos Caddie ~$199/yr **[S]**; HackMotion hardware from $275 **[S]**; Uplift Labs $12.99/mo **[S]**.

**Archery / shooting:** searched thoroughly; the category is AR *games* and scoring apps. **No AR aim
trainer for archery or shooting could be found.** **[U]**

### 1.6 Price anchors

| Product | Recurring price |
|---|---|
| Bullseye Billiards (pool drills, manual scoring) | $69.99/yr, $199.99 lifetime **[F]** |
| Autodarts Plus (phone-camera darts scoring) | ~£59.99/yr **[F]** |
| HomeCourt (phone-camera basketball) | $69.99/yr **[F]** |
| Railbird Pool (phone-camera pool analytics) | $80.00–$131.99/yr **[F]** |
| DrillRoom (phone-camera pool drills) | $89.99/yr **[F]** |
| SwingVision Pro (phone-camera tennis) | $179.99/yr **[F]** |

The pool market already bears $70–$132/year for retrospective analytics with visible accuracy
complaints. DrillRoom's defenders anchor on "less than an hour with a coach," which is a good frame
to borrow.

---

## 2. Onboarding patterns that fit a camera-first AR app

### 2.1 Apple has already written most of this, and CueSync is not following it

The HIG's Augmented Reality page is effectively a spec for the missing first-run experience. **[F]**
<https://developer.apple.com/design/human-interface-guidelines/augmented-reality>

- "Consider using the built-in coaching view to show people what to do and provide feedback during
  the initialization process."
- "Hide unnecessary app UI while people are using a coaching view."
- "Avoid using technical terms like ARKit, world detection, and tracking."
- "In a three-dimensional context, prefer 3D hints… Avoid displaying textual overlay hints in a 3D
  context unless people aren't responding to contextual hints."
- Directly relevant to a four-corner tap: **"Avoid trying to precisely align objects with the edges
  of detected surfaces. In AR, surface boundaries are approximations that may change as people's
  surroundings are further analyzed."**
- "Let people reset the experience if it doesn't meet their expectations."

Apple even supplies the copy, in a do/don't table: **[F]**

| Do | Don't |
|---|---|
| "Unable to find a surface. Try moving to the side or repositioning your phone." | "Unable to find a plane. Adjust tracking." |
| "Try turning on more lights and moving around." | "Insufficient features." |
| "Try moving your phone more slowly." | "Excessive motion detected." |

`ARCoachingOverlayView` is the shipped implementation: "A view that displays standardized onboarding
instructions to direct users toward a specific goal," with goals `.tracking`, `.horizontalPlane`,
`.verticalPlane`, `.anyPlane`, `.geoTracking`. `activatesAutomatically` defaults to `true` and the
view "activates when the session is initializing or when tracking conditions have degraded past a
certain threshold." Three delegate callbacks: `willActivate`, `didDeactivate`,
`didRequestSessionReset` — the last fires when the user taps **Start Over** during relocalization.
**[F]** <https://developer.apple.com/documentation/arkit/arcoachingoverlayview>

**Caveat for this codebase:** there is no SwiftUI equivalent; it must be wrapped in
`UIViewRepresentable`. An Apple DTS engineer confirmed this on the developer forums. **[F]**
<https://developer.apple.com/forums/thread/799425>

Apple's own sample app ("Placing objects and handling 3D interaction") shows the timing: **silence
first, then escalating hints** — the coaching overlay at launch, a scheduled "FIND A SURFACE TO
PLACE AN OBJECT" at 7.5 s, "TRY MOVING LEFT OR RIGHT" at 5 s for the focus square, and tracking-state
feedback escalated after 3 s. It **hides all virtual content** on `sessionWasInterrupted` and
restores it only at `.normal`. **[F]**
<https://developer.apple.com/documentation/arkit/placing-objects-and-handling-3d-interaction>

### 2.2 The hard constraint nobody warns you about: cloth has no texture

This is the single biggest technical-UX risk for CueSync and both platform vendors name it
explicitly.

- Apple's RoomPlan ships a dedicated coaching state, **`lowTexture`**, which fires when "the user
  points the device at a wall with a solid color" or "the camera view finder doesn't contain any wall
  edges or other defining shapes." **[F]**
  <https://developer.apple.com/documentation/roomplan/roomcapturesession/instruction>
- Google's ARCore environment guidance lists the failure conditions as "flat surfaces without
  texture, such as a white desk," "environments with dim lighting," "extremely bright environments,"
  and "transparent or reflective surfaces like glass." **[F]**
  <https://developers.google.com/ar/design/environment/definition>
- Apple's world-tracking doc: "Tracking quality is reduced when the camera can't see details, such as
  when the camera is pointed at a blank wall or the scene is too dark." **[F]**

A uniformly lit cloth — and especially the black cloth on the owner's test table — is exactly this
condition. **Coaching should aim the user at the rails, pockets, diamonds and balls, not at the
playing surface**, and the app must not gate the experience on plane detection over the cloth.

The corollary is a correctness bug waiting to happen: while tracking is `limited`, ARKit says "plane
detection does not add or update plane anchors; hit-testing methods provide no results." **[F]**
<https://developer.apple.com/documentation/arkit/managing-session-life-cycle-and-tracking-quality>
So corner taps *cannot* succeed in that state. Given this repo's standing rule that no guard may
silently swallow a tap, the calibration UI needs an explicit "not yet — hold steady" state rather
than a dropped touch.

### 2.3 What shipping AR apps actually do at launch

| App | Launch screen | Steps to value | Failure behaviour |
|---|---|---|---|
| **Apple Measure** | Live camera, a **dot reticle fixed at screen centre**, translucent controls. Guide says "Use the iPhone camera to slowly scan nearby objects," then align the dot and tap +. Edge guides appear automatically along straight edges. Best results at 0.5–3 m. Recovery is **Clear / start over**, not per-point undo. **[F]** <https://support.apple.com/guide/iphone/measure-dimensions-iphd8ac2cfea/ios> | 1–2 | reset |
| **Pokémon GO AR** | Prompt to enable AR on first encounter, then "Use your camera to slowly look around your surroundings, being sure to include a flat surface… **Tall grass will appear once your device has detected your environment.**" Failure copy: "When it's too dark, the camera may not see all the details." **[F]** <https://niantic.helpshift.com/hc/en/6-pokemon-go/faq/28-catching-pokemon-in-ar-mode/> | ~3 | diegetic |
| **Google Maps Live View** | "Point your phone camera at buildings and signs across the street, instead of trees and people." Calibration is entered deliberately (tap the blue dot → Calibrate). A "what to do if it doesn't work" list gives four preconditions. Framed as transient: "put away your phone once you know where to go." **[F]** <https://support.google.com/maps/answer/9332056> | 2 | precondition list + 2D fallback |
| **IKEA Kreativ** | Not live AR — a gated capture: "Hold your phone with both hands, pivot using your hands and forearms, and keep your elbows close to your body"; "sweep your phone in a slow and wide figure-8 motion"; ends with an explicit accept gate. **[F]** | 5–6 | re-scan |
| **magicplan** | "Point the device at your feet, then towards the ceiling" — a concrete, checkable instruction that happens to produce the parallax ARKit needs. Recovery copy is plain: "move to a part of the room with better lighting conditions and start moving your device in circles." **[F]** <https://help.magicplan.app/scan-a-room-in-seconds-using-lidar> | 2–3 | plain-language retry |
| **Snap Lenses** | A single auto-fading, all-caps hint from a **fixed vocabulary** the author cannot extend: LOOK AROUND, TAP A SURFACE, TAP GROUND TO PLACE, TURN AROUND, COME CLOSER. **[F]** <https://developers.snap.com/lens-studio/publishing/configuring/lens-hints> | 1 | none |
| **Polycam** | A device-and-space checklist **before the camera opens**: charge above 80%, "Enable Do Not Disturb… Even a brief notification pop-up can cause tracking loss," turn on all lights, cover mirrors. **[F]** | 2 | prevention |

Four patterns recur:

1. **Nobody shows a slide deck before the camera.** The camera view is the first screen. The one
   endorsed exception is a short environment-prep card sequence.
2. **The reticle is the onboarding.** Readiness is a small object changing state — Measure's dot,
   ARKit's focus square, magicplan's green corner indicator — not a sentence.
3. **Success is diegetic.** Grass grows. Walls get outlined. Nobody prints "plane detected."
4. **Instructions name the target, not the mechanism.** "Buildings and signs, not trees and people."
   "Start in a corner with a lot of details." Never "move the device to establish parallax."

Google's ARCore design guidance adds the transition rules: "Show users how to find a surface using
their phone. Use illustrations or animations"; "As users move their phones, give instant feedback to
show they've successfully detected a surface"; "When a user successfully finds a surface, tell them
what to do next"; and "Avoid pop-ups and full-screen takeovers unless the user explicitly selects
it." **[F]** <https://developers.google.com/ar/design/content/content-placement> ·
<https://developers.google.com/ar/design/interaction/ui>

ARCore also ships an idea worth stealing wholesale — **Instant Placement**: place the object
immediately with an estimated pose, rendered **grayscale**, and promote it to full colour once the
true pose is known. <https://developers.google.com/ar/develop/instant-placement> The CueSync analogue
is showing a provisional, visually degraded aim line straight away and promoting it on lock. This
also matches the HIG: "avoid waiting for more accurate data before placing an object… then, when
surface detection completes, subtly refine the object's position if necessary."

### 2.4 Camera permission

- ARKit "automatically asks the user for permission the first time your app runs an AR session," and
  `NSCameraUsageDescription` is required or the system terminates the app. Denial arrives as
  `ARError.Code.cameraUnauthorized`. **[F]**
- The HIG: "Avoid requesting permission at launch unless the data or resource is required for your
  app to function. People are less likely to be bothered by a launch-time request when it's obvious
  why you're making it." For an AR-first app, launch-time is defensible. **[F]**
  <https://developer.apple.com/design/human-interface-guidelines/privacy>
- **A priming screen is allowed but constrained**: "Include only one button and make it clear that it
  opens the system alert… Use a term like 'Continue' or 'Next'." And "Don't include additional
  actions… don't provide a way for people to leave the screen or window without viewing the system
  alert." Imitating the alert, showing a picture of it, or offering incentives are App Store
  rejection grounds (5.1.1(iv)). **[F]** The two-button "not now / OK" priming pattern popularised by
  the 2014 Cluster/TechCrunch post is **no longer HIG-compliant** — cite that post for the timing
  principle only. **[F]** <https://techcrunch.com/2014/04/04/the-right-way-to-ask-users-for-ios-permissions/>
- The current denial state in `RootView.swift` is a red caption capsule: "Camera access denied —
  enable it in Settings → CueSync AR". It should be a full-screen explainer with a button using
  `UIApplication.openSettingsURLString`, since a camera-denied AR app has nothing else to show.

---

## 3. First-run for "calibrate a pool table"

### 3.1 The honest risk: four taps is right at the abandonment threshold

Nielsen Norman Group ran usability tests on AR calibration with 11 participants and published ten
guidelines. Their framing matters: "Unlike onboarding, which usually needs to be done just once,
calibration will usually need to be included for every session." **[F]**
<https://www.nngroup.com/articles/ar-calibration/>

The ten, abbreviated, each tied to an observed failure:

1. **Low-granularity instructions, one at a time** — several at once "led to frustration and
   abandonment."
2. **Descriptive and unambiguous** — "scan a textured surface" made a participant scan chair
   upholstery.
3. **Enough time to read and execute** — instructions vanished mid-read.
4. **Visually salient** — near screen centre, contrasting, on a darker background, because "the
   background in an AR experience changes based on the user's environment."
5. **Visuals must augment, not contradict, the text** — an animation showing a device on a table
   while the text said floor.
6. **Consider audio when the device is far from the user.**
7. **Keep users informed of system state** — "I don't know what's going on right now."
8. **Clear, standard signifiers** — an explicit warning against raw feature-point dot clouds: "The
   dots were just confusing… they weren't helpful to me."
9. **Load AR objects within the field of view**, and guide the user back if they move.
10. **Feedback that supports error recovery** — "if I'm scanning it at a blank wall and it's not
    working, I need to know why."

And the direct warning, from their companion article on AR walkthroughs: **"The Best Buy app asked
the user to attach four stickers to the environment to calibrate the AR feature. One study
participant felt it was too much and skipped this part."** Her words: "It's asking so many
specifications to be, like, perfect." **[F]** <https://www.nngroup.com/articles/ar-walkthroughs/>

A four-corner cushion-nose tap is a harder task than four stickers. Every affordance that removes
work buys down that abandonment risk.

### 3.2 The dominant modern pattern: auto-propose, then let the human correct

This is near-universal across every category examined.

- **Apple Notes / Files document scan**: "If your device is in Auto mode, your document will
  automatically scan… Then drag the corners to adjust the scan to fit the page, then tap **Keep
  Scan**." Auto-detect → manual capture fallback → drag corners → **named commit**. **[F]**
  <https://support.apple.com/en-us/108963>
- **Adobe Scan**: live blue corner dots, three named guidance states — "Looking for document",
  "Capturing… hold steady", "No document found. Capture manually." — then crop handles plus an
  **Auto-Detect** button to re-run detection. **[F]**
- **Epson Quick Corner** (projector keystone): auto-adjust from physical corner-marker stickers, with
  Quick Corner still available for manual fine-tuning. Manual mode is two-stage — select a corner
  (keys 1/3/7/9 map to the four corners), press Enter, then adjust — and **a grey triangle shows when
  an axis can go no further**. Hold Esc to reset. **[F]**
- **Autodarts**: yellow markers dragged to named wire intersections, with an "Auto" button. **[F]**
- **Roborock zones**: spawn a default shape, then move and resize it — the user never places N
  independent points, and there is a stated capacity limit and a modal Save. **[F]**
- **Apple's own "Scanning and detecting 3D objects" sample** is a five-step named wizard —
  *Position the object* → *Define bounding box* (drag to move, press-and-hold a side to resize, "or
  if you leave the box untouched, the app will attempt to automatically fit a box around it") →
  *Scan* (highlights parts of the box to show coverage) → *Adjust origin* → **Test**, an explicit
  verification step before export. **[F]**
  <https://developer.apple.com/documentation/arkit/scanning-and-detecting-3d-objects>

Roadmap task **M6-06** already plans exactly this — a `VNDetectRectanglesRequest` pass that
auto-proposes the playing-field quad into the existing `adjusting` state. The research says this
should be **the primary path, not a later enhancement**, and that four cold taps should be the
fallback. `VNDetectRectanglesRequest` returns the four normalised corners of a quad with tunable
`minimumAspectRatio`, `maximumAspectRatio`, `minimumSize` and `quadratureTolerance` ("how many
degrees a rectangle corner angle can deviate from 90°") — which fits a table whose aspect ratio is
known. **[F]** <https://developer.apple.com/documentation/vision/vndetectrectanglesrequest>

### 3.3 Affordance inventory for the manual path

Every item below was confirmed in at least one shipping product.

| Affordance | Seen in |
|---|---|
| Screen-centre reticle + a separate Add button (device aims, thumb confirms) | Apple Measure; ARKit focus square **[F]** |
| A preview indicator showing where the next point will land | magicplan green corner indicator **[F]** |
| Dual input: auto-place **or** tap to place | magicplan **[F]** |
| Draggable corner handles on the quad | Apple Notes, Adobe Scan, Resolume, Cassapa **[F]** |
| **Named** corners, removing ordering ambiguity | Cassapa "4 numbered squares"; Epson 1/3/7/9; Autodarts wire intersections **[F]** |
| Coarse vs fine handles at the same corner (size hierarchy) | Resolume Arena **[F]** |
| Magnifier loupe while dragging | Dynamsoft `enableMagnifier`; Apple's public `UITextLoupeSession` (iOS 17+) **[F]** |
| Snapping / magnetic guides to detected edges | Scanbot magnetic lines; Apple Measure edge guides **[F]** |
| Per-axis limit feedback (grey arrow at the boundary) | Epson Quick Corner **[F]** |
| Explicit undo of the last point | magicplan undo arrow **[F]** |
| Global reset / start over | Apple Measure "Clear"; coaching overlay "Start Over"; HIG mandate **[F]** |
| Named commit rather than an implicit one | "Keep Scan", "Save", "Test" **[F]** |
| **Verification: draw the derived model back onto reality** | Autodarts segment edges over the real wires; the ARKit scanner's Test step; IKEA Kreativ's accept gate **[F]** |
| Progress toward "enough data" as a bar or percentage | Autodarts 95 % chessboard coverage; RoomPlan's live 3D model **[F]** |
| Loop closure terminates the sequence (aim at point 1 again) | magicplan **[F]** |
| Physical fiducials instead of taps | Epson magnets/stickers; Autodarts printed chessboard **[F]** |

**A "step N of M" counter could not be found in any shipping multi-point calibration UI.** **[U]** The
convention appears to be a named state plus a count of what is placed — which is what
`HUDStatus.placingCorners` already does ("Tap the cushion-nose corners (2/4)").

### 3.4 The verification step is the one CueSync is missing

Autodarts' best idea is not the dragging — it is the button afterwards that overlays the *derived*
geometry onto the *observed* image so the user can judge the fit against features they did not
calibrate with. CueSync has an exact equivalent available for free: from four cushion-nose corners
and a table size, the head string, the foot spot and the diamonds are all computable. Drawing them on
the cloth and asking "does the foot spot land on the real foot spot?" is a genuine check, not a
tautology, and it is a far better lock gate than the current "Drag dots onto the cushion noses, then
lock."

The existing copy is already good on the hardest point — it says **cushion nose**, not "corner",
which is the Autodarts "name the physical landmark" principle. Keep that. What is missing is a
picture: the phrase means nothing to a beginner, and a single diagram of a rail cross-section with
the nose marked would carry it.

---

## 4. The three modes

The owner named solo practice, playing a game with friends, and TV/spectator projection. These are
not three skins on one screen; they differ in **who holds the phone** and **who the overlay is for**.

### 4.1 The ergonomic fact that determines everything

You cannot hold a phone and shoot a pool shot at the same time. This is not a minor inconvenience —
it is the axis the three modes actually differ on.

- Research on co-located mobile AR identifies "the challenges of designing for the physical aspects
  of AR devices (e.g., holding smartphones)" as a key finding from a 41-participant study. **[F]**
  <https://arxiv.org/abs/2303.10546>
- The category critique is blunter: phone-held AR is "exhausting, hard on your eyes, back and arms,"
  and "VR looks underwhelming in video but is amazing in real-life, AR looks amazing in video but is
  underwhelming in real-life." **[F]**
  <https://packet39.com/blog/ar-app-sucks-current-sad-state-augmented-reality/>
- Every successful CV sports app in this research **mounts the phone**: HomeCourt makes "get a
  tripod" step 1 of onboarding; SwingVision sells a fence mount and treats a tripod as third-best;
  DrillRoom's one-line setup instruction is "a tripod… 5 feet above the ground"; Autodarts insists on
  "a tripod or phone holder rather than propping the device against something."

CueSync's roadmap and HUD currently assume a handheld device throughout. That assumption is doing a
lot of unexamined work.

**The three modes, restated by device position:**

| Mode | Phone | Overlay audience | Aim line timing |
|---|---|---|---|
| **Solo practice** | Handheld while sighting, then set down to shoot — or mounted | The shooter | Before the shot |
| **Game with friends** | Mounted or passed; the shooter is not the operator | Whoever is watching the screen | Contested (see below) |
| **TV / spectator** | Mounted; nobody looks at it | The room | **After** the shot |

### 4.2 Solo practice

This is the only mode where a live pre-shot aim line is uncontroversial, and it is where the
competitive wedge is. The differentiator is not the aim line — Bullseye Billiards already sells
400 drills at $69.99/yr — it is that **the table scores the drill**. Bullseye makes the user log cue
ball position by hand after every attempt. CueSync's tracker can do it. That is the product claim
worth building the practice mode around, and it matches roadmap M6-03's design (setup ghosts, the
tracker confirms placement, scoring from tracked rest positions with no spin simulation needed).

Design implications: a mounted "range" posture, drill setup ghosts, a one-tap "that wasn't real"
correction on any scored shot (ShotVision's reviewers had to delete bad readings manually, and
HomeCourt's "the app may say you missed even if you made it" is the same complaint), and a session
summary the user can look at with the phone back in their hand.

### 4.3 Playing a game with friends

This mode has a problem the other two do not: **an aim line shown to the shooter is a coaching aid,
and shown to the opponent it is an unfair one.** The video-game world has already settled the
convention — Miniclip's *8 Ball Pool* makes the guideline an upgradeable cue stat and a toggleable
setting, so "how much aim line you get" is an explicit, negotiated level of assistance. **[S]**
<https://support.miniclip.com/hc/en-us/articles/6630561650833--Settings-Guideline>

The practical design is a per-session assistance level agreed before play — the DigiCue precedent of
three named presets (Beginner / Intermediate / Advanced) rather than a settings sheet full of
toggles — and honesty that at the top setting the app is a teaching tool, not a match companion.

### 4.4 TV / spectator — and why it should not be a mirror

**The broadcast idiom for cue sports is not a persistent aim line.** BBC snooker coverage (produced
by IMG) uses Vizrt graphics plus **a Telestrator operated from the commentary box** — a human pundit
draws the line deliberately, "to enhance viewer enjoyment by predicting solutions to difficult pots."
**[F]** <https://www.svgeurope.org/blog/headlines/cue-the-ob-how-img-produces-snooker-coverage-for-the-bbc/>
Hawk-Eye was used in BBC snooker from 2007 but **was removed after 2015**; on the World Snooker Tour
it now appears mainly at China-based events and its job is administrative — helping a referee
re-spot a ball after a foul-and-a-miss. It has never adjudicated a snooker dispute. **[F]**
<https://en.wikipedia.org/wiki/Hawk-Eye>

The wider broadcast pattern is consistent: the graphics that are loved are **momentary**. Toptracer's
tracer exists only for the ball's flight. Tennis Hawk-Eye appears only on a challenge. The NFL's
yellow first-down line is the exception that proves the rule — it is persistent *and* it is
obsessively occlusion-correct: its defining achievement is that the graphic obeys "the visual rules
of foreground objects occluding background objects," with a per-venue colour palette built from
"various shades of green, depending on the type of surface… and the weather." **[F]**
<https://en.wikipedia.org/wiki/1st_%26_Ten_(graphics_system)> The counter-example is FoxTrax, the NHL
glowing puck: casual fans liked it, "hardcore fans did not," and it lasted two seasons. **[S]**

So the spectator screen differs from the player screen in four ways, and each is a design decision:

1. **Timing.** Spectators do not want the prediction before the shot — that spoils it. They want the
   result explained after. Player: predictive. TV: retrospective.
2. **Viewpoint.** A stable rendered top-down table beats the shooter's shaky first-person camera.
   `DisplayKit.ExternalTableView` already exists for this.
3. **Persistent context.** Score, ball-on, current run — clutter on the phone, essential on the TV.
4. **Latency tolerance.** This is the strongest architectural argument. AirPlay plus smart-TV video
   processing adds real delay, and the TV's own processing "can add 50–100 milliseconds" unless Game
   Mode is on **[S]**. A mirrored live AR feed makes that latency a visible defect; a spectator view
   made of score, table diagram and post-shot replay makes it invisible. **Design the TV view so
   latency does not matter.**

**Mechanism (iOS).** A distinct external view is a UIKit scene-session role, not a SwiftUI feature:
set `UIApplicationSupportsMultipleScenes`, add a scene configuration with role
`UIWindowSceneSessionRoleExternalDisplayNonInteractive`, and in the `UIWindowSceneDelegate` create a
`UIWindow` hosting a SwiftUI view, driven from shared observable state. **If you do not add a window
to that scene, the system mirrors instead** — mirroring is the default, not a choice. The external
view is non-interactive by design, which is exactly right for a spectator screen. AirPlay and a wired
adapter surface through the same path. **There is still no native SwiftUI way to mark a scene as
external.** **[F]** <https://cindori.com/developer/swiftui-external-display-ios> ·
<https://useyourloaf.com/blog/swiftui-supporting-external-screens/>

Reference implementation to imitate: **Keynote for iPad's presenter display** — the audience sees the
presentation, the operator keeps notes, timer and next-slide preview. **[S]** Reference
implementation not to imitate: **djay for iOS**, whose own support docs say it "will automatically
mirror the visual output to the external screen." **[S]**

Note the inversion relative to normal second-screen thinking: here the **phone** is the participant's
device and the **TV** is the companion, not the other way round. The general practitioner warning
about second screens — "every time you ask a viewer to pick up their phone… you're asking them to
leave the viewing experience" **[S]** — argues for a TV view that needs no interaction at all.

### 4.5 The mode picker in the HUD today is not this

`RootView.modeMenu` is an SF Symbol opening a three-item menu (free play / called shots / guided
drill), and the practice mode is orthogonal to camera flip, mirror, record and model picker sitting
beside it. The research says the mode choice is the *first* decision — it determines where the phone
goes and who the overlay is for — and should be made before or at the start of a session, not buried
in a row of eight equal-weight icons.

---

## 5. VR/AR glasses — an honest assessment

**Summary: on every shipping headset and every pair of glasses, a real-table pool coach is either
forbidden by platform policy, physically unwearable while shooting, or bandwidth-starved. Quest 3/3S
is the only platform where it is both permitted and technically possible, and it is still the wrong
device to wear while playing pool.** The repo's current position — "visionOS/tvOS are vision, not
targets" — is correct and should stay.

### 5.1 Apple Vision Pro — blocked by policy

- Main camera access requires the entitlement `com.apple.developer.arkit.main-camera-access.allow`
  plus an `Enterprise.license` file tied to the developer account. **[S]**
- An Apple engineer replying on the developer forums in **June 2026**: "There is no way to access the
  main camera outside of enterprise apis for visionOS." **[F]**
  <https://developer.apple.com/forums/thread/768144>
- Enterprise APIs can only be distributed as in-house or custom apps via Apple Business Manager —
  **not on the App Store**. **[S]**
- Non-enterprise apps get derived data only: hand/body skeletons, scene mesh, object tracking. Never
  passthrough frames. **[S]**
- One conflicting signal: a third-party WWDC26 visionOS lab writeup reports Apple engineers saying
  standard Developer Program accounts can *apply* for camera access for professional use cases.
  **[F on the page, but it is one attendee's notes, not documentation.]** These two accounts
  conflict; file a Feedback request before planning around it. **[U]**
- visionOS 27 adds high-frame-rate tracking of moving and handheld objects and a metric-space pose
  API. Whether a 57 mm untextured sphere qualifies as a trackable "object," and whether the API
  requires the camera entitlement, are **not documented**. Expect not — the framework is built around
  distinctive rigid objects trained from a 3D model, not fifteen near-identical spheres. **[U]**

Even if policy changed, the hardware does not fit the activity: the M5 model is **26.4–28.2 oz
(~750–800 g)**, heavier than its predecessor **[S]**, and Apple's own copy says "up to two and a half
hours of general use" **[F]** <https://www.apple.com/newsroom/2025/10/apple-vision-pro-upgraded-with-the-m5-chip-and-dual-knit-band/>
— against a 3–4 hour league night, tethered to a pocket battery while bending over a table.
Passthrough degrades exactly where pool lives: reviewers report visible motion blur on head movement
that "increases in low light, leading to some weird warping of straight lines." **[S]** A pool hall is
a dim room with a hot pool of light on the cloth.

The most on-point analogy found: reviewers of *Ping Pong Club* on Vision Pro note that using a real
physical paddle "simply doesn't make sense with Vision Pro, as a real paddle couldn't be aligned with
the virtual handle." **[S]** Substitute "cue stick."

### 5.2 Meta Quest 3 / 3S — permitted, and still wrong

- Passthrough Camera API shipped **experimental in v74 (March 2025)** and became **publishable to the
  Horizon Store in v76**. **[F]** <https://www.uploadvr.com/quest-passthrough-camera-api-experimental-out-now/>
- Current specs: left+right forward-facing RGB, **max 1280×1280, 60 Hz, capture latency 20–40 ms**,
  YUV420, ~1–2 % GPU per camera. **[F]**
  <https://developers.meta.com/horizon/documentation/spatial-sdk/spatial-sdk-pca-overview/>
- **Meta's own warning is the disqualifier:** the stream "isn't suitable for tracking fast moving
  objects, such as custom controllers, nor for discerning fine features like small text." **[F]**
- A mixed-reality billiards product exists — **MiRacle Pool** (Pixel Works Studios, ~$15, includes an
  arcade mode with an aiming aid) — but it renders a **virtual** table into your real room. **[S]**
  **No shipping product overlays coaching on a real physical pool table via any headset.** **[U]**

### 5.3 Smart glasses — the display layer is not a rendering surface

| Device | Display | Camera to third-party devs | Where the app runs |
|---|---|---|---|
| Ray-Ban Meta / Oakley Meta | none | via Wearables Device Access Toolkit | **on the phone** **[F]** |
| Meta Ray-Ban Display | monocular, **600×600, 20° FOV** | yes | on the phone **[S]** |
| Snap Specs (consumer) | yes | not documented **[U]** | on-device, **$2,195**, ships fall 2026 **[F]** |
| Snap Spectacles (2024 dev) | 46° diagonal | Lens Studio | on-device, **45 min battery** **[S]** |
| Even Realities G2 | narrow HUD | **no camera** | — **[S]** |

The Meta toolkit constraints settle it: the camera stream is **max 720p / 30 fps, limited by
Bluetooth bandwidth**, the app runs on the phone with the Meta AI app as a bridge, publishing is
**developer preview only** (up to 100 testers as of May 2026), and the display APIs expose "text,
images, lists, buttons, and video playback" — a **UI-components layer, not a world-locked 3D
rendering surface**. **[F]** <https://www.uploadvr.com/meta-wearables-device-access-toolkit-public-preview/>
· <https://developers.meta.com/wearables/faq/>

### 5.4 What would have to be true

1. World-locked 3D rendering, not a HUD (rules out every display-glasses product today).
2. Raw camera frames at ≥30 fps with intrinsics and pose, on a consumer distribution path.
3. Tracking a small, fast, near-featureless sphere — the thing Meta explicitly says its stream is not
   for. For scale: Hawk-Eye's advertised accuracy is **2.6 mm** with an official average error of
   **3.6 mm**, bought with 9–12 instrumented cameras and a frame-delayed video path. **[F]** That is
   roughly the implicit bar a player will judge an aim line against, and CueSync has no frame-delay
   budget at all because a live coach must be zero-latency.
4. A device wearable for three hours bent over a table. Nothing shipping clears this.
5. Passthrough that survives pool-hall lighting.
6. League legality — see below, where the answer is no.

---

## 6. Anti-patterns

### 6.1 The one that kills CV sports apps

Across DrillRoom, Railbird, HomeCourt and ShotVision the top complaint is identical and it is not
accuracy in the abstract — it is **accuracy under normal play conditions**, in three specific forms:

- **Occlusion by the player's own body.** DrillRoom: "walking around the table in front of the camera
  causes issues." HomeCourt: "the app can't see anything that's obstructed… like if someone is
  standing in between the camera and the shooter." **This is the number-one named complaint in the
  category and CueSync has no answer to it yet.**
- **Object-to-object contact semantics.** DrillRoom cannot see ball-on-ball contact; HomeCourt
  misreads the three-point line.
- **Losing the primary tracked object.** DrillRoom: "I can't see the cue ball." CueSync's
  tap-to-designate and stable BallTracker IDs are a direct answer to this one.

**ShotVision Launch Monitor** (3.5★ / 1.3K ratings) is the sharpest read on what happens when a CV
sports app ships anyway: "One in 10 would either not register or be obviously inaccurate"; erroneous
readings must be deleted afterward or stats are skewed; "the lowlight/indoor setting simply doesn't
work"; and "unless you pay for a subscription the app is basically useless." **[F]**
<https://apps.apple.com/us/app/shotvision-launch-monitor/id1352247118>

Two design rules fall straight out: **any CV app that writes to a stats history must offer a one-tap
"that wasn't real" delete**, and **never gate the core measurement output behind a paywall while
still asking the user to do all the setup work** — reviewers read that as bait-and-switch and it
shows up in the star rating.

### 6.2 Onboarding anti-patterns

From NN/G's walkthrough study (11 participants): baseline AR literacy is very low — eight of eleven
confused AR with VR, and only four had ever used AR. Findings: **[F]**

- Interactive walkthroughs beat static ones.
- The deck-of-cards format "often caused cognitive overload… Participants couldn't fully remember
  what they had read and had to refer to the help menu or relaunch the experience." So the
  walkthrough must remain **re-openable**.
- Three things must be covered: what to expect, **how to hold the device**, and how to prepare the
  environment. One participant left her phone flat on the table through a whole tutorial: "I thought
  it was just black and I was waiting for the tutorial to tell me what to do." The study names
  HomeCourt specifically for not telling users it wanted landscape orientation.
- Vague environment guidance fails: a participant told to "Move Closer" with no stop condition
  followed it "to the point where I was almost touching the wall."
- Apple has rejected AR apps for not providing instructions on how to use the app. **[S]**
- Apple's own HIG: "If it makes sense to offer a separate tutorial, consider making it optional…
  don't present it again on subsequent launches, but make sure it's easy for people to find if they
  want to view it later." **[F]**

### 6.3 Battery, heat, interruption

The category claim is well attested but not rigorously measured in any source found. **[S]** What is
concrete: HomeCourt reviewers report battery drain and screen blackouts mid-drill, and **an incoming
phone call ends a workout** — an interruption bug worth designing against explicitly. **[S]** ARKit's
own contract says a session is interrupted when it stops receiving camera or motion data, and that
you must **not** call `pause()` in response. **[F]**

### 6.4 Product risk: aiming aids are banned in league and tournament play

This is the most consequential non-UX finding in the research and it is unambiguous.

**CSI / BCAPL / USAPL** — *Official Rules of CueSports International* (the PDF filename indicates the
**2017-07-14** edition; verify against the current edition before relying on it). **[F, text extracted
from the PDF]** <https://www.playcsipool.com/uploads/7/3/5/9/7359673/official_rules_of_csi__170714_.pdf>

- Rule **1-3-1-f**: "You may use your cue, held in your hand or not, to help align a shot… **No other
  cues, bridges or equipment may be used.**"
- Rule **1-3-1-g**: "**You may only use your vision to judge** whether the cue ball or an object ball
  would fit through a gap, or to judge what ball the cue ball would contact first." Penalty for
  (f–g): "**Foul immediately upon the violation, regardless of whether a shot is executed.**"
- Rule **1-3-2**: "**You may not wear any electronic headgear, use any electronic device, or
  voluntarily impede your hearing during a match.**" Cell phones "may not be accessed for messages,
  information or conversations at any time during a match."
- Rule **1-41**: "Billiards-related written reference material, **or such material accessed through
  electronic means, may not be consulted during your match.**"

**APA World Pool Championships** — "**Laser devices, mechanical cues and training/practice aids may
not be used in Tournament play.**" Phones are prohibited while a player is at the table. **[F]**
<https://poolplayers.com/world-pool-championships/rules/>

**WPA rule text could not be retrieved** (the site serves PDFs that would not fetch). **[U]**

Three consequences:

1. CueSync is unambiguously **not legal during sanctioned CSI/BCAPL/USAPL or APA match play**. Three
   independent rules each prohibit it. This is not a grey area.
2. **This is a positioning constraint, not a death sentence.** Golf is the exact parallel: rangefinders
   with slope and launch monitors are banned in competition and support a large, healthy practice
   market. CueSync's category is practice, drills, coaching between matches — and spectator
   production, which touches no player-equipment rule at all because the graphic is shown to
   *spectators*, exactly the Toptracer/Hawk-Eye idiom.
3. Product implications: never market it as usable in league or tournament play; consider an explicit
   match/no-assistance mode; and treat the TV spectator view as the rules-clean surface it is.

### 6.5 Things this app should deliberately not do

- **Do not show a slide-deck tutorial before the camera.** Nobody successful does.
- **Do not print ARKit vocabulary.** "Tracking limited", "insufficient features", "plane detected",
  "MPSGraph", latency in milliseconds, and a raw model picker are debug-harness artifacts. Apple's HIG
  says so directly.
- **Do not show a bare feature-point dot cloud as a progress signal.** NN/G watched participants read
  it as a malfunction.
- **Do not show a confidence meter that reads green while detection fails.** DrillRoom's reviewers
  prove this is worse than no meter.
- **Do not put a permanent aim line on the TV.** No cue-sports broadcast does; FoxTrax is what happens
  when you leave a graphic on.
- **Do not mirror the live AR camera feed to the TV as the default.** Latency turns it into a defect.
- **Do not make the user re-tap four corners after every interruption.** Autodarts repositions without
  restarting the game; ARKit's coaching overlay handles relocalization and offers Start Over.
- **Do not silently swallow a tap.** During `limited` tracking, hit-testing returns nothing — say so.
- **Do not claim spin, english, or anything the solver does not simulate.** The roadmap's honesty rule
  already says this; the research says users punish it (HomeCourt's "may say you missed even if you
  made it" is the same trust break).

---

## 7. Guidelines for CueSync

Twelve rules, each tied to something in the research above.

1. **The camera is the first screen; the reticle is the tutorial.** Ship no slide deck before the
   camera. Readiness is a small object changing state — the way Measure's dot, ARKit's focus square
   and magicplan's green corner indicator all work. *(§2.3: every successful AR app examined opens on
   the live camera.)*

2. **Auto-propose the table quad; make four taps the fallback.** Run the `VNDetectRectanglesRequest`
   pass (roadmap M6-06) as the primary path and let the user correct the proposal. *(§3.2: NN/G
   watched a participant abandon Best Buy's four-sticker calibration outright; auto-then-correct is
   the dominant pattern in Apple Notes, Adobe Scan, Epson, Autodarts and Apple's own 3D scanner.)*

3. **Coach the user toward the rails, pockets and diamonds — never the cloth.** Both Apple
   (`lowTexture`) and Google name a featureless flat surface as *the* plane-detection failure case,
   and a uniformly lit cloth is precisely that. *(§2.2.)*

4. **Verify the calibration by drawing the derived geometry back onto reality before locking.**
   Compute the head string, foot spot and diamonds from the four corners and show them on the cloth;
   lock only after the user confirms they land where the real ones are. *(§3.4: Autodarts' segment-edge
   overlay and the ARKit scanner's Test step are both this idea.)*

5. **Say what to point at, in physical nouns, with a picture — never the mechanism.** "Cushion nose,"
   not "corner"; a rail cross-section diagram, not a sentence. Delete every string containing ARKit
   vocabulary. *(§2.1 and §2.3: Apple's do/don't copy table; Google's "buildings and signs, not trees
   and people"; Autodarts naming wire intersections.)*

6. **Every failure names a cause and an action; no state is silent, and none swallows a tap.** Adopt
   Apple's copy verbatim where it fits ("Try turning on more lights and moving around"), and give
   `limited` tracking an explicit "not yet" state instead of an inert touch. *(§2.2 and §6.2: NN/G
   guideline 10; HomeCourt's docs describe no failure path at all, which is the open lane.)*

7. **Show a provisional aim line immediately, visually degraded, and promote it on lock.** Do not make
   the user wait for a confident solution to see anything. *(§2.3: ARCore Instant Placement renders
   grayscale until the pose is known; the HIG says place first and refine later.)*

8. **Make the mode the first decision, not the sixth icon.** Solo / With friends / TV changes where the
   phone goes, who the overlay serves, and when the line appears. Present it as three named presets,
   not a settings sheet. *(§4: HomeCourt's step 1 is hardware posture; DigiCue ships three named
   presets usable with no app at all.)*

9. **Tell the user to put the phone down, and support it.** Add a mounted posture with framing guidance
   in the Autodarts Lens idiom — live pose corrections, then a green outline plus haptic on lock.
   *(§4.1: every shipping CV sports app mounts the device; a player cannot hold a phone and shoot.)*

10. **The TV view is retrospective, not predictive, and it is a separate scene — never a mirror.** Build
    it on the `UIWindowSceneSessionRoleExternalDisplayNonInteractive` path, show score/state plus
    post-shot replay, and design it so 100–200 ms of AirPlay latency is invisible. *(§4.4: cue-sports
    broadcast draws the line as a deliberate, momentary Telestrator act; iOS mirrors by default unless
    you add a window to that scene.)*

11. **Never score a shot the user cannot correct in one tap, and never claim more physics than the
    solver runs.** A "that wasn't real" gesture on any recorded result, and no spin claims.
    *(§6.1: ShotVision's users must delete bad readings by hand; DrillRoom's meters read green while
    detection fails.)*

12. **Position it as a practice and spectator tool, and say plainly it is not for match play.** CSI
    rules 1-3-1-f, 1-3-2 and 1-41 and the APA training-aid ban each prohibit it during sanctioned
    matches. Golf's rangefinder market shows this is a positioning constraint, not a dead end.
    *(§6.4.)*

**And the one thing to build after those:** an answer to occlusion. It is the top complaint in every
comparable product — DrillRoom, HomeCourt, ShotVision — and nothing in the tree addresses a player
standing between the camera and the table.

---

## What could not be verified

Listed so nobody re-researches it or, worse, treats a gap as a fact.

- **"Fusion Table"** (projector pool), **"SharkGrip"**, **"Shark Pool"** — searched; no such products
  found. Do not use these names.
- **"SnookerVision"** — no product by that name found.
- A Predator, BCA or CSI computer-vision app — none found.
- Any AR **aim trainer** for archery or shooting — only games and scorers.
- BilliardRadar's discontinuation date; DigiBall's official price and true shipping status (the vendor
  page and forum threads contradict); Scolia Home 2 hardware price; MagixPool and MyWebSport pricing;
  PoolLiveAid's commercial release status and calibration method.
- HomeCourt's current free-tier limits (sources conflict).
- Railbird's setup/calibration flow — no documentation found.
- Whether standard Apple Developer accounts can now apply for visionOS main-camera access — Apple's
  forums (June 2026) say enterprise-only; a WWDC26 lab writeup says otherwise. These conflict.
- Whether visionOS 27 object tracking can track pool balls; no documented object-count or minimum-size
  limits.
- Snap Specs developer camera access; Meta Wearables toolkit latency figures; whether that toolkit
  reached general availability during 2026.
- WPA world-standardized rule text on training aids and electronic devices.
- Apple Measure's current on-screen failure strings, and whether it supports drag-to-adjust of a
  completed measurement.
- IKEA Place's first-run copy; Amazon "View in Your Room" scanning instructions (the site blocked
  fetching); Google Maps Live View's verbatim calibration prompts.
- Any shipping **"step N of M" counter** in a multi-point spatial calibration UI.
- Any published battery-drain or rating-impact statistic specific to AR apps; any review-theme data
  specifically about up-front permission demands. Treat "ask in context" as best practice, not as an
  evidenced complaint theme.
- Second-screen usage statistics — the commonly cited figures are vendor blog content and are not
  cited here as fact.
