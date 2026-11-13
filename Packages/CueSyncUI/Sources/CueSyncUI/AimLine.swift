//
//  AimLine.swift
//  CueSyncUI
//
//  The one line on the shot card about the player's aim, and when it may
//  say "On line".
//
//  It used to say "On line" whenever the aim matched the SUGGESTED shot,
//  including in called-shot play before any pocket was called and while the
//  called pocket was a different one. "On line" is the one signal a player
//  in called-shot play waits for, so it has to be true: it is shown only
//  when a pocket is called and the aim sends a ball into THAT pocket.
//

import Foundation

/// How far the aim is from the suggested shot's ideal aim, in the HUD's
/// terms (the session model restates ARExperience's `TargetGuide.Correction`
/// as this, so this package never sees ARKit).
public enum AimCorrection: Equatable, Sendable {
    case onLine
    case left(degrees: Double)
    case right(degrees: Double)
}

public struct AimLine: Equatable, Sendable {

    /// How the line is coloured. Not the shot tier's colour.
    public enum Tone: Equatable, Sendable {
        /// Green: on line.
        case good
        /// Amber: off line.
        case caution
        /// Plain white: a nudge that is neither good nor bad news.
        case neutral
    }

    public enum Side: String, Equatable, Sendable { case left, right }

    public let text: String
    public let tone: Tone

    /// What the card says about the aim, or nil to say nothing.
    ///
    /// - Parameters:
    ///   - calledShotMode: the practice mode is called shots.
    ///   - calledPocketSet: a pocket is called.
    ///   - calledPocketOnLine: the aim sends a ball into the called pocket
    ///     (the session model's `calledShotOnLine`, one definition).
    ///   - correction: how the aim differs from the suggested shot's.
    ///   - correctionIsForCalledPocket: the suggested shot goes to the
    ///     called pocket, so `correction` also tells which way to move to
    ///     reach it. When it does not, the direction is unknown and is not
    ///     guessed.
    public static func resolve(calledShotMode: Bool, calledPocketSet: Bool,
                               calledPocketOnLine: Bool, correction: AimCorrection?,
                               correctionIsForCalledPocket: Bool) -> AimLine? {
        if calledPocketSet {
            if calledPocketOnLine { return AimLine(text: "On line", tone: .good) }
            if correctionIsForCalledPocket, let side = side(of: correction) {
                return AimLine(text: "Off line — move your aim \(side.rawValue)", tone: .caution)
            }
            return AimLine(text: "Off line", tone: .caution)
        }
        // Called-shot play with no pocket called: nothing to be on line to.
        if calledShotMode { return nil }
        // Free play: the aim against the suggested shot, which is what the
        // line has always meant there.
        switch correction {
        case .onLine: return AimLine(text: "On line", tone: .good)
        case .left(let degrees):
            return AimLine(text: HUDCopy.aimMove(side: .left, degrees: degrees), tone: .neutral)
        case .right(let degrees):
            return AimLine(text: HUDCopy.aimMove(side: .right, degrees: degrees), tone: .neutral)
        case nil: return nil
        }
    }

    private static func side(of correction: AimCorrection?) -> Side? {
        switch correction {
        case .left: .left
        case .right: .right
        case .onLine, nil: nil
        }
    }
}
