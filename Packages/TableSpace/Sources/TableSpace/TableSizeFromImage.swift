//
//  TableSizeFromImage.swift
//  TableSpace
//
//  Which standard table is this? Answered in the image, with a ball laid
//  across the table as the ruler.
//
//  The depth ruler (TableSizeFromBalls) compares a cloth depth from the
//  balls' apparent size with the depth the pocket geometry implies. Its
//  weak link is the detector box: a ball is 30-40 px across, a box a few
//  pixels loose is 10 % of range, and on 2026-11-11 the same table read 8 ft
//  on one lock and 7 ft on the next. The tilt of the plane enters too.
//
//  This ruler needs no depth and no box size. At one image row, a ball and
//  the table are at (almost) the same distance, so their widths in pixels
//  are in the ratio of their widths in metres:
//
//      tableWidth = chord(row) / ballWidth(row) * 57.15 mm
//
//  where `chord` is the distance between the two long cushion-nose lines
//  (PocketSnap) along that row and `ballWidth` is the ball's own measured
//  silhouette, half-maximum to half-maximum. Measured by hand on the
//  owner's table: chord 657.7 px, ball 33 px, so 1.14 m: 8 ft (1.17 m),
//  not 7 ft (0.99 m) or 9 ft (1.27 m).
//
//  One small correction: the ball's centre sits 28.6 mm above the cloth and
//  the nose 36.3 mm, so the nose line on the ball's row is a little nearer
//  than the ball. The caller passes that range ratio (it needs the ray's
//  depression angle, which the image alone does not know).
//

import CueSyncCore
import Foundation

public enum TableSizeFromImage {
    /// One ball to measure.
    public struct Ball: Sendable, Equatable {
        /// Silhouette centre, image px.
        public var centre: Vec2
        /// Rough radius, image px (half the detection box).
        public var radius: Double
        /// Range to the nose line on this ball's row divided by range to
        /// the ball (slightly below 1). 1 when unknown.
        public var noseRangeRatio: Double

        public init(centre: Vec2, radius: Double, noseRangeRatio: Double = 1) {
            self.centre = centre
            self.radius = radius
            self.noseRangeRatio = noseRangeRatio
        }
    }

    public struct Estimate: Sendable, Equatable {
        /// Playing-field width (nose to nose across the table), metres.
        public var width: Double
        /// One-sigma uncertainty of `width`, metres.
        public var uncertainty: Double
        /// Balls that produced a measurement.
        public var samples: Int
        /// The size verdict, on length = 2 x width.
        public var verdict: TableSizeFromBalls
        /// Every ball's own width estimate, metres, outliers included.
        public var perBall: [Double] = []

        public var summary: String {
            let name = switch verdict.nearest {
            case .sevenFoot: "7 ft"
            case .eightFoot: "8 ft"
            case .nineFoot: "9 ft"
            default: "custom"
            }
            let each = perBall.map { String(format: "%.3f", $0) }.joined(separator: " ")
            return String(format: "image says %.3f +/- %.3f m wide from %d balls (%@): %@%@", width, uncertainty,
                          samples, each, name, verdict.isDecisive ? "" : " (not decisive)")
        }
    }

    /// Smallest ball-to-cloth contrast measured, 8-bit levels. Only the
    /// light balls (white, yellow, orange) clear it on black cloth. Red and
    /// blue did not on the owner's table: darker towards the edge, their
    /// half-maximum width came out 10-20 % narrow (a table 1.25-1.38 m
    /// wide, against 1.12-1.14 m from the light balls in the same frame).
    public static let minimumContrast = 80.0
    /// Floor on the relative uncertainty: a ball's edge is worth about
    /// half a pixel at each side of a 30-40 px silhouette.
    public static let relativeFloor = 0.012

