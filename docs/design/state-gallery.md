# State gallery

Every HUD state the Simulator can reach, one launch argument each, so a design
review can look at all of them without a pool table.

```
-seedScene <name>        Simulator + DEBUG builds only (App/Sources/DebugScenes.swift)
```

Nothing in a scene draws anything. A scene puts the app in a state through the
app's own entry points (the calibration controller's events, the table state
the live pipeline would publish, `noteOutputHealth`, the camera pose
`updateAim` takes from ARKit, the feedback centre's events, the real
recorder) and the HUD that results is the one a player gets. The scene list is
`DebugScenes.all`; each scene carries a one-line description.

Capture recipe (local only, never commit a still): build for the Simulator,
`simctl install`, then for each scene `agent-device open CQC.CueSync-AR
--relaunch --launch-args -seedScene --launch-args <name>`, wait, screenshot.
`-developerModeUnlocked YES` turns developer mode on for the sheets.

## Not reachable in the Simulator

| State | Why |
|---|---|
| Calibration overlay: corner handles, Lock and Cancel, size preview, the pocket-sighting prompts ("Tap the pocket you can see", "Use pockets") | `CalibrationOverlayView` and `CalibrationInviteCatcher` live inside `ARCameraView`, which is compiled out of Simulator builds (`#if canImport(ARKit) && !targetEnvironment(simulator)`) and projects world points through the AR session. The capsule states of the same flow ("Point at the table", corners 0 to 3 of 4, "Drag dots onto the cushion noses, then lock") ARE reachable and are scenes. |
| "Tap anywhere to calibrate" (a detector is loaded, no table locked) | Needs the hosted-detector preview (`selectedModel`, a Roboflow key). |
| Cue-ball guide words Follow, Left, Right | The app never produces them: `ShotGuide` recommends only centre (no tile), stun and draw. Showing them would mean drawing a view the app never shows. |
| Tapping a pocket to call it | `PocketCallCatcher` is AR-only. The scene calls the pocket through `togglePocketCall`, the function the tap ends in. |
| Anything over a live camera feed (contrast on a bright wall, glare) | The Simulator draws a placeholder. |
