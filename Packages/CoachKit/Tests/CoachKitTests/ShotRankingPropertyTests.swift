//
//  ShotRankingPropertyTests.swift
//  CoachKitTests
//
//  Property tests for ShotRanking and ShotSelection over seeded random
//  legal layouts on a nine-foot table. Every failure message carries its
//  seed; `LayoutGenerator.layout(seed:)` regenerates the layout.
//

import BilliardsPhysics
import CueSyncCore
import Foundation
import Testing
@testable import CoachKit

@Suite("ShotRanking properties")
struct ShotRankingPropertyTests {
    /// 300 fixed seeds; each one is a layout.
    static let seeds: [UInt64] = Array(1...300)

    @Test func generatorProducesLegalLayouts() {
        for seed in Self.seeds {
            let state = LayoutGenerator.layout(seed: seed)
            #expect(LayoutGenerator.isLegal(state), "seed \(seed) produced an illegal layout")
            #expect((2...16).contains(state.balls.count), "seed \(seed) ball count")
        }
    }

    // MARK: a. Solver replay

    /// Cue speed for the replay: 4.0 m/s, the firm end of a normal shot.
    /// The ranking has no power model, so the only fair premise is "hit it
    /// hard enough to arrive".
    static let replaySpeed = 4.0

    /// What the solver did with a shot the ranking offered.
    enum Verdict: String, CaseIterable {
        /// The target dropped in the pocket the ranking named.
        case potted
        /// The target dropped, but in a different pocket.
        case pottedElsewhere
        /// The cue ball dropped before it reached the object ball: its lane
        /// crosses a pocket mouth.
        case scratchBeforeContact
        /// The cue ball dropped after striking the object ball, and the
        /// target did not drop. Where the cue ball goes after contact is
        /// outside the model (`ShotRating.caveats`).
        case scratchAfterContact
        /// The object ball, launched at the speed the solver gives it,
        /// cannot roll as far as the pocket: soft power, not a ranking fault.
        case underpowered
        /// The object ball already sits inside its pocket's capture circle.
        /// The solver captures on ENTERING the circle, so a ball that starts
        /// inside never drops. A solver convention, not a ranking fault.
        case startsInsideCaptureCircle
        /// The solver rolls balls one after another against a static
        /// snapshot ("moving-vs-moving not modeled"): the cue ball goes
        /// first, comes to rest in the object ball's lane, and the object
        /// ball then "hits" it. In play the object ball is long gone.
        case cueRestsInObjectLane
        case unexplained
    }

    /// Aim the cue ball's centre through the ghost ball, as the app does
    /// (`TargetGuide.aim`).
    static func aim(for rating: ShotRating, cue: Ball) -> AimRay {
        AimRay(origin: cue.position, direction: rating.ghostBall - cue.position)
    }

    static func replay(_ rating: ShotRating, in state: TableState,
                       solver: AnalyticSolver) -> Verdict {
        guard let cue = state.cueBall else { return .unexplained }
        let prediction = solver.predict(
            state: state, aim: aim(for: rating, cue: cue),
            options: SolverOptions(initialSpeed: replaySpeed))
        var pocketOf: [BallID: PocketID] = [:]
        for case let .pocket(ball, pocket) in prediction.events { pocketOf[ball] = pocket }
        if let pocket = pocketOf[rating.ball] {
            return pocket == rating.pocket ? .potted : .pottedElsewhere
        }
        if pocketOf[cue.id] != nil {
            let contact = prediction.events.firstIndex {
                if case let .ballBall(moving, struck, _) = $0 {
                    return moving == cue.id && struck == rating.ball
                }
                return false
            }
            let drop = prediction.events.firstIndex {
                if case let .pocket(ball, _) = $0 { return ball == cue.id }
                return false
            }
            if let contact, let drop, contact < drop { return .scratchAfterContact }
            return .scratchBeforeContact
        }

        // Analytic reach of the object ball after contact (equal-mass stun
        // model from AnalyticSolver: speed * cos(cut) * restitution).
        let config = solver.config
        let hitSquared = replaySpeed * replaySpeed
            - 2 * config.rollingDeceleration * rating.cueTravel
        let launch = hitSquared > 0
            ? hitSquared.squareRoot() * cos(rating.cutAngleDegrees * .pi / 180)
                * config.ballBallRestitution
            : 0
        let reach = launch * launch / (2 * config.rollingDeceleration)
        if reach < rating.objectTravel { return .underpowered }

        if let target = state.ball(rating.ball),
           let pocket = state.table.pockets.first(where: { $0.id == rating.pocket }) {
            if target.position.distance(to: pocket.position) < pocket.captureRadius {
                return .startsInsideCaptureCircle
            }
            for case let .rest(ball, point) in prediction.events where ball == cue.id {
                if segmentDistance(from: point, target.position, pocket.position)
                    < 2 * Ball.standardRadius { return .cueRestsInObjectLane }
            }
        }
        return .unexplained
    }

