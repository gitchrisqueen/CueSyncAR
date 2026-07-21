import Testing
@testable import PerceptionKit

@Suite("PerceptionConfig")
struct PerceptionConfigTests {
    @Test func defaultsAreSane() {
        let config = PerceptionConfig.default
        #expect(config.detectionRate > 0)
        #expect(config.appearanceFrames >= 1)
        #expect(config.disappearanceFrames >= config.appearanceFrames)
        #expect((0...1).contains(config.confidenceFloor))
    }
}
