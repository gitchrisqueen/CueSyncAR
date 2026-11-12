//
//  SessionModel+CalibrationHealth.swift
//  CueSync AR
//
//  "Table moved? Re-calibrate": the locked calibration no longer matches
//  the camera's view.
//
//  Seen live on the iPad: the device was bumped after the lock, the HUD kept
//  saying "Tracking 1 balls" with nothing drawn, and the log said
//  `detections=17 projected=0 offTable=15`. The playing-surface gate was
//  rejecting nearly everything and nobody was told. The decision (a sliding
//  window with hysteresis) is `CalibrationHealthMonitor` in PerceptionKit,
//  tested on Linux; this file feeds it, shows the answer and acts on it.
//
//  Storage is in `CalibrationHealthModel` rather than in SessionModel for
//  the reason SessionModel's header gives: lift a concern into its own
//  `@Observable` type and forward to it.
//

import CueSyncCore
import Foundation
import Observation
import os
import PerceptionKit

/// The monitor plus the one observed value the HUD reads. The monitor is
/// `@ObservationIgnored` so only a change of STATUS re-renders a view, not
/// every frame's counts.
@MainActor
@Observable
final class CalibrationHealthModel {
    @ObservationIgnored private var monitor = CalibrationHealthMonitor()
    private(set) var status: CalibrationHealthMonitor.Status = .healthy

    /// Feed one frame. Returns the previous and new status when it changed.
    func ingest(_ sample: CalibrationHealthSample)
        -> (from: CalibrationHealthMonitor.Status, to: CalibrationHealthMonitor.Status)? {
        let before = status
        let after = monitor.ingest(sample)
        guard after != before else { return nil }
        status = after
        return (before, after)
    }

    /// A new lock is a new table: forget the old evidence.
    func reset() {
        monitor.reset()
        if status != .healthy { status = .healthy }
    }

    /// The `calibrationHealth` block of `/state.json`: plain strings and
    /// numbers only, because JSONSerialization aborts on anything else.
    func mirrorState(liveTracking: Bool) -> [String: Any] {
        var state: [String: Any] = [
            "status": liveTracking ? status.label : "inactive",
            "stale": liveTracking && status.isStale
        ]
        if liveTracking {
            state.merge(monitor.mirrorState) { current, _ in current }
        }
        return state
    }
}

extension SessionModel {

    /// The per-output health hook: detection recall (existing) and
    /// calibration fit (new). One call site in the pipeline loop.
    func noteOutputHealth(_ output: PerceptionOutput) {
        noteDetectionHealth(output)
        noteCalibrationHealth(output)
    }

    private func noteCalibrationHealth(_ output: PerceptionOutput) {
        guard let change = calibrationHealth.ingest(output.calibrationHealthSample) else { return }
        let sample = output.calibrationHealthSample
        let from = change.from.label
        let to = change.to.label
        let gate = "detections=\(sample.detections) offTable=\(sample.offTable) railClamped=\(sample.clamped)"
        Self.log.notice("calibration health: \(from, privacy: .public) -> \(to, privacy: .public) (\(gate, privacy: .public))")
    }

    /// True while the app should NOT present guidance as if it were
    /// confident: the shot card and every overlay are held back.
    var calibrationIsStale: Bool {
        isLiveTracking && calibrationHealth.status.isStale
    }

    /// The banner's tap: start the same flow as the table button. It tears
    /// the pipeline down, so the stale verdict goes with it.
    func recalibrateFromBanner() {
        Self.log.notice("calibration health: banner tapped, starting calibration")
        beginCalibration()
    }

    /// The `calibrationHealth` entry of `/state.json`.
    func calibrationHealthMirrorState() -> [String: Any] {
        calibrationHealth.mirrorState(liveTracking: isLiveTracking)
    }
}
