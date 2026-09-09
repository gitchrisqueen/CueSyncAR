//
//  ShotRanking.swift
//  CoachKit
//
//  Ranks every legal ball/pocket pair by how likely the player is to make
//  it, so the app can put its suggestion on the best shot on the table
//  instead of wherever the cue happens to be pointing.
//
//  The number is derived, not tuned. For each candidate the geometry gives
//  an *aim tolerance*: the largest angular error at the cue ball that still
//  drops the object ball. That tolerance is compared against one honest
//  parameter — the player's aiming precision — through a Gaussian, which
//  turns geometry into a probability without any invented curve.
//
//  Honesty rule, inherited from ShotGuide: nothing here claims anything the
//  physics cannot back. Cue-ball control after contact (position play,
//  scratch risk, breakout potential) needs the trajectory solver and is
//  deliberately absent — see `ShotRating.caveats`. The single modelling
//  assumption that geometry does not force is `Config.cutJudgementPenalty`,
//  documented where it is declared.
//

import CueSyncCore
import Foundation

/// One rated ball-into-pocket candidate.
public struct ShotRating: Sendable, Equatable {
    /// Difficulty bands, for colour and copy. Derived from `probability`.
    public enum Difficulty: String, Sendable, Equatable, CaseIterable {
        case easy
        case medium
        case hard
        case longShot
        case blocked

        /// The band a probability falls in. `blocked` is only ever produced
        /// by an obstruction, never by a low probability alone.
        public static func band(probability: Double) -> Difficulty {
            switch probability {
            case 0.75...: .easy
            case 0.45..<0.75: .medium
            case 0.15..<0.45: .hard
            default: .longShot
            }
        }
    }

    /// What stops a shot from being available at all.
    public enum Blocker: Sendable, Equatable {
        /// A ball sits in the cue ball's path to the ghost-ball position.
        case cuePath(BallID)
        /// A ball sits between the object ball and the pocket.
        case objectPath(BallID)
        /// The required cut exceeds 90° — the cue ball cannot reach that
        /// side of the object ball.
        case cutTooThin
        /// The object ball would have to arrive across the pocket mouth
        /// rather than into it.
        case pocketFacingAway
    }

    public var ball: BallID
    public var pocket: PocketID
    /// 0...1. Zero exactly when `blocker != nil`.
    public var probability: Double
    public var difficulty: Difficulty
    /// Cut angle in degrees; 0 is dead straight.
    public var cutAngleDegrees: Double
    /// Distance the cue ball travels to contact, metres.
    public var cueTravel: Double
    /// Distance the object ball travels to the pocket, metres.
    public var objectTravel: Double
    /// The largest aim error at the cue ball that still makes the ball,
    /// radians. This is the quantity everything else is derived from.
    public var aimTolerance: Double
    /// Where the cue ball's centre must arrive.
    public var ghostBall: Vec2
    public var blocker: Blocker?

    public init(ball: BallID, pocket: PocketID, probability: Double,
                difficulty: Difficulty, cutAngleDegrees: Double,
                cueTravel: Double, objectTravel: Double,
                aimTolerance: Double, ghostBall: Vec2,
                blocker: Blocker? = nil) {
        self.ball = ball
        self.pocket = pocket
        self.probability = probability
        self.difficulty = difficulty
        self.cutAngleDegrees = cutAngleDegrees
        self.cueTravel = cueTravel
        self.objectTravel = objectTravel
        self.aimTolerance = aimTolerance
        self.ghostBall = ghostBall
        self.blocker = blocker
    }

    /// Percentage for display, rounded to a whole number.
    public var percentage: Int { Int((probability * 100).rounded()) }

    /// What this rating does *not* account for. Shown to the player rather
    /// than hidden, so a 90 % that leaves no next shot is not read as a
    /// promise.
    public static let caveats =
        "Ranks potting difficulty only — not where the cue ball finishes."
}

