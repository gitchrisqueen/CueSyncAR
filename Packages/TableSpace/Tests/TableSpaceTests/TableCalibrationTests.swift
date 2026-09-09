import CueSyncCore
import Foundation
import Testing
@testable import TableSpace

@Suite("Calibration from one end rail")
struct EndRailCalibrationTests {
    /// A rail lying along world z at y = -0.68, with the table extending
    /// toward +x — the shape of the owner's setup.
    private let a = Vec3(0, -0.68, 0.585)
    private let b = Vec3(0, -0.68, -0.585)
    private let towards = Vec3(1.0, -0.68, 0)

    @Test("The field is exactly the size asked for, whatever the rail measures")
    func sizeComesFromTheArgument() throws {
        let cal = try TableCalibration.fromEndRail(a, b, towards: towards, size: .eightFoot)
        #expect(cal.size == .eightFoot)
        #expect(cal.size.playField.width == 2.34)
        // A rail tapped 6 cm short still yields a full-size table.
        let short = try TableCalibration.fromEndRail(
            Vec3(0, -0.68, 0.555), Vec3(0, -0.68, -0.555),
            towards: towards, size: .eightFoot)
        #expect(short.size.playField.width == 2.34)
    }

    @Test("The rail becomes the short axis and the table runs away from it")
    func axesAreOrientedFromTheRail() throws {
        let cal = try TableCalibration.fromEndRail(a, b, towards: towards, size: .eightFoot)
        #expect(abs(abs(cal.yAxis.z) - 1) < 1e-9, "short axis along the rail")
        #expect(abs(cal.xAxis.x - 1) < 1e-9, "long axis toward the table")
        #expect(abs(cal.xAxis.dot(cal.yAxis)) < 1e-9)
    }

    @Test("The origin lands half a table's length from the rail's midpoint")
    func originIsTheTableCentre() throws {
        let cal = try TableCalibration.fromEndRail(a, b, towards: towards, size: .eightFoot)
        let midpoint = (a + b) * 0.5
        #expect(abs(cal.origin.distance(to: midpoint) - 2.34 / 2) < 1e-9)
        #expect(abs(cal.origin.y - a.y) < 1e-9, "stays on the cloth")
    }

    @Test("Both corners of the given rail come back where they were put")
    func theGivenRailIsReproduced() throws {
        let cal = try TableCalibration.fromEndRail(a, b, towards: towards, size: .eightFoot)
        let corners = cal.worldCorners
        for point in [a, b] {
            let nearest = corners.map { $0.distance(to: point) }.min() ?? .infinity
            #expect(nearest < 1e-9, "the observed rail must be preserved exactly")
        }
    }

    @Test("Rail order does not matter, but which side the table is on does")
    func orderIsSymmetricAndSideIsNot() throws {
        let one = try TableCalibration.fromEndRail(a, b, towards: towards, size: .eightFoot)
        let flipped = try TableCalibration.fromEndRail(b, a, towards: towards, size: .eightFoot)
        #expect(one.origin.distance(to: flipped.origin) < 1e-9)
        let behind = try TableCalibration.fromEndRail(
            a, b, towards: Vec3(-1.0, -0.68, 0), size: .eightFoot)
        #expect(behind.origin.distance(to: one.origin) > 2.0, "the table flips to the other side")
    }

    @Test("A degenerate rail or a colinear hint is refused, not guessed")
    func degenerateInputsThrow() {
        #expect(throws: (any Error).self) {
            try TableCalibration.fromEndRail(a, a, towards: towards, size: .eightFoot)
        }
        // "towards" on the rail itself gives no direction for the table.
        #expect(throws: (any Error).self) {
            try TableCalibration.fromEndRail(a, b, towards: Vec3(0, -0.68, 0), size: .eightFoot)
        }
    }

    @Test("A ball placed in table space round-trips through the calibration")
    func tableSpaceRoundTrips() throws {
        let cal = try TableCalibration.fromEndRail(a, b, towards: towards, size: .eightFoot)
        for point in [Vec2(0, 0), Vec2(1.0, -0.4), Vec2(-1.1, 0.55)] {
            let back = cal.worldToTable(cal.tableToWorld(point))
            #expect(abs(back.x - point.x) < 1e-9)
            #expect(abs(back.y - point.y) < 1e-9)
        }
    }
}
