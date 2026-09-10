//
//  ClothHeightFromPockets.swift
//  CueSync AR
//
//  The cloth height, solved from the taps the user already made.
//
//  Every calibration path needs a plane before a tap means a point, and
//  until now that plane came from the balls — their apparent size gives
//  their range, and their range gives the surface they rest on. Measured
//  on the owner's table, across one session, the device reported:
//
//      -0.349  -0.370  -0.512  -0.229
//
//  The truth, that session, was -0.528. So the ball estimate ranged over
//  283 mm, settled 158 mm wrong, and reported 10-15 mm of spread the
//  whole time it was doing it. It is not a bad idea badly
//  implemented; at 2.4-4 m a ball is about sixteen pixels across, so one
//  pixel of box error is six per cent of range, and six per cent of range
//  is three centimetres of cloth. Two or three pixels of systematic
//  looseness in the detector's boxes is all it takes, and there is no
//  amount of averaging that removes a systematic error.
//
//  But the height does not have to be measured at all. It is already
//  DETERMINED, by two things the app has anyway:
//
//  * the tap rays, which are exact — they come from the camera pose and
//    the touch location, neither of which is a guess; and
//  * the table's size, which the user chose from a list of three.
//
//  Rays from one place fan out. Intersect them with a plane too near the
//  camera and the shape they cut is a small copy of the table; too far
//  and it is a large one. Exactly one height makes it 2.24 m by 1.12 m.
//  Everything else follows, so the height is not an input to the
//  calibration at all — it is an OUTPUT of it, on the same footing as the
//  position and the heading, and it comes with a residual that says
//  whether to believe it.
//
//  Solved this way on the same table, from the same taps, two independent
//  pairs of pockets agreed on -0.5275 and -0.5290: 1.5 mm apart, against
//  the ball estimate's 283 mm range.
//
//  It needs no balls, which also removes the awkward instruction to go and
//  put some out before the table can be found.
//
//  ONE THING IT CANNOT DO, and the reason the balls are still worth
//  keeping. Every standard table is exactly twice as long as it is wide —
//  1.98x0.99, 2.34x1.17, 2.54x1.27 — so a nine-foot table's pockets are a
//  uniform SCALING of an eight-foot table's, and moving the plane is
//  exactly a uniform scaling. The two are therefore indistinguishable:
//  solving for the wrong size returns a proportionally wrong height with a
//  residual of zero, confidently. The residual checks the SHAPE, and the
//  shape is right either way.
//
//  So this pins the height GIVEN the size, and nothing about the pockets
//  can confirm the size. The ball estimate, crude as it is, is the only
//  measurement in the app that is independent of that choice — which is
//  what `sizeAgreeingWith` uses it for, and all it should be trusted for.
//

import CueSyncCore
import Foundation

extension PocketCalibration {

    /// A cloth height solved from tapped pockets and the known table size.
    public struct SolvedHeight: Sendable, Equatable {
        /// World Y of the playing surface.
        public var height: Double
        /// Root-mean-square disagreement between the measured pocket
        /// spacings at this height and the real ones, in metres. This is
        /// the number that says whether to believe the height, and it is
        /// meaningful in a way the ball estimate's spread was not: it
        /// compares against a table, not against itself.
        public var residual: Double
        /// How many pocket-to-pocket distances the answer rests on.
        public var spanCount: Int

        public init(height: Double, residual: Double, spanCount: Int) {
            self.height = height
            self.residual = residual
            self.spanCount = spanCount
        }
    }

    public enum HeightFailure: Error, Equatable {
        /// Fewer than two distinct pockets: no distance to compare.
        case needTwoPockets
        /// Every ray was grazing or pointed away from the cloth.
        case raysDoNotMeetTheCloth
        /// The pockets are too close together in the image for their
        /// separation to pin a height down.
        case tooCloseTogether
    }

    /// Search bounds, in metres below the camera.
    ///
    /// A table is not above the device and not four metres below it. The
    /// bounds exist so a pathological set of rays returns a failure rather
    /// than a confident answer at the edge of the search.
    static let heightSearchRange: ClosedRange<Double> = 0.05...2.5

    /// Which standard size puts the cloth nearest to where the balls say
    /// it is, with the height each one implies.
    ///
    /// The one question the pocket geometry cannot answer on its own. It
    /// asks a lot of the ball estimate — the sizes are 8-13 % apart, which
    /// at half a metre of depth is 4-7 cm, and the ball estimate is worth
    /// about +/-15 cm — so this is NOT reliable enough to pick the size
    /// for the user. It is reliable enough to notice a frank
    /// disagreement, which is the useful case: a nine-foot table
    /// calibrated as a seven-foot one is 28 % wrong, and that is far
    /// outside what the balls could confuse.
    public static func sizeAgreeingWith(
        ballHeight: Double,
        rays: [(pocket: PocketID, ray: TapRay)],
        candidates: [TableSize] = [.sevenFoot, .eightFoot, .nineFoot]
    ) -> [(size: TableSize, solved: SolvedHeight, disagreement: Double)] {
        candidates.compactMap { size in
            guard let solved = try? solveHeight(rays: rays, size: size) else { return nil }
            return (size, solved, abs(solved.height - ballHeight))
        }
        .sorted { $0.disagreement < $1.disagreement }
    }

