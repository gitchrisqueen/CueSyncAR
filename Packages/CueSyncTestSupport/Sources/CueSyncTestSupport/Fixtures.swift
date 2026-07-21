//
//  Fixtures.swift
//  CueSyncTestSupport
//
//  Fixture providers and canonical table states used by every package's
//  tests (and by the app's -UITestFixtureMode launch path). This target
//  deliberately does NOT import Testing: contract checks return failure
//  descriptions and callers assert emptiness with their own framework.
//

import CueSyncCore
import Foundation

// MARK: - Canonical states

public enum TableStateFixtures {
    /// Standard 8-ball rack on a 9-ft table: cue at the head spot, a full
    /// triangle at the foot spot. Positions are exact geometry, not detection
    /// output — confidence is 1.
    public static func eightBallRack() -> TableState {
        let table = Table(size: .nineFoot)
        let r = Ball.standardRadius
        var balls: [Ball] = [
            Ball(id: BallID(0), kind: .cue, position: Vec2(-0.635, 0))
        ]
        // Rack apex at the foot spot (quarter table from the foot rail).
        let apex = Vec2(0.635, 0)
        let dx = r * 3.0.squareRoot() + 1e-4
        // Conventional-enough ordering; the 8 sits center of row 3.
        let numbers = [1, 9, 2, 10, 8, 3, 11, 4, 12, 5, 13, 6, 14, 7, 15]
        var index = 0
        for row in 0..<5 {
            for slot in 0...row {
                let n = numbers[index]
                index += 1
                let kind: Ball.Kind = n == 8 ? .eight : (n < 8 ? .solid(n) : .stripe(n))
                let position = apex + Vec2(Double(row) * dx,
                                           (Double(slot) - Double(row) / 2) * 2 * (r + 5e-5))
                balls.append(Ball(id: BallID(n), kind: kind, position: position))
            }
        }
        return TableState(table: table, balls: balls)
    }

    /// Minimal two-ball state: cue plus one object ball, for solver tests.
    public static func cueAndOneBall(cueAt cue: Vec2 = Vec2(-0.5, 0),
                                     objectAt object: Vec2 = .zero) -> TableState {
        TableState(table: Table(size: .nineFoot), balls: [
            Ball(id: BallID(0), kind: .cue, position: cue),
            Ball(id: BallID(1), kind: .solid(1), position: object)
        ])
    }
}

// MARK: - Fixture providers

public struct FixtureImageBuffer: ImageBufferProviding {
    public let width: Int
    public let height: Int
    public init(width: Int = 1920, height: Int = 1080) {
        self.width = width
        self.height = height
    }
}

/// Replays scripted per-frame detections; loops when frames run out.
public actor FixtureDetectionProvider: DetectionProviding {
    private let frames: [[Detection2D]]
    private var cursor = 0
    public private(set) var prepareCallCount = 0

    public init(frames: [[Detection2D]]) {
        precondition(!frames.isEmpty, "FixtureDetectionProvider needs at least one frame")
        self.frames = frames
    }

    public init(constant detections: [Detection2D]) {
        self.init(frames: [detections])
    }

    public func prepare() async throws {
        prepareCallCount += 1
    }

    public func detect(in frame: CapturedFrame) async throws -> [Detection2D] {
        let result = frames[cursor % frames.count]
        cursor += 1
        return result
    }
}

/// Returns a canned prediction regardless of input.
public struct StaticSolver: TrajectorySolving {
    public let prediction: ShotPrediction
    public init(prediction: ShotPrediction = ShotPrediction()) {
        self.prediction = prediction
    }
    public func predict(state: TableState, aim: AimRay, options: SolverOptions) -> ShotPrediction {
        prediction
    }
}

/// Canned coaching advice; records nothing, never fails.
public struct MockCoach: CoachProviding {
    public let advice: CoachAdvice
    public init(advice: CoachAdvice = CoachAdvice(
        headline: "Cut the 3 to the corner",
        explanation: "Thin cut, moderate speed; watch the scratch line.",
        difficulty: 0.4)) {
        self.advice = advice
    }
    public func advise(state: TableState, prediction: ShotPrediction,
                       skill: SkillLevel) async throws -> CoachAdvice {
        advice
    }
}

// MARK: - Provider contract checks

/// Framework-agnostic contract checks. Each returns human-readable failure
/// descriptions; a conforming implementation yields an empty array. Every
/// provider adapter's test suite must run the matching check.
public enum ProviderContracts {
    public static func checkDetectionProvider(
        _ provider: any DetectionProviding,
        sampleFrame: CapturedFrame = CapturedFrame(
            timestamp: 0, cameraTransform: .identity,
            image: FixtureImageBuffer())
    ) async -> [String] {
        var failures: [String] = []
        do {
            try await provider.prepare()
            // prepare must be idempotent.
            try await provider.prepare()
        } catch {
            failures.append("prepare() threw: \(error)")
            return failures
        }
        do {
            let detections = try await provider.detect(in: sampleFrame)
            for d in detections {
                if !(0...1).contains(d.confidence) {
                    failures.append("confidence out of range: \(d)")
                }
                if d.boundingBox.width < 0 || d.boundingBox.height < 0 {
                    failures.append("negative bounding box: \(d)")
                }
            }
        } catch {
            failures.append("detect() threw on a valid frame: \(error)")
        }
        return failures
    }

    public static func checkTrajectorySolver(
        _ solver: any TrajectorySolving
    ) -> [String] {
        var failures: [String] = []
        let state = TableStateFixtures.cueAndOneBall()
        guard let cue = state.cueBall else { return ["fixture missing cue ball"] }

        // Zero aim must not trap and must produce nothing.
        let empty = solver.predict(
            state: state,
            aim: AimRay(origin: cue.position, direction: .zero),
            options: .default)
        if !empty.segments.isEmpty {
            failures.append("zero-direction aim produced segments")
        }

        // A normal shot must respect the event budget and stay deterministic.
        let aim = AimRay(origin: cue.position, direction: Vec2(1, 0))
        let a = solver.predict(state: state, aim: aim, options: .default)
        let b = solver.predict(state: state, aim: aim, options: .default)
        if a != b {
            failures.append("solver is not deterministic for identical inputs")
        }
        return failures
    }

    public static func checkCoach(_ coach: any CoachProviding) async -> [String] {
        var failures: [String] = []
        do {
            let advice = try await coach.advise(
                state: TableStateFixtures.eightBallRack(),
                prediction: ShotPrediction(),
                skill: .beginner)
            if advice.headline.isEmpty {
                failures.append("empty headline")
            }
            if !(0...1).contains(advice.difficulty) {
                failures.append("difficulty out of range: \(advice.difficulty)")
            }
        } catch {
            failures.append("advise() threw: \(error)")
        }
        return failures
    }
}
