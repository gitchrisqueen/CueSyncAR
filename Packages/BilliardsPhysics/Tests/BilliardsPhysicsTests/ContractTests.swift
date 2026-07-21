import CueSyncCore
import CueSyncTestSupport
import Testing
@testable import BilliardsPhysics

@Suite("AnalyticSolver — provider contract")
struct SolverContractTests {
    @Test func meetsTrajectorySolvingContract() {
        let failures = ProviderContracts.checkTrajectorySolver(AnalyticSolver())
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test func fullRackBreakTerminates() {
        // Smoke: a full rack with a hard break must terminate within the
        // event budget and keep every rest position on the table.
        let state = TableStateFixtures.eightBallRack()
        let cue = state.cueBall!
        let prediction = AnalyticSolver().predict(
            state: state,
            aim: AimRay(origin: cue.position, direction: Vec2(1, 0)),
            options: SolverOptions(initialSpeed: 5.0, maxEvents: 12))
        #expect(!prediction.segments.isEmpty)
        for event in prediction.events {
            if case let .rest(_, point) = event {
                #expect(state.table.contains(point, ballRadius: 0))
            }
        }
    }
}
