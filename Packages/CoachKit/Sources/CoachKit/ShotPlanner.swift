//
//  ShotPlanner.swift
//  CoachKit
//
//  "What should I shoot?" — enumerates every (object ball, pocket) pair on
//  the table, builds the ghost-ball aim for each, throws out the ones that
//  cannot work (blocked lane, lane through a pocket mouth, impossible cut,
//  ball can't enter the jaws) and
//  ranks the rest easiest-first. Pure geometry over CueSyncCore types: no
//  solver dependency, fully testable on Linux. The app feeds the winning
//  `ShotOption.aim` to the trajectory solver to draw the full prediction.
//
//  Honesty note: `difficulty` is a RANKING heuristic (cut angle, distance,
//  jaw margin), not a calibrated make-probability. The jaw acceptance cones
//  are approximations of real pocket geometry; tune them from device data.
//
//  Jaw cone cross-check (JawConeSweepTests, 9-ft table, firm 4 m/s roll):
//  a single ball is rolled at the pocket mouth center from 0.3, 0.6 and
//  1.0 m, at 0...80 degrees off the pocket's inward axis (both signs, 1 degree
//  steps), through the real AnalyticSolver. Widest angle that still drops:
//
//      pocket   0.3 m   0.6 m   1.0 m   ended by
//      corner    39      42      43      table reach (every legal start drops)
//      side      79      79      79      solver (first miss at 80)
//
//  Corner: the solver never rejects a reachable approach; the number falls at
//  short range only because a ball center cannot sit within one radius of a
//  rail. 42 is within 2 degrees of that bound, so the constant is kept.
//  Side: the solver accepts 79 degrees, but the 29 default is kept ON PURPOSE.
//  The solver models a pocket as an idealized capture circle (centre inside
//  `Pocket.captureRadius` pockets the ball, cushions rebound), so it is far
//  more forgiving than real jaws; real jaw geometry still needs device data.
//  Both defaults are asserted to stay inside the solver's cone.
//

import CueSyncCore
import Foundation

/// One viable way to pot one ball.
public struct ShotOption: Sendable, Equatable, Identifiable {
    public enum Rating: String, Sendable, Equatable {
        case easy, medium, hard
    }

    public var id: String { "\(target.rawValue)>\(pocket.rawValue)" }
    public var target: BallID
    public var targetKind: Ball.Kind
    public var pocket: PocketID
    /// Object ball center and pocket mouth center / capture radius, table
    /// space — carried so renderers need nothing beyond the option itself.
    public var targetPosition: Vec2
    public var pocketPosition: Vec2
    public var pocketCaptureRadius: Double
    /// Where the cue ball's center must be at the moment of contact.
    public var ghostBall: Vec2
    /// Aim from the cue ball's center through the ghost ball.
    public var aim: AimRay
    /// 0 = dead straight, larger = thinner hit.
    public var cutAngleDegrees: Double
    /// Cue-ball center → ghost-ball center, meters.
    public var cueDistance: Double
    /// Object ball → pocket mouth, meters.
    public var pocketDistance: Double
    /// 0 (trivial) ... 1 (very hard). Ranking heuristic only.
    public var difficulty: Double

    public var rating: Rating {
        if difficulty < 0.3 { return .easy }
        if difficulty < 0.55 { return .medium }
        return .hard
    }

    /// Short human label, e.g. "5-ball → top-right corner".
    public var title: String {
        "\(ShotOption.name(of: targetKind)) → \(pocket.displayName)"
    }

    /// One-line detail, e.g. "22° cut · easy".
    public var detail: String {
        let cut = Int(cutAngleDegrees.rounded())
        let cutText = cut <= 2 ? "straight in" : "\(cut)° cut"
        return "\(cutText) · \(rating.rawValue)"
    }

    static func name(of kind: Ball.Kind) -> String {
        switch kind {
        case .eight: "8-ball"
        case .solid(let n), .stripe(let n): "\(n)-ball"
        case .cue: "cue ball"
        case .unknown: "ball"
        }
    }
}

