//
//  Truth.swift
//  identity-eval
//
//  The labelled layout: numbers and names only. Table x runs away from the
//  camera, y to the camera's left, grid spacing 0.2925 m.
//

import CueSyncCore
import PerceptionKit

struct TruthBall {
    var id: BallID
    var label: String
    var family: ColorFamily
    var grouping: BallGrouping
    var x: Double
    var y: Double

    var position: Vec2 { Vec2(x, y) }

    /// The kind the shot card should show for this ball.
    var kind: Ball.Kind {
        switch grouping {
        case .cue: .cue
        case .eight: .eight
        case .solid: family.solidNumber.map { .solid($0) } ?? .unknown
        case .stripe: family.solidNumber.map { .stripe($0 + 8) } ?? .unknown
        }
    }
}

enum Truth {
    static let spacing = 0.2925

    /// Ids 1...15 are the ball numbers, 16 is the cue ball.
    static func gridLayout() -> [TruthBall] {
        let s = spacing
        let rows: [(Double, [(Double, ColorFamily, BallGrouping, Int)])] = [
            (3 * s, [(s, .yellow, .solid, 1), (0, .blue, .solid, 2), (-s, .red, .solid, 3)]),
            (2 * s, [(s, .purple, .solid, 4), (0, .orange, .solid, 5), (-s, .green, .solid, 6)]),
            (0, [(s, .maroon, .solid, 7), (0, .black, .eight, 8), (-s, .yellow, .stripe, 9)]),
            (-2 * s, [(s, .blue, .stripe, 10), (0, .red, .stripe, 11), (-s, .purple, .stripe, 12)]),
            (-3 * s, [(s, .orange, .stripe, 13), (0, .green, .stripe, 14), (-s, .maroon, .stripe, 15)]),
        ]
        var balls: [TruthBall] = []
        for (x, row) in rows {
            for (y, family, grouping, number) in row {
                balls.append(TruthBall(id: BallID(number), label: "\(number) \(family.rawValue) \(grouping.rawValue)",
                                       family: family, grouping: grouping, x: x, y: y))
            }
        }
        balls.append(TruthBall(id: BallID(16), label: "cue", family: .white, grouping: .cue, x: -0.26, y: 0.01))
        return balls.sorted { $0.id.rawValue < $1.id.rawValue }
    }
}
