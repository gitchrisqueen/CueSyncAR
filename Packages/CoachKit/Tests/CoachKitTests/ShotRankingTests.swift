import CueSyncCore
import Foundation
import Testing
@testable import CoachKit

@Suite("ShotRanking")
struct ShotRankingTests {
    private let cueID = BallID(0)
    private let objectID = BallID(3)
    private let blockerID = BallID(9)
    private let table = Table(size: .eightFoot)
    private var he: Vec2 { table.halfExtents }

    /// A table holding the cue ball, one object ball, and any extras.
    private func state(cue: Vec2, object: Vec2,
                       objectKind: Ball.Kind = .solid(3),
                       extras: [Ball] = []) -> TableState {
        TableState(table: table, balls: [
            Ball(id: cueID, kind: .cue, position: cue),
            Ball(id: objectID, kind: objectKind, position: object)
        ] + extras, timestamp: 0)
    }

    private func rate(cue: Vec2, object: Vec2, pocket: PocketID = .cornerTopRight,
                      extras: [Ball] = [],
                      config: ShotRanking.Config = .intermediate) -> ShotRating? {
        let s = state(cue: cue, object: object, extras: extras)
        guard let cueBall = s.cueBall,
              let ball = s.ball(objectID),
              let p = s.table.pockets.first(where: { $0.id == pocket }) else { return nil }
        return ShotRanking.rate(cueBall: cueBall, ball: ball, pocket: p, state: s, config: config)
    }

    // MARK: - The model's shape

    @Test("A ball sitting on the pocket lip is a near-certain make")
    func hangerIsEasy() throws {
        let pocket = Vec2(he.x, he.y)
        let object = pocket - Vec2(0.06, 0.06)
        let r = try #require(rate(cue: object - Vec2(0.35, 0.35), object: object))
        #expect(r.blocker == nil)
        #expect(r.probability > 0.95)
        #expect(r.difficulty == .easy)
        #expect(r.cutAngleDegrees < 1)
    }

    @Test("A long, thin cut is a long shot")
    func longThinCutIsHard() throws {
        // Object ball at the table centre, pocket up-right; cue ball far
        // away and well off that line, so the cut is severe and the cue
        // travel long — the two things that compound.
        let object = Vec2(0, 0)
        let toPocket = (Vec2(he.x, he.y) - object).normalized
        let ghost = object - toPocket * (2 * Ball.standardRadius)
        let cue = ghost - toPocket.rotated(by: 65 * .pi / 180) * 1.3
        let r = try #require(rate(cue: cue, object: object))
        #expect(r.blocker == nil)
        #expect(r.cutAngleDegrees > 60)
        #expect(r.cueTravel > 1.2)
        #expect(r.difficulty == .longShot)
        #expect(r.probability < 0.15)
        // Still a real shot, not a refusal.
        #expect(r.probability > 0)
    }

    /// The core claim of the model: tolerance falls as the cue ball gets
    /// further from the ghost ball, all else equal.
    @Test("Doubling the cue-ball distance halves the aim tolerance")
    func toleranceScalesInverselyWithCueTravel() throws {
        let object = Vec2(0, 0)
        let toPocket = (Vec2(he.x, he.y) - object).normalized
        let ghost = object - toPocket * (2 * Ball.standardRadius)
        let near = try #require(rate(cue: ghost - toPocket * 0.4, object: object))
        let far = try #require(rate(cue: ghost - toPocket * 0.8, object: object))
        #expect(near.cutAngleDegrees < 0.001)
        #expect(far.cutAngleDegrees < 0.001)
        // Both straight-on, so only cueTravel differs.
        #expect(abs(near.cueTravel - 0.4) < 1e-9)
        #expect(abs(far.cueTravel - 0.8) < 1e-9)
        let ratio = near.aimTolerance / far.aimTolerance
        #expect(abs(ratio - 2) < 1e-9)
        #expect(near.probability > far.probability)
    }

    @Test("A bigger cut angle is always harder from the same distance")
    func cutAngleReducesProbability() throws {
        let object = Vec2(0, 0)
        let toPocket = (Vec2(he.x, he.y) - object).normalized
        let ghost = object - toPocket * (2 * Ball.standardRadius)
        var previous = 1.1
        for degrees in stride(from: 0.0, through: 60.0, by: 15.0) {
            let radians = degrees * .pi / 180
            let cue = ghost - toPocket.rotated(by: radians) * 0.6
            let r = try #require(rate(cue: cue, object: object))
            #expect(r.probability < previous, "cut \(degrees)° should be harder than the step before")
            previous = r.probability
        }
    }

