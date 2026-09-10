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

    /// The four playing-field corners in world space, in the order
    /// `fromCorners` expects — so a locked calibration can be taken apart,
    /// adjusted, and rebuilt without remembering how it was made.
    ///
    /// The winding is load-bearing and was wrong. `fromCorners` reads its
    /// short axis as `c0 -> c3`; this emitted `(-x,+y), (+x,+y), (+x,-y),
    /// (-x,-y)`, so `c0 -> c3` ran along MINUS y. Every rebuild came back
    /// with the y axis — and therefore the plane normal — exactly
    /// inverted, while the origin and the long axis looked perfect, which
    /// is why it survived: the existing round-trip test checked origin and
    /// size and never the basis.
    ///
    /// It is reachable in the shipping app through `.reopened`
    /// (CalibrationController): adjust a locked table and re-lock it, and
    /// the normal points into the floor. Same class of defect as the
    /// one-pocket handedness bug fixed in #56, and found the same way — by
    /// asserting a round trip instead of assuming one.
    public var worldCorners: [Vec3] {
        let (w, h) = size.playField
        let hx = w / 2, hy = h / 2
        return [Vec2(-hx, -hy), Vec2(hx, -hy), Vec2(hx, hy), Vec2(-hx, hy)]
            .map(tableToWorld)
    }

    /// The same table, shifted by `delta` in TABLE space (metres along
    /// xAxis and yAxis).
    ///
    /// Corrects a calibration whose size and heading are right but whose
    /// centre is not — the failure mode of building a rectangle from one
    /// end rail, where an asymmetric tap on the rail slides the whole
    /// table along it. Measured on the owner's table at 19 cm across,
    /// which put a third of the balls outside the playing-surface envelope
    /// and stopped them being tracked at all.
    public func translated(by delta: Vec2) -> TableCalibration {
        TableCalibration(origin: origin + xAxis * delta.x + yAxis * delta.y,
                         xAxis: xAxis, yAxis: yAxis, size: size)
    }

    /// The same table, measured as `size`, keeping the origin and axes.
    ///
    /// For correcting a field that locked short or long — corners tapped
    /// inside the cushion noses, say — without re-running the flow. Only
    /// the extent changes, so the centre and the heading are preserved and
    /// no ball moves in table space; the pockets and the playing-surface
    /// envelope move to where the size says they are.
    public func resized(to size: TableSize) -> TableCalibration {
        TableCalibration(origin: origin, xAxis: xAxis, yAxis: yAxis, size: size)
    }

    /// How far apart two parallel rail lines are, measured across the
    /// cloth. Compare against `size.playField.height` to judge a fit.
    public static func railSeparation(_ first: (Vec3, Vec3), _ second: (Vec3, Vec3)) -> Double? {
        let direction = (first.1 - first.0)
        guard direction.length > 1e-3 else { return nil }
        let along = direction.normalized
        let offset = second.0 - first.0
        let across = offset - along * offset.dot(along)
        return across.length
    }

    /// Build a calibration from the two LONG rails plus one point on an
    /// end rail.
    ///
    /// Lines beat corners. A corner is one pixel that has to be picked
    /// exactly, and a few pixels of error there slid this table 19 cm
    /// along its own rail and left a third of the balls outside the
    /// playing-surface envelope. A rail is a long straight edge: any two
    /// points anywhere along it give the same line, so the heading and the
    /// centre line come out of geometry that is easy to hit.
    ///
    /// It also suits a camera that cannot see the whole table. The far END
    /// of the owner's table is outside the frame, but both long rails run
    /// right across it, so the constraint that matters most — where the
    /// centre line is — is the one most reliably available.
    ///
    /// `nearRail` and `farRail` are any two points on each long cushion;
    /// `endRail` is one point on the end cushion the camera can see. All
    /// in world space, on the cloth. The rails' measured separation is not
    /// used for the size — `size` is — so it stays available as a check.
    public static func fromLongRails(nearRail: (Vec3, Vec3),
                                     farRail: (Vec3, Vec3),
                                     endRail: Vec3,
                                     size: TableSize) throws -> TableCalibration {
        let nearDirection = nearRail.1 - nearRail.0
        let farDirection = farRail.1 - farRail.0
        guard nearDirection.length > 1e-3, farDirection.length > 1e-3 else {
            throw CalibrationError.degenerateCorners
        }
        // Average the two rail directions, flipping the far one when the
        // points were given in the opposite order.
        let nearUnit = nearDirection.normalized
        let farUnit = farDirection.normalized
        let aligned = farUnit.dot(nearUnit) < 0 ? farUnit * -1 : farUnit
        let longAxis = (nearUnit + aligned).normalized
        guard longAxis.length > 1e-6 else { throw CalibrationError.degenerateCorners }

        // Across the cloth, in the plane the two rails span.
        let planeNormal = longAxis.cross(farRail.0 - nearRail.0)
        guard planeNormal.length > 1e-6 else { throw CalibrationError.degenerateCorners }
        var shortAxis = planeNormal.normalized.cross(longAxis).normalized
        // Point it from the near rail toward the far one.
        if shortAxis.dot(farRail.0 - nearRail.0) < 0 { shortAxis *= -1 }

        let reference = nearRail.0
        func across(_ p: Vec3) -> Double { (p - reference).dot(shortAxis) }
        func along(_ p: Vec3) -> Double { (p - reference).dot(longAxis) }
        let centreAcross = (across(nearRail.0) + across(farRail.0)) / 2

        // The table runs away from the end rail, toward the rest of what
        // the camera can see.
        let visibleMiddle = along(nearRail.0) + along(nearRail.1)
            + along(farRail.0) + along(farRail.1)
        let direction: Double = (visibleMiddle / 4) >= along(endRail) ? 1 : -1
        let centreAlong = along(endRail) + direction * size.playField.width / 2

        let origin = reference + longAxis * centreAlong + shortAxis * centreAcross
        return TableCalibration(origin: origin, xAxis: longAxis,
                                yAxis: shortAxis, size: size)
    }

    /// Build a calibration from ONE end rail plus a known table size.
    ///
    /// `a` and `b` are the two corners of a short rail, in world space, in
    /// either order; `towards` is any point on the cloth, used only to
    /// decide which side of that rail the table lies on. The far end is
    /// constructed from the size rather than observed.
    ///
    /// This exists because a device parked at the side of a table often
    /// cannot see the whole thing: on the owner's iPad the right end sits
    /// outside the frame entirely, so two of the four corners cannot be
    /// tapped at all and every calibration from that position comes out
    /// short — measured at 2.175 m against 2.34. One end rail and the
    /// table's size determine the rectangle completely, so the corners
    /// that cannot be seen do not need to be.
    ///
    /// The rail is used for the SHORT axis and its measured length is
    /// discarded in favour of `size`, so a few centimetres of tap error
    /// changes the origin slightly and the extent not at all.
    public static func fromEndRail(_ a: Vec3, _ b: Vec3, towards: Vec3,
                                   size: TableSize) throws -> TableCalibration {
        let rail = b - a
        guard rail.length > 1e-3 else { throw CalibrationError.degenerateCorners }
        let (width, height) = size.playField
        let shortAxis = rail.normalized
        // Up out of the cloth: the rail and the inward direction both lie
        // in the plane, so their normal is the plane's.
        let toward = towards - a
        let inPlane = toward - shortAxis * toward.dot(shortAxis)
        guard inPlane.length > 1e-3 else { throw CalibrationError.degenerateCorners }
        let longAxis = inPlane.normalized
        let railMidpoint = a + rail * 0.5
        let origin = railMidpoint + longAxis * (width / 2)
        _ = height
        return TableCalibration(origin: origin, xAxis: longAxis,
                                yAxis: shortAxis, size: size)
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
