//
//  BallNamingEvidenceTests.swift
//  PerceptionKitTests
//
//  Synthetic colour statistics only (no images): hue in degrees and chroma
//  and brightness relative to the cue ball, taken from the 15-ball layout
//  recorded 2026-11-12. Each test pins one rule and the pair of balls that
//  used to collide under it.
//

import CueSyncCore
import Foundation
import Testing
@testable import PerceptionKit

/// A patch with the stated hue, chroma and brightness against a neutral
/// cue ball of value 0.8, so relative chroma and value are the stated
/// numbers divided out exactly.
private enum Synthetic {
    static let cueValue = 0.8
    static let reference = WhiteReference(meanRGB: Vec3(cueValue, cueValue, cueValue))

    static func rgb(hue: Double, chroma relativeChroma: Double, value relativeValue: Double) -> Vec3 {
        let high = relativeValue * cueValue
        let chroma = relativeChroma * cueValue
        let low = high - chroma
        let sector = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double)
        switch Int(sector) {
        case 0: (r, g, b) = (chroma, x, 0)
        case 1: (r, g, b) = (x, chroma, 0)
        case 2: (r, g, b) = (0, chroma, x)
        case 3: (r, g, b) = (0, x, chroma)
        case 4: (r, g, b) = (x, 0, chroma)
        default: (r, g, b) = (chroma, 0, x)
        }
        return Vec3(low + r, low + g, low + b)
    }

    static func patch(hue: Double, chroma: Double, value: Double,
                      spread: Double? = 3) -> BallPatch {
        BallPatch(meanRGB: rgb(hue: hue, chroma: chroma, value: value),
                  whiteFraction: 0, chromaFraction: 1, sampleCount: 200, hueSpread: spread)
    }

    static func look(hue: Double, chroma: Double, value: Double,
                     spread: Double? = 3) -> AppearanceObservation? {
        BallAppearance.classify(patch(hue: hue, chroma: chroma, value: value, spread: spread),
                                reference: reference)
    }
}

@Suite("Warm colours: maroon, red, orange and yellow")
struct WarmColourTests {
    private func family(hue: Double, chroma: Double, value: Double) throws -> ColorFamily {
        try #require(Synthetic.look(hue: hue, chroma: chroma, value: value)).family
    }

    @Test("The synthetic patch reproduces the numbers it was built from")
    func syntheticPatchIsFaithful() throws {
        let look = try #require(Synthetic.look(hue: 13, chroma: 0.25, value: 0.55))
        #expect(abs((look.relativeChroma ?? 0) - 0.25) < 1e-9)
        #expect(abs((look.relativeValue ?? 0) - 0.55) < 1e-9)
        #expect(abs((look.hue ?? 0) - 13) < 1e-6)
    }

    @Test("Maroon is maroon at the hues the iPad measured, where hue alone said orange")
    func maroonAtItsMeasuredHues() throws {
        // Maroon solid 1.2-18.8 degrees, maroon stripe 8.7-19.7; chroma
        // 0.19-0.31, value 0.48-0.71.
        for hue in [2.0, 8.0, 11.0, 15.0, 19.0, 25.0] {
            #expect(try family(hue: hue, chroma: 0.23, value: 0.54) == .maroon, "hue \(hue), solid")
            #expect(try family(hue: hue, chroma: 0.28, value: 0.67) == .maroon, "hue \(hue), stripe")
        }
    }

    @Test("Orange at the same hues stays orange, because it is far more coloured and brighter")
    func orangeAtMaroonsHues() throws {
        // Orange solid 12.0-19.0 degrees, orange stripe 19.5-23.4; chroma
        // 0.64-0.75, value 0.92-1.03. Same hues as the maroon above.
        for hue in [12.0, 15.0, 19.0, 21.0, 23.0] {
            #expect(try family(hue: hue, chroma: 0.68, value: 0.95) == .orange, "hue \(hue)")
        }
    }

    @Test("Red stays red next to maroon: same hue band, but twice the chroma and well above the value line")
    func redAgainstMaroon() throws {
        // Red solid -5.3-3.8 degrees, red stripe -0.1-7.5; chroma 0.47-0.58,
        // value 0.80-0.96.
        for hue in [355.0, 0.0, 4.0, 7.0] {
            #expect(try family(hue: hue, chroma: 0.52, value: 0.88) == .red, "hue \(hue)")
        }
        #expect(try family(hue: 0, chroma: 0.25, value: 0.54) == .maroon)
    }