extension PocketID {
    /// Player-facing name; "top"/"bottom" follow the table-space y axis.
    public var displayName: String {
        switch self {
        case .cornerTopLeft: "top-left corner"
        case .cornerTopRight: "top-right corner"
        case .cornerBottomLeft: "bottom-left corner"
        case .cornerBottomRight: "bottom-right corner"
        case .sideTop: "top side pocket"
        case .sideBottom: "bottom side pocket"
        }
    }
}

public enum ShotPlanner {
    public struct Config: Sendable, Equatable {
        /// Hits thinner than this are not offered (cue ball barely touches).
        public var maxCutAngleDegrees: Double
        /// Half-angle of the cone (about the pocket's inward axis) inside
        /// which a ball can still drop. Corner jaws are wider than sides.
        public var cornerAcceptanceDegrees: Double
        public var sideAcceptanceDegrees: Double
        public var maxOptions: Int
        /// Balls that must not be offered as targets (e.g. not your group).
        public var excludedBalls: Set<BallID>

        public init(maxCutAngleDegrees: Double = 75,
                    cornerAcceptanceDegrees: Double = 42,
                    sideAcceptanceDegrees: Double = 29,
                    maxOptions: Int = 5,
                    excludedBalls: Set<BallID> = []) {
            self.maxCutAngleDegrees = maxCutAngleDegrees
            self.cornerAcceptanceDegrees = cornerAcceptanceDegrees
            self.sideAcceptanceDegrees = sideAcceptanceDegrees
            self.maxOptions = maxOptions
            self.excludedBalls = excludedBalls
        }
    }

    /// Viable shots, easiest first. Empty without a cue ball or any option.
    public static func plan(state: TableState,
                            config: Config = Config()) -> [ShotOption] {
        guard let cue = state.cueBall else { return [] }
        var options: [ShotOption] = []

        for target in state.balls where target.kind != .cue
            && !config.excludedBalls.contains(target.id) {
            for pocket in state.table.pockets {
                if let option = option(cue: cue, target: target, pocket: pocket,
                                       state: state, config: config) {
                    options.append(option)
                }
            }
        }

        options.sort {
            $0.difficulty != $1.difficulty
                ? $0.difficulty < $1.difficulty : $0.id < $1.id
        }
        return Array(options.prefix(Swift.max(0, config.maxOptions)))
    }

    /// Picks which option to show, with hysteresis. Ball positions jitter
    /// frame to frame, so two near-equal options would swap places and the
    /// overlay would flicker; the previous pick stays selected while it is
    /// still viable and within `margin` of the best difficulty.
    public static func select(previous: String?, among options: [ShotOption],
                              margin: Double = 0.08) -> ShotOption? {
        guard let best = options.first else { return nil }
        if let previous,
           let kept = options.first(where: { $0.id == previous }),
           kept.difficulty - best.difficulty <= margin {
            return kept
        }
        return best
    }

    // MARK: - One (ball, pocket) pair

