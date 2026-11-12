//
//  ParkedHoldRearmBoxTests.swift
//  ARExperience
//
//  No switch of the parked hold (enable, disable, arm, disarm, the Settings
//  toggle) may move a locked table in the camera image; motion with the
//  hold off drops the lock; every lock starts a new reference.
//

import CueSyncCore
import Foundation
import TableSpace
import Testing
@testable import ARExperience

private func pose(yaw: Double, at t: Vec3) -> Transform3D {
    let cy = cos(yaw), sy = sin(yaw)
    return Transform3D(columns: [
        SIMD4(cy, 0, -sy, 0), SIMD4(0, 1, 0, 0),
        SIMD4(sy, 0, cy, 0), SIMD4(t.x, t.y, t.z, 1)
    ])
}

private func gap(_ a: Transform3D, _ b: Transform3D) -> Double {
    var gap = a.translation.distance(to: b.translation)
    for axis in 0..<3 { gap = max(gap, a.axis(axis).distance(to: b.axis(axis))) }
    return gap
}

/// The table corners (corrected world) in the camera's frame, metres.
private func corners(through camera: Transform3D) -> [Vec3] {
    // Rigid inverse by hand: local = R^T (world - t).
    return [Vec3(-0.6, -0.8, -1.4), Vec3(0.6, -0.8, -1.4),
            Vec3(0.6, -0.8, -2.6), Vec3(-0.6, -0.8, -2.6)].map { world in
        let d = world - camera.translation
        return Vec3(d.dot(camera.axis(0)), d.dot(camera.axis(1)), d.dot(camera.axis(2)))
    }
}

@Suite struct ParkedHoldRearmBoxTests {
    let lockPose = pose(yaw: 0.1, at: Vec3(0.2, 0.1, 0.3))
    /// ARKit's drifting estimate of the camera that never moves.
    func raw(_ step: Int) -> Transform3D {
        pose(yaw: Double(step) * 0.4 * .pi / 180,
             at: Vec3(Double(step) * 0.01, 0, Double(step) * -0.004)) * lockPose
    }

    /// A box that is armed, settled and holding the lock-time pose at t = 2.
    private func lockedBox() -> (ParkedHoldBox, clock: () -> TimeInterval, tick: () -> Void) {
        let box = ParkedHoldBox()
        var t = 0.0
        _ = box.sync(locked: true, parked: true)
        for _ in 0...60 {
            box.noteIMU(time: t, rotationRate: 0.002, userAcceleration: 0.001)
            t += 1.0 / 30
        }
        _ = box.update(cameraPose: lockPose, at: t)
        return (box, { t }, { t += 1.0 / 30
            box.noteIMU(time: t, rotationRate: 0.002, userAcceleration: 0.001) })
    }

    @Test func turningTheHoldOffAndOnKeepsTheLockTimePose() {
        let (box, now, tick) = lockedBox()
        tick()
        _ = box.update(cameraPose: raw(5), at: now())
        box.setEnabled(false)
        #expect(box.isArmed) // the correction is still in force
        #expect(!box.isGateOpen)
        tick()
        let off = box.update(cameraPose: raw(9), at: now())
        #expect(gap(off, lockPose) < 1e-6)
        box.setEnabled(true)
        tick()
        let on = box.update(cameraPose: raw(9), at: now())
        #expect(gap(on, lockPose) < 1e-6)
        #expect(box.isGateOpen)
        #expect(box.reading().referenceHeld)
    }

