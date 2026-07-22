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
        raycastToTablePlane(imagePoint: imagePoint, frame: frame, planeHeightOffset: 0)
    }

    /// Raycast against a plane LIFTED `planeHeightOffset` above the cloth,
    /// with the hit dropped back to cloth level. Passing the ball radius and
    /// the detection box CENTER locates the ball by its sphere center — the
    /// geometrically correct, view-independent method. The box FOOT point is
    /// biased: boxes include the contact shadow, so the bottom edge
    /// unprojects short of the ball (observed as rings offset toward the
    /// camera, with the offset direction changing as the device moves).
    public func raycastToTablePlane(imagePoint: Vec2, frame: CapturedFrame,
                                    planeHeightOffset: Double) -> Vec3? {
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
        // Grazing gate: |denominator| is sin(angle between ray and plane).
        // Below ~7 degrees a pixel of detector noise slides the intersection
        // meters along the cloth (observed as phantom/juddering positions
        // when the device rests on the rail) — treat as "cannot see cloth".
        guard abs(denominator) > Self.minimumIncidenceSine else { return nil }
        let liftedOrigin = calibration.origin + normal * planeHeightOffset
        let t = (liftedOrigin - origin).dot(normal) / denominator
        guard t > 0 else { return nil }
        // Drop the lifted-plane hit straight down to the cloth.
        return origin + direction * t - normal * planeHeightOffset
    }

    /// sin(7°) — rays flatter than this against the table are rejected.
    static let minimumIncidenceSine = 0.12

    /// Forward projection (world → normalized image point), the inverse of
    /// `raycastToTablePlane`'s unprojection. Nil when the frame has no
    /// intrinsics or the point is behind the camera. Used to decide whether
    /// a tracked ball SHOULD be visible in the current frame (visibility-
    /// gated track misses: an out-of-view ball must not decay).
    public func projectToImage(worldPoint: Vec3, frame: CapturedFrame) -> Vec2? {
        guard let k = frame.intrinsics else { return nil }
        // Rigid inverse applied inline: camera coords are the offset from
        // the camera origin projected onto the camera's basis vectors.
        let transform = frame.cameraTransform
        let offset = worldPoint - transform.translation
        let pc = Vec3(offset.dot(transform.axis(0)),
                      offset.dot(transform.axis(1)),
                      offset.dot(transform.axis(2)))
        guard pc.z < -1e-6 else { return nil } // camera looks along -z
        let xn = pc.x / -pc.z
        let yn = pc.y / -pc.z
        let px = k.principalX + k.focalX * xn
        let py = k.principalY - k.focalY * yn
        return Vec2(px / k.imageWidth, py / k.imageHeight)
    }
}
