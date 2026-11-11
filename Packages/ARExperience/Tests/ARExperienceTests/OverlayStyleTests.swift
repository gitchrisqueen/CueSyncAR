import CueSyncCore
import Foundation
import Testing
import TableSpace
@testable import ARExperience

@Suite("Overlay style: the suggested shot is the hero")
struct OverlayStyleTests {

    @Test("Only a solid plan strip is the hero; dashed is always secondary")
    func tiers() {
        #expect(OverlayStyle.tier(role: .plan, dashed: false) == .hero)
        #expect(OverlayStyle.tier(role: .live, dashed: false) == .aim)
        #expect(OverlayStyle.tier(role: .plan, dashed: true) == .secondary)
        #expect(OverlayStyle.tier(role: .live, dashed: true) == .secondary)
    }

    @Test("The hero is thicker, more opaque and floats higher than anything else")
    func heroDominates() {
        let hero = OverlayStyle.Tier.hero
        for other in [OverlayStyle.Tier.aim, .secondary] {
            #expect(OverlayStyle.width(hero) >= 2.5 * OverlayStyle.width(other), "\(other)")
            #expect(OverlayStyle.opacity(hero) > OverlayStyle.opacity(other), "\(other)")
            #expect(OverlayStyle.lift(hero) > OverlayStyle.lift(other), "\(other)")
        }
        #expect(OverlayStyle.opacity(hero) == 1)
    }

    @Test("Aim outranks the ricochet, and both are dimmer than the hero")
    func orderingIsStrict() {
        #expect(OverlayStyle.width(.aim) > OverlayStyle.width(.secondary))
        #expect(OverlayStyle.opacity(.aim) > OverlayStyle.opacity(.secondary))
        #expect(OverlayStyle.opacity(.aim) < 0.7)
    }

    @Test("The hero is far thicker than the old 4 mm, 40 % plan line")
    func notTheOldPlanLine() {
        #expect(OverlayStyle.width(.hero) >= 0.012)
        #expect(OverlayStyle.opacity(.hero) >= 0.9)
    }

    @Test("Every width is a visible line and narrower than a ball")
    func widthsAreSane() {
        for tier in OverlayStyle.Tier.allCases {
            #expect(OverlayStyle.width(tier) >= 0.003)
            #expect(OverlayStyle.width(tier) < Ball.standardRadius * 2)
        }
    }

    @Test("Layer opacity clamps: a degraded table fades, never vanishes")
    func layerOpacity() {
        #expect(OverlayStyle.layerOpacity(confidence: 1) == 1)
        #expect(OverlayStyle.layerOpacity(confidence: 0.4) == 0.4)
        #expect(OverlayStyle.layerOpacity(confidence: 0) == 0.25)
        #expect(OverlayStyle.layerOpacity(confidence: 7) == 1)
    }

    @Test("The shot colour is not the aim colour")
    func oneColourPerMeaning() {
        let aim: UInt32 = 0xF5A623
        #expect(OverlayStyle.shotColor != aim)
        #expect(OverlayStyle.ballRingColor != aim)
    }
}
