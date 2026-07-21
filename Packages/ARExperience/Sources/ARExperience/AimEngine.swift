//
//  AimEngine.swift
//  ARExperience
//
//  Task M3-03: derive the player's AimRay from the device pose. Pure math on
//  Transform3D — no ARKit import — so the full aiming model is unit-tested.
//
//  MVP aiming model ("sight over the ball"): intersect the camera's view ray
//  with the table plane to get the look point; the aim direction runs from
//  the cue ball toward that look point. When the player looks at (or behind)
//  the cue ball itself, fall back to the camera's forward direction projected
//  onto the plane, so the line never jumps erratically near the ball.
//

import CueSyncCore
import Foundation
import TableSpace

public struct AimEngine: Sendable {
    /// Look points closer to the cue ball than this (m) use the fallback.
    public var degenerateRadius: Double

    public init(degenerateRadius: Double = 0.15) {
        self.degenerateRadius = degenerateRadius
    }

    /// - Parameters:
    ///   - cameraTransform: camera-to-world pose (ARKit convention: the
    ///     camera looks along its −z axis).
    ///   - cueBall: current cue-ball position in table space.
    ///   - calibration: the locked table calibration.
    /// - Returns: the aim ray, or nil when no stable direction exists
    ///   (e.g. camera parallel to the plane with a degenerate look point).
    public func aimRay(cameraTransform: Transform3D,
                       cueBall: Vec2,
                       calibration: TableCalibration) -> AimRay? {
        let cameraPosition = cameraTransform.translation
        let forward = cameraTransform.axis(2) * -1 // -z column

        if let lookPoint = calibration.intersect(rayOrigin: cameraPosition,
                                                 rayDirection: forward) {
            let toLook = lookPoint - cueBall
            if toLook.length >= degenerateRadius {
                return AimRay(origin: cueBall, direction: toLook.normalized)
            }
        }

        // Fallback: camera forward projected onto the table plane.
        let planar = Vec2(forward.dot(calibration.xAxis),
                          forward.dot(calibration.yAxis))
        guard planar.length > 1e-6 else { return nil }
        return AimRay(origin: cueBall, direction: planar.normalized)
    }
}
