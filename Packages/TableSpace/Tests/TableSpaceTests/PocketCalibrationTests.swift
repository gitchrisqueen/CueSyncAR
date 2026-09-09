//
//  PocketCalibrationTests.swift
//  TableSpaceTests
//
//  Every test here works the same way: take a table whose truth is known,
//  sight some of its pockets, fit, and check the fit reproduces the table
//  it came from. A rigid fit always returns something, so most of these
//  are about the cases where "something" would be wrong.
//

import CueSyncCore
import Foundation
import Testing

@testable import TableSpace

@Suite("Pocket calibration")
struct PocketCalibrationTests {

    /// A table lying in the y = height plane, rotated by `yaw` about up
    /// and moved to `centre`. World up is +y, matching the app.
    ///
    /// `yAxis` is derived as up × xAxis rather than written out, so that
    /// `normal` (which TableCalibration defines as x × y) really is up.
    /// Writing the pair by hand gets this wrong: the obvious-looking
    /// (-sin, 0, cos) gives a table whose normal points into the floor.
    private func table(size: TableSize = .eightFoot, yaw: Double = 0,
                       centre: Vec3 = Vec3(0, 0, 0)) -> TableCalibration {
        let up = Vec3(0, 1, 0)
        let xAxis = Vec3(cos(yaw), 0, sin(yaw))
        let yAxis = up.cross(xAxis).normalized
        return TableCalibration(origin: centre, xAxis: xAxis, yAxis: yAxis, size: size)
    }

    private func sightings(of truth: TableCalibration, _ ids: [PocketID],
                           noise: [Vec3] = []) -> [PocketCalibration.Sighting] {
        let layout = Table(size: truth.size).pockets
        return ids.enumerated().compactMap { index, id in
            guard let pocket = layout.first(where: { $0.id == id }) else { return nil }
            let jitter = index < noise.count ? noise[index] : .zero
            return PocketCalibration.Sighting(pocket: id,
                                              world: truth.tableToWorld(pocket.position) + jitter)
        }
    }

