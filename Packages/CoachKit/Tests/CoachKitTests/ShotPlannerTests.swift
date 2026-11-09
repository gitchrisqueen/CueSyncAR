import BilliardsPhysics
import CueSyncCore
import Foundation
import Testing
@testable import CoachKit

/// Nine-foot table: half extents (1.27, 0.635); top-right corner pocket at
/// (1.27, 0.635). Hand-derived anchor: a ball at (1.0, 0.365) is exactly
/// 0.27 m left of and below that pocket, i.e. on the 45° diagonal.
@Suite("ShotPlanner")
struct ShotPlannerTests {
    private let table = Table(size: .nineFoot)
    private let cueID = BallID(0)
    private let targetID = BallID(5)

    private func state(cue: Vec2, target: Vec2,
                       others: [Vec2] = []) -> TableState {
        var balls = [
            Ball(id: cueID, kind: .cue, position: cue),
            Ball(id: targetID, kind: .solid(5), position: target)
        ]
        for (index, position) in others.enumerated() {
            balls.append(Ball(id: BallID(20 + index), kind: .stripe(9),
                              position: position))
        }
        return TableState(table: table, balls: balls)
    }

    private func option(_ plan: [ShotOption], pocket: PocketID,
                        target: BallID? = nil) -> ShotOption? {
        plan.first { $0.pocket == pocket && $0.target == (target ?? targetID) }
    }

    private var unlimited: ShotPlanner.Config {
        ShotPlanner.Config(maxOptions: 100)
    }

    // Cue, ghost, object ball and pocket are collinear on the 45° diagonal.
    private let diagonalTarget = Vec2(1.0, 0.365)
    private let diagonalCue = Vec2(0.5, -0.135)

    @Test func straightShotHasNoCutAndRatesEasy() throws {
        let plan = ShotPlanner.plan(state: state(cue: diagonalCue,
                                                 target: diagonalTarget),
                                    config: unlimited)
        let shot = try #require(option(plan, pocket: .cornerTopRight))
        #expect(shot.cutAngleDegrees < 0.5)
        #expect(shot.rating == .easy)
        #expect(shot.detail.contains("straight in"))
        #expect(shot.title == "5-ball → top-right corner")
    }

    @Test func ghostBallSitsOneDiameterBehindTargetAlongThePocketLine() throws {
        let plan = ShotPlanner.plan(state: state(cue: diagonalCue,
                                                 target: diagonalTarget),
                                    config: unlimited)
        let shot = try #require(option(plan, pocket: .cornerTopRight))
        let diameter = Ball.standardRadius * 2
        #expect(abs(shot.ghostBall.distance(to: diagonalTarget) - diameter) < 1e-9)
        // Behind the target relative to the pocket.
        let toPocket = (Vec2(1.27, 0.635) - diagonalTarget).normalized
        let behind = (shot.ghostBall - diagonalTarget).normalized
        #expect(behind.dot(toPocket) < -0.999999)
    }

    @Test func optionCarriesTargetAndPocketGeometry() throws {
        let plan = ShotPlanner.plan(state: state(cue: diagonalCue,
                                                 target: diagonalTarget),
                                    config: unlimited)
        let shot = try #require(option(plan, pocket: .cornerTopRight))
        #expect(shot.targetPosition == diagonalTarget)
        #expect(shot.pocketPosition == Vec2(1.27, 0.635))
        #expect(shot.pocketCaptureRadius == Table.cornerCaptureRadius)
    }

    @Test func aimStartsAtCueBallAndPassesThroughGhost() throws {
        let plan = ShotPlanner.plan(state: state(cue: diagonalCue,
                                                 target: diagonalTarget),
                                    config: unlimited)
        let shot = try #require(option(plan, pocket: .cornerTopRight))
        #expect(shot.aim.origin == diagonalCue)
        let expected = (shot.ghostBall - diagonalCue).normalized
        #expect(shot.aim.direction.distance(to: expected) < 1e-9)
    }

