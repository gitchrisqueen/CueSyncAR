//
//  ShotPlannerPropertyTests.swift
//  CoachKitTests
//
//  Property tests for ShotPlanner over seeded random legal layouts. Every
//  failure message carries its seed, so a counterexample can be replayed.
//

import BilliardsPhysics
import CueSyncCore
import Foundation
import Testing
@testable import CoachKit

// MARK: - Deterministic randomness

/// SplitMix64: tiny, fast, fully deterministic across platforms.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1) from the top 53 bits (no platform-specific path).
    mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    mutating func uniform(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * unit()
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
}

enum LayoutGenerator {
    static let table = Table(size: .nineFoot)

    /// A random LEGAL layout: 2-16 balls (or exactly `count`) including one cue ball (id 0), every
    /// center at least one radius inside the play field, no two balls closer
    /// than a diameter + 0.1 mm.
    static func layout(seed: UInt64, count fixedCount: Int? = nil) -> TableState {
        var rng = SplitMix64(seed: seed)
        let count = fixedCount ?? rng.int(2...16)
        let radius = Ball.standardRadius
        let half = table.halfExtents
        var balls: [Ball] = []
        var attempts = 0
        while balls.count < count && attempts < 5_000 {
            attempts += 1
            let position = Vec2(rng.uniform(-(half.x - radius), half.x - radius),
                                rng.uniform(-(half.y - radius), half.y - radius))
            let clear = balls.allSatisfy {
                $0.position.distance(to: position) >= 2 * radius + 1e-4
            }
            guard clear else { continue }
            let number = balls.count
            let kind: Ball.Kind = number == 0 ? .cue
                : (number < 8 ? .solid(number)
                   : (number == 8 ? .eight : .stripe(number)))
            balls.append(Ball(id: BallID(number), kind: kind, position: position))
        }
        return TableState(table: table, balls: balls)
    }

    static func isLegal(_ state: TableState) -> Bool {
        let radius = Ball.standardRadius
        for (i, ball) in state.balls.enumerated() {
            guard state.table.contains(ball.position, ballRadius: radius) else { return false }
            for other in state.balls[(i + 1)...]
                where ball.position.distance(to: other.position) < 2 * radius + 1e-4 {
                return false
            }
        }
        return state.balls.filter { $0.kind == .cue }.count == 1
    }
}