/// Rates and ranks shots on a table state. Pure and deterministic: the same
/// state always yields the same order.
public enum ShotRanking {
    public struct Config: Sendable, Equatable {
        /// Standard deviation of the player's aiming error on a straight
        /// shot, radians. 0.005 rad ≈ 0.29°.
        public var aimSigma: Double
        /// How much harder a cut is to *judge* than a straight shot, over
        /// and above the geometric amplification that `rate` already
        /// computes. Aiming error is scaled by `1 + penalty·(1 − cos θ)`,
        /// so a straight shot is unaffected and a 78° cut roughly doubles
        /// it.
        ///
        /// This is the one assumption in the file that geometry does not
        /// force, and it is here because without it the model calls a very
        /// thin cut next to a pocket "easy" — which it is not. The shape
        /// (aiming precision degrades with cut angle) is well attested; the
        /// magnitude is a guess until there is a recording of real shots
        /// made and missed to fit it against. Set to 0 for pure geometry.
        public var cutJudgementPenalty: Double
        /// A ball this much beyond touching still counts as an obstruction
        /// worth narrowing the aim for, rather than a clean miss.
        public var clearanceMargin: Double
        /// Below this pot probability a candidate is not offered at all.
        public var minimumProbability: Double
        /// A ball closer than this to a cushion is harder to strike cleanly;
        /// its tolerance is scaled by `railTolerancePenalty`.
        public var railProximity: Double
        public var railTolerancePenalty: Double

        public init(aimSigma: Double = 0.005,
                    cutJudgementPenalty: Double = 1.0,
                    clearanceMargin: Double = 0.04,
                    minimumProbability: Double = 0.02,
                    railProximity: Double = 1.4 * Ball.standardRadius,
                    railTolerancePenalty: Double = 0.75) {
            self.aimSigma = aimSigma
            self.cutJudgementPenalty = cutJudgementPenalty
            self.clearanceMargin = clearanceMargin
            self.minimumProbability = minimumProbability
            self.railProximity = railProximity
            self.railTolerancePenalty = railTolerancePenalty
        }

        /// Beginner: a wider aim error, so only simple shots read as easy.
        public static let beginner = Config(aimSigma: 0.009)
        /// The default. Roughly a competent league player.
        public static let intermediate = Config()
        /// Advanced: tight aim, so thin cuts stay live.
        public static let advanced = Config(aimSigma: 0.003)
    }

    // MARK: - Ranking

    /// Every candidate for every ball in `group`, best first.
    ///
    /// Ties break on ball id then pocket id so the order is stable frame to
    /// frame — a ranking that reshuffles under noise is unusable on a HUD.
    public static func rank(state: TableState,
                            group: BallGroup = .any,
                            config: Config = .intermediate) -> [ShotRating] {
        guard let cue = state.cueBall else { return [] }
        var out: [ShotRating] = []
        for ball in state.balls where ball.id != cue.id && group.includes(ball.kind) {
            for pocket in state.table.pockets {
                guard let r = rate(cueBall: cue, ball: ball, pocket: pocket,
                                   state: state, config: config) else { continue }
                if r.blocker == nil && r.probability < config.minimumProbability { continue }
                out.append(r)
            }
        }
        return out.sorted(by: isBetter)
    }

    /// The best pocket for each ball in `group`, best ball first. This is
    /// what the HUD lists: one row per ball, not six.
    public static func best(state: TableState,
                            group: BallGroup = .any,
                            config: Config = .intermediate) -> [ShotRating] {
        var bestByBall: [BallID: ShotRating] = [:]
        for rating in rank(state: state, group: group, config: config) {
            if let existing = bestByBall[rating.ball], isBetter(existing, rating) { continue }
            bestByBall[rating.ball] = rating
        }
        return bestByBall.values.sorted(by: isBetter)
    }

    /// The single shot the app should suggest, or nil when nothing in the
    /// group is worth offering.
    public static func recommended(state: TableState,
                                   group: BallGroup = .any,
                                   config: Config = .intermediate) -> ShotRating? {
        best(state: state, group: group, config: config)
            .first { $0.blocker == nil }
    }

