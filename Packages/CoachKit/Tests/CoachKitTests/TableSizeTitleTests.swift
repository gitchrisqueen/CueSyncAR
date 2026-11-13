import CueSyncCore
import Testing
@testable import CoachKit

@Suite("Table size titles")
struct TableSizeTitleTests {
    @Test("The picker says '9 ft', the same as the HUD bar, never '9-ft'")
    func titlesMatchTheBar() {
        #expect(TableSizeSetting.standard(.sevenFoot).title == "7 ft")
        #expect(TableSizeSetting.standard(.eightFoot).title == "8 ft")
        #expect(TableSizeSetting.standard(.nineFoot).title == "9 ft")
        for size in TableSizeSetting.selectable {
            #expect(!size.title.contains("-ft"), "\(size.title)")
        }
    }
}

@Suite("Score copy")
struct ScoreCopyPluralTests {
    @Test("One shot is '1 shot', never '1 shots'")
    func singularShot() {
        var score = SessionScore()
        #expect(score.spokenText == "No shots yet this session")
        score.record(.missed)
        #expect(score.spokenText == "0 made out of 1 shot this session")
        score.record(.madeAsAdvised(ball: BallID(1), pocket: .cornerTopRight))
        #expect(score.spokenText == "1 made out of 2 shots this session")
    }
}
