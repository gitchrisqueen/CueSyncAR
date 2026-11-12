import CueSyncCore
import Foundation
import Testing
@testable import CoachKit

@Suite("ShotSelection")
struct ShotSelectionTests {
    private let cueID = BallID(0)
    private let table = Table(size: .eightFoot)

    /// Cue ball on the left, three object balls at decreasing quality:
    /// `near` hangs by a corner, `mid` is out in the open, `far` is a long
    /// way from anything.
    private let near = BallID(1), mid = BallID(2), far = BallID(3)

    private func state(balls extra: [Ball] = []) -> TableState {
        let he = table.halfExtents
        return TableState(table: table, balls: [
            Ball(id: cueID, kind: .cue, position: Vec2(-0.7, -0.1)),
            Ball(id: near, kind: .solid(1), position: Vec2(-he.x + 0.30, -he.y + 0.24)),
            Ball(id: mid, kind: .solid(2), position: Vec2(0.10, 0.15)),
            Ball(id: far, kind: .stripe(11), position: Vec2(0.85, -0.02))
        ] + extra, timestamp: 0)
    }

    private func selection(group: BallGroup = .any) -> ShotSelection {
        var s = ShotSelection()
        s.update(state: state(), group: group, config: .intermediate)
        return s
    }

    // MARK: - Ranking

    @Test("Updating ranks every ball and suggests the best")
    func updatesAndSuggests() throws {
        let s = selection()
        #expect(s.ranking.count == 3)
        let suggested = try #require(s.suggested)
        #expect(suggested.ball == near, "the ball by the corner should be suggested")
        #expect(s.active?.ball == suggested.ball)
        #expect(!s.isPlayerChosen)
    }

    @Test("Without a cue ball there is nothing to offer")
    func noCueBallClearsEverything() {
        var s = selection()
        #expect(!s.ranking.isEmpty)
        let orphaned = TableState(table: table, balls: [
            Ball(id: mid, kind: .solid(2), position: Vec2(0.1, 0.15))
        ], timestamp: 1)
        s.update(state: orphaned, group: .any, config: .intermediate)
        #expect(s.ranking.isEmpty)
        #expect(s.suggested == nil)
        #expect(s.active == nil)
    }

    @Test("A group filters what is offered")
    func groupFilters() {
        #expect(Set(selection(group: .solids).ranking.map(\.ball)) == [near, mid])
        #expect(Set(selection(group: .stripes).ranking.map(\.ball)) == [far])
        #expect(selection(group: .eight).ranking.isEmpty)
    }

    @Test("shootable() hides blocked shots but ranking keeps them")
    func shootableExcludesBlocked() {
        // Wall a ball in so every pocket from it is blocked.
        var s = ShotSelection()
        let walled = state(balls: [
            Ball(id: BallID(20), kind: .solid(5), position: Vec2(0.85, 0.04)),
            Ball(id: BallID(21), kind: .solid(6), position: Vec2(0.85, -0.08)),
            Ball(id: BallID(22), kind: .solid(7), position: Vec2(0.79, -0.02))
        ])
        s.update(state: walled, group: .any, config: .intermediate)
        #expect(s.shootable.allSatisfy { $0.blocker == nil })
        #expect(s.shootable.count <= s.ranking.count)
        #expect(s.suggested?.blocker == nil)
    }

    // MARK: - Choosing

    @Test("Tapping a ball makes it the target and overrides the suggestion")
    func tapSelects() throws {
        var s = selection()
        #expect(s.suggested?.ball == near)
        let choice = s.chooseTarget(near: Vec2(0.10, 0.15), in: state())
        guard case .selected(let rating) = choice else {
            Issue.record("expected a selection, got \(choice)"); return
        }
        #expect(rating.ball == mid)
        #expect(s.target == mid)
        #expect(s.active?.ball == mid)
        #expect(s.isPlayerChosen)
        // The suggestion itself is untouched — it is still what the app
        // would say if the player let go.
        #expect(s.suggested?.ball == near)
    }

