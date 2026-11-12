//
//  ShotRankingAuditTests.swift
//  CoachKitTests
//
//  Checks ShotRanking.rate against an independent derivation of the aim
//  tolerance (docs/research/2026-11-12-ranking-audit.md), and states the
//  shape of the model as property tests: probability is a probability, and
//  a harder shot never reads easier.
//
//  Derivation. R = ball radius, t = cut angle, D = object-ball travel to the
//  pocket, d = cue travel to the ghost ball, W = pocket mouth width
//  (WPA: corner 114 mm, side 127 mm), a = angle the object ball arrives off
//  the pocket's axis.
//    m     = max(0, (W cos a - 2R) / 2)    margin before a jaw point
//    dpsi  = atan(m / D)                   object-line tolerance
//    dmax  = dpsi * 2R cos t / d           aim tolerance at the cue ball
//    sigma = 0.005 * (1 + (1 - cos t))     the model's aim error
//    P     = erf(dmax / (sigma sqrt 2))
//

import CueSyncCore
import Foundation
import Testing
@testable import CoachKit

/// One shot built from the quantities the derivation uses, so the expected
/// value is computed from the inputs and never read back from the code.
struct AuditShot {
    var name: String
    var pocket: PocketID
    /// Object ball's travel to the pocket centre, metres.
    var objectTravel: Double
    /// How far the object ball's line arrives off the pocket's axis.
    var offAxisDegrees: Double
    var cutDegrees: Double
    /// Cue ball's travel to the ghost ball, metres.
    var cueTravel: Double

    var isCorner: Bool { pocket != .sideTop && pocket != .sideBottom }
}

enum AuditReference {
    static let radius = Ball.standardRadius
    static let cornerMouth = 0.114
    static let sideMouth = 0.127
    static let aimSigma = 0.005
    static let cutPenalty = 1.0

    static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
    static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }

    /// Table the audit shots sit on: the 2.256 x 1.079 m table the app was
    /// reading when the 93-94 % symptom was seen.
    static let table = Table(size: .custom(width: 2.255925, height: 1.079337))

    /// Aim tolerance at the cue ball, radians.
    static func tolerance(_ shot: AuditShot) -> Double {
        let width = shot.isCorner ? cornerMouth : sideMouth
        let margin = max(0, (width * cos(radians(shot.offAxisDegrees)) - 2 * radius) / 2)
        let objectLine = atan(margin / shot.objectTravel)
        return objectLine * 2 * radius * cos(radians(shot.cutDegrees)) / shot.cueTravel
    }

    /// `contactSigma` is a distance-independent contact-point error in metres
    /// (proposal only: the model does not have it). A lateral error e at
    /// contact is the same as an aim error e/d at the cue ball.
    static func probability(_ shot: AuditShot, contactSigma: Double = 0) -> Double {
        let cosCut = cos(radians(shot.cutDegrees))
        let aim = aimSigma * (1 + cutPenalty * (1 - cosCut))
        let sigma = (aim * aim + pow(contactSigma / shot.cueTravel, 2)).squareRoot()
        let tolerance = tolerance(shot)
        guard tolerance > 0 else { return 0 }
        return erf(tolerance / (sigma * 2.0.squareRoot()))
    }

    /// The pocket's outward axis, written out here and not taken from the
    /// code under test.
    static func axis(of pocket: Pocket) -> Vec2 {
        let sx: Double = pocket.position.x > 0 ? 1 : -1
        let sy: Double = pocket.position.y > 0 ? 1 : -1
        if abs(pocket.position.x) < 1e-9 { return Vec2(0, sy) }
        return Vec2(sx, sy).normalized
    }

    /// The table state for a shot, or nil when the ball would sit off the
    /// cloth.
    static func state(_ shot: AuditShot, table: Table = AuditReference.table) -> TableState? {
        guard let pocket = table.pockets.first(where: { $0.id == shot.pocket }) else { return nil }
        let into = axis(of: pocket).rotated(by: -radians(shot.offAxisDegrees))
        let ball = pocket.position - into * shot.objectTravel
        guard table.contains(ball, ballRadius: radius) else { return nil }
        let ghost = ball - into * (2 * radius)
        let cue = ghost - into.rotated(by: radians(shot.cutDegrees)) * shot.cueTravel
        return TableState(table: table, balls: [
            Ball(id: BallID(0), kind: .cue, position: cue),
            Ball(id: BallID(5), kind: .solid(5), position: ball)
        ], timestamp: 0)
    }

    static func rate(_ shot: AuditShot, table: Table = AuditReference.table,
                     config: ShotRanking.Config = .intermediate) -> ShotRating? {
        guard let state = state(shot, table: table),
              let cue = state.cueBall,
              let ball = state.ball(BallID(5)),
              let pocket = state.table.pockets.first(where: { $0.id == shot.pocket })
        else { return nil }
        return ShotRanking.rate(cueBall: cue, ball: ball, pocket: pocket,
                                state: state, config: config)
    }
}

