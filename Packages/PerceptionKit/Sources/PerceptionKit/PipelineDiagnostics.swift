//
//  PipelineDiagnostics.swift
//  PerceptionKit
//
//  Numbers about what the pipeline did with a frame, and how long each
//  stage took. Nothing here changes behaviour: it exists so a run at the
//  table can answer "which detections were dropped, and where" and "where
//  did the milliseconds go" without a rebuild.
//
//  None of it enters anything SessionReplay compares. `PerceptionOutput`
//  carries it as extra fields, and the replay schema writes explicit keys.
//

import CueSyncCore
import Foundation
import Synchronization

/// Monotonic nanosecond clock for stage timing.
enum StageClock {
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        end >= start ? Double(end - start) / 1_000_000 : 0
    }
}

/// Timestamps taken across one processed frame, turned into per-stage
/// milliseconds. `appearance` is averaged over every frame (colour is
/// sampled only every Nth, so this is the amortised cost); `appearanceRun`
/// is recorded only on the frames that did sample.
struct StageTimes {
    var started: UInt64
    var detected: UInt64
    var projected: UInt64
    var tracked: UInt64
    var sampled: UInt64
    var finished: UInt64
    var sampledColour: Bool

    var milliseconds: [(String, Double)] {
        let detect = StageClock.milliseconds(from: started, to: detected)
        let project = StageClock.milliseconds(from: detected, to: projected)
        let track = StageClock.milliseconds(from: projected, to: tracked)
        let appearance = StageClock.milliseconds(from: tracked, to: sampled)
        let total = StageClock.milliseconds(from: started, to: finished)
        var rows: [(String, Double)] = [
            ("detect", detect), ("project", project), ("track", track),
            ("appearance", appearance),
            ("other", Swift.max(0, total - detect - project - track - appearance)),
            ("total", total)
        ]
        if sampledColour { rows.append(("appearanceRun", appearance)) }
        return rows
    }
}

/// One raw detector output as the diagnostics report it: numbers and a
/// label, nothing else.
public struct RawDetectionEntry: Sendable, Equatable {
    public var label: String
    /// Detector confidence rounded to 2 decimals.
    public var confidence: Double
    /// Where the box centre lands on the table, in whole centimetres, when
    /// it projects at all. Computed for EVERY detection (stick and
    /// sub-floor ones too), because "is there a detection near this spot"
    /// is the question this list exists to answer.
    public var tableCentimetres: (x: Int, y: Int)?

    public init(label: String, confidence: Double, tableCentimetres: (x: Int, y: Int)? = nil) {
        self.label = label
        self.confidence = confidence
        self.tableCentimetres = tableCentimetres
    }

    public static func == (lhs: RawDetectionEntry, rhs: RawDetectionEntry) -> Bool {
        lhs.label == rhs.label && lhs.confidence == rhs.confidence
            && lhs.tableCentimetres?.x == rhs.tableCentimetres?.x
            && lhs.tableCentimetres?.y == rhs.tableCentimetres?.y
    }
}

/// What happened to this frame's raw detections on the way to the tracker.
///
/// The identity that holds every frame, and that a test pins:
/// `rawCount == stickCount + belowFloor + noRay + rejected + projected`.
public struct DetectionCounts: Sendable, Equatable {
    /// Everything the detector returned.
    public var rawCount = 0
    /// Labelled as the cue stick, so never a ball.
    public var stickCount = 0
    /// Ball detections under the confidence floor.
    public var belowFloor = 0
    /// The `belowFloor` count split by detector label, so a cue ball
    /// (`white-ball`) dropping under the floor is visible on its own.
    public var belowFloorByLabel: [String: Int] = [:]
    /// Highest confidence among the `belowFloor` ones; nil when none.
    public var maxSubFloorConfidence: Double?
    /// At or over the floor but the ray never reached the table plane.
    public var noRay = 0
    /// Projected, but outside the playing-surface admit band.
    public var rejected = 0
    /// Admitted: handed to the tracker as observations.
    public var projected = 0
    /// The floor that was in force for this frame.
    public var confidenceFloor: Double = 0
    /// Every raw detection, strongest first (confidence desc, label asc,
    /// detector order asc). Not capped.
    public var rawLabelsAll: [RawDetectionEntry] = []

    public init() {}
}

/// Everything the diagnostics know after one processed frame.
public struct PipelineDiagnostics: Sendable, Equatable {
    public var detections = DetectionCounts()
    /// The id the tracker will hand the next new track. After a clean run
    /// on N balls it equals N; more means tracks were spawned and lost.
    public var nextTrackID = 0
    /// Tracks seen but not yet confirmed.
    public var tentativeCount = 0
    /// Frames this pipeline has processed.
    public var frames = 0
    /// Rolling mean wall time per stage, milliseconds, over the last
    /// `StageWindow.capacity` frames. Keys: `detect`, `project`, `track`,
    /// `appearance` (averaged over all frames), `appearanceRun` (over the
    /// frames that actually sampled colour), `other`, `total`.
    public var stageMs: [String: Double] = [:]

    public init() {}
}

/// Rolling means over a fixed window of recent samples, by stage name.
public struct RollingMeans: Sendable, Equatable {
    public let capacity: Int
    private var samples: [String: [Double]] = [:]

    public init(capacity: Int = 40) {
        self.capacity = Swift.max(1, capacity)
    }

