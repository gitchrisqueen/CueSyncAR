import CueSyncCore
import Foundation
import Testing
@testable import TableSpace

@Suite("TableCalibration")
struct TableCalibrationTests {
    /// A 9-ft table lying in the world xz-plane (y up), centered at
    /// (1, 0.8, -2), long axis along world x.
    var calibration: TableCalibration {
        TableCalibration(origin: Vec3(1, 0.8, -2),
                         xAxis: Vec3(1, 0, 0),
                         yAxis: Vec3(0, 0, -1),
                         size: .nineFoot)
    }

    @Test func roundTripIsIdentity() {
        let cal = calibration
        let points: [Vec2] = [.zero, Vec2(1.0, 0.5), Vec2(-1.27, 0.635), Vec2(0.3, -0.2)]
        for p in points {
            let back = cal.worldToTable(cal.tableToWorld(p))
            #expect(abs(back.x - p.x) < 1e-9)
            #expect(abs(back.y - p.y) < 1e-9)
        }
    }

    @Test func knownWorldPointMapsCorrectly() {
        let cal = calibration
        // 0.5 m along the long axis, 0.2 m along the short axis from center.
        let world = Vec3(1.5, 0.8, -2.2)
        let table = cal.worldToTable(world)
        #expect(abs(table.x - 0.5) < 1e-9)
        #expect(abs(table.y - 0.2) < 1e-9)
    }

    @Test func heightAbovePlane() {
        let cal = calibration
        // normal = x × y = (1,0,0) × (0,0,-1) = (0,1,0) — world up.
        let hovering = Vec3(1, 1.3, -2)
        #expect(abs(cal.heightAbovePlane(hovering) - 0.5) < 1e-9)
        #expect(abs(cal.heightAbovePlane(cal.tableToWorld(Vec2(0.4, 0.1)))) < 1e-9)
    }

    @Test func rayIntersection() throws {
        let cal = calibration
        // Camera 1 m above the point (0.5, 0.2) in table space, looking
        // straight down.
        let target = cal.tableToWorld(Vec2(0.5, 0.2))
        let cameraPosition = target + Vec3(0, 1, 0)
        let hit = cal.intersect(rayOrigin: cameraPosition, rayDirection: Vec3(0, -1, 0))
        let point = try #require(hit)
        #expect(abs(point.x - 0.5) < 1e-9)
        #expect(abs(point.y - 0.2) < 1e-9)

        // Parallel ray → nil, never a trap.
        #expect(cal.intersect(rayOrigin: cameraPosition, rayDirection: Vec3(1, 0, 0)) == nil)
        // Ray pointing away → nil.
        #expect(cal.intersect(rayOrigin: cameraPosition, rayDirection: Vec3(0, 1, 0)) == nil)
    }

    @Test func fromCornersRecoversAxesAndSize() throws {
        let cal = calibration
        let he = Table(size: .nineFoot).halfExtents
        // Corners ordered around the rectangle.
        let corners = [
            cal.tableToWorld(Vec2(-he.x, -he.y)),
            cal.tableToWorld(Vec2(he.x, -he.y)),
            cal.tableToWorld(Vec2(he.x, he.y)),
            cal.tableToWorld(Vec2(-he.x, he.y))
        ]
        let rebuilt = try TableCalibration.fromCorners(corners)
        #expect(rebuilt.size == .nineFoot)
        #expect(rebuilt.origin.distance(to: cal.origin) < 1e-9)
        // Axes recovered up to sign; mapping must agree up to axis flips,
        // so verify a round trip through the rebuilt calibration instead.
        let p = Vec2(0.7, -0.3)
        let back = rebuilt.worldToTable(rebuilt.tableToWorld(p))
        #expect(abs(back.x - p.x) < 1e-9)
        #expect(abs(back.y - p.y) < 1e-9)
        // Long axis is x: |x-axis · cal.xAxis| ≈ 1.
        #expect(abs(abs(rebuilt.xAxis.dot(cal.xAxis)) - 1) < 1e-9)
    }

    @Test func fromCornersRejectsBadInput() {
        #expect(throws: CalibrationError.needFourCorners) {
            _ = try TableCalibration.fromCorners([Vec3(0, 0, 0)])
        }
        #expect(throws: CalibrationError.self) {
            _ = try TableCalibration.fromCorners([
                Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(0, 0, 0)
            ])
        }
    }

    @Test func fromCornersLocksNonStandardRectanglesAsCustom() throws {
        // Chris's covered home table: 1.58 × 0.76 m — nowhere near a
        // standard size, but a perfectly lockable rectangle.
        let cal = try TableCalibration.fromCorners([
            Vec3(0, 0, 0), Vec3(1.58, 0, 0), Vec3(1.58, 0, 0.76), Vec3(0, 0, 0.76)
        ])
        guard case let .custom(width, height) = cal.size else {
            Issue.record("expected .custom, got \(cal.size)")
            return
        }
        #expect(abs(width - 1.58) < 1e-9)
        #expect(abs(height - 0.76) < 1e-9)
    }

    @Test func fromCornersSnapsWhenCloseToAStandardSize() throws {
        // ~4% off a nine-foot field → snapped (the "slight adjustment").
        let cal = try TableCalibration.fromCorners([
            Vec3(0, 0, 0), Vec3(2.45, 0, 0), Vec3(2.45, 0, 1.23), Vec3(0, 0, 1.23)
        ])
        #expect(cal.size == .nineFoot)
    }

    @Test func codableRoundTrip() throws {
        let cal = calibration
        let data = try JSONEncoder().encode(cal)
        let decoded = try JSONDecoder().decode(TableCalibration.self, from: data)
        #expect(decoded == cal)
    }
}

@Suite("AffineTransform2D")
struct AffineTransformTests {
    @Test func identityAndTranslation() {
        let p = Vec2(3, 4)
        #expect(AffineTransform2D.identity.apply(p) == p)
        let t = AffineTransform2D.translation(Vec2(1, -2)).apply(p)
        #expect(t == Vec2(4, 2))
    }

    @Test func rotationQuarterTurn() {
        let r = AffineTransform2D.rotation(.pi / 2).apply(Vec2(1, 0))
        #expect(abs(r.x) < 1e-12)
        #expect(abs(r.y - 1) < 1e-12)
    }

    @Test func compositionOrder() {
        // Scale-then-translate vs translate-then-scale differ.
        let scale = AffineTransform2D.scale(2, 2)
        let translate = AffineTransform2D.translation(Vec2(1, 0))
        let p = Vec2(1, 1)
        // translate ∘ scale: scale first.
        #expect(translate.concatenating(scale).apply(p) == Vec2(3, 2))
        // scale ∘ translate: translate first.
        #expect(scale.concatenating(translate).apply(p) == Vec2(4, 2))
    }

    @Test func inverseRoundTrip() throws {
        let transform = AffineTransform2D.translation(Vec2(5, -1))
            .concatenating(.rotation(0.7))
            .concatenating(.scale(2, 3))
        let inverse = try #require(transform.inverted())
        let p = Vec2(0.3, -0.9)
        let back = inverse.apply(transform.apply(p))
        #expect(abs(back.x - p.x) < 1e-9)
        #expect(abs(back.y - p.y) < 1e-9)
    }

    @Test func singularHasNoInverse() {
        #expect(AffineTransform2D.scale(0, 1).inverted() == nil)
    }
}