    /// Solve for the plane height that makes the tapped pockets the right
    /// distances apart.
    ///
    /// `rays` are world-space tap rays labelled with the pocket each was
    /// aimed at. Repeated sightings of one pocket are ignored beyond the
    /// first, because a second look at the same hole adds no distance.
    public static func solveHeight(
        rays: [(pocket: PocketID, ray: TapRay)],
        size: TableSize
    ) throws -> SolvedHeight {
        var byPocket: [PocketID: TapRay] = [:]
        for entry in rays where byPocket[entry.pocket] == nil {
            byPocket[entry.pocket] = entry.ray
        }
        guard byPocket.count >= 2 else { throw HeightFailure.needTwoPockets }

        let table = Table(size: size)
        var truth: [PocketID: Vec2] = [:]
        for pocket in table.pockets { truth[pocket.id] = pocket.position }

        let ids = byPocket.keys.sorted { $0.rawValue < $1.rawValue }
        var pairs: [(a: TapRay, b: TapRay, expected: Double)] = []
        for (index, first) in ids.enumerated() {
            for second in ids.dropFirst(index + 1) {
                guard let p = truth[first], let q = truth[second] else { continue }
                pairs.append((byPocket[first]!, byPocket[second]!, (p - q).length))
            }
        }
        guard !pairs.isEmpty else { throw HeightFailure.needTwoPockets }

        // The taps share a camera, so the highest ray origin is the one to
        // measure depth from; using the plane's absolute Y would tie the
        // search to ARKit's origin, which moves every session.
        let cameraY = byPocket.values.map(\.origin.y).max() ?? 0

        /// Total squared error between measured and true spacings.
        func cost(at height: Double) -> Double? {
            var total = 0.0
            var used = 0
            for pair in pairs {
                guard let a = pair.a.intersect(planeHeight: height),
                      let b = pair.b.intersect(planeHeight: height) else { continue }
                let error = (a - b).length - pair.expected
                total += error * error
                used += 1
            }
            return used == pairs.count ? total : nil
        }

        return try search(cameraY: cameraY, spanCount: pairs.count, cost: cost)
    }

    /// The same solve for four CORNER taps, which is what the other
    /// calibration path collects.
    ///
    /// Corners carry no labels — the user taps them in whatever order
    /// suits them — so this compares the SORTED set of the six pairwise
    /// distances against the sorted set a rectangle of that size has:
    /// two widths, two lengths, two diagonals. Sorting makes it
    /// independent of tap order without having to guess an assignment,
    /// and a rectangle's distance multiset determines it up to rigid
    /// motion, so nothing is given away by discarding the order.
    public static func solveHeightForCorners(
        rays: [TapRay],
        size: TableSize
    ) throws -> SolvedHeight {
        guard rays.count == 4 else { throw HeightFailure.needTwoPockets }
        let field = size.playField
        let width: Double = field.width
        let length: Double = field.height
        let diagonal: Double = (width * width + length * length).squareRoot()
        let expected: [Double] = [width, width, length, length, diagonal, diagonal].sorted()

        let cameraY = rays.map(\.origin.y).max() ?? 0
        func cost(at height: Double) -> Double? {
            let points = rays.compactMap { $0.intersect(planeHeight: height) }
            guard points.count == 4 else { return nil }
            var measured: [Double] = []
            for (index, a) in points.enumerated() {
                for b in points.dropFirst(index + 1) { measured.append((a - b).length) }
            }
            measured.sort()
            var total = 0.0
            for (got, want) in zip(measured, expected) {
                let error = got - want
                total += error * error
            }
            return total
        }
        return try search(cameraY: cameraY, spanCount: 6, cost: cost)
    }

    /// Find the height that minimises `cost`, and refuse to report one
    /// when moving the plane barely changes the answer.
    private static func search(cameraY: Double,
                               spanCount: Int,
                               cost: (Double) -> Double?) throws -> SolvedHeight {
        // A coarse sweep, then a golden-section refinement. The cost is
        // a sum of squares in a quantity linear in height, so it is a
        // convex parabola in the shared-origin case and near enough to one
        // otherwise — but the sweep runs first regardless, so a set of rays
        // that is NOT well behaved cannot land the refinement in a local
        // trough far from the answer.
        let steps = 250
        var best: (height: Double, cost: Double)?
        for step in 0...steps {
            let depth = heightSearchRange.lowerBound
                + (heightSearchRange.upperBound - heightSearchRange.lowerBound)
                * Double(step) / Double(steps)
            let height = cameraY - depth
            guard let value = cost(height) else { continue }
            if best == nil || value < best!.cost { best = (height, value) }
        }
        guard var (bestHeight, bestCost) = best else {
            throw HeightFailure.raysDoNotMeetTheCloth
        }

        let coarseStep = (heightSearchRange.upperBound - heightSearchRange.lowerBound)
            / Double(steps)
        var low = bestHeight - coarseStep
        var high = bestHeight + coarseStep
        for _ in 0..<60 {
            let mid = (low + high) / 2
            let probeLow = (low + mid) / 2
            let probeHigh = (mid + high) / 2
            let costLow = cost(probeLow) ?? .infinity
            let costHigh = cost(probeHigh) ?? .infinity
            let costMid = cost(mid) ?? .infinity
            if costLow < costMid { high = mid } else if costHigh < costMid { low = mid } else {
                low = probeLow
                high = probeHigh
            }
            if let value = cost(mid), value < bestCost {
                bestCost = value
                bestHeight = mid
            }
        }

        let residual = (bestCost / Double(spanCount)).squareRoot()

        // A height only means something if moving it CHANGES the answer.
        // Pockets a few pixels apart give rays that stay a few pixels
        // apart at every depth, so the cost barely varies and the minimum
        // is wherever the noise put it. Refuse those rather than return
        // the bottom of a flat trough as if it were a measurement.
        let apart = 0.05
        let sensitivity = [cost(bestHeight + apart), cost(bestHeight - apart)]
            .compactMap { $0 }.min() ?? .infinity
        guard sensitivity - bestCost > 1e-6 else { throw HeightFailure.tooCloseTogether }

        return SolvedHeight(height: bestHeight, residual: residual, spanCount: spanCount)
    }
}
