//
//  BallPatchSamplerTests.swift
//  PerceptionKitTests
//
//  The sampler is exercised against synthetic balls whose answer is
//  known by construction, and against a rendering of the six balls
//  actually on the owner's table, whose colours were measured off
//  Sessions/device-20260909T190855Z.
//

import CueSyncCore
import Foundation
import Testing

@testable import PerceptionKit

/// A flat image of RGB triples, for driving the pure sampler.
private struct TestImage: PixelSampling {
    let pixelWidth: Int
    let pixelHeight: Int
    var pixels: [Vec3]

    init(width: Int, height: Int, fill: Vec3 = Vec3(0, 0, 0)) {
        pixelWidth = width
        pixelHeight = height
        pixels = Array(repeating: fill, count: width * height)
    }

    func rgb(x: Int, y: Int) -> Vec3? {
        guard x >= 0, y >= 0, x < pixelWidth, y < pixelHeight else { return nil }
        return pixels[y * pixelWidth + x]
    }

    mutating func set(_ x: Int, _ y: Int, _ rgb: Vec3) {
        guard x >= 0, y >= 0, x < pixelWidth, y < pixelHeight else { return }
        pixels[y * pixelWidth + x] = rgb
    }

    /// Draw a ball: a disc of `body`, optionally with a horizontal band
    /// of `band` across its middle third, shaded so the bottom is darker
    /// exactly as a real ball under a ceiling light is.
    mutating func drawBall(centreX: Double, centreY: Double, radius: Double,
                           body: Vec3, band: Vec3? = nil, bandFraction: Double = 0.34,
                           shading: Bool = true) {
        let minX = Int(centreX - radius) - 1
        let maxX = Int(centreX + radius) + 1
        let minY = Int(centreY - radius) - 1
        let maxY = Int(centreY + radius) + 1
        for y in minY...maxY {
            for x in minX...maxX {
                let dx = Double(x) + 0.5 - centreX
                let dy = Double(y) + 0.5 - centreY
                guard dx * dx + dy * dy <= radius * radius else { continue }
                var colour = body
                if let band, abs(dy) <= radius * bandFraction { colour = band }
                if shading {
                    // Full brightness at the top, 45% at the bottom.
                    let lit = 1.0 - 0.55 * ((dy / radius) + 1) / 2
                    colour *= lit
                }
                set(x, y, colour)
            }
        }
    }
}

private func box(centreX: Double, centreY: Double, radius: Double,
                 in image: TestImage) -> NormalizedRect {
    let width = Double(image.pixelWidth)
    let height = Double(image.pixelHeight)
    return NormalizedRect(x: (centreX - radius) / width,
                          y: (centreY - radius) / height,
                          width: 2 * radius / width,
                          height: 2 * radius / height)
}

@Suite("Ball patch sampler")
struct BallPatchSamplerTests {

    // MARK: - Geometry