    @Test func noSequenceOfSwitchesMovesTheTable() {
        var state: UInt64 = 7
        func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 33 }
        let (box, now, tick) = lockedBox()
        for step in 1...200 {
            tick()
            let frame = raw(step)
            let before = corners(through: box.update(cameraPose: frame, at: now()))
            switch next() % 4 {
            case 0: box.setEnabled(true)
            case 1: box.setEnabled(false)
            case 2: box.setArmed(true)
            default: box.setArmed(false)
            }
            // The Settings toggle path, too.
            if next() % 5 == 0 { _ = box.sync(locked: true, parked: next() % 2 == 0) }
            let after = corners(through: box.update(cameraPose: frame, at: now()))
            let shift = zip(before, after).map { $0.distance(to: $1) }.max() ?? 0
            #expect(shift < 0.001)
        }
        #expect(gap(box.update(cameraPose: raw(200), at: now()), lockPose) < 1e-6)
    }

    @Test func motionWhileOffDropsTheLockAtTheNextArm() {
        let (box, now, tick) = lockedBox()
        tick()
        box.setEnabled(false)
        // The iPad is picked up and put down with the hold off.
        box.noteIMU(time: now() + 0.1, rotationRate: 0.6, userAcceleration: 0.2)
        let reading = box.reading()
        #expect(reading.motionWhileUnarmed)
        #expect(!reading.lockMustBeDropped)
        box.setEnabled(true)
        #expect(box.reading().lockMustBeDropped)
        #expect(!box.isGateOpen)
        // The app asks for it on its next loop, every time until it did.
        #expect(box.sync(locked: true, parked: true) == .dropLock)
        #expect(box.sync(locked: true, parked: true) == .dropLock)
        // Calibration restarted: the lock is gone, the session with it.
        #expect(box.sync(locked: false, parked: true) == .ok)
        #expect(!box.isArmed)
        #expect(!box.reading().motionWhileUnarmed)
    }

    @Test func motionWithTheHoldOnIsNotAnEvent() {
        let (box, now, tick) = lockedBox()
        tick()
        box.noteIMU(time: now() + 0.1, rotationRate: 0.6, userAcceleration: 0.2)
        #expect(!box.reading().motionWhileUnarmed)
        #expect(box.sync(locked: true, parked: true) == .ok)
    }

    @Test func aStaleIMUIsNotMotion() {
        let (box, now, tick) = lockedBox()
        tick()
        box.setEnabled(false)
        // Frames far from the last IMU sample: no evidence either way.
        _ = box.update(cameraPose: raw(3), at: now() + 60)
        box.setEnabled(true)
        #expect(!box.reading().lockMustBeDropped)
    }

    @Test func aNewLockStartsANewReference() {
        let (box, now, tick) = lockedBox()
        tick()
        _ = box.update(cameraPose: raw(12), at: now())
        #expect(box.reading().correction.translation > 0.05)
        // Calibration restarts (unlocked), then locks again at the same pose.
        #expect(box.sync(locked: false, parked: true) == .ok)
        #expect(!box.isArmed)
        #expect(box.current.correction == .identity)
        #expect(box.reading().referenceAge == nil)
        #expect(box.sync(locked: true, parked: true) == .ok)
        tick()
        let corrected = box.update(cameraPose: raw(12), at: now())
        #expect(gap(corrected, raw(12)) < 1e-9)
        #expect(box.reading().referenceHeld)
        #expect(box.reading().referenceAge.map { $0 >= 0 } == true)
    }

    /// `Scripts/calibrate-pockets.py`: parkedHold 0, parkedHold 1, begin
    /// calibration (unlock), then the picks (lock).
    @Test func theCalibratePocketsSequenceStillWorks() {
        let (box, now, tick) = lockedBox()
        tick()
        _ = box.update(cameraPose: raw(8), at: now())
        box.setEnabled(false)
        box.setEnabled(true)
        _ = box.sync(locked: false, parked: true) // beginCalibration
        tick()
        // Picks are unprojected through ARKit's own pose, uncorrected.
        #expect(gap(box.update(cameraPose: raw(8), at: now()), raw(8)) < 1e-9)
        _ = box.sync(locked: true, parked: true) // the new lock
        tick()
        #expect(gap(box.update(cameraPose: raw(8), at: now()), raw(8)) < 1e-9)
        tick()
        #expect(gap(box.update(cameraPose: raw(10), at: now()), raw(8)) < 1e-9)
    }
}
