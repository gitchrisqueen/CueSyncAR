//
//  PocketVerificationRingTests.swift
//  CueSync AR
//
//  The rings the user checks the calibration against.
//
//  Before locking, the overlay draws all six pockets the candidate
//  calibration DERIVES back onto the cloth. The point is that a person can
//  look at real holes and say yes or no — no residual, no trust required.
//
//  For that to be worth anything the rings have to be honest in both
//  directions, and the two tests here are exactly those directions:
//
//  1. A good fit must put the rings in the holes, including the two side
//     pockets nobody tapped. That is what makes a pass meaningful.
//  2. A bad fit must move them somewhere a person can SEE. A ring that
//     drifts three millimetres off a mis-tapped table is decoration; the
//     check only has teeth if the error reaches the eye.
//
//  The overlay itself lives behind `#if canImport(ARKit) &&
//  !targetEnvironment(simulator)` and is not compiled into any test
//  binary. The geometry it draws is all here.
//

import CueSyncCore
import Foundation
import Testing
@testable import TableSpace

@Suite("Pocket verification rings")
struct PocketVerificationRingTests {

    /// A pocket mouth is roughly 110–120 mm across on an eight-foot table,
    /// so a ring more than about half that from the truth is already
    /// hanging off the hole and onto the cloth.
    private static let visibleMiss = 0.06

    private func reference(yaw: Double = 0.35) throws -> TableCalibration {
        let up = Vec3(0, 1, 0)
        let xAxis = Vec3(cos(yaw), 0, sin(yaw)).normalized
        let yAxis = up.cross(xAxis).normalized
        return TableCalibration(origin: Vec3(0.2, -0.72, -1.8),
                                    xAxis: xAxis, yAxis: yAxis, size: .eightFoot)
    }

    private func worldPocket(_ id: PocketID, of calibration: TableCalibration) throws -> Vec3 {
        let table = Table(size: calibration.size)
        let pocket = try #require(table.pockets.first { $0.id == id })
        return calibration.tableToWorld(pocket.position)
    }

    /// Every ring the overlay would draw, keyed by pocket.
    private func rings(of calibration: TableCalibration) -> [PocketID: Vec3] {
        let table = Table(size: calibration.size)
        return Dictionary(uniqueKeysWithValues: table.pockets.map {
            ($0.id, calibration.tableToWorld($0.position))
        })
    }

    private func sightings(of calibration: TableCalibration,
                           _ ids: [PocketID]) throws -> [PocketCalibration.Sighting] {
        try ids.map {
            PocketCalibration.Sighting(pocket: $0, world: try worldPocket($0, of: calibration))
        }
    }

    @Test("Four tapped corners put all six rings in the real holes")
    func goodFitLandsInTheHoles() throws {
        let truth = try reference()
        let tapped: [PocketID] = [.cornerTopLeft, .cornerTopRight,
                                  .cornerBottomLeft, .cornerBottomRight]
        let solution = try PocketCalibration.solve(
            try sightings(of: truth, tapped), size: .eightFoot, planeNormal: Vec3(0, 1, 0))

        let drawn = rings(of: solution.calibration)
        let expected = rings(of: truth)
        for (id, position) in drawn {
            let miss = (position - expected[id]!).length
            #expect(miss < 0.005, "ring for \(id) sits \(miss) m from the real pocket")
        }

        // The two side pockets were never tapped. They are the ones that
        // make this a check rather than an echo of the user's own input.
        for side in [PocketID.sideTop, .sideBottom] {
            #expect(!tapped.contains(side))
            let miss = (drawn[side]! - expected[side]!).length
            #expect(miss < 0.005, "untapped side pocket \(side) is \(miss) m out")
        }
    }

    @Test("A pocket tapped on the wrong hole throws a ring off the table")
    func mislabelledTapIsVisible() throws {
        let truth = try reference()
        // The classic slip: the far corners look alike from across the
        // room, and the user labels one as its diagonal opposite.
        var wrong = try sightings(of: truth, [.cornerTopLeft, .cornerTopRight,
                                              .cornerBottomLeft, .cornerBottomRight])
        wrong[3] = PocketCalibration.Sighting(
            pocket: .cornerBottomRight, world: try worldPocket(.cornerTopLeft, of: truth))

        let solution = try PocketCalibration.solve(
            wrong, size: .eightFoot, planeNormal: Vec3(0, 1, 0))
        let drawn = rings(of: solution.calibration)
        let expected = rings(of: truth)

        let worst = drawn.map { ($0.value - expected[$0.key]!).length }.max() ?? 0
        #expect(worst > Self.visibleMiss,
                "worst ring is only \(worst) m out — a person could not see this")
    }

    @Test("A tilted-plane fit still draws its rings on its own cloth")
    func ringsFollowTheFittedPlane() throws {
        let truth = try reference()
        let solution = try PocketCalibration.solve(
            try sightings(of: truth, [.cornerTopLeft, .cornerTopRight,
                                      .cornerBottomLeft, .cornerBottomRight]),
            size: .eightFoot, planeNormal: Vec3(0, 1, 0))
        let calibration = solution.calibration
        let normal = calibration.xAxis.cross(calibration.yAxis).normalized
        for (id, position) in rings(of: calibration) {
            let outOfPlane = abs((position - calibration.origin).dot(normal))
            #expect(outOfPlane < 0.001, "ring \(id) floats \(outOfPlane) m off the cloth")
        }
    }
}