    private static func option(cue: Ball, target: Ball, pocket: Pocket,
                               state: TableState, config: Config) -> ShotOption? {
        let toPocket = pocket.position - target.position
        let pocketDistance = toPocket.length
        guard pocketDistance > 1e-9 else { return nil }
        let travel = toPocket / pocketDistance

        // Jaw acceptance: the ball must roll into the pocket within the
        // cone about the pocket's inward axis.
        let axis = inwardAxis(of: pocket)
        let acceptance = isSide(pocket.id) ? config.sideAcceptanceDegrees
                                           : config.cornerAcceptanceDegrees
        let jawAngle = travel.angle(to: axis) * 180 / .pi
        guard jawAngle <= acceptance else { return nil }

        // Ghost ball: cue center at contact, one diameter behind the target
        // along the object ball's required line.
        let ghost = target.position - travel * (cue.radius + target.radius)
        guard state.table.contains(ghost, ballRadius: cue.radius) else { return nil }

        let toGhost = ghost - cue.position
        let cueDistance = toGhost.length
        guard cueDistance > 1e-9 else { return nil }
        let approach = toGhost / cueDistance

        let cut = approach.angle(to: travel) * 180 / .pi
        guard cut <= config.maxCutAngleDegrees else { return nil }

        // Both lanes must be clear of every other ball.
        let epsilon = 1e-4
        for other in state.balls where other.id != cue.id && other.id != target.id {
            let cueLane = distance(from: other.position,
                                   toSegment: cue.position, ghost)
            if cueLane < cue.radius + other.radius - epsilon { return nil }
            let objectLane = distance(from: other.position,
                                      toSegment: target.position, pocket.position)
            if objectLane < target.radius + other.radius - epsilon { return nil }
        }

        // Neither lane may run through a pocket mouth. The cue ball would
        // scratch on the way in; the object ball would drop in the wrong
        // pocket. (The intended pocket is the end of the object lane, so it
        // is exempt there.) Found by the solver cross-check property test.
        for other in state.table.pockets {
            let cueScratch = distance(from: other.position, toSegment: cue.position, ghost)
            if cueScratch < other.captureRadius { return nil }
            if other.id != pocket.id {
                let wrongPocket = distance(from: other.position,
                                           toSegment: target.position, pocket.position)
                if wrongPocket < other.captureRadius { return nil }
            }
        }

        let difficulty = score(cut: cut, cueDistance: cueDistance,
                               pocketDistance: pocketDistance,
                               jawUse: jawAngle / acceptance,
                               tableLength: state.table.size.playField.width)

        return ShotOption(target: target.id, targetKind: target.kind,
                          pocket: pocket.id, targetPosition: target.position,
                          pocketPosition: pocket.position,
                          pocketCaptureRadius: pocket.captureRadius,
                          ghostBall: ghost,
                          aim: AimRay(origin: cue.position, direction: toGhost),
                          cutAngleDegrees: cut, cueDistance: cueDistance,
                          pocketDistance: pocketDistance, difficulty: difficulty)
    }

    /// Weights are a ranking heuristic: cut angle dominates, then distance,
    /// then how much of the jaw cone the shot uses.
    static func score(cut: Double, cueDistance: Double, pocketDistance: Double,
                      jawUse: Double, tableLength: Double) -> Double {
        let cutTerm = Swift.min(1, cut / 90)
        let distanceTerm = Swift.min(1, (cueDistance + pocketDistance)
                                        / (Swift.max(tableLength, 0.1) * 1.2))
        let jawTerm = Swift.min(1, Swift.max(0, jawUse))
        let value = 0.55 * cutTerm + 0.25 * distanceTerm + 0.20 * jawTerm
        return Swift.min(1, Swift.max(0, value))
    }

    // MARK: - Geometry helpers

    private static func isSide(_ id: PocketID) -> Bool {
        id == .sideTop || id == .sideBottom
    }

    /// Unit vector pointing from the table center out through the pocket —
    /// the direction a ball travels when it drops dead-center.
    private static func inwardAxis(of pocket: Pocket) -> Vec2 {
        if isSide(pocket.id) {
            return Vec2(0, pocket.position.y >= 0 ? 1 : -1)
        }
        return Vec2(pocket.position.x >= 0 ? 1 : -1,
                    pocket.position.y >= 0 ? 1 : -1).normalized
    }

    static func distance(from p: Vec2, toSegment a: Vec2, _ b: Vec2) -> Double {
        let ab = b - a
        let lengthSquared = ab.lengthSquared
        guard lengthSquared > 1e-12 else { return p.distance(to: a) }
        let t = Swift.max(0, Swift.min(1, (p - a).dot(ab) / lengthSquared))
        return p.distance(to: a + ab * t)
    }
}
