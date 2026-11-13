import Testing
@testable import CueSyncUI

@Suite("HUD contrast")
struct HUDContrastTests {

    /// The worst ground for LIGHT text: the scrim laid over pure white,
    /// which is the brightest thing a camera can show behind it.
    private var worstBackdrop: Contrast.RGB {
        Contrast.composite(Theme.hudScrim, alpha: Theme.hudScrimOpacity, over: .white)
    }

    @Test("The reference ratios are the WCAG ones")
    func knownRatios() {
        #expect(abs(Contrast.ratio(Contrast.RGB.white, .black) - 21) < 1e-9)
        #expect(abs(Contrast.ratio(Contrast.RGB.white, .white) - 1) < 1e-9)
        // #767676 on white is the textbook 4.54 : 1.
        let grey = Contrast.RGB(ColorToken(0x767676))
        #expect(abs(Contrast.ratio(grey, .white) - 4.54) < 0.01)
    }

    @Test("Every HUD text colour clears AA on the scrim over the brightest backdrop")
    func hudTextMeetsAA() {
        for entry in Theme.hudTextColors {
            let ratio = Contrast.ratio(entry.token, worstBackdrop)
            #expect(ratio >= Contrast.aa, "\(entry.name) text is \(ratio) : 1")
        }
    }

    @Test("The old felt-green and amber text did NOT clear it: why the siblings exist")
    func theTableColoursAreNotTextColours() {
        let felt = Contrast.ratio(Theme.feltGreen, worstBackdrop)
        #expect(felt < Contrast.aa, "if this passes, the text siblings are unnecessary")
    }

    @Test("The scrim is dark and mostly opaque, so the guarantee does not hang on the material")
    func scrimIsStrong() {
        #expect(Theme.hudScrimOpacity >= 0.6)
        #expect(Contrast.relativeLuminance(Contrast.RGB(Theme.hudScrim)) == 0)
    }

    @Test("The tier tints keep their hue: the text siblings are the same family")
    func siblingsAreTheSameFamily() {
        // Brighter, not different: green stays green-dominant, amber stays
        // red-green, coral stays red-dominant.
        #expect(Theme.easyText.green > Theme.easyText.red && Theme.easyText.green > Theme.easyText.blue)
        #expect(Theme.fairText.red > Theme.fairText.blue && Theme.fairText.green > Theme.fairText.blue)
        #expect(Theme.hardText.red > Theme.hardText.green && Theme.hardText.red > Theme.hardText.blue)
    }

    @Test("Text sizes: 17 pt floor on a phone; 36 / 28 / 22 pt on a tablet read from 2 m")
    func textSizes() {
        for role in HUDTextRole.allCases {
            #expect(role.compactSize >= 17, "\(role)")
            #expect(role.baseSize == role.compactSize, "\(role)")
            #expect(role.regularSize >= role.compactSize, "\(role)")
        }
        // On an iPad: headline at least 36, tier chip at least 32, every
        // other persistent string (capsule, bar, buttons, pills) at least 28,
        // a made shot 48 and a miss 34 (the independent re-score measured 22
        // pt text one pixel under the 32 px cap-height floor).
        #expect(HUDTextRole.headline.regularSize >= 36)
        #expect(HUDTextRole.tier.regularSize >= 32)
        #expect(HUDTextRole.body.regularSize >= 28)
        #expect(HUDTextRole.caption.regularSize >= 28)
        #expect(HUDTextRole.payoff.regularSize >= 48)
        #expect(HUDTextRole.payoffDetail.regularSize >= 34)
        // Cap height of the system font is about 0.705 em, at 2 px per pt.
        for role in [HUDTextRole.body, .caption] {
            #expect(role.regularSize * 0.705 * 2 >= 32, "\(role)")
        }
        #expect(HUDTextRole.headline.size(regularWidth: true) == HUDTextRole.headline.regularSize)
        #expect(HUDTextRole.headline.size(regularWidth: false) == HUDTextRole.headline.compactSize)
    }

    @Test("Hit targets and gaps")
    func targets() {
        #expect(HUDMetrics.minimumTarget >= 44)
        #expect(HUDMetrics.barSpacing >= 8)
    }
}
