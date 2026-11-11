//
//  FeedbackWatcher.swift
//  CoachKit
//
//  Turns "what the app looks like now" into feedback events, with the
//  debouncing that keeps jitter from buzzing the player's hand. The app
//  samples one `FeedbackObservation` a few times a second; this type
//  remembers the previous one and reports only what CHANGED and HELD.
//
//  Pure and time-driven by the observation's own clock, so a test can run a
//  minute of play in microseconds.
//
//  What it deliberately does not do: shot made / missed. That needs every
//  tracker frame, not a 4 Hz sample, and lives in `ShotOutcomeDetector`.
//

import Foundation

/// The facts the watcher reads. All of them already exist on the app's
/// session model; none is computed here.
public struct FeedbackObservation: Sendable, Equatable {
    /// Monotonic seconds.
    public var time: TimeInterval
    /// The table calibration is locked.
    public var locked: Bool
    /// The calibration flow's refusal text, when it refused to lock.
    public var refusal: String?
    /// Live ball tracking is running.
    public var live: Bool
    /// ARKit tracking is degraded (lost, too fast, too dark).
    public var degraded: Bool
    public var ballCount: Int
    /// The shot on offer: ball and pocket raw values.
    public var shot: String?
    /// The player chose `shot` rather than the app suggesting it.
    public var shotChosenByPlayer: Bool
    /// Live and tracking, but no clean shot exists.
    public var noCleanShot: Bool
    public var recording: Bool

    public init(time: TimeInterval, locked: Bool = false, refusal: String? = nil,
                live: Bool = false, degraded: Bool = false, ballCount: Int = 0,
                shot: String? = nil, shotChosenByPlayer: Bool = false,
                noCleanShot: Bool = false, recording: Bool = false) {
        self.time = time
        self.locked = locked
        self.refusal = refusal
        self.live = live
        self.degraded = degraded
        self.ballCount = ballCount
        self.shot = shot
        self.shotChosenByPlayer = shotChosenByPlayer
        self.noCleanShot = noCleanShot
        self.recording = recording
    }
}

/// An event with the detail the banner folds in.
public struct DetectedFeedback: Sendable, Equatable {
    public var event: FeedbackEvent
    public var detail: String?

    public init(_ event: FeedbackEvent, detail: String? = nil) {
        self.event = event
        self.detail = detail
    }
}

public struct FeedbackWatcher: Sendable, Equatable {
    public struct Config: Sendable, Equatable {
        /// A ball count must hold this long before it counts as a change.
        public var countHold: TimeInterval = 1.2
        /// The app's suggestion must hold this long before "shot changed".
        public var shotHold: TimeInterval = 0.8
        /// No clean shot must hold this long before it is announced.
        public var noShotHold: TimeInterval = 1.5
        /// Degraded tracking must last this long to count as lost.
        public var lostHold: TimeInterval = 1.0
        /// ...and be healthy this long to count as recovered.
        public var recoveredHold: TimeInterval = 0.8

        public init() {}
    }

    public var config: Config

    private var previous: FeedbackObservation?
    // Ball count debounce.
    private var settledCount: Int?
    private var countCandidate: Int?
    private var countSince: TimeInterval = 0
    // Suggested shot debounce.
    private var heldShot: String?
    private var shotCandidate: String?
    private var shotSince: TimeInterval = 0
    // No-clean-shot latch.
    private var noShotSince: TimeInterval?
    private var noShotAnnounced = false
    // Tracking-lost latch.
    private var degradedSince: TimeInterval?
    private var healthySince: TimeInterval?
    private var lostAnnounced = false
    private var lastRefusal: String?

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Fold in one observation; returns what, if anything, just happened.
    public mutating func observe(_ obs: FeedbackObservation) -> [DetectedFeedback] {
        var events: [DetectedFeedback] = []
        defer { previous = obs }

        // The first observation is a baseline, not an event: a calibration
        // restored at launch is not "table locked".
        guard let prev = previous else {
            settledCount = obs.live ? obs.ballCount : nil
            heldShot = obs.shot
            lastRefusal = obs.refusal
            return events
        }

        if obs.locked, !prev.locked { events.append(.init(.tableLocked)) }
        if let refusal = obs.refusal, refusal != lastRefusal, !obs.locked {
            events.append(.init(.calibrationRefused, detail: refusal))
        }
        lastRefusal = obs.refusal

        if obs.recording != prev.recording {
            events.append(.init(obs.recording ? .recordingStarted : .recordingStopped))
        }

        events += trackingEvents(obs)
        guard obs.live else {
            resetLiveState()
            return events
        }
        events += ballCountEvents(obs)
        events += shotEvents(obs, previous: prev)
        events += noShotEvents(obs)
        return events
    }