    @Test("A further pocket is harder than a near one for the same cut")
    func objectTravelReducesProbability() throws {
        let far = try #require(rate(cue: Vec2(-1.0, -0.5), object: Vec2(-0.8, -0.4)))
        let near = try #require(rate(cue: Vec2(0.6, 0.3), object: Vec2(0.8, 0.4)))
        #expect(near.objectTravel < far.objectTravel)
        #expect(near.probability > far.probability)
    }

    // MARK: - Blockers

    @Test("A ball touching the cue ball's path blocks the shot outright")
    func cuePathBlocked() throws {
        let object = Vec2(0.4, 0.2)
        let cue = Vec2(-0.6, -0.3)
        let midpoint = (cue + object) * 0.5
        let r = try #require(rate(cue: cue, object: object,
                                  extras: [Ball(id: blockerID, kind: .stripe(11), position: midpoint)]))
        #expect(r.blocker == .cuePath(blockerID))
        #expect(r.probability == 0)
        #expect(r.difficulty == .blocked)
    }

    @Test("A ball between the object ball and the pocket blocks the shot")
    func objectPathBlocked() throws {
        let object = Vec2(0, 0)
        let pocket = Vec2(he.x, he.y)
        let midpoint = (object + pocket) * 0.5
        let r = try #require(rate(cue: Vec2(-0.5, -0.25), object: object,
                                  extras: [Ball(id: blockerID, kind: .stripe(11), position: midpoint)]))
        #expect(r.blocker == .objectPath(blockerID))
        #expect(r.probability == 0)
    }

    /// Worth stating because it is counter-intuitive: outside of an
    /// almost-touching squeeze, a ball near the cue's path does not make a
    /// shot harder. The aim precision a pot demands is an order of
    /// magnitude finer than the precision needed to miss a nearby ball, so
    /// the pot constraint binds first. Only contact matters.
    @Test("A ball beside the path costs nothing until it is nearly touching")
    func nearMissBindsOnlyWhenAlmostTouching() throws {
        let object = Vec2(0, 0)
        let cue = Vec2(-0.7, -0.35)
        let clear = try #require(rate(cue: cue, object: object))
        let along = (object - cue).normalized

        func withBlocker(gapBeyondTouching: Double) throws -> ShotRating {
            let offset = 2 * Ball.standardRadius + gapBeyondTouching
            let beside = cue + along * 0.35 + along.perpendicular * offset
            return try #require(rate(cue: cue, object: object,
                                     extras: [Ball(id: blockerID, kind: .stripe(11), position: beside)]))
        }

        // 2 cm of daylight: irrelevant. Missing it needs ~3°, potting needs ~0.15°.
        let roomy = try withBlocker(gapBeyondTouching: 0.02)
        #expect(roomy.blocker == nil)
        #expect(roomy.aimTolerance == clear.aimTolerance)
        #expect(roomy.aimTolerance < 0.02 / 0.35)

        // Half a millimetre: now the squeeze is the binding constraint.
        let squeeze = try withBlocker(gapBeyondTouching: 0.0005)
        #expect(squeeze.blocker == nil)
        #expect(squeeze.aimTolerance < clear.aimTolerance)
        #expect(squeeze.probability < clear.probability)
    }

    @Test("A cut past 90 degrees is refused, not rated low")
    func cutTooThinIsRefused() throws {
        // Cue ball on the far side of the object ball from the pocket's
        // approach line: the cue cannot reach the needed contact point.
        let object = Vec2(0.3, 0.15)
        let cue = Vec2(he.x - 0.05, he.y - 0.05)
        let r = try #require(rate(cue: cue, object: object))
        #expect(r.blocker == .cutTooThin)
        #expect(r.probability == 0)
    }

    @Test("A ball past the pocket cannot be shot back across its mouth")
    func pocketFacingAwayIsRefused() throws {
        // Object hard against the top rail, shooting at the *bottom* corner
        // means arriving almost parallel to that pocket's mouth.
        let object = Vec2(0.0, he.y - Ball.standardRadius)
        let r = try #require(rate(cue: Vec2(-0.4, 0.3), object: object, pocket: .sideTop))
        #expect(r.probability > 0)      // the side pocket it is next to is fine
        let across = try #require(rate(cue: Vec2(-0.4, 0.3), object: object, pocket: .sideBottom))
        #expect(across.blocker == .pocketFacingAway || across.probability < 0.05)
    }

    @Test("A ball frozen on the rail is harder than the same ball off it")
    func railProximityPenalty() throws {
        let onRail = Vec2(0.3, he.y - Ball.standardRadius)
        let offRail = Vec2(0.3, he.y - 0.15)
        let a = try #require(rate(cue: Vec2(-0.6, 0.2), object: onRail, pocket: .cornerTopRight))
        let b = try #require(rate(cue: Vec2(-0.6, 0.2), object: offRail, pocket: .cornerTopRight))
        #expect(a.aimTolerance < b.aimTolerance)
    }

    // MARK: - Skill

    @Test("The same shot reads easier for a better player")
    func skillOrdersProbabilities() throws {
        let object = Vec2(0, 0)
        let cue = Vec2(-0.8, -0.5)
        let beginner = try #require(rate(cue: cue, object: object, config: .beginner))
        let mid = try #require(rate(cue: cue, object: object, config: .intermediate))
        let advanced = try #require(rate(cue: cue, object: object, config: .advanced))
        #expect(beginner.probability < mid.probability)
        #expect(mid.probability < advanced.probability)
        // Geometry is unchanged by skill — only the pricing of it.
        #expect(beginner.aimTolerance == mid.aimTolerance)
        #expect(mid.cutAngleDegrees == advanced.cutAngleDegrees)
    }

    @Test("Probability is zero without tolerance and saturates with plenty")
    func probabilityCurveEndpoints() {
        #expect(ShotRanking.potProbability(tolerance: 0, sigma: 0.005) == 0)
        #expect(ShotRanking.potProbability(tolerance: -1, sigma: 0.005) == 0)
        #expect(ShotRanking.potProbability(tolerance: 0.5, sigma: 0.005) > 0.999)
        let half = ShotRanking.potProbability(tolerance: 0.005, sigma: 0.005)
        #expect(half > 0.6 && half < 0.7)     // erf(1/√2) ≈ 0.6827
    }

    // MARK: - Ranking and grouping

    @Test("Ranking is sorted, deterministic, and never offers the cue ball")
    func rankingIsOrderedAndStable() {
        let s = state(cue: Vec2(-0.9, -0.3), object: Vec2(0.2, 0.1), extras: [
            Ball(id: BallID(5), kind: .solid(5), position: Vec2(0.7, -0.2)),
            Ball(id: BallID(12), kind: .stripe(12), position: Vec2(-0.3, 0.35))
        ])
        let first = ShotRanking.rank(state: s)
        let second = ShotRanking.rank(state: s)
        #expect(first == second)
        #expect(!first.isEmpty)
        #expect(!first.contains { $0.ball == cueID })
        #expect(zip(first, first.dropFirst()).allSatisfy { $0.probability >= $1.probability })
    }

    @Test("best() returns one row per ball, ordered by that ball's best pocket")
    func bestIsOnePerBall() {
        let s = state(cue: Vec2(-0.9, -0.3), object: Vec2(0.2, 0.1), extras: [
            Ball(id: BallID(5), kind: .solid(5), position: Vec2(0.7, -0.2))
        ])
        let best = ShotRanking.best(state: s)
        #expect(Set(best.map(\.ball)).count == best.count)
        #expect(best.count == 2)
        #expect(zip(best, best.dropFirst()).allSatisfy { $0.probability >= $1.probability })
        // Each row really is that ball's best pocket.
        let all = ShotRanking.rank(state: s)
        for row in best {
            let bestForBall = all.filter { $0.ball == row.ball }.map(\.probability).max()
            #expect(row.probability == bestForBall)
        }
    }

    @Test("A group filters the ranking without hiding unnamed balls")
    func groupFiltering() {
        let s = TableState(table: table, balls: [
            Ball(id: cueID, kind: .cue, position: Vec2(-0.9, -0.3)),
            Ball(id: BallID(3), kind: .solid(3), position: Vec2(0.2, 0.1)),
            Ball(id: BallID(11), kind: .stripe(11), position: Vec2(0.5, -0.1)),
            Ball(id: BallID(8), kind: .eight, position: Vec2(-0.2, 0.2)),
            Ball(id: BallID(99), kind: .unknown, position: Vec2(0.8, 0.3))
        ], timestamp: 0)
        let solids = Set(ShotRanking.best(state: s, group: .solids).map(\.ball))
        #expect(solids.contains(BallID(3)))
        #expect(solids.contains(BallID(99)))         // unnamed stays offered
        #expect(!solids.contains(BallID(11)))
        #expect(!solids.contains(BallID(8)))         // the eight is not a solid
        let eight = Set(ShotRanking.best(state: s, group: .eight).map(\.ball))
        #expect(eight == [BallID(8)])
        let open = Set(ShotRanking.best(state: s, group: .any).map(\.ball))
        #expect(open.count == 4)
    }

    @Test("recommended() skips shots that are blocked")
    func recommendedSkipsBlocked() throws {
        // One ball hangs but is blocked to every pocket by a wall of balls;
        // a second ball is clear.
        let object = Vec2(0, 0)
        let s = state(cue: Vec2(-0.8, 0.0), object: object, extras: [
            Ball(id: blockerID, kind: .stripe(11), position: Vec2(-0.4, 0.0)),
            Ball(id: BallID(5), kind: .solid(5), position: Vec2(0.9, 0.42))
        ])
        let pick = try #require(ShotRanking.recommended(state: s))
        #expect(pick.blocker == nil)
        #expect(pick.probability > 0)
    }

    @Test("No cue ball means no ranking, not a crash")
    func noCueBall() {
        let s = TableState(table: table, balls: [
            Ball(id: objectID, kind: .solid(3), position: Vec2(0.2, 0.1))
        ], timestamp: 0)
        #expect(ShotRanking.rank(state: s).isEmpty)
        #expect(ShotRanking.recommended(state: s) == nil)
    }

    // MARK: - Pocket geometry

    @Test("Every pocket faces out of the table, away from its own centre")
    func pocketFacingsPointOutward() {
        for pocket in table.pockets {
            let facing = ShotRanking.facingDirection(of: pocket.id)
            #expect(abs(facing.length - 1) < 1e-9)
            // Facing agrees with the direction from the table centre.
            #expect(facing.dot(pocket.position.normalized) > 0.7)
        }
    }
}

