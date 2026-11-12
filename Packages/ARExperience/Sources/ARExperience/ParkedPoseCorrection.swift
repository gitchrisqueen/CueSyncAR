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
    /// A hold session exists, so the lock-time reference is kept and the
    /// correction stays in force even with the gate (`armed`) closed.
    public var referenceHeld: Bool = false
    /// Seconds since that session began (the lock, or the first arming);
    /// nil without one.
    public var referenceAge: TimeInterval?
    /// The IMU saw motion while the gate was closed on a live session.
    public var motionWhileUnarmed: Bool = false
    /// Re-arming was refused because of that motion: the table lock must be
    /// dropped and calibration asked for again.
    public var lockMustBeDropped: Bool = false
}

/// What `ParkedHoldBox.sync` asks of the app.
public enum ParkedHoldSync: Sendable, Equatable {
    case ok
    /// The device moved while the hold was off: drop the lock, tell the
    /// player, log it.
    case dropLock
}

/// Thread-safe holder: written from the ARSession delegate and the motion
/// queue, read on the main actor.
public final class ParkedHoldBox: @unchecked Sendable {
    private let lock = NSLock()
    private var hold = ParkedPoseHold()
    private var stillness = StillnessDetector()
    private var enabled = true
    private var wantArmed = false
    private var lockedNow = false
    private var sessionStart: TimeInterval?
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
        if stillness.isOverLimit(rotationRate: rotationRate, userAcceleration: userAcceleration) {
            hold.noteMotion()
        }
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
        // Not gated on `enabled`: a session keeps tracking with the gate
        // closed so no switch moves the locked table (ParkedPoseHold).
        let still = imuFresh(at: time) && stillness.isStill
        hold.update(cameraPose: cameraPose, still: still)
        return hold.corrected(cameraPose)
    }

    func noteWorldMapping(_ status: String) {
        lock.lock(); defer { lock.unlock() }
        worldMapping = status
    }

    /// ARKit's `worldMappingStatus` on the newest frame.
    public var worldMappingStatus: String? { lock.lock(); defer { lock.unlock() }; return worldMapping }

    /// Open or close the gate (see `ParkedPoseHold.setArmed`). The gate
    /// stays closed while the feature is disabled.
    @discardableResult
    public func setArmed(_ armed: Bool) -> ParkedPoseHold.ArmOutcome {
        lock.lock(); defer { lock.unlock() }
        wantArmed = armed
        return applyGate()
    }

    /// The one call the app makes each frame loop: the table lock state and
    /// the "device is parked" setting. A lock edge (dropped, or a new lock)
    /// forgets the session, so every lock starts a new reference.
    public func sync(locked: Bool, parked: Bool) -> ParkedHoldSync {
        lock.lock(); defer { lock.unlock() }
        if locked != lockedNow {
            lockedNow = locked
            hold.releaseLock()
            sessionStart = nil
        }
        wantArmed = locked && parked
        _ = applyGate()
        return hold.lockMustBeDropped ? .dropLock : .ok
    }

    /// Caller holds `lock`.
    private func applyGate() -> ParkedPoseHold.ArmOutcome {
        let outcome = hold.setArmed(wantArmed && enabled)
        if hold.isActive, sessionStart == nil { sessionStart = ProcessInfo.processInfo.systemUptime }
        return outcome
    }

    /// A/B switch (mirror `parkedHold`). Switching never moves a locked
    /// table: with a session running the correction stays in force, and the
    /// switch decides only whether a session may start.
    public func setEnabled(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        enabled = on
        _ = applyGate()
    }

    public var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled }
    /// Whether the correction is in force: a session exists (the locked
    /// table lives in the corrected world), even with the gate closed.
    /// Consumers pick their world frame from this.
    public var isArmed: Bool { lock.lock(); defer { lock.unlock() }; return hold.isActive }
    /// Whether the gate itself is open.
    public var isGateOpen: Bool { lock.lock(); defer { lock.unlock() }; return hold.isArmed }

    /// Snapshot of the hold (value type, safe to keep).
    public var current: ParkedPoseHold { lock.lock(); defer { lock.unlock() }; return hold }

    public func reading() -> ParkedHoldReading {
        lock.lock(); defer { lock.unlock() }
        let fresh = lastIMUTime.map { abs(ProcessInfo.processInfo.systemUptime - $0) < 0.5 } ?? false
        let now = ProcessInfo.processInfo.systemUptime
        return ParkedHoldReading(enabled: enabled, armed: hold.isArmed, holding: hold.isHolding,
                                 still: fresh && stillness.isStill, imuLive: fresh,
                                 rotationRate: lastRotation, userAcceleration: lastAcceleration,
                                 drift: hold.drift, correction: hold.correctionMagnitude,
                                 rawPose: hold.lastPose, referenceHeld: hold.isActive,
                                 referenceAge: hold.isActive ? sessionStart.map { now - $0 } : nil,
                                 motionWhileUnarmed: hold.motionWhileUnarmed,
                                 lockMustBeDropped: hold.lockMustBeDropped)
    }
}
