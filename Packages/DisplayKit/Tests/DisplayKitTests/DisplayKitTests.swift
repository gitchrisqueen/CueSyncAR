import Testing
@testable import DisplayKit

@Suite("DisplayKit placeholder")
struct DisplayKitSmokeTests {
    @Test func packageBuildsAndLinksCore() {
        #expect(DisplayKitStatus.implemented == false)
    }
}
