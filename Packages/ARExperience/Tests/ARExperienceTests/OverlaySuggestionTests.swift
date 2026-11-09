import CueSyncCore
import Foundation
import TableSpace
import Testing
@testable import ARExperience

/// Table in the world xz-plane, table +y mapped to world −z (as in the
/// logic suite), centered at the origin.
private let calibration = TableCalibration(origin: .zero,
                                           xAxis: Vec3(1, 0, 0),
                                           yAxis: Vec3(0, 0, -1),
                                           size: .nineFoot)

@Suite("OverlayLayout suggestion")
struct OverlaySuggestionTests {
    private let state = TableState(table: Table(size: .nineFoot), balls: [
        Ball(id: BallID(0), kind: .cue, position: Vec2(0.5, -0.135)),
        Ball(id: BallID(5), kind: .solid(5), position: Vec2(1.0, 0.365))
    ])

    private func layout() -> OverlayLayout {
        OverlayLayout.ballsOnly(state: state, calibration: calibration)
            .withSuggestion(
                .init(cue: Vec2(0.5, -0.135), ghost: Vec2(0.9596, 0.3246),
                      target: Vec2(1.0, 0.365), pocket: Vec2(1.27, 0.635),
                      pocketRadius: Table.cornerCaptureRadius, color: 0x35E08A,
                      cueID: BallID(0), targetID: BallID(5)),
                calibration: calibration)
    }

    @Test func plainLayoutsCarryNoSuggestion() {
        let plain = OverlayLayout.ballsOnly(state: state, calibration: calibration)
        #expect(plain.suggestion == nil)
        #expect(plain != layout())
    }

    @Test func suggestionKeepsBallRingsAndDoesNotMutateTheOriginal() {
        let base = OverlayLayout.ballsOnly(state: state, calibration: calibration)
        let advised = layout()
        #expect(advised.balls == base.balls)
        #expect(base.suggestion == nil)
    }

    @Test func aimStripSpansCueToGhostWithTableHeading() throws {
        let suggestion = try #require(layout().suggestion)
        let cue = Vec2(0.5, -0.135)
        let ghost = Vec2(0.9596, 0.3246)
        #expect(abs(suggestion.aimStrip.length - cue.distance(to: ghost)) < 1e-9)
        let heading = atan2(ghost.y - cue.y, ghost.x - cue.x)
        #expect(abs(suggestion.aimStrip.angle - heading) < 1e-9)
        let mid = calibration.tableToWorld((cue + ghost) * 0.5)
        #expect(suggestion.aimStrip.midpoint.distance(to: mid) < 1e-9)
        #expect(!suggestion.aimStrip.dashed)
        #expect(suggestion.objectStrip.dashed)
    }

    @Test func markersSitAtTheirWorldPositions() throws {
        let suggestion = try #require(layout().suggestion)
        #expect(suggestion.pocket.position
                    .distance(to: calibration.tableToWorld(Vec2(1.27, 0.635))) < 1e-9)
        #expect(suggestion.target.position
                    .distance(to: calibration.tableToWorld(Vec2(1.0, 0.365))) < 1e-9)
        #expect(suggestion.ghost.radius == Ball.standardRadius)
        #expect(suggestion.target.radius > Ball.standardRadius)
        #expect(suggestion.color == 0x35E08A)
        #expect(suggestion.aimStrip.color == 0x35E08A)
    }
}
