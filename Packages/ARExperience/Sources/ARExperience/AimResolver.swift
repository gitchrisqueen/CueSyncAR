//
//  AimResolver.swift
//  ARExperience
//
//  Chooses the aim source per update: the detected cue stick when one is
//  addressing the cue ball, else the device-pose sighting model (AimEngine).
//  Hysteresis: when the stick momentarily drops out of detection its last
//  aim is HELD for a window instead of snapping to device pose and back —
//  every snap redraws every guide line (the on-device "jumping" bug).
//
//  The hold is measured in SECONDS on a caller-supplied clock, not in
//  update counts: the app's loop cadence varies with load, and a replay
//  drives updates from recorded frame timestamps, so a frame-counted grace
//  would make the same session resolve differently live vs replayed.
//  Pure value type, fully tested; SessionModel and ReplayRunner share it.
//

import CueSyncCore
import Foundation
import PerceptionKit
import TableSpace

public struct AimResolver: Sendable {
    /// Where the current aim comes from.
    public enum Source: String, Sendable, Codable, Equatable {
        case stick
        case devicePose
    }

    public struct Config: Sendable, Equatable {
        /// Seconds a stick-derived aim stays live after the stick was last
        /// FRESHLY seen. The on-device detector emits the stick in bursts
        /// (measured 2026-07-23 at the table: fresh stick projections on
        /// only ~7 % of frames, gaps up to ~6 s), so 2.5 s bridges the
        /// typical gap without lingering long after the cue is lifted.
        public var stickHoldSeconds: TimeInterval

        public init(stickHoldSeconds: TimeInterval = 2.5) {
            self.stickHoldSeconds = stickHoldSeconds
        }

        public static let `default` = Config()
    }

    public let config: Config
    private let engine: AimEngine
    private var lastStickAim: AimRay?
    private var lastStickSeenAt: TimeInterval?
    /// Source of the most recent resolution (device pose until a stick is seen).
    public private(set) var source: Source = .devicePose

    public init(config: Config = .default, engine: AimEngine = AimEngine()) {
        self.config = config
        self.engine = engine
    }

    /// Resolve the raw (unsmoothed) aim for one update.
    /// - Parameters:
    ///   - stickQuad: the pipeline's stick footprint for this update, if any.
    ///   - cueBall: tracked cue-ball position (table space).
    ///   - cameraTransform: camera-to-world pose for the device-pose fallback.
    ///   - calibration: the locked table calibration.
    ///   - time: seconds on a monotonic clock — the frame timestamp under
    ///     replay, the injected session clock live.
    /// - Returns: the aim ray (nil when neither source yields one) and the
    ///   source that produced it; `source` is also retained on the resolver.
    public mutating func resolve(stickQuad: [Vec2]?,
                                 cueBall: Vec2,
                                 cameraTransform: Transform3D,
                                 calibration: TableCalibration,
                                 at time: TimeInterval) -> (aim: AimRay?, source: Source) {
        if let stickQuad,
           let stickAim = StickAim.estimate(stickQuad: stickQuad, cueBall: cueBall) {
            lastStickAim = stickAim
            lastStickSeenAt = time
            source = .stick
            return (stickAim, .stick)
        }
        if let held = lastStickAim, let seenAt = lastStickSeenAt,
           (0...config.stickHoldSeconds).contains(time - seenAt) {
            source = .stick
            return (held, .stick)
        }
        source = .devicePose
        let aim = engine.aimRay(cameraTransform: cameraTransform,
                                cueBall: cueBall,
                                calibration: calibration)
        return (aim, .devicePose)
    }

    /// Forget the held stick aim (tracking stopped / reset).
    public mutating func reset() {
        lastStickAim = nil
        lastStickSeenAt = nil
        source = .devicePose
    }
}