    @Test func blockedCueLaneRemovesTheShot() {
        // Midpoint of cue → ghost lane.
        let blocker = Vec2(0.7298, 0.0948)
        let plan = ShotPlanner.plan(
            state: state(cue: diagonalCue, target: diagonalTarget,
                         others: [blocker]),
            config: unlimited)
        #expect(option(plan, pocket: .cornerTopRight) == nil)
    }

    @Test func blockedObjectLaneRemovesTheShot() {
        // Midpoint of target → pocket lane.
        let blocker = Vec2(1.135, 0.5)
        let plan = ShotPlanner.plan(
            state: state(cue: diagonalCue, target: diagonalTarget,
                         others: [blocker]),
            config: unlimited)
        #expect(option(plan, pocket: .cornerTopRight) == nil)
    }

    @Test func ballOffToTheSideOfTheLaneDoesNotBlock() {
        let plan = ShotPlanner.plan(
            state: state(cue: diagonalCue, target: diagonalTarget,
                         others: [Vec2(-0.5, 0.3)]),
            config: unlimited)
        #expect(option(plan, pocket: .cornerTopRight) != nil)
    }

    @Test func cueBallBeyondThePocketSideCannotCutIt() {
        // Cue ball is past the target on the pocket side: the cut would be
        // over 90°, so the shot is impossible.
        let plan = ShotPlanner.plan(state: state(cue: Vec2(1.2, 0.2),
                                                 target: diagonalTarget),
                                    config: unlimited)
        #expect(option(plan, pocket: .cornerTopRight) == nil)
    }

    @Test func ballHuggingTheRailCannotBePottedAwayFromIt() {
        // Ghost ball would have to sit inside the rail.
        let plan = ShotPlanner.plan(state: state(cue: Vec2(0.0, -0.3),
                                                 target: Vec2(0.5, 0.60)),
                                    config: unlimited)
        #expect(option(plan, pocket: .cornerBottomLeft) == nil)
    }

    @Test func obliqueSidePocketApproachIsRejectedButStraightOneAccepted() throws {
        // Ball at (0.5, 0): 38° off the side pocket's axis (limit 29°).
        let oblique = ShotPlanner.plan(state: state(cue: Vec2(0.5, -0.5),
                                                    target: Vec2(0.5, 0)),
                                       config: unlimited)
        #expect(option(oblique, pocket: .sideTop) == nil)

        // Ball at (0.1, 0): object line tilts asin(0.1/0.643) = 8.95° off
        // the pocket axis; the ghost offset adds atan(0.009/0.4435) = 1.16°
        // of approach tilt → cut ≈ 10.1°.
        let straight = ShotPlanner.plan(state: state(cue: Vec2(0.1, -0.5),
                                                     target: Vec2(0.1, 0)),
                                        config: unlimited)
        let shot = try #require(option(straight, pocket: .sideTop))
        #expect(abs(shot.cutAngleDegrees - 10.1) < 0.2)
    }

    @Test func resultsAreSortedEasiestFirstAndCapped() {
        let balls = state(cue: Vec2(-0.6, -0.1), target: Vec2(0.4, 0.2),
                          others: [Vec2(0.9, -0.3), Vec2(-0.2, 0.35)])
        let all = ShotPlanner.plan(state: balls, config: unlimited)
        // Three viable: the (0.4, 0.2) ball → bottom-right corner is
        // correctly blocked by the (0.9, -0.3) ball lying ~0.02 m off its line.
        #expect(all.count >= 3)
        #expect(zip(all, all.dropFirst()).allSatisfy { $0.difficulty <= $1.difficulty })
        #expect(all.allSatisfy { (0...1).contains($0.difficulty) })

        let capped = ShotPlanner.plan(state: balls,
                                      config: ShotPlanner.Config(maxOptions: 2))
        #expect(capped == Array(all.prefix(2)))
    }

    @Test func excludedBallsAreNeverOffered() {
        let balls = state(cue: diagonalCue, target: diagonalTarget,
                          others: [Vec2(-0.5, 0.3)])
        var config = unlimited
        config.excludedBalls = [targetID]
        let plan = ShotPlanner.plan(state: balls, config: config)
        #expect(plan.allSatisfy { $0.target != targetID })
    }

