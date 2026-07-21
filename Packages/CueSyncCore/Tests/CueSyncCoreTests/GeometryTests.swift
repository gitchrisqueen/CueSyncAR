import Foundation
import Testing
@testable import CueSyncCore

@Suite("Geometry")
struct GeometryTests {
    @Test func vectorBasics() {
        let v = Vec2(3, 4)
        #expect(abs(v.length - 5) < 1e-12)
        #expect(abs(v.normalized.length - 1) < 1e-12)
        #expect(Vec2.zero.normalized == .zero)
        #expect(abs(v.dot(Vec2(1, 0)) - 3) < 1e-12)
        #expect(abs(Vec2(1, 0).cross(Vec2(0, 1)) - 1) < 1e-12)
        #expect(Vec2(1, 0).perpendicular == Vec2(0, 1))
    }

    @Test func rotation() {
        let r = Vec2(1, 0).rotated(by: .pi / 2)
        #expect(abs(r.x) < 1e-12)
        #expect(abs(r.y - 1) < 1e-12)
    }

    @Test func angleBetween() {
        let a = Vec2(1, 0).angle(to: Vec2(0, 1))
        #expect(abs(a - .pi / 2) < 1e-12)
        #expect(Vec2(1, 0).angle(to: Vec2(2, 0)) < 1e-9)
    }

    @Test func transformIdentityAndTranslation() {
        var t = Transform3D.identity
        #expect(t.transformPoint(Vec3(1, 2, 3)) == Vec3(1, 2, 3))
        t.columns[3] = SIMD4(5, 6, 7, 1)
        #expect(t.transformPoint(Vec3(1, 2, 3)) == Vec3(6, 8, 10))
        #expect(t.transformDirection(Vec3(1, 0, 0)) == Vec3(1, 0, 0))
        #expect(t.translation == Vec3(5, 6, 7))
    }

    @Test func transformComposition() {
        var translate = Transform3D.identity
        translate.columns[3] = SIMD4(1, 0, 0, 1)
        // 90° rotation about z.
        let rotate = Transform3D(columns: [
            SIMD4(0, 1, 0, 0),
            SIMD4(-1, 0, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(0, 0, 0, 1)
        ])
        let composed = translate * rotate
        let p = composed.transformPoint(Vec3(1, 0, 0))
        #expect(abs(p.x - 1) < 1e-12)
        #expect(abs(p.y - 1) < 1e-12)
    }

    @Test func normalizedRectAnchors() {
        let rect = NormalizedRect(x: 0.2, y: 0.4, width: 0.2, height: 0.1)
        #expect(abs(rect.center.x - 0.3) < 1e-12)
        #expect(abs(rect.center.y - 0.45) < 1e-12)
        #expect(abs(rect.footPoint.y - 0.5) < 1e-12)
    }
}
