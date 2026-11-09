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

    /// The advised shot's lines/rings: neon magenta, a hue none of the
    /// live-prediction colors above use, so "where you should aim" can never
    /// be confused with "where you are aiming". Difficulty is NOT encoded
    /// here — it lives on the card via the tokens below.
    public static let adviceLine = ColorToken(0xFF4FD8)
    /// Difficulty tokens (card stripe/label), one per rating.
    public static let adviceEasy = ColorToken(0x35E08A)
    public static let adviceMedium = ColorToken(0xFFC845)
    public static let adviceHard = ColorToken(0xFF5C5C)
}

#if canImport(SwiftUI)
import SwiftUI

extension ColorToken {
    public var color: Color {
        Color(red: red, green: green, blue: blue)
    }
}
#endif
