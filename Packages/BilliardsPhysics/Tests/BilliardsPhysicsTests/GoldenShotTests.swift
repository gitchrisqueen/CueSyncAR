import CueSyncCore
import Foundation
import Testing
@testable import BilliardsPhysics

// M1-03 golden scenario suite.
//
// Each JSON file in Fixtures/GoldenShots encodes one canonical shot
// (`state + aim + options -> expected prediction`) whose expected trajectory
// was derived BY HAND from the model in Docs/PhysicsModel.md — the math is
// spelled out in each fixture's `derivation` array. The fixtures are frozen
// regressions: per docs/roadmap/04-TESTING-STRATEGY.md they must never be
// silently regenerated; if solver outputs change, escalate to the maintainer
// (07-AGENT-PLAYBOOK.md) with a PR note explaining why.

/// Every frozen golden fixture. `goldenFixtureDirectoryMatchesManifest`
/// keeps this list in lockstep with the files on disk.
private let goldenFixtureNames: [String] = [
    "straightRollToRest",
    "headOnStopShot",
    "thirtyDegreeCut",
    "fortyFiveCushionBounce",
    "perpendicularCushionBounce",
    "cornerPocketScratch",
    "sidePocketScratch",
    "straightInCornerPot",
    "threeBallComboRekiss",
    "nearMissObjectBall",
    "rollsPastSidePocketMouth",
    "railLineRollIntoCornerJaw",
    "maxEventsBudgetExhausted",
    "tooSoftShotEmptyPrediction",
    "sevenFootSidePocketScratch",
    "customConfigCushionBounce",
    "threeFourFiveBankFortyFiveExit",
    "headOnDriveToCushionReturn",
    "cutShotPotsCorner",
    "doubleHeadOnBank"
]

private let goldenSubdirectory = "Fixtures/GoldenShots"

@Suite("AnalyticSolver — golden scenarios (M1-03)")
struct GoldenShotTests {
    @Test(arguments: goldenFixtureNames)
    func fixtureMatchesSolverOutput(name: String) throws {
        let fixture = try GoldenShotFixture.load(named: name)
        let solver = AnalyticSolver(config: fixture.physicsConfig)
        let prediction = solver.predict(state: fixture.tableState,
                                        aim: fixture.aimRay,
                                        options: fixture.solverOptions)
        fixture.verify(prediction)
    }

    @Test func fixtureDirectoryMatchesManifest() throws {
        let directory = try #require(
            Bundle.module.resourceURL?.appendingPathComponent(goldenSubdirectory),
            "golden fixture directory missing from test bundle")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let onDisk = Set(files.filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(".json".count)) })
        #expect(onDisk == Set(goldenFixtureNames),
                "fixture files and manifest diverged; on disk: \(onDisk.sorted())")
        #expect(goldenFixtureNames.count == Set(goldenFixtureNames).count)
    }
}

// MARK: - Fixture schema

/// Decoded golden fixture: solver inputs plus the hand-derived expectation.
struct GoldenShotFixture: Decodable {
    let name: String
    let description: String
    /// Human-readable math showing how `expected` was derived.
    let derivation: [String]
    let table: TableSpec
    let config: PhysicsConfig
    let balls: [BallSpec]
    let aim: AimSpec
    let options: SolverOptions
    /// Absolute tolerance for positions (m) and speeds (m/s).
    let tolerance: Double
    let expected: Expected

    struct TableSpec: Decodable {
        let size: String
    }

    struct BallSpec: Decodable {
        let id: Int
        /// Detector-style class label ("cue", "1"..."15", "8").
        let kind: String
        let position: [Double]
    }

    struct AimSpec: Decodable {
        let origin: [Double]
        let direction: [Double]
    }

    struct Expected: Decodable {
        let segments: [SegmentSpec]
        let events: [EventSpec]
        let pocketedBalls: [Int]
    }

    struct SegmentSpec: Decodable {
        let ball: Int
        let kind: String
        let start: [Double]
        let end: [Double]
        let entrySpeed: Double
    }

    struct EventSpec: Decodable {
        let type: String
        let ball: Int?
        let moving: Int?
        let struck: Int?
        let pocket: String?
        let point: [Double]?
        let contact: [Double]?
    }

    // MARK: Loading

    struct LoadError: Error, CustomStringConvertible {
        let description: String
    }

