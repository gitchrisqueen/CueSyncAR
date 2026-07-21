//
//  CornerOrdering.swift
//  TableSpace
//
//  Orders user-placed rail corners into the perimeter order that
//  TableCalibration.fromCorners requires (consecutive rectangle neighbors,
//  either winding). Users tap corners in arbitrary order; this makes the
//  order irrelevant. Pure math — Linux-tested.
//

import CueSyncCore
import Foundation

public enum CornerOrdering {
    /// Sort exactly four world-space points into perimeter order around
    /// their centroid, by angle in the plane defined by `planeNormal`.
    /// Consecutive points come out as rectangle neighbors, which satisfies
    /// the `TableCalibration.fromCorners` contract (c0→c1 and c3→c2 are one
    /// pair of opposite edges) for any convex quadrilateral.
    /// Inputs with a count other than 4 are returned unchanged.
    public static func orderedAroundCentroid(_ corners: [Vec3],
                                             planeNormal: Vec3) -> [Vec3] {
        guard corners.count == 4 else { return corners }
        let normal = planeNormal.normalized
        // In-plane orthonormal basis (u, v); seed axis picked to avoid
        // near-parallel degeneracy with the normal.
        let seed = abs(normal.x) < 0.9 ? Vec3(1, 0, 0) : Vec3(0, 1, 0)
        let u = seed.cross(normal).normalized
        let v = normal.cross(u)
        let centroid = (corners[0] + corners[1] + corners[2] + corners[3]) * 0.25
        return corners.sorted { a, b in
            let pa = a - centroid
            let pb = b - centroid
            return Foundation.atan2(pa.dot(v), pa.dot(u))
                < Foundation.atan2(pb.dot(v), pb.dot(u))
        }
    }
}
