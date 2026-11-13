import CueSyncCore
import Testing
@testable import CoachKit

@Suite("The true reason a shot is blocked")
struct BlockedReasonTests {

    private func table(_ balls: [Ball]) -> TableState {
        TableState(table: Table(size: .nineFoot), balls: balls, timestamp: 0)
    }

    private func name(_ id: BallID) -> String { "ball \(id.rawValue)" }

    @Test("A ball sitting on the line is the reason, not a pocket behind the ball")
    func theBlockerOnTheLine() {
        // Cue ball, a ball directly in front of it, and the ball behind that.
        let state = table([
            Ball(id: BallID(0), kind: .cue, position: Vec2(-0.9, 0)),
            Ball(id: BallID(2), kind: .solid(2), position: Vec2(-0.5, 0)),
            Ball(id: BallID(4), kind: .solid(4), position: Vec2(0.2, 0.05)),
        ])
        let ratings = ShotRanking.rank(state: state).filter { $0.ball == BallID(4) }
        #expect(!ratings.isEmpty)
        #expect(ratings.allSatisfy { $0.blocker != nil })

        // What the card used to show: the first pocket by id, whatever its reason.
        let first = ShotRanking.best(state: state).first { $0.ball == BallID(4) }
        #expect(first != nil)

        let text = BlockedReason.reason(forBall: ratings, name: name)
        #expect(text == "ball 2 is in the cue ball's way", "\(text)")
        // And it is not the arbitrary pocket's "past 90°".
        #expect(!text.contains("90"))
    }

    @Test("A ball with no pocket in front of it says there is no angle")
    func noAngleAnywhere() {
        // The ball is tight against the head rail with the cue ball behind it
        // and every pocket either behind it or across its mouth.
        let state = table([
            Ball(id: BallID(0), kind: .cue, position: Vec2(1.1, 0.0)),
            Ball(id: BallID(4), kind: .solid(4), position: Vec2(-1.2, 0.0)),
        ])
        let ratings = ShotRanking.rank(state: state).filter { $0.ball == BallID(4) }
        let physical = ratings.contains {
            switch $0.blocker {
            case .cuePath?, .objectPath?, .cueScratch?, .pocketInTheWay?: true
            default: false
            }
        }
        if !physical {
            #expect(BlockedReason.reason(forBall: ratings, name: name) == "No angle to any pocket")
        }
    }

    @Test("One pocket: that pocket's own blocker, in words")
    func onePocket() {
        func rating(_ blocker: ShotRating.Blocker) -> ShotRating {
            ShotRating(ball: BallID(4), pocket: .cornerTopRight, probability: 0, difficulty: .blocked,
                       cutAngleDegrees: 30, cueTravel: 1, objectTravel: 1, aimTolerance: 0,
                       ghostBall: .zero, blocker: blocker)
        }
        #expect(BlockedReason.reason(for: rating(.cuePath(BallID(2))), name: name)
                == "ball 2 is in the cue ball's way")
        #expect(BlockedReason.reason(for: rating(.objectPath(BallID(9))), name: name)
                == "ball 9 is between it and the pocket")
        #expect(BlockedReason.reason(for: rating(.cutTooThin), name: name) == "No angle to that pocket")
        #expect(BlockedReason.reason(for: rating(.pocketFacingAway), name: name) == "No angle to that pocket")
        #expect(BlockedReason.reason(for: rating(.cueScratch(.sideTop)), name: name)
                == "The cue ball would drop in a pocket first")
        #expect(BlockedReason.reason(for: rating(.pocketInTheWay(.sideTop)), name: name)
                == "It would drop in a different pocket")
    }

    @Test("Of several obstructed pockets, the one the ball comes closest to making")
    func closestPocket() {
        func rating(_ pocket: PocketID, cut: Double, _ blocker: ShotRating.Blocker) -> ShotRating {
            ShotRating(ball: BallID(4), pocket: pocket, probability: 0, difficulty: .blocked,
                       cutAngleDegrees: cut, cueTravel: 1, objectTravel: 1, aimTolerance: 0,
                       ghostBall: .zero, blocker: blocker)
        }
        let ratings = [rating(.cornerTopLeft, cut: 100, .cutTooThin),
                       rating(.sideTop, cut: 55, .cuePath(BallID(7))),
                       rating(.cornerTopRight, cut: 25, .objectPath(BallID(3)))]
        #expect(BlockedReason.reason(forBall: ratings, name: name) == "ball 3 is between it and the pocket")
    }
}
