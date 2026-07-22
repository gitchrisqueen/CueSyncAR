import Foundation
import Testing
@testable import CoachKit

@Suite("PracticeMode")
struct PracticeModeTests {
    @Test func freePlayIsPermissive() {
        let config = PracticeMode.freePlay.configuration
        #expect(config.showsShotGuides)
        #expect(!config.requiresCalledPocket)
        #expect(!config.showsDrillTargets)
        #expect(PracticeMode.freePlay.pendingHint(hasCalledPocket: false) == nil)
    }

    @Test func calledShotsRequiresAPocketUntilOneIsCalled() {
        let config = PracticeMode.calledShots.configuration
        #expect(config.requiresCalledPocket)
        #expect(PracticeMode.calledShots.pendingHint(hasCalledPocket: false) != nil)
        #expect(PracticeMode.calledShots.pendingHint(hasCalledPocket: true) == nil)
    }

    @Test func guidedDrillExposesTargetsAndAnHonestPlaceholderHint() {
        let config = PracticeMode.guidedDrill.configuration
        #expect(config.showsDrillTargets)
        // M6-03 content isn't here yet — the mode must say so rather than
        // silently behaving like free play.
        #expect(PracticeMode.guidedDrill.pendingHint(hasCalledPocket: false) != nil)
    }

    @Test func rawValuesAreStableForPersistence() {
        // Stored in UserDefaults — renaming a case breaks user settings.
        #expect(PracticeMode(rawValue: "freePlay") == .freePlay)
        #expect(PracticeMode(rawValue: "calledShots") == .calledShots)
        #expect(PracticeMode(rawValue: "guidedDrill") == .guidedDrill)
        #expect(PracticeMode.allCases.count == 3)
    }

    @Test func survivesCodableRoundTrip() throws {
        for mode in PracticeMode.allCases {
            let data = try JSONEncoder().encode(mode)
            #expect(try JSONDecoder().decode(PracticeMode.self, from: data) == mode)
        }
    }
}
