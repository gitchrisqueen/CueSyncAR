//
//  OverlayStyle.swift
//  ARExperience
//
//  How heavy each line on the table is drawn, as numbers, so the rule
//  "the suggested shot is the brightest thing on the cloth" is a test and
//  not a matter of taste.
//
//  Two independent reviews of the real iPad found the opposite: the
//  recommended plan was a 4 mm line at 40 % opacity, fainter than a stray
//  aim line, and orange meant three different things at once. The
//  hierarchy is now three tiers with one colour each:
//
//    hero      the suggested shot (cue ball -> ghost ball -> pocket):
//              thickest, fully opaque, white. The one line to follow.
//    aim       where the cue is pointing right now: amber, thinner and
//              dimmer, because it is a reading, not an instruction.
//    secondary the cue ball after contact (the ricochet): thinnest,
//              faintest, dashed. Information for later, never the headline.
//
//  Pure, so it is tested on Linux. The renderer reads every number here.
//

import Foundation

public enum OverlayStyle {

    /// What a strip is, for styling.
    public enum Tier: Sendable, Equatable, CaseIterable {
        case hero
        case aim
        case secondary
    }

    /// The tier of a strip. Only a solid line of the recommended plan is
    /// the hero; anything dashed (the cue ball after contact) is secondary
    /// whichever line it belongs to.
    public static func tier(role: OverlayLayout.Strip.Role, dashed: Bool) -> Tier {
        if dashed { return .secondary }
        return role == .plan ? .hero : .aim
    }

    /// Strip width in metres. The ball is 57 mm across; the hero line is a
    /// third of that, so it reads from 2 m on dark cloth.
    public static func width(_ tier: Tier) -> Double {
        switch tier {
        case .hero: 0.018
        case .aim: 0.006
        case .secondary: 0.004
        }
    }

    /// Opacity 0...1 of the strip material.
    public static func opacity(_ tier: Tier) -> Double {
        switch tier {
        case .hero: 1.0
        case .aim: 0.55
        case .secondary: 0.35
        }
    }

    /// How far a strip floats above the cloth, so a heavier line is drawn
    /// over a lighter one it crosses instead of z-fighting with it.
    public static func lift(_ tier: Tier) -> Double {
        switch tier {
        case .hero: 0.0035
        case .aim: 0.002
        case .secondary: 0.0012
        }
    }

    /// The colour of "the shot": the recommended line from the cue ball to
    /// the ghost ball and on to the pocket. One colour for the whole path.
    public static let shotColor: UInt32 = 0xFFFFFF
    /// Rings under the balls that are not being shot at: present, quiet,
    /// and not amber, which means "your aim".
    public static let ballRingColor: UInt32 = 0xD8DEE6
    public static let ballRingOpacity = 0.28
    /// The ghost ball of the recommended shot.
    public static let targetGhostOpacity = 0.5

    /// The opacity of the whole overlay layer given the HUD's confidence
    /// (`HUDStatus.overlayOpacity`): clamped, so a stray value can neither
    /// hide the overlay entirely nor push it past full strength.
    public static func layerOpacity(confidence: Double) -> Double {
        min(1, max(0.25, confidence))
    }
}
