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
        /// Bounds on what counts as a cue being aimed (see `StickAim.Gate`).
        public var gate: StickAim.Gate
        /// A stick reading that DISAGREES with the current one (by more
        /// than `gate.continuityDegrees`) must repeat this many frames
        /// running before it takes over.
        ///
        /// One frame is not evidence that the cue moved. The quad's two
        /// diagonals are near mirrors on a squarish box, so a single pixel
        /// of jitter can hand the aim to the other diagonal — and the
        /// smoother then spends the next second sweeping toward it, which
        /// on the recording read as a 48-degree slide over five frames.
        /// Requiring persistence makes a genuine re-aim cost ~0.4 s and a
        /// one-frame flip cost nothing.
        public var reacquireFrames: Int

        public init(stickHoldSeconds: TimeInterval = 2.5,
                    gate: StickAim.Gate = .default,
                    reacquireFrames: Int = 3) {
            self.stickHoldSeconds = stickHoldSeconds
            self.gate = gate
            self.reacquireFrames = reacquireFrames
        }

        public static let `default` = Config()
    }

    public let config: Config
    private let engine: AimEngine
    private var lastStickAim: AimRay?
    private var lastStickSeenAt: TimeInterval?
    /// A disagreeing stick reading waiting to prove itself, and how many
    /// consecutive frames it has now been seen for.
    private var pendingStickAim: AimRay?
    private var pendingStickFrames = 0
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
        // `previous:` is what makes the stick reading stable frame to
        // frame: without it the diagonal choice and the tip/butt choice are
        // both bistable, and a pixel of box jitter reverses the aim.
        if let stickQuad,
           let stickAim = StickAim.estimate(stickQuad: stickQuad, cueBall: cueBall,
                                            gate: config.gate, previous: lastStickAim) {
            if let held = lastStickAim, !agrees(stickAim, held) {
                // A different reading. Make it prove it is the cue moving
                // and not the box jittering onto the other diagonal.
                if let pending = pendingStickAim, agrees(stickAim, pending) {
                    pendingStickFrames += 1
                } else {
                    pendingStickAim = stickAim
                    pendingStickFrames = 1
                }
                if pendingStickFrames < config.reacquireFrames {
                    // Keep serving the established aim, and DO refresh the
                    // hold clock: a stick is plainly visible this frame, we
                    // are only declining to adopt its new direction yet.
                    // Letting the hold lapse here made the source fall
                    // through to devicePose mid-aim and pushed transitions
                    // UP (4.6 -> 6.4 per minute on the recording) — the
                    // opposite of what this rule is for.
                    lastStickSeenAt = time
                    source = .stick
                    return (held, .stick)
                }
            }
            pendingStickAim = nil
            pendingStickFrames = 0
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

    /// Whether two aim rays point the same way, within the gate's
    /// continuity window.
    private func agrees(_ lhs: AimRay, _ rhs: AimRay) -> Bool {
        lhs.direction.dot(rhs.direction) >= cos(config.gate.continuityDegrees * .pi / 180)
    }

    /// Forget the held stick aim (tracking stopped / reset).
    public mutating func reset() {
        lastStickAim = nil
        lastStickSeenAt = nil
        pendingStickAim = nil
        pendingStickFrames = 0
        source = .devicePose
    }
}
