//
//  DebugScenes.swift
//  CueSync AR
//
//  The state gallery: one launch argument per HUD state, so every state a
//  player can see can be put on the Simulator's screen and photographed.
//
//    launch argument   -seedScene <name>       (names: DebugScenes.all)
//
//  Simulator and DEBUG builds only, compiled out of everything else, so a
//  player's build is unchanged.
//
//  Nothing here draws anything. Each scene feeds the app's own entry points
//  with data: the calibration controller's events, the table state the live
//  pipeline would publish, `noteOutputHealth` for the health verdicts, the
//  camera pose `updateAim` takes from ARKit, the feedback center's events,
//  and the real recorder. The HUD it then shows is the one the app draws.
//
//  What the Simulator cannot reach, and why, is in docs/design/state-gallery.md.
//

#if DEBUG && targetEnvironment(simulator)

import CoachKit
import CueSyncCore
import CueSyncUI
import Foundation
import PerceptionKit
import simd
import TableSpace

enum DebugScenes {

    /// One scene: its name on the launch line, what it shows, and how to
    /// put the app in it.
    struct Scene {
        let name: String
        let about: String
        let run: @MainActor (SessionModel) async -> Void
    }

    /// Every scene, in the order the gallery's INDEX lists them.
    static let all: [Scene] = calibration + tiers + shotStates + health + outcomes + modes + sheets

    static func scene(named name: String) -> Scene? { all.first { $0.name == name } }

    // MARK: - Calibration (the capsule states; the overlay is AR-only)

    /// The nine-foot field's corners in world space (the calibration's
    /// table frame lies on world x / z).
    private static let corners = [Vec3(-1.27, 0, -0.635), Vec3(1.27, 0, -0.635),
                                  Vec3(1.27, 0, 0.635), Vec3(-1.27, 0, 0.635)]

    @MainActor
    private static func calibrating(_ model: SessionModel, corners placed: Int?) {
        model.beginCalibration()
        guard let placed else { return }
        model.calibrationPlaneDetected()
        for corner in corners.prefix(placed) {
            model.placeCorner(corner, planeNormal: Vec3(0, 1, 0))
        }
    }

    static let calibration: [Scene] = [
        Scene(name: "launch", about: "Launch, not calibrated: no table yet") { _ in },
        Scene(name: "calibrate-find", about: "Calibration begun: point at the table") { model in
            calibrating(model, corners: nil)
        },
        Scene(name: "calibrate-corners-0", about: "Plane found, no corner placed (0/4)") { model in
            calibrating(model, corners: 0)
        },
        Scene(name: "calibrate-corners-2", about: "Two corners placed (2/4)") { model in
            calibrating(model, corners: 2)
        },
        Scene(name: "calibrate-corners-3", about: "Three corners placed (3/4)") { model in
            calibrating(model, corners: 3)
        },
        Scene(name: "calibrate-adjust", about: "Four corners: drag the dots, then lock") { model in
            calibrating(model, corners: 4)
        },
        Scene(name: "lock-banner", about: "The table just locked: the lock banner") { model in
            model.feedback.bannerHoldOverride = 3600
            model.seedScene(layout: "open")
        },
    ]

    // MARK: - Shot tiers and labels

    /// The seeded layouts and groups that rank an EASY, a FAIR and a HARD
    /// best shot on this head (the tests of the ranking own the tiers; this
    /// only picks the data that reaches each one).
    static let tiers: [Scene] = [
        Scene(name: "tier-easy", about: "Best shot, EASY") { model in
            model.seedScene(layout: "open", group: .any)
        },
        Scene(name: "tier-fair", about: "Best shot, FAIR") { model in
            model.seedScene(layout: "fair", group: .any)
        },
        Scene(name: "tier-hard", about: "Best available, HARD") { model in
            model.seedScene(layout: "open", group: .solids)
        },
        Scene(name: "label-your-pick", about: "Your pick: the player tapped a ball") { model in
            model.seedScene(layout: "open", group: .any)
            model.pickAnotherBall()
        },
        Scene(name: "label-your-pick-hard", about: "Your pick, HARD") { model in
            model.seedScene(layout: "open", group: .solids)
            model.pickAnotherBall()
        },
    ]

    // MARK: - Shot states

