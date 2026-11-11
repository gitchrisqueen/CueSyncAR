//
//  ShotOutcomeDetector.swift
//  CoachKit
//
//  Did the shot just taken go in? Watches the tracked table frame by frame
//  and, when it is sure, says made-as-advised, made-other, missed or
//  scratch. When it is not sure it says NOTHING: a cheer for a ball that was
//  only hidden behind a hand costs the player's trust, a silence costs
//  nothing.
//
//  The tracker (PerceptionKit.BallTracker) shapes every rule here:
//  - a ball that leaves the table is not reported gone at once. Its track
//    coasts at its last position for 0.75 s (something else moved) to 2.5 s
//    (nothing did) before it retires. So "made" is declared when a ball has
//    been absent from the table state for `confirmAbsence`, never on the
//    first missing frame; and "missed" waits past the longest coast
//    (`missDelay`), or a pocketed ball still standing in as a stale ring
//    would read as a miss.
//  - a ball in flight outruns the tracker's gate, so its id churns: the old
//    id vanishes where it was, a new one appears where it is. A vanish that
//    is matched by a newcomer is a ball that MOVED. Only a vanish with no
//    newcomer to account for it, last seen at a pocket, is a ball that WENT.
//  - a hand over a ball makes it vanish too; it comes back where it was. A
//    ball that returns within `reappearRadius` of where it was lost never
//    counted as gone.
//
//  Pure and clocked by `TableState.timestamp`.
//

import CueSyncCore
import Foundation

/// The shot the app was advising when the cue ball was struck.
public struct AdvisedShot: Sendable, Equatable {
    public var ball: BallID
    public var pocket: PocketID

    public init(ball: BallID, pocket: PocketID) {
        self.ball = ball
        self.pocket = pocket
    }
}

public enum ShotOutcome: Sendable, Equatable {
    /// The advised ball went into the advised pocket.
    case madeAsAdvised(ball: BallID, pocket: PocketID)
    /// A ball went down that was not the advised ball in the advised pocket.
    case madeOther(ball: BallID, pocket: PocketID)
    /// A shot was struck, the balls settled and the advised ball is still up.
    case missed
    /// The cue ball went down.
    case scratch(pocket: PocketID)

    public var event: FeedbackEvent {
        switch self {
        case .madeAsAdvised: .shotMade
        case .madeOther: .shotMadeOther
        case .missed: .shotMissed
        case .scratch: .scratch
        }
    }

    /// Counts toward "made" on a scoreboard.
    public var isMade: Bool {
        switch self {
        case .madeAsAdvised, .madeOther: true
        case .missed, .scratch: false
        }
    }
}

public struct ShotOutcomeDetector: Sendable, Equatable {

    public struct Config: Sendable, Equatable {
        /// A struck cue ball moves at least this fast (m/s) between two
        /// frames. Tracker jitter is a few millimetres a frame; a hand
        /// repositioning the ball is slower than this.
        public var strikeSpeed = 0.5
        /// ...and ends up at least this far (m) from where it rested.
        public var strikeDistance = 0.08
        /// Seconds the strike may wait for its confirming frame.
        public var pendingTimeout = 0.6
        /// A ball slower than this (m/s) is at rest.
        public var settleSpeed = 0.08
        /// Rest for this long (s) before a miss is called.
        public var settleTime = 1.0
        /// No miss is called sooner than this (s) after the strike. It has
        /// to outlast a ball that is pocketed and still standing in as a
        /// stale ring: up to ~1.5 s of roll, the tracker's 2.5 s coast, and
        /// `confirmAbsence` on top of that, with a margin.
        public var missDelay = 4.5
        /// A ball absent this long (s) from the state is gone.
        public var confirmAbsence = 0.8
        /// A ball that comes back within this distance (m) of where it was
        /// lost was hidden, not pocketed.
        public var reappearRadius = 0.10
        /// A ball last seen within a pocket's capture radius plus this slack
        /// (m) went into it. The detector loses a ball as the jaw hides it.
        public var pocketSlack = 0.06
        /// A ball heading for a pocket at least this fast (m/s)...
        public var headingMinSpeed = 0.25
        /// ...and within this distance (m) of it counts as pocketed.
        public var headingLookahead = 0.35
        /// A shot not resolved in this many seconds is dropped silently.
        public var maxWindow = 15.0
        /// Strikes are ignored for this long (s) after an outcome.
        public var cooldown = 1.5

        public init() {}
    }

    public var config: Config

    // MARK: Resting

    private struct Sample: Sendable, Equatable {
        var position: Vec2
        var time: TimeInterval
    }

    private struct Pending: Sendable, Equatable {
        var anchor: Vec2
        var time: TimeInterval
        var cueID: BallID
        var advised: AdvisedShot?
    }

