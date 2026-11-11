//
//  ParkedPoseHold.swift
//  TableSpace
//
//  Camera-pose drift on a parked device, and the correction that cancels it.
//
//  Measured on an iPad on a tripod (docs/validation/2026-11-10-ipad-remote-run.md,
//  docs/plans/2026-11-11-calibration-drift-plan.md): after the table locked,
//  stationary balls crept 30 cm along the table in ten minutes while the
//  world-space calibration corners did not move and the ball-to-ball
//  distances stayed constant. Nothing physical moved; ARKit's estimate of
//  where the camera is did. Visual-inertial odometry on a device that never
//  moves gets no parallax, so nothing in the image pins the estimate down,
//  and it wanders.
//
//  The calibration was measured as a relation between PIXELS and the
//  table: the user (or the mirror) pointed at pockets in the image. When the
//  camera is physically still, that pixel relation is the truth and any
//  later change in the estimated camera pose is error. So while the device
//  is still, hold the camera where it was: the corrected pose stays at the
//  value it had when the stillness began, and the difference between it and
//  ARKit's pose is the correction `D` that maps the corrected (lock-time)
//  world into ARKit's current world:
//
//      D = C_arkit(now) * C_arkit(hold start)^-1 * D_before
//      C_corrected = D^-1 * C_arkit
//
//  Every consumer then works in the corrected world: the perception
//  pipeline sees a camera that does not move, so a stationary ball keeps
//  its table coordinates; overlay content is rendered at `D * X`, which
//  ARKit's drifted camera projects onto the same pixel the lock-time
//  camera did.
//
//  When the device moves, the hold releases and `D` freezes at its last
//  value. ARKit tracks real motion well (that is when it has parallax), so
//  `D^-1 * C_arkit` stays right; the next stillness starts a new hold on
//  top of the frozen correction.
//
//  Stillness comes from the IMU (`StillnessDetector`), never from the
//  ARKit pose: the pose is the thing being corrected, and a slow drift is
//  exactly what a pose-based detector would call "still but moving".
//

import CueSyncCore
import Foundation

/// Decides from IMU samples whether the device is physically still.
///
/// A tripod-mounted device reads a rotation rate of a few thousandths of a
/// radian per second and a user acceleration of a few thousandths of a g.
/// A hand-held one reads ten times that even when the person is trying to
/// hold it steady, and picking a device up reads a hundred times it. The
/// limits sit between the two, and stillness has to last `settleSeconds`
/// before it counts, so a moment of steadiness in the hand does not start
/// a hold.
public struct StillnessDetector: Sendable, Equatable {
    public struct Config: Sendable, Equatable {
        /// Rotation-rate magnitude above which the device is moving, rad/s.
        public var rotationLimit: Double
        /// User-acceleration magnitude above which it is moving, in g.
        public var accelerationLimit: Double
        /// How long every sample must stay under both limits, seconds.
        public var settleSeconds: Double

        public init(rotationLimit: Double = 0.03, accelerationLimit: Double = 0.03,
                    settleSeconds: Double = 1.5) {
            self.rotationLimit = rotationLimit
            self.accelerationLimit = accelerationLimit
            self.settleSeconds = settleSeconds
        }

        public static let `default` = Config()
    }

    public var config: Config
    /// Time of the last sample over a limit (or the first sample seen).
    public private(set) var lastMotion: TimeInterval?
    /// Time of the newest sample.
    public private(set) var lastSample: TimeInterval?

    public init(config: Config = .default) {
        self.config = config
    }

    /// Feed one IMU sample. Returns whether the device is still now.
    @discardableResult
    public mutating func add(time: TimeInterval, rotationRate: Double,
                             userAcceleration: Double) -> Bool {
        if lastMotion == nil { lastMotion = time }
        if rotationRate > config.rotationLimit || userAcceleration > config.accelerationLimit {
            lastMotion = time
        }
        lastSample = time
        return isStill
    }

    /// Still: samples are arriving, and none has crossed a limit for
    /// `settleSeconds`.
    public var isStill: Bool {
        guard let lastMotion, let lastSample else { return false }
        return lastSample - lastMotion >= config.settleSeconds
    }

