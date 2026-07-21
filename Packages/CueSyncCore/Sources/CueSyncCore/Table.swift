//
//  Table.swift
//  CueSyncCore
//
//  Billiards table geometry in table space: a 2D coordinate system on the
//  cloth plane, origin at the center of the playing field, x along the long
//  axis, y along the short axis, meters.
//

import Foundation

/// Table sizes, identified by their playing-field dimensions (cushion nose
/// to cushion nose). The standard cases follow WPA/BCA equipment specs;
/// `custom` carries dimensions measured at calibration time — real venues
/// have odd cuts, covered rails, and worn cloth, and calibration must not
/// refuse to lock over them (measured geometry beats a forced snap).
public enum TableSize: Sendable, Codable, Equatable, Hashable {
    case sevenFoot
    case eightFoot
    case nineFoot
    /// Non-standard playing field (width = long axis, meters).
    case custom(width: Double, height: Double)

    /// The standard sizes, e.g. for pickers and snap inference.
    public static let standardSizes: [TableSize] = [.sevenFoot, .eightFoot, .nineFoot]

    /// Playing field (width along x, height along y), meters.
    public var playField: (width: Double, height: Double) {
        switch self {
        case .sevenFoot: (1.98, 0.99)
        case .eightFoot: (2.34, 1.17)
        case .nineFoot: (2.54, 1.27)
        case .custom(let width, let height): (width, height)
        }
    }

    /// Snap a measured playing field to the nearest STANDARD size, if the
    /// measurement is within `tolerance` (fractional, e.g. 0.05 = 5%) of
    /// it. Returns nil (never `.custom`) when nothing is close enough —
    /// callers decide whether to fall back to `.custom`.
    public static func inferred(width: Double, height: Double,
                                tolerance: Double = 0.05) -> TableSize? {
        // Normalize orientation: long side is width.
        let w = Swift.max(width, height)
        let h = Swift.min(width, height)
        var best: (size: TableSize, error: Double)?
        for size in standardSizes {
            let f = size.playField
            let error = Swift.max(abs(w - f.width) / f.width, abs(h - f.height) / f.height)
            if error <= tolerance, error < (best?.error ?? .infinity) {
                best = (size, error)
            }
        }
        return best?.size
    }
}

public enum PocketID: String, Sendable, Codable, CaseIterable {
    case cornerTopLeft, cornerTopRight
    case cornerBottomLeft, cornerBottomRight
    case sideTop, sideBottom
}

public struct Pocket: Sendable, Equatable, Codable, Identifiable {
    public var id: PocketID
    /// Pocket mouth center in table space.
    public var position: Vec2
    /// A moving ball whose center passes within this distance of `position`
    /// is considered captured. Approximates real mouth geometry for the MVP.
    public var captureRadius: Double

    public init(id: PocketID, position: Vec2, captureRadius: Double) {
        self.id = id
        self.position = position
        self.captureRadius = captureRadius
    }
}

public struct Table: Sendable, Equatable, Codable {
    public var size: TableSize
    public var pockets: [Pocket]

    /// Default capture radii (m), approximating WPA mouth widths. The corner
    /// value exceeds ballRadius·√5 ≈ 0.064 so a ball aimed straight at the
    /// corner enters the capture circle before the cushion-reflection line
    /// (the real mouth center sits outside the rail rectangle, in the jaw).
    public static let cornerCaptureRadius = 0.075
    public static let sideCaptureRadius = 0.058

    public init(size: TableSize,
                cornerCaptureRadius: Double = Table.cornerCaptureRadius,
                sideCaptureRadius: Double = Table.sideCaptureRadius) {
        self.size = size
        let (w, h) = size.playField
        let hx = w / 2
        let hy = h / 2
        self.pockets = [
            Pocket(id: .cornerTopLeft, position: Vec2(-hx, hy), captureRadius: cornerCaptureRadius),
            Pocket(id: .cornerTopRight, position: Vec2(hx, hy), captureRadius: cornerCaptureRadius),
            Pocket(id: .cornerBottomLeft, position: Vec2(-hx, -hy), captureRadius: cornerCaptureRadius),
            Pocket(id: .cornerBottomRight, position: Vec2(hx, -hy), captureRadius: cornerCaptureRadius),
            Pocket(id: .sideTop, position: Vec2(0, hy), captureRadius: sideCaptureRadius),
            Pocket(id: .sideBottom, position: Vec2(0, -hy), captureRadius: sideCaptureRadius)
        ]
    }

    /// Half-extents of the playing field.
    public var halfExtents: Vec2 {
        let (w, h) = size.playField
        return Vec2(w / 2, h / 2)
    }

    /// Whether a point lies on the playing field (inclusive of rails).
    public func contains(_ p: Vec2, ballRadius: Double = 0) -> Bool {
        let he = halfExtents
        return abs(p.x) <= he.x - ballRadius + 1e-9 && abs(p.y) <= he.y - ballRadius + 1e-9
    }
}
