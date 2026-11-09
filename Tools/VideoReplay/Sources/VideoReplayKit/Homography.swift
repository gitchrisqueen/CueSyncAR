//
//  Homography.swift
//  CueSync AR
//
//  Pure 2D projective map between the image plane (pixels, top-left origin)
//  and the cloth plane (table space, meters). Solved from four point pairs
//  (the marked cushion corners vs. the playing-field rectangle), so it needs
//  no camera intrinsics: this is what stands in for PlaneGeometryRaycaster
//  when the input is plain video.
//

import CueSyncCore
import Foundation

public struct Homography: Sendable, Equatable {
    /// Row-major 3x3 matrix, so (x, y, 1) maps to (u, v, w) and the result
    /// is (u / w, v / w).
    public let matrix: [Double]

    public init(matrix: [Double]) {
        precondition(matrix.count == 9, "Homography needs 9 entries")
        self.matrix = matrix
    }

    /// Solves the homography taking each `source[i]` to `destination[i]`.
    /// Returns nil for fewer/more than four pairs or a degenerate layout
    /// (three collinear points make the system singular).
    public init?(from source: [Vec2], to destination: [Vec2]) {
        guard source.count == 4, destination.count == 4 else { return nil }
        // Unknowns h0..h7 (h8 fixed to 1); two equations per pair.
        var system = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for index in 0..<4 {
            let (x, y) = (source[index].x, source[index].y)
            let (u, v) = (destination[index].x, destination[index].y)
            system[2 * index] = [x, y, 1, 0, 0, 0, -x * u, -y * u, u]
            system[2 * index + 1] = [0, 0, 0, x, y, 1, -x * v, -y * v, v]
        }
        guard let solution = Homography.solve(system) else { return nil }
        self.init(matrix: solution + [1])
    }

    /// Maps a point; nil when it lies on the line sent to infinity.
    public func apply(_ point: Vec2) -> Vec2? {
        let m = matrix
        let w = m[6] * point.x + m[7] * point.y + m[8]
        guard abs(w) > 1e-12 else { return nil }
        return Vec2((m[0] * point.x + m[1] * point.y + m[2]) / w,
                    (m[3] * point.x + m[4] * point.y + m[5]) / w)
    }

    /// The inverse map, nil when the matrix is singular.
    public var inverse: Homography? {
        let m = matrix
        let cofactors = [
            m[4] * m[8] - m[5] * m[7], m[2] * m[7] - m[1] * m[8], m[1] * m[5] - m[2] * m[4],
            m[5] * m[6] - m[3] * m[8], m[0] * m[8] - m[2] * m[6], m[2] * m[3] - m[0] * m[5],
            m[3] * m[7] - m[4] * m[6], m[1] * m[6] - m[0] * m[7], m[0] * m[4] - m[1] * m[3],
        ]
        let determinant = m[0] * cofactors[0] + m[1] * cofactors[3] + m[2] * cofactors[6]
        guard abs(determinant) > 1e-18 else { return nil }
        return Homography(matrix: cofactors.map { $0 / determinant })
    }

    /// Gauss-Jordan elimination with partial pivoting on an augmented
    /// n x (n+1) system; nil when a pivot vanishes.
    private static func solve(_ augmented: [[Double]]) -> [Double]? {
        var a = augmented
        let n = a.count
        for column in 0..<n {
            guard let pivot = (column..<n).max(by: { abs(a[$0][column]) < abs(a[$1][column]) }),
                  abs(a[pivot][column]) > 1e-12 else { return nil }
            a.swapAt(column, pivot)
            for row in 0..<n where row != column {
                let factor = a[row][column] / a[column][column]
                if factor == 0 { continue }
                for k in column...n { a[row][k] -= factor * a[column][k] }
            }
        }
        return (0..<n).map { a[$0][n] / a[$0][$0] }
    }
}
