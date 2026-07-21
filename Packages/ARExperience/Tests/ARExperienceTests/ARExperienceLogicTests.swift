import CueSyncCore
import Foundation
import TableSpace
import Testing
@testable import ARExperience

/// Table lying in the world xz-plane (y up), centered at the origin.
private let calibration = TableCalibration(origin: .zero,
                                           xAxis: Vec3(1, 0, 0),
                                           yAxis: Vec3(0, 0, -1),
                                           size: .nineFoot)

/// Camera-to-world transform positioned at `position`, looking along
/// `forward` (camera looks down its −z axis), with a best-effort up vector.
private func cameraTransform(position: Vec3, forward: Vec3) -> Transform3D {
    let f = forward.normalized
    let zAxis = f * -1
    var up = Vec3(0, 1, 0)
    if abs(zAxis.dot(up)) > 0.99 { up = Vec3(0, 0, 1) }
    let xAxis = up.cross(zAxis).normalized
    let yAxis = zAxis.cross(xAxis)
    return Transform3D(columns: [
        SIMD4(xAxis.x, xAxis.y, xAxis.z, 0),
        SIMD4(yAxis.x, yAxis.y, yAxis.z, 0),
        SIMD4(zAxis.x, zAxis.y, zAxis.z, 0),
        SIMD4(position.x, position.y, position.z, 1)
    ])
}

@Suite("AimEngine")
struct AimEngineTests {
    let engine = AimEngine()
    let cueBall = Vec2(-0.5, 0)

    @Test func aimsFromCueBallTowardLookPoint() throws {
        // Camera behind and above the cue ball, looking at table point (0.5, 0.2).
        let lookTarget = calibration.tableToWorld(Vec2(0.5, 0.2))
        let cameraPosition = calibration.tableToWorld(Vec2(-1.1, 0)) + Vec3(0, 0.6, 0)
        let transform = cameraTransform(position: cameraPosition,
                                        forward: lookTarget - cameraPosition)
        let ray = try #require(engine.aimRay(cameraTransform: transform,
                                             cueBall: cueBall,
                                             calibration: calibration))
        #expect(ray.origin == cueBall)
        let expected = (Vec2(0.5, 0.2) - cueBall).normalized
        #expect(abs(ray.direction.x - expected.x) < 1e-6)
        #expect(abs(ray.direction.y - expected.y) < 1e-6)
    }

    @Test func nearBallLookPointFallsBackToForwardProjection() throws {
        // Looking straight at the cue ball: look point within degenerateRadius.
        let cueWorld = calibration.tableToWorld(cueBall)
        let cameraPosition = cueWorld + Vec3(-0.4, 0.5, 0.1)
        let transform = cameraTransform(position: cameraPosition,
                                        forward: cueWorld - cameraPosition)
        let ray = try #require(engine.aimRay(cameraTransform: transform,
                                             cueBall: cueBall,
                                             calibration: calibration))
        // Fallback: forward projected onto the plane, normalized.
        let forward = (cueWorld - cameraPosition).normalized
        let expected = Vec2(forward.dot(calibration.xAxis),
                            forward.dot(calibration.yAxis)).normalized
        #expect(abs(ray.direction.x - expected.x) < 1e-6)
        #expect(abs(ray.direction.y - expected.y) < 1e-6)
    }

    @Test func skyPointingCameraYieldsNil() {
        // Looking straight up: no plane intersection AND no planar component.
        let transform = cameraTransform(position: Vec3(0, 1, 0),
                                        forward: Vec3(0, 1, 0))
        #expect(engine.aimRay(cameraTransform: transform,
                              cueBall: cueBall,
                              calibration: calibration) == nil)
    }
}

@Suite("CalibrationController")
struct CalibrationControllerTests {
    var corners: [Vec3] {
        let he = Table(size: .nineFoot).halfExtents
        return [
            calibration.tableToWorld(Vec2(-he.x, -he.y)),
            calibration.tableToWorld(Vec2(he.x, -he.y)),
            calibration.tableToWorld(Vec2(he.x, he.y)),
            calibration.tableToWorld(Vec2(-he.x, he.y))
        ]
    }

    @Test func happyPathLocks() {
        var controller = CalibrationController()
        #expect(controller.state == .searchingPlane)
        controller.handle(.planeDetected)
        #expect(controller.state == .planeFound)
        controller.handle(.cornersProposed(corners))
        guard case .adjusting = controller.state else {
            Issue.record("expected adjusting, got \(controller.state)")
            return
        }
        controller.handle(.lockRequested)
        #expect(controller.isLocked)
        #expect(controller.calibration?.size == .nineFoot)
        #expect(controller.lastError == nil)
    }

    @Test func cornerAdjustmentIsApplied() {
        var controller = CalibrationController()
        controller.handle(.planeDetected)
        controller.handle(.cornersProposed(corners))
        let moved = corners[2] + Vec3(0.01, 0, 0)
        controller.handle(.cornerMoved(index: 2, to: moved))
        guard case let .adjusting(current) = controller.state else {
            Issue.record("expected adjusting")
            return
        }
        #expect(current[2] == moved)
        // Out-of-range index is ignored, not a trap.
        controller.handle(.cornerMoved(index: 9, to: .zero))
        #expect(controller.state == .adjusting(corners: current))
    }

