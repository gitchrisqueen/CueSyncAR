//
//  PocketSnapTests.swift
//  CueSync AR
//
//  PocketSnap against a synthetic head-rail view of a black-cloth table:
//  bright rails, dark cushions whose lit tops drop into a shadowed face at
//  the nose on the long rails and far end (not the near end, which faces
//  away), dark pocket holes, and pixel noise.
//

import CueSyncCore
import Foundation
import Testing
@testable import TableSpace

/// A rendered synthetic table and the truth it was drawn from.
struct SyntheticTableImage {
    static let width = 1000
    static let height = 700
    /// Cushion-nose quad, image px: TL (near-left), TR (far-left),
    /// BR (far-right), BL (near-right) — the head-rail view.
    var nose: [PocketID: Vec2] = [
        .cornerTopLeft: Vec2(180, 600), .cornerTopRight: Vec2(372, 290.4),
        .cornerBottomRight: Vec2(641.6, 287.3), .cornerBottomLeft: Vec2(852.5, 588.8)
    ]
    /// Where along each long nose line the side pocket is (fraction).
    var sideFraction = 0.42
    var image: LumaImage!

    var sideTop: Vec2 { nose[.cornerTopLeft]! + (nose[.cornerTopRight]! - nose[.cornerTopLeft]!) * sideFraction }
    var sideBottom: Vec2 {
        nose[.cornerBottomLeft]! + (nose[.cornerBottomRight]! - nose[.cornerBottomLeft]!) * sideFraction
    }

    init(noise: Double = 6, shadowOnNearEnd: Bool = false) {
        let order: [PocketID] = [.cornerTopLeft, .cornerTopRight, .cornerBottomRight, .cornerBottomLeft]
        let quad = order.map { nose[$0]! }
        let centre = quad.reduce(Vec2.zero, +) / 4
        // Inset of the rail edge outside the nose line, per side, px.
        let insets: [Double] = [26, 12, 26, 34]
        func line(_ i: Int) -> (p: Vec2, d: Vec2, out: Vec2) {
            let a = quad[i], b = quad[(i + 1) % 4]
            let d = (b - a).normalized
            var out = Vec2(-d.y, d.x)
            if ((a + b) / 2 - centre).dot(out) < 0 { out = Vec2(-out.x, -out.y) }
            return (a, d, out)
        }
        let lines = (0..<4).map(line)
        /// Signed distance outside side i's nose line (positive = outside).
        func outside(_ p: Vec2, _ i: Int) -> Double { (p - lines[i].p).dot(lines[i].out) }
        let sides = (sideTop, sideBottom)
        var pixels = [UInt8](repeating: 0, count: Self.width * Self.height)
        var seed: UInt64 = 12345
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        for y in 0..<Self.height {
            for x in 0..<Self.width {
                let p = Vec2(Double(x), Double(y))
                let d = (0..<4).map { outside(p, $0) }
                var value: Double
                if d.enumerated().allSatisfy({ $0.element <= insets[$0.offset] + 40 }) {
                    value = 180  // rail cap
                } else {
                    value = 120  // room
                }
                if d.enumerated().allSatisfy({ $0.element <= insets[$0.offset] }) {
                    value = 55  // cushion top
                    if d.allSatisfy({ $0 <= 0 }) {
                        value = 60  // cloth
                        for i in 0..<3 where i != 3 && d[i] > -6 { value = 12 }  // shadowed face
                        if shadowOnNearEnd, d[3] > -6 { value = 12 }
                    }
                }
                // Pocket holes: side pockets centred on the nose point but
                // pushed outward so the mouth is cut into the cushion top.
                for (i, mouth) in [(0, sides.0), (2, sides.1)] {
                    let centreHole = mouth + lines[i].out * 10
                    if p.distance(to: centreHole) < 15, outside(p, i) > -3 { value = 8 }
                }
                for corner in quad where p.distance(to: corner + (corner - centre).normalized * 22) < 22 {
                    value = 8
                }
                value += (random() - 0.5) * 2 * noise
                pixels[y * Self.width + x] = UInt8(max(0, min(255, value.rounded())))
            }
        }
        image = LumaImage(width: Self.width, height: Self.height, pixels: pixels)
    }

    /// Distance from `p` to the nose line through two pockets.
    func distanceToNose(_ p: Vec2, _ a: PocketID, _ b: PocketID) -> Double {
        let d = (nose[b]! - nose[a]!).normalized
        return abs((p - nose[a]!).cross(d))
    }
}

@Suite("PocketSnap")
struct PocketSnapTests {
    static let rendered = SyntheticTableImage()

    var roughTaps: [PocketID: Vec2] {
        let truth = Self.rendered
        return [
            .cornerTopLeft: truth.nose[.cornerTopLeft]! + Vec2(9, -7),
            .cornerTopRight: truth.nose[.cornerTopRight]! + Vec2(-8, -6),
            .cornerBottomRight: truth.nose[.cornerBottomRight]! + Vec2(7, -5),
            .cornerBottomLeft: truth.nose[.cornerBottomLeft]! + Vec2(-10, 8),
            .sideTop: truth.sideTop + Vec2(-9, -6),
            .sideBottom: truth.sideBottom + Vec2(8, -7)
        ]
    }

