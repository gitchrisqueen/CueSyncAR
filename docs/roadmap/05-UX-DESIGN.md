# 05 — UX & Visual Design (2026)

Design north star: **the table is the interface.** Screen chrome is minimal,
translucent, and stays out of the camera's way; all primary information lives
*on the table* as spatial overlays. The app should feel like a broadcast-TV
shot tracer you're holding in your hand.

## Design system

- **Materials:** iOS 26 design language — translucent "Liquid Glass"-style
  materials for every HUD surface (`.glassEffect()` / thin materials with
  vibrancy), never opaque panels over the camera feed. Controls float in a
  single bottom glass bar; transient status uses a top-center capsule.
- **Color tokens** (`CueSyncUI.Theme`):
  - `feltGreen` accent family for confirmations/pocket highlights,
  - `cueAmber` for the aiming line,
  - `chalkBlue` for the cue-ball path after contact,
  - `warnCoral` for errors/scratch (cue ball pocketed) predictions,
  - all tokens defined for light/dark and validated for contrast ≥ 4.5:1
    against live camera feeds (tested over bright cloth and dark rooms with a
    subtle scrim behind text).
- **Typography:** SF Pro / SF Rounded for numerics; Dynamic Type throughout;
  monospaced digits for live measurements.
- **Iconography:** SF Symbols 7 only; no custom icon fonts.
- **Motion:** springs (`.snappy` / `.smooth`), 120 Hz-aware; overlay changes
  animate ≤ 250 ms; trajectory lines use a slow animated dash "flow" toward
  the pocket to signal direction without arrowheads.
- **Haptics:** soft tick when calibration locks; success haptic when a
  predicted pocket lines up (rate-limited); nothing during continuous aiming.

## First-run & calibration flow

1. **Welcome (one screen, skippable):** single sentence + camera permission
   request with a plain-language purpose string.
2. **Find the table:** live camera immediately (no menus). Coach mark capsule:
   "Point at the table". Detected plane shimmers subtly on the cloth.
3. **Confirm the rails:** the detected playing-field rectangle glows; four
   corner handles let the user pinch-drag if detection is off; table size
   auto-badge ("9-ft table") tappable to override. One tap on **Lock** ✓.
4. **Ready:** balls pop in with a staggered halo animation as tracking
   stabilizes; ball-count chip ("16 balls") confirms coverage.

Rules: never show a spinner over the camera; every wait state has a live
preview and a one-line instruction; calibration is re-enterable from the HUD
at any time; a returning user at a saved venue skips to step 4 via persisted
world anchors.

## Aiming experience (the core loop)

- **Aim line** (`cueAmber`): from cue ball along the player's sighting
  direction (device-pose derived). Rendered as a thin rounded tube lying on
  the cloth, subtle glow, occlusion-correct against balls (RealityKit
  occlusion so lines pass *behind* balls, not through them).
- **Ghost ball:** translucent outline sphere at the predicted contact point —
  the single most instructive element for players.
- **Object-ball path** (`feltGreen`) with cushion bounce points marked by
  small chevrons; **cue-ball path after contact** (`chalkBlue`, dashed).
- **Pocket alignment:** when the object-ball path enters a pocket's capture
  window, that pocket renders a soft pulsing ring + the path solidifies;
  haptic tick. A predicted scratch turns the cue path `warnCoral`.
- **Confidence honesty:** when tracking quality degrades (fast motion, low
  light), overlays fade to 40% and the status capsule explains why ("Hold
  steady…"). Never show a confident line the system isn't confident in.
- **Mini-map (optional toggle):** 2D top-down table in a corner glass card —
  the same renderer DisplayKit uses — for shots where the phone can't see the
  whole table.

## HUD layout

```
┌────────────────────────────────────┐
│        [status capsule]            │   transient: tracking / hints
│                                    │
│         (camera + AR overlays)     │   the table IS the UI
│                                    │
│  [mini-map]                        │   optional, bottom-left glass card
│   [ ⟳ recal ] [ ● balls:16 ] [ ⚙ ]│   single bottom glass bar
└────────────────────────────────────┘
```

No nav stacks in the live view. Settings is a sheet. Everything reachable in
one thumb tap; hit targets ≥ 44 pt.

## External display ("TV mode")

- On AirPlay/HDMI connect: a glass toast offers **Mirror** or **Table View**.
- **Table View** (default after first use): full-bleed top-down rendered
  table — rich felt texture, correct ball colors/numbers, live positions,
  trajectory predictions — styled like broadcast graphics (subtle vignette,
  large 10-foot-readable labels, no phone chrome, no camera noise). 60 fps,
  4K-aware.
- Phone keeps the AR view; a small "TV" indicator shows the external scene is
  live. Disconnection is seamless (no modal).

## Accessibility

- VoiceOver: HUD fully labeled; spoken shot summary on demand ("Three ball,
  cut left, lined up with corner pocket").
- Dynamic Type through XXL on all non-AR chrome; Reduce Motion disables dash
  flow and pulse animations; Reduce Transparency swaps glass for solid fills;
  color choices double-encoded (dash patterns differ per path, not just hue)
  for color-vision deficiency.
- Left/right-handed HUD flip in settings.

## Design QA gates

- Snapshot suite covers every component in light/dark × Dynamic Type ×
  Reduce Transparency (CI).
- Milestone device runs include an outdoor-bright and a dim-bar lighting pass.
- Any new HUD element must justify itself against the "table is the
  interface" rule in its PR description.
