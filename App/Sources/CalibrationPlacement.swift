//
//  CalibrationPlacement.swift
//  CueSync AR
//
//  What the calibration currently in progress is resting on.
//
//  Three things belong together and were sitting loose in the composition
//  root: the RAYS the corner taps were, the cloth height they were all
//  placed against, and where that height came from.
//
//  They are one concern — "how sure are we about this plane" — and lifting
//  them out is the move SessionModel.swift's own header prescribes when it
//  needs to shrink: a whole concern into its own `@Observable`, not a
//  shuffle of methods into another extension. It crossed the 1000-line
//  lint ceiling adding them, which A0 predicted would happen and named
//  this file as the pressure.
//

import CueSyncCore
import Foundation
import Observation
import TableSpace

@MainActor
@Observable
final class CalibrationPlacement {

    /// The rays the corner taps were, in world space.
    ///
    /// Rays and not points, because a corner at the wrong depth cannot be
    /// corrected by moving it vertically — only by re-intersecting its own
    /// ray at a better height. Depth error is what makes a quad slide
    /// across the table when the device changes angle.
    @ObservationIgnored private(set) var cornerRays: [TapRay] = []

    /// The cloth height every corner in the current flow was placed
    /// against, frozen at the first tap.
    ///
    /// Frozen because the ball estimate updates continuously, and taking it
    /// fresh per tap put the four corners on four slightly different
    /// planes. A quad that is not flat looks worse from every angle than
    /// one uniformly a little wrong — and it cannot be corrected as a
    /// whole afterwards, which is the thing that matters.
    private(set) var clothHeight: Double?

    /// Where that height came from, for the HUD and the mirror.
    private(set) var heightSource: CalibrationHeightSource = .unconstrained

    func begin(height: Double?, source: CalibrationHeightSource) {
        clothHeight = height
        heightSource = source
        cornerRays.removeAll()
    }

    func recordRay(_ ray: TapRay) { cornerRays.append(ray) }

    func adopt(height: Double, source: CalibrationHeightSource) {
        clothHeight = height
        heightSource = source
    }

    /// Re-derive every corner at a better height. Returns nil when any ray
    /// cannot meet the new plane — a partial answer would be a quad with
    /// three corrected corners and one stale one, which is worse than none.
    func corners(atHeight height: Double) -> [Vec3]? {
        let corners = cornerRays.compactMap { $0.intersect(planeHeight: height) }
        return corners.count == cornerRays.count ? corners : nil
    }

    func reset() {
        cornerRays.removeAll()
        clothHeight = nil
        heightSource = .unconstrained
    }
}
