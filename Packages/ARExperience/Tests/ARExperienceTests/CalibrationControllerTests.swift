import CueSyncCore
import Foundation
import TableSpace
import Testing
@testable import ARExperience

@Suite("Remote calibration correction")
struct CalibrationRemoteCorrectionTests {
    /// The owner's real locked calibration: 2.175 × 1.090 m, 16.5 cm short
    /// of an 8-ft field because the corners went inside the cushion noses.
    private var short: TableCalibration {
        TableCalibration(origin: Vec3(0.220478, -0.523416, -2.482509),
                         xAxis: Vec3(0.883370, 0, 0.468676),
                         yAxis: Vec3(-0.468676, 0, 0.883370),
                         size: .custom(width: 2.175177, height: 1.089950))
    }

    private func locked(_ calibration: TableCalibration) -> CalibrationController {
        var c = CalibrationController()
        c.handle(.restored(calibration))
        return c
    }

    @Test("Resizing keeps the centre and the heading, changing only the extent")
    func resizePreservesOriginAndAxes() throws {
        var c = locked(short)
        c.handle(.resized(.eightFoot))
        let after = try #require(c.calibration)
        #expect(after.origin == short.origin)
        #expect(after.xAxis == short.xAxis)
        #expect(after.yAxis == short.yAxis)
        #expect(after.size == .eightFoot)
        #expect(after.size.playField.width == 2.34)
    }

    @Test("No ball moves in table space when the table is re-measured")
    func resizeDoesNotMoveBalls() throws {
        var c = locked(short)
        let world = short.tableToWorld(Vec2(0.4, -0.2))
        c.handle(.resized(.eightFoot))
        let after = try #require(c.calibration)
        let round = after.worldToTable(world)
        #expect(abs(round.x - 0.4) < 1e-9)
        #expect(abs(round.y + 0.2) < 1e-9)
    }

    @Test("Resizing does move the pockets, which is the point")
    func resizeMovesThePockets() {
        let before = Table(size: short.size).pockets
        let after = Table(size: .eightFoot).pockets
        let beforeCorner = before.first { $0.id == .cornerTopRight }!.position
        let afterCorner = after.first { $0.id == .cornerTopRight }!.position
        #expect(afterCorner.x > beforeCorner.x)
        #expect((afterCorner.x - beforeCorner.x) > 0.07)   // ~8 cm per end
    }

    @Test("Corners round-trip through worldCorners")
    func cornersRoundTrip() throws {
        let corners = short.worldCorners
        #expect(corners.count == 4)
        let rebuilt = try TableCalibration.fromCorners(corners, sizeTolerance: 0.2)
        #expect(rebuilt.origin.distance(to: short.origin) < 1e-6)
        let field = rebuilt.size.playField
        #expect(abs(field.width - short.size.playField.width) < 1e-6)
        #expect(abs(field.height - short.size.playField.height) < 1e-6)
    }

    @Test("Reopening a locked table gives back its own four corners")
    func reopenYieldsTheLockedRectangle() {
        var c = locked(short)
        c.handle(.reopened)
        guard case let .adjusting(corners) = c.state else {
            Issue.record("expected .adjusting, got \(c.state)"); return
        }
        #expect(corners.count == 4)
        for (a, b) in zip(corners, short.worldCorners) {
            #expect(a.distance(to: b) < 1e-9)
        }
    }

    @Test("Reopen then lock is a no-op on an untouched rectangle")
    func reopenAndLockIsIdempotent() throws {
        var c = locked(short)
        c.preferredSize = short.size
        c.handle(.reopened)
        c.handle(.lockRequested)
        let after = try #require(c.calibration)
        #expect(after.origin.distance(to: short.origin) < 1e-6)
        #expect(abs(after.size.playField.width - short.size.playField.width) < 1e-3)
    }

    @Test("Neither resize nor reopen does anything without a lock")
    func requiresALock() {
        var c = CalibrationController()
        c.handle(.resized(.eightFoot))
        #expect(c.calibration == nil)
        c.handle(.reopened)
        #expect(c.state == .searchingPlane)
    }
}
