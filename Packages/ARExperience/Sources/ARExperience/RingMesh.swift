//
//  RingMesh.swift
//  ARExperience
//
//  A flat ring (an annulus) lying in the cloth plane, as plain triangles.
//
//  RealityKit has no ring primitive, and a thin cylinder is a filled disc:
//  exactly the "plate" that covered every ball. This is the geometry for a
//  real ring, with a hole in the middle, built without RealityKit so its
//  size, its hole and its winding are tested on Linux. The renderer wraps
//  the arrays in a mesh descriptor.
//

import Foundation

public struct RingMesh: Sendable, Equatable {
    public struct Point: Sendable, Equatable {
        public var x: Float
        public var y: Float
        public var z: Float
    }

    /// Positions in the ring's own frame: centred on the origin, lying in
    /// the x-z plane (y = 0), so placing the entity at a ball or a pocket
    /// puts the ring around it.
    public let points: [Point]
    /// Triangle corner indices, three per triangle. Every triangle appears
    /// twice, once wound to face +y and once facing -y, so the ring shows
    /// from above whichever way the cloth's normal points in the session.
    public let indices: [UInt32]

    public init(innerRadius: Double, outerRadius: Double, segments: Int = 64) {
        let count = max(8, segments)
        let inner = Float(max(0, min(innerRadius, outerRadius)))
        let outer = Float(max(innerRadius, outerRadius))
        var points: [Point] = []
        points.reserveCapacity(count * 2)
        for index in 0..<count {
            let angle = Float(index) / Float(count) * 2 * .pi
            let (s, c) = (sin(angle), cos(angle))
            points.append(Point(x: inner * c, y: 0, z: inner * s))
            points.append(Point(x: outer * c, y: 0, z: outer * s))
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(count * 12)
        for index in 0..<count {
            let next = (index + 1) % count
            let innerA = UInt32(index * 2), outerA = innerA + 1
            let innerB = UInt32(next * 2), outerB = innerB + 1
            // Facing +y: (inner, outer', outer) and (inner, inner', outer').
            indices += [innerA, outerB, outerA, innerA, innerB, outerB]
            // Facing -y: the same triangles reversed.
            indices += [innerA, outerA, outerB, innerA, outerB, innerB]
        }
        self.points = points
        self.indices = indices
    }

    /// The smallest distance from the centre to any point of the ring.
    public var innerRadius: Double {
        Double(points.map { ($0.x * $0.x + $0.z * $0.z).squareRoot() }.min() ?? 0)
    }

    /// The largest distance from the centre to any point of the ring.
    public var outerRadius: Double {
        Double(points.map { ($0.x * $0.x + $0.z * $0.z).squareRoot() }.max() ?? 0)
    }

    /// Total area of the triangles facing +y: the ring's own area, which is
    /// `pi (outer^2 - inner^2)` less the sliver a polygon loses to a circle.
    public var upwardArea: Double {
        var total = 0.0
        for base in stride(from: 0, to: indices.count, by: 3) {
            let a = points[Int(indices[base])]
            let b = points[Int(indices[base + 1])]
            let c = points[Int(indices[base + 2])]
            let (abx, abz) = (Double(b.x - a.x), Double(b.z - a.z))
            let (acx, acz) = (Double(c.x - a.x), Double(c.z - a.z))
            // y component of (b - a) x (c - a): positive when the triangle
            // faces +y.
            let normalY = acx * abz - acz * abx
            if normalY > 0 { total += normalY / 2 }
        }
        return total
    }
}