    private static func isBetter(_ a: ShotRating, _ b: ShotRating) -> Bool {
        if a.probability != b.probability { return a.probability > b.probability }
        if a.ball.rawValue != b.ball.rawValue { return a.ball.rawValue < b.ball.rawValue }
        return a.pocket.rawValue < b.pocket.rawValue
    }

    // MARK: - Rating one candidate

    /// Rate one ball into one pocket. Returns nil when the geometry is
    /// degenerate (the ball is already in the pocket, or sits on the cue
    /// ball).
    public static func rate(cueBall: Ball, ball: Ball, pocket: Pocket,
                            state: TableState,
                            config: Config = .intermediate) -> ShotRating? {
        let radius = ball.radius
        let toPocket = pocket.position - ball.position
        let objectTravel = toPocket.length
        guard objectTravel > radius else { return nil }
        let pocketDirection = toPocket.normalized

        // The cue ball's centre must arrive here: one ball-diameter back
        // along the line the object ball has to leave on.
        let ghost = ball.position - pocketDirection * (2 * radius)
        let toGhost = ghost - cueBall.position
        let cueTravel = toGhost.length
        guard cueTravel > 1e-6 else { return nil }
        let cueDirection = toGhost.normalized

        // Cut angle: between the cue ball's approach and the object ball's
        // departure. At 90° the cue ball is striking a tangent and cannot
        // send the ball forward at all.
        let cosCut = cueDirection.dot(pocketDirection)
        let cutAngle = acos(max(-1, min(1, cosCut)))
        let blockedRating = { (blocker: ShotRating.Blocker) in
            ShotRating(ball: ball.id, pocket: pocket.id, probability: 0,
                       difficulty: .blocked, cutAngleDegrees: cutAngle * 180 / .pi,
                       cueTravel: cueTravel, objectTravel: objectTravel,
                       aimTolerance: 0, ghostBall: ghost, blocker: blocker)
        }
        guard cosCut > 0.01 else { return blockedRating(.cutTooThin) }

        // How wide the pocket looks from the object ball, as an angle. A
        // ball arriving across the mouth rather than into it sees less of
        // it, which is why rail-hugging shots into a corner are harder.
        let facing = facingDirection(of: pocket.id)
        let approach = max(0, pocketDirection.dot(facing))
        guard approach > 0.17 else { return blockedRating(.pocketFacingAway) }   // ~80°
        let mouth = max(0, pocket.captureRadius - radius) * approach
        var objectTolerance = asin(max(-1, min(1, mouth / objectTravel)))

        // Obstruction. A ball in the way does not merely subtract a fixed
        // penalty — it narrows the corridor, which narrows the aim, which
        // the same probability curve then prices. Touching is a hard block.
        let contact = 2 * radius
        let searchWidth = contact + config.clearanceMargin
        if let hit = narrowest(from: ball.position, to: pocket.position,
                               excluding: [ball.id], state: state, searchWidth: searchWidth) {
            if hit.clearance <= contact { return blockedRating(.objectPath(hit.id)) }
            objectTolerance = min(objectTolerance, (hit.clearance - contact) / max(hit.distance, 1e-6))
        }

        // Aim tolerance at the cue ball. A lateral error δ·cueTravel at the
        // ghost ball rotates the object's departure by δ·cueTravel/(2r·cos θ),
        // so the allowable δ is that relation inverted.
        var aimTolerance = objectTolerance * 2 * radius * cosCut / cueTravel

        if let hit = narrowest(from: cueBall.position, to: ghost,
                               excluding: [ball.id, cueBall.id], state: state,
                               searchWidth: searchWidth) {
            if hit.clearance <= contact { return blockedRating(.cuePath(hit.id)) }
            aimTolerance = min(aimTolerance, (hit.clearance - contact) / max(hit.distance, 1e-6))
        }

        // A ball frozen to a cushion cannot be struck on its full face.
        if isNearRail(ball.position, table: state.table, within: config.railProximity) {
            aimTolerance *= config.railTolerancePenalty
        }

        let sigma = config.aimSigma * (1 + config.cutJudgementPenalty * (1 - cosCut))
        let probability = potProbability(tolerance: aimTolerance, sigma: sigma)
        return ShotRating(ball: ball.id, pocket: pocket.id, probability: probability,
                          difficulty: .band(probability: probability),
                          cutAngleDegrees: cutAngle * 180 / .pi,
                          cueTravel: cueTravel, objectTravel: objectTravel,
                          aimTolerance: aimTolerance, ghostBall: ghost)
    }