    private func expectMatches(_ solution: PocketCalibration.Solution,
                               _ truth: TableCalibration,
                               tolerance: Double = 1e-6,
                               _ what: String) {
        let fitted = solution.calibration
        #expect(fitted.origin.distance(to: truth.origin) < tolerance,
                "\(what): origin off by \(fitted.origin.distance(to: truth.origin)) m")
        #expect(fitted.xAxis.distance(to: truth.xAxis) < tolerance,
                "\(what): x axis \(fitted.xAxis) vs \(truth.xAxis)")
        #expect(fitted.yAxis.distance(to: truth.yAxis) < tolerance,
                "\(what): y axis \(fitted.yAxis) vs \(truth.yAxis)")
    }

    // MARK: - It finds the table it came from

    @Test("All six pockets reproduce the table exactly")
    func allSixPocketsRecoverTheTable() throws {
        for yaw in [0.0, 0.4, 1.9, -2.7] {
            let truth = table(yaw: yaw, centre: Vec3(1.3, -0.57, -0.8))
            let solution = try PocketCalibration.solve(
                sightings(of: truth, PocketID.allCases),
                size: .eightFoot, planeNormal: Vec3(0, 1, 0))
            expectMatches(solution, truth, "yaw \(yaw)")
            #expect(solution.residual < 1e-9)
        }
    }

    @Test("Two corners at one end are enough, given a point on the cloth")
    func twoPocketsWithAHintAreEnough() throws {
        let truth = table(yaw: 0.7, centre: Vec3(0.4, -0.6, 2.1))
        let solution = try PocketCalibration.solve(
            sightings(of: truth, [.cornerTopLeft, .cornerBottomLeft]),
            size: .eightFoot, planeNormal: Vec3(0, 1, 0),
            towards: truth.tableToWorld(Vec2(0.5, 0)))
        expectMatches(solution, truth, tolerance: 1e-5, "two corners")
    }

    @Test("The three pockets of one long rail are enough, given a point on the cloth")
    func oneRailWithAHintIsEnough() throws {
        // The owner's actual case: a device parked at the side sees the
        // far rail's three pockets and nothing else.
        let truth = table(yaw: -0.35, centre: Vec3(-0.9, -0.57, 1.2))
        let solution = try PocketCalibration.solve(
            sightings(of: truth, [.cornerTopLeft, .sideTop, .cornerTopRight]),
            size: .eightFoot, planeNormal: Vec3(0, 1, 0),
            towards: truth.tableToWorld(Vec2(0, -0.4)))
        expectMatches(solution, truth, tolerance: 1e-5, "far rail")
    }

    // MARK: - The ways it must refuse

    @Test("One pocket says nothing about which way the table points")
    func onePocketIsRefused() {
        let truth = table()
        #expect(throws: PocketCalibration.Failure.needTwoPockets) {
            try PocketCalibration.solve(sightings(of: truth, [.sideTop]),
                                        size: .eightFoot, planeNormal: Vec3(0, 1, 0))
        }
    }

    @Test("The same pocket sighted twice is still one pocket")
    func repeatedPocketIsNotTwo() {
        let truth = table()
        let one = sightings(of: truth, [.sideTop])
        #expect(throws: PocketCalibration.Failure.needTwoPockets) {
            try PocketCalibration.solve(one + one + one,
                                        size: .eightFoot, planeNormal: Vec3(0, 1, 0))
        }
    }

    @Test("Pockets on one rail, with no cloth point, are refused rather than guessed")
    func collinearWithoutAHintIsRefused() {
        // Both answers fit perfectly and they differ by the whole width of
        // the table. Choosing by luck would put the playing surface on the
        // wrong side of the rail.
        let truth = table()
        #expect(throws: PocketCalibration.Failure.ambiguousSide) {
            try PocketCalibration.solve(
                sightings(of: truth, [.cornerTopLeft, .sideTop, .cornerTopRight]),
                size: .eightFoot, planeNormal: Vec3(0, 1, 0))
        }
    }

    @Test("A degenerate plane normal is refused")
    func degeneratePlaneIsRefused() {
        let truth = table()
        #expect(throws: PocketCalibration.Failure.degenerate) {
            try PocketCalibration.solve(
                sightings(of: truth, [.cornerTopLeft, .cornerBottomRight]),
                size: .eightFoot, planeNormal: .zero)
        }
    }

    // MARK: - The properties that keep it honest

    @Test("The hint picks the side the cloth is actually on")
    func hintDecidesTheSide() throws {
        let truth = table(yaw: 1.1, centre: Vec3(0.2, -0.5, 0.3))
        let rail: [PocketID] = [.cornerTopLeft, .sideTop, .cornerTopRight]
        // A ball near the far rail and one near the near rail must both
        // produce the SAME table — the hint says which side the cloth is,
        // not where the ball is.
        for offset in [-0.05, -0.5] {
            let solution = try PocketCalibration.solve(
                sightings(of: truth, rail), size: .eightFoot,
                planeNormal: Vec3(0, 1, 0),
                towards: truth.tableToWorld(Vec2(0, offset)))
            expectMatches(solution, truth, tolerance: 1e-5, "hint at y=\(offset)")
        }
    }

    @Test("Sightings set position and heading, never size")
    func sightingsNeverChangeTheSize() throws {
        // Two corners sighted 8 cm too close together. A fit that let the
        // measurement set scale would shrink the table; this one must not.
        let truth = table(yaw: 0.25)
        var seen = sightings(of: truth, [.cornerTopLeft, .cornerTopRight])
        seen[0].world += truth.xAxis * 0.04
        seen[1].world -= truth.xAxis * 0.04
        let solution = try PocketCalibration.solve(
            seen, size: .eightFoot, planeNormal: Vec3(0, 1, 0),
            towards: truth.tableToWorld(Vec2(0, -0.3)))
        #expect(solution.calibration.size == .eightFoot)
        let corners = solution.calibration.worldCorners
        let long = corners[0].distance(to: corners[1])
        #expect(abs(long - TableSize.eightFoot.playField.width) < 1e-6,
                "long axis measured \(long)")
    }

    @Test("The fitted table is right way up, whichever way the pockets were sighted")
    func handednessFollowsTheClothNormal() throws {
        let up = Vec3(0, 1, 0)
        let truth = table(yaw: 2.2, centre: Vec3(0, -0.57, 0))
        let solution = try PocketCalibration.solve(
            sightings(of: truth, PocketID.allCases).reversed(),
            size: .eightFoot, planeNormal: up)
        // x cross y is the table's own normal, and it must agree with the
        // cloth's rather than pointing into the floor.
        #expect(solution.calibration.normal.dot(up) > 0.999,
                "normal \(solution.calibration.normal)")
    }

    @Test("Noise spreads across the fit instead of landing on one pocket")
    func noiseIsSharedNotConcentrated() throws {
        let truth = table(yaw: -0.6, centre: Vec3(0.5, -0.57, 0.5))
        // Two centimetres of sighting error on one corner only.
        let noise = [Vec3(0.02, 0, 0.0)] + Array(repeating: Vec3.zero, count: 5)
        let solution = try PocketCalibration.solve(
            sightings(of: truth, PocketID.allCases, noise: noise),
            size: .eightFoot, planeNormal: Vec3(0, 1, 0))
        // A least-squares fit moves the whole table a little rather than
        // leaving the bad pocket 2 cm out, so the worst error is under the
        // error that was put in.
        #expect(solution.worstError < 0.02)
        #expect(solution.residual < 0.01)
        // And the table barely moves: one bad pocket in six is outvoted.
        #expect(solution.calibration.origin.distance(to: truth.origin) < 0.01)
    }

    @Test("A pocket sighted on the wrong hole shows up in the residual")
    func mislabelledPocketIsVisible() throws {
        let truth = table(yaw: 0.9, centre: Vec3(0, -0.57, 0))
        var seen = sightings(of: truth, PocketID.allCases)
        // Say "top left" while pointing at where the side pocket is: the
        // fit still returns a table, and the residual is how a caller
        // finds out not to trust it.
        let layout = Table(size: .eightFoot).pockets
        let sidePosition = try #require(layout.first { $0.id == .sideTop }).position
        seen[0] = PocketCalibration.Sighting(pocket: .cornerTopLeft,
                                             world: truth.tableToWorld(sidePosition))
        let solution = try PocketCalibration.solve(seen, size: .eightFoot,
                                                   planeNormal: Vec3(0, 1, 0))
        #expect(solution.residual > 0.1,
                "a metre-scale mislabel produced residual \(solution.residual)")
    }

    @Test("Several looks at the same pockets average rather than double-count")
    func repeatedSightingsAverage() throws {
        let truth = table(yaw: 0.3, centre: Vec3(0, -0.57, 0))
        let clean = sightings(of: truth, PocketID.allCases)
        var noisy = clean
        noisy[0].world += Vec3(0.03, 0, 0)
        let averaged = try PocketCalibration.solve(clean + noisy, size: .eightFoot,
                                                   planeNormal: Vec3(0, 1, 0))
        let onceOnly = try PocketCalibration.solve(noisy, size: .eightFoot,
                                                   planeNormal: Vec3(0, 1, 0))
        // Averaging halves that pocket's error, so the fit is strictly
        // better than the single noisy look.
        #expect(averaged.worstError < onceOnly.worstError)
    }

    @Test("A seven-foot table is fitted as a seven-foot table")
    func sizeIsHonoured() throws {
        let truth = table(size: .sevenFoot, yaw: 0.15, centre: Vec3(0, -0.57, 0))
        let solution = try PocketCalibration.solve(
            sightings(of: truth, PocketID.allCases),
            size: .sevenFoot, planeNormal: Vec3(0, 1, 0))
        expectMatches(solution, truth, "seven foot")
        #expect(solution.calibration.size == .sevenFoot)
    }

    @Test("A tilted cloth is fitted in its own plane, not a level one")
    func tiltedClothIsHonoured() throws {
        // ARKit's world is gravity-aligned but a calibration solved from
        // ball silhouettes can come out a degree or two off level, and the
        // fit must live in the plane it was handed.
        let tilt = 0.05
        let normal = Vec3(sin(tilt), cos(tilt), 0).normalized
        let xAxis = Vec3(cos(tilt), -sin(tilt), 0).normalized
        let yAxis = normal.cross(xAxis).normalized
        let truth = TableCalibration(origin: Vec3(0.2, -0.5, 0.4), xAxis: xAxis,
                                     yAxis: yAxis, size: .eightFoot)
        let solution = try PocketCalibration.solve(
            sightings(of: truth, PocketID.allCases),
            size: .eightFoot, planeNormal: normal)
        expectMatches(solution, truth, tolerance: 1e-5, "tilted cloth")
    }

    // MARK: - One pocket and a rail direction

    @Test("One pocket plus a rail direction reproduces the table")
    func onePocketAndAHeadingRecoverTheTable() throws {
        for yaw in [0.0, 0.6, -1.4, 2.9] {
            let truth = table(yaw: yaw, centre: Vec3(0.7, -0.57, -1.1))
            let seen = try #require(sightings(of: truth, [.sideBottom]).first)
            let solution = try PocketCalibration.solve(
                pocket: seen, alongRail: truth.xAxis, size: .eightFoot,
                planeNormal: Vec3(0, 1, 0),
                towards: truth.tableToWorld(Vec2(0.3, 0.2)))
            expectMatches(solution, truth, tolerance: 1e-5, "one pocket at yaw \(yaw)")
        }
    }

    @Test("The rail direction's sign does not matter")
    func railDirectionSignIsIrrelevant() throws {
        let truth = table(yaw: 0.8, centre: Vec3(0, -0.57, 0))
        let seen = try #require(sightings(of: truth, [.sideBottom]).first)
        let hint = truth.tableToWorld(Vec2(0, 0.3))
        let forward = try PocketCalibration.solve(
            pocket: seen, alongRail: truth.xAxis, size: .eightFoot,
            planeNormal: Vec3(0, 1, 0), towards: hint)
        let backward = try PocketCalibration.solve(
            pocket: seen, alongRail: truth.xAxis * -1, size: .eightFoot,
            planeNormal: Vec3(0, 1, 0), towards: hint)
        // A table pointing the other way along its own long axis is the
        // same table: same field, same pockets, same playing surface.
        #expect(forward.calibration.origin.distance(to: backward.calibration.origin) < 1e-6)
        #expect(abs(forward.calibration.normal.dot(backward.calibration.normal) - 1) < 1e-9)
    }

    @Test("The hint puts the cloth on the right side of the rail")
    func onePocketHintPicksTheSide() throws {
        let truth = table(yaw: -0.2, centre: Vec3(0, -0.57, 0))
        let seen = try #require(sightings(of: truth, [.sideBottom]).first)
        let solution = try PocketCalibration.solve(
            pocket: seen, alongRail: truth.xAxis, size: .eightFoot,
            planeNormal: Vec3(0, 1, 0),
            towards: truth.tableToWorld(Vec2(0, 0.4)))
        // Getting this backwards would put the whole playing surface on
        // the far side of the rail — 1.17 m out, every ball off-table.
        let hint = truth.tableToWorld(Vec2(0, 0.4))
        #expect(PocketCalibration.outside(hint, of: solution.calibration,
                                          size: .eightFoot) < 1e-9)
    }

    @Test("A rail direction not quite in the cloth plane is flattened, not refused")
    func railDirectionIsFlattenedIntoThePlane() throws {
        let truth = table(yaw: 0.45, centre: Vec3(0, -0.57, 0))
        let seen = try #require(sightings(of: truth, [.sideBottom]).first)
        // A direction read off an image carries a little out-of-plane tilt.
        let tilted = (truth.xAxis + Vec3(0, 0.08, 0)).normalized
        let solution = try PocketCalibration.solve(
            pocket: seen, alongRail: tilted, size: .eightFoot,
            planeNormal: Vec3(0, 1, 0),
            towards: truth.tableToWorld(Vec2(0.2, 0.2)))
        expectMatches(solution, truth, tolerance: 1e-5, "tilted rail direction")
    }

    @Test("A rail direction along the plane normal is refused")
    func degenerateRailDirectionIsRefused() throws {
        let truth = table()
        let seen = try #require(sightings(of: truth, [.sideBottom]).first)
        #expect(throws: PocketCalibration.Failure.degenerate) {
            try PocketCalibration.solve(
                pocket: seen, alongRail: Vec3(0, 1, 0), size: .eightFoot,
                planeNormal: Vec3(0, 1, 0), towards: truth.origin)
        }
    }

    @Test("One pocket's residual is zero and that is not evidence")
    func onePocketResidualIsNotEvidence() throws {
        // Pinned deliberately: a single point is reproduced exactly by
        // construction, so anyone reading `residual` to decide whether to
        // trust a one-pocket fit is reading a number that cannot fail.
        let truth = table(yaw: 1.0, centre: Vec3(0, -0.57, 0))
        let seen = try #require(sightings(of: truth, [.sideBottom]).first)
        let solution = try PocketCalibration.solve(
            pocket: seen, alongRail: truth.xAxis, size: .eightFoot,
            planeNormal: Vec3(0, 1, 0), towards: truth.tableToWorld(Vec2(0, 0.3)))
        #expect(solution.residual < 1e-9)
    }

    @Test("Every one-pocket fit is right way up, for any rail direction and any side")
    func onePocketFitIsAlwaysRightWayUp() throws {
        // The defect this pins: choosing the short axis by where the cloth
        // is can leave the axis pair left-handed, and then the table's
        // normal points into the floor. Origin and field look perfect, so
        // nothing else catches it — heights simply come out negative.
        let up = Vec3(0, 1, 0)
        for yaw in [0.0, 0.5, 1.7, -2.2, 3.0] {
            for sign in [1.0, -1.0] {
                for side in [0.35, -0.35] {
                    let truth = table(yaw: yaw, centre: Vec3(0, -0.57, 0))
                    let seen = try #require(sightings(of: truth, [.sideBottom]).first)
                    let solution = try PocketCalibration.solve(
                        pocket: seen, alongRail: truth.xAxis * sign, size: .eightFoot,
                        planeNormal: up,
                        towards: truth.tableToWorld(Vec2(0, side)))
                    let where_ = "yaw \(yaw) sign \(sign) side \(side)"
                    #expect(solution.calibration.normal.dot(up) > 0.999,
                            "\(where_): normal \(solution.calibration.normal)")
                    // And it is still the same physical rectangle.
                    #expect(solution.calibration.origin.distance(to: truth.origin) < 1e-5,
                            "\(where_): origin moved")
                }
            }
        }
    }
}
