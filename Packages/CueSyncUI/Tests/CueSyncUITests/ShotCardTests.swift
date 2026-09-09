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
        // Everything a player should think twice about shares one colour.
        for band in [ShotConfidence.hard, .longShot, .blocked] {
            #expect(band.token == Theme.warnCoral)
        }
    }

    @Test("Every band has a distinct word a person could hear")
    func wordsAreDistinctAndSpeakable() {
        let words = ShotConfidence.allCases.map(\.word)
        #expect(Set(words).count == words.count)
        #expect(words.allSatisfy { !$0.isEmpty && $0.lowercased() == $0 })
        #expect(ShotConfidence.longShot.word == "long shot")
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
    @Test("A normal shot reads as a percentage into a named pocket")
    func announcesTheShot() {
        let card = ShotCard(percentage: 62, pocket: "top-right corner",
                            confidence: .medium, chosenByPlayer: false)
        #expect(card.accessibilityText
                == "Suggested shot: 62 per cent into the top-right corner, makeable")
    }

    @Test("The player's own pick is announced as theirs")
    func distinguishesThePlayersPick() {
        let card = ShotCard(percentage: 91, pocket: "bottom side",
                            confidence: .easy, chosenByPlayer: true)
        #expect(card.accessibilityText.hasPrefix("Your pick"))
        #expect(card.accessibilityText.contains("good"))
    }

    @Test("A blocked shot announces the reason, never a zero")
    func blockedShotsGiveTheReason() {
        let card = ShotCard(percentage: nil, pocket: nil, confidence: .blocked,
                            chosenByPlayer: true,
                            blockedReason: "Blocked — a ball is in the cue ball's way")
        #expect(card.accessibilityText == "Blocked — a ball is in the cue ball's way")
        #expect(!card.accessibilityText.contains("0"))
    }

    @Test("A card with nothing to say still names who chose it")
    func degradesWithoutNumbers() {
        #expect(ShotCard(percentage: nil, pocket: nil, confidence: .hard,
                         chosenByPlayer: false).accessibilityText == "Suggested shot")
        #expect(ShotCard(percentage: 40, pocket: nil, confidence: .hard,
                         chosenByPlayer: true).accessibilityText == "Your pick")
    }
}
#endif
