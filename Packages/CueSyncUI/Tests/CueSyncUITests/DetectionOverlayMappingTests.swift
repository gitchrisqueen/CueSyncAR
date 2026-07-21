import CueSyncCore
import Testing
@testable import CueSyncUI

@Suite("NormalizedRotation")
struct NormalizedRotationTests {
    let rect = NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)

    @Test func identityLeavesRectAlone() {
        #expect(NormalizedRotation.none.apply(rect) == rect)
    }

    @Test func clockwiseMapsTopLeftRegionToTopRight() {
        // A box near the image top-left lands near the view top-RIGHT after
        // a 90° CW rotation.
        let r = NormalizedRotation.clockwise90.apply(
            NormalizedRect(x: 0.0, y: 0.0, width: 0.2, height: 0.1))
        #expect(abs(r.x - 0.9) < 1e-12)
        #expect(abs(r.y - 0.0) < 1e-12)
        #expect(abs(r.width - 0.1) < 1e-12)
        #expect(abs(r.height - 0.2) < 1e-12)
    }

    @Test func fourQuarterTurnsAreIdentity() {
        var r = rect
        for _ in 0..<4 { r = NormalizedRotation.clockwise90.apply(r) }
        #expect(abs(r.x - rect.x) < 1e-12)
        #expect(abs(r.y - rect.y) < 1e-12)
        #expect(abs(r.width - rect.width) < 1e-12)
        #expect(abs(r.height - rect.height) < 1e-12)
    }

    @Test func cwThenCCWIsIdentity() {
        let there = NormalizedRotation.clockwise90.apply(rect)
        let back = NormalizedRotation.counterClockwise90.apply(there)
        #expect(abs(back.x - rect.x) < 1e-12)
        #expect(abs(back.y - rect.y) < 1e-12)
    }

    @Test func cycleVisitsAllFourRotations() {
        var rotation = NormalizedRotation.none
        var seen: Set<Int> = []
        for _ in 0..<4 {
            seen.insert(rotation.rawValue)
            rotation = rotation.next
        }
        #expect(seen.count == 4)
        #expect(rotation == .none)
    }
}

@Suite("AspectFillMapping")
struct AspectFillMappingTests {
    @Test func widerImageCropsHorizontally() {
        // 1600×900 image into a 400×400 view: scale = 400/900, scaled
        // width ≈ 711 → x offset ≈ -155.6; full-image rect covers overflow.
        let full = AspectFillMapping.mapRect(
            NormalizedRect(x: 0, y: 0, width: 1, height: 1),
            imageWidth: 1600, imageHeight: 900,
            viewWidth: 400, viewHeight: 400)
        #expect(full.y == 0)
        #expect(full.height == 400)
        #expect(full.x < 0)
        #expect(abs(full.width - 1600.0 * (400.0 / 900.0)) < 1e-9)

        // The image center stays at the view center under aspect-fill.
        let center = AspectFillMapping.mapRect(
            NormalizedRect(x: 0.5, y: 0.5, width: 0, height: 0),
            imageWidth: 1600, imageHeight: 900,
            viewWidth: 400, viewHeight: 400)
        #expect(abs(center.x - 200) < 1e-9)
        #expect(abs(center.y - 200) < 1e-9)
    }

    @Test func matchingAspectIsPureScale() {
        let r = AspectFillMapping.mapRect(
            NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            imageWidth: 800, imageHeight: 600,
            viewWidth: 400, viewHeight: 300)
        #expect(abs(r.x - 100) < 1e-9)
        #expect(abs(r.y - 75) < 1e-9)
        #expect(abs(r.width - 200) < 1e-9)
        #expect(abs(r.height - 150) < 1e-9)
    }

    @Test func degenerateInputsReturnZeroRect() {
        let r = AspectFillMapping.mapRect(
            NormalizedRect(x: 0, y: 0, width: 1, height: 1),
            imageWidth: 0, imageHeight: 0, viewWidth: 100, viewHeight: 100)
        #expect(r.width == 0 && r.height == 0)
    }
}