    static let shotStates: [Scene] = [
        Scene(name: "no-clean-shot", about: "No clean shot: try a safety") { model in
            model.seedScene(layout: "blocked")
        },
        Scene(name: "blocked-shot", about: "The player picked a ball that is blocked") { model in
            model.seedScene(layout: "pickblock")
            model.pickAnotherBall(preferring: BallID(4))
        },
        Scene(name: "ball-unknown", about: "Balls with no number and no colour: the card says BALL, invents nothing") { model in
            model.seedScene(layout: "unknownballs")
        },
        Scene(name: "no-cue-ball", about: "No cue ball: place the cue ball") { model in
            model.seedScene(layout: "nocue")
        },
        Scene(name: "break-rack", about: "A full rack: break the rack") { model in
            model.seedScene(layout: "rack")
        },
        Scene(name: "guide-stun", about: "Aiming a straight shot: the Stun tile") { model in
            model.seedScene(layout: "straight")
            model.aim(at: Vec2(0.5, 0.25))
        },
        Scene(name: "guide-draw", about: "Aiming into a scratch: the Draw tile") { model in
            model.seedScene(layout: "scratch")
            model.aim(at: Vec2(-0.829, 0.307))
        },
        Scene(name: "guide-centre", about: "Aiming a medium cut: centre ball, no tile") { model in
            model.seedScene(layout: "open")
            // A 20 degree cut on the 3-ball: the guide says centre ball, so no tile.
            model.aim(at: Vec2(0.2415, 0.3181))
        },
    ]

    // MARK: - Health states

    static let health: [Scene] = [
        Scene(name: "table-moved", about: "Table moved? Re-calibrate") { model in
            model.seedScene(layout: "rack")
            model.feedCalibrationHealth(detections: 15, offTable: 14)
        },
        Scene(name: "low-light", about: "ARKit: need more light") { model in
            model.seedScene(layout: "open")
            model.trackingCondition = .insufficientFeatures
        },
        Scene(name: "hold-steady", about: "ARKit: hold steady") { model in
            model.seedScene(layout: "open")
            model.trackingCondition = .excessiveMotion
        },
        Scene(name: "table-lost", about: "ARKit: re-finding the table") { model in
            model.seedScene(layout: "open")
            model.trackingCondition = .relocalizing
        },
        Scene(name: "losing-balls", about: "Only seeing 6 of 15 balls: amber capsule, no card") { model in
            model.seedScene(layout: "rack")
            model.feedDetectionHealth(peak: 15, now: 6, luminance: 0.6)
        },
        Scene(name: "losing-balls-lowlight", about: "Only seeing 6 of 15 balls in a dim room: more light would help") { model in
            model.seedScene(layout: "rack")
            model.feedDetectionHealth(peak: 15, now: 6, luminance: 0.15)
        },
        Scene(name: "losing-one-of-fifteen", about: "Only seeing 1 of 15 balls: must not look healthy") { model in
            model.seedScene(layout: "rack")
            model.feedDetectionHealth(peak: 15, now: 1, luminance: 0.6)
        },
        Scene(name: "cue-ball-only", about: "Only the cue ball on the table: no balls to shoot at") { model in
            model.seedScene(layout: "oneball")
        },
        Scene(name: "one-ball", about: "One object ball: Tracking 1 ball") { model in
            model.seedScene(layout: "oneobject")
        },
    ]

    // MARK: - Outcomes (banners, score, streak)

