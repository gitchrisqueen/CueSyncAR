//
//  RealWorldPhysicsTests.swift
//  BilliardsPhysics
//
//  Real-world grounding suite (physics audit, 2026-07). Every test pins a
//  solver behavior or config constant against published pool-physics data so
//  a future "tuning" cannot silently drift the model into fantasy physics.
//
//  Sources referenced in the tests:
//  - D. Alciatore, "The Illustrated Principles of Pool and Billiards" and
//    technical proofs at billiards.colostate.edu (rolling resistance,
//    ball-ball COR, 90-degree stun rule, banks-go-short).
//  - S. Mathavan, M. R. Jackson, R. M. Parkin, "A theoretical analysis of
//    billiard ball dynamics under cushion impacts" (Proc. IMechE C, 2010) —
//    cushion normal restitution and tangential speed loss.
//  - WPA/BCA equipment specifications (table playing fields, ball size,
//    pocket mouths).
//

import CueSyncCore
import Foundation
import Testing
@testable import BilliardsPhysics

private let cueID = BallID(0)
private let objectID = BallID(1)

private func makeState(balls: [Ball], size: TableSize = .nineFoot) -> TableState {
    TableState(table: Table(size: size), balls: balls, timestamp: 0)
}

@Suite("Real-world grounding — equipment geometry")
struct EquipmentGeometryTests {
    @Test func standardBallRadiusMatchesRegulation() {
        // WPA spec: American pool ball diameter 2 1/4 in = 57.15 mm.
        #expect(abs(Ball.standardRadius - 0.0286) < 3e-4,
                "ball radius must be 57.15 mm / 2 = 28.575 mm")
        #expect(Ball.standardRadius == 0.028575)
    }

    @Test func standardTableSizesMatchWPAPlayingFields() {
        // WPA/BCA playing surfaces (cushion nose to cushion nose):
        // 9 ft: 100 x 50 in = 2.54 x 1.27 m; 8 ft: 92 x 46 in = 2.34 x 1.17;
        // 7 ft: 78 x 39 in = 1.98 x 0.99 (some 7-footers 1.93 x 0.98).
        #expect(TableSize.nineFoot.playField == (2.54, 1.27))
        #expect(TableSize.eightFoot.playField == (2.34, 1.17))
        #expect(TableSize.sevenFoot.playField == (1.98, 0.99))
        // 2:1 aspect for every standard size.
        for size in TableSize.standardSizes {
            let f = size.playField
            #expect(abs(f.width / f.height - 2.0) < 1e-9)
        }
    }

    @Test func pocketCaptureRadiiApproximateWPAMouths() {
        // WPA mouth widths: corner 4.5-4.625 in (11.4-11.75 cm), side
        // 5-5.125 in (12.7-13 cm). The capture-circle model measures from
        // the mouth CENTER, so the physically comparable scale is the
        // half-mouth (~0.057-0.059 corner, ~0.0635-0.065 side).
        //
        // Corner: the circle sits at the rail-rectangle corner while the
        // real mouth center sits outside it in the jaw, so the radius must
        // also win the race against the cushion-reflection line: a ball
        // aimed dead at the corner crosses the inset line r*sqrt(5) ~=
        // 0.0639 m from the corner (see Docs/PhysicsModel.md), so capture
        // must trigger before that.
        let jawRace = Ball.standardRadius * 5.0.squareRoot()
        #expect(Table.cornerCaptureRadius > jawRace + 0.005,
                "corner capture must comfortably beat the cushion-reflection race")
        #expect(Table.cornerCaptureRadius <= 0.08,
                "corner capture beyond 8 cm would swallow balls a real 11.4-11.7 cm mouth rejects")
        // Side: capture circle is centered on the rail line, so its radius
        // plays directly as the half-mouth. Keep it within the real
        // half-mouth band, slightly tight is fine (the circle accepts
        // shallow-angle rollers that real side jaws reject).
        #expect(Table.sideCaptureRadius >= 0.05 && Table.sideCaptureRadius <= 0.066,
                "side capture should approximate the 12.7-13 cm WPA side mouth (half = 6.35-6.5 cm)")
    }
}

@Suite("Real-world grounding — config constants")
struct ConfigConstantBandTests {
    let config = PhysicsConfig.standard

