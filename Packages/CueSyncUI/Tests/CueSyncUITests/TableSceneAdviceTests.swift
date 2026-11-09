import CueSyncCore
import Foundation
import Testing
@testable import CueSyncUI

@Suite("TableScene advice")
struct TableSceneAdviceTests {
    private let state = TableState(table: Table(size: .nineFoot), balls: [
        Ball(id: BallID(0), kind: .cue, position: Vec2(0.5, -0.135)),
        Ball(id: BallID(5), kind: .solid(5), position: Vec2(1.0, 0.365))
    ])

    private var advice: TableScene.Advice {
        TableScene.Advice(cue: Vec2(0.5, -0.135), ghost: Vec2(0.9596, 0.3246),
                          target: Vec2(1.0, 0.365), pocket: Vec2(1.27, 0.635),
                          pocketRadius: Table.cornerCaptureRadius,
                          color: Theme.adviceEasy)
    }

    @Test func noAdviceMeansNoMark() {
        let scene = TableScene.compose(state: state,
                                       viewportWidth: 800, viewportHeight: 600)
        #expect(scene.advice == nil)
    }

    @Test func adviceMapsToViewSpaceWithYFlipped() throws {
        let scene = TableScene.compose(state: state, advice: advice,
                                       viewportWidth: 800, viewportHeight: 600)
        let mark = try #require(scene.advice)
        // Aim line runs from the cue ball's on-screen position to the ghost.
        #expect(mark.aimLine.count == 2)
        #expect(mark.aimLine[0] == scene.balls[0].center)
        // Cue ball is below the pocket in table space → LARGER view y.
        #expect(mark.aimLine[0].y > mark.pocketCenter.y)
        // Object line starts on the target ball and ends at the pocket.
        #expect(mark.objectLine[0] == scene.balls[1].center)
        #expect(mark.objectLine[1] == mark.pocketCenter)
        // Pocket mark coincides with the table's top-right pocket.
        let pocket = try #require(scene.pockets.first { $0.id == .cornerTopRight })
        #expect(mark.pocketCenter == pocket.center)
        #expect(mark.pocketRadius > pocket.radius)
        #expect(mark.color == Theme.adviceEasy)
    }

    @Test func ghostBallIsOneBallRadiusAtScale() throws {
        let scene = TableScene.compose(state: state, advice: advice,
                                       viewportWidth: 800, viewportHeight: 600)
        let mark = try #require(scene.advice)
        #expect(abs(mark.ghost.radius - Ball.standardRadius * scene.scale) < 1e-9)
        #expect(mark.ghost.isGhost)
        #expect(mark.targetRingRadius > mark.ghost.radius)
    }

    @Test func adviceParticipatesInSceneEquality() {
        let plain = TableScene.compose(state: state,
                                       viewportWidth: 800, viewportHeight: 600)
        let advised = TableScene.compose(state: state, advice: advice,
                                         viewportWidth: 800, viewportHeight: 600)
        #expect(plain != advised)
    }

    @Test func difficultyTokensAreDistinct() {
        let colors = [Theme.adviceEasy, Theme.adviceMedium, Theme.adviceHard]
        #expect(Set(colors.map(\.rgb)).count == 3)
    }

    @Test func adviceLineIsDistinctFromEveryLivePredictionColor() {
        let live = [Theme.cueAmber, Theme.feltGreen, Theme.chalkBlue, Theme.warnCoral]
        #expect(!live.contains { $0.rgb == Theme.adviceLine.rgb })
    }
}
