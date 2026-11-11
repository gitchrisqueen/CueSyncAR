//
//  CalibrationDriftTests.swift
//  TableSpace
//
//  Parked-device pose hold, stillness detection, the pocket homography
//  and the ball-ruler table-size classifier
//  (docs/plans/2026-11-11-calibration-drift-plan.md).
//

import CueSyncCore
import Foundation
import Testing
@testable import TableSpace

// MARK: - Helpers

/// Rigid pose: yaw about world Y (radians), then translation.
private func pose(yaw: Double = 0, pitch: Double = 0, at t: Vec3) -> Transform3D {
    let cy = cos(yaw), sy = sin(yaw), cp = cos(pitch), sp = sin(pitch)
    // R = Ry(yaw) * Rx(pitch)
    let x = Vec3(cy, 0, -sy)
    let y = Vec3(sy * sp, cp, cy * sp)
    let z = Vec3(sy * cp, -sp, cy * cp)
    return Transform3D(columns: [
        SIMD4(x.x, x.y, x.z, 0), SIMD4(y.x, y.y, y.z, 0),
        SIMD4(z.x, z.y, z.z, 0), SIMD4(t.x, t.y, t.z, 1)
    ])
}

private func close(_ a: Vec3, _ b: Vec3, _ tol: Double = 1e-9) -> Bool { a.distance(to: b) < tol }
private func close(_ a: Vec2, _ b: Vec2, _ tol: Double = 1e-9) -> Bool { a.distance(to: b) < tol }

/// Pinhole projection of a world point for a camera pose (camera looks
/// down -Z, image y down), focal 1000 px, centre (960, 720).
private func project(_ world: Vec3, camera: Transform3D) -> Vec2 {
    let local = AnchoredCalibration.invertRigid(camera).transformPoint(world)
    return Vec2(960 + 1000 * local.x / -local.z, 720 - 1000 * local.y / -local.z)
}

// MARK: - StillnessDetector

@Suite struct StillnessDetectorTests {
    @Test func tripodNoiseSettlesToStill() {
        var detector = StillnessDetector()
        var still = false
        for i in 0...60 { // 2 s at 30 Hz
            still = detector.add(time: Double(i) / 30, rotationRate: 0.004, userAcceleration: 0.002)
        }
        #expect(still)
    }

    @Test func notStillBeforeSettleTime() {
        var detector = StillnessDetector()
        for i in 0...30 { // 1 s < 1.5 s settle
            detector.add(time: Double(i) / 30, rotationRate: 0.001, userAcceleration: 0.001)
        }
        #expect(!detector.isStill)
    }

    @Test func handHeldMotionIsNotStill() {
        var detector = StillnessDetector()
        for i in 0...150 {
            let wobble = i % 10 == 0 ? 0.08 : 0.01
            detector.add(time: Double(i) / 30, rotationRate: wobble, userAcceleration: 0.01)
        }
        #expect(!detector.isStill)
    }

    @Test func oneJoltRestartsTheSettleClock() {
        var detector = StillnessDetector()
        for i in 0...90 { detector.add(time: Double(i) / 30, rotationRate: 0, userAcceleration: 0) }
        #expect(detector.isStill)
        detector.add(time: 3.1, rotationRate: 0.5, userAcceleration: 0.2)
        #expect(!detector.isStill)
        detector.add(time: 4.0, rotationRate: 0, userAcceleration: 0)
        #expect(!detector.isStill)
        detector.add(time: 4.7, rotationRate: 0, userAcceleration: 0)
        #expect(detector.isStill)
        detector.reset()
        #expect(!detector.isStill)
    }
}

// MARK: - ParkedPoseHold

@Suite struct ParkedPoseHoldTests {
    let lockPose = pose(yaw: 0.1, pitch: -0.4, at: Vec3(0, 0, 0))
    let ball = Vec3(0.2, -0.55, -2.0)

    @Test func disarmedPassesPosesThrough() {
        var hold = ParkedPoseHold()
        hold.update(cameraPose: lockPose, still: true)
        let drifted = pose(yaw: 0.1, pitch: -0.4, at: Vec3(0.3, 0, 0))
        hold.update(cameraPose: drifted, still: true)
        #expect(!hold.isHolding)
        #expect(hold.corrected(drifted) == drifted)
        #expect(hold.drift == nil)
    }

