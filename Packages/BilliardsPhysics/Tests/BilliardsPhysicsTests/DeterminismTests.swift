import CueSyncCore
import Foundation
import Testing
@testable import BilliardsPhysics

@Suite("AnalyticSolver — determinism")
struct SolverDeterminismTests {
    /// Two object balls mirrored about the aim line at EXACTLY the same
    /// travel distance: the struck ball must be the lower id regardless of
    /// the order balls were added (the stationary set used to be walked in
    /// dictionary order, which is randomized per process).
    @Test func symmetricFrozenPairResolvesToTheLowerID() {
        let cue = Ball(id: BallID(0), kind: .cue, position: Vec2(-0.5, 0))
        let r = Ball.standardRadius
        // Centers at x = 0, y = ±r: the cue ball's swept circle (radius 2r)
        // reaches both at the same t.
        let upper = Ball(id: BallID(3), kind: .solid(3), position: Vec2(0, r))
        let lower = Ball(id: BallID(7), kind: .solid(7), position: Vec2(0, -r))
        let aim = AimRay(origin: cue.position, direction: Vec2(1, 0))
        let solver = AnalyticSolver()

        var struckIDs: Set<Int> = []
        for balls in [[cue, upper, lower], [cue, lower, upper]] {
            for _ in 0..<10 {
                let state = TableState(table: Table(size: .nineFoot), balls: balls)
                let prediction = solver.predict(state: state, aim: aim, options: .default)
                if let contact = prediction.firstContact {
                    struckIDs.insert(contact.struck.rawValue)
                }
            }
        }
        #expect(struckIDs == [3])
    }

    @Test func repeatedSolvesAreBitIdentical() {
        let state = TableState(table: Table(size: .eightFoot), balls: [
            Ball(id: BallID(0), kind: .cue, position: Vec2(-0.6, 0.1)),
            Ball(id: BallID(1), kind: .solid(1), position: Vec2(0.2, 0.15)),
            Ball(id: BallID(2), kind: .solid(2), position: Vec2(0.5, -0.3)),
            Ball(id: BallID(3), kind: .stripe(9), position: Vec2(0.8, 0.4))
        ])
        let aim = AimRay(origin: Vec2(-0.6, 0.1), direction: Vec2(1, 0.07))
        let solver = AnalyticSolver()
        let reference = solver.predict(state: state, aim: aim,
                                       options: SolverOptions(initialSpeed: 3.5))
        for _ in 0..<50 {
            #expect(solver.predict(state: state, aim: aim,
                                   options: SolverOptions(initialSpeed: 3.5)) == reference)
        }
    }
}
