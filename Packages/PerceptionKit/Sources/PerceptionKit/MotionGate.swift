//
//  MotionGate.swift
//  PerceptionKit
//
//  Motion-aware detection throttling. Re-detecting a static scene every
//  cycle wastes battery, hosted-API quota, and thermal headroom; the gate
//  lets detection run at full cadence while the camera (or scene) is
//  moving and drops to a slow heartbeat once it settles. Pure logic —
//  callers feed it camera poses and frame timestamps.
//

import CueSyncCore
import Foundation

/// Decides whether a detection pass is worth running, based on camera
/// motion since the *last accepted pass*. Comparing against the last pass
/// (not the previous frame) means slow continuous drift still accumulates
/// and eventually triggers a pass.
public struct MotionGate: Sendable, Equatable {
    public struct Config: Sendable, Equatable {
        /// Camera translation (meters) since the last pass that counts as motion.
        public var translationThreshold: Double
        /// Rotation of the camera's forward axis (radians) that counts as motion.
        public var rotationThreshold: Double
        /// Heartbeat cadence while static — a pass is still allowed this often,
        /// so scene-only changes (balls moving, lighting) are picked up.
        public var staticInterval: TimeInterval

        public init(translationThreshold: Double = 0.02,
                    rotationThreshold: Double = 2.0 * .pi / 180,
                    staticInterval: TimeInterval = 2.0) {
            self.translationThreshold = translationThreshold
            self.rotationThreshold = rotationThreshold
            self.staticInterval = staticInterval
        }

        public static let `default` = Config()
    }

    public let config: Config
    private var lastPassPose: Transform3D?
    private var lastPassAt: TimeInterval?

    public init(config: Config = .default) {
        self.config = config
    }

    /// `timestamp` is any monotonically increasing seconds value (e.g. the
    /// frame's capture timestamp). Returns true when a detection pass should
    /// run now, and records the pass internally when it does.
    public mutating func shouldRunDetection(pose: Transform3D,
                                            timestamp: TimeInterval) -> Bool {
        guard let lastPose = lastPassPose, let lastAt = lastPassAt else {
            recordPass(pose: pose, timestamp: timestamp)
            return true
        }
        let moved = Self.exceedsMotionThresholds(from: lastPose, to: pose,
                                                 config: config)
        let heartbeatDue = timestamp - lastAt >= config.staticInterval
        guard moved || heartbeatDue else { return false }
        recordPass(pose: pose, timestamp: timestamp)
        return true
    }

    private mutating func recordPass(pose: Transform3D, timestamp: TimeInterval) {
        lastPassPose = pose
        lastPassAt = timestamp
    }

    /// True when the pose delta counts as camera motion under `config`.
    static func exceedsMotionThresholds(from: Transform3D, to: Transform3D,
                                        config: Config) -> Bool {
        if from.translation.distance(to: to.translation) >= config.translationThreshold {
            return true
        }
        let forwardBefore = from.axis(2).normalized
        let forwardAfter = to.axis(2).normalized
        let dot = Swift.max(-1, Swift.min(1, forwardBefore.dot(forwardAfter)))
        return Foundation.acos(dot) >= config.rotationThreshold
    }
}