    // MARK: - Model pieces

    /// Probability that a Gaussian aim error of standard deviation `sigma`
    /// lands inside ±`tolerance`.
    static func potProbability(tolerance: Double, sigma: Double) -> Double {
        guard tolerance > 0, sigma > 0 else { return 0 }
        return erf(tolerance / (sigma * 2.0.squareRoot()))
    }

    /// Outward direction a pocket's mouth faces, in table space.
    static func facingDirection(of pocket: PocketID) -> Vec2 {
        let d = 1 / 2.0.squareRoot()
        switch pocket {
        case .cornerTopLeft: return Vec2(-d, d)
        case .cornerTopRight: return Vec2(d, d)
        case .cornerBottomLeft: return Vec2(-d, -d)
        case .cornerBottomRight: return Vec2(d, -d)
        case .sideTop: return Vec2(0, 1)
        case .sideBottom: return Vec2(0, -1)
        }
    }

    static func isNearRail(_ p: Vec2, table: Table, within: Double) -> Bool {
        let he = table.halfExtents
        return abs(abs(p.x) - he.x) < within || abs(abs(p.y) - he.y) < within
    }

    private struct Interference {
        var id: BallID
        /// Centre-to-line distance of the tightest ball, metres.
        var clearance: Double
        /// How far along the corridor it sits, metres — the lever arm that
        /// turns a lateral gap into an angular one.
        var distance: Double
    }

    /// The ball that comes closest to the corridor from `a` to `b`, if any
    /// comes near enough to matter.
    private static func narrowest(from a: Vec2, to b: Vec2, excluding: Set<BallID>,
                                  state: TableState, searchWidth: Double) -> Interference? {
        let along = b - a
        let length = along.length
        guard length > 1e-6 else { return nil }
        let dir = along / length
        var tightest: Interference?
        for other in state.balls where !excluding.contains(other.id) {
            let rel = other.position - a
            let t = rel.dot(dir)
            guard t > 0, t < length else { continue }          // beside, not between
            let clearance = abs(rel.cross(dir))
            guard clearance < searchWidth else { continue }
            if clearance < (tightest?.clearance ?? .infinity) {
                tightest = Interference(id: other.id, clearance: clearance, distance: t)
            }
        }
        return tightest
    }
}

extension ShotRanking {
    /// The shot to suggest, holding the previous suggestion unless a
    /// materially better one appears.
    ///
    /// Tracked ball positions jitter by a few millimetres a frame, so two
    /// shots within a point or two of each other trade places constantly.
    /// Recomputing the suggestion from scratch every frame would swap the
    /// highlighted ball back and forth while the player is down on the
    /// shot — the ranking would be correct and unusable at the same time.
    ///
    /// So the incumbent keeps the suggestion until something beats it by
    /// `margin`. Switching costs the player's attention; a percentage
    /// point does not buy that.
    public static func stableRecommendation(previous: BallID?,
                                            candidates: [ShotRating],
                                            margin: Double = 0.05) -> ShotRating? {
        let live = candidates.filter { $0.blocker == nil }
        guard let leader = live.max(by: { $0.probability < $1.probability }) else { return nil }
        guard let previous,
              let incumbent = live.first(where: { $0.ball == previous }) else { return leader }
        return leader.probability > incumbent.probability + margin ? leader : incumbent
    }
}
