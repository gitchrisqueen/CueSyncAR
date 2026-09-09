//
//  GuidePolicy.swift
//  ARExperience
//
//  How much of a solved shot is worth DRAWING.
//
//  The solver answers "where does everything end up", which is the right
//  question for physics and the wrong one for a guide line. On the
//  operator's table it rolls the cue ball through three to five cushions,
//  then the struck ball, then whatever that hits — up to four balls and
//  twelve segments, a polyline four to five metres long across a 2.26 m
//  table. Two consequences, both reported from the table:
//
//   * it does not read as a shot line, it reads as a scribble;
//   * a degree of aim noise at the cue ball becomes METRES of movement at
//     the far end, because the far end is five metres of arc away. Measured
//     far-end shift per re-solve: about 2 m.
//
//  Trimming is done here rather than by lowering `SolverOptions.maxEvents`
//  because that budget is spent depth-first: the cue ball's entire rollout
//  is simulated before the struck ball is dequeued, so a small budget
//  starves the object ball completely — the one leg a player most wants to
//  see. The full solution stays intact for physics and coaching; only the
//  drawn subset is cut.
//

import CueSyncCore
import Foundation

public struct GuidePolicy: Sendable, Equatable {
    /// Cushions to keep on the cue ball's path AFTER it strikes a ball.
    /// One shows where the cue ball goes next — position play — without
    /// following it around the table.
    public var cueCushionsAfterContact: Int
    /// Cushions to keep when the aim hits no ball at all: a bank line the
    /// player is deliberately reading, so it gets a little more rope.
    public var cueCushionsWithoutContact: Int
    /// Whether to keep the struck ball's path past its first cushion.
    /// Off: a made ball ends at the pocket, a missed one at the rail.
    public var followStruckBallPastFirstCushion: Bool
    /// Balls beyond the cue ball and the ball it strikes. A three-ball
    /// chain is a prediction about a prediction; drawing it implies a
    /// confidence the tracker does not have.
    public var keepSecondaryChains: Bool

    public init(cueCushionsAfterContact: Int = 1,
                cueCushionsWithoutContact: Int = 2,
                followStruckBallPastFirstCushion: Bool = false,
                keepSecondaryChains: Bool = false) {
        self.cueCushionsAfterContact = cueCushionsAfterContact
        self.cueCushionsWithoutContact = cueCushionsWithoutContact
        self.followStruckBallPastFirstCushion = followStruckBallPastFirstCushion
        self.keepSecondaryChains = keepSecondaryChains
    }

    public static let `default` = GuidePolicy()

    /// The subset of `prediction` worth drawing.
    ///
    /// Relies on two facts about `AnalyticSolver`: it rolls each ball to
    /// rest before dequeuing the next, so a ball's segments are contiguous
    /// and in order; and every segment ends in exactly one event for that
    /// ball. So "keep this ball's first K events" and "keep its first K
    /// segments" are the same cut, and neither needs to compare floating
    /// point positions — which is how the post-contact colouring bug got
    /// in (`segment.end == contact`).
    public static func trim(_ prediction: ShotPrediction,
                            cueID: BallID,
                            policy: GuidePolicy = .default) -> ShotPrediction {
        guard !prediction.segments.isEmpty else { return prediction }
        // A prediction whose segments carry no events cannot be cut by
        // events without erasing it. Solvers are free to report a bare
        // polyline; leave those alone.
        guard !prediction.events.isEmpty else { return prediction }

        let struckID = prediction.firstContact.map(\.struck)
        var keptEventCount: [BallID: Int] = [:]
        var cushionsBeforeContact = 0
        var cushionsAfterContact = 0
        var sawContact = false
        var cueFinished = false

        for event in prediction.events {
            guard let ball = owner(of: event) else { continue }
            if ball == cueID {
                if cueFinished { continue }
                switch event {
                case .ballBall:
                    sawContact = true
                case .cushion:
                    // Count first, then decide: the cushion that REACHES
                    // the budget is drawn (it is the bounce the player is
                    // reading); the roll away from it is not.
                    if sawContact {
                        cushionsAfterContact += 1
                        if cushionsAfterContact > policy.cueCushionsAfterContact { continue }
                        if cushionsAfterContact == policy.cueCushionsAfterContact {
                            cueFinished = true
                        }
                    } else {
                        cushionsBeforeContact += 1
                        if cushionsBeforeContact > policy.cueCushionsWithoutContact { continue }
                        if cushionsBeforeContact == policy.cueCushionsWithoutContact {
                            cueFinished = true
                        }
                    }
                case .pocket, .rest:
                    // Where the cue ball ends up, when it gets there inside
                    // the budget: worth drawing, and nothing follows it.
                    cueFinished = true
                }
                keptEventCount[cueID, default: 0] += 1
            } else if ball == struckID {
                let already = keptEventCount[ball, default: 0]
                if already > 0, !policy.followStruckBallPastFirstCushion { continue }
                keptEventCount[ball, default: 0] += 1
            } else if policy.keepSecondaryChains {
                keptEventCount[ball, default: 0] += 1
            }
        }

        // Balls with no events of their own are not trimmable; keep them.
        var eventsPerBall: [BallID: Int] = [:]
        for event in prediction.events {
            if let ball = owner(of: event) { eventsPerBall[ball, default: 0] += 1 }
        }
        var remaining = keptEventCount
        let segments = prediction.segments.filter { segment in
            guard eventsPerBall[segment.ballID] != nil else { return true }
            guard let left = remaining[segment.ballID], left > 0 else { return false }
            remaining[segment.ballID] = left - 1
            return true
        }
        var eventBudget = keptEventCount
        let events = prediction.events.filter { event in
            guard let ball = owner(of: event),
                  let left = eventBudget[ball], left > 0 else { return false }
            eventBudget[ball] = left - 1
            return true
        }
        // Pocketed balls must follow what is DRAWN, or the called-shot
        // check and the pocket highlight disagree with the line the player
        // is looking at.
        let pocketed = events.compactMap { event -> BallID? in
            if case let .pocket(ball, _) = event { return ball }
            return nil
        }
        return ShotPrediction(segments: segments, events: events, pocketedBalls: pocketed)
    }

    /// Which ball an event belongs to.
    static func owner(of event: CollisionEvent) -> BallID? {
        switch event {
        case let .ballBall(moving, _, _): moving
        case let .cushion(ball, _): ball
        case let .pocket(ball, _): ball
        case let .rest(ball, _): ball
        }
    }
}
