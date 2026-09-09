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

@Suite("Sliding a locked table")
struct TranslatedCalibrationTests {
    private let cal = TableCalibration(origin: Vec3(0.2, -0.55, -2.4),
                                       xAxis: Vec3(0.883370, 0, 0.468676),
                                       yAxis: Vec3(-0.468676, 0, 0.883370),
                                       size: .eightFoot)

    @Test("Translating moves the table without resizing or re-aiming it")
    func keepsSizeAndAxes() {
        let moved = cal.translated(by: Vec2(-0.08, -0.15))
        #expect(moved.size == cal.size)
        #expect(moved.xAxis == cal.xAxis)
        #expect(moved.yAxis == cal.yAxis)
        #expect(moved.origin != cal.origin)
        #expect(abs(moved.origin.y - cal.origin.y) < 1e-9, "stays on the cloth")
    }

    @Test("A ball keeps its world position and gains the opposite table offset")
    func ballsShiftTheOtherWay() {
        let world = cal.tableToWorld(Vec2(0.5, 0.2))
        let moved = cal.translated(by: Vec2(-0.08, -0.15))
        let after = moved.worldToTable(world)
        #expect(abs(after.x - (0.5 + 0.08)) < 1e-9)
        #expect(abs(after.y - (0.2 + 0.15)) < 1e-9)
    }

    @Test("The move is exactly the distance asked for, along the table's own axes")
    func distanceIsExact() {
        let delta = Vec2(-0.08, -0.15)
        let moved = cal.translated(by: delta)
        #expect(abs(moved.origin.distance(to: cal.origin) - delta.length) < 1e-9)
        let along = moved.origin - cal.origin
        #expect(abs(along.dot(cal.xAxis) - delta.x) < 1e-9)
        #expect(abs(along.dot(cal.yAxis) - delta.y) < 1e-9)
    }

    @Test("Zero is a no-op and translations compose")
    func composesAndIdentity() {
        #expect(cal.translated(by: .zero).origin == cal.origin)
        let twice = cal.translated(by: Vec2(0.1, 0.2)).translated(by: Vec2(-0.1, -0.2))
        #expect(twice.origin.distance(to: cal.origin) < 1e-9)
    }
}

@Suite("Calibration from the long rails")
struct LongRailCalibrationTests {
    /// Ground truth: an 8-ft table on the world xz-plane at y = -0.48,
    /// centred on the origin, long axis along +x.
    private let cloth = -0.48
    private var truth: TableCalibration {
        TableCalibration(origin: Vec3(0, cloth, 0), xAxis: Vec3(1, 0, 0),
                         yAxis: Vec3(0, 0, -1), size: .eightFoot)
    }

    /// Points on the real rails of `truth`, at arbitrary places along them.
    private func rails(nearAt: (Double, Double) = (-0.8, 0.6),
                       farAt: (Double, Double) = (-0.5, 0.9))
        -> (near: (Vec3, Vec3), far: (Vec3, Vec3), end: Vec3) {
        let t = truth
        let hy = t.size.playField.height / 2
        let hx = t.size.playField.width / 2
        return (near: (t.tableToWorld(Vec2(nearAt.0, -hy)), t.tableToWorld(Vec2(nearAt.1, -hy))),
                far: (t.tableToWorld(Vec2(farAt.0, hy)), t.tableToWorld(Vec2(farAt.1, hy))),
                end: t.tableToWorld(Vec2(-hx, 0.15)))
    }

    @Test("Two rails and one end point recover the table exactly")
    func recoversTheTable() throws {
        let r = rails()
        let built = try TableCalibration.fromLongRails(nearRail: r.near, farRail: r.far,
                                                       endRail: r.end, size: .eightFoot)
        #expect(built.origin.distance(to: truth.origin) < 1e-9)
        #expect(abs(built.xAxis.dot(truth.xAxis)) > 0.999999)
        #expect(built.size == .eightFoot)
    }

    /// The point of using rails rather than corners: where along a rail
    /// the points are taken cannot matter, because a line is a line.
    @Test("Where along the rails the points are taken makes no difference")
    func railSamplingIsIrrelevant() throws {
        let a = rails(nearAt: (-1.0, -0.7), farAt: (0.6, 1.0))
        let b = rails(nearAt: (0.2, 1.05), farAt: (-1.1, -0.2))
        let one = try TableCalibration.fromLongRails(nearRail: a.near, farRail: a.far,
                                                     endRail: a.end, size: .eightFoot)
        let other = try TableCalibration.fromLongRails(nearRail: b.near, farRail: b.far,
                                                       endRail: b.end, size: .eightFoot)
        #expect(one.origin.distance(to: other.origin) < 1e-9)
        #expect(one.origin.distance(to: truth.origin) < 1e-9)
    }

