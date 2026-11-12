//
//  BallEightUniquenessTests.swift
//  PerceptionKitTests
//
//  Only one ball is the eight. Measured on a full 16-ball layout on black
//  cloth in a dim room, five balls (dark blue, purple, maroon, dark green
//  and the real 8) all read as dark and neutral and all five were named
//  the eight. Everything here is synthetic numbers; no image is used.
//

import CueSyncCore
import Foundation
import Testing

@testable import PerceptionKit

private let eight = BallID(8)
private let darkBlue = BallID(2)
private let purple = BallID(4)
private let maroon = BallID(7)
private let darkGreen = BallID(6)

/// One look at a dark ball: black by the single-frame rule, with the
/// chromatic reading the classifier attaches to it.
private func dark(chroma: Double, value: Double = 0.15, hue: ColorFamily? = nil,
                  hueConfidence: Double = 0.8) -> AppearanceObservation {
    AppearanceObservation(family: .black, confidence: 0.9, whiteFraction: 0.05,
                          meanRGB: Vec3(value * 0.5, value * 0.5, value * 0.5),
                          relativeChroma: chroma, relativeValue: value,
                          fallbackFamily: hue, fallbackConfidence: hue == nil ? 0 : hueConfidence)
}

private func look(_ family: ColorFamily, _ confidence: Double = 0.9) -> AppearanceObservation {
    AppearanceObservation(family: family, confidence: confidence, whiteFraction: 0.05)
}

private func table(_ ids: [BallID]) -> TableState {
    TableState(table: Table(size: .eightFoot),
               balls: ids.enumerated().map {
                   Ball(id: $1, kind: .unknown, position: Vec2(0.2 * Double($0), 0.3))
               })
}

/// The full-table failure: the real 8 is the most neutral of five dark balls.
private let fullTableFrame: [BallID: AppearanceObservation] = [
    eight: dark(chroma: 0.03, value: 0.12),
    darkBlue: dark(chroma: 0.12, value: 0.16, hue: .blue),
    purple: dark(chroma: 0.13, value: 0.15, hue: .purple),
    maroon: dark(chroma: 0.14, value: 0.20, hue: .maroon),
    darkGreen: dark(chroma: 0.11, value: 0.14, hue: .green)
]

@Suite("Ball identity: only one ball is the eight")
struct BallEightUniquenessTests {
    private func identity(frames: Int = 6, _ frame: [BallID: AppearanceObservation] = fullTableFrame)
        -> BallIdentity {
        var identity = BallIdentity()
        for _ in 0..<frames { identity.observe(frame) }
        return identity
    }

    @Test("Five dark balls, one near-black: exactly one eight, and it is the near-black one")
    func fiveDarkBallsOneEight() {
        let identity = identity()
        let named = identity.apply(to: table([eight, darkBlue, purple, maroon, darkGreen]))
        #expect(named.balls.filter { $0.kind == .eight }.map(\.id) == [eight])
        #expect(identity.eightHolder == eight)
        #expect(identity.family(for: eight)?.family == .black)
    }

    @Test("The four that lose fall back to their hue class, and claim no group")
    func losersKeepTheirHue() {
        let identity = identity()
        #expect(identity.family(for: darkBlue)?.family == .blue)
        #expect(identity.family(for: purple)?.family == .purple)
        #expect(identity.family(for: maroon)?.family == .maroon)
        #expect(identity.family(for: darkGreen)?.family == .green)
        for id in [darkBlue, purple, maroon, darkGreen] {
            // No validated stripe signal on dark balls: unknown, not "solid".
            #expect(identity.group(for: id) == nil)
            #expect(identity.kind(for: id) == .unknown)
        }
    }

    @Test("No near-black ball on the table: nobody is the eight")
    func noEightWhenNothingIsNeutral() {
        var frame = fullTableFrame
        frame[eight] = nil
        let identity = identity(frame)
        let named = identity.apply(to: table([darkBlue, purple, maroon, darkGreen]))
        #expect(!named.balls.contains { $0.kind == .eight })
        #expect(identity.eightHolder == nil)
        // They are still named by hue, which is all the HUD needs.
        #expect(identity.family(for: darkBlue)?.family == .blue)
        #expect(identity.family(for: darkGreen)?.family == .green)
    }

    @Test("The real 8 hidden for a few frames: no dark neighbour takes the name")
    func occlusionDoesNotHandOverTheName() {
        var identity = identity(frames: 10)
        var others = fullTableFrame
        others[eight] = nil
        // A neighbour that is nearly neutral itself, so it would win an
        // election the eight was not in.
        others[purple] = dark(chroma: 0.08, value: 0.15, hue: .purple)
        for _ in 0..<12 { identity.observe(others) }
        #expect(identity.eightHolder == eight)
        let named = identity.apply(to: table([eight, darkBlue, purple, maroon, darkGreen]))
        #expect(named.balls.filter { $0.kind == .eight }.map(\.id) == [eight])
    }

