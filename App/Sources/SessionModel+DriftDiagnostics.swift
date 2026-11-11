//
//  SessionModel+DriftDiagnostics.swift
//  CueSync AR
//
//  Camera-pose drift on a parked device: the measurements that show it and
//  the switch for the fix (ARExperience.ParkedHoldBox).
//
//  Debug-only: these fields reach `/state.json` under "pose" and nowhere
//  else. They exist because the 2026-11-10 iPad run could see the balls'
//  table coordinates creep but not WHY; with the raw camera pose, ARKit's
//  tracking and mapping state, the IMU and a ball's world position side by
//  side, a drift run says which of them moved.
//  See docs/plans/2026-11-11-calibration-drift-plan.md.
//

import ARExperience
import CueSyncCore
import Foundation
import TableSpace

extension SessionModel {

    /// The `pose` block of `/state.json`.
    func driftMirrorState() -> [String: Any] {
        var state: [String: Any] = ["trackingState": String(describing: trackingCondition)]
        guard let coordinator = arCoordinator else { return state }
        let reading = coordinator.parkedHold.reading()
        if let mapping = coordinator.parkedHold.worldMappingStatus { state["worldMapping"] = mapping }
        func r(_ v: Double, _ digits: Double = 1000) -> Double { (v * digits).rounded() / digits }
        if let raw = reading.rawPose {
            let t = raw.translation
            // Camera forward is -Z: heading and pitch of the look direction.
            let forward = raw.transformDirection(Vec3(0, 0, -1))
            state["cameraRaw"] = [
                "x": r(t.x), "y": r(t.y), "z": r(t.z),
                "yawDeg": r(atan2(-forward.x, -forward.z) * 180 / .pi, 100),
                "pitchDeg": r(asin(max(-1, min(1, forward.y))) * 180 / .pi, 100)
            ]
        }
        var hold: [String: Any] = [
            "enabled": reading.enabled, "armed": reading.armed, "holding": reading.holding,
            "still": reading.still, "imuLive": reading.imuLive,
            "correctionMm": r(reading.correction.translation * 1000, 10),
            "correctionDeg": r(reading.correction.rotationDegrees, 1000)
        ]
        if let rate = reading.rotationRate { hold["rotRate"] = r(rate, 10000) }
        if let accel = reading.userAcceleration { hold["userAccel"] = r(accel, 10000) }
        if let drift = reading.drift {
            hold["driftMm"] = r(drift.translation * 1000, 10)
            hold["driftDeg"] = r(drift.rotationDegrees, 1000)
        }
        state["parkedHold"] = hold
        if let anchor = coordinator.currentTableAnchorTransform {
            let t = anchor.translation
            state["tableAnchorRaw"] = ["x": r(t.x), "y": r(t.y), "z": r(t.z)]
        }
        // Stationary-ball reference: every ball's position in the corrected
        // world and in ARKit's raw world. On a still table the corrected
        // value should not move; the raw one shows what ARKit's frame did.
        if let calibration = tableCalibration, let balls = tableState?.balls {
            let hold = coordinator.parkedHold.current
            state["ballsWorld"] = balls.map { ball -> [String: Any] in
                let world = calibration.tableToWorld(ball.position)
                let raw = hold.toARKit(world)
                // rawValue: JSONSerialization aborts the app on a BallID.
                return ["id": ball.id.rawValue, "x": r(world.x), "z": r(world.z),
                        "rawX": r(raw.x), "rawZ": r(raw.z)]
            }
        }
        if placement.sizeFromBalls == nil, !placement.sizeCheckRays.isEmpty {
            noteSizeFromBalls(rays: placement.sizeCheckRays)
        }
        if let verdict = placement.sizeFromBalls {
            state["sizeFromBalls"] = verdict.summary
        }
        return state
    }

    /// `/cmd?action=parkedHold&v=0|1`: the A/B switch for the pose hold.
    func setParkedHoldEnabled(_ on: Bool) {
        arCoordinator?.parkedHold.setEnabled(on)
        Self.log.notice("parked pose hold \(on ? "ON" : "OFF", privacy: .public) (remote)")
        showRemoteFeedback(on ? "Parked pose hold on" : "Parked pose hold off")
    }

    /// Measure the table size with the balls as a ruler, after a pocket
    /// calibration: the pocket rays give the cloth depth each standard size
    /// implies; the balls' apparent size gives the real depth.
    func noteSizeFromBalls(rays: [(pocket: PocketID, ray: TapRay)]) {
        placement.sizeCheckRays = rays
        guard let plane = estimateClothPlane(), let camera = rays.first?.ray.origin else {
            placement.sizeFromBalls = nil
            return
        }
        let solved = TableSize.standardSizes.compactMap { size -> (size: TableSize, height: Double)? in
            (try? PocketCalibration.solveHeight(rays: rays, size: size)).map { (size, $0.height) }
        }
        placement.sizeFromBalls = TableSizeFromBalls.classify(
            cameraHeight: camera.y, ballClothHeight: plane.height,
            ballSpread: plane.spread, solvedHeights: solved)
        if let verdict = placement.sizeFromBalls {
            Self.log.notice("table size: \(verdict.summary, privacy: .public)")
        }
    }
}