    @Test func noCueBallMeansNoPlan() {
        let noCue = TableState(table: table, balls: [
            Ball(id: targetID, kind: .solid(5), position: diagonalTarget)
        ])
        #expect(ShotPlanner.plan(state: noCue).isEmpty)
    }

    @Test func difficultyGrowsWithCutAndWithDistance() {
        let length = 2.54
        let base = ShotPlanner.score(cut: 10, cueDistance: 0.5,
                                     pocketDistance: 0.5, jawUse: 0.2,
                                     tableLength: length)
        #expect(ShotPlanner.score(cut: 50, cueDistance: 0.5, pocketDistance: 0.5,
                                  jawUse: 0.2, tableLength: length) > base)
        #expect(ShotPlanner.score(cut: 10, cueDistance: 1.5, pocketDistance: 1.0,
                                  jawUse: 0.2, tableLength: length) > base)
        #expect(ShotPlanner.score(cut: 10, cueDistance: 0.5, pocketDistance: 0.5,
                                  jawUse: 0.9, tableLength: length) > base)
        #expect(ShotPlanner.score(cut: 90, cueDistance: 9, pocketDistance: 9,
                                  jawUse: 5, tableLength: length) == 1)
    }

    // MARK: - Selection hysteresis

    private func fake(_ id: Int, difficulty: Double) -> ShotOption {
        ShotOption(target: BallID(id), targetKind: .solid(id), pocket: .sideTop,
                   targetPosition: .zero, pocketPosition: .zero,
                   pocketCaptureRadius: Table.sideCaptureRadius,
                   ghostBall: .zero, aim: AimRay(origin: .zero, direction: Vec2(1, 0)),
                   cutAngleDegrees: 0, cueDistance: 1, pocketDistance: 1,
                   difficulty: difficulty)
    }

    @Test func selectionKeepsPreviousPickWithinMarginAndSwitchesBeyondIt() {
        let options = [fake(1, difficulty: 0.20), fake(2, difficulty: 0.25),
                       fake(3, difficulty: 0.50)]
        // Within the 0.08 margin of the best → keep the previous pick.
        #expect(ShotPlanner.select(previous: options[1].id, among: options)?.id
                == options[1].id)
        // 0.30 worse than the best → switch to the best.
        #expect(ShotPlanner.select(previous: options[2].id, among: options)?.id
                == options[0].id)
        // Previous pick no longer viable → best.
        #expect(ShotPlanner.select(previous: "gone", among: options)?.id
                == options[0].id)
        // No previous → best; nothing to pick → nil.
        #expect(ShotPlanner.select(previous: nil, among: options)?.id
                == options[0].id)
        #expect(ShotPlanner.select(previous: nil, among: []) == nil)
    }

    // MARK: - Cross-check against the real trajectory solver

    @Test func plannedShotsActuallyPotTheTargetInTheSolver() throws {
        // Every unblocked straight-ish option the planner offers for this
        // layout must drop its target when run through AnalyticSolver at a
        // firm speed. Guards the planner's geometry against the physics.
        let balls = state(cue: Vec2(-0.7, -0.1), target: Vec2(0.45, 0.25))
        let plan = ShotPlanner.plan(state: balls, config: unlimited)
        let solver = AnalyticSolver()
        var verified = 0
        for shot in plan where shot.cutAngleDegrees < 35 {
            let prediction = solver.predict(
                state: balls, aim: shot.aim,
                options: SolverOptions(initialSpeed: 3.5))
            #expect(prediction.pocketedBalls.contains(shot.target),
                    "\(shot.title) cut \(shot.cutAngleDegrees)° did not pot")
            let pocketEvent = prediction.events.contains {
                if case .pocket(let ball, let pocket) = $0 {
                    return ball == shot.target && pocket == shot.pocket
                }
                return false
            }
            #expect(pocketEvent, "\(shot.title) potted in the wrong pocket")
            verified += 1
        }
        #expect(verified > 0)
    }
}
