//
//  StandardSizeComparison.swift
//  TableSpace
//
//  T1.2 (measurement truth): after a calibration locks, tell the user how
//  far the measured playing field sits from the nearest standard table so a
//  mis-tapped corner (outer rail instead of cushion nose) is visible
//  immediately instead of surfacing later as overlay offset.
//

import CueSyncCore
import Foundation

/// How a measured playing field relates to the nearest standard table size.
public struct StandardSizeComparison: Sendable, Equatable {
    /// The closest standard size (by worst-axis fractional error).
    public let nearest: TableSize
    /// Measured minus standard, long axis, meters (positive = oversized).
    public let widthDelta: Double
    /// Measured minus standard, short axis, meters.
    public let heightDelta: Double

    /// Compare a measured playing field against the standard sizes. Unlike
    /// `TableSize.inferred`, this never returns nil — display code always
    /// has a nearest size to talk about, however far off the measurement is.
    public init(measuredWidth: Double, measuredHeight: Double) {
        let w = Swift.max(measuredWidth, measuredHeight)
        let h = Swift.min(measuredWidth, measuredHeight)
        var best: (size: TableSize, error: Double)?
        for size in TableSize.standardSizes {
            let field = size.playField
            let error = Swift.max(abs(w - field.width) / field.width,
                                  abs(h - field.height) / field.height)
            if error < (best?.error ?? .infinity) {
                best = (size, error)
            }
        }
        // standardSizes is non-empty by definition; the loop always sets best.
        let nearest = best!.size
        self.nearest = nearest
        self.widthDelta = w - nearest.playField.width
        self.heightDelta = h - nearest.playField.height
    }

    /// Compare a locked calibration's size. For a size that already snapped
    /// to a standard the deltas are zero by construction.
    public init(size: TableSize) {
        let field = size.playField
        self.init(measuredWidth: field.width, measuredHeight: field.height)
    }

    /// Largest per-axis deviation, meters.
    public var maxDelta: Double { Swift.max(abs(widthDelta), abs(heightDelta)) }

    /// Short human string, e.g. "8 ft table" or "8 ft +3.1 cm" — the locked
    /// HUD/mirror line. Deltas under 5 mm read as an exact match.
    public var summary: String {
        let name: String
        switch nearest {
        case .sevenFoot: name = "7 ft"
        case .eightFoot: name = "8 ft"
        case .nineFoot: name = "9 ft"
        case .custom: name = "custom"
        }
        if maxDelta < 0.005 { return "\(name) table" }
        let signedCm = (abs(widthDelta) >= abs(heightDelta) ? widthDelta : heightDelta) * 100
        return String(format: "%@ %+.1f cm", name, signedCm)
    }
}
