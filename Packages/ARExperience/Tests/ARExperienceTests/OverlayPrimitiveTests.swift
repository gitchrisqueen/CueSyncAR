import BilliardsPhysics
import CueSyncCore
import Foundation
import TableSpace
import Testing
@testable import ARExperience

// The renderer draws `OverlayLayout.primitives` and applies `OverlayDiff`
// plans. These hold the rules that make a draw cheap: the same layout
// draws nothing, sub-millimetre jitter draws nothing, and only a new or
// different-looking primitive is built.

private let cueID = BallID(0)
private let solver = AnalyticSolver()
private let calibration = TableCalibration(origin: .zero, xAxis: Vec3(1, 0, 0),
                                           yAxis: Vec3(0, 0, -1), size: .eightFoot)

/// Cue ball plus fifteen object balls on a grid; `shift` nudges every object
/// ball by that many metres (the tracker's jitter, in the worst direction).
private func table(shift: Vec2 = .zero, dropLast: Bool = false) -> TableState {
    let size = Table(size: .eightFoot)
    let (length, width) = (size.size.playField.width, size.size.playField.height)
    var balls = [Ball(id: cueID, kind: .cue, position: Vec2(0.3, 0.07))]
    var next = 1
    for k in [3.0, 2.0, 0.0, -2.0, -3.0] {
        for j in [1.0, 0.0, -1.0] {
            balls.append(Ball(id: BallID(next), kind: .solid(next),
                              position: Vec2(k * length / 8, j * width / 8) + shift))
            next += 1
        }
    }
    if dropLast { balls.removeLast() }
    return TableState(table: size, balls: balls, timestamp: 0)
}

private func suggestion(_ state: TableState, ball: Int = 7,
                        pocket: PocketID = .cornerTopLeft) throws -> OverlayLayout.Target {
    let object = try #require(state.ball(BallID(ball)))
    let hole = try #require(state.table.pockets.first { $0.id == pocket })
    let ghost = object.position - (hole.position - object.position).normalized * (2 * object.radius)
    let prediction = try #require(TargetGuide.plan(state: state, ghostBall: ghost, solver: solver, speed: 3.5))
    return OverlayLayout.Target(prediction: prediction, ball: BallID(ball), pocket: pocket, ghostBall: ghost)
}

private func drawn(_ layout: OverlayLayout) -> [String: OverlayPrimitive] {
    Dictionary(uniqueKeysWithValues: layout.primitives.map { ($0.key, $0) })
}

@Suite("OverlayPrimitive: what is on the cloth")
struct OverlayPrimitiveListTests {
    @Test("Keys are unique and stable between two identical layouts")
    func keysAreStable() throws {
        let state = table()
        let target = try suggestion(state)
        let a = OverlayLayout.ballsOnly(state: state, calibration: calibration, target: target)
        let b = OverlayLayout.ballsOnly(state: state, calibration: calibration, target: target)
        #expect(a.primitives.map(\.key) == b.primitives.map(\.key))
        #expect(Set(a.primitives.map(\.key)).count == a.primitives.count)
    }

    @Test("A suggestion on 15 balls: two rings, the hero line, the pocket ring and the target ghost")
    func suggestionPrimitives() throws {
        let state = table()
        let layout = OverlayLayout.ballsOnly(state: state, calibration: calibration,
                                             target: try suggestion(state))
        let list = layout.primitives
        #expect(list.filter { $0.key.contains(".ring.") }.count == 2)
        #expect(list.filter { $0.key.hasPrefix("hero.strip.") }.count == 2)
        #expect(list.contains { $0.key == "hero.pocket" })
        #expect(list.contains { $0.key == "hero.ghost" })
        // The target ball's ring fades with its shot; the cue ball's does not.
        #expect(list.filter { $0.group == .hero }.contains { $0.key.contains(".ring.") })
        #expect(list.filter { $0.group == .base }.filter { $0.key.contains(".ring.") }.count == 1)
    }