    // MARK: Tracking lost / recovered

    private mutating func trackingEvents(_ obs: FeedbackObservation) -> [DetectedFeedback] {
        guard obs.live else {
            degradedSince = nil
            healthySince = nil
            lostAnnounced = false
            return []
        }
        if obs.degraded {
            healthySince = nil
            if degradedSince == nil { degradedSince = obs.time }
            if !lostAnnounced, let since = degradedSince, obs.time - since >= config.lostHold {
                lostAnnounced = true
                return [.init(.trackingLost)]
            }
        } else {
            degradedSince = nil
            if lostAnnounced {
                if healthySince == nil { healthySince = obs.time }
                if let since = healthySince, obs.time - since >= config.recoveredHold {
                    lostAnnounced = false
                    healthySince = nil
                    return [.init(.trackingRecovered)]
                }
            }
        }
        return []
    }

    // MARK: Ball count

    private mutating func ballCountEvents(_ obs: FeedbackObservation) -> [DetectedFeedback] {
        guard let settled = settledCount else {
            // Tracking just started: the first count is a baseline unless it
            // already has balls in it, which is "balls found".
            settledCount = obs.ballCount
            countCandidate = nil
            return obs.ballCount > 0
                ? [.init(.ballsFound, detail: Self.balls(obs.ballCount))] : []
        }
        guard obs.ballCount != settled else {
            countCandidate = nil
            return []
        }
        if countCandidate != obs.ballCount {
            countCandidate = obs.ballCount
            countSince = obs.time
            return []
        }
        guard obs.time - countSince >= config.countHold else { return [] }
        settledCount = obs.ballCount
        countCandidate = nil
        let event: FeedbackEvent = settled == 0 ? .ballsFound : .ballCountChanged
        return obs.ballCount > 0 ? [.init(event, detail: Self.balls(obs.ballCount))] : []
    }

    private static func balls(_ count: Int) -> String {
        count == 1 ? "1 ball" : "\(count) balls"
    }

    // MARK: Shot

    private mutating func shotEvents(_ obs: FeedbackObservation,
                                     previous prev: FeedbackObservation) -> [DetectedFeedback] {
        // The player's own tap is acknowledged at once: they acted, they
        // are waiting for it. A held debounce would feel like a missed tap.
        if obs.shotChosenByPlayer, obs.shot != nil,
           !prev.shotChosenByPlayer || obs.shot != prev.shot {
            heldShot = obs.shot
            shotCandidate = nil
            return [.init(.shotSelected)]
        }
        guard let shot = obs.shot else {
            heldShot = nil
            shotCandidate = nil
            return []
        }
        guard let held = heldShot else {
            // The first suggestion is the card appearing, not a change.
            heldShot = shot
            shotCandidate = nil
            return []
        }
        guard shot != held else {
            shotCandidate = nil
            return []
        }
        if shotCandidate != shot {
            shotCandidate = shot
            shotSince = obs.time
            return []
        }
        guard obs.time - shotSince >= config.shotHold else { return [] }
        heldShot = shot
        shotCandidate = nil
        return obs.shotChosenByPlayer ? [] : [.init(.shotChanged)]
    }

    // MARK: No clean shot

    private mutating func noShotEvents(_ obs: FeedbackObservation) -> [DetectedFeedback] {
        guard obs.noCleanShot else {
            noShotSince = nil
            noShotAnnounced = false
            return []
        }
        if noShotSince == nil { noShotSince = obs.time }
        guard !noShotAnnounced, let since = noShotSince,
              obs.time - since >= config.noShotHold else { return [] }
        noShotAnnounced = true
        return [.init(.noCleanShot)]
    }

    private mutating func resetLiveState() {
        settledCount = nil
        countCandidate = nil
        heldShot = nil
        shotCandidate = nil
        noShotSince = nil
        noShotAnnounced = false
    }
}
