//
//  PocketCalibration.swift
//  TableSpace
//
//  Finding the table from its pockets, because on a black-cloth table
//  they are the only thing you can actually see.
//
//  Every other constructor here starts from a cushion NOSE — the line
//  where the cushion meets the cloth. That line is the right one
//  geometrically and it is invisible on the owner's table: the cushions
//  are wrapped in the same black cloth as the bed, so nose-to-cloth has
//  no contrast at all. What a camera sees instead is the cloth-to-rail
//  edge, several centimetres further out, and calibrating from that
//  oversizes the table — a mistake this package already has a test named
//  after (`railTopTapsInflateTheFieldAndStillSnap`).
//
//  Pockets do not have that problem. A pocket is a hole: dark against
//  light rail wood, distinctly shaped, and visible from any angle that
//  can see the table at all. And the geometry is free — a pocket's mouth
//  centre IS a corner of the nose rectangle, or the midpoint of a long
//  rail (see `Table.pockets`). So sighting pockets measures the nose
//  rectangle directly, without anyone ever seeing a nose.
//
//  The fit is a 2-D rigid transform: the pocket layout for a known table
//  size is a rigid body, so the only unknowns are where it sits and which
//  way it points. Solved in closed form by Procrustes — no iteration, no
//  starting guess, no convergence to worry about.
//

import CueSyncCore
import Foundation

public enum PocketCalibration {
    /// One pocket, seen and placed on the cloth plane.
    public struct Sighting: Sendable, Equatable {
        public var pocket: PocketID
        /// Where the sighting landed in world space, already unprojected
        /// onto the cloth plane by the caller.
        public var world: Vec3

        public init(pocket: PocketID, world: Vec3) {
            self.pocket = pocket
            self.world = world
        }
    }

    /// A fitted table, and how well it fits.
    ///
    /// The residual is the point of returning a struct rather than a bare
    /// calibration. A rigid fit always succeeds — it will happily place a
    /// table through badly-sighted pockets — so the number that says
    /// whether to believe it has to come back with it.
    public struct Solution: Sendable, Equatable {
        public var calibration: TableCalibration
        /// RMS distance, metres, between each sighted pocket and where
        /// the fitted table puts that pocket.
        public var residual: Double
        /// The pocket that fits worst, and by how far. More useful than
        /// the RMS when one sighting is simply on the wrong hole.
        public var worstPocket: PocketID
        public var worstError: Double

        public init(calibration: TableCalibration, residual: Double,
                    worstPocket: PocketID, worstError: Double) {
            self.calibration = calibration
            self.residual = residual
            self.worstPocket = worstPocket
            self.worstError = worstError
        }
    }

    public enum Failure: Error, Equatable {
        /// Fewer than two distinct pockets: nothing fixes the heading.
        case needTwoPockets
        /// Every sighting is on one rail, and no `towards` point was
        /// given to say which side of it the table lies on.
        case ambiguousSide
        /// The sightings collapse to a point, or the plane normal is
        /// degenerate.
        case degenerate
    }