@Suite("ShotRanking audit")
struct ShotRankingAuditTests {
    /// The four shots from the on-table symptom, then the shots that bracket
    /// them. The reported shots give cut, cue travel and object travel (the
    /// fourth gave no object travel: 0.64 m is the value that reproduces the
    /// 94 % the app showed). All are taken straight into the pocket's axis
    /// unless the name says otherwise.
    static let shots: [AuditShot] = [
        AuditShot(name: "reported 1 corner", pocket: .cornerTopRight, objectTravel: 0.43,
                  offAxisDegrees: 0, cutDegrees: 16.2, cueTravel: 0.60),
        AuditShot(name: "reported 2 corner", pocket: .cornerTopRight, objectTravel: 0.46,
                  offAxisDegrees: 0, cutDegrees: 13.1, cueTravel: 0.58),
        AuditShot(name: "reported 3 side", pocket: .sideTop, objectTravel: 0.27,
                  offAxisDegrees: 0, cutDegrees: 47.4, cueTravel: 0.36),
        AuditShot(name: "reported 4 corner", pocket: .cornerTopRight, objectTravel: 0.64,
                  offAxisDegrees: 0, cutDegrees: 23.6, cueTravel: 0.37),
        AuditShot(name: "dead straight, short", pocket: .cornerTopRight, objectTravel: 0.30,
                  offAxisDegrees: 0, cutDegrees: 0, cueTravel: 0.30),
        AuditShot(name: "long straight", pocket: .cornerTopRight, objectTravel: 1.50,
                  offAxisDegrees: 10, cutDegrees: 0, cueTravel: 0.80),
        AuditShot(name: "thin cut", pocket: .cornerTopRight, objectTravel: 0.50,
                  offAxisDegrees: 0, cutDegrees: 70, cueTravel: 0.50),
        AuditShot(name: "side, 40 deg off axis", pocket: .sideTop, objectTravel: 0.50,
                  offAxisDegrees: 40, cutDegrees: 15, cueTravel: 0.50),
        AuditShot(name: "side, on axis", pocket: .sideTop, objectTravel: 0.50,
                  offAxisDegrees: 0, cutDegrees: 15, cueTravel: 0.50),
        AuditShot(name: "corner, 40 deg off axis", pocket: .cornerTopRight, objectTravel: 0.50,
                  offAxisDegrees: 40, cutDegrees: 15, cueTravel: 0.50)
    ]

    // MARK: Reference agreement

