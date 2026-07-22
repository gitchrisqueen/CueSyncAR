//
//  AimStabilizer.swift
//  PerceptionKit
//
//  Temporal stabilization for the aim ray. Raw per-frame aim estimates
//  (stick detection or device pose) carry sensor + detector noise; feeding
//  them straight into the solver re-draws the trajectory every tick and the
//  guide lines visibly "jump all over the place" (observed on device).
//
//  Two standard techniques, both pure and tested here:
//  - Exponential smoothing of the aim DIRECTION as a vector lerp (avoids
//    angle-wrap artifacts) and of the origin.
//  - A deadband: the stabilized aim only *emits* a change once the smoothed
//    value drifts past an angular/positional threshold — small noise keeps
//    the previous prediction perfectly still, intentional movement passes
//    through after ~2-3 frames of smoothing.
//

import CueSyncCore
import Foundation

public struct AimStabilizer: Sendable, Equatable {
    public struct Config: Sendable, Equatable {
        /// Smoothing factor for new samples (higher = more responsive).
        public var alpha: Double
        /// Emitted direction updates only after this angular drift (rad).
        public var angleDeadband: Double
        /// Emitted origin updates only after this positional drift (m).
        public var originDeadband: Double

        public init(alpha: Double = 0.35,
                    angleDeadband: Double = 0.02,
                    originDeadband: Double = 0.012) {
            self.alpha = alpha
            self.angleDeadband = angleDeadband
            self.originDeadband = originDeadband
        }

        public static let `default` = Config()
    }

    private let config: Config
    private var smoothedDirection: Vec2?
    private var smoothedOrigin: Vec2?
    private var emittedDirection: Vec2?
    private var emittedOrigin: Vec2?

    public init(config: Config = .default) {
        self.config = config
    }

    /// Feed one raw aim sample; returns the stabilized aim to act on and
    /// whether it CHANGED since the last emit (callers skip re-solving the
    /// shot when it didn't).
    public mutating func stabilize(_ raw: AimRay) -> (aim: AimRay, changed: Bool) {
        let alpha = config.alpha
        let newDirection: Vec2
        let newOrigin: Vec2
        if let currentDirection = smoothedDirection, let currentOrigin = smoothedOrigin {
            newDirection = (raw.direction * alpha + currentDirection * (1 - alpha)).normalized
            newOrigin = raw.origin * alpha + currentOrigin * (1 - alpha)
        } else {
            newDirection = raw.direction
            newOrigin = raw.origin
        }
        smoothedDirection = newDirection
        smoothedOrigin = newOrigin

        guard let lastDirection = emittedDirection, let lastOrigin = emittedOrigin else {
            emittedDirection = newDirection
            emittedOrigin = newOrigin
            return (AimRay(origin: newOrigin, direction: newDirection), true)
        }
        // dot → angle drift; clamp for acos safety.
        let dot = max(-1, min(1, newDirection.dot(lastDirection)))
        let drifted = Foundation.acos(dot) > config.angleDeadband
            || newOrigin.distance(to: lastOrigin) > config.originDeadband
        if drifted {
            emittedDirection = newDirection
            emittedOrigin = newOrigin
            return (AimRay(origin: newOrigin, direction: newDirection), true)
        }
        return (AimRay(origin: lastOrigin, direction: lastDirection), false)
    }

    /// Forget all state (call when the aim SOURCE switches, e.g. stick →
    /// device pose — blending across models would smear the transition).
    public mutating func reset() {
        smoothedDirection = nil
        smoothedOrigin = nil
        emittedDirection = nil
        emittedOrigin = nil
    }
}
