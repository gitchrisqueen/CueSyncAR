//
//  FrameChangeGate.swift
//  CueSync AR
//
//  Don't run the detector on a picture we already looked at.
//
//  The live pipeline had NO gate. `MotionGate` exists but is used only by
//  the hosted-preview path, and it gates on CAMERA POSE — which is the
//  right reason not to use it here, because a phone on a tripod is still
//  while the balls move. So every delivered frame ran a Core ML pass, and
//  between shots that is the same table, over and over, for the whole of a
//  fifteen-minute session.
//
//  This gate asks the other question: did the PICTURE change. If it did
//  not, neither the camera nor the balls moved, and the previous answer is
//  still the right one.
//
//  WHY MAX-CELL DELTA AND NOT MEAN. A ball crossing a 24x24 grid changes
//  perhaps three cells, hard. Averaged over 576 cells that is a change of
//  ~0.002 — indistinguishable from sensor noise, so a mean-based gate
//  would either skip real motion or fire constantly. The maximum is the
//  statistic that separates them: noise moves every cell a little, a ball
//  moves a few cells a lot.
//
//  The mean is still watched, but for the other thing it is good at:
//  a lighting change that shifts the whole frame at once.
//

import Foundation

/// A coarse fingerprint of one frame — cheap to take, cheap to compare.
public struct FrameSignature: Sendable, Equatable {
    /// Row-major luma samples, 0...1.
    public let cells: [Double]

    public init(cells: [Double]) { self.cells = cells }

    public var meanLuminance: Double {
        guard !cells.isEmpty else { return 0 }
        return cells.reduce(0, +) / Double(cells.count)
    }

    /// The largest single-cell change, and the whole-frame change. Nil when
    /// the two signatures are not comparable (different grids), which must
    /// be treated as "changed" rather than "same".
    public func difference(from other: FrameSignature) -> (maximum: Double, mean: Double)? {
        guard cells.count == other.cells.count, !cells.isEmpty else { return nil }
        var maximum = 0.0
        var total = 0.0
        for (a, b) in zip(cells, other.cells) {
            let delta = abs(a - b)
            maximum = Swift.max(maximum, delta)
            total += delta
        }
        return (maximum, total / Double(cells.count))
    }
}

/// Decides whether this frame is worth looking at.
public struct FrameChangeGate: Sendable, Equatable {

    public struct Config: Sendable, Equatable {
        /// Largest single-cell luma change that counts as something moving.
        /// Above sensor noise, below the contrast of a ball arriving in a
        /// cell that did not have one.
        public var cellThreshold: Double
        /// Whole-frame change that counts — catches lighting shifts, which
        /// move every cell a little and no cell a lot.
        public var meanThreshold: Double
        /// Process at least this often regardless. The tracker's
        /// visible-miss grace is 2.5 s, so staying well under that means a
        /// skipped stretch can never retire a track; and it bounds how
        /// stale the overlay can be if the gate is ever wrong.
        public var heartbeat: TimeInterval

        public init(cellThreshold: Double = 0.06,
                    meanThreshold: Double = 0.01,
                    heartbeat: TimeInterval = 1.0) {
            self.cellThreshold = cellThreshold
            self.meanThreshold = meanThreshold
            self.heartbeat = heartbeat
        }
    }

    public var config: Config
    /// Off by default is the wrong default for a battery win, but ON by
    /// default is the wrong default for a perception change nobody has
    /// watched at a table yet. It is on, and switchable from the mirror.
    public var isEnabled: Bool

    private var lastProcessed: FrameSignature?
    private var lastProcessedAt: TimeInterval?

    /// How many frames this gate has skipped, and how many it let through.
    public private(set) var skipped = 0
    public private(set) var processed = 0

    public init(config: Config = Config(), isEnabled: Bool = true) {
        self.config = config
        self.isEnabled = isEnabled
    }

    /// Fraction of frames skipped so far; nil before anything was seen.
    public var skipRate: Double? {
        let total = skipped + processed
        return total > 0 ? Double(skipped) / Double(total) : nil
    }

    /// Whether to run detection on this frame.
    ///
    /// A nil signature means the frame could not be sampled — an unreadable
    /// pixel format, a platform without CoreVideo. That must ALWAYS process:
    /// the gate's job is to skip work it can prove is redundant, and it can
    /// prove nothing about a frame it could not read.
    public mutating func shouldProcess(_ signature: FrameSignature?,
                                       at timestamp: TimeInterval) -> Bool {
        guard isEnabled, let signature else {
            processed += 1
            lastProcessed = signature
            lastProcessedAt = timestamp
            return true
        }
        defer {
            if lastProcessedAt == timestamp { lastProcessed = signature }
        }
        guard let previous = lastProcessed, let since = lastProcessedAt else {
            processed += 1
            lastProcessed = signature
            lastProcessedAt = timestamp
            return true
        }
        // Heartbeat first: a gate that can stall indefinitely is a frozen
        // overlay waiting to happen, and the cost of being wrong here is
        // far higher than the cost of one extra inference per second.
        if timestamp - since >= config.heartbeat {
            processed += 1
            lastProcessed = signature
            lastProcessedAt = timestamp
            return true
        }
        guard let delta = signature.difference(from: previous) else {
            processed += 1
            lastProcessed = signature
            lastProcessedAt = timestamp
            return true
        }
        if delta.maximum >= config.cellThreshold || delta.mean >= config.meanThreshold {
            processed += 1
            lastProcessed = signature
            lastProcessedAt = timestamp
            return true
        }
        skipped += 1
        return false
    }

    public mutating func reset() {
        lastProcessed = nil
        lastProcessedAt = nil
        skipped = 0
        processed = 0
    }
}
