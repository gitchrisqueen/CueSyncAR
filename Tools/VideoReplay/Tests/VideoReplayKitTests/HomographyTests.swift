//
//  HomographyTests.swift
//  CueSync AR
//
//  Pure-geometry checks for the pixel <-> table-plane map and the corner
//  config built on it.
//

import CueSyncCore
import Foundation
import Testing
@testable import VideoReplayKit

private let tolerance = 1e-6

private func expectClose(_ actual: Vec2?, _ expected: Vec2, tolerance: Double = tolerance,
                         sourceLocation: SourceLocation = #_sourceLocation) {
    guard let actual else {
        Issue.record("expected \(expected), got nil", sourceLocation: sourceLocation)
        return
    }
    #expect(actual.distance(to: expected) < tolerance, "\(actual) != \(expected)",
            sourceLocation: sourceLocation)
}

/// A pub-table-like trapezoid (far edge shorter than near edge), in pixels.
private let trapezoid: [Vec2] = [Vec2(210, 120), Vec2(470, 120), Vec2(640, 600), Vec2(40, 600)]
private let field: [Vec2] = [Vec2(-1, -0.5), Vec2(1, -0.5), Vec2(1, 0.5), Vec2(-1, 0.5)]

@Suite struct HomographyTests {
    @Test func mapsEachSourceCornerOntoItsDestination() throws {
        let homography = try #require(Homography(from: trapezoid, to: field))
        for (pixel, table) in zip(trapezoid, field) {
            expectClose(homography.apply(pixel), table)
        }
    }

    @Test func roundTripsThroughTheInverse() throws {
        let homography = try #require(Homography(from: trapezoid, to: field))
        let inverse = try #require(homography.inverse)
        for point in [Vec2(0, 0), Vec2(0.7, -0.3), Vec2(-0.9, 0.45), Vec2(0.123, 0.4)] {
            let pixel = try #require(inverse.apply(point))
            expectClose(homography.apply(pixel), point)
        }
        for pixel in [Vec2(300, 300), Vec2(100, 580), Vec2(450, 150)] {
            let table = try #require(homography.apply(pixel))
            expectClose(inverse.apply(table), pixel, tolerance: 1e-6)
        }
    }

    @Test func identityPairsGiveTheIdentityMap() throws {
        let square = [Vec2(0, 0), Vec2(1, 0), Vec2(1, 1), Vec2(0, 1)]
        let homography = try #require(Homography(from: square, to: square))
        expectClose(homography.apply(Vec2(0.3, 0.8)), Vec2(0.3, 0.8))
    }

    @Test func scalesAndTranslatesAnAffineQuad() throws {
        // Pixel rectangle 100x50 at (10, 20) -> field 2 x 1 centered on the origin.
        let pixels = [Vec2(10, 20), Vec2(110, 20), Vec2(110, 70), Vec2(10, 70)]
        let homography = try #require(Homography(from: pixels, to: field))
        expectClose(homography.apply(Vec2(60, 45)), Vec2(0, 0))
        expectClose(homography.apply(Vec2(85, 32.5)), Vec2(0.5, -0.25))
    }

    @Test func diagonalIntersectionMapsToTheFieldCenter() throws {
        // Projective invariant: the image of the field's center is where the
        // quad's diagonals cross, NOT the pixel centroid.
        let homography = try #require(Homography(from: trapezoid, to: field))
        let crossing = try #require(diagonalIntersection(trapezoid))
        expectClose(homography.apply(crossing), Vec2(0, 0))
        let centroid = (trapezoid[0] + trapezoid[1] + trapezoid[2] + trapezoid[3]) / 4
        let mapped = try #require(homography.apply(centroid))
        #expect(mapped.length > 0.01, "perspective: pixel centroid is not the field center")
    }

    @Test func perspectiveFarSideIsMoreCompressedPerPixel() throws {
        let homography = try #require(Homography(from: trapezoid, to: field))
        let near = try #require(homography.apply(Vec2(340, 590)))
        let nearNext = try #require(homography.apply(Vec2(340, 580)))
        let far = try #require(homography.apply(Vec2(340, 130)))
        let farNext = try #require(homography.apply(Vec2(340, 140)))
        #expect(abs(farNext.y - far.y) > abs(nearNext.y - near.y))
    }

