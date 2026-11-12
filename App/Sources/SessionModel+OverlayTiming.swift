//
//  SessionModel+OverlayTiming.swift
//  CueSync AR
//
//  Drawing the overlay when a new table state lands, and timing the path
//  from the camera to the drawn overlay.
//
//  Hooks in SessionModel.swift, each one line replaced for one line:
//  - the pipeline output handler calls `Self.noteArrival(output)` first
//    thing on the main actor, which stamps when the hand-off ended;
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

    /// The pipeline's output reached the main actor. Called first in the
    /// output handler, before any of its work, so `hop` is the wait for the
    /// main actor alone.
    static func noteArrival(_ output: PerceptionOutput) {
        LatencyLedger.shared.noteArrived(captured: output.state.timestamp,
                                         produced: output.producedAt,
                                         at: ProcessInfo.processInfo.systemUptime)
    }

    /// `health.latency` in `/state.json`: camera to drawn overlay, split into
    /// stages that add up (see `LatencyLedger`). Nil until a frame was drawn.
    ///
    /// Not the same number as `health.overlayLatencyMs`, which stops when the
    /// pipeline's output reaches the main actor and so cannot see the wait to
    /// be drawn or the draw.
    func latencyMirrorState() -> [String: Any]? {
        guard isLiveTracking, let summary = LatencyLedger.shared.summary else { return nil }
        func tenth(_ value: Double) -> Double { (value * 10).rounded() / 10 }
        return [
            "stageMs": summary.meanMs.mapValues(tenth),
            "medianMs": tenth(summary.medianTotalMs),
            "worstMs": tenth(summary.worstTotalMs),
            "samples": summary.samples,
            "superseded": summary.superseded,
            "rejected": summary.rejected,
            "incomplete": summary.incomplete
        ]
    }
}