    @Test func codeAgreesWithTheDerivationOnEveryReferenceShot() throws {
        for shot in Self.shots {
            let rating = try #require(AuditReference.rate(shot), "\(shot.name): cannot be built")
            #expect(rating.blocker == nil, "\(shot.name): blocked by \(String(describing: rating.blocker))")
            let expected = AuditReference.tolerance(shot)
            #expect(abs(rating.aimTolerance - expected) < 1e-9,
                    "\(shot.name): tolerance \(rating.aimTolerance) rad, derivation \(expected) rad")
            let expectedProbability = AuditReference.probability(shot)
            #expect(abs(rating.probability - expectedProbability) < 1e-9,
                    "\(shot.name): \(rating.probability), derivation \(expectedProbability)")
            // The inputs really are what the shot says they are.
            #expect(abs(rating.cutAngleDegrees - shot.cutDegrees) < 1e-6, "\(shot.name): cut")
            #expect(abs(rating.cueTravel - shot.cueTravel) < 1e-9, "\(shot.name): cue travel")
            #expect(abs(rating.objectTravel - shot.objectTravel) < 1e-9, "\(shot.name): object travel")
        }
    }

    /// `Pocket.captureRadius` is the solver's capture circle for a ball
    /// centre, tuned so a ball aimed at the corner enters it before the
    /// cushion line. It is not half a mouth width, so the margin must not
    /// move when it changes.
    @Test func aimToleranceDoesNotDependOnTheSolversCaptureRadius() throws {
        let wide = Table(size: AuditReference.table.size,
                         cornerCaptureRadius: 0.085, sideCaptureRadius: 0.068)
        for shot in Self.shots {
            let base = try #require(AuditReference.rate(shot))
            let changed = try #require(AuditReference.rate(shot, table: wide))
            #expect(base.aimTolerance == changed.aimTolerance,
                    "\(shot.name): tolerance follows the capture radius")
        }
    }

    /// Values before and after the fix, for the four on-table shots.
    /// Before: 94 / 94 / 92 / 94 % (aim tolerance 0.567 / 0.556 / 0.672 /
    /// 0.589 degrees). The corner margin was `captureRadius - R` = 46.4 mm
    /// where a 114 mm mouth leaves `(114 - 2R) / 2` = 28.4 mm; the side
    /// margin was 29.4 mm where a 127 mm mouth leaves 34.9 mm.
    /// After: 75 / 75 / 96 / 75 % (0.346 / 0.339 / 0.792 / 0.360 degrees).
    @Test func theFourReportedShotsReadWhatTheDerivationSays() throws {
        let reported = try Self.shots.prefix(4).map { try #require(AuditReference.rate($0)) }
        let percentages = reported.map(\.percentage)
        #expect(percentages == [75, 75, 96, 75], "got \(percentages)")
        let degrees = reported.map { AuditReference.degrees($0.aimTolerance) }
        for (got, want) in zip(degrees, [0.346, 0.339, 0.792, 0.360]) {
            #expect(abs(got - want) < 0.001, "tolerance \(got) deg, wanted \(want)")
        }
    }

    @Test func printAuditTable() throws {
        var lines = ["AUDIT shot | cut | cue m | obj m | code tol deg | ref tol deg | code % | ref % "
                     + "| ref % +1.5mm | +2mm | +3mm"]
        for shot in Self.shots {
            let rating = try #require(AuditReference.rate(shot))
            let refs = [1.5, 2, 3].map { AuditReference.probability(shot, contactSigma: $0 / 1000) }
            lines.append(String(
                format: "AUDIT %@ | %.1f | %.2f | %.2f | %.3f | %.3f | %.1f | %.1f | %.1f | %.1f | %.1f",
                shot.name, shot.cutDegrees, shot.cueTravel, shot.objectTravel,
                AuditReference.degrees(rating.aimTolerance),
                AuditReference.degrees(AuditReference.tolerance(shot)),
                rating.probability * 100, AuditReference.probability(shot) * 100,
                refs[0] * 100, refs[1] * 100, refs[2] * 100))
        }
        print(lines.joined(separator: "\n"))
    }
}

@Suite("ShotRanking audit properties")
struct ShotRankingAuditPropertyTests {
    /// Rail proximity is a deliberate step in the model, not a smooth
    /// quantity, so the monotonic properties are stated with it off.
    static let smooth = ShotRanking.Config(railTolerancePenalty: 1)

    static func random(_ rng: inout SplitMix64) -> AuditShot {
        AuditShot(name: "random",
                  pocket: rng.int(0...1) == 0 ? .cornerTopRight : .sideTop,
                  objectTravel: rng.uniform(0.12, 1.0),
                  offAxisDegrees: rng.uniform(0, 65),
                  cutDegrees: rng.uniform(0, 80),
                  cueTravel: rng.uniform(0.15, 1.5))
    }

