//
//  TiltedPocketFit.swift
//  TableSpace
//
//  Fitting the table to pocket RAYS with the plane's height AND tilt free.
//
//  The flat fit (`solveHeight` then `solve` against a horizontal plane)
//  leaves 25-30 mm rms on the owner's table whatever the picks are. The
//  reason is the viewing angle: from the head rail the far pockets are
//  seen about 10 degrees above grazing, so an error of 1 mm in the plane's
//  height under them moves them about 6 mm along the table, and half a
//  degree of tilt between ARKit's gravity and the slate is 20 mm of height
//  at the far end. Measured 2026-11-11 with the same four picks: 26.7 mm
//  rms flat, 9.1 mm with a 0.5 degree tilt free. Neither a level table nor
//  ARKit's gravity is better than that, so the tilt is a real unknown, not
//  a fudge.
//
//  It is only freed when the fit can afford it. Six pockets give twelve
//  coordinates against six unknowns (heading, position, height, two tilts),
//  so the residual still means something; with four the tilt would soak
//  up most of the evidence, so four pockets stay flat. Every fit also
//  reports each pocket's LEAVE-ONE-OUT error, the honest accuracy number:
//  where the table fitted to the other pockets puts this one.
//

import CueSyncCore
import Foundation

extension PocketCalibration {

    /// A table fitted to pocket rays on a possibly tilted plane.
    public struct TiltedFit: Sendable, Equatable {
        /// The table on the plane the sightings lie on (not yet lowered to
        /// the cloth: see `lowered(by:)`).
        public var calibration: TableCalibration
        /// Unit normal of the fitted plane (world up when not tilted).
        public var normal: Vec3
        /// Angle between `normal` and world up, degrees.
        public var tiltDegrees: Double
        /// RMS in-plane distance between sighted and fitted pockets, metres.
        public var residual: Double
        /// Per-pocket in-plane error, metres.
        public var errors: [PocketID: Double]
        /// Per-pocket error when that pocket is left out of the fit, metres.
        /// Empty with fewer than five pockets.
        public var leaveOneOut: [PocketID: Double]
        /// A pocket removed as an outlier before this fit, if any.
        public var dropped: PocketID?
        /// Where this fit puts the dropped pocket relative to its sighting.
        public var droppedError: Double?
        /// Pockets used.
        public var pocketCount: Int

        public var worst: (pocket: PocketID, error: Double)? {
            errors.max { $0.value < $1.value }.map { ($0.key, $0.value) }
        }
    }

    /// Steepest tilt considered, as a slope (about 1.5 degrees).
    static let maximumTiltSlope = 0.026

    /// Fit with height and (from five pockets up) tilt free.
    ///
    /// - Parameters:
    ///   - rays: world rays labelled by pocket; one per pocket (later
    ///     duplicates are ignored).
    ///   - size: the table size.
    ///   - dropOutlier: with six pockets, remove one whose leave-one-out
    ///     error is far beyond the others' and refit. The dropped pocket is
    ///     reported, never hidden.
    ///   - alongFree: pockets whose position ALONG the long rails is not
    ///     known, only across them: a near corner snapped onto the long
    ///     cushion nose keeps the tap's guess along it (the near end's nose
    ///     faces away from a camera at the head rail). Those constrain the
    ///     fit across the table only, and their error is measured across.
    public static func solveTilted(rays: [(pocket: PocketID, ray: TapRay)],
                                   size: TableSize,
                                   dropOutlier: Bool = true,
                                   alongFree: Set<PocketID> = []) throws -> TiltedFit {
        var unique: [(pocket: PocketID, ray: TapRay)] = []
        for entry in rays where !unique.contains(where: { $0.pocket == entry.pocket }) {
            unique.append(entry)
        }
        guard unique.count >= 2 else { throw Failure.needTwoPockets }
        var fit = try bestFit(unique, size: size, alongFree: alongFree)
        fit.leaveOneOut = leaveOneOut(unique, size: size, around: fit, alongFree: alongFree)
        // Dropping needs redundancy left over: after the drop, at least
        // three more measured coordinates than the six unknowns (heading,
        // two position, height, two tilts). An along-free pocket measures
        // one coordinate, a full one two. Without that margin a dropped
        // pocket just leaves the rest fitting each other trivially: on
        // device, five pockets with two along-free "fitted" to 1.2 mm after
        // dropping a far corner that was in fact fine.
        guard dropOutlier, unique.count >= 6,
              let suspect = fit.leaveOneOut.max(by: { $0.value < $1.value })?.key else { return fit }
        let measured = unique.filter { $0.pocket != suspect }
            .reduce(0) { $0 + (alongFree.contains($1.pocket) ? 1 : 2) }
        guard measured - 6 >= 3 else { return fit }
        // Drop the worst pocket only when the other five then agree far
        // better than the six did, and it is centimetres off their table.
        let rest = unique.filter { $0.pocket != suspect }
        guard var refit = try? bestFit(rest, size: size, alongFree: alongFree),
              let ray = unique.first(where: { $0.pocket == suspect })?.ray else { return fit }
        let suspectError = predictionError(refit, pocket: suspect, ray: ray, size: size,
                                           alongFree: alongFree.contains(suspect))
        guard suspectError > outlierDistance, refit.residual * 2.5 < fit.residual else { return fit }
        refit.leaveOneOut = leaveOneOut(rest, size: size, around: refit, alongFree: alongFree)
        refit.dropped = suspect
        refit.droppedError = suspectError
        return refit
    }