    static let outcomes: [Scene] = [
        Scene(name: "shot-made", about: "A made shot: banner and score") { model in
            await model.seedAndSettle(layout: "open", scoreboard: true)
            model.feedback.bannerHoldOverride = 3600
            model.simulateShot(result: "made")
        },
        Scene(name: "shot-streak", about: "Made shots in a row: streak") { model in
            await model.seedAndSettle(layout: "open", scoreboard: true)
            model.feedback.bannerHoldOverride = 3600
            for _ in 0..<3 where model.activeShot != nil {
                model.simulateShot(result: "made")
                try? await Task.sleep(for: .milliseconds(1700))
            }
        },
        Scene(name: "shot-missed", about: "A missed shot: banner") { model in
            await model.seedAndSettle(layout: "open", scoreboard: true)
            model.feedback.bannerHoldOverride = 3600
            model.simulateShot(result: "missed")
        },
        Scene(name: "shot-scratch", about: "The cue ball was pocketed") { model in
            await model.seedAndSettle(layout: "open", scoreboard: true)
            model.feedback.bannerHoldOverride = 3600
            model.simulateShot(result: "scratch")
        },
        Scene(name: "scoreboard", about: "The scoreboard chip after a made and a missed shot") { model in
            await model.seedAndSettle(layout: "open", scoreboard: true)
            model.simulateShot(result: "made")
            try? await Task.sleep(for: .milliseconds(1700))
            if model.activeShot != nil { model.simulateShot(result: "missed") }
        },
        Scene(name: "sheet-more-scored", about: "The More sheet with a score: shots made and best streak") { model in
            await model.seedAndSettle(layout: "open", scoreboard: true)
            for _ in 0..<2 where model.activeShot != nil {
                model.simulateShot(result: "made")
                try? await Task.sleep(for: .milliseconds(1700))
            }
            model.openSheet("more")
        },
        Scene(name: "scoreboard-empty", about: "The scoreboard chip before any shot") { model in
            model.seedScene(layout: "open", group: .any, scoreboard: true)
        },
        Scene(name: "banner-tracking-lost", about: "Tracking lost: amber capsule, no card, no pill") { model in
            await model.seedAndSettle(layout: "open")
            model.feedback.bannerHoldOverride = 3600
            // What the app does: ARKit loses the table, the status says so,
            // and the feedback event fires. The event draws no pill: the
            // capsule carries the message.
            model.trackingCondition = .relocalizing
            model.postFeedback(.trackingLost, force: true)
        },
        Scene(name: "banner-tracking-recovered", about: "Banner: tracking recovered") { model in
            await model.seedAndSettle(layout: "open")
            model.feedback.bannerHoldOverride = 3600
            model.postFeedback(.trackingRecovered, force: true)
        },
        Scene(name: "banner-calibration-refused", about: "Banner: the lock was refused") { model in
            await model.seedAndSettle(layout: "open")
            model.feedback.bannerHoldOverride = 3600
            model.postFeedback(.calibrationRefused, detail: "Those corners do not make a table", force: true)
        },
    ]

    // MARK: - Practice modes and recording

    static let modes: [Scene] = [
        Scene(name: "called-no-pocket", about: "Called shots: no pocket called yet") { model in
            model.seedScene(layout: "straight", mode: .calledShots)
            model.aim(at: Vec2(0.5, 0.25))
        },
        Scene(name: "called-on-line", about: "Called shots: pocket called, on line") { model in
            model.seedScene(layout: "straight", mode: .calledShots)
            model.callPocket(near: Vec2(1.27, 0.635))
            model.aim(at: Vec2(0.5, 0.25))
        },
        Scene(name: "called-off-line-aimed", about: "Called shots: aim a little off the called pocket: which way") { model in
            model.seedScene(layout: "straight", mode: .calledShots)
            model.callPocket(near: Vec2(1.27, 0.635))
            model.aim(at: Vec2(0.5, 0.31))
        },
        Scene(name: "called-off-line", about: "Called shots: a different pocket called, aim at the ball") { model in
            model.seedScene(layout: "straight", mode: .calledShots)
            model.callPocket(near: Vec2(-1.27, 0.635))
            model.aim(at: Vec2(0.5, 0.25))
        },
        Scene(name: "called-no-shot", about: "Called shots: no ball can go into the called pocket") { model in
            model.seedScene(layout: "straight", mode: .calledShots)
            model.callPocket(near: Vec2(-1.27, -0.635))
        },
        Scene(name: "blocked-called", about: "Called shots: a blocked pick, the reason is for the called pocket") { model in
            model.seedScene(layout: "pickblock", mode: .calledShots)
            model.callPocket(near: Vec2(1.27, 0.635))
            model.pickAnotherBall(preferring: BallID(4))
        },
        Scene(name: "recording", about: "Recording in progress (the real recorder)") { model in
            model.seedScene(layout: "open")
            await model.startRecording()
            // Starting a recording restarts the live pipeline, which on a
            // device then reports the table again within a frame. There is
            // no pipeline here, so put the table back the way it would be.
            model.reinstallTable(layout: "open")
        },
    ]

    // MARK: - Sheets

    static let sheets: [Scene] = [
        Scene(name: "sheet-more", about: "The More sheet") { model in
            model.seedScene(layout: "open")
            model.openSheet("more")
        },
        Scene(name: "sheet-settings", about: "The Settings sheet") { model in
            model.seedScene(layout: "open")
            model.openSheet("settings")
        },
    ]
}

// MARK: - Helpers on the model

@MainActor
extension SessionModel {

    /// Seed a layout with fixed settings, so a scene does not depend on what
    /// an earlier launch left in UserDefaults.
    func seedScene(layout: String, group: BallGroup = .any, mode: PracticeMode = .freePlay,
                   scoreboard: Bool = false) {
        updateSettings {
            $0.ballGroup = group
            $0.practiceMode = mode
            $0.showScoreboard = scoreboard
            $0.deviceParked = false
        }
        seedSyntheticTable(named: layout, quiet: true)
    }