@Suite("BallGroup")
struct BallGroupTests {
    @Test("Groups admit their own balls and never the cue ball")
    func membership() {
        #expect(BallGroup.solids.includes(.solid(3)))
        #expect(!BallGroup.solids.includes(.stripe(11)))
        #expect(!BallGroup.solids.includes(.eight))
        #expect(BallGroup.stripes.includes(.stripe(11)))
        #expect(BallGroup.eight.includes(.eight))
        #expect(!BallGroup.eight.includes(.solid(1)))
        for group in BallGroup.allCases {
            #expect(!group.includes(.cue))
        }
    }

    @Test("An unnamed ball is offered by every group except the eight")
    func unknownIsAdmitted() {
        #expect(BallGroup.any.includes(.unknown))
        #expect(BallGroup.solids.includes(.unknown))
        #expect(BallGroup.stripes.includes(.unknown))
        #expect(!BallGroup.eight.includes(.unknown))
    }

    @Test("Halves of the rack are each other's opposite; open play has none")
    func opposites() {
        #expect(BallGroup.solids.opposite == .stripes)
        #expect(BallGroup.stripes.opposite == .solids)
        #expect(BallGroup.any.opposite == .any)
        #expect(BallGroup.eight.opposite == .eight)
    }

    @Test("A ball's own group round-trips")
    func groupOfKind() {
        #expect(BallGroup.of(.solid(1)) == .solids)
        #expect(BallGroup.of(.stripe(15)) == .stripes)
        #expect(BallGroup.of(.eight) == .eight)
        #expect(BallGroup.of(.cue) == nil)
        #expect(BallGroup.of(.unknown) == nil)
    }
}

