//
//  DebugSeed.swift
//  CueSync AR
//
//  Simulator-only synthetic table (workstream A of docs/roadmap/12). The
//  Simulator cannot run ARKit, so without this the HUD never leaves the
//  "AR requires a physical device" placeholder. A seed installs a fixed
//  TableState + a locked calibration so the real HUD renders: mini-map,
//  advisor card with its cycle button, the "No clean shot" capsule.
//
//  Triggers (both compiled out of release and device builds):
//    launch argument   -seedTable open|blocked|rack
//    mirror command    GET /cmd?action=seed&layout=open|blocked|rack
//

#if DEBUG && targetEnvironment(simulator)

import CueSyncCore
import Foundation

enum DebugSeed {
    static let layoutNames = ["open", "blocked", "rack"]

    /// Table-space meters on a 9-ft table (x along the long rail).
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
            // One ball frozen near the head rail: every pocket is either
            // behind it, too thin a cut, or outside the jaw cone.
            return TableState(table: table, balls: [
                ball(0, .cue, -0.90, 0.0),
                ball(4, .solid(4), -1.22, 0.0)
            ])
        case "rack":
            return TableStateFixtureCopy.eightBallRack()
        default:
            return nil
        }
    }
}

/// App-local copy of the standard rack: CueSyncTestSupport is a test
/// target and must not link into the app.
private enum TableStateFixtureCopy {
    static func eightBallRack() -> TableState {
        let table = Table(size: .nineFoot)
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
        publishMirrorFrame(nil)
    }

    /// Returns false (and tells the player) for an unknown layout name.
    @discardableResult
    func seedSyntheticTable(named name: String) -> Bool {
        guard let state = DebugSeed.state(named: name) else {
            showTapFeedback("Unknown seed '\(name)' (\(DebugSeed.layoutNames.joined(separator: ", ")))")
            return false
        }
        installDebugTable(state)
        showTapFeedback("Seeded table: \(name)")
        return true
    }
}

#endif
