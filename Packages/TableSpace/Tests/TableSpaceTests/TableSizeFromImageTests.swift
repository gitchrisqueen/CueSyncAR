//
//  TableSizeFromImageTests.swift
//  CueSync AR
//
//  The image ruler against synthetic views of 7, 8 and 9 ft tables: two
//  converging nose lines, and balls drawn at the size a 57.15 mm ball has
//  at that row.
//

import CueSyncCore
import Foundation
import Testing
@testable import TableSpace

@Suite("Table size from the image")
struct TableSizeFromImageTests {
    static let width = 900
    static let height = 600

    /// Left/right nose lines converging upward (far is up).
    static let left = PocketSnap.Line(point: Vec2(150, 560), direction: Vec2(0.5, -0.866).normalized,
                                      rms: 0, inliers: 0)
    static let right = PocketSnap.Line(point: Vec2(750, 560), direction: Vec2(-0.5, -0.866).normalized,
                                       rms: 0, inliers: 0)

    static func chord(atRow y: Double) -> Double {
        let row = PocketSnap.Line(point: Vec2(0, y), direction: Vec2(1, 0), rms: 0, inliers: 0)
        return row.intersect(left)!.distance(to: row.intersect(right)!)
    }

    /// Cloth 60, balls `ballLevel`, noise +/- `noise`, a soft 1 px edge.
    static func render(fieldWidth: Double, balls: [Vec2], ballLevel: Double = 200, noise: Double = 5,
                       scale: Double = 1, seed: UInt64 = 3) -> (LumaImage, [TableSizeFromImage.Ball]) {
        var pixels = [UInt8](repeating: 0, count: width * height)
        var state = seed
        func random() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53) - 0.5
        }
        let radii = balls.map { chord(atRow: $0.y) * TableSizeFromImage.Ball.diameter / fieldWidth / 2 * scale }
        for y in 0..<height {
            for x in 0..<width {
                let p = Vec2(Double(x), Double(y))
                var value = 60.0
                for (centre, radius) in zip(balls, radii) {
                    let d = p.distance(to: centre) - radius
                    // Linear edge one pixel wide: half-maximum at the radius.
                    let coverage = max(0, min(1, 0.5 - d))
                    value = max(value, 60 + (ballLevel - 60) * coverage)
                }
                pixels[y * width + x] = UInt8(max(0, min(255, (value + random() * 2 * noise).rounded())))
            }
        }
        let image = LumaImage(width: width, height: height, pixels: pixels)!
        return (image, zip(balls, radii).map { TableSizeFromImage.Ball(centre: $0, radius: $1 * 1.15) })
    }

    static let ballPositions = [Vec2(420, 200), Vec2(470, 330), Vec2(380, 450), Vec2(520, 260)]

    @Test(arguments: [TableSize.sevenFoot, .eightFoot, .nineFoot])
    func identifiesEachStandardSize(_ size: TableSize) throws {
        let truth = size.playField.height
        let (image, balls) = Self.render(fieldWidth: truth, balls: Self.ballPositions)
        let estimate = try #require(TableSizeFromImage.estimate(
            image, leftNose: Self.left, rightNose: Self.right, across: Vec2(1, 0), balls: balls))
        #expect(estimate.verdict.nearest == size)
        #expect(estimate.verdict.isDecisive)
        #expect(abs(estimate.width - truth) / truth < 0.03, "width \(estimate.width) vs \(truth)")
        #expect(estimate.samples == 4)
    }

    @Test func repeatMeasurementsWithDifferentNoiseAgree() throws {
        let truth = TableSize.eightFoot.playField.height
        var verdicts: Set<String> = []
        for seed in [UInt64(1), 9, 77] {
            let (image, balls) = Self.render(fieldWidth: truth, balls: Self.ballPositions, noise: 12, seed: seed)
            let estimate = try #require(TableSizeFromImage.estimate(
                image, leftNose: Self.left, rightNose: Self.right, across: Vec2(1, 0), balls: balls))
            verdicts.insert("\(estimate.verdict.nearest) \(estimate.verdict.isDecisive)")
        }
        #expect(verdicts == ["eightFoot true"])
    }

    @Test func aBallTheColourOfTheClothIsSkipped() {
        let (image, balls) = Self.render(fieldWidth: 1.17, balls: Self.ballPositions, ballLevel: 75)
        #expect(TableSizeFromImage.estimate(image, leftNose: Self.left, rightNose: Self.right,
                                            across: Vec2(1, 0), balls: balls) == nil)
    }

    @Test func aBallOffTheTableIsIgnored() throws {
        let truth = TableSize.eightFoot.playField.height
        let (image, balls) = Self.render(fieldWidth: truth, balls: Self.ballPositions + [Vec2(40, 300)])
        let estimate = try #require(TableSizeFromImage.estimate(
            image, leftNose: Self.left, rightNose: Self.right, across: Vec2(1, 0), balls: balls))
        #expect(estimate.samples == 4)
    }

    @Test func halfwayBetweenSizesIsNotDecisive() throws {
        let between = (TableSize.sevenFoot.playField.height + TableSize.eightFoot.playField.height) / 2
        let (image, balls) = Self.render(fieldWidth: between, balls: Self.ballPositions)
        let estimate = try #require(TableSizeFromImage.estimate(
            image, leftNose: Self.left, rightNose: Self.right, across: Vec2(1, 0), balls: balls))
        #expect(!estimate.verdict.isDecisive)
        #expect(estimate.summary.contains("not decisive"))
    }

    @Test func ballWidthIsTheHalfMaximumWidth() throws {
        let (image, _) = Self.render(fieldWidth: 1.17, balls: [Vec2(450, 300)], noise: 0)
        let expected = Self.chord(atRow: 300) * TableSizeFromImage.Ball.diameter / 1.17
        let measured = try #require(TableSizeFromImage.ballWidth(
            image, centre: Vec2(450.7, 299.4), radius: expected / 2, along: Vec2(1, 0)))
        #expect(abs(measured - expected) < 0.6, "\(measured) vs \(expected)")
    }

    @Test func noseRangeRatioScalesTheWidth() throws {
        let (image, plain) = Self.render(fieldWidth: 1.17, balls: Self.ballPositions)
        let ratio = plain.map { TableSizeFromImage.Ball(centre: $0.centre, radius: $0.radius, noseRangeRatio: 0.98) }
        let a = try #require(TableSizeFromImage.estimate(image, leftNose: Self.left, rightNose: Self.right,
                                                         across: Vec2(1, 0), balls: plain))
        let b = try #require(TableSizeFromImage.estimate(image, leftNose: Self.left, rightNose: Self.right,
                                                         across: Vec2(1, 0), balls: ratio))
        #expect(abs(b.width / a.width - 0.98) < 1e-9)
    }

    @Test func depthRulerComparesBallsAtTheSightingsLevel() throws {
        // Nose sightings of an 8 ft table, camera 0.6 m above the cloth:
        // the nose plane is 0.5637 m down. Comparing the balls' cloth
        // (0.6 m down) against it reads the table 6 % long; at the nose
        // level it reads exactly right.
        let noseDepth = 0.6 - PocketSnap.noseHeight
        let solved = TableSize.standardSizes.map {
            (size: $0, height: -noseDepth * $0.playField.width / TableSize.eightFoot.playField.width)
        }
        let naive = try #require(TableSizeFromBalls.classify(
            cameraHeight: 0, ballClothHeight: -0.6, ballSpread: 0.002, solvedHeights: solved))
        let matched = try #require(TableSizeFromBalls.classify(
            cameraHeight: 0, ballClothHeight: -0.6, ballSpread: 0.002, solvedHeights: solved,
            sightingsAboveCloth: PocketSnap.noseHeight))
        #expect(abs(matched.impliedLength - 2.34) < 1e-9)
        #expect(naive.impliedLength > 2.34 * 1.05)
        #expect(matched.nearest == .eightFoot)
    }

    @Test func pocketViewNames() {
        let taps: [PocketID: Vec2] = [
            .cornerTopLeft: Vec2(100, 600), .cornerTopRight: Vec2(380, 330),
            .cornerBottomRight: Vec2(700, 330), .cornerBottomLeft: Vec2(970, 600),
            .sideTop: Vec2(290, 420), .sideBottom: Vec2(780, 420)
        ]
        #expect(PocketSnap.viewName(.cornerTopRight, taps: taps) == "far-left corner")
        #expect(PocketSnap.viewName(.cornerBottomLeft, taps: taps) == "near-right corner")
        #expect(PocketSnap.viewName(.sideTop, taps: taps) == "left side pocket")
        #expect(PocketSnap.viewName(.sideBottom, taps: [:]) == "sideBottom")
    }
}
