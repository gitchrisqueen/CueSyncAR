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
| The recorder's numbers (frames, megabytes, a running clock) | The recording scene starts the real recorder, but no AR frames arrive in the Simulator, so the badge sits at "REC 0:00". The scene puts the table back after the recorder restarts the (absent) pipeline. |
| A streak banner | The HUD shows a run on the score chip ("3 of 3 made · 3 in a row") and the More sheet shows the best streak; there is no separate streak banner. |

Scenes that play shots (`shot-*`, `scoreboard`, `sheet-more-scored`) wait three
seconds after seeding so the sampler's lock tick (which zeroes the score) and
the "Table locked" pill have already happened.

## Scenes added for the truth pass

`banner-tracking-lost` now sets ARKit's tracking condition first, as the app
does, so the screen is the amber capsule alone (no tick, no card, no pill).
`called-off-line-aimed` calls the suggested shot's pocket with the aim a
little off ("Off line — move your aim right"). `ball-unknown` seeds balls
with neither number nor colour (the card says BALL). `cue-ball-only` and
`one-ball` are the two readings of "one ball": only the cue ball ("No balls to
shoot at") and one object ball ("Tracking 1 ball"). Every ball count is
object balls: a full rack is 15.

## Scenes for the called-shot pass

`called-on-line`, `called-off-line-aimed`, `called-off-line` (a pocket the ball
cannot go into is called: the slot says so), `called-no-shot` and
`blocked-called` (a blocked pick with a pocket called: the reason is for that
pocket). `losing-balls-lowlight` is the dim-room variant of `losing-balls`
(it was `losing-balls-dark`, a name that read as the dark appearance).