    private var sample: Sample?
    private var anchor: Vec2?
    private var restCueID: BallID?
    private var restAdvised: AdvisedShot?
    private var pending: Pending?
    private var cooldownUntil: TimeInterval = -.infinity
    private var lastTime: TimeInterval?

    // MARK: In flight

    private struct Track: Sendable, Equatable {
        var position: Vec2
        var time: TimeInterval
        var velocity: Vec2
        var isCue: Bool
    }

    private struct Vanished: Sendable, Equatable {
        var id: BallID
        var isCue: Bool
        var position: Vec2
        var velocity: Vec2
        var since: TimeInterval
    }

    private struct Flight: Sendable, Equatable {
        var startedAt: TimeInterval
        var advised: AdvisedShot?
        var tracks: [BallID: Track] = [:]
        var known: Set<BallID> = []
        var vanished: [Vanished] = []
        /// Object-ball ids that appeared after the strike.
        var newcomers: Set<BallID> = []
        var lastMotionAt: TimeInterval
    }

    private var flight: Flight?

    public init(config: Config = Config()) {
        self.config = config
    }

    /// True between a confirmed strike and its outcome.
    public var isShotInFlight: Bool { flight != nil }

    public mutating func reset() {
        sample = nil
        anchor = nil
        restCueID = nil
        restAdvised = nil
        pending = nil
        flight = nil
        cooldownUntil = -.infinity
        lastTime = nil
    }

    /// Fold in one tracked frame. `advised` is the shot on offer right now;
    /// the one that counts is the one on offer just BEFORE the strike.
    public mutating func observe(_ state: TableState, advised: AdvisedShot?) -> ShotOutcome? {
        let now = state.timestamp
        // A clock that runs backwards is a new session.
        if let last = lastTime, now < last - 0.001 { reset() }
        lastTime = now

        if flight != nil {
            let (finished, outcome) = advance(state)
            if finished {
                flight = nil
                sample = nil
                anchor = nil
                pending = nil
                cooldownUntil = now + config.cooldown
            }
            return outcome
        }
        rest(state, advised: advised)
        return nil
    }

    // MARK: Resting: did a strike happen?

    private mutating func rest(_ state: TableState, advised: AdvisedShot?) {
        let now = state.timestamp
        let cue = state.cueBall

        if let waiting = pending {
            if now - waiting.time > config.pendingTimeout {
                pending = nil
            } else if let cue {
                if cue.position.distance(to: waiting.anchor) >= config.strikeDistance,
                   !identitySwapped(state, restCueID: waiting.cueID) {
                    startFlight(state, pending: waiting)
                } else {
                    // It came back, or another ball took over the label.
                    pending = nil
                    refreshRest(cue, advised: advised, now: now)
                }
                return
            } else {
                return // the cue ball is hidden this frame; keep waiting
            }
        }

        guard let cue else {
            sample = nil
            return
        }
        if now >= cooldownUntil, let last = sample, let rest = anchor, now > last.time {
            let speed = cue.position.distance(to: last.position) / (now - last.time)
            if speed >= config.strikeSpeed,
               cue.position.distance(to: rest) >= config.strikeDistance {
                pending = Pending(anchor: rest, time: now, cueID: restCueID ?? cue.id,
                                  advised: restAdvised)
                sample = Sample(position: cue.position, time: now)
                return
            }
        }
        refreshRest(cue, advised: advised, now: now)
    }

    private mutating func refreshRest(_ cue: Ball, advised: AdvisedShot?, now: TimeInterval) {
        sample = Sample(position: cue.position, time: now)
        anchor = cue.position
        restCueID = cue.id
        restAdvised = advised
    }

    /// The "cue ball" label moved to a different ball while the old one is
    /// still on the table as an object ball: a re-designation, not a shot.
    private func identitySwapped(_ state: TableState, restCueID: BallID) -> Bool {
        guard let old = state.ball(restCueID), old.kind != .cue,
              let cue = state.cueBall, cue.id != restCueID else { return false }
        return true
    }

    private mutating func startFlight(_ state: TableState, pending: Pending) {
        var next = Flight(startedAt: pending.time, advised: pending.advised,
                          lastMotionAt: state.timestamp)
        for ball in state.balls {
            next.known.insert(ball.id)
            next.tracks[ball.id] = Track(position: ball.position, time: state.timestamp,
                                         velocity: .zero, isCue: ball.kind == .cue)
        }
        flight = next
        self.pending = nil
    }

    // MARK: In flight: where did everything go?

