import Testing
import CueSyncCore
@testable import CoachKit

@Suite("CoachKit")
struct CoachKitSmokeTests {
    /// Replaces a test that asserted `CoachKitStatus.implemented == false`
    /// — a milestone marker that shipped in the release binary and whose
    /// only reader was the assertion that it was still false. This checks
    /// the same thing that test actually checked: the package builds and
    /// links CueSyncCore.
    @Test func packageBuildsAndLinksCore() {
        #expect(SkillLevel.intermediate.rawValue == "intermediate")
    }
}
