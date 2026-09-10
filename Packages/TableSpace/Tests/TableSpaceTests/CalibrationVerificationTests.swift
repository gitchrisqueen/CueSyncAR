//
//  CalibrationVerificationTests.swift
//  CueSync AR
//
//  Hand-computed positions for each standard size, because the whole
//  point of these marks is that they can be checked against a real table —
//  and a mark drawn in the wrong place is worse than no mark, since it
//  would have someone reject a calibration that was right.
//

import CueSyncCore
import Foundation
import Testing
@testable import TableSpace

@Suite("Calibration verification marks")
struct CalibrationVerificationTests {

    private func reference(size: TableSize = .eightFoot,
                           yaw: Double = 0.4,
                           height: Double = -0.53) -> TableCalibration {
        let up = Vec3(0, 1, 0)
        let xAxis = Vec3(cos(yaw), 0, sin(yaw)).normalized
        return TableCalibration(origin: Vec3(0.2, height, -2.1),
                                xAxis: xAxis, yAxis: up.cross(xAxis).normalized,
                                size: size)
    }

    @Test("Eighteen diamonds, on every standard size",
          arguments: [TableSize.sevenFoot, .eightFoot, .nineFoot])
    func eighteenDiamonds(size: TableSize) {
        #expect(CalibrationVerification.diamonds(for: size).count == 18)
    }

    @Test("Six to a long rail, three to a short one")
    func diamondsPerRail() {
        let size = TableSize.eightFoot
        let (width, height) = size.playField
        let marks = CalibrationVerification.diamonds(for: size)
        let onLongRails = marks.filter { abs(abs($0.y) - height / 2) < 1e-9 }
        let onShortRails = marks.filter { abs(abs($0.x) - width / 2) < 1e-9 }
        #expect(onLongRails.count == 12)
        #expect(onShortRails.count == 6)
        #expect(onLongRails.filter { $0.y > 0 }.count == 6)
        #expect(onShortRails.filter { $0.x > 0 }.count == 3)
    }

    @Test("Hand-computed eighth marks on an eight-foot table")
    func handComputedEighths() {
        // 2.34 m long: eighths at 0.2925 m. From -1.17, the interior marks
        // are at -0.8775, -0.585, -0.2925, [0 = side pocket], 0.2925,
        // 0.585, 0.8775.
        let expected: [Double] = [-0.8775, -0.585, -0.2925, 0.2925, 0.585, 0.8775]
        // On the FAR long rail only: `y > 0` alone would also catch the
        // short-rail marks that happen to sit above the axis.
        let top = CalibrationVerification.diamonds(for: .eightFoot)
            .filter { abs($0.y - 1.17 / 2) < 1e-9 }
            .map(\.x)
            .sorted()
        #expect(top.count == expected.count)
        for (got, want) in zip(top, expected) {
            #expect(abs(got - want) < 1e-9, "diamond at \(got), expected \(want)")
        }
    }

