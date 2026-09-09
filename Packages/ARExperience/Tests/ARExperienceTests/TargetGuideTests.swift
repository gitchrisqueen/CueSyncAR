import BilliardsPhysics
import CueSyncCore
import Foundation
import TableSpace
import Testing
@testable import ARExperience

@Suite("TargetGuide")
struct TargetGuideTests {
    private let cueID = BallID(0)
    private let objectID = BallID(3)
    private let table = Table(size: .eightFoot)
    private var he: Vec2 { table.halfExtents }
    private let solver = AnalyticSolver()

    private func state(cue: Vec2, object: Vec2, extras: [Ball] = []) -> TableState {
        TableState(table: table, balls: [
            Ball(id: cueID, kind: .cue, position: cue),
            Ball(id: objectID, kind: .solid(3), position: object)
        ] + extras, timestamp: 0)
    }

    /// Ghost-ball position for `object` into `pocket`, the same way
    /// ShotRanking computes it.
    private func ghost(object: Vec2, pocket: Vec2) -> Vec2 {
        object - (pocket - object).normalized * (2 * Ball.standardRadius)
    }

    // MARK: - Aim

    @Test("The ideal aim points from the cue ball at the ghost ball")
    func aimPointsAtTheGhost() throws {
        let object = Vec2(0, 0)
        let g = ghost(object: object, pocket: Vec2(he.x, he.y))
        let cue = Ball(id: cueID, kind: .cue, position: Vec2(-0.8, -0.4))
        let ray = try #require(TargetGuide.aim(cueBall: cue, ghostBall: g))
        #expect(ray.origin == cue.position)
        #expect(abs(ray.direction.length - 1) < 1e-9)
        // Following the ray by the right distance lands on the ghost.
        let travelled = cue.position + ray.direction * cue.position.distance(to: g)
        #expect(travelled.distance(to: g) < 1e-9)
    }

    @Test("A cue ball already on the ghost has no aim, rather than a made-up one")
    func degenerateAimIsNil() {
        let g = Vec2(0.2, 0.1)
        let cue = Ball(id: cueID, kind: .cue, position: g)
        #expect(TargetGuide.aim(cueBall: cue, ghostBall: g) == nil)
    }

    // MARK: - The plan

