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
    /// No longer thrown by `fromCorners` (non-standard rectangles lock as
    /// `TableSize.custom`); kept for API stability.
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
    /// Raw measured long axis at lock time (pre-snap), meters. Nil on
    /// calibrations persisted before this field existed (decodes absent).
    public var measuredWidth: Double?
    /// Raw measured short axis at lock time (pre-snap), meters.
    public var measuredHeight: Double?

    public init(origin: Vec3, xAxis: Vec3, yAxis: Vec3, size: TableSize,
                measuredWidth: Double? = nil, measuredHeight: Double? = nil) {
        self.origin = origin
        self.xAxis = xAxis.normalized
        self.yAxis = yAxis.normalized
        self.size = size
        self.measuredWidth = measuredWidth
        self.measuredHeight = measuredHeight
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
    /// The long edge pair becomes the x axis. Table size snaps first to
    /// `preferredSize` (the user's saved table spec — repeat calibrations
    /// of the same table must agree with each other, not with a generic
    /// standard), then to the nearest standard size within `sizeTolerance`;
    /// anything else locks as `.custom` with the measured dimensions —
    /// never refuse a real table for being odd.
    ///
    /// The snap is deliberately ASYMMETRIC, because the tapping error it
    /// exists to absorb has a direction.
    ///
    /// OVER-measurement is a documented, quantified mis-tap: tapping the
    /// rail top instead of the cushion nose inflates the field by a
    /// percentage of each corner's distance from centre — +4 cm from 2.4 m
    /// overhead, +8 cm from 1.2 m, +6.5 cm from a realistic head-rail pose
    /// (`ProjectionRoundTripTests.railTopTapsInflateTheFieldAndStillSnap`).
    /// Symmetric inflation leaves the origin and axes untouched, so the
    /// snap absorbs it entirely and ball error stays under 2 mm. Going up,
    /// the fractional `sizeTolerance` is exactly the right instrument.
    ///
    /// UNDER-measurement has no such mechanism — nothing systematically
    /// pulls taps inside the cushion nose — so a field measuring smaller
    /// than a standard most likely IS smaller. Snapping it up moves every
    /// pocket outward: a real 2.26 x 1.09 m table snapped to the 2.34 x
    /// 1.17 m standard drew every pocket ~4 cm outside the real one, on
    /// every shot, because `Table(size:)` builds pockets and cushions from
    /// the snapped size while the tapped corners set the origin and axes.
    /// Below a standard, therefore, `maxSnapUnder` (metres) governs and the
    /// honest answer past it is `.custom` with what was actually measured —
    /// with the HUD reporting the delta so a genuine mis-tap can be
    /// re-tapped rather than silently absorbed.
    public static func fromCorners(_ corners: [Vec3],
                                   sizeTolerance: Double = 0.08,
                                   maxSnapUnder: Double = 0.03,
                                   preferredSize: TableSize? = nil)
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
        let size: TableSize
        if let preferred = preferredSize,
           matches(width: width, height: height, candidate: preferred,
                   tolerance: sizeTolerance),
           undersizeDelta(width: width, height: height, candidate: preferred)
            <= maxSnapUnder + snapEpsilon {
            size = preferred
        } else if let standard = TableSize.inferred(width: width, height: height,
                                                    tolerance: sizeTolerance),
                  undersizeDelta(width: width, height: height, candidate: standard)
                    <= maxSnapUnder + snapEpsilon {
            size = standard
        } else {
            size = .custom(width: width, height: height)
        }

        let x = edgeA.normalized
        // Orthonormalize the short axis against x (Gram-Schmidt).
        let yRaw = edgeB - x * edgeB.dot(x)
        guard yRaw.length > 1e-6 else { throw CalibrationError.degenerateCorners }
        let y = yRaw.normalized

        let centroid = (c0 + c1 + c2 + c3) * 0.25
        return TableCalibration(origin: centroid, xAxis: x, yAxis: y, size: size,
                                measuredWidth: width, measuredHeight: height)
    }

    /// Re-derive a size that an OLDER, symmetric snap rule captured.
    ///
    /// Calibrations locked before the undersize bound existed persist with
    /// a standard `size` and the raw `measured*` fields that contradict it
    /// — an 8 ft label over a field measured 9 cm smaller. Those are the
    /// ones drawing pockets outside the real ones, and they live in
    /// UserDefaults and in saved venues, so a fix that only changed
    /// `fromCorners` would need every user to re-tap their table. Applied
    /// on load instead.
    ///
    /// Deliberately NOT applied to recorded session bundles: a bundle is
    /// evidence of what the app did at the time, and rewriting its
    /// calibration would silently change every replay golden.
    public func correctingUndersizedSnap(maxSnapUnder: Double = 0.03) -> TableCalibration {
        guard let measuredWidth, let measuredHeight else { return self }
        if case .custom = size { return self }
        guard Self.undersizeDelta(width: measuredWidth, height: measuredHeight,
                                  candidate: size) > maxSnapUnder + Self.snapEpsilon
        else { return self }
        return TableCalibration(origin: origin, xAxis: xAxis, yAxis: yAxis,
                                size: .custom(width: measuredWidth,
                                              height: measuredHeight),
                                measuredWidth: measuredWidth,
                                measuredHeight: measuredHeight)
    }

    /// Makes `maxSnapUnder` an inclusive bound in binary floating point:
    /// a field exactly 3 cm under computes as 0.030000000000000027.
    static let snapEpsilon = 1e-9

    /// How much SMALLER (metres, worst axis) a measured field is than a
    /// candidate's playing field; zero when the measurement is at or over
    /// it. Orientation-normalized the same way `TableSize.inferred` does
    /// it: long side against long side.
    static func undersizeDelta(width: Double, height: Double,
                               candidate: TableSize) -> Double {
        let field = candidate.playField
        let w = Swift.max(width, height), h = Swift.min(width, height)
        let fw = Swift.max(field.width, field.height)
        let fh = Swift.min(field.width, field.height)
        return Swift.max(Swift.max(fw - w, fh - h), 0)
    }

    /// Whether a measured field is within `tolerance` (fractional, worst
    /// axis) of a candidate size's playing field.
    private static func matches(width: Double, height: Double,
                                candidate: TableSize, tolerance: Double) -> Bool {
        let w = Swift.max(width, height)
        let h = Swift.min(width, height)
        let field = candidate.playField
        let error = Swift.max(abs(w - field.width) / field.width,
                              abs(h - field.height) / field.height)
        return error <= tolerance
    }

    /// How the measured field compares to the nearest standard size —
    /// falls back to the snapped size for pre-T1.2 calibrations (delta 0).
    public var standardSizeComparison: StandardSizeComparison {
        if let measuredWidth, let measuredHeight {
            StandardSizeComparison(measuredWidth: measuredWidth,
                                   measuredHeight: measuredHeight)
        } else {
            StandardSizeComparison(size: size)
        }
    }
}
