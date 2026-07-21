import CueSyncCore
import Foundation
import Testing
@testable import CueSyncTestSupport

@Suite("Table state fixtures")
struct TableStateFixtureTests {
    @Test func eightBallRackIsWellFormed() {
        let state = TableStateFixtures.eightBallRack()
        #expect(state.balls.count == 16)
        #expect(state.cueBall != nil)
        #expect(state.balls.contains { $0.kind == .eight })

        // All balls on the table.
        for ball in state.balls {
            #expect(state.table.contains(ball.position, ballRadius: ball.radius),
                    "ball \(ball.id.rawValue) off table at \(ball.position)")
        }
        // No overlaps.
        for (i, a) in state.balls.enumerated() {
            for b in state.balls.dropFirst(i + 1) {
                #expect(a.position.distance(to: b.position) >= a.radius + b.radius - 1e-9,
                        "balls \(a.id.rawValue) and \(b.id.rawValue) overlap")
            }
        }
        // IDs unique.
        #expect(Set(state.balls.map(\.id)).count == 16)
    }
}

@Suite("Fixture provider contracts")
struct ContractSelfTests {
    @Test func fixtureDetectionProviderMeetsContract() async {
        let provider = FixtureDetectionProvider(constant: [
            Detection2D(classLabel: "cue",
                        boundingBox: NormalizedRect(x: 0.4, y: 0.5, width: 0.05, height: 0.05),
                        confidence: 0.98)
        ])
        let failures = await ProviderContracts.checkDetectionProvider(provider)
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test func fixtureDetectionProviderReplaysFramesInOrder() async throws {
        let frame1 = [Detection2D(classLabel: "cue",
                                  boundingBox: NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.1),
                                  confidence: 0.9)]
        let frame2: [Detection2D] = []
        let provider = FixtureDetectionProvider(frames: [frame1, frame2])
        let sample = CapturedFrame(timestamp: 0, cameraTransform: .identity,
                                   image: FixtureImageBuffer())
        let first = try await provider.detect(in: sample)
        let second = try await provider.detect(in: sample)
        let third = try await provider.detect(in: sample)
        #expect(first == frame1)
        #expect(second == frame2)
        #expect(third == frame1) // loops
    }

    @Test func staticSolverMeetsContract() {
        let failures = ProviderContracts.checkTrajectorySolver(StaticSolver())
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test func mockCoachMeetsContract() async {
        let failures = await ProviderContracts.checkCoach(MockCoach())
        #expect(failures.isEmpty, "\(failures)")
    }
}
