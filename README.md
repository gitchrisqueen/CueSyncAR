# CueSync AR - Billiards Augmented Reality App

## Overview

CueSync AR is an iOS app designed to provide an immersive and educational experience for billiards enthusiasts using Augmented Reality (AR) technology. The app focuses on real-time object detection, trajectory projection, and spatial awareness to enhance the user's understanding and skills in playing billiards.

## Project plan (2026)

The full modernization & MVP roadmap — architecture, module specs, testing
strategy, UX design, milestones, and the parallel-agent development playbook —
lives in [`docs/roadmap/`](docs/roadmap/00-OVERVIEW.md). The features below
describe the product vision; the roadmap describes how we get there.

## Features

### 1. Augmented Reality (AR) Object Detection

- Utilizes ARKit and Core ML to perform real-time object detection for billiard tables and balls.
- Integrates a pre-trained machine learning model for accurate and efficient object recognition.
- Handles detected objects for further analysis and interaction.

### 2. Trajectory Projection

- Calculates and visualizes the trajectory of billiard balls in real time.
- Uses ARKit to draw projection lines on the AR view to guide users on potential ball movements.
- Provides an intuitive representation of recommended angles for striking the cue ball.

### 3. User Interface (UI)

- Implements a user-friendly interface using UIKit for seamless interaction.
- Displays information about recommended angles, current cue ball alignment, and game/drill options.
- Customizable and extensible for future features and game modes.

### 4. Flexibility for Games and Drills

- Designed with a modular architecture to easily incorporate various billiards games and drills.
- Allows users to practice and enhance their billiards skills in a structured and engaging manner.
- Enables the addition of new game modes through future updates.

### 5. Projection to External Display

- Supports broadcasting of AR content to external displays or projectors.
- Utilizes ARKit features to locate and align with the projector's position in the physical space.
- Enhances the app's versatility for instructional purposes and group activities.

### 6. Compatibility

- Works seamlessly on iOS mobile phones and iPads.
- Compatible with Apple's VisionOS and tvOS for a consistent AR experience across different Apple devices.

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
- Special thanks to contributors for their valuable input.

## Contact

For questions or feedback, please contact the development team at [email@example.com].

