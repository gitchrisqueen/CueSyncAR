//
//  BallIdentity.swift
//  PerceptionKit
//
//  Naming a tracked ball from many looks at it, rather than one.
//
//  A single frame cannot tell a stripe from a solid and the numbers say
//  so. Measured on Sessions/device-20260909T014006Z, white fraction by
//  ball: eight 0.18, cue 0.15-0.19, solid blue 0.08-0.12, stripe red
//  0.05, stripe purple 0.03 — both stripes scoring BELOW both solids.
//  Two reasons, both real: a stripe's band is randomly oriented, so a
//  ball can present its solid pole to the camera, and the lower half of
//  every ball is in shadow.
//
//  That is not a threshold problem. It is why the group is decided on the
//  MAXIMUM white fraction ever seen for a track, never the mean: one
//  clear look at a band is proof of a stripe, while never seeing one is
//  not proof of a solid. Balls rotate as they roll, so the evidence
//  arrives on its own.
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
        /// White fraction above which a ball has shown a band.
        public var stripeWhiteFraction: Double
        /// Confidence a colour vote must reach before the ball is named.
        public var namingConfidence: Double
        /// Looks needed before a group is claimed at all.
        public var minimumObservations: Int

        public init(window: Int = 40,
                    stripeWhiteFraction: Double = 0.30,
                    namingConfidence: Double = 0.5,
                    minimumObservations: Int = 5) {
            self.window = window
            self.stripeWhiteFraction = stripeWhiteFraction
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
    public func family(for id: BallID) -> (family: ColorFamily, confidence: Double)? {
        guard let record = records[id],
              record.observations.count >= config.minimumObservations else { return nil }
        var weights: [ColorFamily: Double] = [:]
        for observation in record.observations {
            weights[observation.family, default: 0] += observation.confidence
        }
        let total = weights.values.reduce(0, +)
        guard total > 0,
              let best = weights.max(by: { $0.value < $1.value }) else { return nil }
        return (best.key, best.value / total)
    }

    /// Which half of the rack, decided on the strongest evidence ever
    /// seen rather than the average.
    public func group(for id: BallID) -> BallGrouping? {
        guard let record = records[id],
              record.observations.count >= config.minimumObservations,
              let colour = family(for: id) else { return nil }
        if colour.family == .black { return .eight }
        if colour.family == .white { return .cue }
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