    @Test("A wrong early pick is repaired by a clearly more neutral ball, not by a marginal one")
    func challengerMustBeClearlyBetter() {
        var identity = BallIdentity()
        // The blue ball is seen first and, alone, is the only candidate.
        for _ in 0..<5 { identity.observe([darkBlue: dark(chroma: 0.09, hue: .blue)]) }
        #expect(identity.eightHolder == darkBlue)
        // A ball a hair more neutral (0.09 vs 0.08) does not displace it.
        for _ in 0..<12 {
            identity.observe([darkBlue: dark(chroma: 0.09, hue: .blue), eight: dark(chroma: 0.08)])
        }
        #expect(identity.eightHolder == darkBlue)
        // A clearly more neutral one does, after the hold. The ranking is on
        // the mean over the kept looks, so the new ball's average takes a
        // while to cross the line: that slowness is the point.
        for _ in 0..<30 {
            identity.observe([darkBlue: dark(chroma: 0.09, hue: .blue), eight: dark(chroma: 0.02)])
        }
        #expect(identity.eightHolder == eight)
    }

    @Test("Ties go to the darker ball, then the lower id")
    func deterministicTieBreak() {
        var identity = BallIdentity()
        for _ in 0..<6 {
            identity.observe([BallID(11): dark(chroma: 0.04, value: 0.20),
                              BallID(3): dark(chroma: 0.04, value: 0.20),
                              BallID(9): dark(chroma: 0.04, value: 0.12)])
        }
        #expect(identity.eightHolder == BallID(9), "darkest of the equally neutral")
        var equal = BallIdentity()
        for _ in 0..<6 {
            equal.observe([BallID(11): dark(chroma: 0.04), BallID(3): dark(chroma: 0.04)])
        }
        #expect(equal.eightHolder == BallID(3), "lower id when nothing else separates them")
    }

    @Test("Jitter between two near-equal balls does not flip the title")
    func jitterDoesNotFlip() {
        var identity = BallIdentity()
        var holders = Set<BallID?>()
        for frame in 0..<40 {
            let wobble = frame.isMultiple(of: 2) ? 0.01 : -0.01
            identity.observe([BallID(3): dark(chroma: 0.05 + wobble),
                              BallID(8): dark(chroma: 0.05 - wobble)])
            if frame >= 5 { holders.insert(identity.eightHolder) }
        }
        #expect(holders.count == 1)
    }

    @Test("A name held over the five-look hold does not flicker on a short glitch")
    func fallbackNameIsHeld() {
        func names(switchObservations: Int) -> [ColorFamily?] {
            var identity = BallIdentity(config: .init(switchObservations: switchObservations))
            var seen: [ColorFamily?] = []
            let sequence = Array(repeating: ColorFamily.blue, count: 6)
                + Array(repeating: ColorFamily.purple, count: 14)
            for hue in sequence {
                identity.observe([eight: dark(chroma: 0.02),
                                  darkBlue: dark(chroma: 0.12, hue: hue)])
                seen.append(identity.family(for: darkBlue)?.family)
            }
            return seen
        }
        let held = names(switchObservations: 5)
        let unguarded = names(switchObservations: 1)
        // Nothing is named before five looks; after that it is blue.
        #expect(held[4..<6].allSatisfy { $0 == .blue })
        let heldFlip = held.firstIndex { $0 == .purple }
        let unguardedFlip = unguarded.firstIndex { $0 == .purple }
        #expect(heldFlip != nil && unguardedFlip != nil)
        #expect((heldFlip ?? 0) - (unguardedFlip ?? 0) >= 4, "the hold delays the rename by the hold length")
    }

    @Test("The player's tap on the eight pins it, and no other ball may be the eight")
    func playerCorrectionWins() {
        var identity = identity()
        identity.setOverride(.eight, for: darkGreen)
        #expect(identity.eightHolder == darkGreen)
        var state = table([eight, darkBlue, darkGreen])
        state.balls[0].kind = .eight  // a stray eight from some other source
        let named = identity.apply(to: state)
        #expect(named.balls.filter { $0.kind == .eight }.map(\.id) == [darkGreen])
    }

    @Test("A stray detector eight is demoted when the identity names a different ball")
    func strayEightIsDemoted() {
        let identity = identity()
        var state = table([eight, darkBlue])
        state.balls[1].kind = .eight
        let named = identity.apply(to: state)
        #expect(named.balls.filter { $0.kind == .eight }.map(\.id) == [eight])
    }
}

