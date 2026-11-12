//
//  SessionModel+OverlayTiming.swift
//  CueSync AR
//
//  Drawing the overlay when a new table state lands, and timing the path
//  from the camera to the drawn overlay.
//
//  Hooks in SessionModel.swift, each one line replaced for one line:
//  - `ingestTrackingFrame` calls `Self.handToPipeline`, which hands the frame
//    over from a task that does NOT run on the main actor;
//  - the output reader (`statesTask`) is detached for the same reason and
//    calls `Self.noteConsumed(output)` as it receives each output;
//  - the output handler calls `Self.noteArrival(output)` first thing on the
//    main actor, which stamps when the hand-off ended;
//  - `recomputeRankingTimed(after:)` (SessionModel+PerceptionDiagnostics)
//    signals `overlaySignal` when it is done, and ARCameraView draws.
//
//  The arithmetic and the ledger are in ARExperience (`LatencyLedger`), where
//  the package tests cover them; this file is wiring.
//

import ARExperience
import CueSyncCore
import Foundation
import PerceptionKit

extension SessionModel {

    /// "A new table state has landed": ARCameraView's drawing task waits on
    /// this, so the overlay is drawn when the state arrives and not on the
    /// loop's next tick.
    static let overlaySignal = RenderSignal()

    /// Hand a frame to the pipeline and return at once.
    ///
    /// This used to be `Task { await pipeline.ingest(...) }`, which inherits
    /// the main actor: the task could not start until the AR loop had run
    /// the rest of its tick (aim, draw, the mirror's state document), so the
    /// frame sat there for tens of milliseconds before the pipeline even
    /// heard of it. It now starts at once on its own thread. The stamp it
    /// takes is the end of the `ingest` stage.
    nonisolated static func handToPipeline(_ pipeline: PerceptionPipeline, frame: CapturedFrame,
                                           anchor: Transform3D?) {
        Task.detached(priority: .userInitiated) {
            LatencyLedger.shared.noteIngested(captured: frame.timestamp,
                                              at: ProcessInfo.processInfo.systemUptime)
            await pipeline.ingest(frame, tableAnchorTransform: anchor)
        }
    }

    /// The task that reads the pipeline's output stream received an output.
    /// Off the main actor, so `stream` is the hand-over alone and `hop` is
    /// the wait for the main actor.
    nonisolated static func noteConsumed(_ output: PerceptionOutput) {
        LatencyLedger.shared.noteConsumed(captured: output.state.timestamp,
                                          at: ProcessInfo.processInfo.systemUptime)
    }

    /// The pipeline's output reached the main actor. Called first in the
    /// output handler, before any of its work, so `hop` is the wait for the
    /// main actor alone.
    nonisolated static func noteArrival(_ output: PerceptionOutput) {
        LatencyLedger.shared.noteArrived(captured: output.state.timestamp,
                                         produced: output.producedAt,
                                         at: ProcessInfo.processInfo.systemUptime)
    }

    /// What the renderer has done to the scene, copied out by the draw path
    /// for `/state.json`.
    static let overlayStats = OverlayStatsBox()

    /// `health.latency` in `/state.json`: camera to drawn overlay, split into
    /// stages that add up (see `LatencyLedger`), and what the renderer did.
    /// Nil until a frame was drawn or the renderer drew.
    ///
    /// Not the same number as `health.overlayLatencyMs`, which stops when the
    /// pipeline's output reaches the main actor and so cannot see the wait to
    /// be drawn or the draw.
    func latencyMirrorState() -> [String: Any]? {
        guard isLiveTracking else { return nil }
        func tenth(_ value: Double) -> Double { (value * 10).rounded() / 10 }
        var state: [String: Any] = [:]
        if let summary = LatencyLedger.shared.summary {
            state["stageMs"] = summary.meanMs.mapValues(tenth)
            state["medianMs"] = tenth(summary.medianTotalMs)
            state["worstMs"] = tenth(summary.worstTotalMs)
            state["samples"] = summary.samples
            state["superseded"] = summary.superseded
            state["rejected"] = summary.rejected
            state["incomplete"] = summary.incomplete
        }
        if let stats = Self.overlayStats.get(), stats.renders > 0 {
            // Renders that changed nothing are the point of the pool: the
            // gap between `renders` and `redraws` is the draws saved.
            state["overlay"] = [
                "renders": stats.renders, "redraws": stats.redraws,
                "built": stats.built, "moved": stats.moved, "removed": stats.removed,
                "lastBuilt": stats.lastBuilt, "lastMoved": stats.lastMoved,
                "lastKept": stats.lastKept, "lastRemoved": stats.lastRemoved
            ]
        }
        return state.isEmpty ? nil : state
    }
}

/// The renderer's counters, written by the draw path and read by the mirror.
final class OverlayStatsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stats: OverlayRenderStats?

    func set(_ value: OverlayRenderStats) {
        lock.lock(); stats = value; lock.unlock()
    }

    func get() -> OverlayRenderStats? {
        lock.lock(); defer { lock.unlock() }
        return stats
    }
}
