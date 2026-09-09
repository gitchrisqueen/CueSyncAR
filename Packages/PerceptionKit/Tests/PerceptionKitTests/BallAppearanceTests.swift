import CueSyncCore
import Foundation
import Testing
@testable import PerceptionKit

/// Patches measured from the owner's own table, not invented.
/// `Sessions/device-20260909T190855Z`, frames 60-150, sampled over the lit
/// upper part of each ball at 0.62 of its projected radius.
enum RealPatches {
    static let cue = BallPatch(meanRGB: Vec3(0.629, 0.620, 0.584),
                               whiteFraction: 0.912, chromaFraction: 0.000, sampleCount: 222)
    static let eight = BallPatch(meanRGB: Vec3(0.192, 0.157, 0.199),
                                 whiteFraction: 0.128, chromaFraction: 0.000, sampleCount: 177)
    static let blueSolid = BallPatch(meanRGB: Vec3(0.089, 0.218, 0.343),
                                     whiteFraction: 0.019, chromaFraction: 0.733, sampleCount: 159)
    static let maroonStripe = BallPatch(meanRGB: Vec3(0.467, 0.329, 0.249),
                                        whiteFraction: 0.059, chromaFraction: 0.789, sampleCount: 219)
    static let redStripe = BallPatch(meanRGB: Vec3(0.611, 0.313, 0.229),
                                     whiteFraction: 0.000, chromaFraction: 0.991, sampleCount: 330)
    static let orangeSolid = BallPatch(meanRGB: Vec3(0.740, 0.539, 0.275),
                                       whiteFraction: 0.000, chromaFraction: 0.991, sampleCount: 222)
    static let reference = WhiteReference(meanRGB: cue.meanRGB)
}

@Suite("BallAppearance")
struct BallAppearanceTests {
    private func classify(_ patch: BallPatch,
                          reference: WhiteReference? = RealPatches.reference)
        -> AppearanceObservation? {
        BallAppearance.classify(patch, reference: reference)
    }

    // MARK: - What it gets right on real balls

    @Test("The cue ball is unmistakable")
    func cueBall() throws {
        let observation = try #require(classify(RealPatches.cue))
        #expect(observation.family == .white)
        #expect(observation.confidence > 0.8)
    }

    /// The eight must never be wrong. In eight-ball, shooting it early is
    /// the game, so a confident mistake here costs more than any other.
    @Test("The eight is unmistakable, and nothing else is called black")
    func eightBall() throws {
        let observation = try #require(classify(RealPatches.eight))
        #expect(observation.family == .black)
        #expect(observation.confidence > 0.8)
        for other in [RealPatches.blueSolid, RealPatches.redStripe,
                      RealPatches.orangeSolid, RealPatches.maroonStripe, RealPatches.cue] {
            #expect(classify(other)?.family != .black)
        }
    }

    @Test("Blue is recognised: it is far from every other colour on the table")
    func blueIsSeparable() throws {
        let observation = try #require(classify(RealPatches.blueSolid))
        #expect(observation.family == .blue)
        #expect(observation.confidence > 0.5)
    }

    // MARK: - What it does NOT get right, measured

