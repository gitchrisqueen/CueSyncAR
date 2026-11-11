//
//  TiltedPocketFitTests.swift
//  CueSync AR
//
//  The tilted-plane pocket fit against synthetic rays from a camera parked
//  at the head rail, the geometry of the owner's table (camera ~0.6 m above
//  the cushion noses, far pockets ~3.6 m away).
//

import CueSyncCore
import Foundation
import Testing
@testable import TableSpace

@Suite("Tilted pocket fit")
struct TiltedPocketFitTests {
    static let camera = Vec3(0.05, 0.0, 0.0)

    /// A table whose noses lie on a plane tilted by (slopeX, slopeZ),
    /// long axis pointing away from the camera.
    static func truth(size: TableSize = .eightFoot, slopeX: Double = 0, slopeZ: Double = 0,
                      depth: Double = 0.58) -> TableCalibration {
        let normal = Vec3(-slopeX, 1, -slopeZ).normalized
        // Long axis heads away from the camera (-z), tilted into the plane.
        let forward = Vec3(0, 0, -1)
        let x = (forward - normal * forward.dot(normal)).normalized
        let y = normal.cross(x).normalized
        let centreFlat = Vec3(0, 0, -(0.20 + size.playField.width / 2 + 1.0))
        let centre = Vec3(centreFlat.x, -depth + slopeX * centreFlat.x + slopeZ * centreFlat.z, centreFlat.z)
        return TableCalibration(origin: centre, xAxis: x * -1, yAxis: y * -1, size: size)
    }