    /// The claim the whole feature rests on: the line drawn for the
    /// recommended shot actually pots the ball. If the solver disagrees
    /// with the ranking's geometry, one of them is lying to the player.
    @Test("The planned shot really does pot the ball the ranking chose")
    func theePlanPotsTheBall() throws {
        let object = Vec2(0.2, 0.1)
        let pocket = Vec2(he.x, he.y)
        let s = state(cue: Vec2(-0.7, -0.35), object: object)
        let plan = try #require(TargetGuide.plan(state: s, ghostBall: ghost(object: object, pocket: pocket),
                                                 solver: solver, speed: 3.5))
        #expect(plan.pocketedBalls.contains(objectID))
        let potted = plan.events.contains { event in
            if case let .pocket(ball, id) = event { return ball == objectID && id == .cornerTopRight }
            return false
        }
        #expect(potted, "the planned aim should send the ball into the ranked pocket")
    }

    @Test("The plan carries both balls: how to hit it and where the cue ball ends up")
    func planShowsBothPaths() throws {
        let object = Vec2(0.2, 0.1)
        let s = state(cue: Vec2(-0.7, -0.35), object: object)
        let plan = try #require(TargetGuide.plan(
            state: s, ghostBall: ghost(object: object, pocket: Vec2(he.x, he.y)),
            solver: solver, speed: 3.5))
        let balls = Set(plan.segments.map(\.ballID))
        #expect(balls.contains(cueID), "the cue ball's approach must be drawn")
        #expect(balls.contains(objectID), "the object ball's path must be drawn")
        #expect(plan.events.contains { if case .ballBall = $0 { return true }; return false })
    }

    @Test("The plan is trimmed like the live guide, not a full simulation")
    func planIsTrimmed() throws {
        let object = Vec2(0.2, 0.1)
        let s = state(cue: Vec2(-0.7, -0.35), object: object)
        let plan = try #require(TargetGuide.plan(
            state: s, ghostBall: ghost(object: object, pocket: Vec2(he.x, he.y)),
            solver: solver, speed: 6))
        #expect(plan.segments.count <= 5)
    }

    @Test("No cue ball, no plan — and never an empty prediction")
    func noPlanWithoutACueBall() {
        let orphan = TableState(table: table, balls: [
            Ball(id: objectID, kind: .solid(3), position: Vec2(0.2, 0.1))
        ], timestamp: 0)
        #expect(TargetGuide.plan(state: orphan, ghostBall: Vec2(0, 0),
                                 solver: solver, speed: 3.5) == nil)
    }

    // MARK: - Telling the player which way to move

    @Test("An aim already on the line reads as on line")
    func onLineWhenAligned() throws {
        let object = Vec2(0.2, 0.1)
        let g = ghost(object: object, pocket: Vec2(he.x, he.y))
        let cue = Ball(id: cueID, kind: .cue, position: Vec2(-0.7, -0.35))
        let ideal = try #require(TargetGuide.aim(cueBall: cue, ghostBall: g))
        #expect(TargetGuide.correction(current: ideal, ideal: ideal) == .onLine)
        #expect(TargetGuide.aimError(current: ideal, ideal: ideal)! < 1e-9)
    }

    @Test("A wide aim is told which way to move, and the two sides disagree")
    func correctionHasASide() throws {
        let object = Vec2(0.2, 0.1)
        let g = ghost(object: object, pocket: Vec2(he.x, he.y))
        let cue = Ball(id: cueID, kind: .cue, position: Vec2(-0.7, -0.35))
        let ideal = try #require(TargetGuide.aim(cueBall: cue, ghostBall: g))
        let radians = 6 * Double.pi / 180
        let clockwise = AimRay(origin: ideal.origin, direction: ideal.direction.rotated(by: -radians))
        let anti = AimRay(origin: ideal.origin, direction: ideal.direction.rotated(by: radians))
        let a = try #require(TargetGuide.correction(current: clockwise, ideal: ideal))
        let b = try #require(TargetGuide.correction(current: anti, ideal: ideal))
        #expect(a != .onLine)
        #expect(b != .onLine)
        #expect(a.side != b.side, "opposite errors must not give the same advice")
        #expect(abs(TargetGuide.aimError(current: clockwise, ideal: ideal)! - 6) < 1e-6)
    }

    /// "A little" has to mean a little, or the player learns to ignore the
    /// line. At six degrees the cue tip moves several centimetres.
    @Test("The wording scales with how far off the aim is")
    func adviceWordingIsProportionate() throws {
        let object = Vec2(0.2, 0.1)
        let g = ghost(object: object, pocket: Vec2(he.x, he.y))
        let cue = Ball(id: cueID, kind: .cue, position: Vec2(-0.7, -0.35))
        let ideal = try #require(TargetGuide.aim(cueBall: cue, ghostBall: g))

        func adviceAt(_ degrees: Double) throws -> String {
            let ray = AimRay(origin: ideal.origin,
                             direction: ideal.direction.rotated(by: degrees * .pi / 180))
            return try #require(TargetGuide.correction(current: ray, ideal: ideal)).advice
        }
        #expect(try adviceAt(3).contains("a little"))
        #expect(try !adviceAt(15).contains("a little"))
        #expect(try adviceAt(15).contains("left") || (try adviceAt(15).contains("right")))
    }

    /// Measured at the table on 2026-09-09: a cue lying on the cloth
    /// produced an "aim" 52 degrees off the recommended shot, and the card
    /// was ready to offer to correct it. Past a point the player is not
    /// making a small error on this shot — they are pointing somewhere
    /// else — and a nudge is worse than silence.
    @Test("Far past the shot, no advice is given at all")
    func noAdviceWhenPointingElsewhere() throws {
        let object = Vec2(0.2, 0.1)
        let g = ghost(object: object, pocket: Vec2(he.x, he.y))
        let cue = Ball(id: cueID, kind: .cue, position: Vec2(-0.7, -0.35))
        let ideal = try #require(TargetGuide.aim(cueBall: cue, ghostBall: g))
        for degrees in [26.0, 52.0, 120.0, 179.0] {
            let ray = AimRay(origin: ideal.origin,
                             direction: ideal.direction.rotated(by: degrees * .pi / 180))
            #expect(TargetGuide.correction(current: ray, ideal: ideal) == nil,
                    "\(degrees)° off should get no advice")
            // The angle itself is still reported — the HUD stops advising,
            // the mirror keeps measuring.
            #expect(TargetGuide.aimError(current: ray, ideal: ideal) != nil)
        }
    }

    @Test("The advice limit is where it says it is")
    func advisableLimitIsHonoured() throws {
        let object = Vec2(0.2, 0.1)
        let g = ghost(object: object, pocket: Vec2(he.x, he.y))
        let cue = Ball(id: cueID, kind: .cue, position: Vec2(-0.7, -0.35))
        let ideal = try #require(TargetGuide.aim(cueBall: cue, ghostBall: g))
        func at(_ degrees: Double, limit: Double) -> TargetGuide.Correction? {
            let ray = AimRay(origin: ideal.origin,
                             direction: ideal.direction.rotated(by: degrees * .pi / 180))
            return TargetGuide.correction(current: ray, ideal: ideal, advisableWithin: limit)
        }
        #expect(at(24, limit: 25) != nil)
        #expect(at(26, limit: 25) == nil)
        #expect(at(40, limit: 45) != nil)
    }

    @Test("Missing either aim gives no advice rather than a guess")
    func noAdviceWithoutBoth() {
        let ray = AimRay(origin: .zero, direction: Vec2(1, 0))
        #expect(TargetGuide.correction(current: nil, ideal: ray) == nil)
        #expect(TargetGuide.correction(current: ray, ideal: nil) == nil)
        #expect(TargetGuide.aimError(current: nil, ideal: nil) == nil)
    }

    @Test("Every correction has advice a person could act on")
    func adviceIsUsable() {
        let cases: [TargetGuide.Correction] = [.onLine, .left(degrees: 3), .right(degrees: 12)]
        for correction in cases {
            #expect(!correction.advice.isEmpty)
        }
        #expect(TargetGuide.Correction.left(degrees: 3).advice.contains("left"))
        #expect(TargetGuide.Correction.right(degrees: 12).advice.contains("right"))
        #expect(TargetGuide.Correction.onLine.side == nil)
    }
}

