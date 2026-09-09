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
            // A field that locks as .custom is one the snap refused, which
            // means it is genuinely not a standard table OR the corners
            // were tapped somewhere other than the cushion nose. The user
            // is the only one who can tell those apart, so say so instead
            // of silently choosing — the size decides where every pocket
            // and cushion is drawn.
            var line = String(format: "Locked %.2f × %.2f m — %@",
                              field.width, field.height, comparison.summary)
            if case .custom = locked.size {
                line += " — using your measurement. Re-tap if the corners "
                    + "weren't on the cushion noses."
            }
            showTapFeedback(line)
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

// MARK: - Remote calibration correction (mirror)

extension SessionModel {
    /// Re-measure the locked table as `size`, keeping its origin and axes.
    ///
    /// Corners tapped inside the cushion noses lock a field that is short,
    /// which moves every pocket inboard and shrinks the playing-surface
    /// envelope the tracker gates against — measured on the owner's table
    /// at 2.175 × 1.090 m against an 8-ft field of 2.34 × 1.17, so 8 cm of
    /// pocket error at each end. This corrects that without asking anyone
    /// to re-tap anything.
    ///
    /// The pipeline is restarted because the envelope is baked into its
    /// `PlayingSurfaceGate` at construction.
    @discardableResult
    func resizeCalibration(to size: TableSize) -> Bool {
        guard calibration.isLocked else {
            showTapFeedback("Nothing to resize — the table isn't calibrated")
            return false
        }
        calibration.handle(.resized(size))
        guard let updated = tableCalibration else { return false }
        let field = updated.size.playField
        if let anchorTransform = lockAnchorTransform {
            persistCalibration(updated, anchorTransform: anchorTransform)
        }
        CalibrationStore.saveTableSpec(updated.size)
        restartPipelineForCalibrationChange()
        let line = String(format: "Table re-measured %.3f × %.3f m", field.width, field.height)
        showTapFeedback(line + " (remote)")
        Self.log.notice("calibration resized: \(line, privacy: .public)")
        return true
    }

    /// Move one locked corner by `delta` metres in TABLE space, then lock
    /// again — the remote equivalent of dragging a corner handle.
    ///
    /// Corner order matches `TableCalibration.fromCorners`: 0 top-left,
    /// 1 top-right, 2 bottom-right, 3 bottom-left, in table axes.
    @discardableResult
    func nudgeLockedCorner(index: Int, by delta: Vec2) -> Bool {
        guard let current = tableCalibration, calibration.isLocked else {
            showTapFeedback("Nothing to nudge — the table isn't calibrated")
            return false
        }
        var corners = current.worldCorners
        guard corners.indices.contains(index) else { return false }
        corners[index] = corners[index]
            + current.xAxis * delta.x + current.yAxis * delta.y
        calibration.handle(.reopened)
        calibration.handle(.cornerMoved(index: index, to: corners[index]))
        guard requestCalibrationLock(), let updated = tableCalibration else {
            // Put the old rectangle back rather than leaving the app
            // half-calibrated with the overlay open.
            calibration.handle(.resetRequested)
            calibration.handle(.restored(current))
            showTapFeedback("Corner nudge refused: \(calibration.lastError.map(String.init(describing:)) ?? "lock failed")")
            return false
        }
        if let anchorTransform = lockAnchorTransform {
            persistCalibration(updated, anchorTransform: anchorTransform)
        }
        restartPipelineForCalibrationChange()
        let field = updated.size.playField
        showTapFeedback(String(format: "Corner %d nudged — field %.3f × %.3f m (remote)",
                               index, field.width, field.height))
        return true
    }

    /// The playing-surface envelope is fixed when the pipeline is built, so
    /// a calibration change only takes effect after a restart.
    private func restartPipelineForCalibrationChange() {
        guard isLiveTracking else { return }
        stopLiveTracking()
        startLiveTrackingIfReady()
    }
}

// MARK: - Remote calibration from the mirror