    @Test func rollingDecelerationIsAnEffectiveClothValue() {
        // Pure rolling resistance is ~0.1 m/s^2 (mu_r ~= 0.01, Alciatore
        // TP A.4) — but that alone predicts a 2 m/s ball rolling
        // v^2/(2a) = 20 m, four 9-ft table lengths, which no real table
        // shows: the model has no sliding phase (mu ~= 0.2, ~2 m/s^2 until
        // natural roll, the 2/7 rule) and no rail/ball contact losses, so
        // the single constant must absorb them. Observed rollouts (a firm
        // 2 m/s lag-style shot dies within ~1.5-2 table lengths) imply an
        // effective deceleration of roughly v^2/(2d) = 4/(2*4..5) ~=
        // 0.4-0.5 m/s^2. Pin the defensible band.
        #expect(config.rollingDeceleration >= 0.25 && config.rollingDeceleration <= 0.6,
                "effective rolling deceleration outside the 0.25-0.6 m/s^2 real-cloth band")
    }

    @Test func lagSpeedShotDiesWithinTwoTableLengths() {
        // A 2 m/s shot down a 9-ft table must neither die mid-table nor roll
        // forever: real tables show ~1.5-2 lengths of travel. With the
        // current 0.5 m/s^2 the stop distance is v^2/(2a) = 4/(2*0.5) = 4 m.
        let v = 2.0
        let stop = v * v / (2 * config.rollingDeceleration)
        let tableLength = TableSize.nineFoot.playField.width  // 2.54 m
        #expect(stop >= tableLength, "a 2 m/s shot must at least cross a 9-ft table")
        #expect(stop <= 2 * tableLength, "a 2 m/s shot must not exceed two table lengths")
    }

    @Test func ballBallTransferMatchesPhenolicCOR() {
        // Equal-mass head-on impact: struck ball speed = v*(1+e)/2 for
        // ball-ball COR e. Phenolic balls: e ~= 0.92-0.96 (Alciatore TP
        // B.15), so the transfer fraction — which is what
        // ballBallRestitution encodes — must sit in 0.96-0.98.
        #expect(config.ballBallRestitution >= 0.955 && config.ballBallRestitution <= 0.985,
                "ball-ball transfer fraction outside the (1+e)/2 band for e in 0.92-0.96")
    }

    @Test func cushionConstantsSitInMeasuredBandsAndBankShort() {
        // Cushion normal COR: effective 0.6-0.85 at play speeds (Mathavan
        // et al. 2010; Alciatore rail measurements).
        #expect(config.cushionRestitution >= 0.6 && config.cushionRestitution <= 0.85)
        // Tangential retention from rail/cloth friction: ~0.7-0.9.
        #expect(config.cushionTangentialRetention >= 0.7 && config.cushionTangentialRetention <= 0.9)
        // Banks must play SHORT, never long: tan(theta_out) =
        // (f/e)*tan(theta_in) measured from the rail normal, so f < e.
        #expect(config.cushionTangentialRetention < config.cushionRestitution,
                "tangential retention must be below normal COR or banks rebound long")
    }
}

@Suite("Real-world grounding — ball-ball impacts")
struct BallImpactGroundingTests {
    let config = PhysicsConfig.standard
    let solver = AnalyticSolver()

    @Test func headOnObjectBallGetsTransferFractionOfImpactSpeed() throws {
        // Cue (-0.5, 0) -> object (0, 0) at 1.5 m/s. Ghost-ball contact at
        // x = -2r, travel d = 0.5 - 2r = 0.44285 m, impact speed
        // sqrt(1.5^2 - 2*0.5*0.44285). Object departs at transfer * that;
        // it must NOT get 100% (a real impact is not perfectly elastic).
        let cueStart = Vec2(-0.5, 0)
        let state = makeState(balls: [
            Ball(id: cueID, kind: .cue, position: cueStart),
            Ball(id: objectID, kind: .solid(1), position: .zero)
        ])
        let prediction = solver.predict(
            state: state,
            aim: AimRay(origin: cueStart, direction: Vec2(1, 0)),
            options: SolverOptions(initialSpeed: 1.5))

        let travel = 0.5 - 2 * Ball.standardRadius
        let impactSpeed = (1.5 * 1.5 - 2 * config.rollingDeceleration * travel).squareRoot()
        let objectEntry = try #require(prediction.segments(for: objectID).first).entrySpeed
        #expect(abs(objectEntry - impactSpeed * config.ballBallRestitution) < 1e-9)
        #expect(objectEntry < impactSpeed, "object ball must not receive 100% of the impact speed")
    }

