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

    /// The reference's own brightness once white-balanced (its largest
    /// channel, which is its green: the gains are normalised on green).
    /// The yardstick every relative feature divides by. Nil when the
    /// reference is too dark to balance.
    public var balancedValue: Double? {
        guard let reference = balanced(meanRGB) else { return nil }
        return Swift.max(reference.x, Swift.max(reference.y, reference.z))
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
    /// The patch's raw mean colour, passed through so the app can publish
    /// it and a later session can tune thresholds from real numbers.
    public var meanRGB: Vec3?
    /// Chroma and brightness of the patch's mean colour, white-balanced on
    /// the cue ball and divided by the cue ball's brightness: the two
    /// numbers the eight is ranked on (see `BallAppearance.relativeColour`).
    public var relativeChroma: Double?
    public var relativeValue: Double?
    /// The best CHROMATIC reading of a ball this look called black. Only
    /// set on those looks. A ball that loses the eight's election falls
    /// back to it: on a full table a dark blue, purple, maroon or dark
    /// green ball can read as neutral against a bright cue ball, and only
    /// one ball may be the eight.
    public var fallbackFamily: ColorFamily?
    public var fallbackConfidence: Double

    public init(family: ColorFamily, confidence: Double, whiteFraction: Double,
                hueSpread: Double? = nil, meanRGB: Vec3? = nil,
                relativeChroma: Double? = nil, relativeValue: Double? = nil,
                fallbackFamily: ColorFamily? = nil, fallbackConfidence: Double = 0) {
        self.family = family
        self.confidence = confidence
        self.whiteFraction = whiteFraction
        self.hueSpread = hueSpread
        self.meanRGB = meanRGB
        self.relativeChroma = relativeChroma
        self.relativeValue = relativeValue
        self.fallbackFamily = fallbackFamily
        self.fallbackConfidence = fallbackConfidence
    }
}

public enum BallAppearance {
    public struct Config: Sendable, Equatable {
        /// Below this many pixels a patch is not classified at all.
        public var minimumSamples: Int
        /// Fraction of individually chromatic pixels at or below which a
        /// patch counts as neutral for the WHITE route (see
        /// `whiteFractionFloor`). It no longer decides the eight: counting
        /// single pixels is exactly what named a dark blue ball the
        /// eight, see `blackMeanChromaCeiling`.
        public var blackChromaCeiling: Double
        /// Mostly neutral and bright is the cue ball.
        public var whiteFractionFloor: Double
        /// Degrees of hue error at which a family's fit falls to zero.
        public var hueTolerance: Double
        /// A ball whose AVERAGE colour, white-balanced on the cue ball,
        /// has chroma (max minus min channel) below this fraction of the
        /// cue ball's brightness is neutral: the eight if dark, white if
        /// not.
        ///
        /// Measured on the owner's table (research 2026-11-10, 160 labelled
        /// balls over 31 frames): the dark blue ball scores 0.236-0.313
        /// and the eight-ball samples score 0.020-0.079, so 0.15 sits
        /// about 3x from each side. The per-pixel route it replaces called
        /// that blue ball black at 0.9 confidence in 17 of 22 frames,
        /// because H.264 noise pushed its per-pixel chroma fraction under
        /// 0.15; averaging hundreds of pixels removes the noise, and
        /// dividing by the cue ball rather than by the ball's own value
        /// keeps a dim blue's colour from vanishing under an absolute
        /// floor. Fitted on three distinct eight-balls and one blue ball.
        public var blackMeanChromaCeiling: Double
        /// Of the neutral balls, one dimmer than this fraction of the cue
        /// ball is the eight. Measured eights: 0.18-0.52 of the cue ball.
        public var blackRelativeValueCeiling: Double
        /// A red-hued ball dimmer than this fraction of the cue ball is
        /// the maroon, otherwise the red. Relative to the cue ball
        /// because absolute brightness moves with the room: it fixed
        /// red-read-as-maroon in 15 of 22 iPad frames. Not separable by
        /// brightness across lights (red 0.72-0.92 against maroon
        /// 0.78-0.90 on two clips), so the answer is only ever a vote
        /// input: `BallIdentity` commits it after several agreeing looks.
        public var maroonRelativeValueCeiling: Double

