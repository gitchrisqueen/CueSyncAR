import CueSyncCore
import Foundation
import TableSpace
import Testing
@testable import ARExperience

/// Table in the world xz-plane (y up), centered at the origin.
private let calibration = TableCalibration(origin: .zero,
                                           xAxis: Vec3(1, 0, 0),
                                           yAxis: Vec3(0, 0, -1),
                                           size: .nineFoot)

/// Camera 1 m behind the cue ball (along −x) and 0.6 m up, looking down
/// the table: the device-pose model aims along +x.
private let cameraBehindCue = Transform3D(columns: [
    SIMD4(0, 0, 1, 0),                 // camera x → world +z
    SIMD4(0, 1, 0, 0),                 // camera y → world +y
    SIMD4(-1, 0, 0, 0),                // camera −z → world +x (looking down-table)
    SIMD4(-1.5, 0.6, 0, 1)
])

/// Stick lying along +x, tip 0.1 m short of the cue ball at (−0.5, 0).
private let stickQuad: [Vec2] = [
    Vec2(-1.6, 0.02), Vec2(-0.6, 0.02), Vec2(-0.6, -0.02), Vec2(-1.6, -0.02)
]
private let cueBall = Vec2(-0.5, 0)

@Suite("AimResolver")
struct AimResolverTests {
    @Test func stickWinsWhenAddressingTheBall() {
        var resolver = AimResolver()
        let (aim, source) = resolver.resolve(stickQuad: stickQuad, cueBall: cueBall,
                                             cameraTransform: cameraBehindCue,
                                             calibration: calibration, at: 10)
        #expect(source == .stick)
        #expect(resolver.source == .stick)
        #expect(aim?.direction.x ?? 0 > 0.99)
    }

    @Test func fallsBackToDevicePoseWithoutAStick() throws {
        var resolver = AimResolver()
        let (aim, source) = resolver.resolve(stickQuad: nil, cueBall: cueBall,
                                             cameraTransform: cameraBehindCue,
                                             calibration: calibration, at: 10)
        #expect(source == .devicePose)
        let ray = try #require(aim)
        #expect(ray.origin == cueBall)
        #expect(ray.direction.x > 0.99)
    }

    @Test func defaultHoldIsTheMeasuredTwoAndAHalfSeconds() {
        #expect(AimResolver.Config.default.stickHoldSeconds == 2.5)
    }

    @Test func holdsTheLastStickAimForTheWindowInSeconds() throws {
        var resolver = AimResolver(config: AimResolver.Config(stickHoldSeconds: 1.2))
        let (stickAim, _) = resolver.resolve(stickQuad: stickQuad, cueBall: cueBall,
                                             cameraTransform: cameraBehindCue,
                                             calibration: calibration, at: 100.0)
        // Stick drops out: held for 1.2 s from when it was LAST seen,
        // regardless of how many updates land in that window.
        for time in [100.1, 100.5, 100.9, 101.15] {
            let (aim, source) = resolver.resolve(stickQuad: nil, cueBall: cueBall,
                                                 cameraTransform: cameraBehindCue,
                                                 calibration: calibration, at: time)
            #expect(source == .stick, "still held at \(time)")
            #expect(aim == stickAim)
        }
        let (_, expired) = resolver.resolve(stickQuad: nil, cueBall: cueBall,
                                            cameraTransform: cameraBehindCue,
                                            calibration: calibration, at: 101.21)
        #expect(expired == .devicePose)
    }

    @Test func seeingTheStickAgainRestartsTheHold() {
        var resolver = AimResolver(config: AimResolver.Config(stickHoldSeconds: 1.0))
        _ = resolver.resolve(stickQuad: stickQuad, cueBall: cueBall,
                             cameraTransform: cameraBehindCue, calibration: calibration, at: 0)
        _ = resolver.resolve(stickQuad: nil, cueBall: cueBall,
                             cameraTransform: cameraBehindCue, calibration: calibration, at: 0.9)
        _ = resolver.resolve(stickQuad: stickQuad, cueBall: cueBall,
                             cameraTransform: cameraBehindCue, calibration: calibration, at: 1.0)
        let (_, source) = resolver.resolve(stickQuad: nil, cueBall: cueBall,
                                           cameraTransform: cameraBehindCue,
                                           calibration: calibration, at: 1.9)
        #expect(source == .stick)
    }

