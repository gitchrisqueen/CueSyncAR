//
//  BallIdentity.swift
//  PerceptionKit
//
//  Naming a tracked ball from many looks at it, rather than one.
//
//  A stripe is found by HUE SPREAD: a solid ball is one pigment and hue
//  survives shading, so its lit pixels agree, while a stripe has two
//  materials and they do not. Measured over 14 frames of the owner's
//  table, interquartile hue spread ran 1.8-9.0 degrees for the two
//  solids and 26.9-35.5 for the two stripes, with nothing in between.
//
//  Whiteness was tried first and does not work on these balls. Measured
//  on Sessions/device-20260909T014006Z, white fraction by ball: eight
//  0.18, cue 0.15-0.19, solid blue 0.08-0.12, stripe red 0.05, stripe
//  purple 0.03 — both stripes scoring BELOW both solids. The bands are
//  plainly visible in the frames; they are simply a warm cream rather
//  than a neutral white, so a neutrality test cannot see them. The test
//  is kept as a second route because it costs nothing and does fire on
//  balls whose bands really are white.
//
//  Both signals are one-directional, which is why the group is decided
//  on the MAXIMUM ever seen for a track rather than the mean: a stripe
//  presenting its solid pole is indistinguishable from a solid, so one
//  clear look is proof of a stripe while never seeing one proves
//  nothing. Balls rotate as they roll, so the evidence arrives on its
//  own.
//
//  The colour is decided the opposite way — by vote — because every look
//  sees the same colour and disagreement there is noise.
//

import CueSyncCore
import Foundation

public struct BallIdentity: Sendable, Equatable {
    public struct Config: Sendable, Equatable {
        /// Observations kept per track.
        public var window: Int
        /// White fraction above which a ball has shown a band. Kept as
        /// a second route to the same conclusion: on balls whose bands
        /// really are white it fires, and it costs nothing when they are
        /// not. It is not the primary signal - see `stripeHueSpread`.
        public var stripeWhiteFraction: Double
        /// Interquartile hue spread, in degrees, above which a ball has
        /// shown two materials and is therefore a stripe.
        ///
        /// Measured over 14 frames of the owner's table: solids spanned
        /// 1.8-9.0 degrees and stripes 26.9-35.5, with nothing between.
        /// The default sits about a factor of three from either side,
        /// which is where a threshold should sit when the gap is that
        /// wide and the sample is that small (four balls, one table, one
        /// light).
        public var stripeHueSpread: Double
        /// Confidence a colour vote must reach before the ball is named.
        public var namingConfidence: Double
        /// Looks needed before a group is claimed at all.
        public var minimumObservations: Int

        public init(window: Int = 40,
                    stripeWhiteFraction: Double = 0.30,
                    stripeHueSpread: Double = 16,
                    namingConfidence: Double = 0.5,
                    minimumObservations: Int = 5) {
            self.window = window
            self.stripeWhiteFraction = stripeWhiteFraction
            self.stripeHueSpread = stripeHueSpread
            self.namingConfidence = namingConfidence
            self.minimumObservations = minimumObservations
        }

        public static let `default` = Config()
    }

    /// What is known about one tracked ball.
    public struct Record: Sendable, Equatable {
        public var observations: [AppearanceObservation] = []
        /// Set by the player tapping to correct the app. Wins over
        /// everything and never decays: the classifier will be wrong
        /// sometimes, and a correction that gets voted away is worse than
        /// no correction at all.
        public var override: Ball.Kind?

        /// Highest white fraction ever seen. One clear look at a band is
        /// the evidence; averaging it away is the mistake.
        public var peakWhiteFraction: Double {
            observations.map(\.whiteFraction).max() ?? 0
        }

        /// Widest hue spread ever seen, for the same reason: a stripe
        /// presenting its solid pole is indistinguishable from a solid,
        /// so the evidence is the best look, not the typical one.
        public var peakHueSpread: Double? {
            observations.compactMap(\.hueSpread).max()
        }
    }

    public var config: Config
    private var records: [BallID: Record] = [:]

    public init(config: Config = .default) {
        self.config = config
    }

    public func record(for id: BallID) -> Record? { records[id] }
    public var trackedCount: Int { records.count }

    // MARK: - Accumulating

    public mutating func observe(_ observation: AppearanceObservation, for id: BallID) {
        var record = records[id] ?? Record()
        record.observations.append(observation)
        if record.observations.count > config.window {
            record.observations.removeFirst(record.observations.count - config.window)
        }
        records[id] = record
    }

    /// Take a whole frame's readings at once.
    public mutating func observe(_ observations: [BallID: AppearanceObservation]) {
        for (id, observation) in observations { observe(observation, for: id) }
    }

