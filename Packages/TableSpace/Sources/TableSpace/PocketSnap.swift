//
//  PocketSnap.swift
//  TableSpace
//
//  Refining rough pocket taps to the table's cushion-nose geometry in the
//  camera image.
//
//  Why not the dark hole. The obvious "snap to the dark blob" was tried
//  first on the owner's table (2026-11-11) and is wrong where it matters:
//  seen from the head rail the far pockets are a sliver of their own back
//  wall, and the blob centroid sits 10-15 image points nearer the camera
//  than the mouth, which at that range is 10-15 cm along the table. The
//  shape fit went from 27 to 80 mm rms. The near pockets have leather
//  liners as grey as the cloth, so there is no blob at all.
//
//  What the image does give, sharply, is lines:
//
//  * the RAIL EDGE: bright rail cap against the dark cushion, on all four
//    sides, fitted to a few tenths of a pixel over hundreds of samples;
//  * the CUSHION NOSE: going inward from the rail edge, the lit top of the
//    cushion drops into the shadowed face below the nose. That step is the
//    nose line itself, visible on both long rails and the far end (the
//    near cushion faces away from the camera, so its nose is not).
//
//  The solver wants exactly the nose rectangle: a corner pocket IS the
//  corner where two nose lines meet, and a side pocket IS the middle of
//  the gap between its two cushion jaws on the long nose line. So a corner
//  with two visible nose lines snaps to their intersection, a side pocket
//  snaps to the centre of the jaw gap, and a corner with one visible nose
//  line (the near corners) keeps the tap's position along that line and
//  takes the line's position across it. Anything that fails keeps the raw
//  tap, and every result says which of these it was.
//
//  The features are at cushion-nose height, not cloth height; the
//  calibration path accounts for that (`noseHeight`).
//
//  All coordinates here are camera-image pixels.
//

import CueSyncCore
import Foundation

public enum PocketSnap {
    /// Cushion nose height above the bed, metres: 63.5 % of a 57.15 mm
    /// ball, the middle of the WPA range (62.5-64.5 %).
    public static let noseHeight = 0.0363

    public struct Config: Sendable, Equatable {
        /// How far either side of the tap-to-tap segment to look for the
        /// rail edge, pixels.
        public var railSearch: Double = 50
        /// Smallest bright-minus-dark step accepted as the rail edge.
        public var railContrast: Double = 35
        /// Smallest drop accepted as the cushion nose.
        public var noseContrast: Double = 15
        /// Samples along each side.
        public var samples: Int = 80
        /// Fewest inliers a line needs to be used.
        public var minimumInliers: Int = 24
        /// Worst inlier rms, pixels, a line may have and still be used.
        public var maximumLineRMS: Double = 1.6
        /// A snapped point further than this from its tap is not trusted:
        /// the tap is kept. Pixels.
        public var maximumShift: Double = 70

        public init() {}
    }

    public enum Method: String, Sendable, Equatable {
        /// Intersection of two cushion-nose lines.
        case noseCorner
        /// Middle of the jaw gap on a long cushion-nose line.
        case jawGap
        /// The tap moved perpendicularly onto one cushion-nose line.
        case ontoNose
        /// Nothing usable was found; the tap as given.
        case raw
    }

    public struct Result: Sendable, Equatable {
        public var pocket: PocketID
        public var tap: Vec2
        public var point: Vec2
        public var method: Method
        /// Distance from the tap, pixels.
        public var shift: Double { tap.distance(to: point) }
    }

    /// A fitted image line.
    public struct Line: Sendable, Equatable {
        public var point: Vec2
        /// Unit direction.
        public var direction: Vec2
        public var rms: Double
        public var inliers: Int

        public func distance(_ p: Vec2) -> Double { (p - point).cross(direction) }

        public func project(_ p: Vec2) -> Vec2 {
            point + direction * (p - point).dot(direction)
        }

        public func intersect(_ other: Line) -> Vec2? {
            let denominator = direction.cross(other.direction)
            guard abs(denominator) > 1e-6 else { return nil }
            let t = (other.point - point).cross(other.direction) / denominator
            return point + direction * t
        }
    }

    /// The four sides, as (from, to, side pocket on it).
    static let sides: [(PocketID, PocketID, PocketID?)] = [
        (.cornerTopLeft, .cornerTopRight, .sideTop),
        (.cornerTopRight, .cornerBottomRight, nil),
        (.cornerBottomRight, .cornerBottomLeft, .sideBottom),
        (.cornerBottomLeft, .cornerTopLeft, nil)
    ]