@Suite("OverlayLayout target layer")
struct OverlayLayoutTargetTests {
    private let cueID = BallID(0)
    private let objectID = BallID(3)
    private let solver = AnalyticSolver()

    // swiftlint:disable:next large_tuple
    private func fixture() throws -> (TableState, TableCalibration, OverlayLayout.Target) {
        let calibration = TableCalibration(origin: .zero,
                                           xAxis: Vec3(1, 0, 0),
                                           yAxis: Vec3(0, 0, -1),
                                           size: .eightFoot)
        let object = Vec2(0.2, 0.1)
        let he = calibration.size.playField
        let pocket = Vec2(he.width / 2, he.height / 2)
        let ghost = object - (pocket - object).normalized * (2 * Ball.standardRadius)
        let state = TableState(table: Table(size: .eightFoot), balls: [
            Ball(id: cueID, kind: .cue, position: Vec2(-0.7, -0.35)),
            Ball(id: objectID, kind: .solid(3), position: object)
        ], timestamp: 0)
        let prediction = try #require(TargetGuide.plan(state: state, ghostBall: ghost,
                                                       solver: solver, speed: 3.5))
        return (state, calibration,
                OverlayLayout.Target(prediction: prediction, ball: objectID,
                                     pocket: .cornerTopRight, ghostBall: ghost))
    }

    @Test("The target layer is separate from the live one and marked as a plan")
    func planStripsAreDistinct() throws {
        let (state, calibration, target) = try fixture()
        let layout = OverlayLayout.compose(state: state, prediction: ShotPrediction(),
                                           calibration: calibration, target: target)
        #expect(layout.strips.isEmpty, "no live aim here")
        #expect(!layout.targetStrips.isEmpty)
        #expect(layout.targetStrips.allSatisfy { $0.role == .plan })
        #expect(layout.targetGhostBall != nil)
        #expect(layout.targetBall != nil)
        #expect(layout.targetPocket != nil)
    }

    /// The case the feature exists for: a player taps a ball before
    /// getting down on the shot, so there is no live aim at all.
    @Test("ballsOnly still draws the recommended shot")
    func ballsOnlyCarriesTheTarget() throws {
        let (state, calibration, target) = try fixture()
        let bare = OverlayLayout.ballsOnly(state: state, calibration: calibration)
        #expect(bare.targetStrips.isEmpty)
        #expect(!bare.balls.isEmpty)

        let withTarget = OverlayLayout.ballsOnly(state: state, calibration: calibration,
                                                 target: target)
        #expect(!withTarget.targetStrips.isEmpty)
        #expect(withTarget.balls.count == bare.balls.count)
        #expect(withTarget.strips.isEmpty)
    }

    @Test("Plan strips are world-space and lie on the cloth, like the live ones")
    func planStripsAreWorldSpace() throws {
        let (state, calibration, target) = try fixture()
        let layout = OverlayLayout.compose(state: state, prediction: ShotPrediction(),
                                           calibration: calibration, target: target)
        for strip in layout.targetStrips {
            #expect(strip.length > 0)
            #expect(strip.direction != nil)
            let midpoint = (strip.start + strip.end) * 0.5
            #expect(midpoint.distance(to: strip.midpoint) < 1e-9)
            #expect(abs(midpoint.y - calibration.origin.y) < 1e-6)
        }
    }

    @Test("A live aim and a plan coexist without either replacing the other")
    func liveAndPlanCoexist() throws {
        let (state, calibration, target) = try fixture()
        let live = solver.predict(state: state,
                                  aim: AimRay(origin: Vec2(-0.7, -0.35), direction: Vec2(1, 0)),
                                  options: SolverOptions(initialSpeed: 3.5, maxEvents: 8))
        let layout = OverlayLayout.compose(state: state, prediction: live,
                                           calibration: calibration, target: target)
        #expect(!layout.strips.isEmpty)
        #expect(!layout.targetStrips.isEmpty)
        #expect(layout.strips.allSatisfy { $0.role == .live })
        #expect(layout.targetStrips.allSatisfy { $0.role == .plan })
    }
}