    @Test("Both conditions are needed: a dim but vivid ball, or a bright but pale one, is not maroon")
    func maroonNeedsBoth() throws {
        // Dim and vivid: an orange ball in shadow keeps its chroma.
        #expect(try family(hue: 20, chroma: 0.60, value: 0.70) == .orange)
        // Pale and bright: not a maroon either.
        #expect(try family(hue: 20, chroma: 0.30, value: 0.95) != .maroon)
    }

    @Test("The maroon look is confident enough to be named, and more so deeper inside both lines")
    func maroonConfidence() throws {
        let typical = try #require(Synthetic.look(hue: 13, chroma: 0.25, value: 0.55))
        let edge = try #require(Synthetic.look(hue: 13, chroma: 0.38, value: 0.76))
        #expect(typical.confidence >= BallIdentity.Config.default.namingConfidence)
        #expect(edge.confidence >= 0.6)
        #expect(typical.confidence > edge.confidence)
    }

    @Test("Yellow reads yellow across the hues it measured, including the ones that sat on the old boundary")
    func yellowHoldsItsBoundary() throws {
        // Yellow solid 36.6-40.4, yellow stripe 36.7-40.3: the old centre
        // (48) put the line at 36.5.
        for hue in [36.6, 37.5, 38.7, 40.4] {
            #expect(try family(hue: hue, chroma: 0.80, value: 1.0) == .yellow, "hue \(hue)")
        }
    }

    @Test("Orange stays orange across everything measured, up to the hue of the earlier session")
    func orangeHoldsItsBoundary() throws {
        // 12-23.4 on the 15-ball layout and 32.6-33.9 on the 2026-11-11
        // session; the yellow centre moved to 44 and must not take these.
        for hue in [12.0, 16.0, 21.0, 23.4, 32.6, 33.9] {
            #expect(try family(hue: hue, chroma: 0.68, value: 0.95) == .orange, "hue \(hue)")
        }
    }
}

@Suite("Solid against stripe")
struct SolidAgainstStripeTests {
    private func identity(hue: Double, chroma: Double, value: Double, spread: Double,
                          looks: Int = 12) throws -> (BallIdentity, BallID) {
        var identity = BallIdentity()
        let id = BallID(7)
        let look = try #require(Synthetic.look(hue: hue, chroma: chroma, value: value, spread: spread))
        for _ in 0..<looks { identity.observe(look, for: id) }
        return (identity, id)
    }

    @Test("A red ball is told solid from stripe by its hue spread, as measured")
    func redIsDecidedBySpread() throws {
        let (solid, solidID) = try identity(hue: 358, chroma: 0.52, value: 0.91, spread: 6.4)
        #expect(solid.group(for: solidID) == .solid)
        #expect(solid.family(for: solidID)?.family == .red)
        let (stripe, stripeID) = try identity(hue: 4, chroma: 0.53, value: 0.86, spread: 24.7)
        #expect(stripe.group(for: stripeID) == .stripe)
        #expect(stripe.family(for: stripeID)?.family == .red)
    }

    @Test("A yellow or orange ball that shows no band is not called solid: its stripe's band is the same hue")
    func bandBlindPigmentsStayUnknown() throws {
        // Yellow stripe measured spread 1.9-7.5 and orange stripe 4.7-9.5,
        // inside the solids' ranges (1.1-4.6 and 1.7-10.3).
        for (hue, chroma, spread) in [(38.5, 0.8, 2.2), (38.3, 0.63, 4.5), (16.0, 0.69, 3.7), (21.0, 0.68, 7.4)] {
            let (identity, id) = try identity(hue: hue, chroma: chroma, value: 0.97, spread: spread)
            #expect(identity.group(for: id) == nil, "hue \(hue) spread \(spread)")
            #expect(identity.kind(for: id) == .unknown)
        }
    }

    @Test("Seeing a band still makes a stripe on a yellow ball: only the absence of one stops meaning solid")
    func bandSeenOnYellowIsStillAStripe() throws {
        let (identity, id) = try identity(hue: 38, chroma: 0.7, value: 0.95, spread: 30)
        #expect(identity.group(for: id) == .stripe)
    }

    @Test("A dim ball's spread is noise and is not a stripe: the maroon solid read 16.8-34.7 degrees")
    func dimSpreadIsIgnored() throws {
        let (identity, id) = try identity(hue: 11, chroma: 0.23, value: 0.54, spread: 34.7)
        #expect(identity.group(for: id) != .stripe)
        #expect(identity.kind(for: id) != .stripe(15))
        // Its hue is the band's too, so it is not called solid either.
        #expect(identity.group(for: id) == nil)
    }