    @Test func clockJumpingBackwardsDoesNotResurrectAStaleHold() {
        var resolver = AimResolver(config: AimResolver.Config(stickHoldSeconds: 1.0))
        _ = resolver.resolve(stickQuad: stickQuad, cueBall: cueBall,
                             cameraTransform: cameraBehindCue, calibration: calibration, at: 50)
        let (_, source) = resolver.resolve(stickQuad: nil, cueBall: cueBall,
                                           cameraTransform: cameraBehindCue,
                                           calibration: calibration, at: 10)
        #expect(source == .devicePose)
    }

    @Test func resetForgetsTheHeldAim() {
        var resolver = AimResolver()
        _ = resolver.resolve(stickQuad: stickQuad, cueBall: cueBall,
                             cameraTransform: cameraBehindCue, calibration: calibration, at: 0)
        resolver.reset()
        #expect(resolver.source == .devicePose)
        let (_, source) = resolver.resolve(stickQuad: nil, cueBall: cueBall,
                                           cameraTransform: cameraBehindCue,
                                           calibration: calibration, at: 0.1)
        #expect(source == .devicePose)
    }
}

@Suite("ShotPlanner")
struct ShotPlannerTests {
    /// Solver stub: one segment per call, straight along the aim, tagged
    /// with the launch speed so re-solves are observable.
    final class CountingSolver: TrajectorySolving, @unchecked Sendable {
        private(set) var calls = 0
        func predict(state: TableState, aim: AimRay, options: SolverOptions) -> ShotPrediction {
            calls += 1
            let cue = state.cueBall?.id ?? BallID(0)
            return ShotPrediction(segments: [
                TrajectorySegment(ballID: cue, start: aim.origin,
                                  end: aim.origin + aim.direction * 0.5,
                                  entrySpeed: options.initialSpeed)
            ])
        }
    }

    private func state(cueAt position: Vec2 = cueBall) -> TableState {
        TableState(table: Table(size: .nineFoot), balls: [
            Ball(id: BallID(0), kind: .cue, position: position),
            Ball(id: BallID(1), kind: .unknown, position: Vec2(0.3, 0.1))
        ], timestamp: 1)
    }

    @Test func noCueBallMeansNoPlan() {
        let solver = CountingSolver()
        var planner = ShotPlanner(solver: solver)
        let empty = TableState(table: Table(size: .nineFoot), balls: [])
        let (plan, changed) = planner.update(state: empty, stickQuad: nil,
                                             cameraTransform: cameraBehindCue,
                                             calibration: calibration, at: 0)
        #expect(plan == nil)
        #expect(!changed)
        #expect(solver.calls == 0)
    }

    @Test func solvesOnceThenHoldsInsideTheDeadband() throws {
        let solver = CountingSolver()
        var planner = ShotPlanner(solver: solver, guideSpeed: 3.5)
        let first = planner.update(state: state(), stickQuad: nil,
                                   cameraTransform: cameraBehindCue,
                                   calibration: calibration, at: 0)
        #expect(first.changed)
        let plan = try #require(first.plan)
        #expect(plan.source == .devicePose)
        #expect(plan.prediction.segments.first?.entrySpeed == 3.5)
        #expect(solver.calls == 1)

        // Same aim, jitter-only state with a new timestamp: no re-solve.
        var jittered = state()
        jittered.timestamp = 2
        jittered.balls[0].position += Vec2(0.0005, -0.0004)
        let second = planner.update(state: jittered, stickQuad: nil,
                                    cameraTransform: cameraBehindCue,
                                    calibration: calibration, at: 0.15)
        #expect(!second.changed)
        #expect(second.plan == plan)
        #expect(solver.calls == 1)
    }

