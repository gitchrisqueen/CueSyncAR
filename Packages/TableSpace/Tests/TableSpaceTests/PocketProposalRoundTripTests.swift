//
//  PocketProposalRoundTripTests.swift
//  CueSync AR
//
//  The pocket solver's answer has to survive the correction UI.
//
//  Today the in-app route for a pocket calibration does
//  `.resetRequested` then `.restored(solution)`, which jumps straight to
//  `.locked` and skips the four draggable handles entirely. That is fine
//  for a debug command typed by a careful operator; for a user it means a
//  table locks with no way to fix it and a residual printed as a toast
//  nobody can act on.
//
//  Routing it through `.cornersProposed` instead lands in `.adjusting`,
//  which is the correction UI — but `.lockRequested` RE-DERIVES the size
//  from those corners via `fromCorners`, and that snaps. So the solver's
//  size could silently become a different one on the way through.
//
//  These tests are the guard on that path. They are what makes the UI
//  change in C2b safe to write.
//

import CueSyncCore
import Foundation
import Testing
@testable import TableSpace

@Suite("Pocket solve survives the correction UI")
struct PocketProposalRoundTripTests {

    /// Build pocket sightings by asking a known calibration where its own
    /// pockets are, so the solver is being handed a perfect observation of
    /// a table we already know the answer for.
    private func sightings(of calibration: TableCalibration,
                           _ pockets: [PocketID]) -> [PocketCalibration.Sighting] {
        let table = Table(size: calibration.size)
        return pockets.compactMap { id -> PocketCalibration.Sighting? in
            guard let pocket = table.pockets.first(where: { $0.id == id }) else { return nil }
            return PocketCalibration.Sighting(pocket: id,
                                              world: calibration.tableToWorld(pocket.position))
        }
    }

    private func reference(size: TableSize, yaw: Double) throws -> TableCalibration {
        let up = Vec3(0, 1, 0)
        let xAxis = Vec3(cos(yaw), 0, sin(yaw)).normalized
        let yAxis = up.cross(xAxis).normalized
        return try TableCalibration(origin: Vec3(0.3, -0.65, -2.1),
                                    xAxis: xAxis, yAxis: yAxis, size: size)
    }

    @Test("A pocket solve round-trips through the corners the lock re-derives",
          arguments: [TableSize.sevenFoot, TableSize.eightFoot, TableSize.nineFoot])
    func roundTripPerStandardSize(size: TableSize) throws {
        let truth = try reference(size: size, yaw: 0.4)
        let solution = try PocketCalibration.solve(
            sightings(of: truth, [.cornerTopLeft, .cornerBottomRight, .sideTop]),
            size: size, planeNormal: Vec3(0, 1, 0))

        // The trip the UI will take: solved table -> its corners ->
        // fromCorners, exactly as `.cornersProposed` + `.lockRequested` do.
        let rebuilt = try TableCalibration.fromCorners(solution.calibration.worldCorners,
                                                       preferredSize: size)

        #expect(rebuilt.size == size, "the lock re-derived a different size")
        let originDrift = (rebuilt.origin - solution.calibration.origin).length
        #expect(originDrift < 0.005, "origin moved \(originDrift) m through the round trip")
        #expect(rebuilt.xAxis.dot(solution.calibration.xAxis) > 0.9999)
        #expect(rebuilt.yAxis.dot(solution.calibration.yAxis) > 0.9999)
    }

    @Test("Passing the solved size as preferred is what keeps it",
          arguments: [0.0, 0.4, 1.1, -0.9] as [Double])
    func preferredSizeIsLoadBearing(yaw: Double) throws {
        let truth = try reference(size: .eightFoot, yaw: yaw)
        let solution = try PocketCalibration.solve(
            sightings(of: truth, [.cornerTopLeft, .cornerTopRight, .cornerBottomLeft]),
            size: .eightFoot, planeNormal: Vec3(0, 1, 0))
        let rebuilt = try TableCalibration.fromCorners(solution.calibration.worldCorners,
                                                       preferredSize: .eightFoot)
        #expect(rebuilt.size == .eightFoot)
        #expect((rebuilt.origin - truth.origin).length < 0.005)
    }

    @Test("The one-pocket-plus-rail solve round-trips too")
    func onePocketPathRoundTrips() throws {
        let truth = try reference(size: .eightFoot, yaw: 0.25)
        let table = Table(size: .eightFoot)
        let pocket = try #require(table.pockets.first { $0.id == .sideTop })
        let sighting = PocketCalibration.Sighting(
            pocket: .sideTop, world: truth.tableToWorld(pocket.position))
        let solution = try PocketCalibration.solve(
            pocket: sighting,
            alongRail: truth.xAxis,
            size: .eightFoot,
            planeNormal: Vec3(0, 1, 0),
            towards: truth.origin)
        let rebuilt = try TableCalibration.fromCorners(solution.calibration.worldCorners,
                                                       preferredSize: .eightFoot)
        #expect(rebuilt.size == .eightFoot)
        #expect((rebuilt.origin - solution.calibration.origin).length < 0.005)
    }

    @Test("Two collinear pockets without a side are refused, not guessed")
    func collinearWithoutTowardsIsRefused() throws {
        let truth = try reference(size: .eightFoot, yaw: 0.0)
        // Both on the same long rail, no `towards`: the fit is
        // mirror-ambiguous and the solver must say so rather than pick.
        let onOneRail = sightings(of: truth, [.cornerTopLeft, .cornerTopRight])
        #expect(throws: (any Error).self) {
            _ = try PocketCalibration.solve(onOneRail, size: .eightFoot,
                                            planeNormal: Vec3(0, 1, 0))
        }
    }
}