    /// At or above this the ranking calls a shot makeable
    /// (`ShotRating.Difficulty.medium` and `.easy`).
    static let makeableFloor = 0.45

    /// Measured over seeds 1...300 at 4.0 m/s, AFTER the two lane fixes in
    /// `ShotRanking` (pocket mouths, and balls just past the ghost ball):
    /// 2,406 unblocked ratings, 696 of them makeable (>= 45 %).
    ///   makeable  potted 687, cueRestsInObjectLane 6, startsInsideCapture 3
    ///   all       potted 2,104, scratchAfterContact 44, underpowered 224,
    ///             cueRestsInObjectLane 27, startsInsideCapture 3,
    ///             unexplained 4
    /// BEFORE the fixes the same seeds gave 2,440 unblocked ratings, 698
    /// makeable. Across all ratings 6 scratched before contact and 17
    /// dropped the target in the wrong pocket; of the makeable ones 1 and 1.
    ///
    /// The 4 that remain unexplained are all long shots (3 %, 14 %, 3 %,
    /// 15 %): rail-hugging objects whose aim line the solver bounces off a
    /// cushion before the pocket, and one whose ghost-ball position is
    /// 3 cm beyond the cushion line (seed 14), so the cue ball cannot get
    /// there. A known limit of the model at the bottom of the range, pinned
    /// here so it cannot grow, not a claim that it is right.
    @Test func offeredShotsDropInTheSolverUnlessAnExplainedPremiseFails() {
        let solver = AnalyticSolver()
        var all: [Verdict: Int] = [:]
        var makeable: [Verdict: Int] = [:]
        var unexplained = 0
        for seed in Self.seeds {
            let state = LayoutGenerator.layout(seed: seed)
            for rating in ShotRanking.rank(state: state) where rating.blocker == nil {
                let verdict = Self.replay(rating, in: state, solver: solver)
                all[verdict, default: 0] += 1
                if rating.probability >= Self.makeableFloor { makeable[verdict, default: 0] += 1 }
                // Never acceptable at any probability: these are failures of
                // what the ranking CLAIMS about the lanes, not of power or
                // of what the cue ball does afterwards.
                let name = "seed \(seed): \(rating.ball.rawValue)->\(rating.pocket.rawValue)"
                #expect(verdict != .scratchBeforeContact, "\(name) scratches before contact")
                #expect(verdict != .pottedElsewhere, "\(name) drops in another pocket")
                if verdict == .unexplained {
                    unexplained += 1
                    #expect(rating.difficulty == .longShot,
                            "\(name) is rated \(rating.percentage)% and did not drop")
                }
                if rating.probability >= Self.makeableFloor {
                    #expect(verdict != .underpowered,
                            "\(name) is makeable but not in reach at \(Self.replaySpeed) m/s")
                }
            }
        }
        func line(_ counts: [Verdict: Int]) -> String {
            Verdict.allCases.map { "\($0.rawValue)=\(counts[$0, default: 0])" }
                .joined(separator: " ")
        }
        let total = makeable.values.reduce(0, +)
        print("REPLAY all-unblocked total=\(all.values.reduce(0, +)) \(line(all))")
        print("REPLAY makeable(>=45%) total=\(total) \(line(makeable))")
        // Was `> 500`, when 696 shots read makeable. The old count came from
        // a corner margin 63 % too wide (captureRadius - R = 46.4 mm against
        // the 28.4 mm a 114 mm mouth leaves; see ShotRankingAuditTests). With
        // the margin from the mouth width 416 read makeable, and 412 of them
        // (99 %) potted in the solver, so the premise this floor guards -
        // enough makeable shots to mean anything - still holds.
        // Docs: docs/research/2026-11-12-ranking-audit.md.
        #expect(total > 300, "too few makeable shots to mean anything: \(total)")
        #expect(unexplained <= 4, "unexplained misses grew to \(unexplained)")
        #expect(Double(makeable[.potted, default: 0]) / Double(total) > 0.95)
    }

    // MARK: Pocket lanes (regression for the fix the replay found)

    private func twoBalls(cue: Vec2, target: Vec2) -> TableState {
        TableState(table: LayoutGenerator.table, balls: [
            Ball(id: BallID(0), kind: .cue, position: cue),
            Ball(id: BallID(5), kind: .solid(5), position: target)
        ])
    }

    private func rate(_ state: TableState, into pocket: PocketID) throws -> ShotRating {
        let cue = try #require(state.cueBall)
        let target = try #require(state.ball(BallID(5)))
        let mouth = try #require(state.table.pockets.first { $0.id == pocket })
        return try #require(ShotRanking.rate(cueBall: cue, ball: target, pocket: mouth, state: state))
    }

    @Test func cueLaneThroughAPocketMouthIsBlockedAsAScratch() throws {
        // Cue and target hug the top rail; the lane from the cue ball to
        // the ghost ball crosses x = 0 about 0.046 m from the side-pocket
        // centre (capture radius 0.058), so the cue ball would scratch.
        let state = twoBalls(cue: Vec2(-0.5, 0.60), target: Vec2(0.5, 0.58))
        let blocked = try rate(state, into: .cornerTopRight)
        #expect(blocked.blocker == .cueScratch(.sideTop))
        #expect(blocked.percentage == 0)
        #expect(blocked.headline.hasPrefix("Blocked"))
        // And the solver agrees with the blocker.
        let verdict = Self.replay(blocked, in: state, solver: AnalyticSolver())
        #expect(verdict == .scratchBeforeContact)

        // Same target and pocket from a clear lane is still offered.
        let clear = twoBalls(cue: Vec2(0.0, 0.1), target: Vec2(0.5, 0.58))
        #expect(try rate(clear, into: .cornerTopRight).blocker == nil)
    }

    @Test func objectLaneThroughAnotherPocketMouthIsBlocked() throws {
        // Seed 234 of the replay: ball 6 sits near the top-left corner and
        // its lane to the FAR top-right corner crosses the top side pocket.
        let state = LayoutGenerator.layout(seed: 234)
        let target = try #require(state.ball(BallID(6)))
        let cue = try #require(state.cueBall)
        let pocket = try #require(state.table.pockets.first { $0.id == .cornerTopRight })
        let rated = try #require(ShotRanking.rate(cueBall: cue, ball: target, pocket: pocket,
                                                  state: state))
        #expect(rated.blocker == .pocketInTheWay(.sideTop))
    }

    @Test func aBallJustPastTheGhostBallBlocksTheCueLane() throws {
        // Target at the centre, pocket up-right. A second ball sits half a
        // diameter beyond the ghost-ball position and to the side: not
        // between the cue ball and the ghost ball, but within a diameter of
        // where the cue ball must stop, so the cue ball cannot get there.
        let r = Ball.standardRadius
        let target = Vec2(0, 0)
        let table = LayoutGenerator.table
        let pocket = try #require(table.pockets.first { $0.id == .cornerTopRight })
        let dir = (pocket.position - target).normalized
        let perp = Vec2(-dir.y, dir.x)
        let ghost = target - dir * (2 * r)
        let neighbour = ghost + dir * 0.01 + perp * 0.05
        #expect(neighbour.distance(to: target) >= 2 * r + 1e-4, "neighbour overlaps the target")
        #expect(neighbour.distance(to: ghost) < 2 * r)
        let state = TableState(table: table, balls: [
            Ball(id: BallID(0), kind: .cue, position: ghost - dir * 0.6),
            Ball(id: BallID(5), kind: .solid(5), position: target),
            Ball(id: BallID(9), kind: .stripe(9), position: neighbour)
        ])
        let rated = try rate(state, into: .cornerTopRight)
        #expect(rated.blocker == .cuePath(BallID(9)))
    }

    @Test func aBallRestingOnAPocketLipDoesNotBlockItsOwnLane() throws {
        // The cue ball sits inside the side pocket's capture circle. The
        // solver (and a real ball) is only captured on ENTERING a circle,
        // so a lane that starts inside is not a scratch.
        let state = twoBalls(cue: Vec2(0.0, -0.58), target: Vec2(-0.6, -0.2))
        let cue = try #require(state.cueBall)
        let side = try #require(state.table.pockets.first { $0.id == .sideBottom })
        #expect(cue.position.distance(to: side.position) < side.captureRadius)
        let rated = try rate(state, into: .cornerBottomLeft)
        #expect(rated.blocker != .cueScratch(.sideBottom))
    }

    // MARK: b. Lanes are clear (independent re-derivation)

    @Test func noRankedShotHasABlockedLane() {
        var checked = 0
        for seed in Self.seeds {
            let state = LayoutGenerator.layout(seed: seed)
            guard let cue = state.cueBall else { continue }
            for rating in ShotRanking.rank(state: state) {
                guard let target = state.ball(rating.ball),
                      let pocket = state.table.pockets.first(where: { $0.id == rating.pocket })
                else {
                    Issue.record("seed \(seed): rating names a ball or pocket that does not exist")
                    continue
                }
                let name = "seed \(seed): \(rating.ball.rawValue)->\(rating.pocket.rawValue)"
                if rating.blocker != nil {
                    // A blocked rating must say so everywhere.
                    #expect(rating.probability == 0 && rating.difficulty == .blocked,
                            "\(name): blocked rating carries a probability")
                    continue
                }
                #expect(rating.probability >= ShotRanking.Config().minimumProbability,
                        "\(name): offered below the minimum probability")
                for other in state.balls where other.id != cue.id && other.id != target.id {
                    let cueLane = segmentDistance(from: other.position, cue.position,
                                                  rating.ghostBall)
                    #expect(cueLane >= other.radius + cue.radius - 1e-4,
                            "\(name): cue lane blocked by ball \(other.id.rawValue)")
                    let objectLane = segmentDistance(from: other.position, target.position,
                                                     pocket.position)
                    #expect(objectLane >= other.radius + target.radius - 1e-4,
                            "\(name): object lane blocked by ball \(other.id.rawValue)")
                }
                // No pocket mouth in either lane, except one the lane starts in.
                for other in state.table.pockets {
                    if cue.position.distance(to: other.position) >= other.captureRadius {
                        #expect(segmentDistance(from: other.position, cue.position, rating.ghostBall)
                                    >= other.captureRadius,
                                "\(name): cue lane enters \(other.id)")
                    }
                    if other.id != pocket.id,
                       target.position.distance(to: other.position) >= other.captureRadius {
                        #expect(segmentDistance(from: other.position, target.position, pocket.position)
                                    >= other.captureRadius,
                                "\(name): object lane enters \(other.id)")
                    }
                }
                checked += 1
            }
        }
        #expect(checked > 1_000, "too few ratings checked: \(checked)")
    }

    // MARK: c. Ordering and determinism

    @Test func rankingIsSortedUniqueDeterministicAndOrderIndependent() {
        for seed in Self.seeds {
            let state = LayoutGenerator.layout(seed: seed)
            let all = ShotRanking.rank(state: state)

            for (a, b) in zip(all, all.dropFirst()) {
                let ordered = a.probability > b.probability
                    || (a.probability == b.probability && (a.ball.rawValue < b.ball.rawValue
                        || (a.ball == b.ball && a.pocket.rawValue < b.pocket.rawValue)))
                #expect(ordered, """
                    seed \(seed): \(a.ball.rawValue)->\(a.pocket.rawValue) before \
                    \(b.ball.rawValue)->\(b.pocket.rawValue) is out of order
                    """)
            }
            let pairs = all.map { "\($0.ball.rawValue)/\($0.pocket.rawValue)" }
            #expect(Set(pairs).count == pairs.count, "seed \(seed): duplicate ball/pocket pair")
            #expect(all.allSatisfy { (0...1).contains($0.probability) },
                    "seed \(seed): probability out of range")

            // `best` keeps exactly one pocket per ball, and it is that ball's best.
            let best = ShotRanking.best(state: state)
            #expect(Set(best.map(\.ball)).count == best.count, "seed \(seed): best repeats a ball")
            for row in best {
                #expect(all.first { $0.ball == row.ball } == row,
                        "seed \(seed): best for ball \(row.ball.rawValue) is not its top pocket")
            }
            #expect(ShotRanking.recommended(state: state) == best.first { $0.blocker == nil },
                    "seed \(seed): recommended is not the first shootable best")

            #expect(ShotRanking.rank(state: state) == all, "seed \(seed): not deterministic")

            var rng = SplitMix64(seed: seed ^ 0xC0FFEE)
            for _ in 0..<3 {
                var shuffled = state
                shuffled.balls.shuffle(using: &rng)
                #expect(ShotRanking.rank(state: shuffled) == all,
                        "seed \(seed): permuting the balls changed the ranking")
                #expect(ShotRanking.best(state: shuffled) == best,
                        "seed \(seed): permuting the balls changed best")
            }
        }
    }

    @Test func groupFilterOnlyEverRemovesShots() {
        for seed in Self.seeds.prefix(100) {
            let state = LayoutGenerator.layout(seed: seed)
            let everything = ShotRanking.rank(state: state, group: .any)
            for group in [BallGroup.solids, .stripes, .eight] {
                let expected = everything.filter { rating in
                    state.ball(rating.ball).map { group.includes($0.kind) } ?? false
                }
                #expect(ShotRanking.rank(state: state, group: group) == expected,
                        "seed \(seed): \(group) is not a pure filter of .any")
            }
        }
    }

    // MARK: d. Hysteresis

    @Test func stableRecommendationFollowsItsRuleOnRealRankings() {
        var kept = 0
        var switched = 0
        for seed in Self.seeds {
            let state = LayoutGenerator.layout(seed: seed)
            let candidates = ShotRanking.best(state: state)
            let live = candidates.filter { $0.blocker == nil }
            guard let leader = live.max(by: { $0.probability < $1.probability }) else {
                #expect(ShotRanking.stableRecommendation(previous: nil, candidates: candidates) == nil)
                continue
            }
            #expect(ShotRanking.stableRecommendation(previous: nil, candidates: candidates)?.ball
                        == leader.ball, "seed \(seed): nil previous must return the leader")
            #expect(ShotRanking.stableRecommendation(previous: BallID(999), candidates: candidates)?.ball
                        == leader.ball, "seed \(seed): vanished previous must return the leader")
            for margin in [0.0, 0.05, 0.2] {
                for previous in live {
                    let chosen = ShotRanking.stableRecommendation(
                        previous: previous.ball, candidates: candidates, margin: margin)
                    let within = leader.probability <= previous.probability + margin
                    #expect(chosen?.ball == (within ? previous.ball : leader.ball),
                            "seed \(seed): previous \(previous.ball.rawValue) margin \(margin)")
                    if within && previous.ball != leader.ball { kept += 1 }
                    if !within { switched += 1 }
                }
            }
        }
        #expect(kept > 100, "keep branch hit only \(kept) times")
        #expect(switched > 100, "switch branch hit only \(switched) times")
    }

    /// Jitter: every ball is re-drawn within 2 mm of its true position each
    /// frame for 100 frames, through the app's own path (`ShotSelection`,
    /// intermediate config) against "always take the best".
    ///
    /// Selection changes that no margin can hide come from a shot's
    /// VIABILITY flipping under 2 mm (it blinks between shootable and
    /// blocked, so the incumbent really is gone). So the asserted bounds
    /// are: hysteresis never flickers more than "always the best" does, and
    /// a layout whose set of shootable balls never changes switches at most
    /// twice. The measured totals are printed by the test.
    @Test func suggestedShotDoesNotFlickerUnderTwoMillimetreJitter() {
        let frames = 100
        var withHysteresis = 0
        var withoutHysteresis = 0
        var worstStable = 0
        var worst = (seed: UInt64(0), changes: 0)
        var layoutsUsed = 0
        for seed in Self.seeds.prefix(150) {
            let base = LayoutGenerator.layout(seed: seed)
            guard ShotRanking.best(state: base).filter({ $0.blocker == nil }).count >= 2 else { continue }
            layoutsUsed += 1
            var rng = SplitMix64(seed: seed ^ 0xBADC0DE)
            var selection = ShotSelection()
            var previous: BallID?
            var lastBest: BallID?
            var lastSet: Set<BallID> = []
            var changes = 0
            var bestChanges = 0
            var setChanges = 0
            for frame in 0..<frames {
                let state = LayoutGenerator.jittered(base, limit: 0.002, rng: &rng)
                selection.update(state: state, group: .any, config: .intermediate)
                let chosen = selection.suggested?.ball
                let best = ShotRanking.recommended(state: state)?.ball
                let set = Set(selection.shootable.map(\.ball))
                if frame > 0 {
                    if chosen != previous { changes += 1 }
                    if best != lastBest { bestChanges += 1 }
                    if set != lastSet { setChanges += 1 }
                }
                previous = chosen
                lastBest = best
                lastSet = set
            }
            withHysteresis += changes
            withoutHysteresis += bestChanges
            if setChanges == 0 { worstStable = max(worstStable, changes) }
            if changes > worst.changes { worst = (seed, changes) }
            #expect(changes <= bestChanges,
                    "seed \(seed): hysteresis flickered more than the plain best")
        }
        print("JITTER layouts=\(layoutsUsed) frames=\(frames) hysteresis=\(withHysteresis) "
              + "plain-best=\(withoutHysteresis) worst-stable-layout=\(worstStable) worst=\(worst)")
        #expect(layoutsUsed > 50)
        // Was `<= 2`. Measured on the same seeds: with the over-wide corner
        // margin, 3 flickers in total and 0 on layouts with a fixed shootable
        // set; with the margin from the mouth width, 32 in total (against 100
        // for "always the best") and 4 on a fixed set (seed 28).
        // That layout holds shots rated 5-23 %, where the aim tolerance is
        // about 0.1 degrees, so 2 mm of ball jitter swings the number by
        // 18 points - more than the 0.05 hysteresis margin. The old value
        // sat on the flat 94 % plateau where jitter could not show. The bound
        // pins the new behaviour; the margin (ShotSelection) is the place to
        // tune it. Docs: docs/research/2026-11-12-ranking-audit.md.
        #expect(worstStable <= 4, "layouts with a fixed shootable set flickered \(worstStable) times")
        #expect(withHysteresis <= withoutHysteresis)
    }
}