    /// Refine pocket taps. Needs all four corner taps to know where the
    /// rails run; without them every tap comes back `.raw`.
    public static func refine(_ image: LumaImage,
                              taps: [PocketID: Vec2],
                              config: Config = Config()) -> [PocketID: Result] {
        var results: [PocketID: Result] = [:]
        for (pocket, tap) in taps {
            results[pocket] = Result(pocket: pocket, tap: tap, point: tap, method: .raw)
        }
        let cornerIDs: [PocketID] = [.cornerTopLeft, .cornerTopRight,
                                     .cornerBottomRight, .cornerBottomLeft]
        let corners = cornerIDs.compactMap { taps[$0] }
        guard corners.count == 4 else { return results }
        let centre = corners.reduce(Vec2.zero, +) / 4
        let noses = noseLines(image, taps: taps, config: config)
        func usable(_ index: Int) -> Line? {
            guard let line = noses[index], line.inliers >= config.minimumInliers,
                  line.rms <= config.maximumLineRMS else { return nil }
            return line
        }
        func accept(_ pocket: PocketID, _ point: Vec2?, _ method: Method) {
            guard let tap = taps[pocket], let point, tap.distance(to: point) <= config.maximumShift
            else { return }
            results[pocket] = Result(pocket: pocket, tap: tap, point: point, method: method)
        }
        // Corner i sits between side i-1 and side i.
        for (index, pocket) in cornerIDs.enumerated() {
            let before = usable((index + 3) % 4)
            let after = usable(index)
            guard let tap = taps[pocket] else { continue }
            if let before, let after {
                accept(pocket, before.intersect(after), .noseCorner)
            } else if let line = before ?? after {
                accept(pocket, line.project(tap), .ontoNose)
            }
        }
        for (index, side) in sides.enumerated() {
            guard let pocket = side.2, let tap = taps[pocket], let line = usable(index) else { continue }
            if let gap = jawGapCentre(image, nose: line, near: tap, centre: centre) {
                accept(pocket, gap, .jawGap)
            } else {
                accept(pocket, line.project(tap), .ontoNose)
            }
        }
        return results
    }

    /// What a person looking at the screen calls a pocket: "far-left
    /// corner", "right side pocket". From where the taps sit in the image
    /// (up the screen is far), so it matches what the user sees whatever
    /// the table's own labels are.
    public static func viewName(_ pocket: PocketID, taps: [PocketID: Vec2]) -> String {
        guard let point = taps[pocket], taps.count > 1 else { return pocket.rawValue }
        let centre = taps.values.reduce(Vec2.zero, +) / Double(taps.count)
        let lateral = point.x < centre.x ? "left" : "right"
        switch pocket {
        case .sideTop, .sideBottom:
            return "\(lateral) side pocket"
        default:
            return "\(point.y < centre.y ? "far" : "near")-\(lateral) corner"
        }
    }

    // MARK: - Lines

    /// The cushion-nose line of each side (TL-TR, TR-BR, BR-BL, BL-TL),
    /// nil where none was found. Needs the four corner taps.
    public static func noseLines(_ image: LumaImage, taps: [PocketID: Vec2],
                                 config: Config = Config()) -> [Line?] {
        sideLines(image, taps: taps, config: config).map(\.nose)
    }

    /// Rail-edge and cushion-nose line of each side, for diagnostics.
    public static func sideLines(_ image: LumaImage, taps: [PocketID: Vec2],
                                 config: Config = Config()) -> [(rail: Line?, nose: Line?)] {
        let corners = [PocketID.cornerTopLeft, .cornerTopRight, .cornerBottomRight, .cornerBottomLeft]
            .compactMap { taps[$0] }
        guard corners.count == 4 else { return Array(repeating: (nil, nil), count: 4) }
        let centre = corners.reduce(Vec2.zero, +) / 4
        return sides.map { from, to, _ in
            guard let a = taps[from], let b = taps[to],
                  let rail = railEdge(image, from: a, to: b, centre: centre, config: config) else { return (nil, nil) }
            return (rail, noseLine(image, rail: rail, segment: (a, b), centre: centre, config: config))
        }
    }

    /// Outward unit normal of the segment a->b: pointing away from `centre`.
    static func outwardNormal(_ a: Vec2, _ b: Vec2, centre: Vec2) -> (along: Vec2, out: Vec2)? {
        let span = b - a
        guard span.length > 1 else { return nil }
        let along = span.normalized
        var out = Vec2(-along.y, along.x)
        if ((a + b) / 2 - centre).dot(out) < 0 { out = Vec2(-out.x, -out.y) }
        return (along, out)
    }

