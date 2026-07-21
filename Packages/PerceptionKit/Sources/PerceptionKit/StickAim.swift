//
//  StickAim.swift
//  PerceptionKit
//
//  Aim from the ACTUAL cue stick: the detector's stick bounding box,
//  projected onto the table plane, becomes an aim ray through the cue
//  ball. A thin rotated stick fills its image box corner-to-corner, so
//  the stick's axis is one of the projected quad's diagonals — the one
//  whose line passes closest to the cue ball. Pure math, fully tested;
//  the device-pose AimEngine remains the fallback when no stick is seen.
//

import CueSyncCore
import Foundation

public enum StickAim {
    /// - Parameters:
    ///   - stickQuad: the stick detection's bounding-box corners projected
    ///     into table space, in image order TL, TR, BR, BL.
    ///   - cueBall: tracked cue-ball position (table space).
    ///   - maxLateralOffset: reject when the stick's line misses the cue
    ///     ball by more than this (m) — probably a stick elsewhere on the
    ///     table, not the one being aimed.
    ///   - maxTipDistance: reject when the stick's near end is farther than
    ///     this (m) from the cue ball — nobody is addressing the ball.
    ///   - minLength: reject stubby quads (false positives, chalk, hands).
    /// - Returns: an aim ray from the cue ball along the stick's pointing
    ///   direction, or nil when the stick can't be trusted.
    public static func estimate(stickQuad: [Vec2],
                                cueBall: Vec2,
                                maxLateralOffset: Double = 0.2,
                                maxTipDistance: Double = 0.8,
                                minLength: Double = 0.4) -> AimRay? {
        guard stickQuad.count == 4 else { return nil }
        // Image-box corners TL,TR,BR,BL → diagonals (TL,BR) and (TR,BL).
        let diagonals = [(stickQuad[0], stickQuad[2]), (stickQuad[1], stickQuad[3])]

        var best: (a: Vec2, b: Vec2, lateral: Double)?
        for (a, b) in diagonals {
            let axis = b - a
            guard axis.lengthSquared > 1e-12 else { continue }
            let t = (cueBall - a).dot(axis) / axis.lengthSquared
            let closest = a + axis * t
            let lateral = cueBall.distance(to: closest)
            if best == nil || lateral < best!.lateral {
                best = (a, b, lateral)
            }
        }
        guard let best, best.lateral <= maxLateralOffset else { return nil }
        guard best.a.distance(to: best.b) >= minLength else { return nil }

        // Near end = tip (by the cue ball); far end = butt. Aim runs from
        // the butt through the ball.
        let aNearer = cueBall.distance(to: best.a) <= cueBall.distance(to: best.b)
        let near = aNearer ? best.a : best.b
        let far = aNearer ? best.b : best.a
        guard near.distance(to: cueBall) <= maxTipDistance else { return nil }

        let direction = cueBall - far
        guard direction.length > 1e-9 else { return nil }
        return AimRay(origin: cueBall, direction: direction.normalized)
    }
}
