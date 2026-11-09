//
//  ShotRankingSpeedTests.swift
//  CoachKitTests
//
//  Speed budget: the app re-ranks on every pipeline output
//  (`SessionModel.recomputeRanking` -> `ShotSelection.update`), so ranking
//  must stay cheap with all 16 balls on the table. The budget is enforced
//  in release builds only; debug builds are several times slower, so there
//  the test still runs the work (and checks it produced shots) but does
//  not hold it to the number.
//

import CueSyncCore
import Foundation
import Testing
@testable import CoachKit

@Suite("ShotRanking speed")
struct ShotRankingSpeedTests {
    /// Mean wall time per call must stay under this in release.
    static let budgetMilliseconds = 5.0
    static let iterations = 200

    /// Frames that differ by 0.1 micrometre on the cue ball, so every call
    /// has a distinct input and the optimizer cannot hoist a pure call out
    /// of the loop; the layout is effectively unchanged.
    private func frames(of state: TableState) -> [TableState] {
        let cueIndex = state.balls.firstIndex { $0.kind == .cue } ?? 0
        return (0..<Self.iterations).map { index in
            var frame = state
            frame.balls[cueIndex].position.x += Double(index) * 1e-7
            return frame
        }
    }

    private func milliseconds(_ elapsed: Duration) -> Double {
        let parts = elapsed.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    @Test func rankingSixteenBallsStaysUnderBudget() {
        // Sixteen random balls, and the dense standard rack: the worst case
        // for corridor checks is a cluster, not a scatter.
        var layouts = [("scatter", LayoutGenerator.layout(seed: 11, count: 16))]
        layouts.append(("rack", Self.rack()))
        for (name, state) in layouts {
            #expect(state.balls.count == 16, "\(name) must hold 16 balls")
            let inputs = frames(of: state)
            var offered = ShotRanking.best(state: state).count      // warm-up
            var selection = ShotSelection()
            let clock = ContinuousClock()
            let rankElapsed = clock.measure {
                for frame in inputs { offered = ShotRanking.best(state: frame).count }
            }
            let updateElapsed = clock.measure {
                for frame in inputs {
                    selection.update(state: frame, group: .any, config: .intermediate)
                }
            }
            let rankMean = milliseconds(rankElapsed) / Double(Self.iterations)
            let updateMean = milliseconds(updateElapsed) / Double(Self.iterations)
            print("SPEED \(name) balls=\(state.balls.count) rows=\(offered) "
                  + "best=\(String(format: "%.3f", rankMean)) ms "
                  + "selection.update=\(String(format: "%.3f", updateMean)) ms "
                  + "over \(Self.iterations) calls")
            #expect(offered > 0, "\(name): nothing ranked")
            #if DEBUG
            // Debug build: ran once for coverage; the budget is a release number.
            #else
            #expect(rankMean < Self.budgetMilliseconds,
                    "\(name): best() mean \(rankMean) ms exceeds \(Self.budgetMilliseconds) ms")
            #expect(updateMean < Self.budgetMilliseconds,
                    "\(name): update() mean \(updateMean) ms exceeds \(Self.budgetMilliseconds) ms")
            #endif
        }
    }

    /// The standard eight-ball rack with the cue ball behind the head
    /// string; written here because CoachKit's tests do not link
    /// CueSyncTestSupport.
    private static func rack() -> TableState {
        let table = LayoutGenerator.table
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