    /// The device run's failure, reproduced: the camera never moves but
    /// ARKit's estimate of it slides 30 cm and yaws a little. The corrected
    /// pose must stay at the lock-time pose, so a ball seen at the same
    /// pixel unprojects to the same place.
    @Test func stillDeviceDriftIsCancelled() throws {
        var hold = ParkedPoseHold()
        hold.setArmed(true)
        hold.update(cameraPose: lockPose, still: true)
        let pixel = project(ball, camera: lockPose)
        let drifted = pose(yaw: 0.13, pitch: -0.41, at: Vec3(0.3, 0.02, -0.05))
        hold.update(cameraPose: drifted, still: true)
        let corrected = hold.corrected(drifted)
        #expect(corrected.translation.distance(to: lockPose.translation) < 1e-9)
        #expect(PoseDelta(from: corrected, to: lockPose).rotationDegrees < 1e-6)
        // Overlay content at the corrected-world ball lands on the same
        // pixel through ARKit's drifted camera.
        let rendered = hold.toARKit(ball)
        #expect(close(project(rendered, camera: drifted), pixel, 1e-6))
        // And a tap through ARKit's world maps back to the corrected one.
        #expect(close(hold.fromARKit(rendered), ball))
        let delta = try #require(hold.drift)
        #expect(abs(delta.translation - Vec3(0.3, 0.02, -0.05).length) < 1e-9)
        #expect(delta.rotationDegrees > 1)
    }

    /// Real motion while not still is tracked by ARKit; the correction
    /// built up during the hold stays frozen, and a second hold composes.
    @Test func correctionFreezesThroughMotionAndComposes() {
        var hold = ParkedPoseHold()
        hold.setArmed(true)
        hold.update(cameraPose: lockPose, still: true)
        let drift = pose(at: Vec3(0.1, 0, 0))
        let drifted = drift * lockPose
        hold.update(cameraPose: drifted, still: true)
        // Physically move 0.5 m in z; ARKit reports it on top of its drift.
        let moved = drift * pose(yaw: 0.1, pitch: -0.4, at: Vec3(0, 0, 0.5))
        hold.update(cameraPose: moved, still: false)
        #expect(!hold.isHolding)
        #expect(close(hold.corrected(moved).translation, Vec3(0, 0, 0.5)))
        // Park again; ARKit drifts another 0.2 m in x.
        hold.update(cameraPose: moved, still: true)
        let movedDrifted = pose(at: Vec3(0.2, 0, 0)) * moved
        hold.update(cameraPose: movedDrifted, still: true)
        #expect(close(hold.corrected(movedDrifted).translation, Vec3(0, 0, 0.5)))
        #expect(abs(hold.correctionMagnitude.translation - 0.3) < 1e-9)
    }

    @Test func disarmingDropsTheCorrection() {
        var hold = ParkedPoseHold()
        hold.setArmed(true)
        hold.update(cameraPose: lockPose, still: true)
        hold.update(cameraPose: pose(at: Vec3(1, 0, 0)), still: true)
        #expect(hold.correctionMagnitude.translation > 0.5)
        hold.setArmed(false)
        #expect(hold.correction == .identity)
        #expect(!hold.isHolding)
    }

    @Test func poseDeltaMeasuresRotation() {
        let a = pose(yaw: 0, at: Vec3(0, 0, 0))
        let b = pose(yaw: .pi / 6, at: Vec3(0, 0, 0.02))
        let delta = PoseDelta(from: a, to: b)
        #expect(abs(delta.rotationDegrees - 30) < 1e-6)
        #expect(abs(delta.translation - 0.02) < 1e-12)
    }
}

// MARK: - Homography2D

@Suite struct Homography2DTests {
    let camera = pose(yaw: 0.05, pitch: -0.5, at: Vec3(0, 0.9, 1.6))

    /// Table plane y = 0, table x along world -z (long axis away from the
    /// camera), table y along world x.
    func world(_ table: Vec2) -> Vec3 { Vec3(table.y, 0, -table.x) }

    @Test func recoversTableFromPocketPixels() throws {
        let table = Table(size: .eightFoot)
        let sightings = table.pockets.filter { $0.id.rawValue.hasPrefix("corner") }.map {
            (pocket: $0.id, image: project(world($0.position), camera: camera))
        }
        let h = try Homography2D.fitPockets(sightings, size: .eightFoot)
        // Any cloth point, not just the pockets.
        for p in [Vec2(0.3, 0.2), Vec2(-0.9, -0.4), Vec2(1.0, 0.5)] {
            let mapped = try #require(h.apply(project(world(p), camera: camera)))
            #expect(close(mapped, p, 1e-6))
        }
    }