    @Test func stunCutSeparatesAtNinetyDegrees() throws {
        // The 90-degree rule (Alciatore, "The 90° rule"): a SLIDING (stun)
        // cue ball departs along the tangent line, perpendicular to the
        // object ball's impact-line path — the MVP's declared model for
        // every hit. Half-ball offset -> 30-degree cut.
        let state = makeState(balls: [
            Ball(id: cueID, kind: .cue, position: .zero),
            Ball(id: objectID, kind: .solid(1),
                 position: Vec2(0.5, Ball.standardRadius))
        ])
        let prediction = solver.predict(
            state: state,
            aim: AimRay(origin: .zero, direction: Vec2(1, 0)),
            options: SolverOptions(initialSpeed: 1.5))

        let objectDir = try #require(prediction.segments(for: objectID).first)
        let cueSegments = prediction.segments(for: cueID)
        #expect(cueSegments.count >= 2)
        let objectV = (objectDir.end - objectDir.start).normalized
        let cueV = (cueSegments[1].end - cueSegments[1].start).normalized
        let separation = objectV.angle(to: cueV) * 180 / .pi
        #expect(abs(separation - 90) < 1e-6,
                "stun-model separation must be 90 degrees, got \(separation)")
    }

    @Test func impactsNeverCreateKineticEnergy() throws {
        // Sweep cut angles from full to razor-thin: post-impact
        // KE (object^2 + cue^2, unit mass) can never exceed the impact KE.
        // Geometry (cue at (0.9, 0) shooting -x at an object near the left
        // rail) is chosen so the object ball dies at or before the left
        // cushion and can never bank back for a re-kiss — a re-kiss would
        // hand the cue ball second-generation segments and invalidate this
        // single-impact energy accounting.
        var checkedOffsets = 0
        let cueStart = Vec2(0.9, 0)
        for offsetFraction in stride(from: 0.0, through: 1.9, by: 0.1) {
            let offset = offsetFraction * Ball.standardRadius
            let objectPos = Vec2(0.3, offset)
            let state = makeState(balls: [
                Ball(id: cueID, kind: .cue, position: cueStart),
                Ball(id: objectID, kind: .solid(1), position: objectPos)
            ])
            let prediction = solver.predict(
                state: state,
                aim: AimRay(origin: cueStart, direction: Vec2(-1, 0)),
                options: SolverOptions(initialSpeed: 1.5))
            guard let contact = prediction.firstContact else { continue }

            // Single-impact accounting requires exactly one ball-ball event.
            let ballBallEvents = prediction.events.filter {
                if case .ballBall = $0 { return true } else { return false }
            }
            guard ballBallEvents.count == 1 else { continue }
            checkedOffsets += 1

            let travel = contact.contact.distance(to: cueStart)
            let impactSpeed = (1.5 * 1.5 - 2 * config.rollingDeceleration * travel).squareRoot()
            let objectSpeed = prediction.segments(for: objectID).first?.entrySpeed ?? 0
            let cueSegments = prediction.segments(for: cueID)
            let cueSpeed = cueSegments.count >= 2 ? cueSegments[1].entrySpeed : 0
            let keIn = impactSpeed * impactSpeed
            let keOut = objectSpeed * objectSpeed + cueSpeed * cueSpeed
            #expect(keOut <= keIn + 1e-9,
                    "offset \(offsetFraction)r created energy: \(keOut) > \(keIn)")
        }
        #expect(checkedOffsets >= 15, "energy sweep lost too many cases to re-kisses")
    }
}

@Suite("Real-world grounding — cushion rebounds")
struct CushionGroundingTests {
    let config = PhysicsConfig.standard
    let solver = AnalyticSolver()

    /// 45-degree approach to the top rail, clear of every pocket mouth.
    private func fortyFiveBounce() -> ShotPrediction {
        let start = Vec2(-0.9, 0)
        return solver.predict(
            state: makeState(balls: [Ball(id: cueID, kind: .cue, position: start)]),
            aim: AimRay(origin: start, direction: Vec2(1, 1).normalized),
            options: SolverOptions(initialSpeed: 2.5))
    }