    /// `seedScene`, then wait out the sampler's lock tick (4 Hz) and the lock pill, which
    /// resets the score and the shot tracking when it sees a new lock. A
    /// scene that plays shots must start after it, or the score is wiped.
    func seedAndSettle(layout: String, scoreboard: Bool = false) async {
        seedScene(layout: layout, group: .any, scoreboard: scoreboard)
        // 3 s: past the lock tick (4 Hz) AND past the "Table locked" pill's
        // 2.2 s, so the scene starts from a quiet screen.
        try? await Task.sleep(for: .seconds(3))
    }

    /// Re-publish a layout as the pipeline's next output would.
    func reinstallTable(layout: String) {
        guard let state = DebugSeed.state(named: layout) else { return }
        installDebugState(state)
        recomputeRanking()
    }

    /// Put the camera above `point` (table metres), looking at it, and let
    /// the app's own aim code take it from there (`updateAim` is what
    /// ARKit's camera pose feeds on a device). The table frame lies on
    /// world x / z, so table (x, y) is world (x, 0, y).
    func aim(at point: Vec2, height: Double = 1.0) {
        let target = SIMD3<Double>(point.x, 0, point.y)
        let position = target + SIMD3<Double>(0, height, 0.3)
        let back = simd_normalize(position - target)
        let right = simd_normalize(simd_cross(SIMD3<Double>(0, 1, 0), back))
        let up = simd_cross(back, right)
        let pose = Transform3D(columns: [SIMD4(right, 0), SIMD4(up, 0),
                                         SIMD4(back, 0), SIMD4(position, 1)])
        for _ in 0..<6 { updateAim(cameraTransform: pose) }
    }

    /// Tap a ball other than the suggested one (or `preferring` it).
    func pickAnotherBall(preferring wanted: BallID? = nil) {
        guard let state = tableState else { return }
        let suggested = activeShot?.ball
        let candidates = state.balls.filter { $0.id != state.cueBall?.id && $0.id != suggested }
        guard let ball = candidates.first(where: { $0.id == wanted }) ?? candidates.first else { return }
        _ = selectTarget(near: ball.position)
    }

    /// Call the pocket nearest `point`, the way a tap on it does.
    func callPocket(near point: Vec2) {
        guard let table = tableState?.table,
              let pocket = table.pockets.min(by: { $0.position.distance(to: point) < $1.position.distance(to: point) })
        else { return }
        togglePocketCall(pocket.id)
    }

    /// Frames a live pipeline would have reported for a calibration that no
    /// longer fits: most detections land off the table, for several seconds.
    func feedCalibrationHealth(detections: Int, offTable: Int, seconds: Double = 5) {
        guard let state = tableState else { return }
        var time = state.timestamp
        for _ in 0..<Int(seconds * 10) {
            time += 0.1
            noteOutputHealth(PerceptionOutput(
                state: TableState(table: state.table, balls: state.balls, timestamp: time),
                surfaceGate: SurfaceGateCounts(rejected: offTable),
                gateCandidates: detections))
        }
    }

    /// Frames a live pipeline would have reported for a detector that has
    /// gone quiet: `peak` OBJECT balls for a while, then `now`. The count
    /// rule is the app's own (`TableState.objectBallCount`): the cue ball is
    /// never counted. The table state afterwards is the cue ball and `now`
    /// object balls, as the tracker's output would be.
    func feedDetectionHealth(peak: Int, now: Int, luminance: Double) {
        guard let state = tableState else { return }
        let cue = state.cueBall
        let objects = state.balls.filter { $0.id != cue?.id }
        func table(_ count: Int, at time: Double) -> TableState {
            TableState(table: state.table,
                       balls: (cue.map { [$0] } ?? []) + Array(objects.prefix(count)),
                       timestamp: time)
        }
        var time = state.timestamp
        for _ in 0..<80 {
            time += 0.1
            noteOutputHealth(PerceptionOutput(state: table(peak, at: time), luminance: luminance))
        }
        for _ in 0..<80 {
            time += 0.1
            noteOutputHealth(PerceptionOutput(state: table(now, at: time), luminance: luminance))
        }
        installDebugState(table(now, at: time))
        recomputeRanking()
    }

    func openSheet(_ name: String) {
        NotificationCenter.default.post(name: .mirrorOpenSheet, object: nil,
                                        userInfo: ["name": name])
    }
}

#endif
