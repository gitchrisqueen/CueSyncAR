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
//  aim line, and orange meant three different things at once. A third found
//  that once the clutter was gone the line the player has to FOLLOW, the
//  object ball's path to the pocket, was the faintest mark left: 11 px wide
//  at 3.4 : 1 against the cloth, while the cue ball's leg was 14 px at
//  9.9 : 1, and the pocket ring shared the line's green. The hierarchy is
//  now four tiers:
//
//    hero      the object ball's leg, target ball to pocket: the widest and
//              the brightest (white), fully opaque. The one line to follow.
//    lead      the cue ball's leg to the ghost ball: still clearly visible but
//              narrower than the hero, in its own hue.
//    aim       where the cue is pointing right now: thinner and dimmer,
//              because it is a reading, not an instruction.
//    secondary the cue ball after contact (the ricochet): thinnest,
//              faintest, dashed. Information for later, never the headline.
//
//  Every colour is an `OverlayPalette` token (CueSyncUI), one per meaning.
//  Each mark of the suggested shot is laid on a dark casing so it reads on any
//  cloth, not just a black one; see `OverlayPalette` for the arithmetic.
//
//  Pure, so it is tested on Linux. The renderer reads every number here.
//

import CueSyncUI
import Foundation

public enum OverlayStyle {

    /// What a strip is, for styling.
    public enum Tier: Sendable, Equatable, CaseIterable {
        case hero
        case lead
        case aim
        case secondary
    }

    /// The tier of a strip by role alone. A solid line of the recommended plan
    /// is the hero (the object leg: `tier(of:)` tells the cue leg apart);
    /// anything dashed (the cue ball after contact) is secondary whichever
    /// line it belongs to.
    public static func tier(role: OverlayLayout.Strip.Role, dashed: Bool) -> Tier {
        if dashed { return .secondary }
        return role == .plan ? .hero : .aim
    }

    /// The tier of a strip, telling the plan's two legs apart.
    public static func tier(of strip: OverlayLayout.Strip) -> Tier {
        let tier = tier(role: strip.role, dashed: strip.dashed)
        return tier == .hero && strip.leg == .cue ? .lead : tier
    }

    /// Strip width in metres. The ball is 57 mm across. The object leg is
    /// 26 mm: the reviewed iPad drew a 18 mm line at 11 px on the far half
    /// of the table (about 610 px per metre there), and this is at least as
    /// wide as the cue leg was on the near half (14 px at 770 px per metre
    /// is 18 mm): 26 mm is 16 px far and 20 px near. The cue leg is 16 mm,
    /// 12 px near and 10 px far: narrower than the line it leads to, and
    /// still plainly a line.
    public static func width(_ tier: Tier) -> Double {
        switch tier {
        case .hero: 0.026
        case .lead: 0.016
        case .aim: 0.006
        case .secondary: 0.004
        }
    }

    /// Opacity 0...1 of the strip material. Both legs are fully opaque: an
    /// opaque line keeps the contrast the palette was chosen for, where a
    /// translucent one is blended toward whatever cloth is under it.
    public static func opacity(_ tier: Tier) -> Double {
        switch tier {
        case .hero: 1.0
        case .lead: 1.0
        case .aim: 0.55
        case .secondary: 0.35
        }
    }

    /// How far a strip floats above the cloth, so a heavier line is drawn
    /// over a lighter one it crosses instead of z-fighting with it.
    public static func lift(_ tier: Tier) -> Double {
        switch tier {
        case .hero: 0.0035
        case .lead: 0.0030
        case .aim: 0.002
        case .secondary: 0.0012
        }
    }

    // MARK: Casing

    /// How much wider than its line a casing is, in total: 4 mm of dark edge
    /// each side. Wide enough to be seen as an edge at 2 m, narrow enough to
    /// stay an edge.
    public static let casingExtraWidth = 0.008
    /// How far under its line the casing floats.
    public static let casingDrop = 0.0006
    /// The casing's opacity (`OverlayPalette.casingOpacity`).
    public static let casingOpacity = OverlayPalette.casingOpacity
    public static let casingColor: UInt32 = OverlayPalette.casing.rgb

    // MARK: One colour per meaning
    //
    // Every colour here is an `OverlayPalette` token; see that file for why
    // each was chosen and what it was checked against.
    //
    //   white  (objectPath)    the object ball's job: its leg to the pocket
    //                          and the ring on the ball being shot at
    //   cyan   (cuePath)       the cue ball's job: its leg to the ghost ball,
    //                          the ghost ball, and the ring on the cue ball
    //   amber  (aim)           where the cue is pointing right now
    //   lavender (postContact) the cue ball after contact (secondary, off)
    //   salmon (scratch)       a predicted scratch (secondary, off)
    //   pink   (targetPocket)  the pocket ring of the suggested shot
    //   lime   (calledPocket)  the pocket the player called

