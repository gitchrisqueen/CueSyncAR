//
//  Homography2D.swift
//  TableSpace
//
//  A plane-to-plane projective map: image points to table coordinates.
//
//  For a camera that does not move, the image of the cloth plane and the
//  table are related by one fixed 3x3 homography, and it needs no camera
//  pose at all: four pocket sightings in the image and where those pockets
//  are on the table determine it. That makes it the drift-immune reference
//  for a parked device (see ParkedPoseHold and
//  docs/plans/2026-11-11-calibration-drift-plan.md): the ARKit path maps a
//  ball pixel to the table through the camera pose, and when the pose
//  drifts so does the ball; this path maps the same pixel through the
//  pockets, and the pockets do not move.
//
//  The same map is in Tools/VideoReplay (from four corners); this one takes
//  four or more points, so the side pockets add redundancy and a residual.
//

import CueSyncCore
import Foundation

public struct Homography2D: Sendable, Equatable {
    /// Row-major 3x3, normalised so the last element is 1.
    public var m: [Double]

    public init(m: [Double]) {
        precondition(m.count == 9, "a homography has nine elements")
        self.m = m
    }

    public enum Failure: Error, Equatable {
        case needFourPoints
        /// The points are collinear (or nearly), so no plane map exists.
        case degenerate
    }

    /// Map a point. Nil when the point maps to infinity (it is on the
    /// image's horizon line for this plane).
    public func apply(_ p: Vec2) -> Vec2? {
        let w = m[6] * p.x + m[7] * p.y + m[8]
        guard abs(w) > 1e-12 else { return nil }
        return Vec2((m[0] * p.x + m[1] * p.y + m[2]) / w,
                    (m[3] * p.x + m[4] * p.y + m[5]) / w)
    }

    /// Least-squares fit from `source` to `target` (h33 fixed to 1),
    /// with Hartley normalisation of both point sets so pixel-sized and
    /// metre-sized coordinates condition the same.
    public static func fit(from source: [Vec2], to target: [Vec2]) throws -> Homography2D {
        guard source.count == target.count, source.count >= 4 else { throw Failure.needFourPoints }
        let (ts, sn) = normaliser(source)
        let (tt, tn) = normaliser(target)
        // Normal equations of the 2n x 8 DLT system.
        var ata = [Double](repeating: 0, count: 64)
        var atb = [Double](repeating: 0, count: 8)
        for (s, t) in zip(sn, tn) {
            let rows: [([Double], Double)] = [
                ([s.x, s.y, 1, 0, 0, 0, -s.x * t.x, -s.y * t.x], t.x),
                ([0, 0, 0, s.x, s.y, 1, -s.x * t.y, -s.y * t.y], t.y)
            ]
            for (row, rhs) in rows {
                for i in 0..<8 {
                    atb[i] += row[i] * rhs
                    for j in 0..<8 { ata[i * 8 + j] += row[i] * row[j] }
                }
            }
        }
        guard let h = solve(ata, atb, n: 8) else { throw Failure.degenerate }
        let normalised = h + [1]
        // H = Tt^-1 * Hn * Ts
        let full = multiply(multiply(invertSimilarity(tt), normalised), ts)
        guard abs(full[8]) > 1e-12 else { throw Failure.degenerate }
        return Homography2D(m: full.map { $0 / full[8] })
    }

    /// Root-mean-square distance between mapped sources and targets.
    public func residual(from source: [Vec2], to target: [Vec2]) -> Double {
        let errors = zip(source, target).map { s, t -> Double in
            guard let p = apply(s) else { return .infinity }
            return p.distance(to: t)
        }
        guard !errors.isEmpty else { return 0 }
        return sqrt(errors.map { $0 * $0 }.reduce(0, +) / Double(errors.count))
    }

    /// Image (or view) points of pocket sightings to table coordinates.
    public static func fitPockets(_ sightings: [(pocket: PocketID, image: Vec2)],
                                  size: TableSize) throws -> Homography2D {
        let layout = Dictionary(uniqueKeysWithValues: Table(size: size).pockets.map { ($0.id, $0.position) })
        var source: [Vec2] = []
        var target: [Vec2] = []
        for sighting in sightings {
            guard let position = layout[sighting.pocket] else { continue }
            source.append(sighting.image)
            target.append(position)
        }
        return try fit(from: source, to: target)
    }

    // MARK: - Linear algebra helpers

    /// Similarity that moves the centroid to the origin and the mean
    /// distance to sqrt(2), as a row-major 3x3, plus the moved points.
    static func normaliser(_ points: [Vec2]) -> ([Double], [Vec2]) {
        let n = Double(points.count)
        let cx = points.map(\.x).reduce(0, +) / n
        let cy = points.map(\.y).reduce(0, +) / n
        let mean = points.map { Vec2($0.x - cx, $0.y - cy).length }.reduce(0, +) / n
        let s = mean > 1e-12 ? 2.0.squareRoot() / mean : 1
        let t = [s, 0, -s * cx, 0, s, -s * cy, 0, 0, 1]
        return (t, points.map { Vec2(($0.x - cx) * s, ($0.y - cy) * s) })
    }

    static func invertSimilarity(_ t: [Double]) -> [Double] {
        let s = t[0]
        return [1 / s, 0, -t[2] / s, 0, 1 / s, -t[5] / s, 0, 0, 1]
    }

    static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: 9)
        for r in 0..<3 {
            for c in 0..<3 {
                var sum = 0.0
                for k in 0..<3 { sum += a[r * 3 + k] * b[k * 3 + c] }
                out[r * 3 + c] = sum
            }
        }
        return out
    }

    /// Gaussian elimination with partial pivoting; nil when singular.
    static func solve(_ matrix: [Double], _ rhs: [Double], n: Int) -> [Double]? {
        var a = matrix
        var b = rhs
        for col in 0..<n {
            var pivot = col
            for row in col..<n where abs(a[row * n + col]) > abs(a[pivot * n + col]) { pivot = row }
            guard abs(a[pivot * n + col]) > 1e-10 else { return nil }
            if pivot != col {
                for k in 0..<n { a.swapAt(col * n + k, pivot * n + k) }
                b.swapAt(col, pivot)
            }
            for row in (col + 1)..<n {
                let f = a[row * n + col] / a[col * n + col]
                guard f != 0 else { continue }
                for k in col..<n { a[row * n + k] -= f * a[col * n + k] }
                b[row] -= f * b[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<n { sum -= a[row * n + k] * x[k] }
            x[row] = sum / a[row * n + row]
        }
        return x
    }
}
