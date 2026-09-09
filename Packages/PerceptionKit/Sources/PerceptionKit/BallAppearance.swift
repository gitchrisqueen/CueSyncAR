//
//  BallAppearance.swift
//  PerceptionKit
//
//  Telling a ball's colour — and so its number — from a 25-pixel patch.
//
//  On a standard American set colour IS the number: yellow is the 1 or
//  the 9, blue the 2 or the 10, and so on up to maroon. So a classifier
//  that gets the colour and the group right names the ball without ever
//  reading a digit, which is just as well: at the owner's shooting
//  distance a ball is 22-36 px across and the printed number is 3-4 px
//  tall, motion blurred, and facing away half the time.
//
//  Measured on Sessions/device-20260909T014006Z, and it decides the
//  design: under that room's light EVERY ball reads as orange. Raw hues
//  bunch into 19-34 degrees whatever the ball actually is — the blue
//  2-ball measures 25. White-balancing against the cue ball recovers
//  them completely (purple 271, blue 233, yellow 38, red 356), so every
//  feature here is measured relative to the cue ball and none is
//  absolute.
//

import CueSyncCore
import Foundation

/// What a ball's surface looks like, sampled from one frame.
///
/// Deliberately small and unitless-by-construction: no pixels, no
/// platform types, so the classifier can be exercised on Linux against
/// vectors measured from real recordings.
public struct BallPatch: Sendable, Equatable, Codable {
    /// Mean colour of the ball's pixels, each channel 0...1.
    public var meanRGB: Vec3
    /// Fraction of pixels that are bright and near-neutral — a stripe's
    /// band, or the eight's number patch.
    public var whiteFraction: Double
    /// Fraction carrying real colour.
    public var chromaFraction: Double
    /// How many pixels the patch was built from. Small patches are not
    /// trusted; the classifier says so rather than guessing.
    public var sampleCount: Int
    /// Interquartile spread of the patch's hues, in degrees, or nil when
    /// too few pixels carried a hue to measure one (the cue ball and the
    /// eight, every frame, correctly).
    ///
    /// This is what separates a stripe from a solid. A solid ball is one
    /// pigment and hue survives shading, so its lit pixels agree; a
    /// stripe has two materials and does not. Whiteness cannot do the
    /// job on real balls, whose bands are a warm cream rather than a
    /// neutral white - see BallPatchSampler for the measurements.
    public var hueSpread: Double?

    public init(meanRGB: Vec3, whiteFraction: Double,
                chromaFraction: Double, sampleCount: Int,
                hueSpread: Double? = nil) {
        self.meanRGB = meanRGB
        self.whiteFraction = whiteFraction
        self.chromaFraction = chromaFraction
        self.sampleCount = sampleCount
        self.hueSpread = hueSpread
    }
}

/// The cue ball, used as the illuminant.
///
/// It is a known white, it is already identified two ways (the detector's
/// own `white-ball` class and the player's tap designation), and it is in
/// frame whenever a shot is being aimed. That makes it the one reference
/// always available, and the reason this works at night under tungsten.
public struct WhiteReference: Sendable, Equatable {
    public var meanRGB: Vec3

    public init(meanRGB: Vec3) {
        self.meanRGB = meanRGB
    }

    /// Per-channel gains that would make the reference neutral, normalised
    /// on green. Nil when the reference is too dark to divide by.
    public var gains: Vec3? {
        let (r, g, b) = (meanRGB.x, meanRGB.y, meanRGB.z)
        guard r > 0.02, g > 0.02, b > 0.02 else { return nil }
        return Vec3(g / r, 1, g / b)
    }

    public func balanced(_ rgb: Vec3) -> Vec3? {
        guard let gains else { return nil }
        return Vec3(min(1, rgb.x * gains.x), min(1, rgb.y * gains.y), min(1, rgb.z * gains.z))
    }
}

/// The colours a standard set uses, one per number within a group.
public enum ColorFamily: String, Sendable, Equatable, CaseIterable, Codable {
    case yellow, blue, red, purple, orange, green, maroon, black, white

    /// Hue centre in degrees, for the chromatic families.
    var hueCentre: Double? {
        switch self {
        case .yellow: 48
        case .orange: 25
        case .red: 356
        case .maroon: 348
        case .purple: 275
        case .blue: 228
        case .green: 130
        case .black, .white: nil
        }
    }

    /// The solid carrying this colour: 1 yellow through 7 maroon.
    public var solidNumber: Int? {
        switch self {
        case .yellow: 1
        case .blue: 2
        case .red: 3
        case .purple: 4
        case .orange: 5
        case .green: 6
        case .maroon: 7
        case .black, .white: nil
        }
    }
}

/// One frame's reading of a ball.
public struct AppearanceObservation: Sendable, Equatable {
    public var family: ColorFamily
    /// 0...1. Driven by how much better the winning family fits than the
    /// runner-up, so the warm colours — which this room's light pushes
    /// together — report low confidence instead of a confident mistake.
    public var confidence: Double
    /// Passed through untouched for the aggregator, which needs the
    /// MAXIMUM seen over time rather than any single frame's value.
    public var whiteFraction: Double
    /// Likewise passed through: the aggregator takes the maximum hue
    /// spread ever seen, because a stripe showing its solid pole looks
    /// exactly like a solid and averaging hides the one look that told
    /// the truth.
    public var hueSpread: Double?

