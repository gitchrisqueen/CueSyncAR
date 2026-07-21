//
//  PlaneGeometryRaycaster.swift
//  PerceptionKit
//
//  Pure-math PlaneRaycasting: unprojects a normalized image point through
//  the frame's pinhole intrinsics into a world ray, then intersects the
//  locked table plane. No ARKit, no main-actor hop — safe to call from the
//  pipeline actor, and fully unit-tested. This is what lets detection
//  results land on the calibrated table without per-point ARView raycasts.
//

import CueSyncCore
import Foundation
import TableSpace

public struct PlaneGeometryRaycaster: PlaneRaycasting {
    private let calibration: TableCalibration

    public init(calibration: TableCalibration) {
        self.calibration = calibration
    }

    /// `imagePoint` is normalized (0...1, top-left origin) in the captured
    /// image's native orientation — the same space detector boxes use.
    /// Returns nil when the frame carries no intrinsics or the ray misses
    /// the plane (parallel or behind the camera).
    public func raycastToTablePlane(imagePoint: Vec2, frame: CapturedFrame) -> Vec3? {
        guard let k = frame.intrinsics else { return nil }
        let px = imagePoint.x * k.imageWidth
        let py = imagePoint.y * k.imageHeight
        // Camera space: +x right, +y up, looking along -z (ARKit
        // convention). Image y grows downward, hence the sign flip.
        let xc = (px - k.principalX) / k.focalX
        let yc = -((py - k.principalY) / k.focalY)
        let directionCamera = Vec3(xc, yc, -1)
        let direction = frame.cameraTransform.transformDirection(directionCamera).normalized
        let origin = frame.cameraTransform.translation

        let normal = calibration.normal
        let denominator = direction.dot(normal)
        guard abs(denominator) > 1e-9 else { return nil }
        let t = (calibration.origin - origin).dot(normal) / denominator
        guard t > 0 else { return nil }
        return origin + direction * t
    }
}