    /// `finished` says whether the shot is over (with or without a verdict).
    private mutating func advance(_ state: TableState) -> (finished: Bool, outcome: ShotOutcome?) {
        guard var shot = flight else { return (true, nil) }
        let now = state.timestamp

        if now - shot.startedAt > config.maxWindow { return (true, nil) }

        track(state, into: &shot)
        flight = shot

        let aged = shot.vanished.filter { now - $0.since >= config.confirmAbsence }
        let objectPending = shot.vanished.contains { !$0.isCue && now - $0.since < config.confirmAbsence }

        // Scratch: the cue ball went and nothing wears its label now.
        if state.cueBall == nil,
           let cue = aged.first(where: { $0.isCue }),
           let pocket = pocket(for: cue, in: state.table) {
            return (true, .scratch(pocket: pocket.id))
        }

        let objects = shot.vanished.filter { !$0.isCue }
        let net = objects.count - shot.newcomers.count
        if !objectPending, net > 0 {
            let down = aged.filter { !$0.isCue }
                .compactMap { vanished in pocket(for: vanished, in: state.table).map { (vanished, $0) } }
            if let best = choose(down, advised: shot.advised, vanished: shot.vanished) {
                return (true, best)
            }
        }

        // A miss is only called on a quiet table, past the longest coast.
        guard now - shot.startedAt >= config.missDelay,
              now - shot.lastMotionAt >= config.settleTime, !objectPending else { return (false, nil) }
        let cueGone = state.cueBall == nil
        let unexplained = net > 0
        if cueGone || unexplained { return (true, nil) }
        guard let advised = shot.advised, shot.known.contains(advised.ball) else { return (true, nil) }
        return (true, .missed)
    }

    private func choose(_ down: [(Vanished, Pocket)], advised: AdvisedShot?,
                        vanished: [Vanished]) -> ShotOutcome? {
        guard !down.isEmpty else { return nil }
        let ordered = down.sorted { lhs, rhs in
            let l = lhs.0.id == advised?.ball
            let r = rhs.0.id == advised?.ball
            if l != r { return l }
            return lhs.0.position.distance(to: lhs.1.position)
                < rhs.0.position.distance(to: rhs.1.position)
        }
        let (ball, pocket) = ordered[0]
        if let advised, pocket.id == advised.pocket {
            let advisedGone = vanished.contains { $0.id == advised.ball }
            if ball.id == advised.ball || advisedGone {
                return .madeAsAdvised(ball: ball.id, pocket: pocket.id)
            }
        }
        return .madeOther(ball: ball.id, pocket: pocket.id)
    }

    /// Update tracks, and note what vanished, what came back and what is new.
    private func track(_ state: TableState, into shot: inout Flight) {
        let now = state.timestamp
        let present = Set(state.balls.map(\.id))

        for ball in state.balls {
            let isCue = ball.kind == .cue
            if var existing = shot.tracks[ball.id] {
                let dt = now - existing.time
                if dt > 0 {
                    existing.velocity = (ball.position - existing.position) / dt
                    if existing.velocity.length > config.settleSpeed { shot.lastMotionAt = now }
                }
                existing.position = ball.position
                existing.time = now
                existing.isCue = isCue
                shot.tracks[ball.id] = existing
                continue
            }
            shot.lastMotionAt = now
            if let index = shot.vanished.firstIndex(where: { $0.id == ball.id }) {
                shot.vanished.remove(at: index) // the same ball, back from behind a hand
            } else if let index = shot.vanished.firstIndex(where: {
                $0.isCue == isCue && $0.position.distance(to: ball.position) <= config.reappearRadius
            }) {
                shot.vanished.remove(at: index) // re-acquired where it was lost
            } else if !isCue, !shot.known.contains(ball.id) {
                shot.newcomers.insert(ball.id)
            }
            shot.tracks[ball.id] = Track(position: ball.position, time: now,
                                         velocity: .zero, isCue: isCue)
        }

        for (id, lost) in shot.tracks where !present.contains(id) {
            shot.vanished.append(Vanished(id: id, isCue: lost.isCue, position: lost.position,
                                          velocity: lost.velocity, since: now))
            shot.tracks[id] = nil
        }
    }

    /// The pocket a vanished ball went into, if it plausibly did: last seen
    /// inside a pocket's capture radius (plus slack), or heading for one.
    private func pocket(for lost: Vanished, in table: Table) -> Pocket? {
        let near = table.pockets
            .map { ($0, lost.position.distance(to: $0.position)) }
            .filter { $0.1 <= $0.0.captureRadius + config.pocketSlack }
            .min { $0.1 < $1.1 }
        if let near { return near.0 }

        let speed = lost.velocity.length
        guard speed >= config.headingMinSpeed else { return nil }
        let direction = lost.velocity / speed
        return table.pockets
            .compactMap { pocket -> (Pocket, Double)? in
                let toPocket = pocket.position - lost.position
                let along = toPocket.dot(direction)
                guard along >= 0, along <= config.headingLookahead,
                      abs(toPocket.cross(direction)) <= pocket.captureRadius else { return nil }
                return (pocket, along)
            }
            .min { $0.1 < $1.1 }?.0
    }
}
