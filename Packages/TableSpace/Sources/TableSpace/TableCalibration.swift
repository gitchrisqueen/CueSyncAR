//
//  TableCalibration.swift
//  TableSpace
//
//  Maps between ARKit world space (3D meters) and table space (2D meters on
//  the cloth plane, origin at playing-field center, x along the long axis).
//  Pure math: ARKit supplies the corner points / plane, this package supplies
//  the transforms. Codable so calibrations persist per venue.
//

import CueSyncCore
import Foundation

public enum CalibrationError: Error, Equatable {
    case needFourCorners
    case degenerateCorners
    case unrecognizedTableSize(width: Double, height: Double)
}

public struct TableCalibration: Sendable, Equatable, Codable {
    /// World-space position of the table-space origin (field center).
    public var origin: Vec3
    /// World-space unit vector of the table-space +x axis (long axis).
    public var xAxis: Vec3
    /// World-space unit vector of the table-space +y axis (short axis).
    public var yAxis: Vec3
    public var size: TableSize

    public init(origin: Vec3, xAxis: Vec3, yAxis: Vec3, size: TableSize) {
        self.origin = origin
        self.xAxis = xAxis.normalized
        self.yAxis = yAxis.normalized
        self.size = size
    }

    /// Plane normal (right-handed: x × y).
    public var normal: Vec3 { xAxis.cross(yAxis) }

    // MARK: - Mapping

    /// Project a world point onto the table plane and express it in table space.
    public func worldToTable(_ p: Vec3) -> Vec2 {
        let rel = p - origin
        return Vec2(rel.dot(xAxis), rel.dot(yAxis))
    }

    /// Lift a table-space point back to world space (on the cloth plane).
    public func tableToWorld(_ p: Vec2) -> Vec3 {
        origin + xAxis * p.x + yAxis * p.y
    }

    /// Height of a world point above the table plane (signed, meters).
    public func heightAbovePlane(_ p: Vec3) -> Double {
        (p - origin).dot(normal)
    }

    /// Intersect a world-space ray with the table plane, returning the hit
    /// in table space. Returns nil for rays parallel to (or pointing away
    /// from) the plane — total by construction, never traps.
    public func intersect(rayOrigin: Vec3, rayDirection: Vec3) -> Vec2? {
        let n = normal
        let denom = rayDirection.dot(n)
        guard abs(denom) > 1e-9 else { return nil }
        let t = (origin - rayOrigin).dot(n) / denom
        guard t > 0 else { return nil }
        return worldToTable(rayOrigin + rayDirection * t)
    }

    // MARK: - Construction from corners

    /// Build a calibration from the four playing-field corners in world
    /// space, ordered around the rectangle (either winding, any starting
    /// corner): c0→c1 and c3→c2 must be one pair of opposite edges.
    /// The long edge pair becomes the x axis. Table size is snapped to the
    /// nearest standard size within `sizeTolerance`.
    public static func fromCorners(_ corners: [Vec3],
                                   sizeTolerance: Double = 0.05)
    throws -> TableCalibration {
        guard corners.count == 4 else { throw CalibrationError.needFourCorners }
        let c0 = corners[0], c1 = corners[1], c2 = corners[2], c3 = corners[3]

        // Average the two parallel edges of each pair to damp corner noise.
        var edgeA = ((c1 - c0) + (c2 - c3)) * 0.5   // c0→c1 direction pair
        var edgeB = ((c3 - c0) + (c2 - c1)) * 0.5   // c0→c3 direction pair
        let lengthA = edgeA.length
        let lengthB = edgeB.length
        guard lengthA > 1e-6, lengthB > 1e-6 else {
            throw CalibrationError.degenerateCorners
        }

        // x axis = long edge.
        if lengthB > lengthA {
            swap(&edgeA, &edgeB)
        }
        let width = Swift.max(lengthA, lengthB)
        let height = Swift.min(lengthA, lengthB)
        guard let size = TableSize.inferred(width: width, height: height,
                                            tolerance: sizeTolerance) else {
            throw CalibrationError.unrecognizedTableSize(width: width, height: height)
        }

        let x = edgeA.normalized
        // Orthonormalize the short axis against x (Gram-Schmidt).
        let yRaw = edgeB - x * edgeB.dot(x)
        guard yRaw.length > 1e-6 else { throw CalibrationError.degenerateCorners }
        let y = yRaw.normalized

        let centroid = (c0 + c1 + c2 + c3) * 0.25
        return TableCalibration(origin: centroid, xAxis: x, yAxis: y, size: size)
    }
}
