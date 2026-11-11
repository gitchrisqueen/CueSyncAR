//
//  SeededHUDUITests.swift
//  CueSync AR UI tests
//
//  The HUD with a table on it. The Simulator cannot run ARKit, so
//  LaunchSmokeUITests only ever sees the cold-start HUD. A DEBUG Simulator
//  build can be launched with `-seedTable <layout>` (App/Sources/DebugSeed.swift),
//  which installs a synthetic table and runs the app's own ranking, so the
//  shot card, the group button and the live-tracking status are on screen
//  for real: the same `ShotRanking` -> `ShotSelection` -> `ShotAdviceCluster`
//  path a device uses, minus the camera.
//
//  What it cannot do is tap a ball to choose it: that catcher lives in the
//  ARKit-only half of RootView. Choosing a different shot is covered here
//  through the group button, which re-ranks.
//

import XCTest

@MainActor
final class SeededHUDUITests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
    }

    private func launchSeeded(_ layout: String) -> XCUIApplication {
        let app = XCUIApplication()
        // `-ballGroup any` pins the persisted group (the argument domain
        // outranks it), so a previous run's cycling cannot change this one.
        app.launchArguments += ["-seedTable", layout, "-ballGroup", "any"]
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// The capsule exists from first launch ("Point at the table"); the
    /// seed lands a moment later, after the app's own bootstrap.
    private func waitForCapsule(_ app: XCUIApplication, containing text: String) {
        // By text, as LaunchSmokeUITests does: the capsule is a Label, so an
        // identifier query can land on its icon rather than its words.
        let capsule = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(capsule.waitForExistence(timeout: 60),
                      "status capsule never read '\(text)'; saw: "
                      + app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))
    }

    func testSeededTableShowsTheLiveHUD() {
        let app = launchSeeded("open")
        waitForCapsule(app, containing: "Tracking 5 balls")

        let card = element(app, "shot-card")
        XCTAssertTrue(card.waitForExistence(timeout: 10),
                      "no shot card: the seed did not reach the ranking")
        XCTAssertTrue(card.label.hasPrefix("Suggested shot:"), card.label)
        // A named ball into a pocket seen from the player's side, and a
        // difficulty word: never the percentage.
        XCTAssertTrue(card.label.contains(" into the "), card.label)
        let tiers = ["easy", "fair", "hard"]
        XCTAssertTrue(tiers.contains { card.label.hasSuffix(", \($0)") }, card.label)
        XCTAssertFalse(card.label.contains("per cent"), card.label)
        XCTAssertFalse(card.label.contains("%"), card.label)

        // The rest of the HUD a player has in front of them.
        XCTAssertTrue(element(app, "ball-group-button").exists, "no group button")
        XCTAssertTrue(app.buttons["calibrate-button"].exists, "no table control")
        XCTAssertTrue(element(app, "practice-mode-menu").exists, "no practice-mode control")
        XCTAssertTrue(app.buttons["more-button"].exists, "no More control")
        XCTAssertTrue(element(app, "table-scene").exists, "no seeded table drawn")

        // The cold-start copy is gone: a seeded table is a locked one.
        XCTAssertFalse(app.staticTexts["Point at the table"].exists)
    }

    func testChoosingAGroupReRanksAndChangesTheCard() {
        let app = launchSeeded("open")
        waitForCapsule(app, containing: "Tracking 5 balls")
        let card = element(app, "shot-card")
        let group = element(app, "ball-group-button")
        XCTAssertTrue(card.waitForExistence(timeout: 30), "no shot card")
        XCTAssertTrue(group.waitForExistence(timeout: 10), "no group button")

        // Any -> solids -> stripes. The open layout has two solids, one
        // stripe and the eight, so the best shot cannot be the same ball in
        // every group.
        var cards = [card.label]
        var groups = [group.label]
        for _ in 0..<2 {
            let before = group.label
            group.tap()
            let changed = NSPredicate(format: "label != %@", before)
            expectation(for: changed, evaluatedWith: group)
            waitForExpectations(timeout: 10)
            groups.append(group.label)
            cards.append(card.label)
        }
        XCTAssertEqual(Set(groups).count, 3, "the group button did not cycle: \(groups)")
        XCTAssertGreaterThan(Set(cards).count, 1,
                             "re-ranking by group never changed the shot: \(cards)")
    }

    /// Every pocket is blocked, so there is nothing to suggest: the app
    /// shows no card rather than a card for a shot that cannot be made.
    func testBlockedLayoutOffersNoShot() {
        let app = launchSeeded("blocked")
        waitForCapsule(app, containing: "Tracking 2 balls")
        // Tracking and the ranking are installed by one call, so the
        // capsule being up means the (empty) suggestion is already settled.
        XCTAssertFalse(element(app, "shot-card").exists,
                       "a blocked table was offered as a shot")
        XCTAssertTrue(element(app, "ball-group-button").exists)
        // ...and says why, instead of leaving the player wondering.
        XCTAssertTrue(element(app, "shot-empty").waitForExistence(timeout: 10),
                      "no 'No clean shot' capsule on a blocked table")
    }

    /// A full rack has nothing to rank: the card area says to break.
    func testFullRackSaysBreakTheRack() {
        let app = launchSeeded("rack")
        waitForCapsule(app, containing: "Tracking 16 balls")
        XCTAssertTrue(element(app, "shot-empty").waitForExistence(timeout: 10),
                      "no 'Break the rack' capsule on a full rack")
        XCTAssertFalse(element(app, "shot-card").exists)
    }

    /// Players never see developer instruments (build badge, mirror
    /// address, detector rows): the Simulator debug build unlocks them by
    /// default, so this pins the locked state explicitly.
    func testPlayerSeesNoDeveloperControlsInMore() {
        let app = XCUIApplication()
        app.launchArguments += ["-seedTable", "open", "-developerModeUnlocked", "NO"]
        app.launch()
        waitForCapsule(app, containing: "Tracking 5 balls")
        let more = app.buttons["more-button"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        XCTAssertTrue(app.buttons["more-settings"].waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "more-debug-mirror").exists, "debug mirror toggle visible to a player")
        XCTAssertFalse(app.staticTexts["Address"].exists, "mirror address visible to a player")
    }
}
