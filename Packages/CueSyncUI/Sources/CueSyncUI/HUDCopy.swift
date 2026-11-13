//
//  HUDCopy.swift
//  CueSyncUI
//
//  The wording of the HUD as pure functions, so Linux tests can hold it:
//  counts with the right plural, the shot call as a one-line headline, the
//  bar's state line, and the one word on the cue-ball guide tile.
//

import CueSyncCore
import Foundation

public enum HUDCopy {

    /// "1 ball", "6 balls". Every count a player can read goes through
    /// here, so "1 balls" cannot come back.
    public static func count(_ number: Int, _ noun: String) -> String {
        number == 1 ? "1 \(noun)" : "\(number) \(noun)s"
    }

    /// The shot call as the card's headline: upper case, the ball without
    /// its noun, the pocket without "pocket", at most `maxLength`
    /// characters ("Orange ball", "near-left corner" gives
    /// "ORANGE → NEAR-LEFT CORNER"). The longest line the ball and pocket
    /// names can make is 33 characters (a test enumerates them), so this
    /// never has to cut a name; it keeps both names whole.
    public static func headline(ball: String?, pocket: String?) -> String? {
        switch (ball.map(shortBall), pocket.map(shortPocket)) {
        case let (ball?, pocket?): "\(ball) → \(pocket)"
        case let (ball?, nil): ball
        case let (nil, pocket?): pocket
        case (nil, nil): nil
        }
    }

    /// A hyphen between letters becomes a non-breaking hyphen, so a narrow
    /// card wraps "NEAR-RIGHT CORNER" before "NEAR-RIGHT", never inside it.
    public static func keepingWordsWhole(_ text: String) -> String {
        var out = ""
        let chars = Array(text)
        for (index, char) in chars.enumerated() {
            let betweenLetters = index > 0 && index + 1 < chars.count
                && (chars[index - 1].isLetter || chars[index - 1].isNumber) && chars[index + 1].isLetter
            out.append(char == "-" && betweenLetters ? "\u{2011}" : char)
        }
        return out
    }

    /// "Move your aim left" / "Move your aim a little left": which way, and
    /// of what. ("Aim left" left the player asking left of the ball, the
    /// ghost ball or the cue.)
    public static func aimMove(side: AimLine.Side, degrees: Double) -> String {
        degrees < 5 ? "Move your aim a little \(side.rawValue)" : "Move your aim \(side.rawValue)"
    }

    /// The shot-strength slider's readout: a word, not metres a second.
    public static func shotStrengthWord(speed: Double, range: ClosedRange<Double>) -> String {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return "Medium" }
        let position = (speed - range.lowerBound) / span
        switch position {
        case ..<(1.0 / 3.0): return "Soft"
        case ..<(2.0 / 3.0): return "Medium"
        default: return "Firm"
        }
    }

    /// The scoreboard chip: "3 of 5 made", with the run once it is more
    /// than one: "3 of 3 made · 3 in a row".
    public static func scoreLine(chip: String, streak: Int) -> String {
        streak >= 2 ? "\(chip) made · \(streak) in a row" : "\(chip) made"
    }

    /// The most characters the headline may use.
    public static let headlineMaxLength = 40

    /// "Orange ball" is "ORANGE"; "Yellow stripe" stays whole; "8-ball",
    /// "Cue ball" stay whole (the noun IS the name there).
    static func shortBall(_ name: String) -> String {
        let upper = name.uppercased()
        guard upper.hasSuffix(" BALL"), upper != "CUE BALL" else { return upper }
        return String(upper.dropLast(" BALL".count))
    }

    /// "left side pocket" is "LEFT SIDE"; corners keep "CORNER".
    static func shortPocket(_ name: String) -> String {
        let upper = name.uppercased()
        guard upper.hasSuffix(" POCKET") else { return upper }
        return String(upper.dropLast(" POCKET".count))
    }

    /// The quiet line in the bottom bar: "8 ft · Free play · Any group".
    /// `table` is nil until a table is locked, and then that part is left
    /// out rather than guessed.
    public static func stateLine(table: String?, practice: String,
                                 group: String?) -> String {
        [table, practice, group ?? "Any group"]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// A table size as the bar says it: "8 ft".
    public static func tableSizeName(feet: Int) -> String { "\(feet) ft" }

    /// What a player says about how to strike the cue ball.
    public enum GuideWord: String, Sendable, Equatable, CaseIterable {
        case draw = "Draw"
        case stun = "Stun"
        case follow = "Follow"
        case left = "Left"
        case right = "Right"
    }

    /// The one word on the cue-ball guide tile, or nil when the advice is
    /// centre ball and the tile stays hidden. Side is chosen over
    /// follow/draw only when it is the larger offset.
    public static func guideWord(tipOffset tip: Vec2) -> GuideWord? {
        let centre = 0.05
        guard abs(tip.x) >= centre || abs(tip.y) >= centre else { return nil }
        if abs(tip.x) > abs(tip.y) { return tip.x < 0 ? .left : .right }
        if tip.y > 0 { return .follow }
        // Hitting just below centre is a stun; well below is a draw.
        return tip.y > -0.45 ? .stun : .draw
    }
}
