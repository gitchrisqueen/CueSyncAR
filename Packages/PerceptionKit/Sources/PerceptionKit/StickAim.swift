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
    /// Bounds on a projected stick quad, and how much continuity with the
    /// previous accepted aim is worth.
    ///
    /// Every number here was measured on two recordings of the same table
    /// on the same evening — one with the operator AIMING a real cue, one
    /// with a cue LYING on the cloth — committed as `device-aimed-cue` and
    /// `device-lying-cue`. That mattered, because the geometry is not what
    /// intuition says: the lying cue's axis passes CLOSER to the cue ball
    /// (median 4.6 cm vs 14.2 cm) and its near end is CLOSER (8.1 cm vs
    /// 32.7 cm) than the aimed cue's. Tightening lateral offset or tip
    /// distance to reject a discarded cue therefore rejects the aimed one
    /// first: a gate of 6 cm / 30 cm accepted 2.6 % of aiming frames.
    ///
    /// The aimed cue reads "further away" because its butt is raised ~20 cm
    /// and every corner is projected onto the cloth plane, so the elevated
    /// end lands long and drags the whole quad with it.
    ///
    /// The bounds are therefore left where they were. What this type adds
    /// is `continuityDegrees` — choosing between readings by AGREEMENT with
    /// the last accepted one rather than by geometry alone, which is what
    /// actually fixed the 171-degree aim reversals.
    public struct Gate: Sendable, Equatable {
        /// Reject when the stick's line misses the cue ball by more than
        /// this — probably a stick elsewhere on the table.
        public var maxLateralOffset: Double
        /// Reject when the near end is farther than this from the cue ball:
        /// nobody is addressing it.
        public var maxTipDistance: Double
        /// Reject stubby quads (chalk, hands, ball clusters).
        public var minLength: Double
        /// Reject quads too LONG to be a cue with both ends near the cloth.
        ///
        /// DISABLED by default, and the reason is worth keeping. A bound of
        /// 1.90 m is the only per-frame geometry that separates the two
        /// recordings at all — it takes the lying cue from 95.6 % of frames
        /// admitted to 27.3 %, leaving the aimed cue at 73.7 %. It was
        /// tried, measured, and rejected:
        ///
        /// 1. It does not achieve the goal. Admitting 27 % of frames still
        ///    captures the aim completely, because `AimResolver` HOLDS the
        ///    last stick aim for 2.5 s: at ~4.5 Hz, one accepted frame in
        ///    four refreshes that hold forever. Stick-sourced aim on the
        ///    lying clip fell only 100 % -> 97.7 %. No per-frame gate can
        ///    beat a hold; that is a job for aim-source policy.
        /// 2. It costs stability where it matters. Excluding a diagonal
        ///    changes which one wins, and on the aimed recording the
        ///    per-frame heading swing rose from 2.1 to 20.7 degrees.
        ///
        /// Kept as a knob because the reasoning stands (a cue is 1.45–1.50 m,
        /// so a much longer box has swallowed an arm, a body or a rail run)
        /// and a better-behaved version may want it. Set it to enable it.
        public var maxLength: Double
        /// Two candidate diagonals within this angle of the previous
        /// accepted aim count as "the same stick, still there", and the
        /// consistent one wins over the geometrically closest one.
        public var continuityDegrees: Double

        public init(maxLateralOffset: Double = 0.20,
                    maxTipDistance: Double = 0.80,
                    minLength: Double = 0.40,
                    maxLength: Double = .infinity,
                    continuityDegrees: Double = 25) {
            self.maxLateralOffset = maxLateralOffset
            self.maxTipDistance = maxTipDistance
            self.minLength = minLength
            self.maxLength = maxLength
            self.continuityDegrees = continuityDegrees
        }

        public static let `default` = Gate()
    }

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
                                gate: Gate = .default,
                                previous: AimRay? = nil) -> AimRay? {
        guard stickQuad.count == 4 else { return nil }
        // Image-box corners TL,TR,BR,BL → diagonals (TL,BR) and (TR,BL).
        let diagonals = [(stickQuad[0], stickQuad[2]), (stickQuad[1], stickQuad[3])]

        // Score both diagonals, then choose. Choosing by smallest lateral
        // offset alone is bistable: for a near-square box the two diagonals
        // are near mirrors, so a pixel of box jitter flips which one wins
        // and the aim swings by twice the box's diagonal angle. Continuity
        // with the previous accepted aim breaks the tie first.
        var candidates: [(a: Vec2, b: Vec2, lateral: Double, length: Double)] = []
        for (a, b) in diagonals {
            let axis = b - a
            guard axis.lengthSquared > 1e-12 else { continue }
            let t = (cueBall - a).dot(axis) / axis.lengthSquared
            let lateral = cueBall.distance(to: a + axis * t)
            candidates.append((a, b, lateral, axis.length))
        }
        let admissible = candidates.filter {
            $0.lateral <= gate.maxLateralOffset
                && $0.length >= gate.minLength
                && $0.length <= gate.maxLength
        }
        guard !admissible.isEmpty else { return nil }

        let cosContinuity = cos(gate.continuityDegrees * .pi / 180)
        func ray(_ candidate: (a: Vec2, b: Vec2, lateral: Double, length: Double))
        -> AimRay? {
            // Near end = tip (by the cue ball); far end = butt. Aim runs
            // from the butt through the ball. When the cue ball sits near
            // the middle of the diagonal these two distances are almost
            // equal, and one pixel of jitter reverses the aim 180 degrees —
            // measured at 171 degrees on a real recording — so a previous
            // aim, when there is one, decides instead.
            let ends = [(near: candidate.a, far: candidate.b),
                        (near: candidate.b, far: candidate.a)]
            var scored: [(ray: AimRay, tip: Double, agreement: Double)] = []
            for end in ends {
                let tip = end.near.distance(to: cueBall)
                guard tip <= gate.maxTipDistance else { continue }
                let direction = cueBall - end.far
                guard direction.length > 1e-9 else { continue }
                let unit = direction.normalized
                let agreement = previous.map { unit.dot($0.direction) } ?? 0
                scored.append((AimRay(origin: cueBall, direction: unit), tip, agreement))
            }
            guard !scored.isEmpty else { return nil }
            if previous != nil,
               let agreeing = scored.filter({ $0.agreement >= cosContinuity })
                .max(by: { $0.agreement < $1.agreement }) {
                return agreeing.ray
            }
            // No previous aim, or neither end agrees with it: fall back to
            // the geometric reading — the end actually nearer the ball.
            return scored.min(by: { $0.tip < $1.tip })?.ray
        }

        if let previous {
            let consistent = admissible.compactMap { candidate -> (AimRay, Double)? in
                guard let aim = ray(candidate) else { return nil }
                return (aim, aim.direction.dot(previous.direction))
            }
            if let best = consistent.filter({ $0.1 >= cosContinuity })
                .max(by: { $0.1 < $1.1 }) {
                return best.0
            }
        }
        return admissible.sorted { $0.lateral < $1.lateral }
            .lazy.compactMap(ray).first
    }

    /// Whether a projected stick quad plausibly belongs to a stick ON the
    /// table. Device finding (2026-07-23 bank-shot session): the detector
    /// classifies the table's RAIL EDGE as "cue" with high confidence, and
    /// its quad projects entirely beyond the cushions — picking sticks by
    /// raw confidence then locks aim onto the rail forever. A real aiming
    /// stick always has its tip end over the cloth (the butt legitimately
    /// overhangs the near rail), so: accept when at least one corner lies
    /// within the playing field plus `margin` meters.
    public static func quadOnTable(_ quad: [Vec2],
                                   halfExtents: Vec2,
                                   margin: Double = 0.05) -> Bool {
        quad.contains { corner in
            abs(corner.x) <= halfExtents.x + margin
                && abs(corner.y) <= halfExtents.y + margin
        }
    }
}