    /// Fit a table to sighted pockets.
    ///
    /// - Parameters:
    ///   - sightings: at least two distinct pockets. Duplicates of the
    ///     same pocket are averaged rather than double-weighted, so a
    ///     caller may hand over several frames' worth.
    ///   - size: the table's known size. Pocket layout comes from it, and
    ///     the fitted extent is exactly this — the sightings set position
    ///     and heading only, never scale. Two pockets sighted 5 cm too
    ///     close together must not shrink the table.
    ///   - planeNormal: the cloth normal, pointing up out of the bed.
    ///     Fixes the handedness of the result, so a table is never fitted
    ///     upside down.
    ///   - towards: any point known to be on the cloth — a ball will do.
    ///     Consulted only when the sightings are collinear, which is the
    ///     common case of seeing one rail's three pockets and nothing
    ///     else.
    public static func solve(_ sightings: [Sighting],
                             size: TableSize,
                             planeNormal: Vec3,
                             towards: Vec3? = nil) throws -> Solution {
        let merged = averagedByPocket(sightings)
        guard merged.count >= 2 else { throw Failure.needTwoPockets }
        guard planeNormal.length > 1e-9 else { throw Failure.degenerate }
        let normal = planeNormal.normalized

        // An arbitrary but right-handed basis in the cloth plane. Only the
        // fitted rotation is meaningful; this just gives the fit somewhere
        // to happen. u × v == normal, which is what keeps the final
        // xAxis × yAxis == normal and the table the right way up.
        let seed = abs(normal.x) < 0.9 ? Vec3(1, 0, 0) : Vec3(0, 1, 0)
        let u = normal.cross(seed).normalized
        let v = normal.cross(u).normalized

        let reference = merged[0].world
        func flatten(_ p: Vec3) -> Vec2 {
            let rel = p - reference
            return Vec2(rel.dot(u), rel.dot(v))
        }

        let table = Table(size: size)
        let layout = Dictionary(uniqueKeysWithValues: table.pockets.map { ($0.id, $0.position) })
        var model: [Vec2] = []
        var observed: [Vec2] = []
        for sighting in merged {
            guard let expected = layout[sighting.pocket] else { continue }
            model.append(expected)
            observed.append(flatten(sighting.world))
        }
        guard model.count >= 2 else { throw Failure.needTwoPockets }

        let modelCentre = centroid(model)
        let observedCentre = centroid(observed)
        // Procrustes without scale: the rotation that best carries the
        // known layout onto what was seen.
        var dot = 0.0
        var cross = 0.0
        for (m, o) in zip(model, observed) {
            let a = m - modelCentre
            let b = o - observedCentre
            dot += a.dot(b)
            cross += a.cross(b)
        }
        guard dot * dot + cross * cross > 1e-18 else { throw Failure.degenerate }
        let angle = atan2(cross, dot)

        // Collinear sightings leave the table's side undetermined: the
        // rotation above fits equally well flipped 180 degrees about the
        // rail. That is not a numerical wobble, it is two real answers,
        // and picking one by luck would put the whole playing surface on
        // the wrong side of the rail.
        var chosen = angle
        if isCollinear(observed) {
            guard let towards else { throw Failure.ambiguousSide }
            let flipped = angle + .pi
            let hint = flatten(towards)
            // The cloth point has to end up inside the table, so keep the
            // orientation whose field the hint actually falls in.
            let direct = outsideness(hint, size: size, angle: angle,
                                     modelCentre: modelCentre, observedCentre: observedCentre)
            let mirror = outsideness(hint, size: size, angle: flipped,
                                     modelCentre: modelCentre, observedCentre: observedCentre)
            chosen = direct <= mirror ? angle : flipped
        }

        let cosine = cos(chosen)
        let sine = sin(chosen)
        // Table +x and +y, carried out of the fit and back into world space.
        let xAxis = (u * cosine + v * sine).normalized
        let yAxis = (u * -sine + v * cosine).normalized
        // Table-space (0, 0) is the field centre, which the model
        // centroid is NOT unless every pocket was sighted — so place the
        // origin by carrying the model's own centre through the fit.
        let originFlat = observedCentre - rotate(modelCentre, by: chosen)
        let origin = reference + u * originFlat.x + v * originFlat.y

        let calibration = TableCalibration(origin: origin, xAxis: xAxis,
                                           yAxis: yAxis, size: size)
        var sumSquares = 0.0
        var worstPocket = merged[0].pocket
        var worstError = 0.0
        for sighting in merged {
            guard let expected = layout[sighting.pocket] else { continue }
            let error = calibration.tableToWorld(expected).distance(to: sighting.world)
            sumSquares += error * error
            if error > worstError {
                worstError = error
                worstPocket = sighting.pocket
            }
        }
        let residual = (sumSquares / Double(model.count)).squareRoot()
        return Solution(calibration: calibration, residual: residual,
                        worstPocket: worstPocket, worstError: worstError)
    }