    /// Forget everything (the IMU stopped, or the session restarted).
    public mutating func reset() {
        lastMotion = nil
        lastSample = nil
    }
}

/// The parked-device pose correction. See the file header for the model.
public struct ParkedPoseHold: Sendable, Equatable {
    /// Maps the corrected world into ARKit's current world. Identity until
    /// a hold has run.
    public private(set) var correction: Transform3D = .identity
    /// The correction frozen when the current hold began (or the last one
    /// ended). `correction` is built on top of it while holding.
    public private(set) var frozenCorrection: Transform3D = .identity
    /// ARKit's camera pose when the current hold began; nil when not holding.
    public private(set) var reference: Transform3D?
    /// ARKit's latest camera pose.
    public private(set) var lastPose: Transform3D?
    /// Whether a hold may run at all (a table is locked and the feature is on).
    public private(set) var isArmed = false

    public init() {}

    /// True while the camera is being held at `reference`.
    public var isHolding: Bool { reference != nil }

    /// Arm or disarm. Disarming drops the correction: with nothing locked
    /// there is no calibration for it to protect, and the next lock is
    /// measured in ARKit's world as it is then.
    public mutating func setArmed(_ armed: Bool) {
        guard armed != isArmed else { return }
        isArmed = armed
        if !armed {
            correction = .identity
            frozenCorrection = .identity
            reference = nil
        }
    }

    /// Feed ARKit's camera pose for a frame, with whether the IMU says the
    /// device is still.
    public mutating func update(cameraPose pose: Transform3D, still: Bool) {
        lastPose = pose
        guard isArmed else { return }
        if still {
            if let reference {
                correction = pose * AnchoredCalibration.invertRigid(reference) * frozenCorrection
            } else {
                // Start a hold on top of whatever is frozen. The camera is
                // corrected to where it is now, which the frozen correction
                // already makes consistent with the calibration.
                reference = pose
                correction = frozenCorrection
            }
        } else if reference != nil {
            // Moving: freeze the correction where the hold left it. ARKit
            // tracks real motion; what it got wrong while parked stays fixed.
            frozenCorrection = correction
            reference = nil
        }
    }

    /// ARKit's pose re-expressed in the corrected world.
    public func corrected(_ pose: Transform3D) -> Transform3D {
        AnchoredCalibration.invertRigid(correction) * pose
    }

    /// A corrected-world point in ARKit's world (for rendering, projection).
    public func toARKit(_ point: Vec3) -> Vec3 { correction.transformPoint(point) }

    /// An ARKit-world point in the corrected world (for taps, raycasts).
    public func fromARKit(_ point: Vec3) -> Vec3 {
        AnchoredCalibration.invertRigid(correction).transformPoint(point)
    }

    /// An ARKit-world direction in the corrected world.
    public func fromARKit(direction: Vec3) -> Vec3 {
        AnchoredCalibration.invertRigid(correction).transformDirection(direction)
    }

    /// How far ARKit's camera estimate has wandered since the current hold
    /// began: translation in metres and rotation in degrees. Nil when not
    /// holding. This is the drift DETECTOR: on a still device every
    /// millimetre here is error that the hold is cancelling.
    public var drift: PoseDelta? {
        guard let reference, let lastPose else { return nil }
        return PoseDelta(from: reference, to: lastPose)
    }

    /// The whole correction in force, as a pose delta.
    public var correctionMagnitude: PoseDelta {
        PoseDelta(from: .identity, to: correction)
    }
}

/// The difference between two rigid poses.
public struct PoseDelta: Sendable, Equatable {
    /// Distance between the two translations, metres.
    public var translation: Double
    /// Angle of the relative rotation, degrees.
    public var rotationDegrees: Double

    public init(translation: Double, rotationDegrees: Double) {
        self.translation = translation
        self.rotationDegrees = rotationDegrees
    }

    public init(from a: Transform3D, to b: Transform3D) {
        translation = a.translation.distance(to: b.translation)
        // trace(Ra^T Rb) = sum of column dot products.
        let trace = (0..<3).reduce(0.0) { $0 + a.axis($1).dot(b.axis($1)) }
        let cosine = min(1, max(-1, (trace - 1) / 2))
        rotationDegrees = acos(cosine) * 180 / .pi
    }
}