    @Test("Tapping the target again gives it back to the app")
    func tapReleases() {
        var s = selection()
        _ = s.chooseTarget(near: Vec2(0.10, 0.15), in: state())
        #expect(s.target == mid)
        #expect(s.chooseTarget(near: Vec2(0.10, 0.15), in: state()) == .released)
        #expect(s.target == nil)
        #expect(s.active?.ball == near)
        #expect(!s.isPlayerChosen)
    }

    @Test("A tap on empty cloth is reported as a miss, never swallowed")
    func tapMissesCleanly() {
        var s = selection()
        #expect(s.chooseTarget(near: Vec2(0.5, 0.5), in: state(), maxDistance: 0.1) == .missed)
        #expect(s.target == nil)
        var empty = ShotSelection()
        #expect(empty.chooseTarget(near: .zero, in: state()) == .missed)
    }

    @Test("The nearest ball wins a tap between two")
    func tapPicksTheNearest() throws {
        var s = selection()
        let between = (Vec2(0.10, 0.15) + Vec2(0.85, -0.02)) * 0.5
        let nudgedTowardMid = between + (Vec2(0.10, 0.15) - between).normalized * 0.12
        let choice = s.chooseTarget(near: nudgedTowardMid, in: state(), maxDistance: 0.5)
        guard case .selected(let rating) = choice else {
            Issue.record("expected a selection, got \(choice)"); return
        }
        #expect(rating.ball == mid)
    }

    // MARK: - Holding on across frames

    @Test("The player's pick survives ordinary re-ranking")
    func pickSurvivesUpdates() {
        var s = selection()
        _ = s.chooseTarget(near: Vec2(0.10, 0.15), in: state())
        for _ in 0..<5 {
            s.update(state: state(), group: .any, config: .intermediate)
        }
        #expect(s.target == mid)
        #expect(s.active?.ball == mid)
    }

    @Test("A pick that leaves the table is released rather than mislabelled")
    func pickReleasedWhenTheBallGoes() {
        var s = selection()
        _ = s.chooseTarget(near: Vec2(0.10, 0.15), in: state())
        #expect(s.target == mid)
        let potted = TableState(table: table, balls: state().balls.filter { $0.id != mid },
                                timestamp: 2)
        s.update(state: potted, group: .any, config: .intermediate)
        #expect(s.target == nil, "showing the app's suggestion under the player's label is worse")
        #expect(s.isPlayerChosen == false)
        #expect(s.active?.ball == near)
    }

    @Test("A pick outside the chosen group is released when the group changes")
    func pickReleasedOnGroupChange() {
        var s = selection()
        _ = s.chooseTarget(near: Vec2(0.85, -0.02), in: state())
        #expect(s.target == far)      // a stripe
        s.update(state: state(), group: .solids, config: .intermediate)
        #expect(s.target == nil)
    }

    @Test("The suggestion does not flicker between two near-equal shots")
    func suggestionHoldsUnderJitter() throws {
        // Two balls deliberately close in quality; jitter their positions
        // by a couple of millimetres and confirm the suggestion sits still.
        let he = table.halfExtents
        var s = ShotSelection()
        func jittered(_ n: Int) -> TableState {
            let wobble = Double(n % 3) * 0.002 - 0.002
            return TableState(table: table, balls: [
                Ball(id: cueID, kind: .cue, position: Vec2(-0.7, -0.1)),
                Ball(id: near, kind: .solid(1),
                     position: Vec2(-he.x + 0.30 + wobble, -he.y + 0.24)),
                Ball(id: mid, kind: .solid(2),
                     position: Vec2(-he.x + 0.30, he.y - 0.24 - wobble))
            ], timestamp: TimeInterval(n))
        }
        s.update(state: jittered(0), group: .any, config: .intermediate)
        let first = try #require(s.suggested?.ball)
        for n in 1..<30 {
            s.update(state: jittered(n), group: .any, config: .intermediate)
            #expect(s.suggested?.ball == first, "suggestion moved on frame \(n)")
        }
    }