    /// The cue-ball leg of the recommended shot: cue ball to ghost ball.
    public static let heroCueColor: UInt32 = OverlayPalette.cuePath.rgb
    /// The object-ball leg of the recommended shot: target ball to pocket.
    public static let heroObjectColor: UInt32 = OverlayPalette.objectPath.rgb
    /// Older name for the cue-ball leg's colour (also the ghost ball's).
    public static let shotColor: UInt32 = heroCueColor
    /// The ring on the pocket the shot is going into.
    public static let pocketRingColor: UInt32 = OverlayPalette.targetPocket.rgb
    /// The ring on the cue ball, and on every ball when no shot is suggested.
    public static let cueRingColor: UInt32 = heroCueColor
    /// The ring on the ball being shot at.
    public static let targetRingColor: UInt32 = heroObjectColor
    /// Rings on balls when no shot is suggested: present so tap-to-designate
    /// has a visible target, quiet, and not amber, which means "your aim".
    public static let ballRingColor: UInt32 = 0xD8DEE6
    /// Where the cue is pointing right now.
    public static let aimColor: UInt32 = OverlayPalette.aim.rgb
    /// The live object ball's path, with no suggestion: the object role's
    /// colour, so the object path is white wherever it is drawn.
    public static let objectPathColor: UInt32 = OverlayPalette.objectPath.rgb
    /// The cue ball after contact, and a predicted scratch.
    public static let postContactColor: UInt32 = OverlayPalette.postContact.rgb
    public static let scratchColor: UInt32 = OverlayPalette.scratch.rgb
    /// The called pocket, and the called pocket when the shot goes into it.
    public static let calledPocketColor: UInt32 = OverlayPalette.calledPocket.rgb
    public static let calledPocketOpacity = 0.6
    public static let calledPocketOnLineOpacity = 0.9

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

    /// Thickness (m) of the quiet ring on a pocket the live aim ends in.
    public static let pocketRingWidth = 0.008
    public static let pocketRingOpacity = 1.0
    /// Inner and outer radius (m) of the quiet ring on a pocket: it straddles
    /// the capture circle.
    public static func pocketRing(captureRadius: Double) -> (inner: Double, outer: Double) {
        (captureRadius - pocketRingWidth / 2, captureRadius + pocketRingWidth / 2)
    }

    // MARK: The pocket to hit
    //
    // The ring on the suggested shot's pocket is the one thing to aim at, so
    // it is big enough to find from 2 m and thick enough to be a stroke, not
    // a hairline.
    //
    // Radius: 1.5 times the pocket's capture radius, centred on the pocket.
    // The capture radius approximates the mouth (`Table.cornerCaptureRadius`
    // 75 mm, side 58 mm), so the ring's diameter is 225 mm at a corner and
    // 174 mm at a side pocket: 1.5 times the mouth's own width, which is the
    // size the review asked for. The reason for the margin is the same
    // review's other finding: the line's end sat about one ball diameter
    // (57 mm) from the true mouth, whether from drawing or from calibration.
    // A ring of radius 113 mm still encloses the real mouth centre with that
    // much error, where one of 75 mm lay half across it.
    /// How many capture radii the pocket-to-hit ring's centre line lies out.
    public static let targetPocketRingScale = 1.5
    /// Stroke (m): 14 mm, 8 to 11 px at 2 m on the iPad, against 5 px before.
    public static let targetPocketRingWidth = 0.014
    /// The casing's extra width on each side of the ring's stroke.
    public static let targetPocketCasingMargin = 0.003

    /// Inner and outer radius (m) of the ring on the pocket the shot goes into.
    public static func targetPocketRing(captureRadius: Double) -> (inner: Double, outer: Double) {
        let centre = captureRadius * targetPocketRingScale
        return (centre - targetPocketRingWidth / 2, centre + targetPocketRingWidth / 2)
    }

    /// Its casing: the same ring, wider by the margin on both edges.
    public static func targetPocketCasing(captureRadius: Double) -> (inner: Double, outer: Double) {
        let ring = targetPocketRing(captureRadius: captureRadius)
        return (ring.inner - targetPocketCasingMargin, ring.outer + targetPocketCasingMargin)
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
