//
//  Geometry.swift
//  CueSyncCore
//
//  Cross-platform 2D/3D math helpers built only on the Swift standard
//  library's SIMD types, so they compile on Linux CI as well as Apple
//  platforms. Angles are radians; distances are meters.
//

import Foundation

/// 2D point/vector in table space (meters).
public typealias Vec2 = SIMD2<Double>
/// 3D point/vector in world space (meters).
public typealias Vec3 = SIMD3<Double>

extension SIMD2 where Scalar == Double {
    public var length: Double { (x * x + y * y).squareRoot() }

    public var lengthSquared: Double { x * x + y * y }

    /// Unit vector; returns `.zero` for the zero vector rather than trapping.
    public var normalized: Vec2 {
        let len = length
        guard len > .ulpOfOne else { return .zero }
        return self / len
    }

    public func dot(_ other: Vec2) -> Double { x * other.x + y * other.y }

    /// Z component of the 3D cross product — signed area / turn direction.
    public func cross(_ other: Vec2) -> Double { x * other.y - y * other.x }

    public func distance(to other: Vec2) -> Double { (self - other).length }

    /// Perpendicular vector, rotated +90° (counter-clockwise).
    public var perpendicular: Vec2 { Vec2(-y, x) }

    public func rotated(by angle: Double) -> Vec2 {
        let c = Foundation.cos(angle)
        let s = Foundation.sin(angle)
        return Vec2(x * c - y * s, x * s + y * c)
    }

    /// Angle in radians between two vectors (0...π).
    public func angle(to other: Vec2) -> Double {
        let d = normalized.dot(other.normalized)
        return Foundation.acos(Swift.max(-1, Swift.min(1, d)))
    }
}

extension SIMD3 where Scalar == Double {
    public var length: Double { (x * x + y * y + z * z).squareRoot() }

    public var normalized: Vec3 {
        let len = length
        guard len > .ulpOfOne else { return .zero }
        return self / len
    }

    public func dot(_ other: Vec3) -> Double { x * other.x + y * other.y + z * other.z }

    public func cross(_ other: Vec3) -> Vec3 {
        Vec3(y * other.z - z * other.y,
             z * other.x - x * other.z,
             x * other.y - y * other.x)
    }

    public func distance(to other: Vec3) -> Double { (self - other).length }
}

/// Minimal column-major 4×4 transform for camera poses and anchor transforms.
/// Mirrors `simd_float4x4` semantics without importing Apple's `simd` module,
/// so core stays Linux-buildable. Convert at the ARKit boundary.
public struct Transform3D: Sendable, Equatable, Codable {
    /// Column-major storage: columns[c][r].
    public var columns: [SIMD4<Double>]

    public init(columns: [SIMD4<Double>]) {
        precondition(columns.count == 4, "Transform3D requires exactly 4 columns")
        self.columns = columns
    }

    public static let identity = Transform3D(columns: [
        SIMD4(1, 0, 0, 0),
        SIMD4(0, 1, 0, 0),
        SIMD4(0, 0, 1, 0),
        SIMD4(0, 0, 0, 1)
    ])

    public var translation: Vec3 {
        Vec3(columns[3].x, columns[3].y, columns[3].z)
    }

    /// The basis vector of the given column (0 = x-axis, 1 = y, 2 = z).
    public func axis(_ index: Int) -> Vec3 {
        let c = columns[index]
        return Vec3(c.x, c.y, c.z)
    }

    public func transformPoint(_ p: Vec3) -> Vec3 {
        let v = SIMD4(p.x, p.y, p.z, 1)
        let r = columns[0] * v.x + columns[1] * v.y + columns[2] * v.z + columns[3] * v.w
        return Vec3(r.x, r.y, r.z)
    }

    public func transformDirection(_ d: Vec3) -> Vec3 {
        let r = columns[0] * d.x + columns[1] * d.y + columns[2] * d.z
        return Vec3(r.x, r.y, r.z)
    }

    public static func * (lhs: Transform3D, rhs: Transform3D) -> Transform3D {
        var out = [SIMD4<Double>](repeating: .zero, count: 4)
        for c in 0..<4 {
            let v = rhs.columns[c]
            out[c] = lhs.columns[0] * v.x + lhs.columns[1] * v.y + lhs.columns[2] * v.z + lhs.columns[3] * v.w
        }
        return Transform3D(columns: out)
    }
}

/// Axis-aligned rectangle in a normalized (0...1) image coordinate space.
/// Origin is top-left, y increases downward — matching Vision/Core ML
/// bounding-box conventions after the adapter normalizes them.
public struct NormalizedRect: Sendable, Equatable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var center: Vec2 { Vec2(x + width / 2, y + height / 2) }

    /// Bottom-center of the box — where a ball touches the cloth in image space.
    public var footPoint: Vec2 { Vec2(x + width / 2, y + height) }
}
