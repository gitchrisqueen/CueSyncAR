import Testing
@testable import CueSyncUI

@Suite("Theme tokens")
struct ThemeTests {
    @Test func componentsDecodeCorrectly() {
        let token = ColorToken(0x2FA36B)
        #expect(abs(token.red - Double(0x2F) / 255) < 1e-12)
        #expect(abs(token.green - Double(0xA3) / 255) < 1e-12)
        #expect(abs(token.blue - Double(0x6B) / 255) < 1e-12)
    }

    @Test func paletteTokensAreDistinct() {
        let palette = [Theme.feltGreen, Theme.cueAmber, Theme.chalkBlue, Theme.warnCoral]
        #expect(Set(palette.map(\.rgb)).count == palette.count)
    }
}
