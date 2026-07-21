import Testing
@testable import CueSyncUI

@Suite("HUDStatus calibration states")
struct HUDStatusCalibrationTests {
    @Test func placingCornersShowsProgressCount() {
        #expect(HUDStatus.placingCorners(placed: 0).label == "Tap the rail corners (0/4)")
        #expect(HUDStatus.placingCorners(placed: 3).label == "Tap the rail corners (3/4)")
        #expect(HUDStatus.placingCorners(placed: 0).systemImage == "hand.tap")
    }

    @Test func calibrationStatesKeepFullOverlayOpacity() {
        #expect(HUDStatus.placingCorners(placed: 1).overlayOpacity == 1.0)
        #expect(HUDStatus.confirmingRails.overlayOpacity == 1.0)
    }
}
