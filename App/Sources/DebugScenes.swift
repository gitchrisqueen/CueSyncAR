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
            model.aim(at: Vec2(0.25, 0.30))
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
        Scene(name: "losing-balls", about: "Only seeing 2 of 6 balls") { model in
            model.seedScene(layout: "rack")
            model.feedDetectionHealth(peak: 6, now: 2, luminance: 0.6)
        },
        Scene(name: "losing-balls-dark", about: "Only seeing 2 of 6 balls: more light would help") { model in
            model.seedScene(layout: "rack")
            model.feedDetectionHealth(peak: 6, now: 2, luminance: 0.15)
        },
        Scene(name: "losing-one-of-fifteen", about: "Tracking 1 ball of 15: must not look healthy") { model in
            model.seedScene(layout: "rack")
            model.feedDetectionHealth(peak: 15, now: 1, luminance: 0.6, shownBalls: 1)
        },
        Scene(name: "one-ball", about: "A table with one ball: Tracking 1 ball") { model in
            model.seedScene(layout: "oneball")
        },
    ]

    // MARK: - Outcomes (banners, score, streak)

    static let outcomes: [Scene] = [
        Scene(name: "shot-made", about: "A made shot: banner and score") { model in
            model.feedback.bannerHoldOverride = 3600
            model.seedScene(layout: "open", group: .any, scoreboard: true)
            model.simulateShot(result: "made")
        },
        Scene(name: "shot-streak", about: "Made shots in a row: streak") { model in
            model.feedback.bannerHoldOverride = 3600
            model.seedScene(layout: "open", group: .any, scoreboard: true)
            for _ in 0..<3 where model.activeShot != nil { model.simulateShot(result: "made") }
        },
        Scene(name: "shot-missed", about: "A missed shot: banner") { model in
            model.feedback.bannerHoldOverride = 3600
            model.seedScene(layout: "open", group: .any, scoreboard: true)
            model.simulateShot(result: "missed")
        },
        Scene(name: "shot-scratch", about: "The cue ball was pocketed") { model in
            model.feedback.bannerHoldOverride = 3600
            model.seedScene(layout: "open", group: .any, scoreboard: true)
            model.simulateShot(result: "scratch")
        },
        Scene(name: "scoreboard", about: "The scoreboard chip after a made and a missed shot") { model in
            model.seedScene(layout: "open", group: .any, scoreboard: true)
            model.simulateShot(result: "made")
            if model.activeShot != nil { model.simulateShot(result: "missed") }
        },
        Scene(name: "scoreboard-empty", about: "The scoreboard chip before any shot") { model in
            model.seedScene(layout: "open", group: .any, scoreboard: true)
        },
        Scene(name: "banner-tracking-lost", about: "Banner: tracking lost") { model in
            model.feedback.bannerHoldOverride = 3600
            model.seedScene(layout: "open")
            model.postFeedback(.trackingLost, force: true)
        },
        Scene(name: "banner-tracking-recovered", about: "Banner: tracking recovered") { model in
            model.feedback.bannerHoldOverride = 3600
            model.seedScene(layout: "open")
            model.postFeedback(.trackingRecovered, force: true)
        },
        Scene(name: "banner-calibration-refused", about: "Banner: the lock was refused") { model in
            model.feedback.bannerHoldOverride = 3600
            model.seedScene(layout: "open")
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
        Scene(name: "called-off-line", about: "Called shots: pocket called, not on line") { model in
            model.seedScene(layout: "straight", mode: .calledShots)
            model.callPocket(near: Vec2(-1.27, 0.635))
            model.aim(at: Vec2(0.5, 0.25))
        },
        Scene(name: "recording", about: "Recording in progress (the real recorder)") { model in
            model.seedScene(layout: "open")
            await model.startRecording()
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
    /// gone quiet: `peak` balls for a while, then `now`. `shownBalls`
    /// replaces the table state afterwards with that many balls, as the
    /// tracker's output would.
    func feedDetectionHealth(peak: Int, now: Int, luminance: Double, shownBalls: Int? = nil) {
        guard let state = tableState else { return }
        func output(_ count: Int, at time: Double) -> PerceptionOutput {
            PerceptionOutput(state: TableState(table: state.table,
                                               balls: Array(state.balls.prefix(count)),
                                               timestamp: time),
                             luminance: luminance)
        }
        var time = state.timestamp
        for _ in 0..<80 { time += 0.1; noteOutputHealth(output(peak, at: time)) }
        for _ in 0..<80 { time += 0.1; noteOutputHealth(output(now, at: time)) }
        if let shownBalls {
            installDebugState(TableState(table: state.table,
                                         balls: Array(state.balls.prefix(shownBalls)),
                                         timestamp: time))
            recomputeRanking()
        }
    }

    func openSheet(_ name: String) {
        NotificationCenter.default.post(name: .mirrorOpenSheet, object: nil,
                                        userInfo: ["name": name])
    }
}

#endif