/// The seven balls as the pipeline actually projected them on 2026-09-09,
/// on the owner's measured 2.256 × 1.079 m table (`Sessions/
/// device-20260909T014006Z`, frame 2). Synthetic geometry can be made to
/// say anything; this is the shape of a real rack.
@Suite("ShotRanking on a recorded table")
struct ShotRankingRealTableTests {
    private let table = Table(size: .custom(width: 2.255925, height: 1.079337))

    private var state: TableState {
        TableState(table: table, balls: [
            Ball(id: BallID(0), kind: .unknown, position: Vec2(-0.875984, -0.398337), confidence: 0.80),
            Ball(id: BallID(1), kind: .unknown, position: Vec2(0.724486, -0.354730), confidence: 0.74),
            Ball(id: BallID(2), kind: .unknown, position: Vec2(0.743277, 0.226318), confidence: 0.72),
            Ball(id: BallID(3), kind: .unknown, position: Vec2(0.068308, 0.206770), confidence: 0.74),
            Ball(id: BallID(4), kind: .unknown, position: Vec2(0.006855, -0.450730), confidence: 0.61),
            Ball(id: BallID(5), kind: .unknown, position: Vec2(-0.886536, 0.331994), confidence: 0.52),
            Ball(id: BallID(6), kind: .cue, position: Vec2(-0.526984, -0.238454), confidence: 0.36)
        ], timestamp: 0)
    }

