//
//  MirrorPacing.swift
//  ARExperience
//
//  How often the debug mirror does its expensive work.
//
//  The AR loop used to hand the mirror three jobs on the main actor:
//    - a screenshot of the ARView (~100 ms on an iPad) once a second, awaited
//      inline so that tick ran 100 ms long;
//    - the `/state.json` document, built every tick;
//    - while anyone had asked for `/ui.jpg`, a drawHierarchy of the whole
//      window plus a JPEG encode EVERY TICK, not once a second.
//  All of it competes with the overlay for the same main actor, and the
//  hand-off from the pipeline waits behind it. This decides which of the
//  three is due, given who is actually looking:
//
//    frame.jpg  every `frameWatchedPeriod` while a client fetched it lately,
//               else every `frameIdlePeriod` (never zero, so the first fetch
//               finds an image; the next one after it is fresh within a tick)
//    state.json while a client fetched it lately: every call if it polls fast
//               (scripts poll it at 4 to 6 Hz and want every tick), else at
//               `stateWatchedFraction` of the client's own poll interval, so a
//               client that asks every 2.5 s is not served a document built
//               every 100 ms (several ms of main actor each); else every
//               `stateIdlePeriod`
//    ui.jpg     at most every `uiPeriod`, and only while a client asked
//
//  Pure value type over a caller-supplied clock: tested on Linux.
//

import Foundation

public struct MirrorPacing: Sendable, Equatable {
    public struct Config: Sendable, Equatable {
        public var frameWatchedPeriod: TimeInterval
        public var frameIdlePeriod: TimeInterval
        public var stateIdlePeriod: TimeInterval
        public var uiPeriod: TimeInterval
        /// A watched state is rebuilt this fraction of the client's poll
        /// interval apart, never slower than `stateWatchedMax`, and every
        /// call when that works out under `stateEveryCallBelow`.
        public var stateWatchedFraction: Double
        public var stateWatchedMax: TimeInterval
        public var stateEveryCallBelow: TimeInterval

        public init(frameWatchedPeriod: TimeInterval = 1,
                    frameIdlePeriod: TimeInterval = 5,
                    stateIdlePeriod: TimeInterval = 1,
                    uiPeriod: TimeInterval = 1,
                    stateWatchedFraction: Double = 0.4,
                    stateWatchedMax: TimeInterval = 1,
                    stateEveryCallBelow: TimeInterval = 0.1) {
            self.frameWatchedPeriod = frameWatchedPeriod
            self.frameIdlePeriod = frameIdlePeriod
            self.stateIdlePeriod = stateIdlePeriod
            self.uiPeriod = uiPeriod
            self.stateWatchedFraction = stateWatchedFraction
            self.stateWatchedMax = stateWatchedMax
            self.stateEveryCallBelow = stateEveryCallBelow
        }

        public static let `default` = Config()

        /// How long a watched state may go without a rebuild, given how often
        /// its client asks (nil: not known, treated as "fast").
        func watchedStatePeriod(pollInterval: TimeInterval?) -> TimeInterval {
            guard let pollInterval, pollInterval.isFinite, pollInterval > 0 else { return 0 }
            let period = Swift.min(pollInterval * stateWatchedFraction, stateWatchedMax)
            return period < stateEveryCallBelow ? 0 : period
        }
    }

    /// Which surfaces a client has fetched recently.
    public struct Watching: Sendable, Equatable {
        public var frame: Bool
        public var state: Bool
        public var ui: Bool
        /// Seconds between the client's recent `/state.json` fetches.
        public var statePollInterval: TimeInterval?

        public init(frame: Bool, state: Bool, ui: Bool, statePollInterval: TimeInterval? = nil) {
            self.frame = frame
            self.state = state
            self.ui = ui
            self.statePollInterval = statePollInterval
        }
    }

    /// What to do on this call.
    public struct Due: Sendable, Equatable {
        public var frame = false
        public var state = false
        public var ui = false

        public init(frame: Bool = false, state: Bool = false, ui: Bool = false) {
            self.frame = frame
            self.state = state
            self.ui = ui
        }
    }

    public var config: Config
    public private(set) var lastFrame: TimeInterval?
    public private(set) var lastState: TimeInterval?
    public private(set) var lastUI: TimeInterval?

    public init(config: Config = .default) {
        self.config = config
    }

    /// What is due at `now`. Whatever is reported due is recorded as done, so
    /// the caller must do it.
    ///
    /// - Parameter frameInFlight: a screenshot is still being taken. The next
    ///   one waits for it rather than piling up behind it.
    public mutating func due(at now: TimeInterval, watching: Watching,
                             frameInFlight: Bool = false) -> Due {
        var due = Due()
        let framePeriod = watching.frame ? config.frameWatchedPeriod : config.frameIdlePeriod
        if !frameInFlight, Self.elapsed(since: lastFrame, now: now, atLeast: framePeriod) {
            due.frame = true
            lastFrame = now
        }
        let statePeriod = watching.state
            ? config.watchedStatePeriod(pollInterval: watching.statePollInterval)
            : config.stateIdlePeriod
        if Self.elapsed(since: lastState, now: now, atLeast: statePeriod) {
            due.state = true
            lastState = now
        }
        if watching.ui, Self.elapsed(since: lastUI, now: now, atLeast: config.uiPeriod) {
            due.ui = true
            lastUI = now
        }
        return due
    }

    /// True when nothing was done yet, the period has passed, or the clock
    /// stepped backwards (a stale stamp must not freeze the mirror).
    private static func elapsed(since last: TimeInterval?, now: TimeInterval,
                                atLeast period: TimeInterval) -> Bool {
        guard let last, now >= last else { return true }
        // A microsecond of slack, so ticks that are exactly one period apart
        // are not pushed to the next tick by floating-point error.
        return now - last >= period - 1e-6
    }
}