    static func load(named name: String) throws -> GoldenShotFixture {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json",
                                          subdirectory: goldenSubdirectory) else {
            throw LoadError(description: "missing golden fixture \(name).json")
        }
        let fixture = try JSONDecoder().decode(GoldenShotFixture.self,
                                               from: Data(contentsOf: url))
        guard fixture.name == name else {
            throw LoadError(description: "fixture \(name).json declares name \(fixture.name)")
        }
        return fixture
    }

    // MARK: Solver inputs

    var physicsConfig: PhysicsConfig { config }

    var solverOptions: SolverOptions { options }

    var tableSize: TableSize {
        switch table.size {
        case "sevenFoot": .sevenFoot
        case "eightFoot": .eightFoot
        case "nineFoot": .nineFoot
        default: fatalError("unknown table size \(table.size)")
        }
    }

    var tableState: TableState {
        TableState(table: Table(size: tableSize),
                   balls: balls.map {
                       Ball(id: BallID($0.id), kind: Ball.Kind(classLabel: $0.kind),
                            position: vec($0.position))
                   })
    }

    var aimRay: AimRay {
        AimRay(origin: vec(aim.origin), direction: vec(aim.direction))
    }

    // MARK: Verification

    func verify(_ prediction: ShotPrediction) {
        verifySegments(prediction)
        verifyEvents(prediction)
        #expect(prediction.pocketedBalls == expected.pocketedBalls.map { BallID($0) },
                "\(name): pocketed balls mismatch")
    }

    private func verifySegments(_ prediction: ShotPrediction) {
        #expect(prediction.segments.count == expected.segments.count,
                "\(name): expected \(expected.segments.count) segments, got \(prediction.segments)")
        for (index, (actual, spec)) in zip(prediction.segments, expected.segments).enumerated() {
            let label = "\(name) segment[\(index)]"
            #expect(actual.ballID == BallID(spec.ball), "\(label): ball")
            #expect(actual.kind.rawValue == spec.kind, "\(label): kind")
            expectClose(actual.start, spec.start, "\(label): start")
            expectClose(actual.end, spec.end, "\(label): end")
            expectClose(actual.entrySpeed, spec.entrySpeed, "\(label): entrySpeed")
        }
    }

    private func verifyEvents(_ prediction: ShotPrediction) {
        #expect(prediction.events.count == expected.events.count,
                "\(name): expected \(expected.events.count) events, got \(prediction.events)")
        for (index, (actual, spec)) in zip(prediction.events, expected.events).enumerated() {
            let label = "\(name) event[\(index)]"
            switch actual {
            case let .ballBall(moving, struck, contact):
                #expect(spec.type == "ballBall", "\(label): expected \(spec.type), got ballBall")
                #expect(moving == (spec.moving).map { BallID($0) }, "\(label): moving ball")
                #expect(struck == (spec.struck).map { BallID($0) }, "\(label): struck ball")
                if let point = spec.contact { expectClose(contact, point, "\(label): contact") }
            case let .cushion(ball, point):
                #expect(spec.type == "cushion", "\(label): expected \(spec.type), got cushion")
                #expect(ball == (spec.ball).map { BallID($0) }, "\(label): ball")
                if let expectedPoint = spec.point { expectClose(point, expectedPoint, "\(label): point") }
            case let .pocket(ball, pocket):
                #expect(spec.type == "pocket", "\(label): expected \(spec.type), got pocket")
                #expect(ball == (spec.ball).map { BallID($0) }, "\(label): ball")
                #expect(pocket.rawValue == spec.pocket, "\(label): pocket")
            case let .rest(ball, point):
                #expect(spec.type == "rest", "\(label): expected \(spec.type), got rest")
                #expect(ball == (spec.ball).map { BallID($0) }, "\(label): ball")
                if let expectedPoint = spec.point { expectClose(point, expectedPoint, "\(label): point") }
            }
        }
    }

    private func expectClose(_ actual: Vec2, _ expected: [Double], _ label: String) {
        let expectedVec = vec(expected)
        #expect(actual.distance(to: expectedVec) <= tolerance,
                "\(label): expected \(expectedVec), got \(actual)")
    }

    private func expectClose(_ actual: Double, _ expected: Double, _ label: String) {
        #expect(abs(actual - expected) <= tolerance,
                "\(label): expected \(expected), got \(actual)")
    }

    private func vec(_ components: [Double]) -> Vec2 {
        precondition(components.count == 2, "expected a 2-component vector")
        return Vec2(components[0], components[1])
    }
}
