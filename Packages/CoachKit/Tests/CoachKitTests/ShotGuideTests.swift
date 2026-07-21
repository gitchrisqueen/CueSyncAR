import CueSyncCore
import Foundation
import Testing
@testable import CoachKit

@Suite("ShotGuide")
struct ShotGuideTests {
    private let cueID = BallID(0)
    private let objectID = BallID(3)

    private func state(withCue: Bool = true) -> TableState {
        var balls: [Ball] = [
            Ball(id: objectID, kind: .solid(3), position: Vec2(0.5, 0),
                 confidence: 0.9)
        ]
        if withCue {
            balls.append(Ball(id: cueID, kind: .cue, position: .zero,
                              confidence: 0.9))
        }
        return TableState(table: Table(size: .nineFoot), balls: balls,
                          timestamp: 0)
    }

    /// Contact at (0.4, 0); struck ball departs at `angleDegrees` from the
    /// cue ball's straight-line approach (+x).
    private func prediction(departureAngleDegrees: Double,
                            scratch: Bool = false) -> ShotPrediction {
        let contact = Vec2(0.4, 0)
        let radians = departureAngleDegrees * .pi / 180
        let departure = Vec2(cos(radians), sin(radians)) * 0.3
        var events: [CollisionEvent] = [
            .ballBall(moving: cueID, struck: objectID, contact: contact)
        ]
        var pocketed: [BallID] = []
        if scratch {
            events.append(.pocket(ball: cueID, pocket: .cornerTopRight))
            pocketed.append(cueID)
        }
        return ShotPrediction(
            segments: [
                TrajectorySegment(ballID: cueID, start: .zero, end: contact),
                TrajectorySegment(ballID: objectID, start: Vec2(0.5, 0),
                                  end: Vec2(0.5, 0) + departure)
            ],
            events: events,
            pocketedBalls: pocketed)
    }

    @Test func scratchRecommendsDraw() {
        let guide = ShotGuide.recommend(state: state(),
                                        prediction: prediction(departureAngleDegrees: 30,
                                                               scratch: true))
        #expect(guide.spin == .draw)
        #expect(guide.tipOffset.y < 0)
        #expect(guide.headline.contains("scratch") || guide.headline.contains("Draw"))
    }

    @Test func nearStraightRecommendsStun() {
        let guide = ShotGuide.recommend(state: state(),
                                        prediction: prediction(departureAngleDegrees: 5))
        #expect(guide.spin == .stun)
        #expect(guide.tipOffset.y < 0)
        let cut = guide.cutAngleDegrees
        #expect(cut != nil && cut! <= 15)
    }

    @Test func thinCutRecommendsSimpleCenter() {
        let guide = ShotGuide.recommend(state: state(),
                                        prediction: prediction(departureAngleDegrees: 75))
        #expect(guide.spin == .center)
        #expect(guide.tipOffset == .zero)
        #expect(guide.headline.lowercased().contains("thin"))
    }

    @Test func mediumCutRecommendsCenter() {
        let guide = ShotGuide.recommend(state: state(),
                                        prediction: prediction(departureAngleDegrees: 35))
        #expect(guide.spin == .center)
        #expect(guide.tipOffset == .zero)
        #expect(guide.cutAngleDegrees != nil)
    }

    @Test func noContactAndNoCueBallDegradeHonestly() {
        let noContact = ShotGuide.recommend(state: state(),
                                            prediction: ShotPrediction())
        #expect(noContact.spin == .center)
        #expect(noContact.cutAngleDegrees == nil)

        let noCue = ShotGuide.recommend(state: state(withCue: false),
                                        prediction: ShotPrediction())
        #expect(noCue.headline == "Find the cue ball")
    }

    @Test func cutAngleMatchesGeometry() {
        let cut = ShotGuide.cutAngleDegrees(
            cuePosition: .zero, contact: Vec2(0.4, 0), struck: objectID,
            prediction: prediction(departureAngleDegrees: 40))
        #expect(cut != nil)
        #expect(abs(cut! - 40) < 1e-9)
    }
}
