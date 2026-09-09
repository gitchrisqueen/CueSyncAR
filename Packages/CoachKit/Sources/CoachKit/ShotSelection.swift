//
//  ShotSelection.swift
//  CoachKit
//
//  What the app is currently offering the player: the ranked shots, the
//  one it suggests, and the one they have overridden it with.
//
//  This is a value type rather than a handful of properties on the app's
//  session model so the rules that bind them — the suggestion holds
//  against jitter, a player's pick survives until they release it or the
//  ball leaves, an empty table clears everything — are testable without
//  a device, a camera or a running app.
//

import CueSyncCore
import Foundation

public struct ShotSelection: Sendable, Equatable {
    /// Best pocket per ball, best ball first.
    public private(set) var ranking: [ShotRating] = []
    /// What the app suggests, held steady frame to frame.
    public private(set) var suggested: ShotRating?
    /// What the player chose instead, if anything.
    public private(set) var target: BallID?

    public init() {}

    /// The shot on screen: the player's pick when they have one, else the
    /// app's suggestion.
    public var active: ShotRating? {
        if let target, let chosen = ranking.first(where: { $0.ball == target }) {
            return chosen
        }
        return suggested
    }

    /// True when `active` is the player's choice rather than the app's.
    public var isPlayerChosen: Bool {
        guard let target else { return false }
        return ranking.contains { $0.ball == target }
    }

    /// Everything currently shootable, for the HUD list.
    public var shootable: [ShotRating] { ranking.filter { $0.blocker == nil } }

    // MARK: - Mutation

    /// Re-rank on a new table state.
    ///
    /// A player's pick is dropped as soon as that ball stops being
    /// rankable — pocketed, or its track retired. Keeping it would show
    /// the app's suggestion under the player's label, which is worse than
    /// admitting the pick is gone.
    public mutating func update(state: TableState, group: BallGroup,
                                config: ShotRanking.Config) {
        guard state.cueBall != nil else {
            clear()
            return
        }
        ranking = ShotRanking.best(state: state, group: group, config: config)
        if let target, !ranking.contains(where: { $0.ball == target }) {
            self.target = nil
        }
        suggested = ShotRanking.stableRecommendation(previous: suggested?.ball,
                                                     candidates: ranking)
    }

    public mutating func clear() {
        ranking = []
        suggested = nil
        target = nil
    }

    /// What a tap on the cloth did.
    public enum Choice: Sendable, Equatable {
        /// That ball is now the target.
        case selected(ShotRating)
        /// The target was already that ball, so it was released back to
        /// the app's suggestion.
        case released
        /// No rankable ball was near enough; the caller should interpret
        /// the tap some other way rather than swallow it.
        case missed
    }

    /// Choose (or release) the rankable ball nearest `point`.
    public mutating func chooseTarget(near point: Vec2, in state: TableState,
                                      maxDistance: Double = 0.25) -> Choice {
        guard !ranking.isEmpty else { return .missed }
        let rankable = Set(ranking.map(\.ball))
        let candidates = state.balls.filter { rankable.contains($0.id) }
        guard let nearest = candidates.min(by: {
            $0.position.distance(to: point) < $1.position.distance(to: point)
        }), nearest.position.distance(to: point) <= maxDistance else { return .missed }

        if target == nearest.id {
            target = nil
            return .released
        }
        target = nearest.id
        guard let rating = ranking.first(where: { $0.ball == nearest.id }) else { return .missed }
        return .selected(rating)
    }
}

extension ShotRating {
    /// One line a player can read while down on the shot. Names an
    /// obstruction rather than reporting it as 0 %: the difference between
    /// "no angle" and "a ball is in the way" changes what they do next.
    public var headline: String {
        switch blocker {
        case .cuePath: "Blocked — a ball is in the cue ball's way"
        case .objectPath: "Blocked — a ball is between it and the pocket"
        case .cutTooThin: "No angle — that cut is past 90°"
        case .pocketFacingAway: "No angle — it would cross the pocket mouth"
        case nil: "\(percentage)% into the \(pocket.spokenName)"
        }
    }
}

extension PocketID {
    /// How a person names this pocket out loud. Used in HUD copy today and
    /// by spoken guidance later.
    public var spokenName: String {
        switch self {
        case .cornerTopLeft: "top-left corner"
        case .cornerTopRight: "top-right corner"
        case .cornerBottomLeft: "bottom-left corner"
        case .cornerBottomRight: "bottom-right corner"
        case .sideTop: "top side"
        case .sideBottom: "bottom side"
        }
    }
}
