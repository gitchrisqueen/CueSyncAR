//
//  LaunchSmokeUITests.swift
//  CueSyncAR UI tests
//
//  What a Simulator can honestly assert about this app.
//
//  Scoped narrowly on purpose. `RootView.swift` substitutes
//  `SimulatorPlaceholderView` and the entire AR path — ARCameraView, the
//  tap catchers, CalibrationOverlayView — sits inside
//  `#if canImport(ARKit) && !targetEnvironment(simulator)`. That code is
//  not in the Simulator binary, so a UI test cannot drive calibration, or
//  tap-to-designate, or the camera permission prompt, no matter how it is
//  written. Those stay asserted by CalibrationController's pure tests and
//  by a device run.
//
//  What IS reachable is everything outside that guard: the status capsule,
//  the control bar, the More sheet and the whole of Settings — which is
//  where the developer-surface gating and the copy pass both live, and
//  where a regression would otherwise only be caught by someone looking.
//

import XCTest

final class LaunchSmokeUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        return app
    }

    /// The one that would have caught a malformed scene manifest or a
    /// crash in `bootstrap()`: does it get to a screen at all?
    func testAppLaunchesAndShowsTheStatusCapsule() {
        let app = launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        // "Point at the table" is the cold-start status. Matching on the
        // text rather than an identifier because this asserts the PLAYER'S
        // first impression, which is the thing worth pinning.
        let capsule = app.staticTexts["Point at the table"]
        XCTAssertTrue(capsule.waitForExistence(timeout: 20),
                      "no status capsule — the app launched but never got to a HUD")
    }

    /// The three controls the HUD rewrite settled on. A fourth appearing
    /// in a Release build would mean a developer surface escaped its gate.
    func testControlBarHasTheExpectedControls() {
        let app = launch()
        // By identifier, not by label: the practice-mode control is a Menu,
        // whose accessibility label is the SELECTED mode and therefore
        // changes as soon as anyone picks a different one.
        XCTAssertTrue(app.buttons["calibrate-button"].waitForExistence(timeout: 20),
                      "no Set up table control")
        XCTAssertTrue(app.buttons["practice-mode-menu"].exists, "no practice-mode control")
        XCTAssertTrue(app.buttons["more-button"].exists, "no More control")
    }

    /// Settings is where the copy pass and the developer gate both live.
    func testSettingsOpensAndShowsPlayerFacingRows() {
        let app = launch()
        XCTAssertTrue(app.buttons["calibrate-button"].waitForExistence(timeout: 20))

        // The More sheet is the only route to Settings.
        let more = app.buttons["more-button"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), "no More control to open")
        more.tap()
        let settings = app.buttons["more-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10),
                      "the More sheet did not offer Settings")
        settings.tap()

        // Player-facing rows, by the identifiers they already carry.
        let tableSize = app.descendants(matching: .any)["settings-table-size"]
        XCTAssertTrue(tableSize.waitForExistence(timeout: 10),
                      "Settings opened but has no table-size row")
        // The About row is always present and carries the developer unlock,
        // so it is the one row that must survive every gating change. It
        // sits near the bottom of the form, so it has to be scrolled to —
        // `exists` is false for a cell that has never been rendered.
        let version = app.descendants(matching: .any)["settings-version"]
        var swipes = 0
        while !version.exists && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(version.exists,
                      "the About row carries the developer unlock and must always be present")
    }

    /// A raw enum case, a script name or a `(remote)` marker on screen is
    /// the exact class of leak the copy pass removed. This is the app-side
    /// half of `PlayerCopyAudit`, which can only see CueSyncUI's strings.
    func testNoDeveloperVocabularyOnTheFirstScreen() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Point at the table"].waitForExistence(timeout: 20))
        let visible = app.staticTexts.allElementsBoundByIndex.compactMap { $0.label }
        for text in visible {
            XCTAssertFalse(text.contains("(remote)"), "\(text) leaks a developer marker")
            XCTAssertFalse(text.contains(".sh"), "\(text) names a script")
            XCTAssertFalse(text.contains("Scripts/"), "\(text) names a source path")
        }
    }
}