    @Test("Every object ball gets a rating, and none of them is the cue ball")
    func coversTheRack() {
        let best = ShotRanking.best(state: state)
        #expect(best.count == 6)
        #expect(!best.contains { $0.ball == BallID(6) })
        #expect(best.allSatisfy { (0...1).contains($0.probability) })
        #expect(best.allSatisfy { $0.cutAngleDegrees >= 0 && $0.cutAngleDegrees <= 90 })
    }

    @Test("The suggestion is a real, unblocked shot the player could take")
    func recommendsSomethingShootable() throws {
        let pick = try #require(ShotRanking.recommended(state: state))
        #expect(pick.blocker == nil)
        #expect(pick.probability > 0.3)
        // The ghost ball must sit on the table, not inside a cushion.
        #expect(state.table.contains(pick.ghostBall, ballRadius: 0))
        // And it must be reachable: the cue ball is not already past it.
        #expect(pick.cueTravel > 0)
    }

    @Test("The two balls near a corner outrank the three long shots")
    func nearBallsOutrankLongOnes() throws {
        let best = ShotRanking.best(state: state)
        let byBall = Dictionary(uniqueKeysWithValues: best.map { ($0.ball, $0) })
        // Balls 0 and 5 sit within 35 cm of the left-hand corners; balls 1,
        // 2 and 3 are 0.44-1.11 m from theirs with the cue ball a table away.
        for near in [BallID(0), BallID(5)] {
            for far in [BallID(1), BallID(2), BallID(3)] {
                let a = try #require(byBall[near])
                let b = try #require(byBall[far])
                #expect(a.probability > b.probability,
                        "ball \(near.rawValue) should beat ball \(far.rawValue)")
            }
        }
    }

    /// Ball 4 hangs 9 cm off the side pocket but has to be cut at 78°. Pure
    /// geometry calls that easy; `cutJudgementPenalty` is what stops the app
    /// promising a player something no one makes four times in five.
    @Test("A very thin cut beside a pocket is not sold as an easy shot")
    func thinCutIsNotEasy() throws {
        let four = try #require(ShotRanking.best(state: state).first { $0.ball == BallID(4) })
        #expect(four.cutAngleDegrees > 70)
        #expect(four.difficulty != .easy)
        #expect(four.probability < 0.7)

        // With the penalty off, the same shot reads as easy — which is the
        // behaviour the term exists to correct.
        let raw = ShotRanking.best(state: state,
                                   config: ShotRanking.Config(cutJudgementPenalty: 0))
        let rawFour = try #require(raw.first { $0.ball == BallID(4) })
        #expect(rawFour.probability > four.probability)
        #expect(rawFour.aimTolerance == four.aimTolerance)   // geometry untouched
    }

    @Test("Ranking a group nobody has been assigned yet still offers every ball")
    func unnamedBallsStayShootable() {
        // Nothing is classified yet — the appearance pass has not run. A
        // player choosing "solids" must still see shots, or the app goes
        // blank on them.
        #expect(ShotRanking.best(state: state, group: .solids).count == 6)
        #expect(ShotRanking.best(state: state, group: .stripes).count == 6)
        #expect(ShotRanking.best(state: state, group: .eight).isEmpty)
    }
}
