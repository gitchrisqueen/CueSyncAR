import Foundation
import Testing
@testable import CoachKit

@Suite("Words a player reads")
struct SetupCopyTests {
    @Test("One name for 'any group': the bar and Settings say the same")
    func anyGroup() {
        #expect(BallGroup.any.label == "Any group")
        let labels = BallGroup.allCases.map(\.label)
        #expect(Set(labels).count == labels.count)
        #expect(!labels.contains("Open"))
    }

    @Test("No setup prompt says 'cushion nose'")
    func noJargonInSetupPrompts() {
        let stages: [GuidanceStage] = [.confirmingRails, .placingCorners(placed: 0),
                                       .placingCorners(placed: 2), .findingTable, .needsCalibration]
        for (index, stage) in stages.enumerated() {
            var guidance = SpokenGuidance(verbosity: .keyMoments)
            let text = guidance.next(for: .init(stage: stage), at: TimeInterval(index * 10))?.text ?? ""
            #expect(!text.isEmpty, "\(stage)")
            #expect(!text.lowercased().contains("nose"), "\(stage): \(text)")
        }
    }
}