    public mutating func record(_ name: String, _ milliseconds: Double) {
        var window = samples[name, default: []]
        window.append(milliseconds)
        if window.count > capacity { window.removeFirst(window.count - capacity) }
        samples[name] = window
    }

    /// Mean per stage, rounded to 0.01 ms.
    public var means: [String: Double] {
        samples.compactMapValues { window in
            guard !window.isEmpty else { return nil }
            return (window.reduce(0, +) / Double(window.count) * 100).rounded() / 100
        }
    }
}

/// Live knobs and the latest readings, shared between the app and the
/// pipeline actor.
///
/// One small thread-safe object rather than actor calls, because the app
/// reads it from a synchronous `/state.json` builder and writes it from a
/// synchronous command handler, and the pipeline actor must see a change
/// on its very next frame.
public final class PerceptionControls: Sendable {
    /// The range `/cmd?action=confidenceFloor` accepts.
    public static let confidenceFloorRange: ClosedRange<Double> = 0.05...0.9

    private struct State {
        var confidenceFloor: Double?
        var diagnostics: PipelineDiagnostics?
        var appStages = RollingMeans()
    }

    private let state = Mutex(State())

    public init() {}

    /// The floor the player asked for, or nil to use `PerceptionConfig`'s.
    public var confidenceFloorOverride: Double? {
        state.withLock { $0.confidenceFloor }
    }

    /// Set the floor. Returns false, changing nothing, outside
    /// `confidenceFloorRange` or for a value that is not a number.
    /// Passing nil clears the override.
    @discardableResult
    public func setConfidenceFloor(_ value: Double?) -> Bool {
        if let value, !(value.isFinite && Self.confidenceFloorRange.contains(value)) { return false }
        state.withLock { $0.confidenceFloor = value }
        return true
    }

    /// The newest diagnostics the pipeline published.
    public var latestDiagnostics: PipelineDiagnostics? {
        state.withLock { $0.diagnostics }
    }

    func publish(_ diagnostics: PipelineDiagnostics) {
        state.withLock { $0.diagnostics = diagnostics }
    }

    /// A new pipeline starts from nothing: the readings of the last one
    /// are not evidence about this one.
    public func resetDiagnostics() {
        state.withLock {
            $0.diagnostics = nil
            $0.appStages = RollingMeans()
        }
    }

    /// Record a stage the app times itself, on the main actor, after the
    /// pipeline has handed the frame over.
    public func noteAppStage(_ name: String, milliseconds: Double) {
        state.withLock { $0.appStages.record(name, milliseconds) }
    }

    /// What `/cmd?action=confidenceFloor&v=...` does with its `v`.
    public enum FloorCommandOutcome: Sendable, Equatable {
        case set(Double)
        /// `v=default`: back to `PerceptionConfig`'s floor.
        case cleared
        /// Missing, not a number, or outside `confidenceFloorRange`.
        /// Nothing changed.
        case refused
    }

    /// Parse and apply the command's `v`. The parsing lives here, not in
    /// the app target, so it is covered by this package's tests.
    @discardableResult
    public func applyFloorCommand(_ value: String?) -> FloorCommandOutcome {
        guard let value else { return .refused }
        if value == "default" {
            setConfidenceFloor(nil)
            return .cleared
        }
        guard let number = Double(value), setConfidenceFloor(number) else { return .refused }
        return .set(number)
    }

    /// Only the stages the app times on the main actor: `ranking` (the
    /// re-rank and everything it triggers) and `handoff` (from the pipeline
    /// yielding the output to the ranking finishing, so it includes the
    /// wait for the main actor).
    public var appStageMilliseconds: [String: Double] {
        state.withLock { $0.appStages.means }
    }

    /// Pipeline stages and app stages together.
    public var stageMilliseconds: [String: Double] {
        state.withLock { current in
            (current.diagnostics?.stageMs ?? [:])
                .merging(current.appStages.means) { _, app in app }
        }
    }
}

extension PipelineDiagnostics {
    /// This frame's entries for the `detection` block of `/state.json`.
    ///
    /// Plain strings and numbers only, because the file is built with
    /// `JSONSerialization`: no NaN (it traps), no optionals, no tuples.
    /// `maxSubFloorConf` is left out when nothing was under the floor.
    public var mirrorEntries: [String: Any] {
        let counts = detections
        var entries: [String: Any] = [
            "rawCount": counts.rawCount,
            "stickCount": counts.stickCount,
            "belowFloor": counts.belowFloor,
            "belowFloorByLabel": counts.belowFloorByLabel,
            "noRay": counts.noRay,
            "projected": counts.projected,
            "rejected": counts.rejected,
            "confidenceFloor": counts.confidenceFloor,
            "nextTrackID": nextTrackID,
            "tentativeCount": tentativeCount,
            "rawLabelsAll": counts.rawLabelsAll.map { entry -> [String: Any] in
                var row: [String: Any] = ["label": entry.label, "conf": entry.confidence]
                if let at = entry.tableCentimetres {
                    row["x"] = at.x
                    row["y"] = at.y
                }
                return row
            }
        ]
        if let sub = counts.maxSubFloorConfidence, sub.isFinite {
            entries["maxSubFloorConf"] = (sub * 100).rounded() / 100
        }
        return entries
    }
}
