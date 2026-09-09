//
//  StickDwell.swift
//  ARExperience
//
//  Has this cue moved lately?
//
//  A cue lying on the cloth is indistinguishable from a cue being aimed in
//  any SINGLE frame — a 2-D bounding box cannot see that one is held 20 cm
//  above the felt. Every per-frame geometric gate tried against two real
//  recordings failed on this: the discarded cue's axis actually passes
//  CLOSER to the cue ball than the aimed one's, so tightening the bounds
//  rejects the player first (a 6 cm / 30 cm gate admitted 2.6 % of genuine
//  aiming frames).
//
//  Over TIME the two are obvious. A cue being aimed is picked up, set down,
//  drawn back, stroked; a cue lying on the cloth is furniture. Measured on
//  the two recordings, over an eight-second window:
//
//    aiming        0 % of windows stay inside 35 cm
//    lying down   60 % of windows stay inside 35 cm
//
//  Zero on the aiming side is the number that matters: this can suppress a
//  discarded cue without ever suppressing a player who is addressing the
//  ball. Shorter windows do not have that property — at four seconds, 12 %
//  of genuine aiming windows look static, which is exactly the moment the
//  guide is most wanted.
//

import CueSyncCore
import Foundation

/// Rolling record of where a detected cue has been, used to tell a cue
/// that is being handled from one that is lying there.
public struct StickDwell: Sendable {
    public struct Config: Sendable, Equatable {
        /// How far back to look.
        public var window: TimeInterval
        /// A cue whose position stays inside this box over the whole
        /// window is not being aimed with.
        public var maxSpread: Double

        public init(window: TimeInterval = 8.0, maxSpread: Double = 0.35) {
            self.window = window
            self.maxSpread = maxSpread
        }

        public static let `default` = Config()
    }

    public let config: Config
    /// Named rather than a tuple so the type can synthesise Equatable
    /// for tests; tuples cannot.
    struct Sample: Sendable, Equatable {
        var time: TimeInterval
        var position: Vec2
    }
    private var samples: [Sample] = []

    public init(config: Config = .default) {
        self.config = config
    }

    /// Note where the cue is now. `position` is the quad's centroid in
    /// table space; `time` is the frame's timestamp, never wall clock, so
    /// replay and the live session agree.
    public mutating func record(_ position: Vec2, at time: TimeInterval) {
        // A jump backwards means a new session or a reset; start over
        // rather than measuring a spread across the discontinuity.
        if let last = samples.last, time < last.time {
            samples.removeAll()
        }
        samples.append(Sample(time: time, position: position))
        // Keep ONE sample from before the cutoff. Pruning everything older
        // leaves a span strictly shorter than the window, so `isStatic`'s
        // "a full window has been observed" test could never pass. Holding
        // the boundary sample also makes the spread slightly conservative,
        // which is the right direction: harder to call a cue resting.
        let cutoff = time - config.window
        if let lastStale = samples.lastIndex(where: { $0.time < cutoff }), lastStale > 0 {
            samples.removeFirst(lastStale)
        }
    }

    /// True once the cue has been observed for a FULL window and never
    /// left a `maxSpread` box in it.
    ///
    /// The full-window requirement is what stops this from firing early: a
    /// cue that has only just been seen has no history, and the honest
    /// answer then is "not known to be static", not "static".
    public var isStatic: Bool {
        guard let first = samples.first, let last = samples.last,
              last.time - first.time >= config.window else { return false }
        let xs = samples.map(\.position.x)
        let ys = samples.map(\.position.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return false }
        return Vec2(maxX - minX, maxY - minY).length <= config.maxSpread
    }

    /// Seconds of history held, for diagnostics.
    public var observedSeconds: TimeInterval {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return last.time - first.time
    }

    public mutating func reset() {
        samples.removeAll()
    }

    public static func centroid(of quad: [Vec2]) -> Vec2? {
        guard !quad.isEmpty else { return nil }
        let sum = quad.reduce(Vec2.zero) { $0 + $1 }
        return sum * (1.0 / Double(quad.count))
    }
}