    @Test("The brightness line is 0.6: a look just under it is ignored, one at it counts")
    func brightnessLine() throws {
        let (under, underID) = try identity(hue: 230, chroma: 0.5, value: 0.59, spread: 30)
        #expect(under.group(for: underID) == .solid)
        let (over, overID) = try identity(hue: 230, chroma: 0.5, value: 0.61, spread: 30)
        #expect(over.group(for: overID) == .stripe)
    }

    @Test("One bright look at a band is still proof, among many dim noisy ones")
    func oneBrightLookIsProof() {
        var identity = BallIdentity()
        let id = BallID(7)
        for _ in 0..<10 {
            if let dim = Synthetic.look(hue: 230, chroma: 0.5, value: 0.5, spread: 60) { identity.observe(dim, for: id) }
        }
        #expect(identity.group(for: id) == .solid, "dim spread alone proves nothing")
        if let bright = Synthetic.look(hue: 230, chroma: 0.5, value: 0.9, spread: 28) {
            identity.observe(bright, for: id)
        }
        #expect(identity.group(for: id) == .stripe)
    }

    @Test("Observations that carry no hue or brightness keep the behaviour they always had")
    func legacyObservationsAreUnchanged() {
        var identity = BallIdentity()
        let id = BallID(3)
        for _ in 0..<8 {
            identity.observe(AppearanceObservation(family: .orange, confidence: 0.9, whiteFraction: 0,
                                                   hueSpread: 9), for: id)
        }
        #expect(identity.group(for: id) == .solid)
    }
}

@Suite("Dark balls that are not the eight")
struct DarkBallNamingTests {
    private let eightID = BallID(8)
    private let darkID = BallID(4)

    /// A dark ball whose neutral reading made it a black candidate, with
    /// the chromatic reading it falls back on.
    private func dark(hue: Double, chroma: Double, fallback: ColorFamily) -> AppearanceObservation {
        AppearanceObservation(family: .black, confidence: 0.9, whiteFraction: 0.1, hueSpread: 10,
                              meanRGB: nil, relativeChroma: chroma, relativeValue: 0.4,
                              fallbackFamily: fallback, fallbackConfidence: 0.6, hue: hue)
    }

    private func eight() -> AppearanceObservation {
        AppearanceObservation(family: .black, confidence: 0.9, whiteFraction: 0.1, hueSpread: nil,
                              meanRGB: nil, relativeChroma: 0.02, relativeValue: 0.27, hue: 20)
    }

    private func run(hues: [Double], chroma: Double, fallback: ColorFamily) -> BallIdentity {
        var identity = BallIdentity()
        for hue in hues {
            identity.observe([eightID: eight(), darkID: dark(hue: hue, chroma: chroma, fallback: fallback)])
        }
        return identity
    }

    @Test("A near-neutral dark ball with a scattered hue is left unnamed, not called maroon")
    func scatteredHueIsNotAName() {
        // Dark purple balls: chroma 0.05, hue anywhere from 290 to 46
        // degrees, read as maroon in every frame before.
        let hues = (0..<20).map { Double(($0 * 37) % 120) - 70 }
        let identity = run(hues: hues, chroma: 0.05, fallback: .maroon)
        #expect(identity.kind(for: eightID) == .eight)
        #expect(identity.family(for: darkID) == nil)
        #expect(identity.kind(for: darkID) == .unknown)
    }

    @Test("A near-neutral dark ball with a steady hue is still named by it")
    func steadyHueIsAName() {
        let hues = (0..<20).map { 139 + Double($0 % 3) }
        let identity = run(hues: hues, chroma: 0.06, fallback: .green)
        #expect(identity.family(for: darkID)?.family == .green)
    }

    @Test("Too few looks cannot show a steady hue: a name does not flash up for a frame and go")
    func fewLooksAreNotSteady() {
        let identity = run(hues: Array(repeating: 139, count: 5), chroma: 0.06, fallback: .green)
        #expect(identity.family(for: darkID) == nil)
    }

