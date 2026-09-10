//
//  CalibrationHeight.swift
//  CueSync AR
//
//  Where the playing surface is, how sure we are, and when to change our
//  mind.
//
//  The corner taps decide the table's EXTENT and HEADING. They do not
//  decide its HEIGHT — a tap is a ray, and a ray needs a plane before it
//  means a point. Getting that plane wrong put the whole calibration quad
//  in the air above the cloth, and it did so silently, because every tap
//  agreed with the first one.
//
//  So height gets its own type, with two jobs the old code did not do:
//
//  1. SAY WHERE IT CAME FROM. "The balls told me, from 23 samples with 12
//     mm of spread" and "I guessed from an ARKit plane" are different
//     claims, and a calibration built on the second should say so rather
//     than look identical to one built on the first.
//
//  2. CHANGE ITS MIND. Ball evidence arrives continuously and improves —
//     3 samples become 30, and the spread narrows. A calibration locked
//     early on thin evidence should tighten as better evidence arrives,
//     rather than being frozen at whatever was known in the first second.
//     Otherwise the user has to know to re-calibrate later, which is a
//     thing no one will ever do.
//

import CueSyncCore
import Foundation

/// Where a calibration's plane height came from, and how much to trust it.
public enum CalibrationHeightSource: Sendable, Equatable {

    /// Measured from balls resting on the cloth. The best answer available,
    /// and the only one that improves on its own.
    case balls(samples: Int, spreadMillimetres: Int)
    /// A real ARKit plane with actual detected extent under the tap.
    case detectedPlane
    /// No plane and no balls: the height came from wherever the ray
    /// happened to land. A calibration built on this is a guess.
    case unconstrained

    /// Whether a calibration built on this should be treated as settled.
    public var isTrustworthy: Bool {
        switch self {
        case .balls(let samples, let spread): samples >= 3 && spread <= 40
        case .detectedPlane: true
        case .unconstrained: false
        }
    }

    /// What to tell the user, or nil when nothing needs saying.
    ///
    /// The ball count is concrete on purpose. "Put some balls on the table"
    /// leaves a person wondering whether two is some; the estimator needs
    /// three observations and gets better with range spread, so the advice
    /// says three and says to spread them.
    public var advice: String? {
        switch self {
        case .balls(let samples, let spread) where samples < 3:
            return "Roll a few more balls out — \(samples) so far, three is enough"
        case .balls(_, let spread) where spread > 40:
            return "The balls disagree about where the cloth is (\(spread) mm) — "
                + "check nothing else is being read as a ball"
        case .balls:
            return nil
        case .detectedPlane:
            return nil
        case .unconstrained:
            return "Put three or four balls on the table, spread out, so it can "
                + "find the cloth"
        }
    }

    /// Short label for the mirror and for a diagnostics row.
    public var summary: String {
        switch self {
        case .balls(let samples, let spread): "balls (\(samples) samples, \(spread) mm spread)"
        case .detectedPlane: "detected plane"
        case .unconstrained: "unconstrained"
        }
    }
}

/// When a locked calibration should move to a better-measured height.
public enum CalibrationRefinement: Sendable {

    public struct Config: Sendable, Equatable {
        /// Below this the estimate is not worth acting on.
        public var minimumSamples: Int
        /// Millimetres. A wide spread means the samples are not all balls.
        public var maximumSpread: Int
        /// Metres. Smaller than this and the correction is churn — it would
        /// re-anchor the table for a difference nobody can see.
        public var minimumCorrection: Double
        /// Metres. Larger than this and the ESTIMATE is what is wrong, not
        /// the calibration. Silently yanking a locked table 20 cm because
        /// the detector had a bad minute is worse than leaving it.
        public var maximumCorrection: Double

        public init(minimumSamples: Int = 8,
                    maximumSpread: Int = 30,
                    minimumCorrection: Double = 0.005,
                    maximumCorrection: Double = 0.15) {
            self.minimumSamples = minimumSamples
            self.maximumSpread = maximumSpread
            self.minimumCorrection = minimumCorrection
            self.maximumCorrection = maximumCorrection
        }
    }

    /// Why a refinement was or was not applied. Distinct cases because they
    /// need different words and, in one case, different action.
    public enum Decision: Sendable, Equatable {
        case refine(to: Double, correction: Double)
        case alreadyGoodEnough
        case estimateTooThin(samples: Int)
        case estimateTooScattered(spreadMillimetres: Int)
        /// The estimate disagrees so violently that it, not the
        /// calibration, is the suspect thing.
        case correctionImplausible(metres: Double)
    }

    public static func decide(lockedHeight: Double,
                              samples: Int,
                              spreadMillimetres: Int,
                              estimatedHeight: Double,
                              config: Config = Config()) -> Decision {
        guard samples >= config.minimumSamples else {
            return .estimateTooThin(samples: samples)
        }
        guard spreadMillimetres <= config.maximumSpread else {
            return .estimateTooScattered(spreadMillimetres: spreadMillimetres)
        }
        let correction = estimatedHeight - lockedHeight
        let magnitude = abs(correction)
        guard magnitude >= config.minimumCorrection else { return .alreadyGoodEnough }
        guard magnitude <= config.maximumCorrection else {
            return .correctionImplausible(metres: correction)
        }
        return .refine(to: estimatedHeight, correction: correction)
    }
}
