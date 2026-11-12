//
//  ParkedHoldBoxTests.swift
//  ARExperience
//
//  The device wrapper around TableSpace.ParkedPoseHold: it may only hold
//  while IMU samples are fresh and still, and never when switched off.
//

import CueSyncCore
import Foundation
import TableSpace
import Testing
@testable import ARExperience

private func shifted(_ x: Double) -> Transform3D {
    var t = Transform3D.identity
    t.columns[3] = SIMD4(x, 0, 0, 1)
    return t
}

@Suite struct ParkedHoldBoxTests {
    /// Feed 2 s of tripod-quiet IMU ending at `end`.
    private func settle(_ box: ParkedHoldBox, until end: TimeInterval) {
        for i in 0...60 {
            box.noteIMU(time: end - 2 + Double(i) / 30, rotationRate: 0.002, userAcceleration: 0.001)
        }
    }

    @Test func holdsDriftWhenArmedAndStill() {
        let box = ParkedHoldBox()
        box.setArmed(true)
        settle(box, until: 100)
        _ = box.update(cameraPose: .identity, at: 100)
        let corrected = box.update(cameraPose: shifted(0.3), at: 100.1)
        #expect(corrected.translation.length < 1e-9)
        #expect(box.current.isHolding)
    }

    @Test func staleIMUDoesNotHold() {
        let box = ParkedHoldBox()
        box.setArmed(true)
        settle(box, until: 10)
        // ARKit frames 50 s after the last IMU sample: no evidence of stillness.
        _ = box.update(cameraPose: .identity, at: 60)
        let corrected = box.update(cameraPose: shifted(0.3), at: 60.1)
        #expect(abs(corrected.translation.x - 0.3) < 1e-9)
        #expect(!box.current.isHolding)
    }

    /// A box that was disabled before any lock never starts a hold. (The
    /// old version of this test also asserted that disabling a RUNNING hold
    /// dropped its correction; that was the table-moves bug, and
    /// ParkedHoldRearmBoxTests now asserts the opposite.)
    @Test func disabledNeverStartsAHold() {
        let box = ParkedHoldBox()
        box.setEnabled(false)
        box.setArmed(true)
        #expect(!box.isArmed)
        settle(box, until: 100)
        _ = box.update(cameraPose: .identity, at: 100)
        let corrected = box.update(cameraPose: shifted(0.4), at: 100.2)
        #expect(abs(corrected.translation.x - 0.4) < 1e-9)
        box.noteWorldMapping("mapped")
        #expect(box.worldMappingStatus == "mapped")
        #expect(!box.reading().enabled)
    }
}
