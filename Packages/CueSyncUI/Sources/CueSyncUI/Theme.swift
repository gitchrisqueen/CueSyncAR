//
//  Theme.swift
//  CueSyncUI
//
//  Design-system tokens per docs/roadmap/05-UX-DESIGN.md. Raw values are
//  cross-platform so tests run on Linux; SwiftUI conveniences are gated.
//  HUD components and the 2D table renderer land in M1-05/M1-06.
//

import Foundation

/// sRGB color token, stored as 0xRRGGBB.
public struct ColorToken: Sendable, Equatable {
    public let rgb: UInt32
    public init(_ rgb: UInt32) { self.rgb = rgb }

    public var red: Double { Double((rgb >> 16) & 0xFF) / 255 }
    public var green: Double { Double((rgb >> 8) & 0xFF) / 255 }
    public var blue: Double { Double(rgb & 0xFF) / 255 }
}

public enum Theme {
    /// Confirmations, object-ball paths, pocket highlights.
    public static let feltGreen = ColorToken(0x2FA36B)
    /// The aiming line.
    public static let cueAmber = ColorToken(0xF5A623)
    /// Cue-ball path after contact.
    public static let chalkBlue = ColorToken(0x4A90D9)
    /// Errors and predicted scratches.
    public static let warnCoral = ColorToken(0xE8604C)

    // MARK: HUD text on the scrim
    //
    // The four tokens above are for the table (lines, discs, rings) and
    // for icons and borders. They are too dark to be TEXT on a HUD over a
    // live camera: felt green measured 1.6 to 3.1 : 1 on the real iPad.
    // Text uses the brighter siblings below, on a dark scrim, and
    // `HUDContrastTests` holds every pair to WCAG AA against the worst
    // backdrop a camera can supply.

    /// The dark plate under every HUD element.
    public static let hudScrim = ColorToken(0x000000)
    /// How opaque the plate is. High enough that a white wall behind a
    /// thin material still leaves a dark ground for light text.
    public static let hudScrimOpacity = 0.72
    /// Primary HUD text.
    public static let hudText = ColorToken(0xFFFFFF)
    /// Secondary HUD text: quieter than primary, still at least AA.
    public static let hudTextSecondary = ColorToken(0xD2D8DF)
    /// Text-grade siblings of the three shot-tier colours.
    public static let easyText = ColorToken(0x5FE3A1)
    public static let fairText = ColorToken(0xFFC247)
    /// Red-family text: a blocked shot, a scratch, a failure. NOT a hard
    /// shot: a playable shot that is difficult is not a fault.
    public static let hardText = ColorToken(0xFFA595)

    /// A hard shot has a colour of its own, orange, apart from FAIR's amber
    /// and from the red a blocked shot and an error use. The independent
    /// review read the shared red as "this shot is a fault". The shape (a
    /// triangle) and the word still carry the meaning.
    public static let hardTier = ColorToken(0xFF8A3D)
    public static let hardTierText = ColorToken(0xFFB070)

    // MARK: Sheet text
    //
    // Section footnotes and headers in the More and Settings sheets used
    // the system secondary grey: 3.29 : 1 on the grouped background. These
    // are the same quiet grey, at least 4.5 : 1 in both appearances.
    public static let sheetSecondaryLight = ColorToken(0x636366)
    public static let sheetSecondaryDark = ColorToken(0xAEAEB2)
    /// The grouped backgrounds they sit on, for the contrast test.
    public static let sheetGroundLight = ColorToken(0xF2F2F7)
    public static let sheetGroundDark = ColorToken(0x1C1C1E)

    /// Every (text colour, what it is) the HUD draws over the scrim. The
    /// contrast test walks this list, so a new text colour has to be added
    /// here to be used and is checked the moment it is.
    public static let hudTextColors: [(name: String, token: ColorToken)] = [
        ("primary", hudText), ("secondary", hudTextSecondary),
        ("easy", easyText), ("fair", fairText), ("hard", hardText),
        ("hard tier", hardTierText)
    ]
}

#if canImport(SwiftUI)
import SwiftUI

extension ColorToken {
    public var color: Color {
        Color(red: red, green: green, blue: blue)
    }
}
#endif
