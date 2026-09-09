import CueSyncCore
import Foundation
import Testing
@testable import PerceptionKit

@Suite("BallIdentity")
struct BallIdentityTests {
    private let ball = BallID(7)

    private func observation(_ family: ColorFamily, confidence: Double = 0.8,
                             white: Double = 0.05) -> AppearanceObservation {
        AppearanceObservation(family: family, confidence: confidence, whiteFraction: white)
    }

    private func identity(_ observations: [AppearanceObservation],
                          config: BallIdentity.Config = .default) -> BallIdentity {
        var identity = BallIdentity(config: config)
        for observation in observations { identity.observe(observation, for: ball) }
        return identity
    }

    // MARK: - Naming

    @Test("A consistent blue solid becomes the 2-ball")
    func namesASolid() {
        let identity = identity(Array(repeating: observation(.blue, white: 0.04), count: 10))
        #expect(identity.group(for: ball) == .solid)
        #expect(identity.kind(for: ball) == .solid(2))
    }

    /// The rule the whole aggregator exists for. A stripe's band is
    /// randomly oriented and the lower half of every ball is in shadow,
    /// so most looks at a stripe see no white at all — measured on the
    /// owner's table with both stripes scoring BELOW both solids on mean
    /// white fraction. One clear look is proof; the mean destroys it.
    @Test("One clear look at a band makes a stripe, however many looks missed it")
    func peakWhiteDecidesTheGroup() {
        var looks = Array(repeating: observation(.blue, white: 0.02), count: 19)
        looks.append(observation(.blue, white: 0.55))
        let identity = identity(looks)
        #expect(identity.group(for: ball) == .stripe)
        #expect(identity.kind(for: ball) == .stripe(10))
        // The mean of those looks is 0.045 — a solid, by any averaging rule.
        let mean = looks.map(\.whiteFraction).reduce(0, +) / Double(looks.count)
        #expect(mean < BallIdentity.Config.default.stripeWhiteFraction)
    }

    @Test("Never seeing a band is not proof of a solid, but it is what we go with")
    func absenceOfEvidenceIsReported() {
        let identity = identity(Array(repeating: observation(.red, white: 0.01), count: 12))
        #expect(identity.group(for: ball) == .solid)
        #expect(identity.kind(for: ball) == .solid(3))
        // And the record says exactly how strong that evidence was.
        #expect(identity.record(for: ball)?.peakWhiteFraction ?? 1 < 0.05)
    }

    @Test("The eight and the cue ball skip the group question entirely")
    func neutralsAreTheirOwnGroup() {
        var identity = BallIdentity()
        for _ in 0..<10 {
            identity.observe(observation(.black, confidence: 0.9, white: 0.13), for: BallID(1))
            identity.observe(observation(.white, confidence: 0.9, white: 0.91), for: BallID(2))
        }
        #expect(identity.group(for: BallID(1)) == .eight)
        #expect(identity.kind(for: BallID(1)) == .eight)
        #expect(identity.group(for: BallID(2)) == .cue)
        #expect(identity.kind(for: BallID(2)) == .cue)
    }

    // MARK: - Refusing to guess

    @Test("Too few looks yields unknown, not a first impression")
    func waitsForEvidence() {
        let identity = identity(Array(repeating: observation(.blue), count: 3))
        #expect(identity.family(for: ball) == nil)
        #expect(identity.group(for: ball) == nil)
        #expect(identity.kind(for: ball) == .unknown)
    }

    /// Colour is decided by vote because every look sees the same colour
    /// and disagreement there is noise — but a ball the classifier cannot
    /// settle on stays unnamed rather than taking a plurality.
    @Test("A colour nobody agrees on stays unnamed")
    func disagreementStaysUnknown() {
        let identity = identity([
            observation(.red, confidence: 0.3), observation(.orange, confidence: 0.3),
            observation(.maroon, confidence: 0.25), observation(.orange, confidence: 0.28),
            observation(.red, confidence: 0.31), observation(.maroon, confidence: 0.3)
        ])
        let colour = identity.family(for: ball)
        #expect(colour != nil, "there is still a leader")
        #expect((colour?.confidence ?? 1) < BallIdentity.Config.default.namingConfidence)
        #expect(identity.kind(for: ball) == .unknown, "a leader is not a decision")
    }

    @Test("A tentative naming is flagged so the HUD can show it dimly")
    func tentativeIsFlagged() {
        let shaky = identity([
            observation(.blue, confidence: 0.55), observation(.blue, confidence: 0.5),
            observation(.purple, confidence: 0.45), observation(.blue, confidence: 0.5),
            observation(.purple, confidence: 0.4), observation(.blue, confidence: 0.6)
        ])
        #expect(shaky.isTentative(for: ball))
        let certain = identity(Array(repeating: observation(.blue, confidence: 0.9), count: 10))
        #expect(!certain.isTentative(for: ball))
    }

    // MARK: - The player's correction

    @Test("A tap wins over every observation and never decays")
    func overrideWins() {
        var identity = identity(Array(repeating: observation(.blue), count: 20))
        #expect(identity.kind(for: ball) == .solid(2))
        identity.setOverride(.stripe(11), for: ball)
        #expect(identity.kind(for: ball) == .stripe(11))
        #expect(!identity.isTentative(for: ball), "a correction is not a guess")
        for _ in 0..<40 { identity.observe(observation(.blue), for: ball) }
        #expect(identity.kind(for: ball) == .stripe(11), "observations cannot vote it away")
        identity.setOverride(nil, for: ball)
        #expect(identity.kind(for: ball) == .solid(2))
    }

    @Test("A correction can be made before anything has been observed")
    func overrideWithoutObservations() {
        var identity = BallIdentity()
        identity.setOverride(.eight, for: ball)
        #expect(identity.kind(for: ball) == .eight)
    }

    // MARK: - Track lifetime

    @Test("Retiring a track forgets it, so a reused id inherits no colour")
    func retainDropsDeadTracks() {
        var identity = BallIdentity()
        for _ in 0..<10 {
            identity.observe(observation(.blue), for: BallID(1))
            identity.observe(observation(.red), for: BallID(2))
        }
        #expect(identity.trackedCount == 2)
        identity.retain([BallID(1)])
        #expect(identity.trackedCount == 1)
        #expect(identity.kind(for: BallID(2)) == .unknown)
        #expect(identity.kind(for: BallID(1)) == .solid(2))
    }

    @Test("The window is bounded, and the newest looks are the ones kept")
    func windowIsBounded() {
        var identity = BallIdentity(config: .init(window: 6, minimumObservations: 3))
        for _ in 0..<6 { identity.observe(observation(.red), for: ball) }
        for _ in 0..<6 { identity.observe(observation(.green), for: ball) }
        #expect(identity.record(for: ball)?.observations.count == 6)
        #expect(identity.family(for: ball)?.family == .green)
    }

    @Test("Clearing forgets everything, corrections included")
    func clearResets() {
        var identity = identity(Array(repeating: observation(.blue), count: 10))
        identity.setOverride(.eight, for: ball)
        identity.clear()
        #expect(identity.trackedCount == 0)
        #expect(identity.kind(for: ball) == .unknown)
    }

    @Test("Stripe numbers are their solid plus eight")
    func stripeNumbering() {
        for (family, solid) in [(ColorFamily.yellow, 1), (.blue, 2), (.red, 3),
                                (.purple, 4), (.orange, 5), (.green, 6), (.maroon, 7)] {
            let identity = identity(Array(repeating:
                observation(family, confidence: 0.9, white: 0.5), count: 10))
            #expect(identity.kind(for: ball) == .stripe(solid + 8))
        }
    }
}