    /// The player's correction, pinned to the track for the session.
    public mutating func setOverride(_ kind: Ball.Kind?, for id: BallID) {
        var record = records[id] ?? Record()
        record.override = kind
        records[id] = record
    }

    /// Forget tracks that no longer exist, so ids reused by a restarted
    /// tracker do not inherit a previous ball's colour.
    public mutating func retain(_ live: Set<BallID>) {
        records = records.filter { live.contains($0.key) }
    }

    public mutating func clear() { records = [:] }

    // MARK: - Deciding

    /// The winning colour and how strongly it won, or nil while there is
    /// not enough to say.
    ///
    /// The confidence is the vote share TIMES how sure the winning looks
    /// individually were, and it has to be both. Vote share alone says
    /// only that the looks agreed with each other — twenty looks that
    /// each scored 0.12 agree perfectly and produce a vote share of 1.0.
    /// Measured on the owner's table, that is exactly what the orange
    /// solid and the red stripe do: the warm colours sit inside each
    /// other's tolerance, every frame reads them the same unsure way,
    /// and a vote-share confidence turned that unanimous uncertainty
    /// into a confident answer. It named two different balls the 13.
    public func family(for id: BallID) -> (family: ColorFamily, confidence: Double)? {
        guard let record = records[id],
              record.observations.count >= config.minimumObservations else { return nil }
        var weights: [ColorFamily: Double] = [:]
        var counts: [ColorFamily: Int] = [:]
        for observation in record.observations {
            weights[observation.family, default: 0] += observation.confidence
            counts[observation.family, default: 0] += 1
        }
        let total = weights.values.reduce(0, +)
        guard total > 0,
              let best = weights.max(by: { $0.value < $1.value }),
              let bestCount = counts[best.key], bestCount > 0 else { return nil }
        let share = best.value / total
        let strength = best.value / Double(bestCount)
        return (best.key, share * strength)
    }

    /// Which half of the rack, decided on the strongest evidence ever
    /// seen rather than the average.
    public func group(for id: BallID) -> BallGrouping? {
        guard let record = records[id],
              record.observations.count >= config.minimumObservations,
              let colour = family(for: id) else { return nil }
        if colour.family == .black { return .eight }
        if colour.family == .white { return .cue }
        // Either signal is enough. Both are one-directional: they can
        // only ever have seen a band, never proved there isn't one, so a
        // ball that has shown neither is called solid provisionally and
        // will be corrected the moment it rolls and shows otherwise.
        if let spread = record.peakHueSpread, spread >= config.stripeHueSpread { return .stripe }
        return record.peakWhiteFraction >= config.stripeWhiteFraction ? .stripe : .solid
    }

    /// The ball's identity: a player's correction if there is one, else
    /// colour and group combined into a number.
    ///
    /// `.unknown` freely, and by design. Every consumer already handles
    /// it — `BallGroup.includes` admits unnamed balls into both halves of
    /// the rack precisely so a ranking never goes blank on a player who
    /// has picked a side.
    public func kind(for id: BallID) -> Ball.Kind {
        if let override = records[id]?.override { return override }
        guard let colour = family(for: id), let grouping = group(for: id) else { return .unknown }
        switch grouping {
        case .cue: return .cue
        case .eight: return .eight
        case .solid, .stripe:
            guard colour.confidence >= config.namingConfidence,
                  let number = colour.family.solidNumber else { return .unknown }
            return grouping == .solid ? .solid(number) : .stripe(number + 8)
        }
    }

    /// Name every ball in `state` this has an opinion about.
    ///
    /// A ball already known to be the cue ball is never renamed. The
    /// detector's own `white-ball` class and the player's tap
    /// designation are both stronger evidence than a colour vote, and a
    /// mis-renamed cue ball does not just mislabel one ball — it takes
    /// the aim line, the ghost ball and the whole ranking with it.
    public func apply(to state: TableState) -> TableState {
        var updated = state
        updated.balls = state.balls.map { ball in
            guard ball.kind != .cue else { return ball }
            let named = kind(for: ball.id)
            guard named != .unknown else { return ball }
            var renamed = ball
            renamed.kind = named
            return renamed
        }
        return updated
    }

    /// True when the ball is named but the naming is a guess worth
    /// showing dimly rather than stating. The HUD uses it to mark a
    /// number as correctable instead of asserting it.
    public func isTentative(for id: BallID) -> Bool {
        guard records[id]?.override == nil, let colour = family(for: id) else { return false }
        return colour.confidence < 0.75
    }
}

/// What a ball is, before it has a number.
public enum BallGrouping: String, Sendable, Equatable, CaseIterable {
    case cue
    case solid
    case stripe
    case eight
}