    @Test func farCornersSnapToTheNoseIntersection() {
        let snapped = PocketSnap.refine(Self.rendered.image, taps: roughTaps)
        for pocket in [PocketID.cornerTopRight, .cornerBottomRight] {
            let result = snapped[pocket]!
            #expect(result.method == .noseCorner, "\(pocket)")
            #expect(result.point.distance(to: Self.rendered.nose[pocket]!) < 0.6,
                    "\(pocket) \(result.point) vs \(Self.rendered.nose[pocket]!)")
        }
    }

    @Test func nearCornersLandOnTheLongNoseLine() {
        let snapped = PocketSnap.refine(Self.rendered.image, taps: roughTaps)
        let tl = snapped[.cornerTopLeft]!
        let bl = snapped[.cornerBottomLeft]!
        #expect(tl.method == .ontoNose)
        #expect(bl.method == .ontoNose)
        #expect(Self.rendered.distanceToNose(tl.point, .cornerTopLeft, .cornerTopRight) < 0.6)
        #expect(Self.rendered.distanceToNose(bl.point, .cornerBottomLeft, .cornerBottomRight) < 0.6)
    }

    @Test func nearCornersBecomeIntersectionsWhenTheNearNoseIsVisible() {
        let rendered = SyntheticTableImage(shadowOnNearEnd: true)
        let snapped = PocketSnap.refine(rendered.image, taps: roughTaps)
        for pocket in [PocketID.cornerTopLeft, .cornerBottomLeft] {
            #expect(snapped[pocket]!.method == .noseCorner)
            #expect(snapped[pocket]!.point.distance(to: rendered.nose[pocket]!) < 0.8)
        }
    }

    @Test func sidePocketsSnapToTheJawGapCentre() {
        let snapped = PocketSnap.refine(Self.rendered.image, taps: roughTaps)
        let top = snapped[.sideTop]!
        let bottom = snapped[.sideBottom]!
        #expect(top.method == .jawGap)
        #expect(bottom.method == .jawGap)
        #expect(top.point.distance(to: Self.rendered.sideTop) < 1.0, "\(top.point) vs \(Self.rendered.sideTop)")
        #expect(bottom.point.distance(to: Self.rendered.sideBottom) < 1.0)
    }

    @Test func snappingIsStableAcrossDifferentRoughTaps() {
        var other = roughTaps
        for (pocket, tap) in other { other[pocket] = tap + Vec2(-5, 9) }
        let a = PocketSnap.refine(Self.rendered.image, taps: roughTaps)
        let b = PocketSnap.refine(Self.rendered.image, taps: other)
        for pocket in [PocketID.cornerTopRight, .cornerBottomRight, .sideTop, .sideBottom] {
            #expect(a[pocket]!.point.distance(to: b[pocket]!.point) < 0.6, "\(pocket)")
        }
    }

    @Test func aFeaturelessImageKeepsEveryTap() {
        let flat = LumaImage(width: 400, height: 300, pixels: [UInt8](repeating: 60, count: 400 * 300))!
        let taps: [PocketID: Vec2] = [.cornerTopLeft: Vec2(50, 250), .cornerTopRight: Vec2(120, 60),
                                      .cornerBottomRight: Vec2(280, 60), .cornerBottomLeft: Vec2(350, 250)]
        let snapped = PocketSnap.refine(flat, taps: taps)
        for (pocket, tap) in taps {
            #expect(snapped[pocket]!.method == .raw)
            #expect(snapped[pocket]!.point == tap)
        }
    }

    @Test func withoutAllFourCornersNothingMoves() {
        var taps = roughTaps
        taps[.cornerBottomLeft] = nil
        let snapped = PocketSnap.refine(Self.rendered.image, taps: taps)
        #expect(snapped.count == 5)
        #expect(snapped.values.allSatisfy { $0.method == .raw })
    }

    @Test func aSnapTooFarFromItsTapIsRefused() {
        var config = PocketSnap.Config()
        config.maximumShift = 3
        let snapped = PocketSnap.refine(Self.rendered.image, taps: roughTaps, config: config)
        #expect(snapped.values.allSatisfy { $0.method == .raw })
    }

    @Test func lumaImageRejectsAWrongSizeAndSamplesBilinearly() {
        #expect(LumaImage(width: 2, height: 2, pixels: [0, 0, 0]) == nil)
        let image = LumaImage(width: 2, height: 2, pixels: [0, 100, 100, 200])!
        #expect(image.sample(Vec2(0.5, 0.5)) == 100)
        #expect(image.sample(Vec2(1.5, 0.5)) == nil)
        #expect(image.value(1, 1) == 200)
        #expect(image.value(2, 0) == nil)
    }

    @Test func theReadyPromptAsksForAllSix() {
        var flow = PocketSightingFlow()
        for (index, pocket) in [PocketID.cornerTopLeft, .cornerTopRight, .cornerBottomRight,
                                .cornerBottomLeft].enumerated() {
            flow.sight(pocket, at: Vec2(Double(index * 100), Double(index % 2 * 300)))
        }
        #expect(flow.prompt.contains("Tap all six"))
        flow.sight(.sideTop, at: Vec2(50, 100))
        flow.sight(.sideBottom, at: Vec2(250, 100))
        #expect(!flow.prompt.contains("Tap all six"))
    }

    @Test func lineIntersectionAndProjection() {
        let a = PocketSnap.Line(point: Vec2(0, 0), direction: Vec2(1, 0), rms: 0, inliers: 0)
        let b = PocketSnap.Line(point: Vec2(3, 5), direction: Vec2(0, 1), rms: 0, inliers: 0)
        #expect(a.intersect(b)!.distance(to: Vec2(3, 0)) < 1e-9)
        #expect(a.intersect(a) == nil)
        #expect(a.project(Vec2(2, 7)).distance(to: Vec2(2, 0)) < 1e-9)
    }
}
