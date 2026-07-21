import Foundation
import Testing
@testable import CueSyncCore

@Suite("Table geometry")
struct TableTests {
    @Test(arguments: TableSize.standardSizes + [TableSize.custom(width: 1.58, height: 0.76)])
    func pocketsDerivedFromSize(size: TableSize) {
        let table = Table(size: size)
        #expect(table.pockets.count == 6)
        let he = table.halfExtents
        let corners = table.pockets.filter { $0.id.rawValue.hasPrefix("corner") }
        #expect(corners.count == 4)
        for pocket in corners {
            #expect(abs(abs(pocket.position.x) - he.x) < 1e-12)
            #expect(abs(abs(pocket.position.y) - he.y) < 1e-12)
        }
        let sides = table.pockets.filter { $0.id.rawValue.hasPrefix("side") }
        #expect(sides.count == 2)
        for pocket in sides {
            #expect(abs(pocket.position.x) < 1e-12)
            #expect(abs(abs(pocket.position.y) - he.y) < 1e-12)
        }
    }

    @Test func sizeInference() {
        #expect(TableSize.inferred(width: 2.54, height: 1.27) == .nineFoot)
        #expect(TableSize.inferred(width: 2.51, height: 1.29) == .nineFoot)
        // Orientation-agnostic.
        #expect(TableSize.inferred(width: 1.17, height: 2.34) == .eightFoot)
        // Way off spec → nil (inference never invents a custom size).
        #expect(TableSize.inferred(width: 3.5, height: 1.0) == nil)
    }

    @Test func customSizeCarriesMeasuredPlayFieldAndRoundTrips() throws {
        let size = TableSize.custom(width: 1.58, height: 0.76)
        #expect(size.playField.width == 1.58)
        #expect(size.playField.height == 0.76)
        let data = try JSONEncoder().encode(size)
        let decoded = try JSONDecoder().decode(TableSize.self, from: data)
        #expect(decoded == size)
        // Standard sizes still encode/decode alongside the custom case.
        let nine = try JSONDecoder().decode(
            TableSize.self, from: JSONEncoder().encode(TableSize.nineFoot))
        #expect(nine == .nineFoot)
    }

    @Test func containment() {
        let table = Table(size: .nineFoot)
        #expect(table.contains(.zero))
        #expect(table.contains(Vec2(1.27, 0.635)))
        #expect(!table.contains(Vec2(1.30, 0)))
        // Ball radius shrinks the reachable field.
        #expect(!table.contains(Vec2(1.26, 0), ballRadius: 0.028575))
    }
}

@Suite("Ball classification")
struct BallKindTests {
    @Test func classLabelMapping() {
        #expect(Ball.Kind(classLabel: "cue") == .cue)
        #expect(Ball.Kind(classLabel: "white") == .cue)
        #expect(Ball.Kind(classLabel: "8") == .eight)
        #expect(Ball.Kind(classLabel: "ball-8") == .eight)
        #expect(Ball.Kind(classLabel: "3") == .solid(3))
        #expect(Ball.Kind(classLabel: "solid-7") == .solid(7))
        #expect(Ball.Kind(classLabel: "ball-12") == .stripe(12))
        #expect(Ball.Kind(classLabel: "chalk") == .unknown)
        #expect(Ball.Kind(classLabel: "16") == .unknown)
    }
}

@Suite("Codable round-trips")
struct CodableTests {
    @Test func tableStateRoundTrip() throws {
        let state = TableState(
            table: Table(size: .nineFoot),
            balls: [
                Ball(id: BallID(0), kind: .cue, position: Vec2(-0.5, 0)),
                Ball(id: BallID(9), kind: .stripe(9), position: Vec2(0.3, 0.1), confidence: 0.93)
            ],
            timestamp: 12.5
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TableState.self, from: data)
        #expect(decoded == state)
    }

    @Test func predictionRoundTrip() throws {
        let prediction = ShotPrediction(
            segments: [TrajectorySegment(ballID: BallID(0), start: .zero,
                                         end: Vec2(1, 0), kind: .roll, entrySpeed: 2)],
            events: [
                .ballBall(moving: BallID(0), struck: BallID(3), contact: Vec2(1, 0)),
                .cushion(ball: BallID(3), point: Vec2(1.2, 0.6)),
                .pocket(ball: BallID(3), pocket: .cornerTopRight),
                .rest(ball: BallID(0), point: Vec2(0.9, 0.1))
            ],
            pocketedBalls: [BallID(3)]
        )
        let data = try JSONEncoder().encode(prediction)
        let decoded = try JSONDecoder().decode(ShotPrediction.self, from: data)
        #expect(decoded == prediction)
        #expect(decoded.firstContact?.struck == BallID(3))
        #expect(!decoded.isScratch(cueBall: BallID(0)))
    }
}

@Suite("Provider registry")
struct RegistryTests {
    struct FakeSolver: TrajectorySolving {
        func predict(state: TableState, aim: AimRay, options: SolverOptions) -> ShotPrediction {
            ShotPrediction()
        }
    }

    @Test func registerAndResolve() async throws {
        let registry = ProviderRegistry()
        await registry.register(FakeSolver() as any TrajectorySolving)
        let solver = try await registry.resolve((any TrajectorySolving).self)
        #expect(solver is FakeSolver)
    }

    @Test func unregisteredThrows() async {
        let registry = ProviderRegistry()
        await #expect(throws: ProviderRegistry.RegistryError.self) {
            _ = try await registry.resolve((any DetectionProviding).self)
        }
        let missing = await registry.resolveIfRegistered((any CoachProviding).self)
        #expect(missing == nil)
    }

    @Test func lastRegistrationWins() async throws {
        let registry = ProviderRegistry()
        await registry.register(StaticSecrets([.roboflowAPIKey: "a"]) as any SecretsProviding)
        await registry.register(StaticSecrets([.roboflowAPIKey: "b"]) as any SecretsProviding)
        let secrets = try await registry.resolve((any SecretsProviding).self)
        #expect(secrets.secret(for: .roboflowAPIKey) == "b")
    }
}

@Suite("Secrets")
struct SecretsTests {
    @Test func staticSecrets() {
        let secrets = StaticSecrets([.anthropicAPIKey: "test-key"])
        #expect(secrets.secret(for: .anthropicAPIKey) == "test-key")
        #expect(secrets.secret(for: .roboflowAPIKey) == nil)
    }

    @Test func environmentSecretsMissingKeyIsNil() {
        let secrets = EnvironmentSecrets()
        #expect(secrets.secret(for: SecretKey(rawValue: "CUESYNC_DEFINITELY_UNSET_KEY")) == nil)
    }
}
