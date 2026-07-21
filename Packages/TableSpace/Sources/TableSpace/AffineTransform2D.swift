//
//  AffineTransform2D.swift
//  TableSpace
//
//  Minimal 2D affine transform (2×3 matrix) for image↔table 2D mappings and
//  the mini-map/TV renderers. Cross-platform (no CoreGraphics dependency).
//

import CueSyncCore
import Foundation

public struct AffineTransform2D: Sendable, Equatable, Codable {
    // | a  b  tx |
    // | c  d  ty |
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double
    public var tx: Double
    public var ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    public static let identity = AffineTransform2D(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public static func translation(_ t: Vec2) -> AffineTransform2D {
        AffineTransform2D(a: 1, b: 0, c: 0, d: 1, tx: t.x, ty: t.y)
    }

    public static func scale(_ sx: Double, _ sy: Double) -> AffineTransform2D {
        AffineTransform2D(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0)
    }

    public static func rotation(_ angle: Double) -> AffineTransform2D {
        let cs = cos(angle)
        let sn = sin(angle)
        return AffineTransform2D(a: cs, b: -sn, c: sn, d: cs, tx: 0, ty: 0)
    }

    public func apply(_ p: Vec2) -> Vec2 {
        Vec2(a * p.x + b * p.y + tx, c * p.x + d * p.y + ty)
    }

    /// Composition: `self.concatenating(other)` applies `other` first, then `self`.
    public func concatenating(_ other: AffineTransform2D) -> AffineTransform2D {
        AffineTransform2D(
            a: a * other.a + b * other.c,
            b: a * other.b + b * other.d,
            c: c * other.a + d * other.c,
            d: c * other.b + d * other.d,
            tx: a * other.tx + b * other.ty + tx,
            ty: c * other.tx + d * other.ty + ty)
    }

    public var determinant: Double { a * d - b * c }

    /// Inverse, or nil when the transform is singular.
    public func inverted() -> AffineTransform2D? {
        let det = determinant
        guard abs(det) > 1e-12 else { return nil }
        let ia = d / det
        let ib = -b / det
        let ic = -c / det
        let id = a / det
        return AffineTransform2D(
            a: ia, b: ib, c: ic, d: id,
            tx: -(ia * tx + ib * ty),
            ty: -(ic * tx + id * ty))
    }
}
