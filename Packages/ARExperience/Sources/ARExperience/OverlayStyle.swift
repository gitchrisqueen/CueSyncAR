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
//              thickest, fully opaque; white for the cue ball's leg, green
//              for the object ball's. The one line to follow.
//    aim       where the cue is pointing right now: amber, thinner and
//              dimmer, because it is a reading, not an instruction.
//    secondary the cue ball after contact (the ricochet): thinnest,
//              faintest, dashed. Information for later, never the headline.
//
//  Pure, so it is tested on Linux. The renderer reads every number here.
//

import CueSyncUI
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

    // MARK: One colour per meaning
    //
    // Every colour here is a `Theme` token, so the table and the HUD speak
    // one language:
    //
    //   white  (hudText)    the cue ball's job: the cue-ball leg of the shot
    //                       and the ring on the cue ball
    //   green  (feltGreen)  the object ball's job: its leg to the pocket,
    //                       the ring on it, and the pocket ring it ends in
    //   amber  (cueAmber)   where the cue is pointing right now (the live aim)
    //   blue   (chalkBlue)  the cue ball after contact (secondary, off)
    //   coral  (warnCoral)  a predicted scratch (secondary, off)

    /// The cue-ball leg of the recommended shot: cue ball to ghost ball.
    public static let heroCueColor: UInt32 = Theme.hudText.rgb
    /// The object-ball leg of the recommended shot: target ball to pocket.
    public static let heroObjectColor: UInt32 = Theme.feltGreen.rgb
    /// Older name for the cue-ball leg's colour.
    public static let shotColor: UInt32 = heroCueColor
    /// The ring on the pocket the shot is going into.
    public static let pocketRingColor: UInt32 = heroObjectColor
    /// The ring on the cue ball, and on every ball when no shot is suggested.
    public static let cueRingColor: UInt32 = heroCueColor
    /// The ring on the ball being shot at.
    public static let targetRingColor: UInt32 = heroObjectColor
    /// Rings on balls when no shot is suggested: present so tap-to-designate
    /// has a visible target, quiet, and not amber, which means "your aim".
    public static let ballRingColor: UInt32 = 0xD8DEE6

    // MARK: Rings
    //
    // A ring, never a plate. The old marker was a filled disc wider than the
    // ball and brighter than the line, so fifteen of them out-shouted the
    // shot. A ring starts outside the ball's footprint and is a few
    // millimetres thick, so nothing is covered.

    /// Opacity of every ball ring. In the 25 to 40 percent band by rule:
    /// quiet enough that fifteen of them do not compete with the hero line.
    public static let ballRingOpacity = 0.3
    /// The two rings that belong to the suggested shot sit at the top of
    /// the band so they still read first.
    public static let involvedRingOpacity = 0.4
    /// The band every ball ring stays inside.
    public static let ringOpacityRange = 0.25...0.4
    /// Clear gap (m) between the ball's footprint and the ring's inner edge.
    public static let ringGap = 0.004
    /// Thickness (m) of a ball ring.
    public static let ringWidth = 0.003
    /// Inner and outer radius (m) of the ring drawn around a ball.
    public static func ballRing(ballRadius: Double) -> (inner: Double, outer: Double) {
        (ballRadius + ringGap, ballRadius + ringGap + ringWidth)
    }

    /// Thickness (m) of the pocket ring. Heavier than a ball ring: it is the
    /// one thing to hit.
    public static let pocketRingWidth = 0.008
    public static let pocketRingOpacity = 1.0
    /// Inner and outer radius (m) of the ring on a pocket. The marker's
    /// radius is the pocket's capture radius and is the ring's centre line,
    /// so the ring straddles the capture circle instead of lying inside it.
    public static func pocketRing(captureRadius: Double) -> (inner: Double, outer: Double) {
        (captureRadius - pocketRingWidth / 2, captureRadius + pocketRingWidth / 2)
    }

    /// The ghost ball of the recommended shot.
    public static let targetGhostOpacity = 0.5
    /// Opacity of the live aim's ghost ball, and of the pockets it ends in.
    public static let liveGhostOpacity = 0.35
    public static let liveFlatMarkerOpacity = 0.5

    /// How far a flat marker (ring, called pocket) floats above the cloth,
    /// and how thick a called-pocket disc is.
    public static let markerLift = 0.002
    public static let markerThickness = 0.004

    /// The opacity of the whole overlay layer given the HUD's confidence
    /// (`HUDStatus.overlayOpacity`): clamped, so a stray value can neither
    /// hide the overlay entirely nor push it past full strength.
    public static func layerOpacity(confidence: Double) -> Double {
        min(1, max(0.25, confidence))
    }
}