    /// How far off the other pockets' table a sighting must be before it
    /// may be dropped, metres.
    static let outlierDistance = 0.03

    static func leaveOneOut(_ rays: [(pocket: PocketID, ray: TapRay)],
                            size: TableSize, around start: TiltedFit,
                            alongFree: Set<PocketID> = []) -> [PocketID: Double] {
        guard rays.count >= 5 else { return [:] }
        var result: [PocketID: Double] = [:]
        for entry in rays {
            let rest = rays.filter { $0.pocket != entry.pocket }
            guard let fit = try? bestFit(rest, size: size, around: start, alongFree: alongFree) else { continue }
            result[entry.pocket] = predictionError(fit, pocket: entry.pocket, ray: entry.ray, size: size,
                                                   alongFree: alongFree.contains(entry.pocket))
        }
        return result
    }

    /// In-plane distance between where `fit` puts a pocket and where its
    /// ray meets the fitted plane (across the table only, `alongFree`).
    static func predictionError(_ fit: TiltedFit, pocket: PocketID, ray: TapRay,
                                size: TableSize, alongFree: Bool = false) -> Double {
        guard let expected = Table(size: size).pockets.first(where: { $0.id == pocket })?.position,
              let hit = intersect(ray, planePoint: fit.calibration.origin, normal: fit.normal)
        else { return .infinity }
        let offset = hit - fit.calibration.tableToWorld(expected)
        return alongFree ? abs(offset.dot(fit.calibration.yAxis)) : offset.length
    }

    static func intersect(_ ray: TapRay, planePoint: Vec3, normal: Vec3) -> Vec3? {
        let denominator = ray.direction.dot(normal)
        guard abs(denominator) > 1e-6 else { return nil }
        let t = (planePoint - ray.origin).dot(normal) / denominator
        guard t > 0 else { return nil }
        return ray.origin + ray.direction * t
    }

