//
//  SessionHealth.swift
//  CueSync AR
//
//  The numbers MVP item 6 promises, as something that can actually be read.
//
//  00-OVERVIEW.md commits to ">= 30 FPS camera feed, overlay latency under
//  ~100 ms, no crashes across a 15-minute session". None of the three was
//  measurable: the mirror published no frame rate, no thermal state and no
//  battery level, and the only latency number in the app timed the
//  detector CALL, not camera-to-overlay.
//
//  Pure, so the arithmetic is provable without a device — the device only
//  has to supply timestamps.
//

import Foundation

/// How hot the device says it is.
///
/// Its own type rather than `ProcessInfo.ThermalState` because that type
/// does not exist in Linux's FoundationEssentials, and this package is
/// built and tested on Linux. The app maps the platform enum onto this at
/// the one place it reads it.
public enum ThermalReading: String, Sendable, Equatable, CaseIterable {
    case nominal, fair, serious, critical, unknown
}

/// A rolling read on how the session is actually performing.
public struct SessionHealth: Sendable, Equatable {

    /// How many recent frames the rate is averaged over. Small enough to
    /// react within a second at 5 Hz, large enough not to jitter.
    public static let window = 20

    private var frameTimes: [TimeInterval] = []
    private var latencies: [Double] = []

    public init() {}

    /// Register one processed frame.
    ///
    /// - Parameters:
    ///   - cameraTimestamp: the frame's own capture time (ARFrame's clock).
    ///   - now: the same clock, read when the overlay for that frame is
    ///     published. The gap between them is the part of end-to-end
    ///     latency this app is responsible for.
    public mutating func note(cameraTimestamp: TimeInterval, publishedAt now: TimeInterval) {
        frameTimes.append(now)
        if frameTimes.count > Self.window { frameTimes.removeFirst() }
        let latency = (now - cameraTimestamp) * 1000
        // Negative or absurd gaps mean the two timestamps came from
        // different clocks; publishing a nonsense number is worse than
        // publishing none, because someone will quote it.
        if latency >= 0, latency < 10_000 {
            latencies.append(latency)
            if latencies.count > Self.window { latencies.removeFirst() }
        }
    }

    /// Frames per second over the window; nil until there are two frames.
    public var framesPerSecond: Double? {
        guard frameTimes.count >= 2, let first = frameTimes.first,
              let last = frameTimes.last, last > first else { return nil }
        return Double(frameTimes.count - 1) / (last - first)
    }

    /// Median camera-to-overlay latency in milliseconds; nil until there is
    /// a sample. Median rather than mean: one stall should not move the
    /// number that gets quoted.
    public var overlayLatencyMilliseconds: Double? {
        guard !latencies.isEmpty else { return nil }
        let sorted = latencies.sorted()
        return sorted[sorted.count / 2]
    }

    /// Worst latency in the window — the one that matters for "does it feel
    /// attached to the table".
    public var worstLatencyMilliseconds: Double? { latencies.max() }

    public mutating func reset() {
        frameTimes.removeAll()
        latencies.removeAll()
    }
}