    /// The rail edge between two corner taps: the strongest step from dark
    /// (inside) to bright (outside) across the segment, fitted robustly.
    static func railEdge(_ image: LumaImage, from a: Vec2, to b: Vec2,
                         centre: Vec2, config: Config) -> Line? {
        guard let frame = outwardNormal(a, b, centre: centre) else { return nil }
        let length = a.distance(to: b)
        var points: [Vec2] = []
        for k in 0..<config.samples {
            let t = 0.06 + 0.88 * Double(k) / Double(max(config.samples - 1, 1))
            let base = a + frame.along * (length * t)
            let profile = stride(from: -config.railSearch, through: config.railSearch, by: 0.5).map { s in
                (s, step(image, at: base + frame.out * s, normal: frame.out, along: frame.along))
            }
            if let s = strongestStep(profile, minimum: config.railContrast) {
                points.append(base + frame.out * s)
            }
        }
        return robustLine(points, minimum: config.minimumInliers)
    }

    /// The cushion nose: inward from the rail edge, the strongest drop from
    /// the lit cushion top into the shadowed face below it.
    static func noseLine(_ image: LumaImage, rail: Line, segment: (from: Vec2, to: Vec2),
                         centre: Vec2, config: Config) -> Line? {
        let (a, b) = segment
        guard let frame = outwardNormal(a, b, centre: centre) else { return nil }
        var inward = Vec2(-rail.direction.y, rail.direction.x)
        if inward.dot(frame.out) > 0 { inward = Vec2(-inward.x, -inward.y) }
        let length = a.distance(to: b)
        let reach = min(max(length * 0.12, 20), 150)
        var points: [Vec2] = []
        for k in 0..<config.samples {
            let t = 0.06 + 0.88 * Double(k) / Double(max(config.samples - 1, 1))
            let foot = rail.project(a + frame.along * (length * t))
            // Start past the rail edge's own step, which is blurred over a
            // few pixels and is far stronger than the nose: the first point
            // below halfway from the rail cap to the cushion, plus margin.
            func level(_ s: Double) -> Double? { image.mean(at: foot + inward * s, along: rail.direction) }
            let interior = stride(from: 4.0, through: reach, by: 1).compactMap(level).sorted()
            guard let railLevel = level(-4), !interior.isEmpty else { continue }
            let halfway = (railLevel + interior[interior.count / 2]) / 2
            guard let edgeEnd = stride(from: 0.0, through: reach, by: 0.5)
                .first(where: { (level($0) ?? .infinity) < halfway }) else { continue }
            let start = edgeEnd + 4
            guard start < reach - 4 else { continue }
            let profile = stride(from: start, through: reach, by: 0.5).map { s in
                (s, step(image, at: foot + inward * s, normal: inward * -1, along: rail.direction))
            }
            if let s = strongestStep(profile, minimum: config.noseContrast) {
                points.append(foot + inward * s)
            }
        }
        return robustLine(points, minimum: config.minimumInliers)
    }

    /// Brightness on the `normal` side minus the other side, 2 px out.
    static func step(_ image: LumaImage, at p: Vec2, normal: Vec2, along: Vec2) -> Double? {
        guard let outside = image.mean(at: p + normal * 2, along: along),
              let inside = image.mean(at: p - normal * 2, along: along) else { return nil }
        return outside - inside
    }

    /// Position of the largest step, refined with a parabola through its
    /// neighbours; nil when the largest is below `minimum`.
    static func strongestStep(_ profile: [(Double, Double?)], minimum: Double) -> Double? {
        var best: Int?
        for (index, entry) in profile.enumerated() {
            guard let value = entry.1 else { continue }
            if best == nil || value > (profile[best!].1 ?? -.infinity) { best = index }
        }
        guard let index = best, let peak = profile[index].1, peak >= minimum else { return nil }
        guard index > 0, index + 1 < profile.count,
              let left = profile[index - 1].1, let right = profile[index + 1].1 else {
            return profile[index].0
        }
        let curvature = left - 2 * peak + right
        let spacing = profile[index + 1].0 - profile[index].0
        guard curvature < -1e-9 else { return profile[index].0 }
        let offset = 0.5 * (left - right) / curvature
        return profile[index].0 + max(-0.5, min(0.5, offset)) * spacing
    }

