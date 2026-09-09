//
//  DetectionHealth.swift
//  CueSyncUI
//
//  Noticing when the app has stopped seeing most of the table, and
//  saying so.
//
//  ARKit's own `insufficientFeatures` does not cover this. Measured on
//  the owner's table at dusk: ARKit tracked the room perfectly well —
//  tiles, furniture and window frames are plenty of features — while
//  ball detection collapsed. Over 290 recorded frames the detector found
//  all six balls in 2 of them, and a median of 2 per frame; the six
//  balls were individually seen in 58 %, 31 %, 22 %, 6 %, 2 % and 1 % of
//  frames. The HUD said "Tracking 3 balls" throughout, in the same
//  reassuring tone it uses when everything is fine.
//
//  Saying "Tracking 3" is not false. It is just not the useful sentence,
//  because the player cannot tell it apart from a table with three balls
//  left on it. What they need to know is that the app is seeing a
//  fraction of what it saw a minute ago.
//
//  The signal is recall against the PEAK recently seen, not against any
//  assumed rack size. The app never knows how many balls are on the
//  table — balls get pocketed, and a practice layout can be any size —
//  but it does know how many it could see a moment ago, and a fall from
//  six to two is a fact about the app, not about the table.
//

import Foundation

public struct DetectionHealth: Sendable, Equatable {
    public struct Config: Sendable, Equatable {
        /// How far back "recently" reaches. Long enough to span a shot
        /// and the balls settling, short enough that a rack genuinely
        /// being cleared stops looking like a fault.
        public var window: TimeInterval
        /// Never complain until the app has managed to see this many at
        /// once. Below it there is no peak worth falling from, and a
        /// player setting up two balls for a drill is not a fault.
        public var minimumPeak: Int
        /// At or below this fraction of the peak, recall has collapsed.
        public var thinFraction: Double
        /// And it must climb back above THIS fraction to be called
        /// healthy again. The gap is deliberate: a warning that flickers
        /// on and off at the boundary is worse than one that is late.
        public var healthyFraction: Double
        /// Mean frame luminance, 0...1, below which the scene really is
        /// dark and "more light would help" is a claim rather than a
        /// guess. Above it the app says what it knows — that it has
        /// stopped seeing balls — without inventing a cause.
        public var darkLuminance: Double
        /// Readings this old are forgotten.
        public var settleSeconds: TimeInterval

        public init(window: TimeInterval = 20,
                    minimumPeak: Int = 3,
                    thinFraction: Double = 0.5,
                    healthyFraction: Double = 0.75,
                    darkLuminance: Double = 0.32,
                    settleSeconds: TimeInterval = 4) {
            self.window = window
            self.minimumPeak = minimumPeak
            self.thinFraction = thinFraction
            self.healthyFraction = healthyFraction
            self.darkLuminance = darkLuminance
            self.settleSeconds = settleSeconds
        }

        public static let `default` = Config()
    }

    /// What the app can currently see, relative to what it could.
    public enum Verdict: Sendable, Equatable {
        case healthy
        /// Seeing `seen` where it recently managed `peak`. `dark` is true
        /// only when the frames really are dim, so the copy can offer a
        /// cause when there is one and stay quiet about it when there
        /// isn't.
        case thin(seen: Int, peak: Int, dark: Bool)
    }

    /// One frame's reading. A named type rather than a tuple so the
    /// whole value stays Equatable, which the app's Observation-backed
    /// model needs to avoid re-rendering on every frame.
    struct Sample: Sendable, Equatable {
        var time: TimeInterval
        var count: Int
        var luminance: Double?
    }

    public var config: Config
    private var samples: [Sample] = []
    private var startedAt: TimeInterval?
    private var isThin = false

    public init(config: Config = .default) {
        self.config = config
    }

    /// Offer one frame's reading. `luminance` is the mean brightness of
    /// the frame, 0...1, or nil when the frame carried no pixels (replay).
    public mutating func observe(detected: Int, luminance: Double? = nil,
                                 at time: TimeInterval) {
        if startedAt == nil { startedAt = time }
        samples.append(Sample(time: time, count: detected, luminance: luminance))
        let cutoff = time - config.window
        samples.removeAll { $0.time < cutoff }
    }

    public mutating func reset() {
        samples = []
        startedAt = nil
        isThin = false
    }

    /// The peak the app managed within the window.
    public var peak: Int { samples.map(\.count).max() ?? 0 }

    /// What it is seeing now — the median of the last few readings, not
    /// the newest one. A detector drops a frame here and there even in
    /// good light, and one empty frame is not a collapse.
    public var current: Int {
        let recent = samples.suffix(5).map(\.count).sorted()
        guard !recent.isEmpty else { return 0 }
        return recent[recent.count / 2]
    }

    /// Mean luminance over the window, or nil when no frame reported one.
    public var luminance: Double? {
        let values = samples.compactMap(\.luminance)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    public mutating func verdict(at time: TimeInterval) -> Verdict {
        // Say nothing while the session is finding its feet: every cold
        // start begins at zero balls and would otherwise announce a
        // collapse before the first frame is even processed.
        guard let startedAt, time - startedAt >= config.settleSeconds else {
            isThin = false
            return .healthy
        }
        let peak = peak
        guard peak >= config.minimumPeak else {
            isThin = false
            return .healthy
        }
        let ratio = Double(current) / Double(peak)
        if isThin {
            if ratio >= config.healthyFraction { isThin = false }
        } else if ratio <= config.thinFraction {
            isThin = true
        }
        guard isThin else { return .healthy }
        let dark = (luminance ?? 1) < config.darkLuminance
        return .thin(seen: current, peak: peak, dark: dark)
    }
}
