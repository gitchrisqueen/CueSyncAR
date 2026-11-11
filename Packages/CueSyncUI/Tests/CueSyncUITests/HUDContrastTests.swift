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

    @Test("Text sizes: nothing under 13 pt on a phone, nothing under 20 pt for secondary on a tablet")
    func textSizes() {
        for role in HUDTextRole.allCases {
            #expect(role.baseSize >= 13, "\(role)")
        }
        let secondary = HUDTextRole.caption
        #expect(secondary.baseSize * HUDTextRole.regularWidthScale >= 20)
        #expect(HUDTextRole.body.baseSize * HUDTextRole.regularWidthScale >= 22)
        #expect(HUDTextRole.headline.baseSize * HUDTextRole.regularWidthScale >= 28)
    }

    @Test("Hit targets and gaps")
    func targets() {
        #expect(HUDMetrics.minimumTarget >= 44)
        #expect(HUDMetrics.barSpacing >= 8)
    }
}