    @Test func badRectangleStaysAdjustingWithError() {
        var controller = CalibrationController()
        controller.handle(.planeDetected)
        controller.handle(.cornersProposed([.zero, .zero, .zero, .zero]))
        controller.handle(.lockRequested)
        #expect(!controller.isLocked)
        #expect(controller.lastError != nil)
        guard case .adjusting = controller.state else {
            Issue.record("must stay adjusting after failed lock")
            return
        }
    }

    @Test func planeLossRestartsUnlessLocked() {
        var controller = CalibrationController()
        controller.handle(.planeDetected)
        controller.handle(.planeLost)
        #expect(controller.state == .searchingPlane)

        controller.handle(.planeDetected)
        controller.handle(.cornersProposed(corners))
        controller.handle(.lockRequested)
        controller.handle(.planeLost)
        #expect(controller.isLocked, "locked calibration survives transient plane loss")

        controller.handle(.resetRequested)
        #expect(controller.state == .searchingPlane)
    }

    @Test func restoredCalibrationLocksFromAnyUnlockedState() throws {
        let saved = try TableCalibration.fromCorners(corners)

        // Cold start: restore locks immediately (saved-venue fast path).
        var controller = CalibrationController()
        controller.handle(.restored(saved))
        #expect(controller.calibration == saved)

        // Mid-flow restore wins over manual progress…
        var midFlow = CalibrationController()
        midFlow.handle(.planeDetected)
        midFlow.handle(.cornersProposed(corners))
        midFlow.handle(.restored(saved))
        #expect(midFlow.isLocked)

        // …but never replaces a calibration locked this session.
        var locked = CalibrationController()
        locked.handle(.planeDetected)
        locked.handle(.cornersProposed(corners))
        locked.handle(.lockRequested)
        let lockedCalibration = locked.calibration
        var other = saved
        other.origin += Vec3(1, 0, 0)
        locked.handle(.restored(other))
        #expect(locked.calibration == lockedCalibration)
    }
}

@Suite("OverlayLayout")
struct OverlayLayoutTests {
    let cueID = BallID(0)
    let objectID = BallID(1)

    var state: TableState {
        TableState(table: Table(size: .nineFoot), balls: [
            Ball(id: cueID, kind: .cue, position: Vec2(-0.5, 0)),
            Ball(id: objectID, kind: .solid(1), position: .zero)
        ])
    }

    @Test func stripsCarryStylingAndWorldPlacement() {
        let contact = Vec2(-2 * Ball.standardRadius, 0)
        let prediction = ShotPrediction(
            segments: [
                TrajectorySegment(ballID: cueID, start: Vec2(-0.5, 0), end: contact),
                TrajectorySegment(ballID: cueID, start: contact, end: Vec2(-0.1, -0.3)),
                TrajectorySegment(ballID: objectID, start: .zero, end: Vec2(0.6, 0))
            ],
            events: [.ballBall(moving: cueID, struck: objectID, contact: contact)],
            pocketedBalls: [])
        let layout = OverlayLayout.compose(state: state, prediction: prediction,
                                           calibration: calibration)

        #expect(layout.strips.count == 3)
        // Aim strip: amber, solid, lies along +x.
        let aim = layout.strips[0]
        #expect(aim.color == 0xF5A623)
        #expect(!aim.dashed)
        #expect(abs(aim.angle) < 1e-9)
        // Post-contact cue strip: chalk blue, dashed.
        let tangent = layout.strips[1]
        #expect(tangent.color == 0x4A90D9)
        #expect(tangent.dashed)
        // Object strip: green; world midpoint on the plane (y = 0 here).
        let object = layout.strips[2]
        #expect(object.color == 0x2FA36B)
        #expect(abs(object.midpoint.y) < 1e-9)
        #expect(abs(object.midpoint.x - 0.3) < 1e-9)
        #expect(abs(object.length - 0.6) < 1e-9)

        // Ghost ball at the contact, radius = cue radius.
        #expect(layout.ghostBall != nil)
        #expect(abs((layout.ghostBall?.radius ?? 0) - Ball.standardRadius) < 1e-12)
        #expect(layout.highlightedPockets.isEmpty)
    }

    @Test func scratchTintsPostContactStrips() {
        let contact = Vec2(0.0, 0.0)
        let prediction = ShotPrediction(
            segments: [
                TrajectorySegment(ballID: cueID, start: Vec2(-0.5, 0), end: contact),
                TrajectorySegment(ballID: cueID, start: contact, end: Vec2(-1.27, -0.635),
                                  kind: .intoPocket)
            ],
            events: [
                .ballBall(moving: cueID, struck: objectID, contact: contact),
                .pocket(ball: cueID, pocket: .cornerBottomLeft)
            ],
            pocketedBalls: [cueID])
        let layout = OverlayLayout.compose(state: state, prediction: prediction,
                                           calibration: calibration)
        #expect(layout.strips.last?.color == 0xE8604C)
        #expect(layout.highlightedPockets.count == 1)
    }

    @Test func zeroLengthSegmentsAreDropped() {
        let prediction = ShotPrediction(
            segments: [TrajectorySegment(ballID: cueID, start: .zero, end: .zero)],
            events: [], pocketedBalls: [])
        let layout = OverlayLayout.compose(state: state, prediction: prediction,
                                           calibration: calibration)
        #expect(layout.strips.isEmpty)
    }
}
