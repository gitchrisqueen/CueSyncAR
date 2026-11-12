//
//  StateGalleryUITests.swift
//  CueSync AR UI tests
//
//  The state gallery (App/Sources/DebugScenes.swift) as a regression net:
//  each scene is launched with `-seedScene <name>` and must put the words a
//  player would read on the screen. The scenes only feed the app's own entry
//  points, so a scene that stops reaching its state means the state itself
//  broke, not the test.
//
//  The scene names are the contract with DebugScenes.swift: a scene renamed
//  there and not here shows up as an "Unknown scene" toast and a failed wait.
//

import XCTest

@MainActor
final class StateGalleryUITests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
    }

    private func launch(_ scene: String, developerMode: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-seedScene", scene]
        if developerMode { app.launchArguments += ["-developerModeUnlocked", "YES"] }
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// Some visible text contains `text`, within `timeout` seconds.
    private func expectText(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 60,
                            file: StaticString = #filePath, line: UInt = #line) {
        let match = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: timeout),
                      "never read '\(text)'; saw: "
                      + app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "),
                      file: file, line: line)
    }

    /// The shot card's accessibility label.
    private func cardLabel(_ app: XCUIApplication) -> String {
        let card = element(app, "shot-card")
        XCTAssertTrue(card.waitForExistence(timeout: 60), "no shot card")
        return card.label
    }

    // MARK: Calibration (capsule states)

    func testCalibrationCapsuleStates() {
        let cases: [(scene: String, text: String)] = [
            ("calibrate-find", "Point at the table"),
            ("calibrate-corners-2", "(2/4)"),
            ("calibrate-corners-3", "(3/4)"),
            ("calibrate-adjust", "Drag dots onto the cushion noses"),
        ]
        for (scene, text) in cases {
            let app = launch(scene)
            expectText(app, text)
            XCTAssertTrue(app.buttons["calibrate-button"].exists, "no way out of '\(scene)'")
            app.terminate()
        }
    }

    // MARK: Tiers and labels

    func testTiersAndLabels() {
        let cases: [(scene: String, prefix: String, suffix: String)] = [
            ("tier-easy", "Suggested shot", ", easy"),
            ("tier-fair", "Suggested shot", ", fair"),
            ("tier-hard", "Suggested shot", ", hard"),
            ("label-your-pick", "Your pick", ""),
        ]
        for (scene, prefix, suffix) in cases {
            let app = launch(scene)
            let label = cardLabel(app)
            XCTAssertTrue(label.hasPrefix(prefix), "\(scene): \(label)")
            XCTAssertTrue(label.hasSuffix(suffix), "\(scene): \(label)")
            app.terminate()
        }
        let best = launch("tier-easy")
        expectText(best, "Best shot")
        best.terminate()
        let hard = launch("tier-hard")
        expectText(hard, "Best available")
        hard.terminate()
        let pick = launch("label-your-pick")
        expectText(pick, "Your pick")
    }

    // MARK: No shot, blocked, no cue ball

    func testNoShotStates() {
        let noClean = launch("no-clean-shot")
        XCTAssertTrue(element(noClean, "shot-empty").waitForExistence(timeout: 60))
        noClean.terminate()

        let rack = launch("break-rack")
        XCTAssertTrue(element(rack, "shot-empty").waitForExistence(timeout: 60))
        rack.terminate()

        let blocked = launch("blocked-shot")
        XCTAssertTrue(cardLabel(blocked).hasPrefix("Blocked"))
        blocked.terminate()

        let noCue = launch("no-cue-ball")
        expectText(noCue, "Place the cue ball")
    }

    // MARK: Health

    func testHealthStates() {
        let cases: [(scene: String, text: String)] = [
            ("table-moved", "Table moved? Re-calibrate"),
            ("low-light", "Need more light"),
            ("hold-steady", "Hold steady"),
            ("table-lost", "Re-finding the table"),
            ("losing-balls", "Only seeing 2 of 6 balls"),
            ("losing-balls-dark", "more light would help"),
            ("losing-one-of-fifteen", "Only seeing 1 of 15 balls"),
            ("one-ball", "Tracking 1 ball"),
        ]
        for (scene, text) in cases {
            let app = launch(scene)
            expectText(app, text)
            XCTAssertFalse(app.staticTexts["Tracking 1 balls"].exists, "\(scene): wrong plural")
            app.terminate()
        }
    }

    /// The stale-lock capsule is a button, and the shot card is held back.
    func testTableMovedIsAButtonAndHidesTheCard() {
        let app = launch("table-moved")
        expectText(app, "Table moved? Re-calibrate")
        XCTAssertTrue(app.buttons["Table moved? Re-calibrate"].exists
                      || app.buttons.containing(NSPredicate(format: "label CONTAINS 'Re-calibrate'")).firstMatch.exists)
        XCTAssertFalse(element(app, "shot-card").exists, "a shot card on a table that has moved")
    }

    // MARK: Guide tile

    func testGuideTileAppearsOnlyForARealWord() {
        let stun = launch("guide-stun")
        XCTAssertTrue(element(stun, "cue-ball-guide").waitForExistence(timeout: 60))
        XCTAssertTrue(element(stun, "cue-ball-guide").label.contains("stun"))
        stun.terminate()

        let draw = launch("guide-draw")
        XCTAssertTrue(element(draw, "cue-ball-guide").waitForExistence(timeout: 60))
        XCTAssertTrue(element(draw, "cue-ball-guide").label.contains("draw"))
        draw.terminate()

        let centre = launch("guide-centre")
        expectText(centre, "Tracking")
        XCTAssertTrue(element(centre, "shot-card").waitForExistence(timeout: 60))
        XCTAssertFalse(element(centre, "cue-ball-guide").exists, "a tile for a centre hit")
    }

    // MARK: Outcomes

    func testScoreboardAndOutcomes() {
        let empty = launch("scoreboard-empty")
        XCTAssertEqual(element(empty, "score-chip").label, "No shots yet this session")
        empty.terminate()

        let made = launch("shot-made")
        XCTAssertTrue(element(made, "feedback-banner").waitForExistence(timeout: 60))
        XCTAssertTrue(element(made, "score-chip").exists)
        made.terminate()

        let missed = launch("shot-missed")
        XCTAssertTrue(element(missed, "feedback-banner").waitForExistence(timeout: 60))
    }

    // MARK: Called shots

    func testCalledShots() {
        let none = launch("called-no-pocket")
        expectText(none, "Call your pocket")
        none.terminate()

        let on = launch("called-on-line")
        expectText(on, "On line")
        on.terminate()

        let off = launch("called-off-line")
        expectText(off, "Tracking")
        XCTAssertFalse(off.staticTexts.containing(NSPredicate(format: "label CONTAINS 'On line'")).firstMatch.exists)
    }

    // MARK: Recording and sheets

    func testRecordingBadge() {
        let app = launch("recording")
        expectText(app, "REC")
        XCTAssertTrue(app.buttons["record-button"].exists)
    }

    func testSheetsAreFreeOfDeveloperRowsUnlessUnlocked() {
        for sheet in ["sheet-more", "sheet-settings"] {
            let player = launch(sheet)
            XCTAssertTrue(player.navigationBars.firstMatch.waitForExistence(timeout: 60), sheet)
            XCTAssertFalse(element(player, "more-debug-mirror").exists, sheet)
            XCTAssertFalse(player.staticTexts["Address"].exists, sheet)
            player.terminate()
        }
        let developer = launch("sheet-more", developerMode: true)
        XCTAssertTrue(element(developer, "more-debug-mirror").waitForExistence(timeout: 60),
                      "developer rows missing with developer mode on")
    }
}
