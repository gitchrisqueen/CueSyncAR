# CueSync AR - Billiards Augmented Reality App

## Status (2026-09)

- **What runs:** eleven SwiftPM packages (physics, table geometry, perception pipeline, AR shell, UI,
  display routing, coaching), Swift Testing suites on Linux and macOS, SwiftLint and secrets
  scanning in CI. The pure core (physics, calibration math, tracking) has no device dependencies.
- **Device-verified, one session (2026-07-23, iPad, one 8 ft table —
  `docs/validation/2026-07-23-T1-device-verification.md`):** relocalization of a saved calibration
  (2 s on three consecutive relaunches), anchor-rooted overlays staying on the cloth after
  relocalization (before/after photos in the same folder), stick-based aiming engaging with the cue
  on the table (86 % duty cycle after the hold fix), and the debug mirror as the observation path.
  On-device ball detection runs CPU-only and was shown to be **blind to a ball at shot speed**
  (only rest positions are captured) — a documented negative result, not a verified feature.
- **Not yet:** pocket calling, predicted-vs-actual bank paths (one uncalibrated data point so
  far), overlay accuracy and physics tuning. These are being validated against recorded sessions
  and a synthetic ground-truth harness (`docs/roadmap/`), driven by an autonomous agent loop
  (`docs/agent-runner.md`). Claims about accuracy carry a measured number and a run link, or they
  are not made.
- **Platforms:** iOS 26 on iPhone/iPad. visionOS/tvOS are vision, not targets.

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

What is not done yet is tracked in
[`docs/roadmap/06-MILESTONES.md`](docs/roadmap/06-MILESTONES.md) and
[`docs/roadmap/09-SESSION-STATE.md`](docs/roadmap/09-SESSION-STATE.md).
Open items from those documents, plus one gap visible in the tree:
guided-drill content, the external-display window wiring in the app target
(not yet referenced from `App/Sources`), TV-mode styling, a settings screen,
the device checklist at a real table, and App Store hardening are all open.
The bundled Core ML model is pinned to CPU-only inference on iOS 26 until
it is re-exported. Overlay positions still sit a few centimetres off the
real balls.

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
- Free play and called shots (tap a pocket during live tracking) work now; guided-drill content is planned (roadmap M6-03).
- Full game rules engines (for example 8-ball) are on the post-MVP backlog.

### 5. Projection to External Display (planned)

- The routing state machine and table-view scene for a TV or projector output exist in `Packages/DisplayKit`; the window-scene wiring in the app target has not landed yet (`App/Sources` does not reference `DisplayKit` today; 06-MILESTONES.md records the package side, M4-01, as merged).
- Locating and aligning with a projector's position in the physical space is planned as roadmap M6-05 (`docs/roadmap/08-PRACTICE-MODES.md`), listed as post-MVP backlog item 6 in `docs/roadmap/06-MILESTONES.md`.

### 6. Compatibility

- The app target builds for iPhone and iPad (iOS 26 minimum).
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
