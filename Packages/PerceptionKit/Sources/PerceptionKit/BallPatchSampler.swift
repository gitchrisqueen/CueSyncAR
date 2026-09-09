//
//  BallPatchSampler.swift
//  PerceptionKit
//
//  Turning a detector box and a camera frame into a BallPatch.
//
//  Split in two on purpose. Everything here is pure: it reads pixels
//  through a protocol, so the geometry and the statistics can be
//  exercised on Linux against synthetic balls and against colours
//  measured off the owner's table. The CVPixelBuffer conformance that
//  makes it work on device lives at the bottom of this file behind a
//  platform check and contains no decisions.
//
//  Three things were measured on Sessions/device-20260909T190855Z
//  (frames 0-20, six balls, 1440x1080) and are the reason the code looks
//  the way it does:
//
//  1. Chroma is measured ABSOLUTELY (max channel minus min), never as a
//     saturation ratio. The eight ball is dark, so dividing by its value
//     amplifies sensor noise into colour: relative saturation called 65%
//     of the eight's pixels chromatic, which would have sent the one
//     ball that must never be misnamed down the hue path. Absolute
//     chroma separates perfectly - eight 0.000 and cue 0.000 against
//     0.97-1.00 for every coloured ball, with no threshold in between
//     doing any work.
//
//  2. Do not trim the patch to its brightest pixels. That was tried, to
//     drop the shadowed lower hemisphere, and it discards exactly the
//     evidence a stripe carries: on this table both stripe bands face
//     down-camera and sit in shadow, so "keep the brightest 65%" threw
//     the band away and reported both stripes as bandless.
//
//  3. Stripes are found by HUE SPREAD, not by whiteness. These balls'
//     bands are a warm cream, not a neutral white - under this room's
//     light the band is as far from neutral as the colour is, so a
//     whiteness test cannot see it. But a solid ball is one pigment, and
//     hue survives shading, so its lit pixels all share a hue; a stripe
//     has two materials and two hues. Measured over 14 frames, the
//     interquartile hue spread was 1.8-6.0 degrees (blue solid) and
//     6.5-9.0 (orange solid) against 26.9-30.7 (maroon stripe) and
//     32.7-35.5 (red stripe). No overlap, and a factor of three either
//     side of the default threshold.
//

import CueSyncCore
import Foundation

/// Read access to one frame's pixels, in the buffer's own row/column
/// grid, as linear-ish RGB with each channel 0...1.
///
/// Exists so the sampler never imports CoreVideo. Coordinates are pixel
/// indices from the TOP-LEFT of the buffer, matching `NormalizedRect`
/// once `VisionBoxMapping` has flipped Vision's bottom-left origin.
public protocol PixelSampling: Sendable {
    var pixelWidth: Int { get }
    var pixelHeight: Int { get }
    /// Nil outside the buffer.
    func rgb(x: Int, y: Int) -> Vec3?
}

public enum BallPatchSampler {
    public struct Config: Sendable, Equatable {
        /// Sampling disc radius as a fraction of the box's inscribed
        /// radius. Insets away from the silhouette, where the cloth
        /// bleeds in and the box is least accurate. Measured insensitive
        /// between 0.55 and 1.0; 0.80 keeps most of the ball.
        public var discFraction: Double
        /// Pixels at or above this value are a specular highlight - the
        /// light source, not the ball - and are dropped. They would
        /// otherwise read as bright neutral and inflate the white
        /// fraction of every glossy ball under a lamp.
        public var specularCeiling: Double
        /// Absolute chroma (max channel minus min) at or above which a
        /// pixel carries real colour.
        public var chromaFloor: Double
        /// Absolute chroma at or below which a pixel is neutral. Held
        /// below `chromaFloor` so no pixel is ever counted as both.
        public var whiteChromaCeiling: Double
        /// A neutral pixel must also be this bright to be white rather
        /// than black.
        public var whiteValueFloor: Double
        /// Pixels dimmer than this are too noisy for their hue to mean
        /// anything, and are left out of the spread.
        public var hueValueFloor: Double
        /// Below this many pixels there is no patch at all.
        public var minimumSamples: Int
        /// Below this many chromatic pixels the hue spread is reported
        /// as nil rather than computed from a handful of them. The cue
        /// ball and the eight land here every frame, which is correct:
        /// neither has a hue to spread.
        public var minimumChromaticSamples: Int

        public init(discFraction: Double = 0.80,
                    specularCeiling: Double = 0.97,
                    chromaFloor: Double = 0.12,
                    whiteChromaCeiling: Double = 0.10,
                    whiteValueFloor: Double = 0.25,
                    hueValueFloor: Double = 0.25,
                    minimumSamples: Int = 40,
                    minimumChromaticSamples: Int = 40) {
            self.discFraction = discFraction
            self.specularCeiling = specularCeiling
            self.chromaFloor = chromaFloor
            self.whiteChromaCeiling = whiteChromaCeiling
            self.whiteValueFloor = whiteValueFloor
            self.hueValueFloor = hueValueFloor
            self.minimumSamples = minimumSamples
            self.minimumChromaticSamples = minimumChromaticSamples
        }