    @Test func rejectsDegenerateInput() {
        let collinear = [Vec2(0, 0), Vec2(1, 1), Vec2(2, 2), Vec2(3, 3)]
        #expect(Homography(from: collinear, to: field) == nil)
        #expect(Homography(from: Array(trapezoid.prefix(3)), to: field) == nil)
    }

    @Test func singularMatrixHasNoInverse() {
        let singular = Homography(matrix: [1, 2, 3, 2, 4, 6, 0, 0, 1])
        #expect(singular.inverse == nil)
    }

    private func diagonalIntersection(_ quad: [Vec2]) -> Vec2? {
        let (a, b, c, d) = (quad[0], quad[1], quad[2], quad[3])
        let r = c - a
        let s = d - b
        let denominator = r.cross(s)
        guard abs(denominator) > 1e-12 else { return nil }
        let t = (b - a).cross(s) / denominator
        return a + r * t
    }
}

@Suite struct ClipGeometryTests {
    private let corners: [[Double]] = [[210, 120], [470, 120], [640, 600], [40, 600]]

    @Test func cornersLandOnTheNineFootFieldRectangle() throws {
        let geometry = try ClipGeometry(config: ClipConfig(tableSize: "nineFoot", corners: corners))
        let half = geometry.table.halfExtents
        #expect(geometry.table.size == .nineFoot)
        expectClose(geometry.imageToTable.apply(geometry.pixelCorners[0]), Vec2(-half.x, -half.y))
        expectClose(geometry.imageToTable.apply(geometry.pixelCorners[1]), Vec2(half.x, -half.y))
        expectClose(geometry.imageToTable.apply(geometry.pixelCorners[2]), Vec2(half.x, half.y))
        expectClose(geometry.imageToTable.apply(geometry.pixelCorners[3]), Vec2(-half.x, half.y))
    }

    @Test func tableToImageIsTheInverse() throws {
        let geometry = try ClipGeometry(config: ClipConfig(tableSize: "sevenFoot", corners: corners))
        let pocket = try #require(geometry.table.pockets.first { $0.id == .sideTop })
        let pixel = try #require(geometry.tableToImage.apply(pocket.position))
        expectClose(geometry.imageToTable.apply(pixel), pocket.position)
    }

    @Test func rejectsUnknownSizeAndBadCorners() {
        #expect(throws: ClipConfigError.unknownTableSize("tenFoot")) {
            try ClipGeometry(config: ClipConfig(tableSize: "tenFoot", corners: corners))
        }
        #expect(throws: ClipConfigError.self) {
            try ClipGeometry(config: ClipConfig(tableSize: "nineFoot", corners: [[0, 0], [1, 1]]))
        }
        #expect(throws: ClipConfigError.self) {
            try ClipGeometry(config: ClipConfig(tableSize: "nineFoot",
                                                corners: [[0, 0], [1, 1], [2, 2], [3, 3]]))
        }
    }

    @Test func decodesCornersJSON() throws {
        let json = Data("""
        {"tableSize": "eightFoot", "corners": [[1, 2], [3, 4], [5, 6], [7, 8]], "notes": "n"}
        """.utf8)
        let config = try JSONDecoder().decode(ClipConfig.self, from: json)
        #expect(config.tableSize == "eightFoot")
        #expect(config.corners.count == 4)
    }
}

@Suite struct ContactSheetTests {
    @Test func samplesEvenlyIncludingBothEnds() {
        #expect(ContactSheet.sampleIndices(total: 60, count: 12).first == 0)
        #expect(ContactSheet.sampleIndices(total: 60, count: 12).last == 59)
        #expect(ContactSheet.sampleIndices(total: 60, count: 12).count == 12)
        #expect(ContactSheet.sampleIndices(total: 5, count: 12) == [0, 1, 2, 3, 4])
        #expect(ContactSheet.sampleIndices(total: 0, count: 12).isEmpty)
    }
}
