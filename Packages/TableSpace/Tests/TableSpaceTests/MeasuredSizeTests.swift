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
        var object = try jsonDictionary(calibration)
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
        var object = try jsonDictionary(anchored)
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

    /// The regression this pair exists for. 2.26 x 1.09 is 8 cm under the
    /// 8 ft standard on both axes — 3.3 %, inside the old 8 % fractional
    /// tolerance, so it used to snap. `Table(size:)` then built pockets and
    /// cushions from the 2.34 x 1.17 standard while the origin and axes
    /// came from the tapped corners, drawing every pocket ~4 cm outside the
    /// real one. It must lock as measured instead.
    @Test func aRealTableEightCentimetresUnderSpecLocksAsMeasured() throws {
        let calibration = try TableCalibration.fromCorners(realTableCorners)
        #expect(calibration.size == .custom(width: 2.26, height: 1.09))
        #expect(abs((calibration.measuredWidth ?? 0) - 2.26) < 1e-9)
        // Still reported against the nearest standard, so the HUD can tell
        // the user how far off they are and offer a re-tap.
        #expect(calibration.standardSizeComparison.summary == "8 ft -8.0 cm")
    }

    @Test func measurementNoiseInsideThreeCentimetresStillSnaps() throws {
        // 2 cm under on the long axis, exact on the short: corner-tap noise,
        // not a different table.
        let corners = [Vec3(0, 0, 0), Vec3(2.32, 0, 0),
                       Vec3(2.32, 0, 1.17), Vec3(0, 0, 1.17)]
        let calibration = try TableCalibration.fromCorners(corners)
        #expect(calibration.size == .eightFoot)
    }

    @Test func theSavedSpecIsAlsoBoundedByTheAbsoluteRule() throws {
        // A spec 9 cm away must not capture a different table either.
        let spec = TableSize.custom(width: 2.35, height: 1.18)
        let calibration = try TableCalibration.fromCorners(realTableCorners,
                                                           preferredSize: spec)
        #expect(calibration.size == .custom(width: 2.26, height: 1.09))
    }
}

/// Encode a value and read it back as a mutable JSON dictionary, so a test can
/// strip fields that a pre-T1.2 payload would not have carried. Throws rather
/// than force-casting: a non-object payload is a test-setup bug worth a failure
/// message, not a crash.
private func jsonDictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "encoded \(T.self) is not a JSON object"))
    }
    return object
}

/// Venues locked under the old symmetric snap rule carry a standard size
/// over a measurement that contradicts it. They must self-correct on load,
/// because the alternative is asking every user to re-tap their table.
@Suite struct UndersizedSnapMigrationTests {
    /// As persisted from Christopher's table: labelled 8 ft, measured 9 cm
    /// smaller, drawing every pocket ~4.5 cm outside the real one.
    private var legacy: TableCalibration {
        TableCalibration(origin: .zero, xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 0, 1),
                         size: .eightFoot,
                         measuredWidth: 2.249, measuredHeight: 1.125)
    }

    @Test func aStandardLabelOverASmallerMeasurementBecomesCustom() {
        let corrected = legacy.correctingUndersizedSnap()
        #expect(corrected.size == .custom(width: 2.249, height: 1.125))
        // Origin and axes are untouched — only the size label was wrong.
        #expect(corrected.origin == legacy.origin)
        #expect(corrected.xAxis == legacy.xAxis)
        #expect(corrected.measuredWidth == legacy.measuredWidth)
    }

    @Test func aMeasurementInsideTheBoundIsLeftAlone() {
        let fine = TableCalibration(origin: .zero, xAxis: Vec3(1, 0, 0),
                                    yAxis: Vec3(0, 0, 1), size: .eightFoot,
                                    measuredWidth: 2.32, measuredHeight: 1.17)
        #expect(fine.correctingUndersizedSnap().size == .eightFoot)
    }

    @Test func anInflatedFieldIsLeftAlone() {
        // Rail-top taps measure BIGGER; the snap is correct there.
        let inflated = TableCalibration(origin: .zero, xAxis: Vec3(1, 0, 0),
                                        yAxis: Vec3(0, 0, 1), size: .eightFoot,
                                        measuredWidth: 2.42, measuredHeight: 1.21)
        #expect(inflated.correctingUndersizedSnap().size == .eightFoot)
    }

    @Test func recordsWithoutAMeasurementAreLeftAlone() {
        let preT12 = TableCalibration(origin: .zero, xAxis: Vec3(1, 0, 0),
                                      yAxis: Vec3(0, 0, 1), size: .eightFoot)
        #expect(preT12.correctingUndersizedSnap().size == .eightFoot)
    }

    @Test func theAnchoredRecordMigratesToo() {
        let anchored = AnchoredCalibration(calibration: legacy,
                                           anchorTransform: .identity)
        let corrected = anchored.correctingUndersizedSnap()
        #expect(corrected.size == .custom(width: 2.249, height: 1.125))
        let world = corrected.worldCalibration(anchorTransform: .identity)
        #expect(world.size == .custom(width: 2.249, height: 1.125))
    }
}