    @Test("A solid ball yields its own colour and nothing of the cloth")
    func solidBallIsSampledCleanly() throws {
        var image = TestImage(width: 120, height: 120, fill: Vec3(0.02, 0.02, 0.02))
        image.drawBall(centreX: 60, centreY: 60, radius: 16,
                       body: Vec3(0.10, 0.25, 0.40), shading: false)
        let patch = try #require(BallPatchSampler.sample(box: box(centreX: 60, centreY: 60,
                                                                  radius: 16, in: image),
                                                         from: image))
        #expect(abs(patch.meanRGB.x - 0.10) < 0.01)
        #expect(abs(patch.meanRGB.y - 0.25) < 0.01)
        #expect(abs(patch.meanRGB.z - 0.40) < 0.01)
        #expect(patch.chromaFraction == 1.0)
        #expect(patch.whiteFraction == 0.0)
    }

    @Test("A box that runs off the edge of the frame is refused, not clipped silently")
    func boxOffTheFrameIsRefused() {
        let image = TestImage(width: 60, height: 60, fill: Vec3(0.5, 0.5, 0.5))
        #expect(BallPatchSampler.sample(box: NormalizedRect(x: 1.4, y: 0.4,
                                                           width: 0.1, height: 0.1),
                                        from: image) == nil)
    }

    @Test("A ball too small to carry information yields no patch")
    func tinyBallYieldsNoPatch() {
        var image = TestImage(width: 60, height: 60, fill: Vec3(0.02, 0.02, 0.02))
        image.drawBall(centreX: 30, centreY: 30, radius: 2, body: Vec3(0.8, 0.2, 0.2),
                       shading: false)
        #expect(BallPatchSampler.sample(box: box(centreX: 30, centreY: 30, radius: 2,
                                                 in: image), from: image) == nil)
    }

    @Test("A degenerate box is refused rather than dividing by zero")
    func degenerateBoxIsRefused() {
        let image = TestImage(width: 60, height: 60, fill: Vec3(0.5, 0.5, 0.5))
        #expect(BallPatchSampler.sample(box: NormalizedRect(x: 0.5, y: 0.5,
                                                           width: 0, height: 0.1),
                                        from: image) == nil)
    }

    @Test("Specular highlight is dropped, so a lamp does not turn a red ball white")
    func specularHighlightIsExcluded() throws {
        var image = TestImage(width: 120, height: 120, fill: Vec3(0.02, 0.02, 0.02))
        image.drawBall(centreX: 60, centreY: 60, radius: 16,
                       body: Vec3(0.70, 0.15, 0.12), shading: false)
        // A blown-out highlight over a quarter of the ball.
        for y in 48...58 {
            for x in 52...68 where (Double(x) - 60) * (Double(x) - 60)
                + (Double(y) - 60) * (Double(y) - 60) <= 256 {
                image.set(x, y, Vec3(1, 1, 1))
            }
        }
        let patch = try #require(BallPatchSampler.sample(box: box(centreX: 60, centreY: 60,
                                                                  radius: 16, in: image),
                                                         from: image))
        #expect(patch.whiteFraction == 0.0)
        #expect(patch.chromaFraction == 1.0)
    }

    // MARK: - Hue spread, the stripe signal

    @Test("A solid ball has a hue spread near zero however it is shaded")
    func solidBallHasNoHueSpread() throws {
        var image = TestImage(width: 120, height: 120, fill: Vec3(0.02, 0.02, 0.02))
        image.drawBall(centreX: 60, centreY: 60, radius: 18,
                       body: Vec3(0.80, 0.45, 0.10), shading: true)
        let patch = try #require(BallPatchSampler.sample(box: box(centreX: 60, centreY: 60,
                                                                  radius: 18, in: image),
                                                         from: image))
        let spread = try #require(patch.hueSpread)
        // Shading scales all three channels, so hue is untouched by it.
        #expect(spread < 1.0)
    }

    @Test("A striped ball's hue spread clears the threshold that a solid's does not")
    func stripedBallHasWideHueSpread() throws {
        var image = TestImage(width: 120, height: 120, fill: Vec3(0.02, 0.02, 0.02))
        image.drawBall(centreX: 60, centreY: 60, radius: 18,
                       body: Vec3(0.70, 0.16, 0.13),      // red body, hue ~3 degrees
                       band: Vec3(0.62, 0.53, 0.33))      // cream band, hue ~41 degrees
        let patch = try #require(BallPatchSampler.sample(box: box(centreX: 60, centreY: 60,
                                                                  radius: 18, in: image),
                                                         from: image))
        let spread = try #require(patch.hueSpread)
        #expect(spread >= BallIdentity.Config.default.stripeHueSpread)
    }

    @Test("A ball with no chromatic pixels reports no hue spread rather than a made-up one")
    func achromaticBallHasNoHueSpread() throws {
        var image = TestImage(width: 120, height: 120, fill: Vec3(0.02, 0.02, 0.02))
        image.drawBall(centreX: 60, centreY: 60, radius: 18,
                       body: Vec3(0.66, 0.65, 0.63), shading: true)
        let patch = try #require(BallPatchSampler.sample(box: box(centreX: 60, centreY: 60,
                                                                  radius: 18, in: image),
                                                         from: image))
        #expect(patch.hueSpread == nil)
        #expect(patch.chromaFraction == 0.0)
    }

    @Test("Hue spread is circular, so a red ball straddling 0 degrees is not called striped")
    func hueSpreadWrapsAroundZero() throws {
        // Hues at 358, 359, 0, 1, 2 degrees: three degrees of spread, not
        // three hundred and fifty-eight.
        let hues = [358.0, 359, 0, 1, 2, 358.5, 1.5, 0.5]
        let spread = try #require(BallPatchSampler.circularInterquartileRange(hues))
        #expect(spread < 5)
    }

    @Test("Hue spread needs enough pixels to mean anything")
    func hueSpreadNeedsSamples() {
        #expect(BallPatchSampler.circularInterquartileRange([10, 20]) == nil)
    }

    // MARK: - Robustness

    @Test("A box off by three pixels does not change what the ball is")
    func samplingSurvivesBoxJitter() throws {
        var image = TestImage(width: 160, height: 160, fill: Vec3(0.02, 0.02, 0.02))
        image.drawBall(centreX: 80, centreY: 80, radius: 16,
                       body: Vec3(0.70, 0.16, 0.13), band: Vec3(0.62, 0.53, 0.33))
        let offsets: [(Double, Double)] = [(0, 0), (3, 0), (-3, 0), (0, 3), (0, -3),
                                           (2, 2), (-2, 2), (2, -2), (-2, -2)]
        for (dx, dy) in offsets {
            let patch = try #require(BallPatchSampler.sample(
                box: box(centreX: 80 + dx, centreY: 80 + dy, radius: 16, in: image),
                from: image), "no patch at offset (\(dx), \(dy))")
            let spread = try #require(patch.hueSpread, "no spread at offset (\(dx), \(dy))")
            #expect(spread >= BallIdentity.Config.default.stripeHueSpread,
                    "offset (\(dx), \(dy)) lost the stripe: spread \(spread)")
        }
    }

    // MARK: - The real table

    /// The six balls on the owner's table, rendered from the mean body
    /// and band colours measured off the recording, then put through the
    /// sampler and the classifier end to end.
    ///
    /// This is not a substitute for a device run — the real frames carry
    /// noise, motion blur and a moving light this rendering does not —
    /// but it pins the whole chain against colours that came off a
    /// camera rather than out of a designer's head.
    @Test("The owner's six balls classify correctly through the whole chain")
    func realTableBallsClassify() throws {
        // Measured on Sessions/device-20260909T190855Z, frames 0-20.
        let table: [(name: String, body: Vec3, band: Vec3?, expected: BallGrouping)] = [
            ("eight", Vec3(0.24, 0.20, 0.24), nil, .eight),
            ("cue", Vec3(0.70, 0.69, 0.65), nil, .cue),
            ("blue solid", Vec3(0.13, 0.27, 0.40), nil, .solid),
            ("orange solid", Vec3(0.83, 0.57, 0.29), nil, .solid),
            ("red stripe", Vec3(0.67, 0.29, 0.24), Vec3(0.62, 0.53, 0.33), .stripe),
            ("maroon stripe", Vec3(0.48, 0.32, 0.28), Vec3(0.60, 0.50, 0.31), .stripe)
        ]

        // The cue ball is the illuminant, exactly as on device.
        var image = TestImage(width: 160, height: 160, fill: Vec3(0.02, 0.02, 0.02))
        image.drawBall(centreX: 80, centreY: 80, radius: 16, body: Vec3(0.70, 0.69, 0.65))
        let cuePatch = try #require(BallPatchSampler.sample(
            box: box(centreX: 80, centreY: 80, radius: 16, in: image), from: image))
        let reference = WhiteReference(meanRGB: cuePatch.meanRGB)

        for ball in table {
            var frame = TestImage(width: 160, height: 160, fill: Vec3(0.02, 0.02, 0.02))
            frame.drawBall(centreX: 80, centreY: 80, radius: 16,
                           body: ball.body, band: ball.band)
            let patch = try #require(BallPatchSampler.sample(
                box: box(centreX: 80, centreY: 80, radius: 16, in: frame), from: frame),
                                     "\(ball.name): no patch")
            let observation = try #require(BallAppearance.classify(patch, reference: reference),
                                           "\(ball.name): not classified")
            var identity = BallIdentity()
            let id = BallID(rawValue: 1)
            for _ in 0..<6 { identity.observe(observation, for: id) }
            let detail = "\(ball.name): expected \(ball.expected), "
                + "got \(String(describing: identity.group(for: id))) "
                + "— hue spread \(String(describing: patch.hueSpread)), "
                + "chroma \(patch.chromaFraction), white \(patch.whiteFraction)"
            #expect(identity.group(for: id) == ball.expected, "\(detail)")
        }
    }

    @Test("The eight is never mistaken for a colour, whatever else is tuned")
    func eightIsNeverColoured() throws {
        var image = TestImage(width: 160, height: 160, fill: Vec3(0.02, 0.02, 0.02))
        image.drawBall(centreX: 80, centreY: 80, radius: 16, body: Vec3(0.70, 0.69, 0.65))
        let cuePatch = try #require(BallPatchSampler.sample(
            box: box(centreX: 80, centreY: 80, radius: 16, in: image), from: image))
        let reference = WhiteReference(meanRGB: cuePatch.meanRGB)

        var frame = TestImage(width: 160, height: 160, fill: Vec3(0.02, 0.02, 0.02))
        // The eight with its white number patch, as it appears on the table.
        frame.drawBall(centreX: 80, centreY: 80, radius: 16, body: Vec3(0.24, 0.20, 0.24))
        for y in 68...74 {
            for x in 76...84 { frame.set(x, y, Vec3(0.72, 0.71, 0.69)) }
        }
        let patch = try #require(BallPatchSampler.sample(
            box: box(centreX: 80, centreY: 80, radius: 16, in: frame), from: frame))
        // The measured separation: an absolute-chroma reading puts the
        // eight at zero, far under the ceiling. Relative saturation put
        // it at 0.65 and would have sent it down the hue path.
        #expect(patch.chromaFraction <= BallAppearance.Config.default.blackChromaCeiling)
        let observation = try #require(BallAppearance.classify(patch, reference: reference))
        #expect(observation.family == .black)
    }
}
