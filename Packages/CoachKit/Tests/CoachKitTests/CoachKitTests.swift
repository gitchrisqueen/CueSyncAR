import Testing
@testable import CoachKit

@Suite("CoachKit placeholder")
struct CoachKitSmokeTests {
    @Test func packageBuildsAndLinksCore() {
        #expect(CoachKitStatus.implemented == false)
    }
}