    @Test func layoutChangeForcesAReSolve() {
        let solver = CountingSolver()
        var planner = ShotPlanner(solver: solver)
        _ = planner.update(state: state(), stickQuad: nil, cameraTransform: cameraBehindCue,
                           calibration: calibration, at: 0)
        var moved = state()
        moved.balls[1].position += Vec2(0.02, 0)
        let result = planner.update(state: moved, stickQuad: nil,
                                    cameraTransform: cameraBehindCue,
                                    calibration: calibration, at: 0.15)
        #expect(result.changed)
        #expect(solver.calls == 2)
    }

    @Test func guideSpeedChangeInvalidatesThePlan() {
        let solver = CountingSolver()
        var planner = ShotPlanner(solver: solver, guideSpeed: 3.5)
        _ = planner.update(state: state(), stickQuad: nil, cameraTransform: cameraBehindCue,
                           calibration: calibration, at: 0)
        planner.guideSpeed = 2.0
        let result = planner.update(state: state(), stickQuad: nil,
                                    cameraTransform: cameraBehindCue,
                                    calibration: calibration, at: 0.15)
        #expect(result.changed)
        #expect(result.plan?.prediction.segments.first?.entrySpeed == 2.0)
        #expect(solver.calls == 2)
    }

    @Test func stickTakesOverAndIsHeldAcrossDropouts() {
        let solver = CountingSolver()
        var planner = ShotPlanner(solver: solver)
        _ = planner.update(state: state(), stickQuad: nil, cameraTransform: cameraBehindCue,
                           calibration: calibration, at: 0)
        let withStick = planner.update(state: state(), stickQuad: stickQuad,
                                       cameraTransform: cameraBehindCue,
                                       calibration: calibration, at: 0.2)
        #expect(withStick.plan?.source == .stick)
        #expect(planner.aimSource == .stick)
        let held = planner.update(state: state(), stickQuad: nil,
                                  cameraTransform: cameraBehindCue,
                                  calibration: calibration, at: 0.9)
        #expect(held.plan?.source == .stick)
        let stillHeld = planner.update(state: state(), stickQuad: nil,
                                       cameraTransform: cameraBehindCue,
                                       calibration: calibration, at: 2.6)
        #expect(stillHeld.plan?.source == .stick)
        // Default hold is 2.5 s after the last fresh stick (t = 0.2).
        let expired = planner.update(state: state(), stickQuad: nil,
                                     cameraTransform: cameraBehindCue,
                                     calibration: calibration, at: 2.75)
        #expect(expired.plan?.source == .devicePose)
    }

    @Test func losingTheCueBallClearsThePlanAndReportsTheChange() {
        let solver = CountingSolver()
        var planner = ShotPlanner(solver: solver)
        _ = planner.update(state: state(), stickQuad: nil, cameraTransform: cameraBehindCue,
                           calibration: calibration, at: 0)
        var noCue = state()
        noCue.balls[0].kind = .unknown
        let result = planner.update(state: noCue, stickQuad: nil,
                                    cameraTransform: cameraBehindCue,
                                    calibration: calibration, at: 0.15)
        #expect(result.plan == nil)
        #expect(result.changed)
        #expect(planner.plan == nil)
    }

    @Test func resetForgetsEverything() {
        let solver = CountingSolver()
        var planner = ShotPlanner(solver: solver)
        _ = planner.update(state: state(), stickQuad: stickQuad, cameraTransform: cameraBehindCue,
                           calibration: calibration, at: 0)
        planner.reset()
        #expect(planner.plan == nil)
        #expect(planner.aimSource == .devicePose)
        let after = planner.update(state: state(), stickQuad: nil,
                                   cameraTransform: cameraBehindCue,
                                   calibration: calibration, at: 0.1)
        #expect(after.plan?.source == .devicePose)
        #expect(solver.calls == 2)
    }

    @Test func layoutMovedIgnoresTimestampsAndSubToleranceJitter() {
        let a = state()
        var b = a
        b.timestamp = 99
        b.balls[1].position += Vec2(0.004, 0)
        #expect(!ShotPlanner.layoutMoved(from: a, to: b, tolerance: 0.005))
        b.balls[1].kind = .solid(1)
        #expect(ShotPlanner.layoutMoved(from: a, to: b, tolerance: 0.005))
        #expect(ShotPlanner.layoutMoved(from: nil, to: a, tolerance: 0.005))
    }
}
