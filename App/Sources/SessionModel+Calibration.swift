//
//  SessionModel+Calibration.swift
//  CueSync AR
//
//  M3-02: the calibration flow as the app drives it — enter/cancel, corner
//  taps and their mid-calibration rebasing against the shared cluster
//  anchor, lock, persist, restore — plus the T1.2 relocalization stopwatch
//  that restore reads. The stored state it mutates (`calibration`,
//  `pendingCorners`, `calibrationVisible`, `cornerAnchorBase`,
//  `relocalizationStartedAt`, `relocalizationSeconds`) stays in
//  SessionModel.swift, because `@Observable` tracks only the class body;
//  this file is that state's only writer. Split out of SessionModel.swift
//  for SwiftLint's file_length limit.
//

import CueSyncCore
import Foundation
import TableSpace

extension SessionModel {
    func beginCalibration() {
        if isRecording {
            // A new calibration would orphan the bundle's calibration.json:
            // close the recording as it stands (the user sees the save line).
            Task { await stopRecording(reason: .user) }
        }
        stopLiveTracking() // recalibration invalidates the pipeline's plane
        // Abandon the saved venue too: re-entering calibration means the
        // stored one is wrong (or the table moved). Prevents a stale bad
        // lock from relocalizing back over the fresh flow on next launch.
        CalibrationStore.clear()
        // Manual recalibration abandons any pending relocalization — stop
        // the stopwatch so a later restore can't misreport.
        relocalizationStartedAt = nil
        pendingCorners = []
        cornerAnchorBase = nil
        calibration.handle(.resetRequested)
        // Re-pins of a known table snap to its saved spec, not just the
        // generic standards (a shallow-angle tap set once locked an 8 ft
        // table as 7 ft — the spec makes repeat calibrations agree).
        // An explicit Settings override wins over the remembered spec.
        calibration.preferredSize = settings.tableSize.override ?? CalibrationStore.loadTableSpec()
        calibrationVisible = true
    }

    /// Live measured size while the user adjusts corners — shown in the
    /// calibration HUD BEFORE lock so a bad tap is visible immediately.
    var calibrationSizePreview: String? {
        guard case .adjusting(let corners) = calibration.state,
              let preview = try? TableCalibration.fromCorners(
                corners, preferredSize: calibration.preferredSize) else {
            return nil
        }
        let comparison = preview.standardSizeComparison
        return String(format: "%.2f × %.2f m — %@",
                      preview.measuredWidth ?? 0,
                      preview.measuredHeight ?? 0,
                      comparison.summary)
    }

    func cancelCalibration() {
        calibrationVisible = false
    }

    func calibrationPlaneDetected() {
        calibration.handle(.planeDetected)
    }

    /// Add one tapped corner; proposes the (perimeter-ordered) rectangle to
    /// the controller once all four are down.
    func placeCorner(_ world: Vec3, planeNormal: Vec3) {
        guard case .planeFound = calibration.state, pendingCorners.count < 4 else { return }
        pendingCorners.append(world)
        if pendingCorners.count == 4 {
            let ordered = CornerOrdering.orderedAroundCentroid(pendingCorners,
                                                               planeNormal: planeNormal)
            calibration.handle(.cornersProposed(ordered))
        }
    }

    /// Throw away tapped/proposed corners and start corner placement over
    /// (stays in the flow; the AR layer re-reports the plane on next tick).
    func restartCorners() {
        pendingCorners = []
        cornerAnchorBase = nil
        calibration.handle(.resetRequested)
    }

    // MARK: Corner anchor rebasing (mid-calibration drift)

    func setCornerAnchorBase(_ position: Vec3) {
        cornerAnchorBase = position
    }

    func rebaseCorners(clusterAnchorAt current: Vec3) {
        guard let base = cornerAnchorBase else { return }
        let delta = current - base
        guard delta.length > 1e-6 else { return }
        cornerAnchorBase = current
        if !pendingCorners.isEmpty {
            pendingCorners = pendingCorners.map { $0 + delta }
        }
        if case let .adjusting(corners) = calibration.state {
            for (index, corner) in corners.enumerated() {
                calibration.handle(.cornerMoved(index: index, to: corner + delta))
            }
        }
    }

    func moveCorner(index: Int, to world: Vec3) {
        calibration.handle(.cornerMoved(index: index, to: world))
    }

    /// Ask the controller to lock. On success the overlay dismisses; the
    /// caller (AR layer) then anchors + persists via `persistCalibration`.
    func requestCalibrationLock() -> Bool {
        calibration.handle(.lockRequested)
        guard calibration.isLocked else { return false }
        calibrationVisible = false
        // T1.2 measurement truth: surface how far the measured field sits
        // from the nearest standard size the moment it locks — a big delta
        // means mis-tapped corners (outer rail instead of cushion nose).
        if let locked = tableCalibration {
            let comparison = locked.standardSizeComparison
            let field = locked.size.playField
            showTapFeedback(String(format: "Locked %.2f × %.2f m — %@",
                                   field.width, field.height, comparison.summary))
            Self.log.notice("calibration locked: \(comparison.summary, privacy: .public) (max delta \(Int(comparison.maxDelta * 1000)) mm)")
            // Remember this table's size as the user's spec so future
            // re-pins snap to it (survives venue clears).
            CalibrationStore.saveTableSpec(locked.size)
        }
        return true
    }

    /// Persist a locked calibration relative to its world anchor so a
    /// returning visit relocalizes straight to Ready.
    func persistCalibration(_ locked: TableCalibration, anchorTransform: Transform3D) {
        lockAnchorTransform = anchorTransform
        CalibrationStore.save(AnchoredCalibration(calibration: locked,
                                                  anchorTransform: anchorTransform))
    }

    /// A saved venue relocalized — jump to locked (unless the user already
    /// locked a fresh calibration this session; the controller ignores it).
    func restoreCalibration(_ restored: TableCalibration, anchorTransform: Transform3D) {
        let wasLocked = calibration.isLocked
        calibration.handle(.restored(restored))
        if !wasLocked, calibration.isLocked { lockAnchorTransform = anchorTransform }
        // T1.2 relocalization timing: verified bar is locked within 15 s of
        // seeing the table; the mirror surfaces the measured number.
        if !wasLocked, calibration.isLocked, let started = relocalizationStartedAt {
            let seconds = Date().timeIntervalSince(started)
            relocalizationSeconds = seconds
            relocalizationStartedAt = nil
            showTapFeedback(String(format: "Table restored in %.1f s", seconds))
            Self.log.notice("relocalized in \(String(format: "%.2f", seconds), privacy: .public) s")
        }
    }

    // MARK: T1.2 relocalization instrumentation

    /// The AR layer calls this the moment it starts a session with a saved
    /// world map, starting the relocalization stopwatch.
    func markRelocalizationStart() {
        relocalizationStartedAt = Date()
        relocalizationSeconds = nil
    }

    /// The 15 s relocalization deadline passed. Log it but KEEP the
    /// stopwatch running: ARKit retains the loaded world map across the
    /// fallback reconfigure and often relocalizes late (~2 min observed on
    /// the black-cloth table) — that late number is exactly the
    /// measurement T1.2 exists to capture.
    func markRelocalizationTimeout() {
        guard let started = relocalizationStartedAt else { return }
        Self.log.notice("relocalization deadline (15 s) passed after \(Int(Date().timeIntervalSince(started))) s — plane detection reenabled, stopwatch still running")
    }
}