/// Point-to-segment distance, written independently of the planner's helper.
func segmentDistance(from p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    if lengthSquared < 1e-18 { return hypot(p.x - a.x, p.y - a.y) }
    var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared
    t = Swift.min(1, Swift.max(0, t))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

// MARK: - Properties

@Suite("ShotPlanner properties")
struct ShotPlannerPropertyTests {
    /// 300 fixed seeds: each one is a layout, and a failing message names it.
    static let seeds: [UInt64] = Array(1...300)
    private let unlimited = ShotPlanner.Config(maxOptions: 1_000)

    /// Hit-ball radius sums use the same standard radius throughout.
    private let radius = Ball.standardRadius

    @Test func generatorProducesLegalLayouts() {
        for seed in Self.seeds {
            let state = LayoutGenerator.layout(seed: seed)
            #expect(LayoutGenerator.isLegal(state), "seed \(seed) produced an illegal layout")
            #expect((2...16).contains(state.balls.count), "seed \(seed) ball count")
        }
    }

    // MARK: a. Solver replay

    /// Cue speed for the replay: 4.0 m/s, the top of the 2.5-4 m/s range.
    /// The planner has no power model, so the only fair premise is "enough
    /// speed to arrive". Measured over seeds 1...300 (1,804 options) the
    /// share of options that do NOT drop in the solver, before the
    /// pocket-lane fix (1,813 options), was 17.8% at 2.5 m/s, 11.4% at 3.0,
    /// 6.9% at 3.5 and 3.9% at 4.0. After the fix it is 68 of 1,804 (3.8%)
    /// at 4.0. Firmer is fairer to the planner, which has no power model.
    /// The solver's 8-event budget is not a factor (raising `maxEvents`
    /// to 64 changed no result).
    static let replaySpeed = 4.0

    enum Verdict: String, CaseIterable {
        case potted
        /// The object ball, launched at the speed the solver gives it,
        /// cannot roll as far as the pocket. Soft power, not a planner bug.
        case underpowered
        /// The object ball already sits inside the pocket's capture circle.
        /// The solver only pockets a ball whose path ENTERS the circle, so
        /// a ball that starts inside never drops.
        case startsInsideCaptureCircle
        /// The solver rolls balls one after another against a static
        /// snapshot ("moving-vs-moving not modeled"). The cue ball goes
        /// first, comes to rest in the object ball's lane, and the object
        /// ball then "hits" it. In play the object ball is long gone.
        case cueRestsInObjectLane
        case unexplained
    }

    /// Solver replay plus classification of why a shot did not drop. Every
    /// explanation is checked against independent numbers, never assumed.
    static func replay(_ option: ShotOption, in state: TableState,
                       solver: AnalyticSolver) -> Verdict {
        let prediction = solver.predict(
            state: state, aim: option.aim,
            options: SolverOptions(initialSpeed: replaySpeed))
        if prediction.pocketedBalls.contains(option.target) { return .potted }

        // Analytic reach of the object ball after contact (equal-mass stun
        // model from AnalyticSolver: speed * cos(cut) * restitution).
        let config = solver.config
        let hitSquared = replaySpeed * replaySpeed
            - 2 * config.rollingDeceleration * option.cueDistance
        let launch = hitSquared > 0
            ? hitSquared.squareRoot() * cos(option.cutAngleDegrees * .pi / 180)
                * config.ballBallRestitution
            : 0
        let reach = launch * launch / (2 * config.rollingDeceleration)
        if reach < option.pocketDistance { return .underpowered }

        if option.pocketDistance < option.pocketCaptureRadius {
            return .startsInsideCaptureCircle
        }

        // Cue ball final resting spot inside the object lane?
        for event in prediction.events {
            if case .rest(let ball, let point) = event, ball == state.cueBall?.id {
                let lane = segmentDistance(from: point, option.targetPosition,
                                           option.pocketPosition)
                if lane < 2 * Ball.standardRadius { return .cueRestsInObjectLane }
            }
        }
        return .unexplained
    }

    /// Measured at seeds 1...300, post-fix, 4.0 m/s: 1,804 options; 1,736
    /// drop (96.2%); 68 do not: 43 underpowered, 1 starts inside the capture
    /// circle, 24 cue-rests-in-object-lane, 0 unexplained. Before the
    /// pocket-lane fix there were also 2 unexplained scratches (the cue
    /// ball's lane ran through a side-pocket mouth, so the solver pocketed
    /// the cue ball); that was a real planner bug and is now rejected.
    @Test func everyPlannedShotDropsInTheSolverUnlessAnExplainedPremiseFails() {
        let solver = AnalyticSolver()
        var counts: [Verdict: Int] = [:]
        for seed in Self.seeds {
            let state = LayoutGenerator.layout(seed: seed)
            for option in ShotPlanner.plan(state: state, config: unlimited) {
                let verdict = Self.replay(option, in: state, solver: solver)
                counts[verdict, default: 0] += 1
                #expect(verdict != .unexplained,
                        "seed \(seed): \(option.id) cut \(option.cutAngleDegrees)° did not drop")
            }
        }
        let total = counts.values.reduce(0, +)
        print("REPLAY options=\(total) "
              + Verdict.allCases.map { "\($0.rawValue)=\(counts[$0, default: 0])" }
                  .joined(separator: " "))
        #expect(total > 1_000, "too few options to mean anything: \(total)")
        // The premise-holding majority must be the potted ones.
        #expect(Double(counts[.potted, default: 0]) / Double(total) > 0.9)
    }

    // MARK: Pocket lanes (regression for the planner fix)

    private func twoBalls(cue: Vec2, target: Vec2) -> TableState {
        TableState(table: LayoutGenerator.table, balls: [
            Ball(id: BallID(0), kind: .cue, position: cue),
            Ball(id: BallID(5), kind: .solid(5), position: target)
        ])
    }

    @Test func cueLaneThroughASidePocketMouthIsRejected() {
        // Cue and target hug the top rail; the lane crosses x = 0 about
        // 0.046 m from the side-pocket center (capture radius 0.058), so the
        // cue ball would scratch before it reached the ghost ball.
        let state = twoBalls(cue: Vec2(-0.5, 0.60), target: Vec2(0.5, 0.58))
        let plan = ShotPlanner.plan(state: state, config: unlimited)
        #expect(!plan.contains { $0.pocket == .cornerTopRight })

        // Same target and pocket from a clear lane is still offered.
        let clear = twoBalls(cue: Vec2(0.0, 0.1), target: Vec2(0.5, 0.58))
        let clearPlan = ShotPlanner.plan(state: clear, config: unlimited)
        #expect(clearPlan.contains { $0.pocket == .cornerTopRight })
    }

    @Test func noLaneRunsThroughAPocketMouthExceptTheIntendedOne() {
        for seed in Self.seeds {
            let state = LayoutGenerator.layout(seed: seed)
            guard let cue = state.cueBall else { continue }
            for option in ShotPlanner.plan(state: state, config: unlimited) {
                for pocket in state.table.pockets {
                    let cueLane = segmentDistance(from: pocket.position, cue.position,
                                                  option.ghostBall)
                    #expect(cueLane >= pocket.captureRadius,
                            "seed \(seed): \(option.id) cue lane enters \(pocket.id)")
                    if pocket.id != option.pocket {
                        let objectLane = segmentDistance(from: pocket.position,
                                                         option.targetPosition,
                                                         option.pocketPosition)
                        #expect(objectLane >= pocket.captureRadius,
                                "seed \(seed): \(option.id) object lane enters \(pocket.id)")
                    }
                }
            }
        }
    }

    // MARK: b. Lanes are clear (independent re-derivation)

    @Test func noReturnedOptionHasABlockedLane() {
        var checked = 0
        for seed in Self.seeds {
            let state = LayoutGenerator.layout(seed: seed)
            guard let cue = state.cueBall else { continue }
            for option in ShotPlanner.plan(state: state, config: unlimited) {
                guard let target = state.ball(option.target) else {
                    Issue.record("seed \(seed): option names a ball that is not on the table")
                    continue
                }
                #expect(option.targetPosition == target.position, "seed \(seed) \(option.id)")
                for other in state.balls where other.id != cue.id && other.id != target.id {
                    let cueLane = segmentDistance(from: other.position, cue.position,
                                                  option.ghostBall)
                    #expect(cueLane >= other.radius + cue.radius - 1e-4,
                            "seed \(seed): \(option.id) cue lane blocked by ball \(other.id.rawValue)")
                    let objectLane = segmentDistance(from: other.position, target.position,
                                                     option.pocketPosition)
                    #expect(objectLane >= other.radius + target.radius - 1e-4,
                            "seed \(seed): \(option.id) object lane blocked by ball \(other.id.rawValue)")
                }
                checked += 1
            }
        }
        #expect(checked > 1_000, "too few options checked: \(checked)")
    }

    // MARK: c. Ordering and determinism

    @Test func planIsSortedCappedDeterministicAndOrderIndependent() {
        for seed in Self.seeds {
            let state = LayoutGenerator.layout(seed: seed)
            let all = ShotPlanner.plan(state: state, config: unlimited)

            // Ascending difficulty, ties broken by ascending id.
            for (a, b) in zip(all, all.dropFirst()) {
                let ordered = a.difficulty < b.difficulty
                    || (a.difficulty == b.difficulty && a.id < b.id)
                #expect(ordered, "seed \(seed): \(a.id) before \(b.id) is out of order")
            }
            #expect(Set(all.map(\.id)).count == all.count, "seed \(seed): duplicate ids")

            // maxOptions caps and keeps the best prefix.
            for cap in [0, 1, 3, 5, 100] {
                let capped = ShotPlanner.plan(state: state,
                                              config: ShotPlanner.Config(maxOptions: cap))
                #expect(capped.count <= cap, "seed \(seed): cap \(cap) gave \(capped.count)")
                #expect(capped == Array(all.prefix(cap)), "seed \(seed): cap \(cap) prefix")
            }

            // Same input, same output.
            #expect(ShotPlanner.plan(state: state, config: unlimited) == all,
                    "seed \(seed): plan is not deterministic")

            // Input ball order is irrelevant.
            var rng = SplitMix64(seed: seed ^ 0xC0FFEE)
            for _ in 0..<3 {
                var shuffled = state
                shuffled.balls.shuffle(using: &rng)
                #expect(ShotPlanner.plan(state: shuffled, config: unlimited) == all,
                        "seed \(seed): permuting the balls changed the plan")
            }
        }
    }

    // MARK: d. Hysteresis

    @Test func selectionFollowsTheHysteresisRuleOnRealPlans() {
        var kept = 0
        var switched = 0
        for seed in Self.seeds {
            let state = LayoutGenerator.layout(seed: seed)
            let options = ShotPlanner.plan(state: state, config: unlimited)
            guard let best = options.first else {
                #expect(ShotPlanner.select(previous: nil, among: options) == nil)
                continue
            }
            #expect(ShotPlanner.select(previous: nil, among: options)?.id == best.id,
                    "seed \(seed): nil previous must return best")
            #expect(ShotPlanner.select(previous: "no-such-option", among: options)?.id == best.id,
                    "seed \(seed): vanished previous must return best")
            for margin in [0.0, 0.08, 0.2] {
                for previous in options {
                    let chosen = ShotPlanner.select(previous: previous.id, among: options,
                                                    margin: margin)
                    let within = previous.difficulty - best.difficulty <= margin
                    #expect(chosen?.id == (within ? previous.id : best.id),
                            "seed \(seed): previous \(previous.id) margin \(margin)")
                    if within && previous.id != best.id { kept += 1 }
                    if !within { switched += 1 }
                }
            }
        }
        // Both branches were really exercised.
        #expect(kept > 100, "keep branch hit only \(kept) times")
        #expect(switched > 100, "switch branch hit only \(switched) times")
    }

    /// Moves every ball by a random vector no longer than `limit` meters,
    /// retrying so each frame stays a legal layout (as detections would).
    static func jittered(_ base: TableState, limit: Double,
                         rng: inout SplitMix64) -> TableState {
        for _ in 0..<50 {
            var frame = base
            for index in frame.balls.indices {
                let angle = rng.uniform(0, 2 * .pi)
                let magnitude = rng.uniform(0, limit)
                frame.balls[index].position += Vec2(cos(angle), sin(angle)) * magnitude
            }
            if LayoutGenerator.isLegal(frame) { return frame }
        }
        return base
    }

    /// Jitter: every ball moves by at most 2 mm per frame (re-drawn each
    /// frame around its true position) for 100 frames. Measured over 143
    /// layouts that offer at least two options: 54 selection changes in
    /// total with hysteresis versus 178 for "always take the best". The
    /// remaining flicker comes from options whose VIABILITY flips under
    /// 2 mm, which no ranking margin can hide: the worst layout (seed 7)
    /// changed its selection 44 times because ball 12 sits 0.44 mm outside
    /// the 8-ball's pocket lane, so that shot blinks in and out. The
    /// asserted bounds follow from that mechanism:
    /// - a layout whose option set never changes selects at most 2 times
    ///   (measured: 0);
    /// - in every layout, selection changes never exceed the number of
    ///   frames in which the option set changed, plus 2.
    @Test func selectedShotDoesNotFlickerUnderTwoMillimetreJitter() {
        let frames = 100
        var totalWithHysteresis = 0
        var totalWithout = 0
        var worstStable = 0
        var worstUnstable = (seed: UInt64(0), changes: 0, setChanges: 0)
        var layoutsUsed = 0
        for seed in Self.seeds.prefix(150) {
            let base = LayoutGenerator.layout(seed: seed)
            guard ShotPlanner.plan(state: base, config: unlimited).count >= 2 else { continue }
            layoutsUsed += 1
            var rng = SplitMix64(seed: seed ^ 0xBADC0DE)
            var previous: String?
            var lastBest: String?
            var lastSet: Set<String> = []
            var changes = 0
            var bestChanges = 0
            var setChanges = 0
            for frame in 0..<frames {
                let state = Self.jittered(base, limit: 0.002, rng: &rng)
                // The app's own call: default config, then hysteresis.
                let options = ShotPlanner.plan(state: state)
                let chosen = ShotPlanner.select(previous: previous, among: options)?.id
                let best = options.first?.id
                let set = Set(options.map(\.id))
                if frame > 0 {
                    if chosen != previous { changes += 1 }
                    if best != lastBest { bestChanges += 1 }
                    if set != lastSet { setChanges += 1 }
                }
                previous = chosen
                lastBest = best
                lastSet = set
            }
            totalWithHysteresis += changes
            totalWithout += bestChanges
            if setChanges == 0 { worstStable = Swift.max(worstStable, changes) }
            if changes > worstUnstable.changes {
                worstUnstable = (seed, changes, setChanges)
            }
            #expect(changes <= setChanges + 2,
                    "seed \(seed): \(changes) selection changes but only \(setChanges) option-set changes")
        }
        print("JITTER layouts=\(layoutsUsed) frames=\(frames) hysteresis total=\(totalWithHysteresis) "
              + "no-hysteresis total=\(totalWithout) worst-stable=\(worstStable) "
              + "worst-layout=\(worstUnstable)")
        #expect(layoutsUsed > 50)
        #expect(worstStable <= 2, "stable layouts flickered \(worstStable) times")
        #expect(totalWithHysteresis <= totalWithout,
                "hysteresis made flicker worse: \(totalWithHysteresis) vs \(totalWithout)")
    }
}