    public init(family: ColorFamily, confidence: Double, whiteFraction: Double,
                hueSpread: Double? = nil) {
        self.family = family
        self.confidence = confidence
        self.whiteFraction = whiteFraction
        self.hueSpread = hueSpread
    }
}

public enum BallAppearance {
    public struct Config: Sendable, Equatable {
        /// Below this many pixels a patch is not classified at all.
        public var minimumSamples: Int
        /// Chroma below this, with a dark surface, is the eight.
        public var blackChromaCeiling: Double
        public var blackValueCeiling: Double
        /// Mostly neutral and bright is the cue ball.
        public var whiteFractionFloor: Double
        /// Degrees of hue error at which a family's fit falls to zero.
        public var hueTolerance: Double

        public init(minimumSamples: Int = 40,
                    blackChromaCeiling: Double = 0.15,
                    blackValueCeiling: Double = 0.45,
                    whiteFractionFloor: Double = 0.55,
                    hueTolerance: Double = 40) {
            self.minimumSamples = minimumSamples
            self.blackChromaCeiling = blackChromaCeiling
            self.blackValueCeiling = blackValueCeiling
            self.whiteFractionFloor = whiteFractionFloor
            self.hueTolerance = hueTolerance
        }

        public static let `default` = Config()
    }

    /// Classify one patch.
    ///
    /// Returns nil without a `reference`, deliberately. The measured hue
    /// collapse under warm light is not a small bias to be corrected
    /// later — it makes every ball the same colour — so a guess made
    /// without a white reference would be worse than admitting there is
    /// none.
    public static func classify(_ patch: BallPatch, reference: WhiteReference?,
                                config: Config = .default) -> AppearanceObservation? {
        guard patch.sampleCount >= config.minimumSamples,
              let reference, let balanced = reference.balanced(patch.meanRGB) else { return nil }
        let value = Swift.max(balanced.x, Swift.max(balanced.y, balanced.z))

        if patch.whiteFraction >= config.whiteFractionFloor,
           patch.chromaFraction <= config.blackChromaCeiling {
            return AppearanceObservation(family: .white, confidence: 0.9,
                                         whiteFraction: patch.whiteFraction,
                                         hueSpread: patch.hueSpread)
        }
        if patch.chromaFraction <= config.blackChromaCeiling,
           value <= config.blackValueCeiling {
            // The eight is the one ball that must never be wrong: in
            // eight-ball, shooting it early is the game.
            return AppearanceObservation(family: .black, confidence: 0.9,
                                         whiteFraction: patch.whiteFraction,
                                         hueSpread: patch.hueSpread)
        }
        guard let hue = Self.hue(of: balanced) else { return nil }

        // Score every chromatic family, then let the margin between the
        // best two set the confidence. Yellow at 48 and orange at 25 are
        // genuinely close under this light, and the honest output is a
        // low number rather than a coin flip dressed as a decision.
        var scored: [(family: ColorFamily, fit: Double)] = []
        for family in ColorFamily.allCases {
            guard let centre = family.hueCentre else { continue }
            let error = Self.hueDistance(hue, centre)
            scored.append((family, Swift.max(0, 1 - error / config.hueTolerance)))
        }
        scored.sort { $0.fit > $1.fit }
        guard let best = scored.first, best.fit > 0 else { return nil }
        let runnerUp = scored.dropFirst().first?.fit ?? 0
        // Red and maroon are the same hue at different brightness, so the
        // hue margin alone cannot separate them; brightness does.
        var family = best.family
        if family == .red || family == .maroon {
            family = value < 0.55 ? .maroon : .red
        }
        // How much better the winner fits than the next best. A colour
        // with no near neighbour keeps its fit; one sitting between two
        // families loses almost all of it, which is the honest outcome
        // for the warm balls this room's light pushes together.
        let confidence = Swift.max(0, Swift.min(1, best.fit - runnerUp))
        return AppearanceObservation(family: family, confidence: confidence,
                                     whiteFraction: patch.whiteFraction,
                                     hueSpread: patch.hueSpread)
    }

    /// Hue in degrees of a linear RGB triple, or nil when it is neutral.
    static func hue(of rgb: Vec3) -> Double? {
        let (r, g, b) = (rgb.x, rgb.y, rgb.z)
        let high = Swift.max(r, Swift.max(g, b))
        let low = Swift.min(r, Swift.min(g, b))
        let chroma = high - low
        guard chroma > 1e-6 else { return nil }
        let raw: Double
        if high == r {
            raw = 60 * ((g - b) / chroma)
        } else if high == g {
            raw = 60 * (2 + (b - r) / chroma)
        } else {
            raw = 60 * (4 + (r - g) / chroma)
        }
        return (raw < 0 ? raw + 360 : raw).truncatingRemainder(dividingBy: 360)
    }

    /// Shortest distance between two hues, in degrees. Hue is a circle:
    /// 355 and 5 are ten degrees apart, not three hundred and fifty.
    static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let difference = abs(a - b).truncatingRemainder(dividingBy: 360)
        return Swift.min(difference, 360 - difference)
    }
}