    /// The fixture without its best ball, so something else is suggested.
    private func stateWithoutNear(timestamp: TimeInterval = 0) -> TableState {
        TableState(table: table, balls: state().balls.filter { $0.id != near },
                   timestamp: timestamp)
    }

    @Test("A better shot must stay ahead for switchDwell updates before it takes over")
    func betterShotNeedsToPersist() throws {
        var s = ShotSelection()
        s.update(state: stateWithoutNear(), group: .any, config: .intermediate)
        let incumbent = try #require(s.suggested?.ball)
        #expect(incumbent != near)

        // The best ball appears. The old suggestion can still be played, so
        // it holds until the newcomer has led switchDwell times in a row.
        let ranked = ShotRanking.best(state: state(), group: .any, config: .intermediate)
        let leader = try #require(ranked.first { $0.ball == near })
        let held = try #require(ranked.first { $0.ball == incumbent })
        try #require(held.blocker == nil, "fixture: the old suggestion must stay playable")
        try #require(leader.probability > held.probability + 0.05,
                     "fixture: the newcomer must clear the hysteresis margin")
        try #require(ShotSelection.switchDwell >= 2)

        for n in 1..<ShotSelection.switchDwell {
            s.update(state: state(), group: .any, config: .intermediate)
            #expect(s.suggested?.ball == incumbent, "switched after only \(n) update(s)")
        }
        s.update(state: state(), group: .any, config: .intermediate)
        #expect(s.suggested?.ball == near)
    }

    @Test("A lead that lapses starts the count again")
    func interruptedLeadDoesNotSwitch() throws {
        var s = ShotSelection()
        s.update(state: stateWithoutNear(), group: .any, config: .intermediate)
        let incumbent = try #require(s.suggested?.ball)
        // Lead, lapse, lead, lapse: never switchDwell updates in a row.
        for round in 0..<4 {
            for _ in 1..<ShotSelection.switchDwell {
                s.update(state: state(), group: .any, config: .intermediate)
            }
            s.update(state: stateWithoutNear(), group: .any, config: .intermediate)
            #expect(s.suggested?.ball == incumbent, "switched in round \(round)")
        }
    }

    @Test("A suggestion that can no longer be played is replaced at once")
    func goneSuggestionSwitchesImmediately() throws {
        var s = selection()
        #expect(s.suggested?.ball == near)
        s.update(state: stateWithoutNear(timestamp: 1), group: .any, config: .intermediate)
        let next = try #require(s.suggested?.ball)
        #expect(next != near)
    }

    // MARK: - Copy

    @Test("A blocked shot says what is wrong instead of reading zero per cent")
    func blockedShotsExplainThemselves() {
        let base = ShotRating(ball: near, pocket: .sideTop, probability: 0, difficulty: .blocked,
                              cutAngleDegrees: 20, cueTravel: 0.5, objectTravel: 0.5,
                              aimTolerance: 0, ghostBall: .zero, blocker: .cuePath(mid))
        #expect(base.headline.contains("cue ball's way"))
        var objectBlocked = base
        objectBlocked.blocker = .objectPath(mid)
        #expect(objectBlocked.headline.contains("between it and the pocket"))
        var thin = base
        thin.blocker = .cutTooThin
        #expect(thin.headline.contains("90"))
        var clear = base
        clear.blocker = nil
        clear.probability = 0.62
        #expect(clear.headline == "62% into the top side")
        #expect(!clear.headline.contains("Blocked"))
    }

    @Test("Every pocket has a name a person would say out loud")
    func pocketsAreSpeakable() {
        let names = Set(PocketID.allCases.map(\.spokenName))
        #expect(names.count == PocketID.allCases.count)
        #expect(names.allSatisfy { !$0.isEmpty && $0.lowercased() == $0 })
        #expect(PocketID.sideBottom.spokenName == "bottom side")
    }
}
