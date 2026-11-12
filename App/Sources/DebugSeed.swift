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
//    launch argument   -seedTable open|blocked|rack|straight
//    mirror command    GET /cmd?action=seed&layout=open|blocked|rack|straight
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
    static let layoutNames = ["open", "blocked", "rack", "straight", "fair", "pickblock", "nocue",
                              "scratch", "oneball"]

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
        case "fair":
            // A mid-length cut with the eight to spare: the best shot is
            // rated Fair.
            return TableState(table: table, balls: [
                ball(0, .cue, -1.00, -0.40),
                ball(4, .solid(4), -0.20, 0.30),
                ball(8, .eight, 0.90, -0.40)
            ])
        case "pickblock":
            // The second ball sits behind the first: picking it is picking
            // a blocked shot.
            return TableState(table: table, balls: [
                ball(0, .cue, -0.90, 0.0),
                ball(2, .solid(2), -0.50, 0.0),
                ball(4, .solid(4), 0.20, 0.05)
            ])
        case "nocue":
            return TableState(table: table, balls: [
                ball(3, .solid(3), 0.25, 0.30),
                ball(5, .solid(5), 0.55, -0.25),
                ball(9, .stripe(9), -0.10, 0.38)
            ])
        case "scratch":
            // A thin cut near the head rail: the cue ball follows on into
            // the corner, which the guide calls a scratch.
            return TableState(table: table, balls: [
                ball(0, .cue, -1.00, -0.50),
                ball(4, .solid(4), -0.80, 0.30)
            ])
        case "oneball":
            return TableState(table: table, balls: [ball(0, .cue, -0.30, 0.10)])
        case "straight":
            // Cue ball, object ball and the far-right corner pocket on one
            // line: a near-straight shot, which the guide answers with a
            // non-centre strike, so the cue-ball guide tile is on screen.
            return TableState(table: table, balls: [
                ball(0, .cue, -0.30, -0.15),
                ball(4, .solid(4), 0.50, 0.25)
            ])
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
        // `-seedScene <name>`: a whole HUD state (DebugScenes.swift).
        if let name = UserDefaults.standard.string(forKey: "seedScene") {
            guard let scene = DebugScenes.scene(named: name) else {
                showTapFeedback("Unknown scene '\(name)'")
                return
            }
            Task { @MainActor in await scene.run(self) }
            return
        }
        guard let name = UserDefaults.standard.string(forKey: "seedTable") else { return }
        seedSyntheticTable(named: name)
    }

    /// `/cmd?action=seed&layout=<name>`, plus the arcade-layer checks:
    ///
    ///   `action=feedback&event=shotMade[&detail=...][&force=1][&hold=<s>]`  fire one event
    ///   `action=simulateShot&result=made|missed|scratch`          play a synthetic
    ///   shot through the real outcome detector, ranking and HUD
    ///
    /// True when the action was one of these. Simulator builds only.
    func handleDebugSeedCommand(_ params: [String: String]) -> Bool {
        switch params["action"] {
        case "seed":
            seedSyntheticTable(named: params["layout"] ?? "open")
        case "feedback":
            guard let raw = params["event"], let event = FeedbackEvent(rawValue: raw) else {
                showTapFeedback("Unknown feedback event (\(FeedbackEvent.allCases.map(\.rawValue).joined(separator: ", ")))")
                return true
            }
            feedback.bannerHoldOverride = params["hold"].flatMap(Double.init)
            postFeedback(event, detail: params["detail"], force: params["force"] == "1")
        case "simulateShot":
            simulateShot(result: params["result"] ?? "made")
        default:
            return false
        }
        return true
    }

    /// Feed a scripted shot to the live path at 15 Hz of synthetic time:
    /// rest, strike, then the ball rolls into its pocket (made), stops short
    /// (missed) or the cue ball drops (scratch). The frames go through
    /// `installDebugState` and `recomputeRanking`, which is the call every
    /// pipeline output makes, so the detector, the score, the banner and the
    /// log lines are the real ones.
    func simulateShot(result: String) {
        guard let start = tableState, let cue = start.cueBall, let shot = activeShot, shot.blocker == nil,
              let target = start.ball(shot.ball),
              let pocket = start.table.pockets.first(where: { $0.id == shot.pocket }) else {
            showTapFeedback("No shot to simulate: seed a table with a suggested shot first")
            return
        }
        let step = 1.0 / 15.0
        var time = max(clock(), feedback.lastFedTimestamp ?? 0) + 1
        func frame(_ balls: [Ball]) {
            time += step
            installDebugState(TableState(table: start.table, balls: balls, timestamp: time))
            recomputeRanking()
        }
        let others = start.balls.filter { $0.id != cue.id && $0.id != target.id }
        func balls(cue cuePosition: Vec2?, target targetPosition: Vec2?) -> [Ball] {
            var all = others
            if let cuePosition { var c = cue; c.position = cuePosition; all.append(c) }
            if let targetPosition { var t = target; t.position = targetPosition; all.append(t) }
            return all
        }
        func walk(_ from: Vec2, to goal: Vec2, perFrame: Double, stopShort: Double = 0) -> [Vec2] {
            let total = from.distance(to: goal) - stopShort
            let count = max(1, Int((total / perFrame).rounded(.up)))
            return (1...count).map { from + (goal - from).normalized * min(total, perFrame * Double($0)) }
        }

        for _ in 0..<8 { frame(balls(cue: cue.position, target: target.position)) }
        switch result {
        case "scratch":
            for p in walk(cue.position, to: pocket.position, perFrame: 0.08, stopShort: 0.03) {
                frame(balls(cue: p, target: target.position))
            }
            for _ in 0..<25 { frame(balls(cue: nil, target: target.position)) }
        case "missed":
            let path = Array(walk(cue.position, to: target.position, perFrame: 0.15, stopShort: 0.25).prefix(4))
            for p in path { frame(balls(cue: p, target: target.position)) }
            for _ in 0..<90 { frame(balls(cue: path.last, target: target.position)) }
        default:
            let cuePath = walk(cue.position, to: target.position, perFrame: 0.15, stopShort: 0.25)
            let restCue = cuePath.prefix(4).last ?? cue.position
            for p in cuePath.prefix(4) { frame(balls(cue: p, target: target.position)) }
            for p in walk(target.position, to: pocket.position, perFrame: 0.07, stopShort: 0.03) {
                frame(balls(cue: restCue, target: p))
            }
            for _ in 0..<25 { frame(balls(cue: restCue, target: nil)) }
        }
        publishMirrorFrame(nil)
    }

    /// Returns false (and tells the player) for an unknown layout name.
    /// `quiet` skips the "Seeded table" toast, which no player build shows
    /// (the state gallery photographs the HUD as the app draws it).
    @discardableResult
    func seedSyntheticTable(named name: String, quiet: Bool = false) -> Bool {
        guard let state = DebugSeed.state(named: name) else {
            showTapFeedback("Unknown seed '\(name)' (\(DebugSeed.layoutNames.joined(separator: ", ")))")
            return false
        }
        // Take the "before" sample, so the lock below is seen as a lock and
        // not as a table that was already locked when the sampler started.
        feedbackTick()
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
                             footprint: presentation.footprint)
        recomputeRanking()
        if !quiet { showTapFeedback("Seeded table: \(name)") }
        publishMirrorFrame(nil)
        return true
    }
}

#endif
