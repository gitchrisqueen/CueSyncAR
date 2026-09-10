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

    private var pipelineTicks: [TimeInterval] = []
    private var latencies: [Double] = []
    /// Cumulative ARKit frame count and when it was read, for the CAMERA
    /// rate — a different number from the pipeline rate, and the one MVP
    /// item 6 actually names.
    private var lastCameraSample: CameraSample?

    /// Named, not a tuple: a tuple member blocks `Equatable` synthesis.
    private struct CameraSample: Sendable, Equatable {
        var framesSeen: Int
        var at: TimeInterval
    }

    private var cameraRate: Double?

    public init() {}

    /// Register one processed frame.
    ///
    /// - Parameters:
    ///   - cameraTimestamp: the frame's own capture time (ARFrame's clock).
    ///   - now: the same clock, read when the overlay for that frame is
    ///     published. The gap between them is the part of end-to-end
    ///     latency this app is responsible for.
    public mutating func note(cameraTimestamp: TimeInterval, publishedAt now: TimeInterval) {
        pipelineTicks.append(now)
        if pipelineTicks.count > Self.window { pipelineTicks.removeFirst() }
        let latency = (now - cameraTimestamp) * 1000
        // Negative or absurd gaps mean the two timestamps came from
        // different clocks; publishing a nonsense number is worse than
        // publishing none, because someone will quote it.
        if latency >= 0, latency < 10_000 {
            latencies.append(latency)
            if latencies.count > Self.window { latencies.removeFirst() }
        }
    }

    /// How often the PERCEPTION PIPELINE produces a result, in hertz.
    ///
    /// Deliberately not called "fps". It was, and that was a mistake worth
    /// recording: read from `/state.json` it looked like a catastrophic
    /// miss against MVP item 6's ">= 30 FPS camera feed" — 2.9 against 30 —
    /// when the camera was in fact running normally and the pipeline was
    /// sampling roughly one ARKit frame in sixteen, by design. A number
    /// that invites that misreading is the same defect as printing a raw
    /// enum case at a user; the fix is the name, not a footnote.
    public var pipelineHertz: Double? {
        guard pipelineTicks.count >= 2, let first = pipelineTicks.first,
              let last = pipelineTicks.last, last > first else { return nil }
        return Double(pipelineTicks.count - 1) / (last - first)
    }

    /// The CAMERA's frame rate — the number MVP item 6 names. Derived from
    /// ARKit's own cumulative frame counter rather than from anything the
    /// app schedules, so throttling the pipeline cannot flatter it.
    public var cameraFramesPerSecond: Double? { cameraRate }

    /// Feed ARKit's cumulative delegate frame count.
    public mutating func noteCameraFrames(seen: Int, at now: TimeInterval) {
        defer { lastCameraSample = CameraSample(framesSeen: seen, at: now) }
        guard let previous = lastCameraSample else { return }
        let elapsed = now - previous.at
        let frames = seen - previous.framesSeen
        // A counter that went backwards means the session restarted; a
        // sample taken too close to the last one is mostly quantisation.
        guard elapsed >= 0.5, frames >= 0 else { return }
        cameraRate = Double(frames) / elapsed
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
        pipelineTicks.removeAll()
        latencies.removeAll()
        lastCameraSample = nil
        cameraRate = nil
    }
}
