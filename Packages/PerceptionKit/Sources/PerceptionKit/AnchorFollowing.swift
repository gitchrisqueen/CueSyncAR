//
//  AnchorFollowing.swift
//  PerceptionKit
//
//  B3: the table calibration must live in the SAME world frame as the
//  camera poses it is combined with. ARKit refines the table anchor as its
//  map improves (and re-places it after relocalization); a calibration
//  frozen at lock time then projects detections into a table frame that
//  is offset from the physical cloth by exactly ARKit's refinement. The
//  pipeline therefore re-derives its calibration from the anchor's
//  current transform each frame — which also means the raycaster's plane
//  has to move with it. This seam lets a calibration-backed raycaster be
//  rebuilt against the refreshed calibration; scripted fixtures that map
//  image points to a plane of their own simply don't conform, and the
//  pipeline then keeps its calibration pinned (the pre-B3 behaviour).
//

import CueSyncCore
import Foundation
import TableSpace

/// A `PlaneRaycasting` whose plane is defined by a `TableCalibration` and
/// can be re-expressed against a refreshed one.
public protocol CalibrationFollowingRaycaster: PlaneRaycasting {
    /// The same raycaster, intersecting the plane of `calibration` instead.
    func following(_ calibration: TableCalibration) -> any PlaneRaycasting
}

extension PlaneGeometryRaycaster: CalibrationFollowingRaycaster {
    public func following(_ calibration: TableCalibration) -> any PlaneRaycasting {
        PlaneGeometryRaycaster(calibration: calibration)
    }
}