    /// Fit a table from ONE pocket plus the direction of a long rail.
    ///
    /// For the view that has neither enough pockets nor a visible nose: a
    /// device parked at the side of a black-cloth table can often see
    /// exactly one pocket mouth — the near side one, cut into light rail
    /// wood — and both near corners sit outside the frame.
    ///
    /// One pocket fixes position, and the rail fixes heading. The rail's
    /// EDGE is used, not its nose: only the direction is taken from it,
    /// and the cloth-to-wood edge is parallel to the nose line it hides.
    /// So the several centimetres of offset that make the edge useless
    /// for measuring a table cost exactly nothing here — which is the
    /// whole reason this entry point exists.
    ///
    /// - Parameters:
    ///   - pocket: the one sighted pocket, unprojected onto the cloth.
    ///   - alongRail: any world vector parallel to the long rails. Sign
    ///     does not matter.
    ///   - towards: a point known to be on the cloth, which decides which
    ///     side of the rail the table lies on. Required, not optional:
    ///     with one pocket there is nothing else that could decide it.
    public static func solve(pocket: Sighting,
                             alongRail: Vec3,
                             size: TableSize,
                             planeNormal: Vec3,
                             towards: Vec3) throws -> Solution {
        guard planeNormal.length > 1e-9 else { throw Failure.degenerate }
        let normal = planeNormal.normalized
        // Flatten the rail into the cloth plane: a direction read off an
        // image will not be exactly in it.
        let inPlane = alongRail - normal * alongRail.dot(normal)
        guard inPlane.length > 1e-6 else { throw Failure.degenerate }
        var xAxis = inPlane.normalized
        let across = normal.cross(xAxis).normalized
        guard across.length > 1e-6 else { throw Failure.degenerate }

        let table = Table(size: size)
        guard let expected = table.pockets.first(where: { $0.id == pocket.pocket })?.position else {
            throw Failure.degenerate
        }

        func build(_ x: Vec3, _ y: Vec3) -> TableCalibration {
            let origin = pocket.world - (x * expected.x + y * expected.y)
            return TableCalibration(origin: origin, xAxis: x, yAxis: y, size: size)
        }
        // Two tables satisfy one pocket and a heading — the cloth on one
        // side of the rail or the other — and they differ by the whole
        // width of the table. The hint is what picks.
        var yAxis = across
        if outside(towards, of: build(xAxis, across * -1), size: size)
            < outside(towards, of: build(xAxis, across), size: size) {
            yAxis = across * -1
        }
        // Choosing y by where the cloth is can leave the pair
        // left-handed, and then the table's normal points into the floor:
        // heights come out negative, `heightAbovePlane` inverts, and the
        // playing surface is fitted upside down under a correct-looking
        // origin. Reversing the LONG axis fixes the handedness and costs
        // nothing — a table pointing the other way down its own length is
        // the same table, while reversing y would move the cloth.
        if xAxis.cross(yAxis).dot(normal) < 0 { xAxis *= -1 }
        let calibration = build(xAxis, yAxis)
        // A single sighting is reproduced exactly by construction, so the
        // residual is zero and says nothing. Reported anyway, and named
        // honestly, so a caller reading `residual` never mistakes "one
        // point fits one point" for "this table is verified".
        let error = calibration.tableToWorld(expected).distance(to: pocket.world)
        return Solution(calibration: calibration, residual: error,
                        worstPocket: pocket.pocket, worstError: error)
    }

    /// How far outside the playing field a world point falls, in metres.
    static func outside(_ point: Vec3, of calibration: TableCalibration,
                        size: TableSize) -> Double {
        let local = calibration.worldToTable(point)
        let outX = max(0, abs(local.x) - size.playField.width / 2)
        let outY = max(0, abs(local.y) - size.playField.height / 2)
        return (outX * outX + outY * outY).squareRoot()
    }

    // MARK: - Pieces

    /// Several looks at the same pocket average into one, so a caller can
    /// pass a burst of frames without the best-seen pocket dominating.
    static func averagedByPocket(_ sightings: [Sighting]) -> [Sighting] {
        var sums: [PocketID: (total: Vec3, count: Double)] = [:]
        var order: [PocketID] = []
        for sighting in sightings {
            if sums[sighting.pocket] == nil { order.append(sighting.pocket) }
            let existing = sums[sighting.pocket] ?? (.zero, 0)
            sums[sighting.pocket] = (existing.total + sighting.world, existing.count + 1)
        }
        return order.compactMap { id in
            guard let entry = sums[id], entry.count > 0 else { return nil }
            return Sighting(pocket: id, world: entry.total / entry.count)
        }
    }

    static func centroid(_ points: [Vec2]) -> Vec2 {
        guard !points.isEmpty else { return .zero }
        return points.reduce(Vec2.zero, +) / Double(points.count)
    }

    static func rotate(_ p: Vec2, by angle: Double) -> Vec2 {
        Vec2(p.x * cos(angle) - p.y * sin(angle), p.x * sin(angle) + p.y * cos(angle))
    }

    /// True when every point lies within a few millimetres of the line
    /// through the two furthest apart — which is exactly what three
    /// pockets on one rail look like.
    ///
    /// Two points are always collinear, so a two-pocket sighting always
    /// needs the hint. That is correct: two pockets genuinely do not say
    /// which side of themselves the table is on.
    static func isCollinear(_ points: [Vec2], tolerance: Double = 0.02) -> Bool {
        guard points.count > 2 else { return true }
        var best = (a: points[0], b: points[1], span: 0.0)
        for i in points.indices {
            for j in points.indices where j > i {
                let span = points[i].distance(to: points[j])
                if span > best.span { best = (points[i], points[j], span) }
            }
        }
        guard best.span > 1e-6 else { return true }
        let axis = (best.b - best.a).normalized
        for point in points {
            let rel = point - best.a
            if abs(rel.cross(axis)) > tolerance { return false }
        }
        return true
    }

    /// How far outside the field a point falls, in metres; zero when it is
    /// inside. Used only to break the collinear tie.
    static func outsideness(_ point: Vec2, size: TableSize,
                            angle: Double, modelCentre: Vec2,
                            observedCentre: Vec2) -> Double {
        let local = rotate(point - observedCentre, by: -angle) + modelCentre
        let half = Vec2(size.playField.width / 2, size.playField.height / 2)
        let outX = max(0, abs(local.x) - half.x)
        let outY = max(0, abs(local.y) - half.y)
        return (outX * outX + outY * outY).squareRoot()
    }
}