    /// The finding that bounds this whole feature. Under mixed daylight
    /// and interior light the warm balls' mean hues land at 12, 20 and 34
    /// degrees — red, maroon and orange all inside a 22-degree band, on a
    /// scale where the family centres are 23 degrees apart. A striped
    /// ball is worse still, because averaging its band with its colour
    /// pulls the mean toward neutral.
    ///
    /// So the classifier must NOT name these confidently, and this test
    /// exists to fail if someone later tunes it into pretending it can.
    @Test("The warm balls are not confidently named, because they cannot be")
    func warmColoursAreHonestlyUncertain() throws {
        for patch in [RealPatches.redStripe, RealPatches.maroonStripe, RealPatches.orangeSolid] {
            let observation = try #require(classify(patch))
            #expect(observation.confidence < 0.75,
                    "\(observation.family) claimed \(observation.confidence)")
        }
    }

    @Test("Without a white reference nothing is classified at all")
    func refusesWithoutAReference() {
        #expect(classify(RealPatches.blueSolid, reference: nil) == nil)
        // A reference too dark to divide by is no reference.
        let black = WhiteReference(meanRGB: Vec3(0.001, 0.001, 0.001))
        #expect(black.gains == nil)
        #expect(classify(RealPatches.blueSolid, reference: black) == nil)
    }

    @Test("A patch built from too few pixels is refused")
    func refusesTinyPatches() {
        var tiny = RealPatches.blueSolid
        tiny.sampleCount = 12
        #expect(classify(tiny) == nil)
    }

    // MARK: - White balance

    /// The reason every feature here is relative. Measured under the
    /// owner's night lighting, raw hues bunched into 19-34 degrees for
    /// every ball on the table — the blue 2-ball read 25 degrees, which
    /// is orange. Balancing on the cue ball recovers them.
    @Test("White balance is what makes a blue ball read as blue")
    func whiteBalanceRecoversHue() throws {
        // A warm illuminant: everything gains red and loses blue.
        let warm = Vec3(1.35, 1.0, 0.62)
        func lit(_ rgb: Vec3) -> Vec3 {
            Vec3(min(1, rgb.x * warm.x), min(1, rgb.y * warm.y), min(1, rgb.z * warm.z))
        }
        let litBlue = lit(RealPatches.blueSolid.meanRGB)
        let litCue = lit(RealPatches.cue.meanRGB)
        let rawHue = try #require(BallAppearance.hue(of: litBlue))
        #expect(rawHue < 200, "under warm light the raw hue is dragged off blue: \(rawHue)")

        var patch = RealPatches.blueSolid
        patch.meanRGB = litBlue
        let observation = try #require(
            BallAppearance.classify(patch, reference: WhiteReference(meanRGB: litCue)))
        #expect(observation.family == .blue, "balancing on the cue ball should recover it")
    }

    @Test("Gains are normalised on green and neutralise the reference")
    func gainsNeutraliseTheReference() throws {
        let reference = WhiteReference(meanRGB: Vec3(0.62, 0.58, 0.44))
        let gains = try #require(reference.gains)
        #expect(gains.y == 1)
        let neutral = try #require(reference.balanced(reference.meanRGB))
        #expect(abs(neutral.x - neutral.y) < 1e-9)
        #expect(abs(neutral.z - neutral.y) < 1e-9)
    }

    // MARK: - Hue arithmetic

    @Test("Hue is a circle: 355 and 5 are ten degrees apart")
    func hueWrapsAround() {
        #expect(abs(BallAppearance.hueDistance(355, 5) - 10) < 1e-9)
        #expect(abs(BallAppearance.hueDistance(5, 355) - 10) < 1e-9)
        #expect(abs(BallAppearance.hueDistance(10, 200) - 170) < 1e-9)
        #expect(BallAppearance.hueDistance(48, 48) == 0)
    }

    @Test("A neutral patch has no hue rather than an arbitrary one")
    func neutralHasNoHue() {
        #expect(BallAppearance.hue(of: Vec3(0.5, 0.5, 0.5)) == nil)
        #expect(BallAppearance.hue(of: Vec3(1, 0, 0)) == 0)
        #expect(abs((BallAppearance.hue(of: Vec3(0, 1, 0)) ?? -1) - 120) < 1e-9)
        #expect(abs((BallAppearance.hue(of: Vec3(0, 0, 1)) ?? -1) - 240) < 1e-9)
    }

    @Test("Every chromatic family maps to a solid number, and the neutrals do not")
    func familyNumbers() {
        #expect(ColorFamily.yellow.solidNumber == 1)
        #expect(ColorFamily.blue.solidNumber == 2)
        #expect(ColorFamily.maroon.solidNumber == 7)
        #expect(ColorFamily.black.solidNumber == nil)
        #expect(ColorFamily.white.solidNumber == nil)
        let numbered = ColorFamily.allCases.compactMap(\.solidNumber).sorted()
        #expect(numbered == [1, 2, 3, 4, 5, 6, 7])
    }
}
