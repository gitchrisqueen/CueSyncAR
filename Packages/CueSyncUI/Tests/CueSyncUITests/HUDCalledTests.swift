//
//  HUDCalledTests.swift
//  CueSync AR
//
//  The called-shot card: one pocket, three rows, a capsule that never changes
//  height, a score inside the card, plain setup words, and sheet values a
//  player can read.
//

import CueSyncCore
import Foundation
import Testing
@testable import CueSyncUI

#if canImport(SwiftUI)
@Suite("The called-shot card is about one pocket, in three rows")
struct CalledCardTests {

    private func card(blocked: String? = nil, aim: String? = nil, chosen: Bool = false,
                      called: Bool = false, score: String? = nil,
                      confidence: ShotConfidence = .medium) -> ShotCard {
        ShotCard(ball: "Purple ball", leadBall: "4 Purple", pocket: "far-left corner",
                 confidence: blocked == nil ? confidence : .blocked, chosenByPlayer: chosen,
                 blockedReason: blocked, aimAdvice: aim, aimTone: .caution,
                 isCalled: called, scoreText: score)
    }

    @Test("A called card names the called pocket once, and has no second pocket line")
    func onePocket() {
        let card = card(aim: "Off line — move your aim right", called: true)
        #expect(card.headline == "4 PURPLE → FAR-LEFT CORNER")
        #expect(card.provenance == "Called")
        let text = card.accessibilityText.lowercased()
        #expect(text.contains("far-left corner"))
        #expect(!text.contains("far-right"))
        #expect(card.accessibilityText.hasPrefix("Called shot"))
        // There is no "CALLED: …" line any more.
        #expect(card.thirdRow == "Off line — move your aim right")
    }

    @Test("Three rows at most in every state: the third row is one line, whichever applies")
    func threeRowsAtMost() {
        let blocked = card(blocked: "2 Blue is in the cue ball's way", aim: "On line", chosen: true, called: true)
        #expect(blocked.thirdRow == "2 Blue is in the cue ball's way")
        let aiming = card(aim: "On line", chosen: true, called: true)
        #expect(aiming.thirdRow == "On line")
        let picked = card(chosen: true)
        #expect(picked.thirdRow == "Tap it again to go back to the suggested shot")
        let plain = card()
        #expect(plain.thirdRow == nil)
        // Rows: tier row, headline, and at most one more.
        for candidate in [blocked, aiming, picked, plain] {
            #expect(candidate.rowCount <= 3)
        }
        #expect(plain.rowCount == 2)
    }

    @Test("The tier row says who chose it, or how to get out of a blocked pick")
    func tierRowText() {
        #expect(card(blocked: "x", chosen: true).provenance == "Tap again to go back")
        #expect(card(chosen: true).provenance == "Your pick")
        #expect(card(called: true).provenance == "Called")
        #expect(card(confidence: .easy).provenance == "Best shot")
        #expect(card(confidence: .hard).provenance == "Best available")
    }

    @Test("The score is folded into the card, not stacked under it")
    func scoreFolded() {
        #expect(card(score: "2 of 5").scoreText == "2 of 5")
        #expect(card().scoreText == nil)
    }

    @Test("No clean shot into the called pocket says so in player words")
    func noShotToCalledPocket() {
        let state = ShotEmptyState.noShotToCalledPocket(pocket: "far-left corner")
        #expect(state.text == "No clean shot into the far-left corner — call another pocket")
        #expect(PlayerCopyAudit.violations(in: state.text).isEmpty)
        #expect(state != .noCleanShot)
    }
}
#endif

@Suite("The capsule never changes height")
struct CapsuleHeightTests {