/// The old failure case, end to end through the real classifier: patches
/// measured against a bright cue ball in a dim room.
@Suite("Ball identity: dark balls through the classifier")
struct BallEightEndToEndTests {
    private let cue = BallPatch(meanRGB: Vec3(0.70, 0.68, 0.64), whiteFraction: 0.6,
                                chromaFraction: 0.05, sampleCount: 300)
    private func patch(_ rgb: Vec3) -> BallPatch {
        BallPatch(meanRGB: rgb, whiteFraction: 0.04, chromaFraction: 0.5, sampleCount: 300)
    }

    private func frame(_ patches: [BallID: Vec3]) throws -> [BallID: AppearanceObservation] {
        let reference = WhiteReference(meanRGB: cue.meanRGB)
        return try patches.mapValues {
            try #require(BallAppearance.classify(patch($0), reference: reference))
        }
    }

    private let darkSet: [BallID: Vec3] = [
        eight: Vec3(0.050, 0.050, 0.055),
        darkBlue: Vec3(0.040, 0.060, 0.100),
        purple: Vec3(0.070, 0.040, 0.090),
        maroon: Vec3(0.120, 0.040, 0.050),
        darkGreen: Vec3(0.030, 0.070, 0.040)
    ]

    @Test("The classifier reads all five as black; the identity still elects one eight")
    func classifierThenElection() throws {
        let observations = try frame(darkSet)
        for (id, observation) in observations {
            #expect(observation.family == .black, "ball \(id.rawValue) is dark and neutral to the single-frame rule")
            #expect(id == eight || observation.fallbackFamily != nil)
        }
        var identity = BallIdentity()
        for _ in 0..<6 { identity.observe(observations) }
        let named = identity.apply(to: TableState(
            table: Table(size: .eightFoot),
            balls: darkSet.keys.sorted { $0.rawValue < $1.rawValue }.map {
                Ball(id: $0, kind: .unknown, position: Vec2(0.1 * Double($0.rawValue), 0.2))
            }))
        #expect(named.balls.filter { $0.kind == .eight }.map(\.id) == [eight])
        #expect(identity.family(for: darkBlue)?.family == .blue)
        #expect(identity.family(for: purple)?.family == .purple)
        #expect(identity.family(for: maroon)?.family == .maroon)
        #expect(identity.family(for: darkGreen)?.family == .green)
    }

    @Test("Without the eight on the table the same four are named by hue and none is the eight")
    func classifierWithoutTheEight() throws {
        // Dark enough for the single-frame rule to call them black, but
        // coloured enough (relative chroma 0.10-0.15) to be nobody's eight.
        let set: [BallID: Vec3] = [
            darkBlue: Vec3(0.04, 0.06, 0.13),
            purple: Vec3(0.08, 0.04, 0.12),
            maroon: Vec3(0.14, 0.04, 0.05),
            darkGreen: Vec3(0.02, 0.09, 0.04)
        ]
        let observations = try frame(set)
        for (id, observation) in observations {
            #expect(observation.family == .black, "ball \(id.rawValue)")
            #expect((observation.relativeChroma ?? 0) > BallIdentity.Config.default.eightChromaCeiling)
        }
        var identity = BallIdentity()
        for _ in 0..<6 { identity.observe(observations) }
        #expect(identity.eightHolder == nil)
        #expect(identity.family(for: darkBlue)?.family == .blue)
        #expect(identity.family(for: purple)?.family == .purple)
        #expect(identity.family(for: maroon)?.family == .maroon)
        #expect(identity.family(for: darkGreen)?.family == .green)
    }

    @Test("The old blue-versus-8 case: a navy ball still reads Blue, the near-black ball is the 8")
    func navyIsStillBlue() throws {
        let navy = BallID(2)
        let observations = try frame([navy: Vec3(0.10, 0.20, 0.30), eight: Vec3(0.17, 0.15, 0.18)])
        #expect(observations[navy]?.family == .blue)
        var identity = BallIdentity()
        for _ in 0..<6 { identity.observe(observations) }
        // The colour word BallNaming turns into "Blue ball".
        #expect(identity.family(for: navy)?.family.rawValue == "blue")
        #expect(identity.kind(for: eight) == .eight)
        #expect(identity.eightHolder == eight)
    }

    @Test("Looks carry the numbers the mirror publishes")
    func observationsCarryMeasurements() throws {
        let observation = try #require(try frame([eight: darkSet[eight]!])[eight])
        #expect(observation.meanRGB == darkSet[eight])
        #expect((observation.relativeChroma ?? 1) < 0.05)
        var identity = BallIdentity()
        for _ in 0..<5 { identity.observe(observation, for: eight) }
        let record = try #require(identity.record(for: eight))
        let rgb = try #require(record.meanRGB)
        #expect(abs(rgb.x - 0.05) < 1e-9)
        let expectedLuma: Double = 0.299 * 0.05 + 0.587 * 0.05 + 0.114 * 0.055
        let luma: Double = record.meanLuma ?? 0
        #expect(abs(luma - expectedLuma) < 1e-9)
    }
}
