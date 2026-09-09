//
//  CueBallIdentity.swift
//  ARExperience
//
//  Which tracked ball is the cue ball, kept steady across the detector
//  changing its mind.
//
//  Everything downstream hangs off this. No cue ball means no aim origin,
//  so no guide at all — and on a real recording of the operator aiming,
//  49 % of frames had no cue ball, which accounted for 147 of the 183
//  frames that drew nothing. It is the single largest reason the app shows
//  no guide, larger than every aim-source problem combined.
//
//  The cause is that cue-ball identity was re-derived every frame from
//  whatever the detector said. `white-ball` is an intermittent label — a
//  measle ball reads `color-ball`, a ball half-occluded by the bridge hand
//  reads as nothing — so the identity flickered even while the TRACK
//  underneath it was perfectly stable. Track ids are the durable thing;
//  this pins the identity to one and keeps it there.
//
//  Two sources, in priority order:
//   1. the user's tap (`designate`), which is explicit and wins outright;
//   2. adoption — the last track the detector called a cue ball, remembered
//      for as long as that track lives, and re-attached by POSITION for a
//      grace period after it dies so a re-racked or re-spotted ball does
//      not demand another tap.
//

import CueSyncCore
import Foundation

/// Durable cue-ball identity across frames. A value type so the app and
/// the replay harness run the same logic rather than two copies of it.
public struct CueBallIdentity: Sendable, Equatable {
    public struct Config: Sendable, Equatable {
        /// How near a ball must be to the lost cue ball's last known spot
        /// to be treated as the same ball coming back.
        public var reattachRadius: Double
        /// How long after losing the track that re-attachment stays armed.
        /// Long enough to cover a detector dropout and a re-spot, short
        /// enough that a genuinely new rack is not silently adopted.
        public var reattachSeconds: TimeInterval

        public init(reattachRadius: Double = 0.05,
                    reattachSeconds: TimeInterval = 3.0) {
            self.reattachRadius = reattachRadius
            self.reattachSeconds = reattachSeconds
        }

        public static let `default` = Config()
    }

    public let config: Config
    /// Set by an explicit tap. Never overridden by adoption.
    public private(set) var designatedID: BallID?
    /// The track currently believed to be the cue ball.
    public private(set) var currentID: BallID?
    private var lastPosition: Vec2?
    private var lastSeenAt: TimeInterval?

    public init(config: Config = .default) {
        self.config = config
    }

    /// A tap near `point`: mark the nearest tracked ball, or clear the mark
    /// if it is already the designated one. Returns whether anything
    /// changed, so the caller can give feedback either way.
    @discardableResult
    public mutating func toggle(near point: Vec2, in state: TableState,
                                maxDistance: Double) -> Bool {
        guard let nearest = state.balls.min(by: {
            $0.position.distance(to: point) < $1.position.distance(to: point)
        }), nearest.position.distance(to: point) <= maxDistance else { return false }
        if designatedID == nearest.id {
            designatedID = nil
        } else {
            designatedID = nearest.id
            currentID = nearest.id
            lastPosition = nearest.position
            lastSeenAt = state.timestamp
        }
        return true
    }

    /// Forget the explicit mark but keep adoption running.
    public mutating func clearDesignation() {
        designatedID = nil
    }

    /// Tracking restarted: the ids are all new, but the balls have not
    /// moved. Keep the last position so the cue ball can be re-adopted
    /// where it was, rather than making the user tap again.
    public mutating func trackingReset(at time: TimeInterval) {
        designatedID = nil
        currentID = nil
        lastSeenAt = time
    }

    public mutating func reset() {
        designatedID = nil
        currentID = nil
        lastPosition = nil
        lastSeenAt = nil
    }

    /// Resolve this frame's cue ball and relabel the state so exactly one
    /// ball is `.cue`.
    public mutating func apply(to state: TableState) -> TableState {
        let resolved = resolve(in: state)
        currentID = resolved
        if let resolved, let ball = state.balls.first(where: { $0.id == resolved }) {
            lastPosition = ball.position
            lastSeenAt = state.timestamp
        }
        guard let resolved else { return state }
        var adjusted = state
        adjusted.balls = state.balls.map { ball in
            var ball = ball
            if ball.id == resolved {
                ball.kind = .cue
            } else if ball.kind == .cue {
                // Exactly one cue ball, always: two would make
                // `TableState.cueBall` an arbitrary pick by id.
                ball.kind = .unknown
            }
            return ball
        }
        return adjusted
    }

    private func resolve(in state: TableState) -> BallID? {
        guard !state.balls.isEmpty else { return nil }
        // 1. The user's tap, while that track lives.
        if let designatedID, state.balls.contains(where: { $0.id == designatedID }) {
            return designatedID
        }
        // 2. The track we are already following.
        if let currentID, state.balls.contains(where: { $0.id == currentID }) {
            return currentID
        }
        // 3. What the detector says right now — adopt it.
        let detected = state.balls.filter { $0.kind == .cue }
        if let best = detected.max(by: { $0.confidence < $1.confidence }) {
            return best.id
        }
        // 4. The ball standing where the cue ball was last seen. This is
        //    what carries the identity through a detector dropout, a
        //    tracking reset, or a scratch-and-respot.
        guard let lastPosition, let lastSeenAt,
              state.timestamp - lastSeenAt <= config.reattachSeconds else { return nil }
        let candidate = state.balls.min(by: {
            $0.position.distance(to: lastPosition) < $1.position.distance(to: lastPosition)
        })
        guard let candidate,
              candidate.position.distance(to: lastPosition) <= config.reattachRadius else {
            return nil
        }
        return candidate.id
    }
}
