//
//  ClothHeightCheck.swift
//  CueSync AR
//
//  Whether to believe a raycast hit, given what the balls say.
//
//  Split out of the coordinator because it is the DECISION, and the
//  coordinator is full of ARKit that no test can run. The decision is
//  arithmetic and deserves to be checked.
//
//  Context for the tolerance: a tap aimed at a cushion nose can legitimately
//  land a few centimetres above the bed — the nose is above the cloth, and
//  calibration is never exact. A tap that lands on the RAIL TOP, the floor,
//  or a side table across the room is a different surface entirely, and
//  those are what `.existingPlaneInfinite` was handing back.
//

import Foundation

/// Do we trust this raycast hit, or is the known cloth height better?
public enum ClothHeightCheck {

    /// A hit this far from the cloth is still plausibly the cloth (or its
    /// cushion nose). Beyond it, the ray found something else.
    ///
    /// 6 cm: a cushion nose sits roughly 3–4 cm above the bed on a standard
    /// table, and the rail top another 2–3 cm above that. The tolerance has
    /// to admit the first and reject the second, which puts it between them
    /// and closer to the nose.
    public static let tolerance = 0.06

    public static func trusts(hitHeight: Double, clothHeight: Double) -> Bool {
        abs(hitHeight - clothHeight) <= tolerance
    }
}
