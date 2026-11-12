//
//  ParkedPoseHoldRearmTests.swift
//  TableSpace
//
//  Re-arming the parked hold must not move the locked table
//  (docs/roadmap/09-SESSION-STATE.md, 2026-11-12). Pure: poses in, poses out.
//

import CueSyncCore
import Foundation
import Testing
@testable import TableSpace

/// Rigid pose: yaw about world Y (radians), then translation.
private func pose(yaw: Double = 0, at t: Vec3) -> Transform3D {
    let cy = cos(yaw), sy = sin(yaw)
    return Transform3D(columns: [
        SIMD4(cy, 0, -sy, 0), SIMD4(0, 1, 0, 0),
        SIMD4(sy, 0, cy, 0), SIMD4(t.x, t.y, t.z, 1)
    ])
}

/// The largest distance between two poses' axes (rotation) and origins.
private func poseGap(_ a: Transform3D, _ b: Transform3D) -> Double {
    var gap = a.translation.distance(to: b.translation)
    for axis in 0..<3 { gap = max(gap, a.axis(axis).distance(to: b.axis(axis))) }
    return gap
}

/// The table's four corners (corrected world) as the camera sees them
/// through `camera`, in metres in the camera's frame. Comparing these before
/// and after a switch is "the table moved in the image", in millimetres.
private func cornersInCamera(_ camera: Transform3D) -> [Vec3] {
    let corners = [Vec3(-0.6, -0.8, -1.4), Vec3(0.6, -0.8, -1.4),
                   Vec3(0.6, -0.8, -2.6), Vec3(-0.6, -0.8, -2.6)]
    let inverse = AnchoredCalibration.invertRigid(camera)
    return corners.map { inverse.transformPoint($0) }
}

private func shift(_ a: [Vec3], _ b: [Vec3]) -> Double {
    zip(a, b).map { $0.distance(to: $1) }.max() ?? 0
}

/// ARKit's drifting estimate of a camera that never moves: `step` grows the
/// error by 0.4 degrees of yaw and 1 cm.
private func drifted(_ lock: Transform3D, step: Int) -> Transform3D {
    pose(yaw: Double(step) * 0.4 * .pi / 180, at: Vec3(Double(step) * 0.01, 0, Double(step) * -0.004)) * lock
}

@Suite struct ParkedPoseHoldRearmTests {
    let lockPose = pose(yaw: 0.1, at: Vec3(0.2, 0.1, 0.3))

    @Test func rearmingRestoresTheLockTimePose() {
        var hold = ParkedPoseHold()
        #expect(hold.setArmed(true) == .started)
        hold.update(cameraPose: lockPose, still: true)
        // +2 degrees of yaw and 5 cm while the device sits still.
        let drift = pose(yaw: 2 * .pi / 180, at: Vec3(0.05, 0, 0))
        let raw = drift * lockPose
        hold.update(cameraPose: raw, still: true)
        #expect(poseGap(hold.corrected(raw), lockPose) < 1e-6)

        #expect(hold.setArmed(false) == .unchanged)
        hold.update(cameraPose: raw, still: true)
        #expect(poseGap(hold.corrected(raw), lockPose) < 1e-6)
        #expect(hold.setArmed(true) == .resumed)
        hold.update(cameraPose: raw, still: true)
        // P0 again, not the drifted pose.
        #expect(poseGap(hold.corrected(raw), lockPose) < 1e-6)
        #expect(poseGap(hold.corrected(raw), raw) > 0.01)
    }

    @Test func switchesNeverMoveTheTableInTheImage() {
        for seed in 1...20 {
            var hold = ParkedPoseHold()
            var generator = SeededGenerator(seed: UInt64(seed))
            hold.setArmed(true)
            hold.update(cameraPose: lockPose, still: true)
            var step = 0
            for _ in 0..<120 {
                step += 1
                let raw = drifted(lockPose, step: step)
                hold.update(cameraPose: raw, still: true)
                let before = cornersInCamera(hold.corrected(raw))
                let open = generator.next() % 2 == 0
                hold.setArmed(open)
                // The same frame again, after the switch.
                hold.update(cameraPose: raw, still: true)
                let after = cornersInCamera(hold.corrected(raw))
                #expect(shift(before, after) < 0.001)
            }
            // After all of that the camera is still where the lock put it.
            #expect(poseGap(hold.corrected(drifted(lockPose, step: step)), lockPose) < 1e-6)
        }
    }

    @Test func motionWhileUnarmedRefusesTheRestore() {
        var hold = ParkedPoseHold()
        hold.setArmed(true)
        hold.update(cameraPose: lockPose, still: true)
        hold.setArmed(false)
        hold.noteMotion()
        #expect(hold.motionWhileUnarmed)
        #expect(hold.setArmed(true) == .lockMustBeDropped)
        #expect(!hold.isArmed)
        #expect(hold.lockMustBeDropped)
        // Still refused on the next try; only releasing the lock ends it.
        #expect(hold.setArmed(true) == .lockMustBeDropped)
        hold.releaseLock()
        #expect(!hold.lockMustBeDropped && !hold.motionWhileUnarmed)
        #expect(hold.setArmed(true) == .started)
    }

    @Test func motionIsOnlyEvidenceWithAClosedGateOnALiveSession() {
        var hold = ParkedPoseHold()
        hold.noteMotion() // no session
        #expect(!hold.motionWhileUnarmed)
        hold.setArmed(true)
        hold.noteMotion() // gate open: the hold tracks real motion itself
        #expect(!hold.motionWhileUnarmed)
        #expect(hold.setArmed(false) == .unchanged)
        #expect(hold.setArmed(true) == .resumed)
    }

    @Test func aNewLockStartsANewReference() {
        var hold = ParkedPoseHold()
        hold.setArmed(true)
        hold.update(cameraPose: lockPose, still: true)
        let raw = drifted(lockPose, step: 10)
        hold.update(cameraPose: raw, still: true)
        #expect(hold.correctionMagnitude.translation > 0.05)
        hold.releaseLock() // the old lock ended
        #expect(hold.setArmed(true) == .started)
        hold.update(cameraPose: raw, still: true)
        // The new lock is measured here: no old correction, new reference.
        #expect(hold.correction == .identity)
        #expect(hold.reference == raw)
        let later = drifted(lockPose, step: 12)
        hold.update(cameraPose: later, still: true)
        #expect(poseGap(hold.corrected(later), raw) < 1e-6)
    }

    @Test func stillnessLimitsAreExposed() {
        let detector = StillnessDetector()
        #expect(!detector.isOverLimit(rotationRate: 0.004, userAcceleration: 0.002))
        #expect(detector.isOverLimit(rotationRate: 0.1, userAcceleration: 0))
        #expect(detector.isOverLimit(rotationRate: 0, userAcceleration: 0.1))
    }
}

/// A tiny deterministic generator so the sequences are repeatable.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 11
    }
}