        public init(minimumSamples: Int = 40,
                    blackChromaCeiling: Double = 0.15,
                    whiteFractionFloor: Double = 0.55,
                    hueTolerance: Double = 40,
                    blackMeanChromaCeiling: Double = 0.15,
                    blackRelativeValueCeiling: Double = 0.6,
                    maroonRelativeValueCeiling: Double = 0.75) {
            self.minimumSamples = minimumSamples
            self.blackChromaCeiling = blackChromaCeiling
            self.whiteFractionFloor = whiteFractionFloor
            self.hueTolerance = hueTolerance
            self.blackMeanChromaCeiling = blackMeanChromaCeiling
            self.blackRelativeValueCeiling = blackRelativeValueCeiling
            self.maroonRelativeValueCeiling = maroonRelativeValueCeiling
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
              let reference, let balanced = reference.balanced(patch.meanRGB),
              let relative = Self.relativeColour(of: patch, reference: reference) else { return nil }
        let meanChromaRelative = relative.chroma
        let valueRelative = relative.value

        func observation(_ family: ColorFamily, _ confidence: Double,
                         fallback: (family: ColorFamily, confidence: Double)? = nil)
            -> AppearanceObservation {
            AppearanceObservation(family: family, confidence: confidence,
                                  whiteFraction: patch.whiteFraction,
                                  hueSpread: patch.hueSpread, meanRGB: patch.meanRGB,
                                  relativeChroma: meanChromaRelative, relativeValue: valueRelative,
                                  fallbackFamily: fallback?.family,
                                  fallbackConfidence: fallback?.confidence ?? 0)
        }

        if patch.whiteFraction >= config.whiteFractionFloor,
           patch.chromaFraction <= config.blackChromaCeiling {
            return observation(.white, 0.9)
        }
        if meanChromaRelative < config.blackMeanChromaCeiling {
            // Neutral on average. The eight is the one ball that must
            // never be wrong: in eight-ball, shooting it early is the
            // game, so it is decided on the mean colour (3x margin each
            // side, see `blackMeanChromaCeiling`) and never on a count of
            // single pixels that looked coloured.
            //
            // A dark look also carries its best chromatic reading. On a
            // full table every dark ball (blue, purple, maroon, green and
            // the eight) can land here against a bright cue ball, and only
            // one may be the eight: `BallIdentity` ranks the dark balls
            // and sends the losers to this reading.
            if valueRelative < config.blackRelativeValueCeiling {
                return observation(.black, 0.9,
                                   fallback: hueFamily(of: balanced, value: valueRelative, config: config))
            }
            return observation(.white, 0.9)
        }
        guard let reading = hueFamily(of: balanced, value: valueRelative, config: config) else { return nil }
        return observation(reading.family, reading.confidence)
    }

    /// The chromatic family whose hue centre is nearest a white-balanced
    /// colour, with a confidence, or nil when the colour has no hue or
    /// sits outside every family's tolerance.
    ///
    /// Scores every chromatic family, then lets the margin between the
    /// best two set the confidence. Yellow at 48 and orange at 25 are
    /// genuinely close under this light, and the honest output is a low
    /// number rather than a coin flip dressed as a decision.
    static func hueFamily(of balanced: Vec3, value valueRelative: Double,
                          config: Config) -> (family: ColorFamily, confidence: Double)? {
        guard let hue = hue(of: balanced) else { return nil }
        var scored: [(family: ColorFamily, fit: Double)] = []
        for family in ColorFamily.allCases {
            guard let centre = family.hueCentre else { continue }
            let error = hueDistance(hue, centre)
            scored.append((family, Swift.max(0, 1 - error / config.hueTolerance)))
        }
        scored.sort { $0.fit > $1.fit }
        guard let best = scored.first, best.fit > 0 else { return nil }
        let runnerUp = scored.dropFirst().first?.fit ?? 0
        // Red and maroon are the same hue at different brightness, so the
        // hue margin alone cannot separate them; brightness relative to
        // the cue ball does, as far as anything single-frame can.
        var family = best.family
        if family == .red || family == .maroon {
            family = valueRelative < config.maroonRelativeValueCeiling ? .maroon : .red
        }
        // How much better the winner fits than the next best. A colour
        // with no near neighbour keeps its fit; one sitting between two
        // families loses almost all of it, which is the honest outcome
        // for the warm balls this room's light pushes together.
        return (family, Swift.max(0, Swift.min(1, best.fit - runnerUp)))
    }

    /// How coloured (max minus min channel) and how bright (max channel)
    /// the patch's AVERAGE colour is once white-balanced on `reference`,
    /// each as a fraction of the reference's own brightness. Nil when the
    /// reference is too dark to balance.
    ///
    /// This is the feature the eight is decided on: a dark blue ball
    /// measures chroma 0.24-0.31 and the true eights 0.02-0.08, where a
    /// count of individually coloured pixels put the blue under the line.
    static func relativeColour(of patch: BallPatch, reference: WhiteReference)
        -> (chroma: Double, value: Double)? {
        guard let balanced = reference.balanced(patch.meanRGB),
              let referenceValue = reference.balancedValue, referenceValue > 0 else { return nil }
        let high = Swift.max(balanced.x, Swift.max(balanced.y, balanced.z))
        let low = Swift.min(balanced.x, Swift.min(balanced.y, balanced.z))
        return ((high - low) / referenceValue, high / referenceValue)
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
