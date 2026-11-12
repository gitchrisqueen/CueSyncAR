//
//  CalibrationHealthMonitor.swift
//  PerceptionKit
//
//  Notices that a locked calibration no longer matches the camera's view.
//
//  Observed live on the iPad: the table was locked, then the device was
//  bumped (or the ARKit session reset). The HUD kept saying "Locked /
//  Tracking 1 balls" with no overlay while the log read
//  `detections=17 projected=0 offTable=15`. Every ball was being projected
//  to the wrong place, the playing-surface gate rejected 15 of 17 of them,
//  and the player was told nothing — the owner found it in the logs.
//
//  The signal is already computed every frame (the gate's reject and clamp
//  counts). This turns a run of such frames into one verdict. Pure and
//  deterministic: timestamps come in with the samples, no clock inside, so
//  a recorded session replays to the same verdicts.
//

import Foundation

/// One processed frame's evidence about the calibration.
public struct CalibrationHealthSample: Sendable, Equatable {
    /// Capture time of the frame, in seconds (any monotonic base).
    public var timestamp: TimeInterval
    /// Ball detections that reached the playing-surface gate this frame
    /// (cue sticks and low-confidence boxes excluded).
    public var detections: Int
    /// How many of those the gate admitted (clamped ones included).
    public var admitted: Int
    /// How many the gate rejected as off the table.
    public var offTable: Int
    /// How many were admitted only by being pulled back onto the rail.
    public var clamped: Int

    public init(timestamp: TimeInterval, detections: Int, admitted: Int,
                offTable: Int, clamped: Int) {
        self.timestamp = timestamp
        self.detections = max(0, detections)
        self.admitted = max(0, admitted)
        self.offTable = max(0, offTable)
        self.clamped = max(0, clamped)
    }

    /// Detections that look wrong: rejected, or only salvaged by the rail
    /// clamp. Bounded by `detections` so inconsistent input cannot push a
    /// fraction past 1.
    var suspectCount: Int { min(detections, offTable + clamped) }
}

/// Whether the locked calibration still matches what the camera sees.
public struct CalibrationHealthMonitor: Sendable, Equatable {

    /// Why the calibration is judged stale: which kind of rejection
    /// dominated the window.
    public enum Reason: String, Sendable, Equatable {
        /// Most detections projected outside the cloth.
        case offTable
        /// Most detections projected onto, or just past, the rails.
        case railClamped
    }

    public enum Status: Sendable, Equatable {
        case healthy
        /// Bad evidence is accumulating but has not lasted long enough to
        /// act on. Not shown to the player.
        case suspect
        case stale(Reason)

        public var isStale: Bool {
            if case .stale = self { return true }
            return false
        }

        /// Plain text for logs and the mirror's JSON.
        public var label: String {
            switch self {
            case .healthy: "healthy"
            case .suspect: "suspect"
            case .stale(let reason): "stale:\(reason.rawValue)"
            }
        }
    }

    /// Tunables, named so the tests and the doc comments agree.
    public struct Config: Sendable, Equatable {
        /// Sliding window the rejection fraction is measured over.
        public var window: TimeInterval = 3
        /// A frame with fewer detections than this says nothing about the
        /// calibration — an empty or nearly empty table must never trip it.
        public var minimumDetectionsPerFrame = 3
        /// Mean detections per counted frame needed before the window is
        /// evidence either way.
        public var minimumMeanDetections = 4.0
        /// Fraction of detections rejected or clamped that counts as bad.
        public var staleFraction = 0.6
        /// How long a verdict must hold before the status follows it, in
        /// either direction.
        public var hold: TimeInterval = 2

        public init() {}
    }

    private struct Entry: Equatable {
        var timestamp: TimeInterval
        var detections: Int
        var suspect: Int
        var offTable: Int
    }

    private enum Evidence { case bad, good, none }

    public private(set) var status: Status = .healthy
    public let config: Config

    private var window: [Entry] = []
    /// When the current run of identical evidence began.
    private var evidenceSince: TimeInterval?
    private var evidenceKind: Evidence = .none

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Fraction of detections in the window that were rejected or clamped,
    /// or nil when the window holds no counted frame.
    public var suspectFraction: Double? {
        let total = window.reduce(0) { $0 + $1.detections }
        guard total > 0 else { return nil }
        return Double(window.reduce(0) { $0 + $1.suspect }) / Double(total)
    }

    /// Mean detections per counted frame in the window.
    public var meanDetections: Double? {
        window.isEmpty ? nil : Double(window.reduce(0) { $0 + $1.detections }) / Double(window.count)
    }

    /// The monitor's working as plain strings and numbers, for the debug
    /// mirror's JSON (which aborts on any other type). Fractions are
    /// rounded to 2 places; absent while the window is empty.
    public var mirrorState: [String: Any] {
        var state: [String: Any] = ["windowFrames": window.count]
        if let fraction = suspectFraction { state["suspectFraction"] = (fraction * 100).rounded() / 100 }
        if let mean = meanDetections { state["meanDetections"] = (mean * 10).rounded() / 10 }
        return state
    }

    /// Back to healthy with an empty window — a new lock is a new table.
    public mutating func reset() {
        status = .healthy
        window = []
        evidenceSince = nil
        evidenceKind = .none
    }

    /// Feed one frame. Returns the status after it.
    @discardableResult
    public mutating func ingest(_ sample: CalibrationHealthSample) -> Status {
        // Too few balls to judge: leave everything exactly as it was,
        // including a run of evidence in progress.
        guard sample.detections >= config.minimumDetectionsPerFrame else { return status }
        window.append(Entry(timestamp: sample.timestamp, detections: sample.detections,
                            suspect: sample.suspectCount, offTable: sample.offTable))
        let cutoff = sample.timestamp - config.window
        window.removeAll { $0.timestamp < cutoff }

        let evidence = currentEvidence()
        if evidence != evidenceKind {
            evidenceKind = evidence
            evidenceSince = sample.timestamp
        }
        let held = evidenceSince.map { sample.timestamp - $0 } ?? 0

        switch (status, evidence) {
        case (.healthy, .bad):
            status = held >= config.hold ? .stale(dominantReason()) : .suspect
        case (.suspect, .bad):
            if held >= config.hold { status = .stale(dominantReason()) }
        case (.suspect, .good), (.suspect, .none):
            status = .healthy
        case (.stale, .good):
            if held >= config.hold { status = .healthy }
        case (.stale, .bad):
            status = .stale(dominantReason())
        default:
            break
        }
        return status
    }

    private func currentEvidence() -> Evidence {
        guard let fraction = suspectFraction, let mean = meanDetections,
              mean >= config.minimumMeanDetections else { return .none }
        return fraction >= config.staleFraction ? .bad : .good
    }

    private func dominantReason() -> Reason {
        let off = window.reduce(0) { $0 + $1.offTable }
        let suspect = window.reduce(0) { $0 + $1.suspect }
        return off * 2 >= suspect ? .offTable : .railClamped
    }
}