    @Test("A strip is a unit box scaled to its length and thickness, with its heading")
    func stripPrimitive() throws {
        let state = table()
        let layout = OverlayLayout.ballsOnly(state: state, calibration: calibration,
                                             target: try suggestion(state))
        let strip = try #require(layout.primitives.first { $0.key == "hero.strip.1" })
        let source = try #require(layout.targetStrips.last)
        #expect(strip.look.shape == .box)
        #expect(abs(strip.scale.x - source.length) < 1e-12)
        #expect(abs(strip.scale.z - OverlayStyle.width(.hero)) < 1e-12)
        #expect(abs(strip.scale.y - OverlayStyle.width(.hero) / 2) < 1e-12)
        #expect(strip.heading == source.direction)
        #expect(strip.position.distance(to: source.midpoint) <= OverlayStyle.lift(.hero) + 1e-9)
    }

    @Test("A ring's mesh radii ride in its look; its scale is 1")
    func ringPrimitive() throws {
        let state = table()
        let layout = OverlayLayout.ballsOnly(state: state, calibration: calibration)
        let ring = try #require(layout.primitives.first { $0.key.hasPrefix("base.ring.") })
        let radii = OverlayStyle.ballRing(ballRadius: Ball.standardRadius)
        #expect(ring.look.shape == .ring(innerMicrometres: Int((radii.inner * 1e6).rounded()),
                                         outerMicrometres: Int((radii.outer * 1e6).rounded())))
        #expect(ring.scale == Vec3(1, 1, 1))
        #expect(ring.heading == nil)
    }

    @Test("Opacity is in the 25 to 40 percent band for every ball ring")
    func ringOpacity() {
        let layout = OverlayLayout.ballsOnly(state: table(), calibration: calibration)
        for ring in layout.primitives where ring.key.contains(".ring.") {
            #expect(OverlayStyle.ringOpacityRange.contains(ring.look.opacity), "\(ring.key)")
        }
    }
}

@Suite("OverlayDiff: a draw that changes nothing costs nothing")
struct OverlayDiffTests {
    @Test("The same layout twice: nothing to do")
    func identical() throws {
        let state = table()
        let layout = OverlayLayout.ballsOnly(state: state, calibration: calibration,
                                             target: try suggestion(state))
        let plan = OverlayDiff.plan(drawn: drawn(layout), wanted: layout.primitives)
        #expect(plan.isEmpty)
        #expect(plan.keep == layout.primitives.count)
    }

    @Test("Every ball moved by under a millimetre: nothing to do, though the layouts differ")
    func subMillimetreJitter() throws {
        let before = OverlayLayout.ballsOnly(state: table(), calibration: calibration)
        let after = OverlayLayout.ballsOnly(state: table(shift: Vec2(0.0004, -0.0004)),
                                            calibration: calibration)
        #expect(before != after, "the layouts do differ, so a plain == would redraw")
        let plan = OverlayDiff.plan(drawn: drawn(before), wanted: after.primitives)
        #expect(plan.isEmpty)
        #expect(plan.keep == after.primitives.count)
    }

    @Test("A ball that moved 2 mm is moved, and only that ball")
    func oneBallMoves() {
        var moved = table()
        moved.balls[5].position += Vec2(0.002, 0)
        let before = OverlayLayout.ballsOnly(state: table(), calibration: calibration)
        let after = OverlayLayout.ballsOnly(state: moved, calibration: calibration)
        let plan = OverlayDiff.plan(drawn: drawn(before), wanted: after.primitives)
        #expect(plan.move.count == 1)
        #expect(plan.build.isEmpty && plan.remove.isEmpty)
        #expect(plan.move.first?.key == "base.ring.5")
    }

    @Test("Drift is measured against what is DRAWN, so small steps add up")
    func driftAccumulates() {
        let before = OverlayLayout.ballsOnly(state: table(), calibration: calibration)
        let onScreen = drawn(before)
        var redraws = 0
        for step in 1...4 {
            let after = OverlayLayout.ballsOnly(
                state: table(shift: Vec2(0.0004 * Double(step), 0)), calibration: calibration)
            if !OverlayDiff.plan(drawn: onScreen, wanted: after.primitives).isEmpty { redraws += 1 }
        }
        // 0.4 and 0.8 mm are inside the tolerance; 1.2 and 1.6 mm are not.
        #expect(redraws == 2)
    }

