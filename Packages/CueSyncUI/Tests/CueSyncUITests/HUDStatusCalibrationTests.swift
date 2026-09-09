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

@Suite("HUDStatus before calibration")
struct HUDStatusNeedsCalibrationTests {
    /// The capsule used to report the raw detector's box count as
    /// "Tracking N balls" whenever a model was loaded, calibrated table or
    /// not. Off a table there is nothing to gate those boxes against, so
    /// they land on floor tiles and window frames — and the player was
    /// told the app was tracking twenty balls while it tracked none.
    @Test("Before calibration the capsule never claims to be tracking")
    func doesNotClaimTracking() {
        for seeing in [0, 1, 8, 21] {
            let label = HUDStatus.needsCalibration(seeing: seeing).label
            #expect(!label.hasPrefix("Tracking"))
            #expect(label.lowercased().contains("calibrate"))
        }
    }

    @Test("What it can see is called objects, not balls")
    func countsObjectsNotBalls() {
        let label = HUDStatus.needsCalibration(seeing: 21).label
        #expect(label.contains("21 objects"))
        #expect(label.contains("tracking none"))
        #expect(!label.contains("balls"))
    }

    @Test("With nothing detected it just asks for calibration")
    func silentWhenNothingIsSeen() {
        let label = HUDStatus.needsCalibration(seeing: 0).label
        #expect(label == "Tap anywhere to calibrate the table")
        #expect(!label.contains("0"))
    }

    /// The capsule promises the screen is tappable, and
    /// CalibrationInviteCatcher is what makes that true. If the copy ever
    /// stops saying so, the affordance has probably gone with it.
    @Test("The copy tells the player the whole screen is the target")
    func copyMatchesTheAffordance() {
        for seeing in [0, 12] {
            #expect(HUDStatus.needsCalibration(seeing: seeing).label
                .lowercased().contains("tap anywhere"))
        }
    }

    @Test("The icon does not show a checkmark before anything works")
    func iconDoesNotClaimSuccess() {
        #expect(HUDStatus.needsCalibration(seeing: 5).systemImage != "checkmark.circle")
        #expect(HUDStatus.tracking(ballCount: 5).systemImage == "checkmark.circle")
    }

    @Test("It is a normal-confidence state, not a degraded one")
    func notDegraded() {
        #expect(HUDStatus.needsCalibration(seeing: 3).overlayOpacity == 1.0)
    }
}
