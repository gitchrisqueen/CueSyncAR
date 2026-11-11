//
//  DebugSeed.swift
//  CueSync AR
//
//  Simulator-only synthetic table. The Simulator cannot run ARKit, so
//  without this the HUD never leaves "AR requires a physical device". A
//  seed installs a fixed TableState and a locked calibration, then runs
//  the app's own ranking (`recomputeRanking`, the call every pipeline
//  output makes) so the real HUD renders: status capsule, shot card, group
//  button, control bar. Nothing here ranks or draws anything itself.
//
//  Triggers (both compiled out of Release and device builds):
//    launch argument   -seedTable open|blocked|rack
//    mirror command    GET /cmd?action=seed&layout=open|blocked|rack
//
//  The AR loop is the only thing that publishes /state.json, and it does
//  not run in the Simulator, so a seed and every mirror command publish
//  once themselves.
//

#if DEBUG && targetEnvironment(simulator)

import CoachKit
import CueSyncCore
import Foundation
import TableSpace

enum DebugSeed {
    static let layoutNames = ["open", "blocked", "rack"]

    /// Table-space metres on a nine-foot table (x along the long rail).
    static func state(named name: String) -> TableState? {
        let table = Table(size: .nineFoot)
        func ball(_ id: Int, _ kind: Ball.Kind, _ x: Double, _ y: Double) -> Ball {
            Ball(id: BallID(id), kind: kind, position: Vec2(x, y))
        }
        switch name {
        case "open":
            // Mid-game scatter: several viable shots with different cuts.
            return TableState(table: table, balls: [
                ball(0, .cue, -0.60, -0.10),
                ball(3, .solid(3), 0.25, 0.30),
                ball(5, .solid(5), 0.55, -0.25),
                ball(9, .stripe(9), -0.10, 0.38),
                ball(8, .eight, 0.85, 0.10)
            ])
        case "blocked":
            // One ball frozen against the head rail: every pocket is behind
            // it, too thin a cut, or outside the jaw cone.
            return TableState(table: table, balls: [
                ball(0, .cue, -0.90, 0.0),
                ball(4, .solid(4), -1.22, 0.0)
            ])
        case "rack":
            return eightBallRack(table: table)
        default:
            return nil
        }
    }

    /// App-local copy of the standard rack: CueSyncTestSupport is a test
    /// support package and does not link into the app.
    private static func eightBallRack(table: Table) -> TableState {
        let radius = Ball.standardRadius
        var balls = [Ball(id: BallID(0), kind: .cue, position: Vec2(-0.635, 0))]
        let apex = Vec2(0.635, 0)
        let dx = radius * 3.0.squareRoot() + 1e-4
        let numbers = [1, 9, 2, 10, 8, 3, 11, 4, 12, 5, 13, 6, 14, 7, 15]
        var index = 0
        for row in 0..<5 {
            for slot in 0...row {
                let n = numbers[index]
                index += 1
                let kind: Ball.Kind = n == 8 ? .eight : (n < 8 ? .solid(n) : .stripe(n))
                let position = apex + Vec2(Double(row) * dx,
                                           (Double(slot) - Double(row) / 2) * 2 * (radius + 5e-5))
                balls.append(Ball(id: BallID(n), kind: kind, position: position))
            }
        }
        return TableState(table: table, balls: balls)
    }
}

extension SessionModel {
    /// Seeds the layout named by `-seedTable <name>`, if present.
    func applyLaunchSeedIfRequested() {
        guard let name = UserDefaults.standard.string(forKey: "seedTable") else { return }
        seedSyntheticTable(named: name)
    }

    /// `/cmd?action=seed&layout=<name>`. True when the action was a seed.
    func handleDebugSeedCommand(_ params: [String: String]) -> Bool {
        guard params["action"] == "seed" else { return false }
        seedSyntheticTable(named: params["layout"] ?? "open")
        return true
    }

    /// Returns false (and tells the player) for an unknown layout name.
    @discardableResult
    func seedSyntheticTable(named name: String) -> Bool {
        guard let state = DebugSeed.state(named: name) else {
            showTapFeedback("Unknown seed '\(name)' (\(DebugSeed.layoutNames.joined(separator: ", ")))")
            return false
        }
        // A table the size of the layout, lying on the ground plane with its
        // long axis along world x, so table space and world space agree.
        restoreCalibration(TableCalibration(origin: .zero, xAxis: Vec3(1, 0, 0),
                                            yAxis: Vec3(0, 0, 1), size: state.table.size),
                           anchorTransform: .identity)
        installDebugState(state)
        // No AR view to project through, so pocket names come from the 2D
        // drawing's own frame (table x right, y up the screen): "near" is
        // the bottom rail, exactly as TableSceneView draws it.
        presentation.setView(names: PocketViewNaming.names(for: state.table, frame: .identity),
                             side: .leading)
        recomputeRanking()
        showTapFeedback("Seeded table: \(name)")
        publishMirrorFrame(nil)
        return true
    }
}

#endif