    /// Best plane (height, and tilt when five or more pockets) by search.
    /// `start`, when given, is a nearby fit to search around (the
    /// leave-one-out refits), which keeps those cheap.
    static func bestFit(_ rays: [(pocket: PocketID, ray: TapRay)],
                        size: TableSize, around start: TiltedFit? = nil,
                        alongFree: Set<PocketID> = []) throws -> TiltedFit {
        let camera = rays.map(\.ray.origin).reduce(Vec3.zero, +) / Double(rays.count)
        let tiltFree = rays.count >= 5
        let layout = Dictionary(uniqueKeysWithValues: Table(size: size).pockets.map { ($0.id, $0.position) })
        let model = rays.compactMap { layout[$0.pocket] }
        guard model.count == rays.count else { throw Failure.needTwoPockets }
        let sliding = rays.map { alongFree.contains($0.pocket) }

        func plane(_ depth: Double, _ a: Double, _ b: Double) -> (anchor: Vec3, normal: Vec3) {
            (Vec3(camera.x, camera.y - depth, camera.z), Vec3(-a, 1, -b).normalized)
        }
        /// Pocket hits in a 2-D basis of that plane.
        func flatten(_ depth: Double, _ a: Double, _ b: Double) -> (points: [Vec2], anchor: Vec3,
                                                                     u: Vec3, v: Vec3, normal: Vec3)? {
            let (anchor, normal) = plane(depth, a, b)
            let u = normal.cross(Vec3(1, 0, 0)).normalized
            let v = normal.cross(u)
            var observed: [Vec2] = []
            observed.reserveCapacity(rays.count)
            for entry in rays {
                guard let hit = intersect(entry.ray, planePoint: anchor, normal: normal) else { return nil }
                let rel = hit - anchor
                observed.append(Vec2(rel.dot(u), rel.dot(v)))
            }
            return (observed, anchor, u, v, normal)
        }
        /// RMS of the rigid 2-D fit on that plane.
        func cost(_ depth: Double, _ a: Double, _ b: Double) -> Double {
            guard let flat = flatten(depth, a, b) else { return .infinity }
            return rigidFit(model: model, observed: flat.points, sliding: sliding).residual
        }
        /// Best depth for a tilt: sweep, then golden section.
        func bestDepth(_ a: Double, _ b: Double, near guess: Double?) -> (depth: Double, cost: Double) {
            let range: ClosedRange<Double> = guess.map {
                max(heightSearchRange.lowerBound, $0 - 0.1)...min(heightSearchRange.upperBound, $0 + 0.1)
            } ?? heightSearchRange
            let steps = guess == nil ? 120 : 20
            let spacing = (range.upperBound - range.lowerBound) / Double(steps)
            var best = (depth: range.lowerBound, cost: Double.infinity)
            for step in 0...steps {
                let depth = range.lowerBound + spacing * Double(step)
                let value = cost(depth, a, b)
                if value < best.cost { best = (depth, value) }
            }
            guard best.cost.isFinite else { return best }
            var low = best.depth - spacing
            var high = best.depth + spacing
            let ratio = (5.0.squareRoot() - 1) / 2
            for _ in 0..<36 {
                let p = high - ratio * (high - low)
                let q = low + ratio * (high - low)
                if cost(p, a, b) < cost(q, a, b) { high = q } else { low = p }
            }
            let depth = (low + high) / 2
            let value = cost(depth, a, b)
            return value < best.cost ? (depth, value) : best
        }

        var best = (a: 0.0, b: 0.0, depth: 0.0, cost: Double.infinity)
        var step = maximumTiltSlope / 2
        if let start, tiltFree {
            let n = start.normal
            let a = -n.x / n.y
            let b = -n.z / n.y
            let o = start.calibration.origin
            let depth = camera.y - (o.y + a * (camera.x - o.x) + b * (camera.z - o.z))
            let found = bestDepth(a, b, near: depth)
            best = (a, b, found.depth, found.cost)
            step = 0.002
        } else {
            let flat = bestDepth(0, 0, near: nil)
            best = (0, 0, flat.depth, flat.cost)
        }
        if tiltFree {
            // Coordinate descent on the two slopes with a shrinking step.
            while step > 0.0001 {
                var improved = false
                for (da, db) in [(step, 0.0), (-step, 0), (0, step), (0, -step)] {
                    let a = best.a + da
                    let b = best.b + db
                    guard abs(a) <= maximumTiltSlope, abs(b) <= maximumTiltSlope else { continue }
                    let trial = bestDepth(a, b, near: best.depth)
                    if trial.cost < best.cost - 1e-8 {
                        best = (a, b, trial.depth, trial.cost)
                        improved = true
                    }
                }
                if !improved { step /= 2 }
            }
        }
        guard best.cost.isFinite else { throw HeightFailure.raysDoNotMeetTheCloth }
        // Build the table itself once, on the winning plane, from the
        // sightings as the fit placed them (along-free ones slid along the
        // rail to where the table puts them).
        guard let flat = flatten(best.depth, best.a, best.b) else { throw HeightFailure.raysDoNotMeetTheCloth }
        let normal = flat.normal
        let placed = rigidFit(model: model, observed: flat.points, sliding: sliding).observed
        let sightings = zip(rays, placed).map { entry, point in
            Sighting(pocket: entry.pocket, world: flat.anchor + flat.u * point.x + flat.v * point.y)
        }
        let solution = try solve(sightings, size: size, planeNormal: normal, towards: flat.anchor)
        var errors: [PocketID: Double] = [:]
        for sighting in sightings {
            guard let expected = layout[sighting.pocket] else { continue }
            errors[sighting.pocket] = solution.calibration.tableToWorld(expected).distance(to: sighting.world)
        }
        let tilt = acos(max(-1, min(1, normal.dot(Vec3(0, 1, 0))))) * 180 / .pi
        return TiltedFit(calibration: solution.calibration, normal: normal, tiltDegrees: tilt,
                         residual: solution.residual, errors: errors, leaveOneOut: [:],
                         dropped: nil, droppedError: nil, pocketCount: sightings.count)
    }
}