    @Test func fortyFiveDegreeBankReboundsShortOfMirror() throws {
        // Real rails rebound SHORT of the mirror angle (Alciatore: "bank
        // shots go short"): the outbound angle measured from the rail
        // NORMAL is smaller than the inbound 45 degrees, because rail/cloth
        // friction bleeds tangential speed (retention f) while the normal
        // rebound keeps COR e, with f < e. Expect atan(f/e) exactly, and a
        // shortening in the modest 1-8 degree range seen at medium speed.
        let prediction = fortyFiveBounce()
        let segments = prediction.segments(for: cueID)
        #expect(segments.count >= 2)
        let out = (segments[1].end - segments[1].start).normalized
        let outFromNormal = atan2(abs(out.x), abs(out.y)) * 180 / .pi
        let mirror = 45.0
        let expected = atan(config.cushionTangentialRetention / config.cushionRestitution) * 180 / .pi
        #expect(abs(outFromNormal - expected) < 1e-9)
        #expect(outFromNormal < mirror, "rebound must be short of the mirror angle")
        #expect(mirror - outFromNormal >= 1 && mirror - outFromNormal <= 8,
                "bank shortening of \(mirror - outFromNormal) degrees is outside the realistic 1-8 degree band")
    }

    @Test func fortyFiveDegreeBounceRetainsRealisticSpeed() throws {
        // Total speed retention at 45 degrees = sqrt((f^2 + e^2)/2); rails
        // measured across pool/snooker studies retain roughly 60-85% at
        // moderate incidence (Mathavan et al. 2010).
        let prediction = fortyFiveBounce()
        let segments = prediction.segments(for: cueID)
        let vIn = (2.5 * 2.5 - 2 * config.rollingDeceleration * segments[0].length).squareRoot()
        let retention = segments[1].entrySpeed / vIn
        let expected = ((pow(config.cushionTangentialRetention, 2)
            + pow(config.cushionRestitution, 2)) / 2).squareRoot()
        #expect(abs(retention - expected) < 1e-9)
        #expect(retention >= 0.6 && retention <= 0.85,
                "45-degree cushion speed retention \(retention) outside the 0.6-0.85 measured band")
    }

    @Test func perpendicularBounceRetainsNormalCOR() throws {
        // Dead-perpendicular hit: no tangential component, so the rebound
        // speed ratio IS the normal COR.
        let start = Vec2(0.3, 0)
        let prediction = solver.predict(
            state: makeState(balls: [Ball(id: cueID, kind: .cue, position: start)]),
            aim: AimRay(origin: start, direction: Vec2(0, 1)),
            options: SolverOptions(initialSpeed: 1.3))
        let segments = prediction.segments(for: cueID)
        #expect(segments.count >= 2)
        let vIn = (1.3 * 1.3 - 2 * config.rollingDeceleration * segments[0].length).squareRoot()
        #expect(abs(segments[1].entrySpeed / vIn - config.cushionRestitution) < 1e-9)
    }

    @Test func ballDetectedBeyondRailLineBouncesInPlaceInsteadOfTeleporting() throws {
        // Regression: a ball whose detected center sits at/beyond the
        // cushion-reflection inset (frozen on the rail, or in a pocket jaw)
        // while aimed INTO the rail used to produce a negative event
        // distance — the solver teleported it backward along its ray. It
        // must instead bounce immediately at its current position.
        let table = Table(size: .nineFoot)
        let lipX = table.halfExtents.x - Ball.standardRadius
        let start = Vec2(lipX + 0.002, 0.3)  // 2 mm beyond the inset line
        let prediction = solver.predict(
            state: makeState(balls: [Ball(id: cueID, kind: .cue, position: start)]),
            aim: AimRay(origin: start, direction: Vec2(1, 0)),
            options: SolverOptions(initialSpeed: 1.0))

        guard case let .cushion(ball, point)? = prediction.events.first else {
            Issue.record("expected an immediate cushion bounce, got \(prediction.events)")
            return
        }
        #expect(ball == cueID)
        #expect(point.distance(to: start) < 1e-9,
                "bounce must happen at the ball's position, not behind it")
        for segment in prediction.segments {
            #expect(segment.end.x <= start.x + 1e-9,
                    "no point of the path may pass deeper into the rail")
        }
        if case let .rest(_, restPoint)? = prediction.events.last {
            #expect(restPoint.x < start.x, "ball must rebound back onto the table")
        }
    }
}