    /// Consensus line: the line through two of the points that most others
    /// lie within `consensus` px of (every pair tried, so deterministic),
    /// then total least squares with iterative rejection at 2.5 robust
    /// sigmas (never tighter than 0.8 px). The consensus step is what keeps
    /// a second edge (a ball, the cue, a shadow) from dragging the fit.
    static func robustLine(_ points: [Vec2], minimum: Int, consensus: Double = 1.5) -> Line? {
        guard points.count >= minimum else { return nil }
        var seed: (count: Int, line: Line)?
        for i in points.indices {
            for j in points.indices where j > i + 2 {
                let span = points[j] - points[i]
                guard span.length > 1 else { continue }
                let trial = Line(point: points[i], direction: span.normalized, rms: 0, inliers: 0)
                let count = points.reduce(0) { $0 + (abs(trial.distance($1)) <= consensus ? 1 : 0) }
                if count > (seed?.count ?? 0) { seed = (count, trial) }
            }
        }
        guard let seed, seed.count >= minimum,
              var line = fitLine(points.filter { abs(seed.line.distance($0)) <= consensus }) else { return nil }
        var kept = points
        for _ in 0..<5 {
            let deviations = points.map { abs(line.distance($0)) }.sorted()
            let tolerance = min(2 * consensus, max(0.8, 2.5 * 1.4826 * deviations[deviations.count / 2]))
            kept = points.filter { abs(line.distance($0)) <= tolerance }
            guard kept.count >= minimum, let refit = fitLine(kept) else { return nil }
            line = refit
        }
        let rms = (kept.map { line.distance($0) * line.distance($0) }.reduce(0, +)
                   / Double(kept.count)).squareRoot()
        line.rms = rms
        line.inliers = kept.count
        return line
    }

    static func fitLine(_ points: [Vec2]) -> Line? {
        guard points.count >= 2 else { return nil }
        let mean = points.reduce(Vec2.zero, +) / Double(points.count)
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in points {
            let d = p - mean
            sxx += d.x * d.x
            syy += d.y * d.y
            sxy += d.x * d.y
        }
        let angle = 0.5 * atan2(2 * sxy, sxx - syy)
        return Line(point: mean, direction: Vec2(cos(angle), sin(angle)), rms: 0, inliers: points.count)
    }

    // MARK: - Side pockets

    /// Centre of the gap between a side pocket's two cushion jaws: along
    /// the nose line, just outside it on the cushion top, the pocket mouth
    /// is a dark run in an otherwise lit strip. The run nearest the tap
    /// (wider runs preferred) is the mouth.
    static func jawGapCentre(_ image: LumaImage, nose: Line, near tap: Vec2, centre: Vec2) -> Vec2? {
        var out = Vec2(-nose.direction.y, nose.direction.x)
        if (nose.point - centre).dot(out) < 0 { out = Vec2(-out.x, -out.y) }
        let t0 = (tap - nose.point).dot(nose.direction)
        var profile: [(t: Double, v: Double)] = []
        for k in -160...160 {
            let t = t0 + Double(k) * 0.5
            let p = nose.point + nose.direction * t
            let values = [3.0, 4, 5, 6, 7].compactMap { image.sample(p + out * $0) }
            guard !values.isEmpty else { continue }
            profile.append((t, values.reduce(0, +) / Double(values.count)))
        }
        guard profile.count > 40 else { return nil }
        let sorted = profile.map(\.v).sorted()
        let low = sorted[sorted.count / 20]
        let middle = sorted[sorted.count / 2]
        guard middle - low > 12 else { return nil }
        let threshold = (low + middle) / 2
        var runs: [(Double, Double)] = []
        var start: Double?
        var last = 0.0
        for entry in profile {
            if entry.v < threshold {
                if start == nil { start = entry.t }
                last = entry.t
            } else if let begun = start {
                runs.append((begun, last))
                start = nil
            }
        }
        if let begun = start { runs.append((begun, last)) }
        let candidates = runs.filter { $0.1 - $0.0 >= 3 }
        guard let best = candidates.min(by: { score($0, t0) < score($1, t0) }) else { return nil }
        // A run touching the end of the scan is not a gap whose middle we know.
        guard best.0 > profile.first!.t, best.1 < profile.last!.t else { return nil }
        return nose.point + nose.direction * ((best.0 + best.1) / 2)
    }

    private static func score(_ run: (Double, Double), _ t0: Double) -> Double {
        abs((run.0 + run.1) / 2 - t0) - 0.2 * (run.1 - run.0)
    }
}
