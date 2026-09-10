//
//  PocketSpanCheckTests.swift
//  CueSync AR
//
//  The span report exists to tell two failures apart, so these tests are
//  one per failure plus the case where it must not cry wolf.
//

import CueSyncCore
import Foundation
import Testing
@testable import TableSpace

@Suite("Pocket span check")
struct PocketSpanCheckTests {

    private func reference(yaw: Double = 0.3) -> TableCalibration {
        let up = Vec3(0, 1, 0)
        let xAxis = Vec3(cos(yaw), 0, sin(yaw)).normalized
        return TableCalibration(origin: Vec3(0, -0.7, -2),
                                xAxis: xAxis, yAxis: up.cross(xAxis).normalized,
                                size: .eightFoot)
    }

    private func sightings(of calibration: TableCalibration,
                           _ ids: [PocketID]) throws -> [PocketCalibration.Sighting] {
        let table = Table(size: calibration.size)
        return try ids.map { id in
            let pocket = try #require(table.pockets.first { $0.id == id })
            return PocketCalibration.Sighting(pocket: id,
                                              world: calibration.tableToWorld(pocket.position))
        }
    }

    private let allSix: [PocketID] = [.cornerTopLeft, .cornerTopRight, .cornerBottomLeft,
                                      .cornerBottomRight, .sideTop, .sideBottom]

    @Test("Perfect sightings measure the table they came from")
    func perfectSightingsScaleToOne() throws {
        let report = PocketCalibration.spanReport(
            try sightings(of: reference(), allSix), size: .eightFoot)
        #expect(abs(report.medianRatio - 1) < 0.001)
        #expect(report.worstDisagreement < 0.001)
    }

    @Test("A wrong cloth height shows up as one common scale, not a bad pocket",
          arguments: [0.85, 0.93, 1.08] as [Double])
    func heightErrorScalesEverything(scale: Double) throws {
        // Casting against a plane at the wrong depth moves every point
        // along its own ray from the camera, which is a scaling about
        // the camera — so simulate it as exactly that.
        let camera = Vec3(0, 0.4, 1.5)
        let scaled = try sightings(of: reference(), allSix).map {
            PocketCalibration.Sighting(pocket: $0.pocket,
                                       world: camera + ($0.world - camera) * scale)
        }
        let report = PocketCalibration.spanReport(scaled, size: .eightFoot)
        #expect(abs(report.medianRatio - scale) < 0.01,
                "median ratio \(report.medianRatio) did not recover the scale")
        // The whole point: no pocket is blamed for what the plane did.
        #expect(report.worstDisagreement < 0.02,
                "a uniform scale error was misreported as a bad tap")
    }

    @Test("One pocket on the wrong hole is named")
    func mislabelledPocketIsNamed() throws {
        var wrong = try sightings(of: reference(), allSix)
        // Tap the top-left hole but call it the bottom-left one.
        let topLeft = try #require(wrong.first { $0.pocket == .cornerTopLeft }).world
        wrong = wrong.map {
            $0.pocket == .cornerBottomLeft
                ? PocketCalibration.Sighting(pocket: .cornerBottomLeft, world: topLeft)
                : $0
        }
        let report = PocketCalibration.spanReport(wrong, size: .eightFoot)
        #expect(report.suspectPocket == .cornerBottomLeft)
        #expect(report.worstDisagreement > 0.08,
                "the bad pocket was only \(report.worstDisagreement) m out — under the bar")
        // And it must not be mistaken for a height problem.
        #expect(abs(report.medianRatio - 1) < 0.1)
    }

    @Test("Two pockets accuse nobody, because there is nothing to outvote")
    func twoPocketsNameNoSuspect() throws {
        let report = PocketCalibration.spanReport(
            try sightings(of: reference(), [.cornerTopLeft, .cornerBottomRight]),
            size: .eightFoot)
        #expect(report.suspectPocket == nil)
        #expect(report.worstDisagreement == 0)
    }

    @Test("The same pocket sighted twice does not fake a zero-length span")
    func repeatedSightingsAreAveraged() throws {
        let once = try sightings(of: reference(), allSix)
        let twice = once + once
        let report = PocketCalibration.spanReport(twice, size: .eightFoot)
        #expect(report.spans.count == PocketCalibration.spanReport(once, size: .eightFoot).spans.count)
        #expect(abs(report.medianRatio - 1) < 0.001)
    }
}
