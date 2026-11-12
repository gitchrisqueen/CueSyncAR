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
//    state.json every call while a client fetched it lately (scripts poll it
//               at 4 to 6 Hz), else every `stateIdlePeriod`
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

        public init(frameWatchedPeriod: TimeInterval = 1,
                    frameIdlePeriod: TimeInterval = 5,
                    stateIdlePeriod: TimeInterval = 1,
                    uiPeriod: TimeInterval = 1) {
            self.frameWatchedPeriod = frameWatchedPeriod
            self.frameIdlePeriod = frameIdlePeriod
            self.stateIdlePeriod = stateIdlePeriod
            self.uiPeriod = uiPeriod
        }

        public static let `default` = Config()
    }

    /// Which surfaces a client has fetched recently.
    public struct Watching: Sendable, Equatable {
        public var frame: Bool
        public var state: Bool
        public var ui: Bool

        public init(frame: Bool, state: Bool, ui: Bool) {
            self.frame = frame
            self.state = state
            self.ui = ui
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
        if watching.state || Self.elapsed(since: lastState, now: now, atLeast: config.stateIdlePeriod) {
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
        return now - last >= period
    }
}
