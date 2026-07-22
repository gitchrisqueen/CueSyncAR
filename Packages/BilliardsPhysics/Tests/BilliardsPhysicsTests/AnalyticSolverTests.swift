import CueSyncCore
import Foundation
import Testing
@testable import BilliardsPhysics

private let cueID = BallID(0)
private let objectID = BallID(1)

private func makeState(balls: [Ball], size: TableSize = .nineFoot) -> TableState {
    TableState(table: Table(size: size), balls: balls, timestamp: 0)
}

private func cueOnly(at position: Vec2) -> TableState {
    makeState(balls: [Ball(id: cueID, kind: .cue, position: position)])
}

@Suite("AnalyticSolver — straight rolls")
struct StraightRollTests {
    let solver = AnalyticSolver()

    @Test func straightShotStopsAtFrictionDistance() throws {
        // v²/(2a) = 1 / (2·0.5) = 1 m of roll.
        let state = cueOnly(at: Vec2(-0.5, 0))
        let prediction = solver.predict(
            state: state,
            aim: AimRay(origin: Vec2(-0.5, 0), direction: Vec2(1, 0)),
            options: SolverOptions(initialSpeed: 1.0))

        #expect(prediction.segments.count == 1)
        let segment = try #require(prediction.segments.first)
        #expect(segment.ballID == cueID)
        #expect(abs(segment.end.x - 0.5) < 1e-9)
        #expect(abs(segment.end.y) < 1e-9)
        #expect(prediction.events.contains(.rest(ball: cueID, point: segment.end)))
        #expect(prediction.pocketedBalls.isEmpty)
    }

    @Test func zeroAimProducesEmptyPrediction() {
        let state = cueOnly(at: .zero)
        let prediction = solver.predict(
            state: state,
            aim: AimRay(origin: .zero, direction: .zero),
            options: .default)
        #expect(prediction.segments.isEmpty)
        #expect(prediction.events.isEmpty)
    }

    @Test func missingCueBallProducesEmptyPrediction() {
        let state = makeState(balls: [Ball(id: objectID, kind: .solid(1), position: .zero)])
        let prediction = solver.predict(
            state: state,
            aim: AimRay(origin: .zero, direction: Vec2(1, 0)),
            options: .default)
        #expect(prediction.segments.isEmpty)
    }
}

@Suite("AnalyticSolver — cushions")
struct CushionTests {
    let config = PhysicsConfig.standard
    let solver = AnalyticSolver()

    @Test func fortyFiveDegreeBounceReflectsAcrossRail() throws {
        // Start chosen so the 45° path crosses the top rail (y) first, well
        // clear of the side and corner pocket capture circles.
        let start = Vec2(-0.9, 0)
        let state = cueOnly(at: start)
        let direction = Vec2(1, 1).normalized
        let prediction = solver.predict(
            state: state,
            aim: AimRay(origin: start, direction: direction),
            options: SolverOptions(initialSpeed: 2.5))

        guard case let .cushion(ball, point)? = prediction.events.first else {
            Issue.record("expected first event to be a cushion bounce, got \(prediction.events)")
            return
        }
        #expect(ball == cueID)
        // Ball center reflects at half-extent minus radius.
        let expectedY = Table(size: .nineFoot).halfExtents.y - Ball.standardRadius
        #expect(abs(point.y - expectedY) < 1e-9)

        // Post-bounce segment departs downward with x-direction preserved.
        let second = try #require(prediction.segments.dropFirst().first)
        let outDir = (second.end - second.start).normalized
        #expect(outDir.x > 0)
        #expect(outDir.y < 0)

        // Rail model: |vy| (normal) scaled by the COR e, |vx| (tangential)
        // scaled by the retention factor f. With f < e the rebound is
        // steeper than the mirror (banks play short at speed — Alciatore,
        // "bank shots go short with more speed").
        let expectedOut = Vec2(direction.x * config.cushionTangentialRetention,
                               -direction.y * config.cushionRestitution).normalized
        #expect(abs(outDir.x - expectedOut.x) < 1e-9)
        #expect(abs(outDir.y - expectedOut.y) < 1e-9)
    }

    @Test func speedDropsAtCushion() {
        let start = Vec2(-0.9, 0)
        let state = cueOnly(at: start)
        let direction = Vec2(1, 1).normalized
        let prediction = solver.predict(
            state: state,
            aim: AimRay(origin: start, direction: direction),
            options: SolverOptions(initialSpeed: 2.5))

        let segments = prediction.segments(for: cueID)
        #expect(segments.count >= 2)
        #expect(segments[1].entrySpeed < segments[0].entrySpeed)
    }
}

@Suite("AnalyticSolver — ball-ball collisions")
struct BallCollisionTests {
    let config = PhysicsConfig.standard
    let solver = AnalyticSolver()

