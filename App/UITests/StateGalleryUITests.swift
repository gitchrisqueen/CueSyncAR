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
            ("calibrate-adjust", "Drag each dot to a corner where the cushions meet"),
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
        let label = cardLabel(blocked)
        XCTAssertFalse(label.hasPrefix("Suggested shot"), label)
        expectText(blocked, "BLOCKED")
        // The reason a player can see on the table: another ball is on the
        // line, not "that cut is past 90°" for a pocket behind the ball.
        XCTAssertTrue(label.contains("in the cue ball's way"), label)
        XCTAssertFalse(label.contains("90"), label)
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
            ("losing-balls", "Only seeing 6 of 15 balls"),
            ("losing-balls-lowlight", "more light would help"),
            ("losing-one-of-fifteen", "Only seeing 1 of 15 balls"),
            ("one-ball", "Tracking 1 ball"),
            ("cue-ball-only", "No balls to shoot at"),
        ]
        for (scene, text) in cases {
            let app = launch(scene)
            expectText(app, text)
            XCTAssertFalse(app.staticTexts["Tracking 1 balls"].exists, "\(scene): wrong plural")
            app.terminate()
        }
    }

    /// The stale-lock capsule is a real button, with a hint, and tapping it
    /// starts calibration again; the shot card is held back; and the bar
    /// carries "Set up table" too.
    func testTableMovedIsAButtonAndHidesTheCard() {
        let app = launch("table-moved")
        expectText(app, "Table moved? Re-calibrate")
        let button = app.buttons["table-moved-button"]
        XCTAssertTrue(button.waitForExistence(timeout: 30), "the capsule is not a button")
        XCTAssertEqual(button.label, "Table moved? Re-calibrate")
        XCTAssertFalse(element(app, "shot-card").exists, "a shot card on a table that has moved")
        XCTAssertTrue(app.buttons["calibrate-button"].exists, "no Set up table in the bar")
        button.tap()
        // Calibration starts over: the capsule leaves the warning.
        expectText(app, "Point at the table")
        XCTAssertFalse(app.buttons["table-moved-button"].exists)
    }

    /// Tracking lost: the capsule carries it. No tick, no "Tracking N", no
    /// shot card, and no separate pill saying the same thing.
    func testTrackingLostSaysItOnce() {
        let app = launch("banner-tracking-lost")
        expectText(app, "Re-finding the table")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Tracking '")).firstMatch.exists)
        XCTAssertFalse(element(app, "shot-card").exists)
        XCTAssertFalse(element(app, "feedback-banner").exists, "a pill repeating the capsule")
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
        // With a card showing, the score is part of the card ("0 of 0").
        let empty = launch("scoreboard-empty")
        expectText(empty, "0 of 0")
        XCTAssertFalse(element(empty, "score-chip").exists, "a score chip under the card")
        empty.terminate()

        let made = launch("shot-made")
        // A make takes the shot card's slot; no pill stacks under it.
        XCTAssertTrue(element(made, "payoff-card").waitForExistence(timeout: 60))
        XCTAssertFalse(element(made, "shot-card").exists, "the card and the payoff at once")
        XCTAssertFalse(element(made, "feedback-banner").exists, "a pill under the payoff")
        // The score is inside the payoff, not a chip stacked under it.
        XCTAssertTrue(element(made, "payoff-card").label.contains("1 of 1"), element(made, "payoff-card").label)
        XCTAssertFalse(element(made, "score-chip").exists, "a score chip under the payoff")
        made.terminate()

        let missed = launch("shot-missed")
        XCTAssertTrue(element(missed, "payoff-card").waitForExistence(timeout: 60))
        XCTAssertFalse(element(missed, "feedback-banner").exists)
    }

    // MARK: Called shots

    func testCalledShots() {
        // No pocket called: nothing in the aim slot, no "On line".
        let none = launch("called-no-pocket")
        expectText(none, "Call your pocket")
        XCTAssertFalse(none.staticTexts.containing(NSPredicate(format: "label == 'On line'")).firstMatch.exists)
        none.terminate()

        // On line: ONE "On line" (the card's; the capsule keeps the count),
        // and the card is about the called pocket only.
        let on = launch("called-on-line")
        expectText(on, "On line")
        expectText(on, "Called")
        expectText(on, "Tracking")
        XCTAssertEqual(on.staticTexts.matching(NSPredicate(format: "label == 'On line'")).count, 1)
        XCTAssertFalse(on.staticTexts.containing(NSPredicate(format: "label CONTAINS 'send it'")).firstMatch.exists)
        XCTAssertFalse(on.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'CALLED:'")).firstMatch.exists)
        on.terminate()

        // A pocket called that the ball cannot go into: the slot is about
        // THAT pocket, so it says so, and shows no shot into another pocket.
        let off = launch("called-off-line")
        expectText(off, "No clean shot into the far-left corner")
        XCTAssertFalse(element(off, "shot-card").exists, "a shot card for a pocket nothing can go into")
        XCTAssertFalse(off.staticTexts.containing(NSPredicate(format: "label CONTAINS 'RIGHT CORNER'")).firstMatch.exists)
        XCTAssertFalse(off.staticTexts.containing(NSPredicate(format: "label == 'On line'")).firstMatch.exists)
        off.terminate()

        // The called pocket's own shot, aim a little off: which way.
        let aimed = launch("called-off-line-aimed")
        expectText(aimed, "Off line — move your aim")
        aimed.terminate()

        // No ball can go into the called pocket: say so, show no other shot.
        let none2 = launch("called-no-shot")
        expectText(none2, "No clean shot into the")
        XCTAssertFalse(element(none2, "shot-card").exists, "a shot card for a pocket nothing can go into")
    }

    /// A blocked pick with a called pocket: the reason is for that pocket.
    func testBlockedCalledCard() {
        let app = launch("blocked-called")
        let label = cardLabel(app)
        XCTAssertTrue(label.contains("in the cue ball's way"), label)
        expectText(app, "RIGHT CORNER")
    }

    /// The card does not move when the aim crosses the line: the capsule
    /// above it never changes height, so the card's top edge is the same on
    /// and off line.
    func testCardTopDoesNotMoveBetweenOnAndOffLine() {
        let on = launch("called-on-line")
        let onCard = element(on, "shot-card")
        XCTAssertTrue(onCard.waitForExistence(timeout: 60))
        let onTop = onCard.frame.minY
        on.terminate()

        let off = launch("called-off-line-aimed")
        let offCard = element(off, "shot-card")
        XCTAssertTrue(offCard.waitForExistence(timeout: 60))
        let offTop = offCard.frame.minY
        XCTAssertEqual(onTop, offTop, accuracy: 1.0, "the card jumped \(abs(onTop - offTop)) pt")
    }

    // MARK: Ball names

    func testBallNames() {
        let numbered = launch("tier-easy")
        expectText(numbered, "9 YELLOW STRIPE")
        numbered.terminate()
        let unknown = launch("ball-unknown")
        expectText(unknown, "BALL →")
    }

    // MARK: Recording and sheets

    func testRecordingBadge() {
        let app = launch("recording")
        // The badge reads "Recording, 0:00" to VoiceOver and "REC 0:00" on screen.
        expectText(app, "Recording")
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
