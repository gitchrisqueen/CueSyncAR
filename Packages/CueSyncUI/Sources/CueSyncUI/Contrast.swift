//
//  Contrast.swift
//  CueSyncUI
//
//  WCAG 2.x contrast, as a value, so "the HUD is readable" is a test and
//  not an impression.
//
//  Two independent UX reviews measured the shot card and the bottom bar
//  from real iPad pixels at about 1.6 to 3.1 : 1 against the 4.5 : 1 that
//  AA asks for. The cause was structural: thin material over a live
//  camera, with felt-green text. The HUD now draws on a dark scrim, and
//  this file is what keeps it that way: a test composites the scrim over
//  the WORST backdrop a camera can supply (pure white, for light text) and
//  asserts every text colour the HUD uses still clears the bar.
//

import Foundation

public enum Contrast {

    /// WCAG AA for normal-size text.
    public static let aa = 4.5

    /// An sRGB colour with components 0...1, unrounded, so a composite does
    /// not lose precision to the 8-bit token it came from.
    public struct RGB: Sendable, Equatable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        public init(_ token: ColorToken) {
            self.init(red: token.red, green: token.green, blue: token.blue)
        }

        public static let white = RGB(red: 1, green: 1, blue: 1)
        public static let black = RGB(red: 0, green: 0, blue: 0)
    }

    /// WCAG relative luminance, 0 (black) ... 1 (white).
    public static func relativeLuminance(_ color: RGB) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    /// Contrast ratio, 1 ... 21, whichever colour is lighter.
    public static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    public static func ratio(_ a: ColorToken, _ b: RGB) -> Double {
        ratio(RGB(a), b)
    }

    /// `foreground` at `alpha` laid over `backdrop` (ordinary "over" blend).
    public static func composite(_ foreground: ColorToken, alpha: Double, over backdrop: RGB) -> RGB {
        let f = RGB(foreground)
        return RGB(red: f.red * alpha + backdrop.red * (1 - alpha),
                   green: f.green * alpha + backdrop.green * (1 - alpha),
                   blue: f.blue * alpha + backdrop.blue * (1 - alpha))
    }
}
