//
//  IngestThrottle.swift
//  PerceptionKit
//
//  Rate limiter for frame ingest, timed by an explicit clock value instead
//  of wall time. The app feeds it the frame's own capture timestamp (or an
//  injected clock), so the SAME frame sequence always admits the same
//  frames — a wall-clock throttle (`Date()`) made the hosted-API tracking
//  path irreproducible under replay. Pure value type, fully tested.
//

import Foundation

public struct IngestThrottle: Sendable, Equatable {
    /// Minimum seconds between admitted frames.
    public var minimumInterval: TimeInterval
    private var lastAdmittedAt: TimeInterval?

    public init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    /// Whether a frame at `time` (seconds, monotonic) may pass. The first
    /// frame always passes; a frame passes afterwards once `minimumInterval`
    /// has elapsed since the last ADMITTED frame. Time running backwards
    /// (a clock reset) admits and re-bases rather than blocking forever.
    public mutating func admit(at time: TimeInterval) -> Bool {
        if let last = lastAdmittedAt, time >= last, time - last < minimumInterval {
            return false
        }
        lastAdmittedAt = time
        return true
    }

    /// Forget the last admission so the next frame passes.
    public mutating func reset() {
        lastAdmittedAt = nil
    }
}
