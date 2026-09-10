# CueSync AR - Billiards Augmented Reality App

**[gitchrisqueen.github.io/CueSyncAR](https://gitchrisqueen.github.io/CueSyncAR/)** — what
this is, how it works, and where it honestly stands. Built from
[`docs/site/`](docs/site/) and deployed by
[`.github/workflows/pages.yml`](.github/workflows/pages.yml) on every push to `main`.

## Status (2026-09-10) — project paused

**Start with [`docs/HANDOVER.md`](docs/HANDOVER.md).** It is the honest
account of where this stands, the four findings that cost days to learn,
and what to do first. The roadmap in [`docs/roadmap/`](docs/roadmap/00-OVERVIEW.md)
describes a plan; the handover describes reality.

- **What runs:** eleven SwiftPM packages (physics, table geometry,
  perception pipeline, AR shell, UI, display routing, coaching), 26,051
  lines of source against 16,046 lines of tests, **874 package tests**
  passing on Linux and macOS, plus SwiftLint, secrets scanning, an iOS
  Simulator build and a golden replay in CI. The pure core has no device
  dependencies.
- **Calibration is the part that is finished.** Four taps on the pockets
  or the corners produce a table that closes to **5–8 mm rms** on the
  owner's 8 ft table, locking at 2.34 × 1.17 m. The cloth height is
  *solved* from the tap geometry rather than measured from the balls —
  the ball estimate ranged over 283 mm in one session and settled 158 mm
  wrong while reporting 8–15 mm of "spread". Before locking, the app
  draws the eighteen diamonds the calibration implies back onto the cloth
  so a person can check it against geometry the fit never used.
- **Device-verified, two sessions** (2026-07-23 and 2026-09-10, iPad, one
  8 ft table; `docs/validation/`): relocalization of a saved calibration
  in ~2 s across three relaunches, anchor-rooted overlays staying on the
  cloth, stick-based aiming at 86 % duty cycle, 60 fps camera, thermal
  nominal.
- **Measured negative results, stated as such:** on-device detection is
  **blind to a ball at shot speed** (only rest positions are captured);
  the cue ball is identified in **41 % of frames**; the aim line is
  available in **42 % of aimed frames**. These are why the drill design
  scores from rest transitions rather than from watching the ball move.
- **Not built:** onboarding, TV output (`DisplayKit` exists as a package
  and is referenced by zero lines of `App/Sources`), automatic table
  detection, guided-drill content, and any record that survives a
  session. There is no accuracy number on real data, because nothing has
  ever been tape-measured — that trip is the single highest-value thing
  left and is item 2 of the handover.
- **Platforms:** iOS 26. Builds for iPhone and iPad; **has only ever been
  run on an iPad**. visionOS/tvOS are vision, not targets.

Claims about accuracy carry a measured number and a run link, or they are
not made.

## Overview

CueSync AR is an iOS app designed to provide an immersive and educational experience for billiards enthusiasts using Augmented Reality (AR) technology. The app focuses on real-time object detection, trajectory projection, and spatial awareness to enhance the user's understanding and skills in playing billiards.

## Project plan (2026)

The full modernization & MVP roadmap — architecture, module specs, testing
strategy, UX design, milestones, and the parallel-agent development playbook —
lives in [`docs/roadmap/`](docs/roadmap/00-OVERVIEW.md). The features below
describe the product vision; the roadmap describes how we get there.

## Status

This is a work in progress, not a shipping app. What is in the tree today:

- Eleven local SwiftPM packages under [`Packages/`](Packages/) (domain types,
  physics solver, table calibration math, perception pipeline, AR shell,
  external-display routing, UI components, coaching, a hosted-API detection
  adapter, and test support), each with Swift Testing suites that run on
  macOS and Linux in CI.
- A thin SwiftUI app shell under [`App/`](App/) that wires the packages
  together: camera feed, four-corner table calibration, on-device ball
  detection from the bundled `BallDetector.mlpackage`, live aim and
  trajectory overlays, a practice-mode picker (free play, called shots,
  guided drill), and a LAN debug mirror.

What is not done yet is tracked as GitHub issues, grouped by phase, and
summarised in [`docs/HANDOVER.md`](docs/HANDOVER.md): guided-drill
content, the external-display window wiring in the app target (still not
referenced from `App/Sources`), TV-mode styling, onboarding, the device
checklist at a real table, and App Store hardening. The bundled Core ML
model is pinned to CPU-only inference on iOS 26 until it is re-exported.

Overlay positions previously sat a few centimetres off the real balls.
That is now understood: the plane the taps were cast against was up to
158 mm out, because it was being measured from the apparent size of the
balls. The height is solved from the tap geometry instead, and the same
taps that were 34 cm out now close to 5 mm. Whether that fixes ball
placement end-to-end is untested — it needs the table trip.

## Features

### 1. Augmented Reality (AR) Object Detection

- Uses ARKit and Core ML (via Vision) to detect billiard balls and the cue stick in the live camera feed.
- Ships a bundled, fine-tuned on-device model (`App/Resources/BallDetector.mlpackage`); an optional hosted-API adapter exists for A/B evaluation of candidate models (see [`docs/model-testing.md`](docs/model-testing.md)).
- Tracks detected balls into a table-space coordinate system for further analysis and interaction.

### 2. Trajectory Projection

- Calculates the trajectory of the cue ball and object balls in real time with a pure Swift solver (`Packages/BilliardsPhysics`).
- Uses ARKit and RealityKit to draw projection lines, the ghost ball, and pocket highlights on the AR view.
- Shows a coaching card with the cut angle and tip-offset guidance for the current shot.

### 3. User Interface (UI)

- Built with SwiftUI and the Observation framework; reusable HUD components live in `Packages/CueSyncUI`.
- Displays calibration status, ball counts, the current shot guide, and the practice-mode picker.
- Intended to be extended with further game modes as the roadmap progresses.

### 4. Flexibility for Games and Drills

- Modular package architecture so games and drills can be added as pure, testable logic (`Packages/CoachKit` holds the practice-mode framework today).
- Free play and called shots (tap a pocket during live tracking) work now; guided-drill content is planned and is the largest single piece of unbuilt product ([issues #79–#90](https://github.com/gitchrisqueen/CueSyncAR/issues/79)).
- Full game rules engines (for example 8-ball) are on the post-MVP backlog.

### 5. Projection to External Display (planned)

- The routing state machine and table-view scene for a TV or projector output exist in `Packages/DisplayKit`; the window-scene wiring in the app target has not landed yet (`App/Sources` does not reference `DisplayKit` today; 06-MILESTONES.md records the package side, M4-01, as merged).
- Locating and aligning with a projector's position in the physical space is planned as roadmap M6-05 (`docs/roadmap/08-PRACTICE-MODES.md`), listed as post-MVP backlog item 6 in `docs/roadmap/06-MILESTONES.md`.

### 6. Compatibility

- The app target builds for iPhone and iPad (iOS 26 minimum). It has only ever been *run* on an iPad — every device artifact in this repo is `iPad12,1`, and the MVP's own platform sentence names an iPhone.
- visionOS and tvOS are on the post-MVP backlog; there is no target for either today.

## Getting Started

Requirements: macOS with **Xcode 26+** and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). The Xcode project is generated, not committed.

1. Clone the repository: `git clone https://github.com/gitchrisqueen/CueSyncAR.git`
2. Generate the project: `Scripts/bootstrap.sh`
3. Open `CueSyncAR.xcodeproj`, then build and run.

AR and the camera require a **physical iPhone/iPad** (iOS 26+); the Simulator
shows a placeholder. Package logic can be tested anywhere Swift 6.1+ runs:

```sh
Scripts/test-all.sh
```

## Contributing

If you'd like to contribute to CueSync AR, please follow the guidelines in [CONTRIBUTING.md](CONTRIBUTING.md).

## License

This project is licensed under the [MIT License](LICENSE).

## Acknowledgments

- Thanks to the open-source community for the tools and frameworks used in this project.

## Contact

For questions or feedback, please open a [GitHub issue](https://github.com/gitchrisqueen/CueSyncAR/issues).
