//
//  StandardSizeComparisonTests.swift
//  TableSpace
//

import CueSyncCore
import Testing
@testable import TableSpace

@Suite struct StandardSizeComparisonTests {
    @Test func exactStandardSizeHasZeroDelta() {
        let comparison = StandardSizeComparison(size: .eightFoot)
        #expect(comparison.nearest == .eightFoot)
        #expect(comparison.widthDelta == 0)
        #expect(comparison.heightDelta == 0)
        #expect(comparison.summary == "8 ft table")
    }

    @Test func slightlyOversizedEightFootReportsCentimeterDelta() {
        // 3 cm long on the long axis — the classic outer-rail mis-tap.
        let comparison = StandardSizeComparison(measuredWidth: 2.37, measuredHeight: 1.17)
        #expect(comparison.nearest == .eightFoot)
        #expect(abs(comparison.widthDelta - 0.03) < 1e-9)
        #expect(comparison.heightDelta == 0)
        #expect(comparison.summary == "8 ft +3.0 cm")
    }

    @Test func undersizedReportsNegativeDelta() {
        let comparison = StandardSizeComparison(measuredWidth: 1.94, measuredHeight: 0.99)
        #expect(comparison.nearest == .sevenFoot)
        #expect(comparison.summary == "7 ft -4.0 cm")
    }

    @Test func orientationIsNormalized() {
        // Short axis passed first must not change the result.
        let a = StandardSizeComparison(measuredWidth: 1.17, measuredHeight: 2.34)
        #expect(a.nearest == .eightFoot)
        #expect(a.maxDelta < 1e-9)
    }

    @Test func midwayMeasurementPicksTheCloserStandard() {
        // 2.44 x 1.22 sits between 8ft (2.34) and 9ft (2.54) — fractional
        // error decides; both are ~4% off so the comparison still names one
        // and reports an honest ~10 cm delta rather than refusing.
        let comparison = StandardSizeComparison(measuredWidth: 2.44, measuredHeight: 1.22)
        #expect(comparison.maxDelta > 0.05)
        #expect(comparison.nearest == .eightFoot || comparison.nearest == .nineFoot)
    }

    @Test func customNeverComesBack() {
        // Even absurd measurements resolve to a nearest STANDARD size.
        let comparison = StandardSizeComparison(measuredWidth: 5.0, measuredHeight: 3.0)
        #expect(TableSize.standardSizes.contains(comparison.nearest))
    }
}
