//
//  MeasuredSizeTests.swift
//  TableSpace
//
//  T1.2: the raw pre-snap measurement must survive the lock (the snap can
//  legally hide up to 8% of corner error) and old persisted calibrations
//  without the field must still decode.
//

import CueSyncCore
import Foundation
import Testing
@testable import TableSpace

@Suite struct MeasuredSizeTests {
    /// An 8 ft field 3 cm oversized on the long axis, corners in order.
    private var corners: [Vec3] {
        [Vec3(0, 0, 0), Vec3(2.37, 0, 0), Vec3(2.37, 0, 1.17), Vec3(0, 0, 1.17)]
    }

    @Test func fromCornersKeepsThePreSnapMeasurement() throws {
        let calibration = try TableCalibration.fromCorners(corners)
        #expect(calibration.size == .eightFoot) // snapped (3 cm < 8 cm tolerance)
        #expect(abs((calibration.measuredWidth ?? 0) - 2.37) < 1e-9)
        #expect(abs((calibration.measuredHeight ?? 0) - 1.17) < 1e-9)
        #expect(calibration.standardSizeComparison.summary == "8 ft +3.0 cm")
    }

    @Test func preT12CalibrationJSONStillDecodes() throws {
        let calibration = TableCalibration(origin: .zero, xAxis: Vec3(1, 0, 0),
                                           yAxis: Vec3(0, 0, 1), size: .nineFoot)
        var object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(calibration)) as! [String: Any]
        // Simulate a pre-T1.2 payload: the measured fields never existed.
        object.removeValue(forKey: "measuredWidth")
        object.removeValue(forKey: "measuredHeight")
        let decoded = try JSONDecoder().decode(
            TableCalibration.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.measuredWidth == nil)
        #expect(decoded.size == .nineFoot)
        // Fallback comparison reads the snapped size: exact match.
        #expect(decoded.standardSizeComparison.summary == "9 ft table")
    }
}

@Suite struct AnchoredMeasuredSizeTests {
    @Test func measurementSurvivesTheAnchorRoundTrip() throws {
        let corners = [Vec3(0, 0, 0), Vec3(2.37, 0, 0),
                       Vec3(2.37, 0, 1.17), Vec3(0, 0, 1.17)]
        let calibration = try TableCalibration.fromCorners(corners)
        let anchored = AnchoredCalibration(calibration: calibration,
                                           anchorTransform: .identity)
        let restored = anchored.worldCalibration(anchorTransform: .identity)
        #expect(restored.measuredWidth == calibration.measuredWidth)
        #expect(restored.standardSizeComparison.summary == "8 ft +3.0 cm")
    }

    @Test func preT12AnchoredRecordStillDecodes() throws {
        let anchored = AnchoredCalibration(
            calibration: TableCalibration(origin: .zero, xAxis: Vec3(1, 0, 0),
                                          yAxis: Vec3(0, 0, 1), size: .eightFoot),
            anchorTransform: .identity)
        var object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(anchored)) as! [String: Any]
        object.removeValue(forKey: "measuredWidth")
        object.removeValue(forKey: "measuredHeight")
        let decoded = try JSONDecoder().decode(
            AnchoredCalibration.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.measuredWidth == nil)
        #expect(decoded.worldCalibration(anchorTransform: .identity).size == .eightFoot)
    }
}

@Suite struct PreferredSizeSnapTests {
    /// Corners measuring 2.26 x 1.09 — Chris's real 8 ft table, slightly
    /// under spec, as measured by a careful cushion-nose pin.
    private var realTableCorners: [Vec3] {
        [Vec3(0, 0, 0), Vec3(2.26, 0, 0), Vec3(2.26, 0, 1.09), Vec3(0, 0, 1.09)]
    }

    @Test func repinSnapsToTheSavedSpecNotTheGenericStandard() throws {
        let spec = TableSize.custom(width: 2.263, height: 1.093)
        let calibration = try TableCalibration.fromCorners(realTableCorners,
                                                           preferredSize: spec)
        #expect(calibration.size == spec)
        // The raw measurement is still the tap, not the spec.
        #expect(abs((calibration.measuredWidth ?? 0) - 2.26) < 1e-9)
    }

    @Test func farOffMeasurementIgnoresTheSpec() throws {
        // A 7 ft pub table is ~12% off the saved 8 ft-ish spec — the spec
        // must NOT capture it; the standard inference wins.
        let corners = [Vec3(0, 0, 0), Vec3(1.98, 0, 0),
                       Vec3(1.98, 0, 0.99), Vec3(0, 0, 0.99)]
        let spec = TableSize.custom(width: 2.263, height: 1.093)
        let calibration = try TableCalibration.fromCorners(corners,
                                                           preferredSize: spec)
        #expect(calibration.size == .sevenFoot)
    }

    @Test func nilSpecKeepsLegacyBehavior() throws {
        let calibration = try TableCalibration.fromCorners(realTableCorners)
        #expect(calibration.size == .eightFoot) // 3.3% off -> standard snap
    }
}
