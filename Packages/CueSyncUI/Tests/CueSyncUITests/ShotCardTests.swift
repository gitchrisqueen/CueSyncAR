import CueSyncCore
import Foundation
import Testing
@testable import CueSyncUI

@Suite("ShotConfidence")
struct ShotConfidenceTests {
    @Test("Colour follows how likely the shot is, using the existing tokens")
    func tokensMatchTheDesignSystem() {
        #expect(ShotConfidence.easy.token == Theme.feltGreen)
        #expect(ShotConfidence.medium.token == Theme.cueAmber)
        // A hard shot has its own colour (orange); only a block is red.
        for band in [ShotConfidence.hard, .longShot] {
            #expect(band.token == Theme.hardTier)
        }
        #expect(ShotConfidence.blocked.token == Theme.warnCoral)
        #expect(ShotConfidence.hard.token != ShotConfidence.blocked.token)
        #expect(ShotConfidence.hard.textToken != ShotConfidence.blocked.textToken)
    }

    @Test("Every band has a distinct word a person could hear")
    func wordsAreDistinctAndSpeakable() {
        let words = ShotConfidence.allCases.map(\.word)
        #expect(Set(words).count == words.count)
        #expect(words.allSatisfy { !$0.isEmpty && $0.lowercased() == $0 })
        #expect(ShotConfidence.longShot.word == "long shot")
    }

    @Test("The player sees three tiers and a block, never five bands")
    func tierWords() {
        #expect(ShotConfidence.easy.tierWord == "Easy")
        #expect(ShotConfidence.medium.tierWord == "Fair")
        #expect(ShotConfidence.hard.tierWord == "Hard")
        // A long shot is just a hard one to the person at the table.
        #expect(ShotConfidence.longShot.tierWord == "Hard")
        #expect(ShotConfidence.blocked.tierWord == "Blocked")
    }

    @Test("Meaning is never colour-only: each tier has its own shape")
    func tiersHaveShapes() {
        let shapes = [ShotConfidence.easy, .medium, .hard, .blocked].map(\.tierSymbol)
        #expect(Set(shapes).count == shapes.count)
        #expect(ShotConfidence.longShot.tierSymbol == ShotConfidence.hard.tierSymbol)
        // And a distinct word for each of the three tiers.
        #expect(Set([ShotConfidence.easy, .medium, .hard].map(\.tierWord)).count == 3)
    }

    @Test("Tier text is the brighter sibling of the tier colour, on the same hue")
    func textTokensAreTextGrade() {
        for band in ShotConfidence.allCases {
            let table = Contrast.RGB(band.token)
            let text = Contrast.RGB(band.textToken)
            #expect(Contrast.relativeLuminance(text) > Contrast.relativeLuminance(table),
                    "\(band)")
        }
    }

    @Test("Raw values are stable for persistence and for the mirror")
    func rawValuesAreStable() {
        let raws: [String] = ShotConfidence.allCases.map(\.rawValue)
        #expect(raws == ["easy", "medium", "hard", "longShot", "blocked"])
    }
}

#if canImport(SwiftUI)
@Suite("ShotCard")
struct ShotCardTests {
    @Test("A normal shot reads as ball, pocket and a tier word, with no number")
    func announcesTheShot() {
        let card = ShotCard(ball: "Blue ball", pocket: "right side pocket",
                            confidence: .medium, chosenByPlayer: false)
        #expect(card.accessibilityText
                == "Suggested shot: Blue ball into the right side pocket, fair")
        #expect(card.callLine == "Blue ball → right side pocket")
        let digits = card.accessibilityText.filter(\.isNumber)
        #expect(digits.isEmpty, "a percentage leaked into the label")
        #expect(!card.accessibilityText.contains("per cent"))
    }

    @Test("The player's own pick is announced as theirs")
    func distinguishesThePlayersPick() {
        let card = ShotCard(ball: "Red ball", pocket: "near side pocket",
                            confidence: .easy, chosenByPlayer: true)
        #expect(card.accessibilityText.hasPrefix("Your pick"))
        #expect(card.accessibilityText.hasSuffix(", easy"))
        #expect(card.hint == "Your pick — tap again to go back to the suggested shot")
    }

    @Test("A suggestion that is not good does not claim to be the best")
    func hintDoesNotOversell() {
        func hint(_ confidence: ShotConfidence) -> String {
            ShotCard(ball: "Ball", pocket: nil, confidence: confidence,
                     chosenByPlayer: false).hint
        }
        #expect(hint(.easy).hasPrefix("Best shot"))
        #expect(hint(.medium).hasPrefix("Best shot"))
        #expect(hint(.hard).hasPrefix("Best available"))
        #expect(hint(.longShot).hasPrefix("Best available"))
    }

    @Test("A blocked shot announces the reason, never a zero")
    func blockedShotsGiveTheReason() {
        let card = ShotCard(ball: nil, pocket: nil, confidence: .blocked,
                            chosenByPlayer: true,
                            blockedReason: "Blocked — a ball is in the cue ball's way")
        #expect(card.accessibilityText == "Blocked — a ball is in the cue ball's way")
        #expect(!card.accessibilityText.contains("0"))
    }

    @Test("Aim advice is announced after the shot, not instead of it")
    func aimAdviceIsAppended() {
        let card = ShotCard(ball: "Maroon ball", pocket: "far side pocket", confidence: .medium,
                            chosenByPlayer: false, aimAdvice: "Aim a little left")
        #expect(card.accessibilityText.hasSuffix(". Aim a little left"))
        #expect(card.accessibilityText.contains("Maroon ball into the far side pocket"))
    }

    @Test("A blocked shot is not given aiming advice it cannot use")
    func blockedShotsSkipAdvice() {
        let card = ShotCard(ball: nil, pocket: nil, confidence: .blocked,
                            chosenByPlayer: false,
                            blockedReason: "Blocked — a ball is in the cue ball's way",
                            aimAdvice: "Aim a little right")
        #expect(!card.accessibilityText.contains("right"))
    }

    @Test("A card with nothing to say still names who chose it, and how hard")
    func degradesWithoutNames() {
        #expect(ShotCard(ball: nil, pocket: nil, confidence: .hard,
                         chosenByPlayer: false).accessibilityText == "Suggested shot, hard")
        #expect(ShotCard(ball: nil, pocket: nil, confidence: .easy,
                         chosenByPlayer: true).accessibilityText == "Your pick, easy")
    }

    @Test("A pocket is never shown without its ball, and a ball can be shown without its pocket")
    func callLineDegrades() {
        #expect(ShotCard(ball: "Blue ball", pocket: nil, confidence: .easy,
                         chosenByPlayer: false).callLine == "Blue ball")
        #expect(ShotCard(ball: nil, pocket: nil, confidence: .easy,
                         chosenByPlayer: false).callLine == nil)
    }
}

@Suite("ShotEmptyState")
struct ShotEmptyStateTests {
    @Test("The two empty tables each say what to do next")
    func copy() {
        #expect(ShotEmptyState.noCleanShot.text == "No clean shot — try a safety")
        #expect(ShotEmptyState.breakRack.text == "Break the rack")
        #expect(ShotEmptyState.noCleanShot.systemImage != ShotEmptyState.breakRack.systemImage)
    }

    @Test("The copy passes the player-copy audit")
    func auditsClean() {
        for state in [ShotEmptyState.noCleanShot, .breakRack] {
            #expect(PlayerCopyAudit.violations(in: state.text).isEmpty)
        }
    }
}
#endif
