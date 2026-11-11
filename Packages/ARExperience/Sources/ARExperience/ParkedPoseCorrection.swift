//
//  ParkedPoseCorrection.swift
//  ARExperience
//
//  The device side of TableSpace.ParkedPoseHold: IMU stillness in, a
//  corrected world out, applied at the one ARKit boundary
//  (ARSessionCoordinator) so every consumer downstream (perception
//  pipeline, aim, taps, overlay, mirror) works in the same corrected world
//  without knowing about it.
//
//  Why: on a parked iPad ARKit's camera-pose estimate wandered 30 cm in ten
//  minutes while nothing moved (docs/plans/2026-11-11-calibration-drift-plan.md).
//  The IMU says the device is still; the hold keeps the camera where it
//  was and the drift goes into a correction instead of into the balls.
//

import CueSyncCore
import Foundation
import TableSpace

#if canImport(CoreMotion)
import CoreMotion
#endif

/// What the hold is doing right now, for the mirror and the log.
public struct ParkedHoldReading: Sendable, Equatable {
    public var enabled: Bool
    public var armed: Bool
    public var holding: Bool
    public var still: Bool
    /// Whether IMU samples are arriving at all (none in the simulator).
    public var imuLive: Bool
    public var rotationRate: Double?
    public var userAcceleration: Double?
    /// ARKit's camera drift since the current hold began.
    public var drift: PoseDelta?
    /// The correction in force.
    public var correction: PoseDelta
    /// ARKit's raw camera pose (camera-to-world), newest frame.
    public var rawPose: Transform3D?
}

/// Thread-safe holder: written from the ARSession delegate and the motion
/// queue, read on the main actor.
public final class ParkedHoldBox: @unchecked Sendable {
    private let lock = NSLock()
    private var hold = ParkedPoseHold()
    private var stillness = StillnessDetector()
    private var enabled = true
    private var lastRotation: Double?
    private var lastAcceleration: Double?
    private var lastIMUTime: TimeInterval?
    private var worldMapping: String?
    #if canImport(CoreMotion) && os(iOS)
    private let motion = CMMotionManager()
    private let motionQueue = OperationQueue()
    #endif

    public init() {}

    /// Start IMU sampling (30 Hz). Idempotent; a no-op without a device
    /// motion sensor.
    public func startMotion() {
        #if canImport(CoreMotion) && os(iOS)
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motionQueue.maxConcurrentOperationCount = 1
        motion.startDeviceMotionUpdates(to: motionQueue) { [weak self] sample, _ in
            guard let self, let sample else { return }
            let r = sample.rotationRate
            let a = sample.userAcceleration
            self.noteIMU(time: sample.timestamp,
                         rotationRate: (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot(),
                         userAcceleration: (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot())
        }
        #endif
    }

    func noteIMU(time: TimeInterval, rotationRate: Double, userAcceleration: Double) {
        lock.lock(); defer { lock.unlock() }
        stillness.add(time: time, rotationRate: rotationRate, userAcceleration: userAcceleration)
        lastRotation = rotationRate
        lastAcceleration = userAcceleration
        lastIMUTime = time
    }

    /// Whether IMU samples are fresh relative to an ARKit timestamp (both
    /// are system uptime).
    private func imuFresh(at time: TimeInterval) -> Bool {
        guard let lastIMUTime else { return false }
        return abs(time - lastIMUTime) < 0.5
    }

    /// Feed ARKit's camera pose for a frame; returns the corrected pose.
    public func update(cameraPose: Transform3D, at time: TimeInterval) -> Transform3D {
        lock.lock(); defer { lock.unlock() }
        let still = enabled && imuFresh(at: time) && stillness.isStill
        hold.update(cameraPose: cameraPose, still: still)
        return hold.corrected(cameraPose)
    }

    func noteWorldMapping(_ status: String) {
        lock.lock(); defer { lock.unlock() }
        worldMapping = status
    }

    /// ARKit's `worldMappingStatus` on the newest frame.
    public var worldMappingStatus: String? { lock.lock(); defer { lock.unlock() }; return worldMapping }

    public func setArmed(_ armed: Bool) {
        lock.lock(); defer { lock.unlock() }
        hold.setArmed(armed && enabled)
    }

    /// A/B switch (mirror `parkedHold`). Off drops any correction.
    public func setEnabled(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        enabled = on
        if !on { hold.setArmed(false) }
    }

    public var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled }
    public var isArmed: Bool { lock.lock(); defer { lock.unlock() }; return hold.isArmed }

    /// Snapshot of the hold (value type, safe to keep).
    public var current: ParkedPoseHold { lock.lock(); defer { lock.unlock() }; return hold }

    public func reading() -> ParkedHoldReading {
        lock.lock(); defer { lock.unlock() }
        let fresh = lastIMUTime.map { abs(ProcessInfo.processInfo.systemUptime - $0) < 0.5 } ?? false
        return ParkedHoldReading(enabled: enabled, armed: hold.isArmed, holding: hold.isHolding,
                                 still: fresh && stillness.isStill, imuLive: fresh,
                                 rotationRate: lastRotation, userAcceleration: lastAcceleration,
                                 drift: hold.drift, correction: hold.correctionMagnitude,
                                 rawPose: hold.lastPose)
    }
}