    @Test func headOnTransfersMotionAndStunsCue() throws {
        let cueStart = Vec2(-0.5, 0)
        let state = makeState(balls: [
            Ball(id: cueID, kind: .cue, position: cueStart),
            Ball(id: objectID, kind: .solid(1), position: .zero)
        ])
        let prediction = solver.predict(
            state: state,
            aim: AimRay(origin: cueStart, direction: Vec2(1, 0)),
            options: SolverOptions(initialSpeed: 1.0))

        let contact = try #require(prediction.firstContact)
        #expect(contact.moving == cueID)
        #expect(contact.struck == objectID)
        // Ghost-ball center: one ball diameter short of the object ball.
        #expect(abs(contact.contact.x - (-2 * Ball.standardRadius)) < 1e-9)
        #expect(abs(contact.contact.y) < 1e-9)

        // Cue ball stuns out (stops at contact).
        #expect(prediction.events.contains(.rest(ball: cueID, point: contact.contact)))

        // Object ball rolls +x from its position and rests before the rail.
        let objectSegments = prediction.segments(for: objectID)
        #expect(!objectSegments.isEmpty)
        let first = objectSegments[0]
        #expect(first.start == .zero)
        #expect(first.end.x > 0)
        #expect(abs(first.end.y) < 1e-9)
        #expect(prediction.pocketedBalls.isEmpty)
    }

    @Test func thirtyDegreeCutSplitsAlongImpactAndTangentLines() throws {
        // Object offset by half the collision radius → 30° cut:
        // impact line at 30° above x; tangent line at 60° below.
        let collisionRadius = 2 * Ball.standardRadius
        let cueStart = Vec2.zero
        let objectPosition = Vec2(0.5, collisionRadius / 2)
        let state = makeState(balls: [
            Ball(id: cueID, kind: .cue, position: cueStart),
            Ball(id: objectID, kind: .solid(1), position: objectPosition)
        ])
        let prediction = solver.predict(
            state: state,
            aim: AimRay(origin: cueStart, direction: Vec2(1, 0)),
            options: SolverOptions(initialSpeed: 1.5))

        let contact = try #require(prediction.firstContact)
        let impactDir = (objectPosition - contact.contact).normalized
        #expect(abs(impactDir.x - cos(.pi / 6)) < 1e-9)
        #expect(abs(impactDir.y - sin(.pi / 6)) < 1e-9)

        // Object ball's first segment follows the impact line.
        let objectSegment = try #require(prediction.segments(for: objectID).first)
        let objectDir = (objectSegment.end - objectSegment.start).normalized
        #expect(abs(objectDir.x - impactDir.x) < 1e-9)
        #expect(abs(objectDir.y - impactDir.y) < 1e-9)

        // Cue ball's post-contact segment is perpendicular to the impact line.
        let cueSegments = prediction.segments(for: cueID)
        #expect(cueSegments.count >= 2)
        let cueDir = (cueSegments[1].end - cueSegments[1].start).normalized
        #expect(abs(cueDir.dot(objectDir)) < 1e-9)
        #expect(cueDir.y < 0)
    }

    @Test func speedSplitMatchesCutAngle() throws {
        let collisionRadius = 2 * Ball.standardRadius
        let state = makeState(balls: [
            Ball(id: cueID, kind: .cue, position: .zero),
            Ball(id: objectID, kind: .solid(1), position: Vec2(0.5, collisionRadius / 2))
        ])
        let prediction = solver.predict(
            state: state,
            aim: AimRay(origin: .zero, direction: Vec2(1, 0)),
            options: SolverOptions(initialSpeed: 1.5))

        let objectEntry = try #require(prediction.segments(for: objectID).first).entrySpeed
        let cueSegments = prediction.segments(for: cueID)
        let cueEntry = cueSegments[1].entrySpeed
        // cos30/sin30 split, object scaled by ball-ball restitution.
        let ratio = objectEntry / (cueEntry * config.ballBallRestitution)
        #expect(abs(ratio - tan(.pi / 3)) < 1e-6)
    }
}

@Suite("AnalyticSolver — pockets")
struct PocketTests {
    let solver = AnalyticSolver()

    @Test func objectBallDrivenIntoCornerPocketIsCaptured() throws {
        let table = Table(size: .nineFoot)
        let pocket = table.pockets.first { $0.id == .cornerTopRight }!
        let objectPosition = Vec2(1.0, 0.5)
        let toPocket = (pocket.position - objectPosition).normalized
        let ghostCenter = objectPosition - toPocket * (2 * Ball.standardRadius)
        let cueStart = Vec2(0.3, 0.0)
        let aimDirection = (ghostCenter - cueStart).normalized

        let state = makeState(balls: [
            Ball(id: cueID, kind: .cue, position: cueStart),
            Ball(id: objectID, kind: .solid(1), position: objectPosition)
        ])
        let prediction = solver.predict(
            state: state,
            aim: AimRay(origin: cueStart, direction: aimDirection),
            options: SolverOptions(initialSpeed: 3.0))

        #expect(prediction.pocketedBalls.contains(objectID))
        #expect(prediction.events.contains(.pocket(ball: objectID, pocket: .cornerTopRight)))
        // The pocket segment ends at the pocket mouth for rendering.
        let last = try #require(prediction.segments(for: objectID).last)
        #expect(last.kind == .intoPocket)
        #expect(last.end == pocket.position)
    }

