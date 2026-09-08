//
//  CalibrationCornerLayout.swift
//  CueSyncUI
//
//  Pure screen-space bookkeeping for the calibration corner overlay: which
//  corners are drawable this frame, and whether the four of them still form
//  a closed rectangle worth stroking.
//
//  It exists because the overlay draws each corner TWICE — a felt-green dot
//  in a Canvas, and a white drag handle as a positioned SwiftUI view — and
//  those two passes must agree about which corner is which. The first
//  implementation projected with `compactMap`, which silently drops corners
//  ARKit cannot project (behind the camera, off-frame). Dropping shifts
//  every later index: the dot drawn as "corner 2" became corner 3, while the
//  handle indexed the untouched world array and still meant corner 2. The
//  green dots and the white handles then referred to different corners, and
//  the outline joined the wrong pair.
//
//  Keeping the optionals and indexing THROUGH them makes that class of bug
//  unrepresentable: position i is always corner i, or nothing.
//

import Foundation

/// Screen-space projections of the calibration corners for one frame.
public struct CalibrationCornerLayout: Equatable, Sendable {
    /// One slot per corner, in corner order. `nil` means "not projectable
    /// this frame" — never "this corner does not exist".
    public let points: [CGPoint?]

    public init(points: [CGPoint?]) {
        self.points = points
    }

    /// Corner index paired with its point, skipping the unprojectable ones.
    /// The index is the ORIGINAL corner index, so callers that also address
    /// corners by index (drag handles) stay in agreement.
    public var drawable: [(index: Int, point: CGPoint)] {
        points.enumerated().compactMap { index, point in
            point.map { (index: index, point: $0) }
        }
    }

    /// The point for `index`, or nil if it did not project this frame.
    public func point(at index: Int) -> CGPoint? {
        guard points.indices.contains(index) else { return nil }
        return points[index]
    }

    /// The closed outline, but only when EVERY corner projected. A partial
    /// outline is worse than none: joining the corners that happen to be
    /// visible draws an edge that does not exist on the table, which reads
    /// as a mis-calibration the user then tries to "fix".
    public var closedOutline: [CGPoint]? {
        guard points.count == 4 else { return nil }
        let resolved = points.compactMap { $0 }
        guard resolved.count == 4 else { return nil }
        return resolved
    }
}
