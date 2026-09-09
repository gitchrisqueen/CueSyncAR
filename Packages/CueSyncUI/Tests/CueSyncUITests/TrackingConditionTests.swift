import Testing
@testable import CueSyncUI

/// The bug these tests exist to keep dead: for months the player was shown
/// "Tracking limited: insufficientFeatures" — an ARKit enum name — because
/// the only thing that knew tracking was in trouble published
/// `String(describing: reason)` and `HUDStatus.degraded` was unreachable.
@Suite("Tracking condition → what the player reads")
struct TrackingConditionTests {
    @Test("Too little detail means too little light, and says so")
    func insufficientFeaturesAsksForLight() {
        #expect(TrackingCondition.insufficientFeatures.degradedReason == .lowLight)
        #expect(HUDStatus.degraded(reason: .lowLight).label == "Need more light")
    }

    @Test("Excessive motion asks the player to hold still")
    func excessiveMotionAsksForStillness() {
        #expect(TrackingCondition.excessiveMotion.degradedReason == .fastMotion)
        #expect(HUDStatus.degraded(reason: .fastMotion).label == "Hold steady…")
    }

    @Test("Relocalizing and unavailable both mean the table is lost")
    func lostTableStates() {
        #expect(TrackingCondition.relocalizing.degradedReason == .trackingLost)
        #expect(TrackingCondition.unavailable.degradedReason == .trackingLost)
        #expect(HUDStatus.degraded(reason: .trackingLost).label == "Re-finding the table…")
    }

    /// Every cold start passes through `.initializing`. A warning there
    /// would be the first thing every player ever saw, and it resolves
    /// itself in a second or two.
    @Test("Normal and initializing say nothing at all")
    func quietStates() {
        #expect(TrackingCondition.normal.degradedReason == nil)
        #expect(TrackingCondition.initializing.degradedReason == nil)
    }

    @Test("No player-facing string ever leaks an identifier")
    func noEnumNamesReachThePlayer() {
        for condition in TrackingCondition.allCases {
            guard let reason = condition.degradedReason else { continue }
            let label = HUDStatus.degraded(reason: reason).label
            #expect(!label.contains(condition.rawValue))
            #expect(!label.contains("Tracking limited"))
            #expect(label.first?.isUppercase == true)
        }
    }

    @Test("A degraded condition is one that blocks raycasts")
    func degradedBlocksRaycasts() {
        #expect(!TrackingCondition.normal.blocksRaycasts)
        #expect(!TrackingCondition.initializing.blocksRaycasts)
        #expect(TrackingCondition.insufficientFeatures.blocksRaycasts)
        #expect(TrackingCondition.excessiveMotion.blocksRaycasts)
        #expect(TrackingCondition.relocalizing.blocksRaycasts)
        #expect(TrackingCondition.unavailable.blocksRaycasts)
    }
}

@Suite("Tracking condition → what a developer reads")
struct TrackingConditionDiagnosticTests {
    /// The diagnostic is for the log and the debug mirror, which is read
    /// at the table by someone deciding what to do next — so it is a
    /// sentence, not `String(describing:)` of an enum case.
    @Test("Every trouble state has a sentence, and normal has none")
    func diagnosticsAreSentences() {
        #expect(TrackingCondition.normal.diagnostic == nil)
        for condition in TrackingCondition.allCases where condition != .normal {
            let diagnostic = condition.diagnostic ?? ""
            #expect(diagnostic.contains(" "), "\(condition) has no diagnostic sentence")
            #expect(diagnostic.split(separator: " ").count >= 3)
        }
    }

    @Test("Initializing is reported to the log but never to the capsule")
    func initializingIsLogOnly() {
        #expect(TrackingCondition.initializing.diagnostic != nil)
        #expect(TrackingCondition.initializing.degradedReason == nil)
    }
}

@Suite("Tracking condition → why a tap found nothing")
struct TrackingConditionTapAdviceTests {
    /// Corner taps cannot land while tracking is degraded — ARKit returns
    /// nothing from a hit-test at all — so the advice has to name the
    /// actual obstacle rather than repeating "tap the corner".
    @Test("Advice names the obstacle when there is one")
    func adviceNamesTheObstacle() {
        #expect(TrackingCondition.excessiveMotion.missedTapAdvice.contains("still"))
        #expect(TrackingCondition.insufficientFeatures.missedTapAdvice.contains("dark"))
        #expect(TrackingCondition.relocalizing.missedTapAdvice.contains("Finding the table"))
    }

    @Test("With tracking healthy the advice is about aim, not about ARKit")
    func healthyAdviceIsAboutAim() {
        #expect(TrackingCondition.normal.missedTapAdvice
                == "Aim at the cloth inside the cushions, then tap the corner")
        #expect(TrackingCondition.initializing.missedTapAdvice
                == TrackingCondition.normal.missedTapAdvice)
    }

    @Test("Every condition has advice, and none of it is empty or shouty")
    func everyConditionHasAdvice() {
        for condition in TrackingCondition.allCases {
            let advice = condition.missedTapAdvice
            #expect(advice.count > 20)
            #expect(!advice.contains("!"))
            #expect(!advice.contains(condition.rawValue))
        }
    }
}