    @Test("Above the chroma floor the hue is trusted whatever it does")
    func coloured() {
        // Dark green 0.09-0.14 and dark blue 0.09-0.17 measured, with
        // hue spread up to 8 degrees.
        let hues = (0..<20).map { 130 + Double(($0 * 7) % 9) }
        let identity = run(hues: hues, chroma: 0.12, fallback: .green)
        #expect(identity.family(for: darkID)?.family == .green)
    }

    @Test("The one-eight rule is untouched: the neutral ball is the eight, the purple is not")
    func eightStillElected() {
        let identity = run(hues: (0..<20).map { Double(($0 * 37) % 120) - 70 }, chroma: 0.05, fallback: .maroon)
        #expect(identity.eightHolder == eightID)
    }
}

@Suite("Names hold still")
struct NameHoldTests {
    private func look(_ family: ColorFamily) -> AppearanceObservation {
        AppearanceObservation(family: family, confidence: 0.8, whiteFraction: 0)
    }

    private func run(margin: Double, challengerLooks: Int) -> ColorFamily? {
        var identity = BallIdentity(config: .init(switchShareMargin: margin))
        let id = BallID(1)
        for _ in 0..<8 { identity.observe(look(.red), for: id) }
        for _ in 0..<challengerLooks { identity.observe(look(.maroon), for: id) }
        return identity.family(for: id)?.family
    }

    @Test("A challenger that only just leads the vote needs one look more before it renames the ball")
    func marginDelaysTheSwitch() {
        // Eight red looks, then maroon: it first leads at 9 looks (0.53 to
        // 0.47) but leads by the 0.10 margin only from its tenth. Five
        // leading looks rename: at 13 without the margin, 14 with it.
        #expect(run(margin: 0, challengerLooks: 13) == .maroon)
        #expect(run(margin: 0.10, challengerLooks: 13) == .red)
        #expect(run(margin: 0.10, challengerLooks: 14) == .maroon)
    }

    @Test("A dead heat that lasts for ever never renames the ball")
    func deadHeatNeverFlips() {
        var identity = BallIdentity()
        let id = BallID(1)
        for _ in 0..<5 { identity.observe(look(.orange), for: id) }
        for _ in 0..<60 {
            identity.observe(look(.maroon), for: id)
            identity.observe(look(.orange), for: id)
        }
        #expect(identity.family(for: id)?.family == .orange)
    }

    @Test("The first name is still immediate")
    func firstNameIsNotHeldBack() {
        var identity = BallIdentity()
        let id = BallID(1)
        for _ in 0..<5 { identity.observe(look(.maroon), for: id) }
        #expect(identity.family(for: id)?.family == .maroon)
    }
}

@Suite("Naming on the 15-ball layout, end to end")
struct LayoutNamingTests {
    /// Per-ball statistics as measured (medians): hue, relative chroma,
    /// relative value, hue spread. Solids 1-7, stripes 9-15.
    private let balls: [(id: Int, hue: Double, chroma: Double, value: Double, spread: Double,
                         family: ColorFamily, group: BallGrouping?)] = [
        (1, 38.7, 0.80, 1.01, 2.2, .yellow, nil),
        (3, 358.4, 0.52, 0.91, 6.4, .red, .solid),
        (5, 16.1, 0.69, 0.98, 3.7, .orange, nil),
        (7, 11.2, 0.23, 0.54, 24.3, .maroon, nil),
        (9, 38.3, 0.63, 0.86, 4.5, .yellow, nil),
        (11, 3.8, 0.53, 0.86, 17.9, .red, .stripe),
        (13, 21.3, 0.68, 0.97, 7.4, .orange, nil),
        (15, 15.2, 0.28, 0.67, 22.0, .maroon, .stripe)
    ]

    @Test("Every warm ball gets its own colour, none gets a wrong group")
    func warmBallsAreNamedRight() throws {
        var identity = BallIdentity()
        for _ in 0..<10 {
            var frame: [BallID: AppearanceObservation] = [:]
            for ball in balls {
                frame[BallID(ball.id)] = try #require(Synthetic.look(
                    hue: ball.hue, chroma: ball.chroma, value: ball.value, spread: ball.spread))
            }
            identity.observe(frame)
        }
        for ball in balls {
            let id = BallID(ball.id)
            #expect(identity.family(for: id)?.family == ball.family, "ball \(ball.id)")
            #expect(identity.group(for: id) == ball.group, "ball \(ball.id)")
        }
        // The two that used to be called orange, and the card word for them.
        #expect(identity.family(for: BallID(7))?.family == .maroon)
        #expect(identity.family(for: BallID(15))?.family == .maroon)
    }
}