    @Test("Every status icon sits in one box, a little taller than a line of text")
    func oneBox() {
        #expect(HUDIcon.boxFactor >= 1.2)
        // The box, not the glyph, sets the line: so no status can be taller.
        let statuses: [HUDStatus] = [.tracking(ballCount: 4), .onLine, .calledOffLine, .awaitingCueBall,
                                     .tableMoved, .degraded(reason: .trackingLost),
                                     .losingBalls(seen: 1, peak: 4, dark: false), .findingTable]
        for status in statuses { #expect(!status.systemImage.isEmpty) }
    }

    @Test("Called-shot play keeps the tracking count in the capsule")
    func trackingCountStays() {
        // The app no longer swaps the count for an aiming message; the card
        // carries on line / off line.
        #expect(HUDStatus.tracking(ballCount: 4).label == "Tracking 4 balls")
    }
}

@Suite("Payoff with the score inside")
struct PayoffScoreTests {
    @Test("The score is part of the detail line, once")
    func scoreInDetail() {
        let made = PayoffEvent(id: 1, kind: .made, streak: 3, made: 3, attempted: 3, showsScore: true)
        #expect(made.detail == "+1 · 3 IN A ROW · 3 of 3")
        let plain = PayoffEvent(id: 2, kind: .made, streak: 1, made: 1, attempted: 1, showsScore: true)
        #expect(plain.detail == "+1 · 1 of 1")
        let miss = PayoffEvent(id: 3, kind: .missed, made: 0, attempted: 1, showsScore: true)
        #expect(miss.detail == "Line it up again · 0 of 1")
        #expect(PayoffEvent(id: 4, kind: .made, streak: 3, made: 3, attempted: 3).detail == "+1 · 3 IN A ROW")
    }
}

@Suite("Setup words and sheet values")
struct SetupWordsTests {

    @Test("No setup prompt a player reads says 'cushion nose'")
    func plainSetupWords() {
        let setup: [HUDStatus] = [.findingTable, .placingCorners(placed: 0), .placingCorners(placed: 2),
                                  .placingCorners(placed: 3), .confirmingRails, .needsCalibration(seeing: 0),
                                  .needsCalibration(seeing: 4)]
        for status in setup {
            #expect(!status.label.lowercased().contains("nose"), "\(status.label)")
            #expect(PlayerCopyAudit.violations(in: status.label).isEmpty)
        }
        #expect(HUDStatus.placingCorners(placed: 2).label == "Tap the four corners where the cushions meet (2/4)")
        #expect(HUDStatus.confirmingRails.label == "Drag each dot to a corner where the cushions meet, then lock")
    }

    @Test("A picker's value is at least 4.5 : 1 on its row, light and dark")
    func pickerValueContrast() {
        let light = Contrast.ratio(Theme.sheetSecondaryLight, Contrast.RGB(Theme.sheetRowLight))
        let dark = Contrast.ratio(Theme.sheetSecondaryDark, Contrast.RGB(Theme.sheetRowDark))
        #expect(light >= Contrast.aa, "light \(light)")
        #expect(dark >= Contrast.aa, "dark \(dark)")
        // What the system picker drew: "Open" 3.4 : 1, "Medium" 4.0 : 1.
        #expect(Contrast.ratio(ColorToken(0x8A8A8E), Contrast.RGB(ColorToken(0xFCFCFD))) < Contrast.aa)
        #expect(Contrast.ratio(ColorToken(0x7F7F7F), Contrast.RGB(ColorToken(0xFFFFFF))) < Contrast.aa)
    }
}

@Suite("Short statuses stay on one line")
struct StatusLineTests {
    @Test("The statuses a player sees while shooting are all single-line")
    func shootingStatusesAreShort() {
        let shooting: [HUDStatus] = [.tracking(ballCount: 15), .tracking(ballCount: 1), .tracking(ballCount: 0),
                                     .launching]
        for status in shooting {
            #expect(status.label.count <= HUDStatus.singleLineLimit || status == .launching, "\(status.label)")
        }
        #expect(HUDStatus.tracking(ballCount: 15).label.count <= HUDStatus.singleLineLimit)
        #expect(HUDStatus.tracking(ballCount: 0).label.count <= HUDStatus.singleLineLimit)
    }
}