    /// Estimate the size from balls between two long nose lines.
    ///
    /// - Parameters:
    ///   - across: image direction of a line across the table (the far
    ///     end's nose line, or the near rail edge). Widths are measured along
    ///     it.
    public static func estimate(_ image: LumaImage, leftNose: PocketSnap.Line,
                                rightNose: PocketSnap.Line, across: Vec2,
                                balls: [Ball]) -> Estimate? {
        guard across.length > 1e-9 else { return nil }
        let u = across.normalized
        var widths: [Double] = []
        for ball in balls {
            let row = PocketSnap.Line(point: ball.centre, direction: u, rms: 0, inliers: 0)
            guard let a = row.intersect(leftNose), let b = row.intersect(rightNose),
                  let pixels = ballWidth(image, centre: ball.centre, radius: ball.radius, along: u)
            else { continue }
            // The ball must be on the table, between the nose lines.
            let t = (ball.centre - a).dot(b - a) / max((b - a).dot(b - a), 1e-9)
            guard t > 0.02, t < 0.98 else { continue }
            widths.append(a.distance(to: b) / pixels * Ball.diameter * ball.noseRangeRatio)
        }
        guard widths.count >= 2 else { return nil }
        let sorted = widths.sorted()
        let median = sorted[sorted.count / 2]
        let deviations = sorted.map { abs($0 - median) }.sorted()
        let mad = deviations[deviations.count / 2] * 1.4826
        let kept = sorted.filter { abs($0 - median) <= max(3 * mad, median * 0.04) }
        let width = kept.reduce(0, +) / Double(kept.count)
        let spread = (kept.map { ($0 - width) * ($0 - width) }.reduce(0, +)
                      / Double(max(kept.count - 1, 1))).squareRoot()
        let sigma = max(spread / Double(kept.count).squareRoot(), width * relativeFloor)
        let verdict = TableSizeFromBalls.classify(impliedLength: 2 * width, uncertainty: 2 * sigma)
        return Estimate(width: width, uncertainty: sigma, samples: kept.count, verdict: verdict, perBall: widths)
    }

    /// A ball's silhouette width along `u`, image px: the widest of a few
    /// chords near its centre, each from half-maximum to half-maximum.
    /// Nil when the ball does not stand out from the cloth.
    public static func ballWidth(_ image: LumaImage, centre: Vec2, radius: Double, along u: Vec2) -> Double? {
        guard radius >= 3 else { return nil }
        let u = u.normalized
        let v = Vec2(-u.y, u.x)
        var best: Double?
        let reach = radius * 2.2
        for k in -3...3 {
            let rowCentre = centre + v * (Double(k) * radius * 0.12)
            var samples: [(s: Double, value: Double)] = []
            for s in stride(from: -reach, through: reach, by: 0.5) {
                guard let value = image.mean(at: rowCentre + u * s, along: v, halfCount: 1) else { return nil }
                samples.append((s, value))
            }
            let outer = samples.filter { abs($0.s) > radius * 1.6 }.map(\.value).sorted()
            let inner = samples.filter { abs($0.s) < radius * 0.5 }.map(\.value).sorted()
            guard !outer.isEmpty, !inner.isEmpty else { continue }
            let background = outer[outer.count / 2]
            let plateau = inner[inner.count / 2]
            guard plateau - background >= minimumContrast else { continue }
            let level = (background + plateau) / 2
            guard let left = crossing(samples, level: level, outward: -1),
                  let right = crossing(samples, level: level, outward: 1) else { continue }
            let width = right - left
            if width > (best ?? 0) { best = width }
        }
        return best
    }

    /// Where the profile first falls below `level` going out from s = 0,
    /// interpolated between samples.
    static func crossing(_ samples: [(s: Double, value: Double)], level: Double, outward: Double) -> Double? {
        let ordered = samples.filter { $0.s * outward >= 0 }.sorted { abs($0.s) < abs($1.s) }
        guard ordered.count > 1, ordered[0].value > level else { return nil }
        for index in 1..<ordered.count where ordered[index].value <= level {
            let a = ordered[index - 1]
            let b = ordered[index]
            let fraction = (a.value - level) / max(a.value - b.value, 1e-9)
            return a.s + (b.s - a.s) * fraction
        }
        return nil
    }
}

extension TableSizeFromImage.Ball {
    /// Standard pool ball diameter, metres.
    public static let diameter = 0.05715
}
