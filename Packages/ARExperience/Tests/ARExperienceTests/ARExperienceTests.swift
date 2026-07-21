import Testing
@testable import ARExperience

@Suite("ARExperience placeholder")
struct ARExperienceSmokeTests {
    @Test func packageBuildsAndLinksCore() {
        #expect(ARExperienceStatus.implemented == false)
    }
}