    /// Rays from the camera to each pocket, with angular noise (radians)
    /// and optional per-pocket offsets on the plane (metres).
    static func rays(_ table: TableCalibration, pockets: [PocketID] = PocketID.allCases,
                     noise: Double = 0, offsets: [PocketID: Vec2] = [:],
                     seed: UInt64 = 7) -> [(pocket: PocketID, ray: TapRay)] {
        var state = seed
        func random() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53) - 0.5
        }
        let layout = Dictionary(uniqueKeysWithValues: Table(size: table.size).pockets.map { ($0.id, $0.position) })
        return pockets.map { pocket in
            let target = table.tableToWorld(layout[pocket]! + (offsets[pocket] ?? .zero))
            var direction = (target - camera).normalized
            direction = (direction + Vec3(random(), random(), random()) * (2 * noise)).normalized
            return (pocket, TapRay(origin: camera, direction: direction))
        }
    }

    @Test func recoversATiltedTableFromSixPockets() throws {
        let table = Self.truth(slopeX: -0.008, slopeZ: 0.004)
        let fit = try PocketCalibration.solveTilted(rays: Self.rays(table), size: .eightFoot)
        #expect(fit.residual < 0.001)
        #expect(abs(fit.tiltDegrees - 0.51) < 0.05, "tilt \(fit.tiltDegrees)")
        #expect(fit.calibration.origin.distance(to: table.origin) < 0.003)
        #expect(fit.leaveOneOut.count == 6)
        #expect(fit.dropped == nil)
    }

    @Test func aFlatFitOfTheSameTiltedTableIsCentimetresOut() throws {
        // Why the tilt is freed: four pockets of a 0.5 degree table fitted
        // flat. This is the 2026-11-11 failure in miniature.
        let table = Self.truth(slopeX: -0.008, slopeZ: 0.004)
        let four: [PocketID] = [.cornerTopLeft, .cornerTopRight, .cornerBottomRight, .cornerBottomLeft]
        let fit = try PocketCalibration.solveTilted(rays: Self.rays(table, pockets: four), size: .eightFoot)
        #expect(fit.tiltDegrees == 0, "four pockets must stay flat")
        #expect(fit.residual > 0.008)
        #expect(fit.leaveOneOut.isEmpty)
    }

    @Test func noisySixPocketFitStaysWithinTenMillimetres() throws {
        // 0.25 mrad per axis is about half a camera pixel on an iPad.
        let table = Self.truth(slopeX: 0.005, slopeZ: -0.006)
        for seed in [UInt64(1), 2, 3, 4, 5] {
            let fit = try PocketCalibration.solveTilted(
                rays: Self.rays(table, noise: 0.00025, seed: seed), size: .eightFoot)
            #expect(fit.residual < 0.010, "seed \(seed) residual \(fit.residual)")
            let corner = Table(size: .eightFoot).pockets[0].position
            #expect(fit.calibration.tableToWorld(corner).distance(to: table.tableToWorld(corner)) < 0.03)
        }
    }

    @Test func oneBadSightingOfSixIsDroppedAndNamed() throws {
        let table = Self.truth(slopeX: 0.003)
        let rays = Self.rays(table, offsets: [.cornerBottomRight: Vec2(0.07, -0.04)])
        let fit = try PocketCalibration.solveTilted(rays: rays, size: .eightFoot)
        #expect(fit.dropped == .cornerBottomRight)
        #expect(fit.pocketCount == 5)
        #expect(fit.residual < 0.002)
        #expect((fit.droppedError ?? 0) > 0.05)
        #expect(fit.summary.contains("dropped cornerBottomRight"))
    }

    @Test func noOutlierIsDroppedFromCleanSightings() throws {
        let fit = try PocketCalibration.solveTilted(rays: Self.rays(Self.truth()), size: .eightFoot)
        #expect(fit.dropped == nil)
        // Five pockets are never thinned: one fewer could not be checked.
        let five = Self.rays(Self.truth(), pockets: Array(PocketID.allCases.prefix(5)),
                             offsets: [.cornerTopLeft: Vec2(0.08, 0)])
        #expect(try PocketCalibration.solveTilted(rays: five, size: .eightFoot).dropped == nil)
    }

    @Test func loweredMovesTheTableDownItsNormal() throws {
        let table = Self.truth(slopeX: 0.01)
        let fit = try PocketCalibration.solveTilted(rays: Self.rays(table), size: .eightFoot)
        let cloth = fit.lowered(by: PocketSnap.noseHeight)
        #expect(abs((fit.calibration.origin - cloth.origin).length - PocketSnap.noseHeight) < 1e-9)
        #expect((fit.calibration.origin - cloth.origin).dot(fit.normal) > 0)
        #expect(cloth.xAxis == fit.calibration.xAxis)
    }

    @Test func nearCornersKnownOnlyAcrossTheTableDoNotPullTheFit() throws {
        // The near corners snapped onto the long noses keep the tap's guess
        // ALONG the rail: 4 and 6 cm out here. Free along, they cost
        // nothing; used as points, they drag the whole table.
        let table = Self.truth(slopeX: 0.004, slopeZ: -0.003)
        let offsets: [PocketID: Vec2] = [.cornerTopLeft: Vec2(0.04, 0), .cornerBottomLeft: Vec2(-0.06, 0)]
        let rays = Self.rays(table, offsets: offsets)
        let free: Set<PocketID> = [.cornerTopLeft, .cornerBottomLeft]
        let fit = try PocketCalibration.solveTilted(rays: rays, size: .eightFoot, alongFree: free)
        #expect(fit.residual < 0.001, "residual \(fit.residual)")
        #expect(fit.calibration.origin.distance(to: table.origin) < 0.003)
        #expect(fit.dropped == nil)
        let pinned = try PocketCalibration.solveTilted(rays: rays, size: .eightFoot, dropOutlier: false)
        #expect(pinned.residual > 0.015)
    }

    @Test func noPocketIsDroppedWhenTooLittleWouldBeLeftToCheckIt() throws {
        // Two along-free near corners: dropping a far corner would leave
        // eight measured coordinates for six unknowns, so nothing is dropped
        // even with a far corner 7 cm off. The bad pocket shows in the rms.
        let table = Self.truth(slopeX: 0.003)
        let rays = Self.rays(table, offsets: [.cornerBottomRight: Vec2(0.07, -0.04)])
        let free: Set<PocketID> = [.cornerTopLeft, .cornerBottomLeft]
        let fit = try PocketCalibration.solveTilted(rays: rays, size: .eightFoot, alongFree: free)
        #expect(fit.dropped == nil)
        #expect(fit.pocketCount == 6)
        #expect(fit.residual > 0.01)
    }

    @Test func rigidFitSlidesOnlyFlaggedPoints() {
        let model = [Vec2(-1, 0.5), Vec2(1, 0.5), Vec2(1, -0.5), Vec2(-1, -0.5)]
        var observed = model
        observed[0].x += 0.1
        let fixed = PocketCalibration.rigidFit(model: model, observed: observed,
                                               sliding: [false, false, false, false])
        let slid = PocketCalibration.rigidFit(model: model, observed: observed,
                                              sliding: [true, false, false, false])
        #expect(fixed.residual > 0.01)
        #expect(slid.residual < 1e-6)
        #expect(slid.observed[0].distance(to: model[0]) < 1e-6)
        #expect(slid.observed[1] == observed[1])
    }

    @Test func needsTwoPockets() {
        let rays = Self.rays(Self.truth(), pockets: [.cornerTopLeft])
        #expect(throws: PocketCalibration.Failure.needTwoPockets) {
            try PocketCalibration.solveTilted(rays: rays, size: .eightFoot)
        }
    }
}