extension PocketCalibration {
    /// Rigid 2-D fit of `model` (table space) onto `observed`, no scale.
    ///
    /// Points flagged `sliding` are known only across the table: after
    /// each Procrustes step they slide along the fitted long axis to the
    /// model point's position, and the fit repeats (an ICP on lines). With
    /// nothing sliding this is one closed-form step.
    static func rigidFit(model: [Vec2], observed: [Vec2],
                         sliding: [Bool]) -> (residual: Double, observed: [Vec2]) {
        var points = observed
        let modelCentre = centroid(model)
        let iterations = sliding.contains(true) ? 40 : 1
        var residual = Double.infinity
        for _ in 0..<iterations {
            let observedCentre = centroid(points)
            var dot = 0.0, cross = 0.0
            for (m, o) in zip(model, points) {
                dot += (m - modelCentre).dot(o - observedCentre)
                cross += (m - modelCentre).cross(o - observedCentre)
            }
            let angle = atan2(cross, dot)
            var sum = 0.0
            for (m, o) in zip(model, points) {
                let fitted = rotate(m - modelCentre, by: angle) + observedCentre
                sum += (fitted - o).dot(fitted - o)
            }
            residual = (sum / Double(max(model.count, 1))).squareRoot()
            guard iterations > 1 else { break }
            let along = rotate(Vec2(1, 0), by: angle)
            var moved = 0.0
            for index in points.indices where sliding[index] {
                let fitted = rotate(model[index] - modelCentre, by: angle) + observedCentre
                let next = observed[index] + along * (fitted - observed[index]).dot(along)
                moved = max(moved, next.distance(to: points[index]))
                points[index] = next
            }
            if moved < 1e-9 { break }
        }
        return (residual, points)
    }
}

extension PocketCalibration.TiltedFit {
    /// The same table moved `distance` metres down its own normal: from the
    /// plane the sightings were on (cushion noses) to the cloth.
    public func lowered(by distance: Double) -> TableCalibration {
        TableCalibration(origin: calibration.origin - normal * distance,
                         xAxis: calibration.xAxis, yAxis: calibration.yAxis,
                         size: calibration.size)
    }

    /// One line for the mirror: rms, worst, and leave-one-out.
    public var summary: String {
        var line = String(format: "%d pockets, fit %.1f mm rms", pocketCount, residual * 1000)
        if let worst {
            line += String(format: ", worst %@ %.1f mm", worst.pocket.rawValue, worst.error * 1000)
        }
        if !leaveOneOut.isEmpty, let loo = leaveOneOut.max(by: { $0.value < $1.value }) {
            line += String(format: ", leave-one-out max %@ %.1f mm", loo.key.rawValue, loo.value * 1000)
        }
        line += String(format: ", tilt %.2f deg", tiltDegrees)
        if let dropped {
            line += String(format: ", dropped %@ (%.0f mm off)", dropped.rawValue, (droppedError ?? 0) * 1000)
        }
        return line
    }
}