extension SessionModel {
    /// Run the calibration flow from a browser: place the four corners by
    /// screen point, exactly where a finger would put them.
    ///
    /// This exists because a relaunch does not always relocalize the saved
    /// table, and the only alternative was to ask the owner to walk over
    /// and tap four corners every time — for work that is otherwise driven
    /// entirely from the mirror. The points are read off `/frame.jpg`,
    /// which is the same camera image the raycast resolves against, so a
    /// corner can be placed on a cushion nose more precisely than by hand.
    ///
    /// `point` is in VIEW points, the same space `/frame.jpg` covers at
    /// `displayScale` pixels per point.
    /// `planeHeight` is a world Y for the cloth, used when ARKit has no
    /// plane of its own to raycast against.
    ///
    /// A device on a tripod gives ARKit no parallax, so it can sit with the
    /// table filling the frame and never detect a plane — the exact setup
    /// this remote path exists for. Supplying the height turns the raycast
    /// into pure geometry against a known plane, which is all the corner
    /// placement needs. The caller does not have to know the right height
    /// in advance: the field size that comes back scales linearly with the
    /// camera's distance to the plane, so two placements at different
    /// heights determine it exactly.
    @discardableResult
    func placeCornerRemotely(at point: CGPoint, planeHeight: Double? = nil) -> Bool {
        guard let coordinator = arCoordinator else {
            showTapFeedback("No AR session to place a corner in")
            return false
        }
        guard !calibration.isLocked else {
            showTapFeedback("Already calibrated — cancel first (remote)")
            return false
        }
        // A successful raycast IS a found plane.
        //
        // ARKit's plane DETECTION needs parallax, and a device on a tripod
        // never provides any — so `searchingPlane` can persist forever with
        // the table filling the frame, which is exactly the setup this
        // remote path exists for. The estimated-plane raycast works in that
        // state, so the raycast is tried first and the state machine is
        // told what the geometry already proved. The hand flow keeps its
        // stricter gate: a person holding the device can simply move it,
        // and the "hold still" advice is right for them.
        guard let world = coordinator.raycastHorizontalPlane(
            screenPoint: point, fallbackPlaneHeight: planeHeight) else {
            showTapFeedback("Corner missed the table plane at \(Int(point.x)), \(Int(point.y)) (remote)")
            return false
        }
        if case .searchingPlane = calibration.state { calibrationPlaneDetected() }
        guard case .planeFound = calibration.state else {
            showTapFeedback("Not ready for corners — start calibration first (remote)")
            return false
        }
        if pendingCorners.isEmpty {
            coordinator.placeCalibrationAnchor(at: world)
            setCornerAnchorBase(world)
        }
        placeCorner(world, planeNormal: coordinator.horizontalPlaneNormal())
        Self.log.info("remote corner \(self.pendingCorners.count) at (\(Int(point.x)), \(Int(point.y)))")
        return true
    }
}

extension SessionModel {
    /// Calibrate from the ONE end rail the camera can actually see.
    ///
    /// `a` and `b` are the two corners of a short rail in view points and
    /// `towards` is any point on the cloth further down the table. The
    /// plane height is solved rather than supplied: unprojecting the rail
    /// at two trial heights gives a line (everything scales linearly with
    /// the camera's distance to the plane), and the height at which the
    /// rail measures the table's own short dimension is the right one.
    ///
    /// Needed because a device parked beside a table frequently cannot see
    /// the whole thing — on the owner's iPad the right end is outside the
    /// frame, so two corners cannot be tapped at any height and every
    /// calibration from there came out short.
    @discardableResult
    func calibrateFromEndRail(a: CGPoint, b: CGPoint, towards: CGPoint,
                              size: TableSize) -> Bool {
        guard let coordinator = arCoordinator else {
            showTapFeedback("No AR session to calibrate in")
            return false
        }
        func unproject(_ p: CGPoint, _ height: Double) -> Vec3? {
            coordinator.raycastHorizontalPlane(screenPoint: p, fallbackPlaneHeight: height)
        }
        // Two probe heights, one metre apart: rail length is linear in the
        // camera's distance to the plane, so two points fix the line.
        let (h0, h1) = (-1.0, -2.0)
        guard let a0 = unproject(a, h0), let b0 = unproject(b, h0),
              let a1 = unproject(a, h1), let b1 = unproject(b, h1) else {
            showTapFeedback("Could not see the table plane from those points (remote)")
            return false
        }
        let (l0, l1) = (a0.distance(to: b0), a1.distance(to: b1))
        let target = size.playField.height
        guard abs(l1 - l0) > 1e-6 else {
            showTapFeedback("Rail length did not respond to height — degenerate view (remote)")
            return false
        }
        // length(h) = l0 + (l1 - l0) * (h - h0)/(h1 - h0); solve for target.
        let height = h0 + (target - l0) * (h1 - h0) / (l1 - l0)
        guard height.isFinite, height < 0 else {
            showTapFeedback(String(format: "Solved an impossible cloth height (%.2f m) — check the rail points", height))
            return false
        }
        guard let av = unproject(a, height), let bv = unproject(b, height),
              let tv = unproject(towards, height) else {
            showTapFeedback("Lost the plane at the solved height (remote)")
            return false
        }
        do {
            let built = try TableCalibration.fromEndRail(av, bv, towards: tv, size: size)
            calibration.handle(.resetRequested)
            calibration.handle(.restored(built))
            CalibrationStore.saveTableSpec(size)
            if let anchorTransform = lockAnchorTransform {
                persistCalibration(built, anchorTransform: anchorTransform)
            }
            restartPipelineForCalibrationChange()
            startLiveTrackingIfReady()
            let field = built.size.playField
            let line = String(format: "Calibrated from one rail: %.3f × %.3f m, cloth at y=%.3f",
                              field.width, field.height, height)
            showTapFeedback(line + " (remote)")
            Self.log.notice("\(line, privacy: .public)")
            return true
        } catch {
            showTapFeedback("End-rail calibration refused: \(error) (remote)")
            return false
        }
    }
}