    @Test("No diamond sits in a pocket")
    func diamondsAvoidThePockets() {
        // The middle mark of each long rail IS the side pocket; drawing a
        // diamond there would be drawing a dot in a hole.
        for size in TableSize.standardSizes {
            let table = Table(size: size)
            for mark in CalibrationVerification.diamonds(for: size) {
                for pocket in table.pockets {
                    #expect((mark - pocket.position).length > 0.05,
                            "a \(size) diamond lands on \(pocket.id)")
                }
            }
        }
    }

    @Test("Hand-computed quarter marks on the short rails")
    func handComputedQuarters() {
        // 1.17 m across: quarters at 0.2925. From -0.585: -0.2925, 0, 0.2925.
        let right = CalibrationVerification.diamonds(for: .eightFoot)
            .filter { $0.x > 0 && abs($0.x - 1.17) < 1e-9 }
            .map(\.y)
            .sorted()
        #expect(right.count == 3)
        for (got, want) in zip(right, [-0.2925, 0.0, 0.2925]) {
            #expect(abs(got - want) < 1e-9)
        }
    }

    @Test("The spots are the quarter points and the centre")
    func spotsAreQuarterPoints() {
        let spots = CalibrationVerification.spots(for: .eightFoot)
        #expect(spots.count == 3)
        #expect(abs(spots[0].x - (-0.585)) < 1e-9)
        #expect(abs(spots[1].x) < 1e-9)
        #expect(abs(spots[2].x - 0.585) < 1e-9)
        #expect(spots.allSatisfy { abs($0.y) < 1e-9 })
    }

    @Test("The quarter lines span the table and sit on the spots")
    func quarterLinesSpanTheTable() {
        let (width, height) = TableSize.eightFoot.playField
        let lines = CalibrationVerification.quarterLines(for: .eightFoot)
        #expect(lines.count == 2)
        for line in lines {
            #expect(abs(line.0.x - line.1.x) < 1e-9, "a string is not square to the table")
            #expect(abs(abs(line.0.y) - height / 2) < 1e-9)
            #expect(abs(abs(line.1.y) - height / 2) < 1e-9)
            #expect(abs(abs(line.0.x) - width / 4) < 1e-9)
        }
    }

    // MARK: The world-space overlay

    @Test("Every mark lies in the calibrated cloth plane")
    func marksLieOnTheCloth() {
        let calibration = reference()
        let overlay = CalibrationVerification.overlay(for: calibration)
        let normal = calibration.xAxis.cross(calibration.yAxis).normalized
        for point in overlay.pockets + overlay.diamonds + overlay.spots {
            let offPlane = abs((point - calibration.origin).dot(normal))
            #expect(offPlane < 1e-9, "a mark floats \(offPlane) m off the cloth")
        }
    }

    @Test("The centre spot is the table's own origin")
    func centreSpotIsTheOrigin() {
        let calibration = reference()
        let overlay = CalibrationVerification.overlay(for: calibration)
        #expect((overlay.spots[1] - calibration.origin).length < 1e-9)
    }

    @Test("The marks move with the table, not with the room",
          arguments: [0.0, 0.7, -1.3] as [Double])
    func marksFollowTheCalibration(yaw: Double) {
        // The check that catches an overlay drawing from a stale
        // calibration: rotate the table and the diamonds must rotate with
        // it, staying the same distances apart.
        let a = CalibrationVerification.overlay(for: reference(yaw: 0))
        let b = CalibrationVerification.overlay(for: reference(yaw: yaw))
        #expect(a.diamonds.count == b.diamonds.count)
        for index in a.diamonds.indices.dropFirst() {
            let spanA = (a.diamonds[index] - a.diamonds[0]).length
            let spanB = (b.diamonds[index] - b.diamonds[0]).length
            #expect(abs(spanA - spanB) < 1e-9, "the marks distorted when the table turned")
        }
    }

    @Test("A dragged corner moves the derived marks")
    func draggingACornerMovesTheMarks() throws {
        // The correction UI's whole promise: fix the quad and the
        // verification geometry follows. If it did not, the marks would be
        // confirming a table the user had already changed.
        let original = reference()
        var corners = original.worldCorners
        corners = corners.map { $0 + Vec3(0.1, 0, 0) }
        let moved = try TableCalibration.fromCorners(corners,
                                                     preferredSize: original.size)
        let before = CalibrationVerification.overlay(for: original)
        let after = CalibrationVerification.overlay(for: moved)
        for (a, b) in zip(before.diamonds, after.diamonds) {
            #expect(abs((b - a).x - 0.1) < 0.01, "the diamonds did not follow the corners")
        }
    }

    @Test("A bigger table puts its marks further apart")
    func sizeChangesTheSpacing() {
        let eight = CalibrationVerification.diamonds(for: .eightFoot)
        let nine = CalibrationVerification.diamonds(for: .nineFoot)
        let spanEight = eight.map(\.x).max()! - eight.map(\.x).min()!
        let spanNine = nine.map(\.x).max()! - nine.map(\.x).min()!
        #expect(spanNine > spanEight)
        // And by the ratio of the tables, since the layout is proportional.
        let ratio = TableSize.nineFoot.playField.width / TableSize.eightFoot.playField.width
        #expect(abs(spanNine / spanEight - ratio) < 1e-9)
    }
}
