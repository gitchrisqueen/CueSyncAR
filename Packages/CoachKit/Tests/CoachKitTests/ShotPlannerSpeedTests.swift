//
//  ShotPlannerSpeedTests.swift
//  CoachKitTests
//
//  Speed budget: the shot advisor re-plans every camera frame, so `plan`
//  must stay cheap even with all 16 balls on the table. The budget is only
//  enforced in release builds; debug builds are several times slower, so
//  there the test still runs the planner (and checks it produced shots)
//  but does not hold it to the number.
//

import CueSyncCore
import CueSyncTestSupport
import Foundation
import Testing
@testable import CoachKit

@Suite("ShotPlanner speed")
struct ShotPlannerSpeedTests {
    /// Mean wall time per `plan` call must stay under this in release.
    static let budgetMilliseconds = 5.0
    static let iterations = 200

    /// Plans `iterations` times and returns (mean milliseconds, option count).
    /// The cue ball moves a hair (0.1 micrometre) per call so every call has
    /// a distinct input and the optimizer cannot hoist a pure call out of
    /// the loop; the layout stays effectively unchanged.
    private func measure(_ state: TableState) -> (mean: Double, options: Int) {
        let config = ShotPlanner.Config()
        let cueIndex = state.balls.firstIndex { $0.kind == .cue } ?? 0
        var frames: [TableState] = []
        for index in 0..<Self.iterations {
            var frame = state
            frame.balls[cueIndex].position.x += Double(index) * 1e-7
            frames.append(frame)
        }
        // One warm-up call outside the clock.
        var options = ShotPlanner.plan(state: state, config: config).count
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for frame in frames {
                options = ShotPlanner.plan(state: frame, config: config).count
            }
        }
        let parts = elapsed.components
        let total = Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
        return (total / Double(Self.iterations), options)
    }

    private func check(_ name: String, _ state: TableState, expectShots: Bool) {
        #expect(state.balls.count == 16, "\(name) must hold 16 balls")
        let result = measure(state)
        print("SPEED \(name) balls=\(state.balls.count) options=\(result.options) "
              + "mean=\(String(format: "%.3f", result.mean)) ms over \(Self.iterations) calls")
        #expect((result.options > 0) == expectShots,
                "\(name): \(result.options) options, expected shots: \(expectShots)")
        #if DEBUG
        // Debug build: ran once for coverage; the budget is a release number.
        #else
        #expect(result.mean < Self.budgetMilliseconds,
                "\(name): mean \(result.mean) ms exceeds \(Self.budgetMilliseconds) ms")
        #endif
    }

    /// At the break every lane to every pocket is blocked by the rack, so
    /// the planner correctly offers nothing; the call is mostly early exits
    /// and is timed anyway as the cheap end of the range.
    @Test func standardRackPlansWithinBudget() {
        check("rack", TableStateFixtures.eightBallRack(), expectShots: false)
    }

    /// 16 balls spread over the table: the expensive case, with many
    /// (ball, pocket) pairs surviving to the lane checks.

    @Test func scatteredSixteenBallLayoutPlansWithinBudget() {
        check("scattered", LayoutGenerator.layout(seed: 2_026, count: 16), expectShots: true)
    }
}