    @Test("Either rail may be given in either order")
    func pointOrderDoesNotMatter() throws {
        let r = rails()
        let flipped = try TableCalibration.fromLongRails(
            nearRail: (r.near.1, r.near.0), farRail: (r.far.1, r.far.0),
            endRail: r.end, size: .eightFoot)
        #expect(flipped.origin.distance(to: truth.origin) < 1e-9)
        let mixed = try TableCalibration.fromLongRails(
            nearRail: r.near, farRail: (r.far.1, r.far.0), endRail: r.end, size: .eightFoot)
        #expect(mixed.origin.distance(to: truth.origin) < 1e-9)
    }

    @Test("Which rail is called near and which far does not change the table")
    func railRolesAreSymmetric() throws {
        let r = rails()
        let swapped = try TableCalibration.fromLongRails(nearRail: r.far, farRail: r.near,
                                                         endRail: r.end, size: .eightFoot)
        #expect(swapped.origin.distance(to: truth.origin) < 1e-9)
        // The short axis flips to keep the basis pointing near-to-far.
        #expect(abs(swapped.yAxis.dot(truth.yAxis)) > 0.999999)
    }

    /// The failure this replaces. Two corner taps 3 cm out along the rail
    /// slide the whole table by that much; the same 3 cm of error on a
    /// rail point moves nothing, because it stays on the same line.
    @Test("A tap that slides along a rail costs nothing")
    func errorAlongARailIsFree() throws {
        let r = rails()
        let along = truth.xAxis * 0.03
        let slid = try TableCalibration.fromLongRails(
            nearRail: (r.near.0 + along, r.near.1 + along),
            farRail: (r.far.0 - along, r.far.1 - along),
            endRail: r.end, size: .eightFoot)
        #expect(slid.origin.distance(to: truth.origin) < 1e-9)
    }

    @Test("An error ACROSS a rail moves the table by half of it, not all of it")
    func errorAcrossARailIsHalved() throws {
        let r = rails()
        let across = truth.yAxis * 0.04
        let off = try TableCalibration.fromLongRails(
            nearRail: (r.near.0 + across, r.near.1 + across),
            farRail: r.far, endRail: r.end, size: .eightFoot)
        // One rail 4 cm out moves the midline 2 cm — averaging two lines
        // halves the error rather than passing it through.
        #expect(abs(off.origin.distance(to: truth.origin) - 0.02) < 1e-6)
    }

    @Test("Rail separation is reported so a bad fit can be caught")
    func separationIsMeasurable() throws {
        let r = rails()
        let measured = try #require(TableCalibration.railSeparation(r.near, r.far))
        #expect(abs(measured - 1.17) < 1e-9)
        // A rail placed on the wooden rail rather than the cushion nose
        // shows up immediately as a table that is too wide.
        let wide = (r.far.0 + truth.yAxis * 0.05, r.far.1 + truth.yAxis * 0.05)
        let wrong = try #require(TableCalibration.railSeparation(r.near, wide))
        #expect(abs(wrong - 1.22) < 1e-9)
    }

    @Test("Degenerate rails are refused rather than guessed")
    func degenerateInputThrows() {
        let r = rails()
        #expect(throws: (any Error).self) {
            try TableCalibration.fromLongRails(nearRail: (r.near.0, r.near.0),
                                               farRail: r.far, endRail: r.end, size: .eightFoot)
        }
        // Both "rails" on the same line: no plane, no across direction.
        #expect(throws: (any Error).self) {
            try TableCalibration.fromLongRails(nearRail: r.near, farRail: r.near,
                                               endRail: r.end, size: .eightFoot)
        }
    }

    @Test("The table is built on the side of the end rail the camera can see")
    func extendsAwayFromTheEndRail() throws {
        let r = rails()
        let built = try TableCalibration.fromLongRails(nearRail: r.near, farRail: r.far,
                                                       endRail: r.end, size: .eightFoot)
        // Every rail point given must lie inside the resulting field.
        for point in [r.near.0, r.near.1, r.far.0, r.far.1, r.end] {
            let table = built.worldToTable(point)
            #expect(abs(table.x) <= 1.171)
            #expect(abs(table.y) <= 0.586)
        }
    }
}
