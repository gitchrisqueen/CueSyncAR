//
//  ShotAdvisorHUDUITests.swift
//  CueSync AR UI tests
//
//  Simulator-only (the app seeds a synthetic table from `-seedTable`, see
//  App/Sources/DebugSeed.swift): the advisor card and its cycle button must be
//  reachable by accessibility identifier, and cycling must change the shot.
//

import XCTest

@MainActor
final class ShotAdvisorHUDUITests: XCTestCase {
    private func launchSeeded(_ layout: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-seedTable", layout]
        app.launch()
        return app
    }

    func testCardAndNextShotButtonAreReachableAndCycle() throws {
        let app = launchSeeded("open")
        let card = app.descendants(matching: .any)["shot-advisor-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 30), "shot-advisor-card not found")
        let next = app.buttons["next-shot-button"]
        XCTAssertTrue(next.waitForExistence(timeout: 5), "next-shot-button not found")
        XCTAssertTrue(app.descendants(matching: .any)["table-minimap"].exists, "mini-map missing")

        let before = card.label
        XCTAssertTrue(before.hasPrefix("Suggested shot:"), before)
        next.tap()
        let deadline = Date().addingTimeInterval(5)
        while card.label == before, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertNotEqual(card.label, before)
    }

    func testBlockedLayoutShowsNoCleanShotInsteadOfCard() throws {
        let app = launchSeeded("blocked")
        let message = app.staticTexts.containing(
            NSPredicate(format: "label BEGINSWITH 'No clean shot'")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 30), "no-clean-shot capsule missing")
        XCTAssertFalse(app.descendants(matching: .any)["shot-advisor-card"].exists)
    }
}
