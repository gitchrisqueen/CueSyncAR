//
//  HUDReadabilityTests.swift
//  CueSync AR
//
//  The shot card's one-line headline, the bar's state line, the cue-ball
//  guide's one word, and the card's fixed size.
//

import CueSyncCore
import Testing
@testable import CueSyncUI

@Suite("HUD readability")
struct HUDReadabilityTests {

    // MARK: Headline

    @Test("The headline names the ball and the camera-relative pocket in upper case")
    func headlineShape() {
        #expect(HUDCopy.headline(ball: "Orange ball", pocket: "near-left corner")
                == "ORANGE → NEAR-LEFT CORNER")
        #expect(HUDCopy.headline(ball: "Maroon ball", pocket: "left side pocket")
                == "MAROON → LEFT SIDE")
        #expect(HUDCopy.headline(ball: "Yellow stripe", pocket: "far corner")
                == "YELLOW STRIPE → FAR CORNER")
        // The noun IS the name here.
        #expect(HUDCopy.headline(ball: "8-ball", pocket: "right corner") == "8-BALL → RIGHT CORNER")
        #expect(HUDCopy.headline(ball: "Cue ball", pocket: nil) == "CUE BALL")
    }

    @Test("No ball and pocket combination makes a headline over 40 characters")
    func headlineLengthBound() {
        let balls = ["Yellow", "Blue", "Red", "Purple", "Orange", "Green", "Maroon", "Black",
                     "White", "Brown", "Pink"].flatMap { ["\($0) ball", "\($0) stripe"] }
            + ["8-ball", "Cue ball", "Striped ball", "Ball"]
        var pockets: [String] = []
        for depth in ["near", "far"] {
            for lateral in ["left", "right"] {
                pockets += ["\(depth)-\(lateral) corner", "\(lateral) side pocket"]
            }
            pockets += ["\(depth) corner", "\(depth) side pocket"]
        }
        pockets += ["left corner", "right corner"]
        var longest = 0
        for ball in balls {
            for pocket in pockets {
                let line = HUDCopy.headline(ball: ball, pocket: pocket) ?? ""
                longest = max(longest, line.count)
                #expect(line.count <= HUDCopy.headlineMaxLength, "\(line)")
                #expect(line.contains("→"), "\(line)")
            }
        }
        #expect(longest <= 34)
    }

    @Test("The headline degrades like the call line: pocket never without ball unless unknown")
    func headlineDegrades() {
        #expect(HUDCopy.headline(ball: "Blue ball", pocket: nil) == "BLUE")
        #expect(HUDCopy.headline(ball: nil, pocket: nil) == nil)
    }

    #if canImport(SwiftUI)
    @Test("The card shows the headline and keeps the long call line for VoiceOver")
    func cardHeadline() {
        let card = ShotCard(ball: "Orange ball", pocket: "near-left corner",
                            confidence: .easy, chosenByPlayer: false)
        #expect(card.headline == "ORANGE → NEAR-LEFT CORNER")
        #expect(card.callLine == "Orange ball → near-left corner")
        #expect(card.provenance == "Best shot")
        #expect(ShotCard(ball: "Ball", pocket: nil, confidence: .hard,
                         chosenByPlayer: false).provenance == "Best available")
        #expect(ShotCard(ball: "Ball", pocket: nil, confidence: .easy,
                         chosenByPlayer: true).provenance == "Your pick")
    }
    #endif

    // MARK: Cue-ball guide

    @Test("A centre hit has no guide word, so the tile is hidden")
    func centreHidesTheTile() {
        #expect(HUDCopy.guideWord(tipOffset: .zero) == nil)
        #expect(HUDCopy.guideWord(tipOffset: Vec2(0.02, -0.03)) == nil)
    }

    @Test("Any other advice gets exactly one of the app's own words")
    func guideWords() {
        #expect(HUDCopy.guideWord(tipOffset: Vec2(0, -0.6)) == .draw)
        #expect(HUDCopy.guideWord(tipOffset: Vec2(0, -0.3)) == .stun)
        #expect(HUDCopy.guideWord(tipOffset: Vec2(0, 0.4)) == .follow)
        #expect(HUDCopy.guideWord(tipOffset: Vec2(-0.5, 0.1)) == .left)
        #expect(HUDCopy.guideWord(tipOffset: Vec2(0.5, -0.1)) == .right)
        #expect(HUDCopy.GuideWord.allCases.map(\.rawValue)
                == ["Draw", "Stun", "Follow", "Left", "Right"])
        // CoachKit's own recommendations: scratch warning is a draw, the
        // straight-in stun is a stun.
        #expect(HUDCopy.guideWord(tipOffset: Vec2(0, -0.6)) == .draw)
    }

    // MARK: State line

    @Test("The bar's state line is one grey sentence")
    func stateLine() {
        #expect(HUDCopy.stateLine(table: HUDCopy.tableSizeName(feet: 8),
                                  practice: "Free play", group: nil)
                == "8 ft · Free play · Any group")
        #expect(HUDCopy.stateLine(table: "9 ft", practice: "Called shots", group: "Solids")
                == "9 ft · Called shots · Solids")
        // No table yet: the part is left out, not guessed.
        #expect(HUDCopy.stateLine(table: nil, practice: "Free play", group: nil)
                == "Free play · Any group")
        // None of the three bare words the bar used to show.
        let line = HUDCopy.stateLine(table: "8 ft", practice: "Free play", group: nil)
        #expect(!line.contains("8-ft"))
        #expect(!line.contains(" Open"))
    }

    @Test("The state line is secondary text, at least AA on the plate")
    func stateLineContrast() {
        let backdrop = Contrast.composite(Theme.hudScrim, alpha: Theme.hudScrimOpacity, over: .white)
        #expect(Contrast.ratio(Theme.hudTextSecondary, backdrop) >= Contrast.aa)
    }

    // MARK: Card size

    @Test("The card is one fixed width per size class; a typical headline is one line beside the tile")
    func cardWidth() {
        #expect(HUDMetrics.cardWidthRegular > HUDMetrics.cardWidthCompact)
        // An iPad is 1024 pt wide at the narrowest landscape, 1080 on the
        // one in use: the card, with a 16 pt gutter each side, fits.
        #expect(HUDMetrics.cardWidthRegular + 32 <= 1032)
        // "ORANGE → NEAR-LEFT CORNER" (25 characters): about 0.68 em each
        // at 36 pt heavy, plus padding and the guide tile. The longest
        // possible call (33 characters) wraps to a second line instead of
        // clipping, which `ShotCard` allows with a line limit of two.
        let typical = 25.0 * 0.68 * HUDTextRole.headline.regularSize
        #expect(typical + 36 + 120 <= HUDMetrics.cardWidthRegular)
    }
}
