import Testing
@testable import CueSyncUI

@Suite("HUDStatus calibration states")
struct HUDStatusCalibrationTests {
    @Test func placingCornersShowsProgressCount() {
        #expect(HUDStatus.placingCorners(placed: 0).label == "Tap the cushion-nose corners (0/4)")
        #expect(HUDStatus.placingCorners(placed: 3).label == "Tap the cushion-nose corners (3/4)")
        #expect(HUDStatus.placingCorners(placed: 0).systemImage == "hand.tap")
    }

    @Test func calibrationStatesKeepFullOverlayOpacity() {
        #expect(HUDStatus.placingCorners(placed: 1).overlayOpacity == 1.0)
        #expect(HUDStatus.confirmingRails.overlayOpacity == 1.0)
    }
}

/// The degraded states existed for months with nothing able to produce
/// them, so a player in a dim room was shown ARKit's raw enum name
/// ("Tracking limited: insufficientFeatures") instead of a sentence.
@Suite("HUD degraded states")
struct HUDDegradedStateTests {
    @Test func everyDegradedReasonHasAPlayerReadableLabel() {
        let labels = HUDStatus.DegradedReason.allCasesForTest.map {
            HUDStatus.degraded(reason: $0).label
        }
        // No label may leak an identifier: no camelCase run, no dots.
        for label in labels {
            #expect(!label.contains("."))
            #expect(label.first?.isUppercase == true)
            #expect(label.count > 4)
        }
        #expect(Set(labels).count == labels.count, "each reason reads differently")
    }

    @Test func lowLightSaysWhatToDoAboutIt() {
        #expect(HUDStatus.degraded(reason: .lowLight).label == "Need more light")
    }
}

extension HUDStatus.DegradedReason {
    /// `allCases` is not synthesised here (the enum is RawRepresentable but
    /// not CaseIterable in the shipping type); listed explicitly so a new
    /// reason fails to compile this test rather than silently skipping it.
    static var allCasesForTest: [HUDStatus.DegradedReason] {
        [.fastMotion, .lowLight, .trackingLost]
    }
}