        public static let `default` = Config()
    }

    /// Sample the ball inside `box`.
    ///
    /// Returns nil when the box is off the frame, degenerate, or yields
    /// too few pixels to say anything - never a patch built from six
    /// pixels of cloth.
    public static func sample(box: NormalizedRect,
                              from image: some PixelSampling,
                              config: Config = .default) -> BallPatch? {
        let width = Double(image.pixelWidth)
        let height = Double(image.pixelHeight)
        guard width > 0, height > 0, box.width > 0, box.height > 0 else { return nil }

        let centreX = box.center.x * width
        let centreY = box.center.y * height
        // The inscribed radius: detector boxes are not square (a ball at
        // 2.5 m measures about 28 x 32 px here), and the larger half-extent
        // would reach past the silhouette on the narrow axis.
        let radius = min(box.width * width, box.height * height) / 2 * config.discFraction
        guard radius >= 2 else { return nil }

        var samples: [Vec3] = []
        samples.reserveCapacity(Int(radius * radius * 4))
        let minX = max(0, Int((centreX - radius).rounded(.down)))
        let maxX = min(image.pixelWidth - 1, Int((centreX + radius).rounded(.up)))
        let minY = max(0, Int((centreY - radius).rounded(.down)))
        let maxY = min(image.pixelHeight - 1, Int((centreY + radius).rounded(.up)))
        guard minX < maxX, minY < maxY else { return nil }

        let radiusSquared = radius * radius
        for y in minY...maxY {
            let dy = Double(y) + 0.5 - centreY
            for x in minX...maxX {
                let dx = Double(x) + 0.5 - centreX
                guard dx * dx + dy * dy <= radiusSquared else { continue }
                guard let rgb = image.rgb(x: x, y: y) else { continue }
                guard value(rgb) < config.specularCeiling else { continue }
                samples.append(rgb)
            }
        }
        guard samples.count >= config.minimumSamples else { return nil }

        var sum = Vec3.zero
        var whiteCount = 0
        var chromaticCount = 0
        var hues: [Double] = []
        hues.reserveCapacity(samples.count)
        for rgb in samples {
            sum += rgb
            let high = value(rgb)
            let low = min(rgb.x, min(rgb.y, rgb.z))
            let chroma = high - low
            if chroma >= config.chromaFloor {
                chromaticCount += 1
                if high >= config.hueValueFloor, let hue = BallAppearance.hue(of: rgb) {
                    hues.append(hue)
                }
            } else if chroma <= config.whiteChromaCeiling, high >= config.whiteValueFloor {
                whiteCount += 1
            }
        }
        let count = Double(samples.count)
        return BallPatch(meanRGB: sum / count,
                         whiteFraction: Double(whiteCount) / count,
                         chromaFraction: Double(chromaticCount) / count,
                         sampleCount: samples.count,
                         hueSpread: hues.count >= config.minimumChromaticSamples
                             ? circularInterquartileRange(hues) : nil)
    }

    private static func value(_ rgb: Vec3) -> Double {
        max(rgb.x, max(rgb.y, rgb.z))
    }

    /// Interquartile range of a set of hues, in degrees, measured about
    /// their circular mean.
    ///
    /// Circular because hue wraps: a red ball's pixels straddle 0, and a
    /// plain numeric IQR over {2, 358} would report 356 degrees of
    /// spread on a perfectly uniform ball. The interquartile range
    /// rather than the full range because a stripe's edge pixels blend
    /// the two materials and land anywhere between them.
    static func circularInterquartileRange(_ hues: [Double]) -> Double? {
        guard hues.count >= 4 else { return nil }
        var sine = 0.0
        var cosine = 0.0
        for hue in hues {
            let radians = hue * .pi / 180
            sine += sin(radians)
            cosine += cos(radians)
        }
        guard sine != 0 || cosine != 0 else { return nil }
        let mean = atan2(sine, cosine) * 180 / .pi
        var deviations = hues.map { hue -> Double in
            var delta = (hue - mean).truncatingRemainder(dividingBy: 360)
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            return delta
        }
        deviations.sort()
        return percentile(deviations, 0.75) - percentile(deviations, 0.25)
    }

    /// Linear-interpolated percentile over a sorted array.
    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard let first = sorted.first, let last = sorted.last else { return 0 }
        guard sorted.count > 1 else { return first }
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let weight = position - Double(lower)
        guard lower >= 0 else { return first }
        guard upper < sorted.count else { return last }
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }
}