    @Test func directScratchIsDetected() {
        let table = Table(size: .nineFoot)
        let pocket = table.pockets.first { $0.id == .cornerBottomLeft }!
        let cueStart = Vec2(0, 0)
        let aim = AimRay(origin: cueStart,
                         direction: (pocket.position - cueStart).normalized)
        let prediction = solver.predict(
            state: cueOnly(at: cueStart), aim: aim,
            options: SolverOptions(initialSpeed: 3.0))

        #expect(prediction.isScratch(cueBall: cueID))
        #expect(prediction.events.contains(.pocket(ball: cueID, pocket: .cornerBottomLeft)))
    }

    @Test func nearMissRollsPast() {
        // Aim parallel to the long rail, well clear of the side pocket mouth.
        let cueStart = Vec2(-1.0, 0.3)
        let prediction = solver.predict(
            state: cueOnly(at: cueStart),
            aim: AimRay(origin: cueStart, direction: Vec2(1, 0)),
            options: SolverOptions(initialSpeed: 1.0))
        #expect(prediction.pocketedBalls.isEmpty)
    }
}

@Suite("AnalyticSolver — invariants")
struct InvariantTests {
    let solver = AnalyticSolver()

    /// Deterministic seeded generator so CI failures are reproducible.
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func randomState(using rng: inout SplitMix64) -> (TableState, AimRay) {
        let table = Table(size: .nineFoot)
        let he = table.halfExtents
        var balls: [Ball] = []
        let count = Int.random(in: 2...16, using: &rng)
        var attempts = 0
        while balls.count < count && attempts < 500 {
            attempts += 1
            let p = Vec2(Double.random(in: -(he.x - 0.04)...(he.x - 0.04), using: &rng),
                         Double.random(in: -(he.y - 0.04)...(he.y - 0.04), using: &rng))
            if balls.allSatisfy({ $0.position.distance(to: p) > 2.1 * Ball.standardRadius }) {
                let kind: Ball.Kind = balls.isEmpty ? .cue : .solid(1)
                balls.append(Ball(id: BallID(balls.count), kind: kind, position: p))
            }
        }
        let angle = Double.random(in: 0..<(2 * .pi), using: &rng)
        let aim = AimRay(origin: balls[0].position,
                         direction: Vec2(cos(angle), sin(angle)))
        return (TableState(table: table, balls: balls), aim)
    }

    @Test func randomizedShotsRespectInvariants() {
        var rng = SplitMix64(seed: 0xC0E5)
        let table = Table(size: .nineFoot)
        let he = table.halfExtents
        let options = SolverOptions(initialSpeed: 3.0, maxEvents: 8)

        for _ in 0..<500 {
            let (state, aim) = randomState(using: &rng)
            let prediction = solver.predict(state: state, aim: aim, options: options)

            var interactionEvents = 0
            for event in prediction.events {
                switch event {
                case .ballBall, .cushion, .pocket: interactionEvents += 1
                case .rest: break
                }
            }
            #expect(interactionEvents <= options.maxEvents)

            for segment in prediction.segments {
                // Speeds never exceed the launch speed.
                #expect(segment.entrySpeed <= options.initialSpeed + 1e-9)
                // Roll segments stay on the table; pocket segments may end
                // at the mouth on the rail line.
                let slack = segment.kind == .intoPocket ? 0.08 : 1e-6
                for point in [segment.start, segment.end] {
                    #expect(abs(point.x) <= he.x + slack)
                    #expect(abs(point.y) <= he.y + slack)
                }
            }
        }
    }

    @Test func solverIsDeterministic() {
        var rng = SplitMix64(seed: 42)
        let (state, aim) = randomState(using: &rng)
        let a = solver.predict(state: state, aim: aim, options: .default)
        let b = solver.predict(state: state, aim: aim, options: .default)
        #expect(a == b)
    }

    @Test(.timeLimit(.minutes(1)))
    func fullRackPerformanceBudget() {
        // 16-ball predict, 1000 iterations. Generous CI bound; the real
        // budget (<1 ms/call) is verified on device per 04-TESTING-STRATEGY.
        var rng = SplitMix64(seed: 7)
        let (state, aim) = randomState(using: &rng)
        let start = Date()
        for _ in 0..<1000 {
            _ = solver.predict(state: state, aim: aim,
                               options: SolverOptions(initialSpeed: 3.0))
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 5.0, "1000 predictions took \(elapsed)s")
    }
}
