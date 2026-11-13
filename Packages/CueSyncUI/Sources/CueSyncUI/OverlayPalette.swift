//
//  OverlayPalette.swift
//  CueSyncUI
//
//  The colours of the marks drawn ON THE CLOTH, one per meaning, and the
//  cloths they have to be read against.
//
//  These are separate from `Theme`'s four table tokens because those are
//  shared with the HUD and the 2D table view, and a colour chosen to sit on a
//  dark HUD scrim is not the same job as a colour chosen to sit on felt. The
//  Theme tokens are unchanged.
//
//  Why not just green. An independent review of the real iPad measured the
//  object leg (target ball to pocket), the line the player has to follow, at
//  3.4 to 3.7 : 1 against a black cloth, the faintest mark on the table, and
//  its pocket ring was the same green. And a green line on green cloth
//  vanishes. The numbers are unforgiving: on a mid-tone tournament-green
//  cloth (relative luminance 0.16) a colour can reach at most 5.0 : 1 (pure
//  white) and the best pastel reaches about 4.0, so no coloured line can
//  clear 4.5 : 1 against bare green cloth. The marks therefore carry a dark
//  casing (`casing`), and what the eye compares the colour with is the cloth
//  seen THROUGH the casing (`backdrop(over:)`). The object leg is also white,
//  which clears 4.5 : 1 against all three nominal cloths with no help at all.
//
//  Pure: tested on Linux (ARExperience's tests hold the contrast and the hue
//  spacing).
//

import Foundation

public enum OverlayPalette {

    /// What a mark on the cloth means. One colour each, everywhere.
    public enum Role: String, Sendable, CaseIterable {
        /// The ball being shot at, from its centre to the pocket. The line
        /// the player follows, so the strongest mark.
        case objectPath
        /// The cue ball's approach to the ghost ball.
        case cuePath
        /// Where the cue points right now.
        case aim
        /// The cue ball after contact (a test switch).
        case postContact
        /// A predicted scratch (a test switch).
        case scratch
        /// The pocket the suggested shot is going into.
        case targetPocket
        /// The pocket the player called.
        case calledPocket
    }

    /// The object leg: white. Achromatic, so it shares a hue with nothing.
    public static let objectPath = ColorToken(0xFFFFFF)
    /// The cue leg: pale cyan.
    public static let cuePath = ColorToken(0x7FE3F0)
    /// The live aim: amber.
    public static let aim = ColorToken(0xFFC247)
    /// The cue ball after contact: pale lavender.
    public static let postContact = ColorToken(0xDCC6FF)
    /// A predicted scratch: pale salmon.
    public static let scratch = ColorToken(0xFFB8AE)
    /// The pocket ring of the suggested shot: pale pink.
    public static let targetPocket = ColorToken(0xFFB3EA)
    /// The called pocket: lime.
    public static let calledPocket = ColorToken(0xCFF56A)

    public static func token(for role: Role) -> ColorToken {
        switch role {
        case .objectPath: objectPath
        case .cuePath: cuePath
        case .aim: aim
        case .postContact: postContact
        case .scratch: scratch
        case .targetPocket: targetPocket
        case .calledPocket: calledPocket
        }
    }

    // MARK: Casing

    /// The dark edge laid under a mark so it separates from any cloth.
    public static let casing = ColorToken(0x000000)
    /// How opaque it is.
    public static let casingOpacity = 0.6

    /// The cloth as it looks beside a mark: the cloth under the casing.
    public static func backdrop(over cloth: Contrast.RGB) -> Contrast.RGB {
        Contrast.composite(casing, alpha: casingOpacity, over: cloth)
    }

    // MARK: The cloths a mark has to be read against

    /// A nominal cloth, as the camera renders it.
    public struct Cloth: Sendable, Equatable {
        public var name: String
        public var token: ColorToken
        public var rgb: Contrast.RGB { Contrast.RGB(token) }
    }

    /// Black, as the camera rendered it on the iPad this was reviewed on:
    /// sampled cloth was #352B2A and #383731; the lighter of the two.
    public static let black = Cloth(name: "black", token: ColorToken(0x383731))
    /// A mid-tone tournament green (Simonis 860 class) under ordinary room light.
    public static let tournamentGreen = Cloth(name: "tournament green", token: ColorToken(0x2A7F46))
    /// A tournament blue under ordinary room light.
    public static let tournamentBlue = Cloth(name: "tournament blue", token: ColorToken(0x1E5AA0))

    public static let nominalCloths = [black, tournamentGreen, tournamentBlue]

    /// The same three in a brighter room (about 1.35 times the light), for
    /// the cases the nominal ones do not cover.
    public static let litCloths = [
        Cloth(name: "black, lit", token: ColorToken(0x5A5852)),
        Cloth(name: "tournament green, lit", token: ColorToken(0x3FA862)),
        Cloth(name: "tournament blue, lit", token: ColorToken(0x3278C8))
    ]

    // MARK: Hue

    /// Hue in degrees (0 ..< 360) and saturation (0 ... 1) of a token.
    public static func hueAndSaturation(of token: ColorToken) -> (hue: Double, saturation: Double) {
        let r = token.red, g = token.green, b = token.blue
        let high = max(r, g, b), low = min(r, g, b)
        let delta = high - low
        guard high > 0 else { return (0, 0) }
        let saturation = delta / high
        guard delta > 0 else { return (0, saturation) }
        var hue: Double
        if high == r {
            hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if high == g {
            hue = (b - r) / delta + 2
        } else {
            hue = (r - g) / delta + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (hue, saturation)
    }

    /// The shorter way round the hue wheel between two hues, in degrees.
    public static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let gap = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(gap, 360 - gap)
    }
}
