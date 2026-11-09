import CueSyncCore
import Foundation
import TableSpace
import Testing
@testable import ARExperience

/// Several advised-shot layouts (straight, thin cut, backwards, short) on a
/// calibration rotated about the vertical axis and offset from the world
/// origin, so the endpoint invariants hold in WORLD space for any anchor
/// pose, not just the identity one.
private struct ShotCase: CustomTestStringConvertible, Sendable {
    var name: String
    var cue: Vec2
    var ghost: Vec2
    var target: Vec2
    var pocket: Vec2
    var color: UInt32
    var testDescription: String { name }
}

private let cases = [
    ShotCase(name: "straight to far corner", cue: Vec2(-0.8, 0.0), ghost: Vec2(0.4, 0.0),
             target: Vec2(0.4 + 2 * Ball.standardRadius, 0.0), pocket: Vec2(1.27, 0.0),
             color: 0x35E08A),
    ShotCase(name: "thin cut", cue: Vec2(-0.5, -0.4), ghost: Vec2(0.31, 0.12),
             target: Vec2(0.35, 0.18), pocket: Vec2(1.27, 0.635), color: 0xF5A623),
    ShotCase(name: "backwards to near pocket", cue: Vec2(0.6, 0.2), ghost: Vec2(0.1, 0.3),
             target: Vec2(0.05, 0.32), pocket: Vec2(-1.27, 0.635), color: 0xE8604C),
    ShotCase(name: "short shot to side pocket", cue: Vec2(0.05, -0.3), ghost: Vec2(0.0, 0.1),
             target: Vec2(0.0, 0.16), pocket: Vec2(0.0, 0.635), color: 0x35E08A)
]

private func rotated(by yaw: Double) -> TableCalibration {
    // Table +x = world (cos, 0, sin); table +y = world (sin, 0, -cos): a
    // right-handed yaw of the whole table, offset from the world origin.
    TableCalibration(origin: Vec3(0.4, 0.8, -1.1),
                     xAxis: Vec3(cos(yaw), 0, sin(yaw)),
                     yAxis: Vec3(sin(yaw), 0, -cos(yaw)),
                     size: .nineFoot)
}

@Suite("OverlayLayout suggestion geometry")
struct OverlaySuggestionGeometryTests {
    private func suggestion(_ shot: ShotCase, calibration: TableCalibration) throws -> OverlayLayout.Suggestion {
        let state = TableState(table: Table(size: .nineFoot), balls: [
            Ball(id: BallID(0), kind: .cue, position: shot.cue),
            Ball(id: BallID(5), kind: .solid(5), position: shot.target)
        ])
        let layout = OverlayLayout.ballsOnly(state: state, calibration: calibration)
            .withSuggestion(
                .init(cue: shot.cue, ghost: shot.ghost, target: shot.target,
                      pocket: shot.pocket, pocketRadius: Table.cornerCaptureRadius,
                      color: shot.color, cueID: BallID(0), targetID: BallID(5)),
                calibration: calibration)
        return try #require(layout.suggestion)
    }

    /// World endpoints of a strip, rebuilt from midpoint, length and table
    /// heading the way the renderer places and rotates it.
    private func endpoints(_ strip: OverlayLayout.Strip,
                           calibration: TableCalibration) -> (Vec3, Vec3) {
        let mid = calibration.worldToTable(strip.midpoint)
        let half = Vec2(cos(strip.angle), sin(strip.angle)) * (strip.length / 2)
        return (calibration.tableToWorld(mid - half), calibration.tableToWorld(mid + half))
    }

    @Test("aim strip runs cue ball to ghost ball", arguments: cases, [0.0, 0.7, -2.2])
    private func aimStripEndpoints(shot: ShotCase, yaw: Double) throws {
        let calibration = rotated(by: yaw)
        let suggestion = try suggestion(shot, calibration: calibration)
        let (start, end) = endpoints(suggestion.aimStrip, calibration: calibration)
        #expect(start.distance(to: calibration.tableToWorld(shot.cue)) < 1e-9)
        #expect(end.distance(to: calibration.tableToWorld(shot.ghost)) < 1e-9)
        #expect(abs(suggestion.aimStrip.length - shot.cue.distance(to: shot.ghost)) < 1e-9)
    }

    @Test("object strip runs target to pocket", arguments: cases, [0.0, 0.7, -2.2])
    private func objectStripEndpoints(shot: ShotCase, yaw: Double) throws {
        let calibration = rotated(by: yaw)
        let suggestion = try suggestion(shot, calibration: calibration)
        let (start, end) = endpoints(suggestion.objectStrip, calibration: calibration)
        #expect(start.distance(to: calibration.tableToWorld(shot.target)) < 1e-9)
        #expect(end.distance(to: calibration.tableToWorld(shot.pocket)) < 1e-9)
        #expect(abs(suggestion.objectStrip.length - shot.target.distance(to: shot.pocket)) < 1e-9)
    }

    @Test("markers sit at ghost, target and pocket; strips stay on the cloth", arguments: cases)
    private func markersAndPlane(shot: ShotCase) throws {
        let calibration = rotated(by: 0.7)
        let suggestion = try suggestion(shot, calibration: calibration)
        #expect(suggestion.ghost.position.distance(to: calibration.tableToWorld(shot.ghost)) < 1e-9)
        #expect(suggestion.target.position.distance(to: calibration.tableToWorld(shot.target)) < 1e-9)
        #expect(suggestion.pocket.position.distance(to: calibration.tableToWorld(shot.pocket)) < 1e-9)
        for strip in [suggestion.aimStrip, suggestion.objectStrip] {
            #expect(abs(calibration.heightAbovePlane(strip.midpoint)) < 1e-9)
        }
        #expect(suggestion.pocket.radius > Table.cornerCaptureRadius)
    }

    @Test("the advised colour reaches every strip and the suggestion", arguments: cases)
    private func colourFollowsTheAdvice(shot: ShotCase) throws {
        let suggestion = try suggestion(shot, calibration: rotated(by: 0))
        #expect(suggestion.color == shot.color)
        #expect(suggestion.aimStrip.color == shot.color)
        #expect(suggestion.objectStrip.color == shot.color)
        #expect(!suggestion.aimStrip.dashed)
        #expect(suggestion.objectStrip.dashed)
    }
}
