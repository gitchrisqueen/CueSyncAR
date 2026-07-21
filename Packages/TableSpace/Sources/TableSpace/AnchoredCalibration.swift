//
//  AnchoredCalibration.swift
//  TableSpace
//
//  A TableCalibration expressed relative to a world anchor's transform, so
//  it survives across AR sessions: serialize this next to the world map;
//  after relocalization the anchor comes back with a (possibly different)
//  world transform and `worldCalibration(anchorTransform:)` rebuilds the
//  calibration in the new session's world coordinates. Pure math —
//  Linux-tested; ARKit types never appear here.
//

import CueSyncCore
import Foundation

public struct AnchoredCalibration: Sendable, Equatable, Codable {
    /// Table-space origin (field center) in anchor-local coordinates.
    public var localOrigin: Vec3
    /// Table-space axes in anchor-local coordinates (unit vectors).
    public var localXAxis: Vec3
    public var localYAxis: Vec3
    public var size: TableSize

    /// Express `calibration` (world space) relative to the rigid transform
    /// of the anchor it was saved against.
    public init(calibration: TableCalibration, anchorTransform: Transform3D) {
        let inverse = Self.invertRigid(anchorTransform)
        localOrigin = inverse.transformPoint(calibration.origin)
        localXAxis = inverse.transformDirection(calibration.xAxis)
        localYAxis = inverse.transformDirection(calibration.yAxis)
        size = calibration.size
    }

    /// Rebuild the world-space calibration from the anchor's transform in
    /// the *current* session (post-relocalization).
    public func worldCalibration(anchorTransform: Transform3D) -> TableCalibration {
        TableCalibration(origin: anchorTransform.transformPoint(localOrigin),
                         xAxis: anchorTransform.transformDirection(localXAxis),
                         yAxis: anchorTransform.transformDirection(localYAxis),
                         size: size)
    }

    /// Inverse of a rigid (rotation + translation) transform: Rᵀ, -Rᵀt.
    /// Not valid for transforms with scale or shear — anchor transforms are
    /// rigid by ARKit's contract.
    static func invertRigid(_ transform: Transform3D) -> Transform3D {
        let a0 = transform.axis(0)
        let a1 = transform.axis(1)
        let a2 = transform.axis(2)
        let t = transform.translation
        return Transform3D(columns: [
            SIMD4(a0.x, a1.x, a2.x, 0),
            SIMD4(a0.y, a1.y, a2.y, 0),
            SIMD4(a0.z, a1.z, a2.z, 0),
            SIMD4(-t.dot(a0), -t.dot(a1), -t.dot(a2), 1)
        ])
    }
}