    @Test func sixPocketsGiveAResidualThatFlagsABadTap() throws {
        let table = Table(size: .eightFoot)
        var source = table.pockets.map { project(world($0.position), camera: camera) }
        let target = table.pockets.map(\.position)
        let clean = try Homography2D.fit(from: source, to: target)
        #expect(clean.residual(from: source, to: target) < 1e-6)
        source[0].x += 25 // one pocket 25 px off
        let noisy = try Homography2D.fit(from: source, to: target)
        // A least-squares fit spreads the bad tap over all six points, so
        // the rms is well under the tap error but three orders of
        // magnitude over the clean fit.
        #expect(noisy.residual(from: source, to: target) > 0.003)
    }

    @Test func refusesTooFewOrCollinearPoints() {
        #expect(throws: Homography2D.Failure.needFourPoints) {
            try Homography2D.fit(from: [Vec2(0, 0), Vec2(1, 0), Vec2(0, 1)],
                                 to: [Vec2(0, 0), Vec2(1, 0), Vec2(0, 1)])
        }
        #expect(throws: Homography2D.Failure.degenerate) {
            try Homography2D.fit(from: [Vec2(0, 0), Vec2(1, 0), Vec2(2, 0), Vec2(3, 0)],
                                 to: [Vec2(0, 0), Vec2(1, 0), Vec2(2, 0), Vec2(3, 0)])
        }
    }

    @Test func pointAtInfinityIsNil() {
        let h = Homography2D(m: [1, 0, 0, 0, 1, 0, 1, 0, 0])
        #expect(h.apply(Vec2(0, 5)) == nil)
    }
}

// MARK: - TableSizeFromBalls

@Suite struct TableSizeFromBallsTests {
    /// Pocket rays from a camera 1.0 m above an 8 ft table imply depth
    /// proportional to size: 8 ft at 1.0, 7 ft at 1.0*1.98/2.34, 9 ft at
    /// 1.0*2.54/2.34. Balls measuring the true 1.0 m depth pick 8 ft.
    func solved(depth8: Double, camera: Double) -> [(size: TableSize, height: Double)] {
        TableSize.standardSizes.map {
            ($0, camera - depth8 * $0.playField.width / TableSize.eightFoot.playField.width)
        }
    }

    @Test func ballsAtTheEightFootDepthPickEightFoot() throws {
        let verdict = try #require(TableSizeFromBalls.classify(
            cameraHeight: 0.2, ballClothHeight: -0.8, ballSpread: 0.01,
            solvedHeights: solved(depth8: 1.0, camera: 0.2)))
        #expect(verdict.nearest == .eightFoot)
        #expect(abs(verdict.impliedLength - 2.34) < 1e-9)
        #expect(verdict.isDecisive)
    }

    @Test func ballsFurtherAwayPickNineFoot() throws {
        let depth9 = 1.0 * 2.54 / 2.34
        let verdict = try #require(TableSizeFromBalls.classify(
            cameraHeight: 0, ballClothHeight: -depth9, ballSpread: 0.005,
            solvedHeights: solved(depth8: 1.0, camera: 0)))
        #expect(verdict.nearest == .nineFoot)
        #expect(verdict.isDecisive)
    }

    @Test func noisyBallsAreNotDecisive() throws {
        let verdict = try #require(TableSizeFromBalls.classify(
            cameraHeight: 0, ballClothHeight: -1.03, ballSpread: 0.08,
            solvedHeights: solved(depth8: 1.0, camera: 0)))
        #expect(!verdict.isDecisive)
        #expect(verdict.summary.contains("not decisive"))
    }

    @Test func deviceRunNumbersSayEightFoot() throws {
        // 2026-11-11 lock: taps solved y=-0.552 for 8 ft, balls -0.533,
        // spread 9 mm, camera near the session origin.
        let verdict = TableSizeFromBalls.classify(impliedLength: 2.34 * 0.533 / 0.552,
                                                  uncertainty: 2.26 * 0.009 / 0.533)
        #expect(verdict.nearest == .eightFoot)
    }

    @Test func cameraBelowClothGivesNil() {
        #expect(TableSizeFromBalls.classify(cameraHeight: -1, ballClothHeight: 0,
                                            ballSpread: 0.01, solvedHeights: []) == nil)
    }
}
