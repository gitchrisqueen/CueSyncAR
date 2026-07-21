import CueSyncCore
import Foundation
import Testing
@testable import CueSyncUI

private func rackState() -> TableState {
    TableState(table: Table(size: .nineFoot), balls: [
        Ball(id: BallID(0), kind: .cue, position: Vec2(-0.635, 0)),
        Ball(id: BallID(3), kind: .solid(3), position: Vec2(0.4, 0.2))
    ])
}

@Suite("TableScene composition")
struct TableSceneTests {
    @Test func aspectFitCentersAndScales() {
        let scene = TableScene.compose(state: rackState(),
                                       viewportWidth: 800, viewportHeight: 600,
                                       padding: 20)
        // Width-limited: outer table is (2.54+0.1) × (1.27+0.1) m.
        let expectedScale = (800.0 - 40) / (2.54 + 2 * TableScene.railWidth)
        #expect(abs(scene.scale - expectedScale) < 1e-9)
        // Rail frame centered in the viewport.
        #expect(abs((scene.railFrame.x + scene.railFrame.width / 2) - 400) < 1e-9)
        #expect(abs((scene.railFrame.y + scene.railFrame.height / 2) - 300) < 1e-9)
        // Felt sits inside the rails.
        #expect(scene.feltFrame.x > scene.railFrame.x)
        #expect(scene.feltFrame.width < scene.railFrame.width)
    }

    @Test func yAxisFlips() {
        let scene = TableScene.compose(state: rackState(),
                                       viewportWidth: 800, viewportHeight: 600)
        // Ball at table y = +0.2 (up) must be ABOVE center in view space (y down).
        let solid = scene.balls[1]
        #expect(solid.center.y < 300)
        // Ball at table x = -0.635 must be left of center.
        #expect(scene.balls[0].center.x < 400)
    }

    @Test func pocketsHighlightOnlyWhenPredictionPocketsThere() {
        let prediction = ShotPrediction(
            segments: [],
            events: [.pocket(ball: BallID(3), pocket: .cornerTopRight)],
            pocketedBalls: [BallID(3)])
        let scene = TableScene.compose(state: rackState(), prediction: prediction,
                                       viewportWidth: 800, viewportHeight: 600)
        #expect(scene.pockets.count == 6)
        for pocket in scene.pockets {
            #expect(pocket.highlighted == (pocket.id == .cornerTopRight))
        }
        // No prediction → nothing lit.
        let idle = TableScene.compose(state: rackState(),
                                      viewportWidth: 800, viewportHeight: 600)
        #expect(idle.pockets.allSatisfy { !$0.highlighted })
    }

    @Test func cuePathSplitsAtContactIntoAimAndTangent() {
        let cue = BallID(0)
        let object = BallID(3)
        let contact = Vec2(0.34, 0.17)
        let prediction = ShotPrediction(
            segments: [
                TrajectorySegment(ballID: cue, start: Vec2(-0.635, 0), end: contact,
                                  kind: .roll, entrySpeed: 2),
                TrajectorySegment(ballID: cue, start: contact, end: Vec2(0.2, -0.1),
                                  kind: .roll, entrySpeed: 1),
                TrajectorySegment(ballID: object, start: Vec2(0.4, 0.2), end: Vec2(0.9, 0.4),
                                  kind: .roll, entrySpeed: 1.5)
            ],
            events: [.ballBall(moving: cue, struck: object, contact: contact)],
            pocketedBalls: [])
        let scene = TableScene.compose(state: rackState(), prediction: prediction,
                                       viewportWidth: 800, viewportHeight: 600)

        let styles = scene.paths.map(\.style)
        #expect(styles.contains(.aim))
        #expect(styles.contains(.cueAfterContact))
        #expect(styles.contains(.object))
        // Ghost ball marks the contact.
        #expect(scene.ghostBall != nil)
        #expect(scene.ghostBall?.isGhost == true)

        // Aim path is solid amber; tangent is dashed chalk blue.
        let aim = scene.paths.first { $0.style == .aim }!
        let tangent = scene.paths.first { $0.style == .cueAfterContact }!
        #expect(aim.color == Theme.cueAmber)
        #expect(!aim.dashed)
        #expect(tangent.color == Theme.chalkBlue)
        #expect(tangent.dashed)
        // The split point is shared.
        #expect(aim.points.last == tangent.points.first)
    }

    @Test func scratchRendersCoral() {
        let cue = BallID(0)
        let object = BallID(3)
        let contact = Vec2(0.3, 0.15)
        let prediction = ShotPrediction(
            segments: [
                TrajectorySegment(ballID: cue, start: Vec2(-0.635, 0), end: contact),
                TrajectorySegment(ballID: cue, start: contact, end: Vec2(-1.27, -0.635),
                                  kind: .intoPocket)
            ],
            events: [
                .ballBall(moving: cue, struck: object, contact: contact),
                .pocket(ball: cue, pocket: .cornerBottomLeft)
            ],
            pocketedBalls: [cue])
        let scene = TableScene.compose(state: rackState(), prediction: prediction,
                                       viewportWidth: 800, viewportHeight: 600)
        let post = scene.paths.first { $0.style == .scratch }
        #expect(post != nil)
        #expect(post?.color == Theme.warnCoral)
    }

    @Test func ballStyles() {
        #expect(Theme.ballStyle(for: .cue) == BallStyle(fill: Theme.ballWhite, striped: false, number: nil))
        #expect(Theme.ballStyle(for: .eight).number == 8)
        #expect(Theme.ballStyle(for: .solid(3)).striped == false)
        let twelve = Theme.ballStyle(for: .stripe(12))
        #expect(twelve.striped)
        #expect(twelve.number == 12)
        // 12 shares the 4-ball's purple.
        #expect(twelve.fill == Theme.ballStyle(for: .solid(4)).fill)
    }
}

@Suite("HUD status")
struct HUDStatusTests {
    @Test func labelsAndIcons() {
        #expect(HUDStatus.findingTable.label == "Point at the table")
        #expect(HUDStatus.tracking(ballCount: 16).label == "Tracking 16 balls")
        #expect(HUDStatus.degraded(reason: .fastMotion).label == "Hold steady…")
        #expect(HUDStatus.tracking(ballCount: 1).systemImage == "checkmark.circle")
    }

    @Test func confidenceHonestyFadesOverlays() {
        #expect(HUDStatus.tracking(ballCount: 16).overlayOpacity == 1.0)
        #expect(HUDStatus.degraded(reason: .lowLight).overlayOpacity == 0.4)
    }
}