    @Test("A ball that appears is built; one that goes is removed")
    func addAndRemove() {
        let full = OverlayLayout.ballsOnly(state: table(), calibration: calibration)
        let short = OverlayLayout.ballsOnly(state: table(dropLast: true), calibration: calibration)
        let grow = OverlayDiff.plan(drawn: drawn(short), wanted: full.primitives)
        #expect(grow.build.count == 1 && grow.move.isEmpty && grow.remove.isEmpty)
        let shrink = OverlayDiff.plan(drawn: drawn(full), wanted: short.primitives)
        #expect(shrink.remove.count == 1 && shrink.build.isEmpty && shrink.move.isEmpty)
    }

    @Test("A different look is a rebuild, not a move")
    func lookChange() throws {
        let state = table()
        let plain = OverlayLayout.ballsOnly(state: state, calibration: calibration)
        let shot = OverlayLayout.ballsOnly(state: state, calibration: calibration,
                                           target: try suggestion(state))
        let plan = OverlayDiff.plan(drawn: drawn(plain), wanted: shot.primitives)
        // The target ball's ring turned green and joined the hero group.
        #expect(plan.build.contains { $0.group == .hero && $0.key.contains(".ring.") })
        #expect(plan.build.contains { $0.key == "hero.pocket" })
    }

    @Test("A strip that lengthens is a scale change, a strip that swings is a move")
    func strips() throws {
        let state = table()
        let target = try suggestion(state)
        let layout = OverlayLayout.ballsOnly(state: state, calibration: calibration, target: target)
        let leg = try #require(layout.primitives.first { $0.key == "hero.strip.0" })

        var longer = leg
        longer.scale.x += 0.0004
        #expect(OverlayDiff.change(from: leg, to: longer) == .none)
        longer.scale.x += 0.002
        #expect(OverlayDiff.change(from: leg, to: longer) == .move)

        // The far end swings by 0.3 mm: unseen. By 3 mm: moved.
        var nudged = leg
        let sideways = Vec3(-leg.heading!.z, 0, leg.heading!.x)
        nudged.heading = (leg.heading! + sideways * (0.0003 / leg.scale.x)).normalized
        #expect(OverlayDiff.change(from: leg, to: nudged) == .none)
        nudged.heading = (leg.heading! + sideways * (0.003 / leg.scale.x)).normalized
        #expect(OverlayDiff.change(from: leg, to: nudged) == .move)
    }

    @Test("Opacity or colour change is a rebuild, and so is a group change")
    func rebuildTriggers() throws {
        let layout = OverlayLayout.ballsOnly(state: table(), calibration: calibration)
        let ring = try #require(layout.primitives.first)
        var fainter = ring
        fainter.look.opacityPermille += 10
        #expect(OverlayDiff.change(from: ring, to: fainter) == .rebuild)
        var recoloured = ring
        recoloured.look.colour = 0x123456
        #expect(OverlayDiff.change(from: ring, to: recoloured) == .rebuild)
        var regrouped = ring
        regrouped.group = .hero
        #expect(OverlayDiff.change(from: ring, to: regrouped) == .rebuild)
    }

    @Test("A heading that appears or disappears is a move")
    func headingAppears() throws {
        let state = table()
        let layout = OverlayLayout.ballsOnly(state: state, calibration: calibration,
                                             target: try suggestion(state))
        let leg = try #require(layout.primitives.first { $0.key == "hero.strip.0" })
        var headless = leg
        headless.heading = nil
        #expect(OverlayDiff.change(from: leg, to: headless) == .move)
        #expect(OverlayDiff.change(from: headless, to: leg) == .move)
    }
}

@Suite("OverlayRenderStats")
struct OverlayRenderStatsTests {
    @Test("A render that changes nothing is counted but is not a redraw")
    func counts() {
        var stats = OverlayRenderStats()
        stats.note(built: 20, moved: 0, kept: 0, removed: 0)
        stats.note(built: 0, moved: 0, kept: 20, removed: 0)
        stats.note(built: 0, moved: 3, kept: 17, removed: 0)
        #expect(stats.renders == 3)
        #expect(stats.redraws == 2)
        #expect(stats.built == 20 && stats.moved == 3)
        #expect(stats.lastMoved == 3 && stats.lastKept == 17)
    }
}
