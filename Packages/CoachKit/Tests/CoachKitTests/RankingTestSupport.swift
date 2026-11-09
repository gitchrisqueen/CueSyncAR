//
//  RankingTestSupport.swift
//  CoachKitTests
//
//  Seeded randomness and legal-layout generation shared by the ShotRanking
//  property tests. Every failure message in those tests carries its seed,
//  so a counterexample can be regenerated with `LayoutGenerator.layout(seed:)`.
//

import CueSyncCore
import Foundation

/// SplitMix64: tiny, fast, and identical on every platform.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1) from the top 53 bits.
    mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    mutating func uniform(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * unit()
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
}

enum LayoutGenerator {
    static let table = Table(size: .nineFoot)

    /// A random legal layout on a nine-foot table: 2-16 balls (or exactly
    /// `count`) including one cue ball (id 0), every centre at least one
    /// radius inside the play field, no two balls closer than a diameter
    /// plus 0.1 mm.
    static func layout(seed: UInt64, count fixedCount: Int? = nil) -> TableState {
        var rng = SplitMix64(seed: seed)
        let count = fixedCount ?? rng.int(2...16)
        let radius = Ball.standardRadius
        let half = table.halfExtents
        var balls: [Ball] = []
        var attempts = 0
        while balls.count < count && attempts < 5_000 {
            attempts += 1
            let position = Vec2(rng.uniform(-(half.x - radius), half.x - radius),
                                rng.uniform(-(half.y - radius), half.y - radius))
            let clear = balls.allSatisfy {
                $0.position.distance(to: position) >= 2 * radius + 1e-4
            }
            guard clear else { continue }
            let number = balls.count
            let kind: Ball.Kind = number == 0 ? .cue
                : (number < 8 ? .solid(number)
                   : (number == 8 ? .eight : .stripe(number)))
            balls.append(Ball(id: BallID(number), kind: kind, position: position))
        }
        return TableState(table: table, balls: balls)
    }

    static func isLegal(_ state: TableState) -> Bool {
        let radius = Ball.standardRadius
        for (i, ball) in state.balls.enumerated() {
            guard state.table.contains(ball.position, ballRadius: radius) else { return false }
            for other in state.balls[(i + 1)...]
                where ball.position.distance(to: other.position) < 2 * radius + 1e-4 {
                return false
            }
        }
        return state.balls.filter { $0.kind == .cue }.count == 1
    }

    /// Moves every ball by a random vector no longer than `limit` metres,
    /// retrying so each frame stays a legal layout, as detections would.
    static func jittered(_ base: TableState, limit: Double,
                         rng: inout SplitMix64) -> TableState {
        for _ in 0..<50 {
            var frame = base
            for index in frame.balls.indices {
                let angle = rng.uniform(0, 2 * .pi)
                let magnitude = rng.uniform(0, limit)
                frame.balls[index].position += Vec2(cos(angle), sin(angle)) * magnitude
            }
            if isLegal(frame) { return frame }
        }
        return base
    }
}

/// Point-to-segment distance, written independently of the ranking's own
/// corridor helper.
func segmentDistance(from p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    if lengthSquared < 1e-18 { return hypot(p.x - a.x, p.y - a.y) }
    var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared
    t = Swift.min(1, Swift.max(0, t))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}