    /// The probability of a shot, or nil when it cannot be built or is blocked.
    static func probability(_ shot: AuditShot) -> Double? {
        guard let rating = AuditReference.rate(shot, config: smooth), rating.blocker == nil
        else { return nil }
        return rating.probability
    }

    @Test func probabilityIsAlwaysWithinZeroAndOne() {
        var checked = 0
        for seed in UInt64(1)...600 {
            var rng = SplitMix64(seed: seed)
            let shot = Self.random(&rng)
            guard let rating = AuditReference.rate(shot) else { continue }
            #expect((0...1).contains(rating.probability), "seed \(seed): \(rating.probability)")
            #expect(rating.aimTolerance >= 0, "seed \(seed): negative tolerance")
            if rating.blocker != nil { #expect(rating.probability == 0, "seed \(seed)") }
            checked += 1
        }
        #expect(checked > 400, "too few shots built: \(checked)")
    }

    @Test func probabilityNeverRisesAsTheShotGetsHarder() {
        var compared = 0
        for seed in UInt64(1)...600 {
            var rng = SplitMix64(seed: seed)
            let easy = Self.random(&rng)
            var harder: [(String, AuditShot)] = []
            var moreCut = easy
            moreCut.cutDegrees += rng.uniform(0.1, 15)
            harder.append(("cut angle", moreCut))
            var longerCue = easy
            longerCue.cueTravel += rng.uniform(0.02, 0.5)
            harder.append(("cue travel", longerCue))
            var longerObject = easy
            longerObject.objectTravel += rng.uniform(0.02, 0.5)
            harder.append(("object travel", longerObject))
            var offAxis = easy
            offAxis.offAxisDegrees += rng.uniform(0.1, 15)
            harder.append(("off-axis angle", offAxis))

            guard let before = Self.probability(easy) else { continue }
            for (what, shot) in harder {
                // A harder shot that cannot be built or is blocked is 0 or absent.
                guard let after = Self.probability(shot) else { continue }
                #expect(after <= before + 1e-12,
                        "seed \(seed): more \(what) raised \(before) to \(after)")
                compared += 1
            }
        }
        #expect(compared > 800, "too few comparisons: \(compared)")
    }

    @Test func aPocketOffItsAxisNeverBeatsTheSameShotOnIt() {
        var compared = 0
        var strictlyWorse = 0
        for seed in UInt64(1)...600 {
            var rng = SplitMix64(seed: seed)
            var onAxis = Self.random(&rng)
            onAxis.offAxisDegrees = 0
            var off = onAxis
            off.offAxisDegrees = rng.uniform(1, 70)
            guard let straight = Self.probability(onAxis), let angled = Self.probability(off)
            else { continue }
            #expect(angled <= straight + 1e-12,
                    "seed \(seed) \(onAxis.pocket): \(off.offAxisDegrees) deg off axis \(angled) beat on axis \(straight)")
            compared += 1
            if angled < straight - 1e-6 { strictlyWorse += 1 }
        }
        #expect(compared > 200, "too few comparisons: \(compared)")
        #expect(strictlyWorse > compared / 4, "off-axis made no difference: \(strictlyWorse)/\(compared)")
    }

    /// A wider pocket can only help.
    @Test func aWiderMouthNeverHurts() throws {
        for seed in UInt64(1)...200 {
            var rng = SplitMix64(seed: seed)
            let shot = Self.random(&rng)
            guard let narrow = AuditReference.rate(shot, config: Self.smooth), narrow.blocker == nil
            else { continue }
            var wide = Self.smooth
            wide.cornerMouthWidth += 0.02
            wide.sideMouthWidth += 0.02
            let wider = try #require(AuditReference.rate(shot, config: wide))
            #expect(wider.probability >= narrow.probability - 1e-12, "seed \(seed)")
        }
    }
}
