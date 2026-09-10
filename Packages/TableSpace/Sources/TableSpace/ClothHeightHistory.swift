//
//  ClothHeightHistory.swift
//  CueSync AR
//
//  Whether the cloth height has stopped moving — which is not the same
//  question as whether the balls agree, and is the one that was missing.
//
//  Measured on the device, minutes apart, on a table that never moved:
//
//      height -0.367   44 samples   8 mm spread   balls 2.72-4.11 m
//      height -0.512   80 samples  13 mm spread   balls 1.95-3.13 m
//
//  Both pass every confidence test the app had. They are 145 mm apart,
//  and the true cloth — solved from the pocket geometry and confirmed by
//  a fit that only closes there — is -0.481. So the first reading was
//  114 mm wrong while reporting 8 mm of spread.
//
//  Spread cannot catch that, and no threshold on it ever will. Spread
//  measures whether the samples agree with EACH OTHER. A systematic error
//  — the detector's boxes running slightly large, so every ball reads
//  slightly near — moves every sample the same way, so they go on
//  agreeing beautifully while all being wrong together. Adding more balls
//  tightens the spread and does not touch the error, which is the worst
//  possible combination: confidence rising while accuracy does not.
//
//  What DOES catch it is time. The estimate was not stationary; it was
//  converging, and it converged 145 mm as the device saw the table from
//  more angles and closer ranges. An estimate that has moved 145 mm in
//  the last minute is not settled no matter how tight its spread, and an
//  estimate that has not moved in a minute has earned some trust.
//
//  Hence this: the smallest thing that can say "still moving."
//
//  One rule matters more than the rest — NOT ENOUGH HISTORY IS NOT
//  SETTLED. Reporting "no drift" from two samples a second apart would
//  reproduce the original bug exactly, in a new place: confident, early,
//  and wrong. Until the window is actually covered, the honest answer is
//  that we do not know yet.
//

import Foundation

/// A short rolling record of the cloth-height estimate, kept only long
/// enough to say whether it is still moving.
public struct ClothHeightHistory: Sendable, Equatable {

    /// One reading and when it was taken.
    public struct Reading: Sendable, Equatable {
        public var time: TimeInterval
        public var height: Double

        public init(time: TimeInterval, height: Double) {
            self.time = time
            self.height = height
        }
    }

    /// How far back to look, in seconds.
    ///
    /// Long enough that a user re-aiming the device is inside it — that
    /// re-aim is precisely the event that moved the estimate 145 mm — and
    /// short enough that the table is settled well before anyone has
    /// finished tapping four pockets.
    public let window: TimeInterval

    private var readings: [Reading] = []

    public init(window: TimeInterval = 12) {
        self.window = max(window, 1)
    }

    /// Add a reading and forget anything older than the window.
    public mutating func record(height: Double, at time: TimeInterval) {
        // Out-of-order readings would make `covered` lie about how much
        // history there is, so the record only ever moves forward.
        if let last = readings.last, time < last.time { readings.removeAll() }
        readings.append(Reading(time: time, height: height))
        let cutoff = time - window
        readings.removeAll { $0.time < cutoff }
    }

    /// Every reading still inside the window.
    public var recent: [Reading] { readings }

    /// Whether there is enough history to say anything at all.
    ///
    /// Requires readings spanning at least three quarters of the window,
    /// and at least three of them. Two readings a moment apart describe a
    /// moment, not a trend.
    public var isCovered: Bool {
        guard readings.count >= 3,
              let first = readings.first, let last = readings.last else { return false }
        return last.time - first.time >= window * 0.75
    }

    /// How far the estimate has moved across the window, in metres, or nil
    /// when there is not yet enough history to know.
    ///
    /// Peak to trough rather than a standard deviation: a monotonic
    /// convergence — which is what this actually does — has a modest
    /// deviation and a large total movement, and it is the movement that
    /// says the answer is not in yet.
    public var drift: Double? {
        guard isCovered else { return nil }
        let heights = readings.map(\.height)
        guard let low = heights.min(), let high = heights.max() else { return nil }
        return high - low
    }

    /// Millimetres of drift, rounded, for the places that report integers.
    public var driftMillimetres: Int? {
        drift.map { Int(($0 * 1000).rounded()) }
    }

    /// Whether the estimate has stopped moving enough to build on.
    ///
    /// `tolerance` is in metres. The default is 15 mm: below a ball's
    /// radius, and far below the 114 mm error this exists to catch, while
    /// still above the few millimetres the estimate jitters by once it has
    /// converged.
    public func hasSettled(tolerance: Double = 0.015) -> Bool {
        guard let drift else { return false }
        return drift <= tolerance
    }

    /// The best current answer, or nil when there is none.
    public var latest: Double? { readings.last?.height }
}
