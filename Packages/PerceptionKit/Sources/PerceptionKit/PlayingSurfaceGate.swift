//
//  PlayingSurfaceGate.swift
//  PerceptionKit
//
//  The one place that decides whether a table-space point can be a ball on
//  THIS table. Live report, 2026-09-07: "balls are being tracked off the
//  table — that should never happen". Two jobs, both measured against the
//  calibrated playing field (cushion nose to cushion nose):
//
//  1. Admit or reject a projected detection, with an allowance for
//     calibration and projection error, pulling an admitted one back onto
//     the feasible envelope so a rail ball is drawn on the rail.
//  2. Assert the reporting invariant on what the tracker hands back: every
//     ball in a TableState lies inside the playing surface, its centre at
//     least one radius from every cushion.
//

import CueSyncCore
import Foundation

/// Gate for table-space ball positions against the calibrated playing field.
///
/// Geometry. `halfExtents` is the playing field, nose to nose. A ball
/// touching a cushion has its centre one radius INSIDE the nose line, so
/// the feasible envelope for a ball centre is `halfExtents - ballRadius`
/// per axis; nothing real is ever reported past it. Around the envelope
/// sits an admit band `slack` metres wide that absorbs calibration and
/// projection error: an observation inside the band is a real ball whose
/// measurement is slightly off, and it is moved to the nearest feasible
/// centre. Outside the band it is not a ball on this table (a window
/// reflection, a ball on the rail top or a shelf, a rail edge the detector
/// took for a ball) and it is rejected before it can seed a track.
public struct PlayingSurfaceGate: Sendable, Equatable {
    /// Error allowance beyond the feasible envelope, metres.
    ///
    /// Budget for a rail ball's projected centre with the sphere-centre
    /// lift engaged (protocol-dispatched since 33e2cd7 — before that every
    /// ball projected 3–7 cm long, which is what the old `2 × radius`
    /// margin past the nose was really absorbing):
    ///   - corner placement at calibration, edge-averaged by
    ///     `TableCalibration.fromCorners`            ≈ 1.0 cm
    ///   - anchor drift / map refinement since lock  ≈ 1.5 cm
    ///   - detector box jitter → sphere-centre error ≈ 1.0 cm
    ///   - plane-height error through the lift,
    ///     δh / tan(elevation) at a low 25° stance   ≈ 2.0 cm
    /// Worst-case sum ≈ 5.5 cm, root-sum-square ≈ 3 cm. 4.5 cm sits between
    /// them: every plausible error still admits the ball, while the admit
    /// line ends only 1.6 cm past the nose (`slack - ballRadius`), short of
    /// where the rail top begins. It also matches the old empirical margin
    /// (8.6 cm beyond the envelope) once the 3–7 cm bias it was tuned
    /// against is subtracted (1.6–5.6 cm). The slack decides admit or
    /// reject only; it never moves where a ball is reported.
    ///
    /// Known limit: a ball hanging in a corner-pocket jaw can sit up to the
    /// pocket shelf (WPA ≤ 5.7 cm) past the nose intersection and is
    /// dropped by this band. Tracking hangers needs a pocket-aware gate.
    public static let defaultSlack = 0.045

    /// Playing-field half-extents, nose to nose, metres.
    public let halfExtents: Vec2
    public let ballRadius: Double
    /// Admit band beyond the feasible envelope, metres.
    public let slack: Double

    public init(halfExtents: Vec2,
                ballRadius: Double = Ball.standardRadius,
                slack: Double = PlayingSurfaceGate.defaultSlack) {
        self.halfExtents = halfExtents
        self.ballRadius = ballRadius
        self.slack = slack
    }

    public init(table: Table,
                ballRadius: Double = Ball.standardRadius,
                slack: Double = PlayingSurfaceGate.defaultSlack) {
        self.init(halfExtents: table.halfExtents, ballRadius: ballRadius, slack: slack)
    }

    /// Furthest a ball centre can physically sit from the field centre on
    /// each axis: touching the cushion.
    public var feasibleHalfExtents: Vec2 {
        Vec2(halfExtents.x - ballRadius, halfExtents.y - ballRadius)
    }

    /// Nil when the point cannot be a ball on this table; otherwise the
    /// nearest feasible ball centre (the point itself when already inside
    /// the envelope, so interior and rail-contact balls pass unchanged).
    public func admit(_ p: Vec2) -> Vec2? {
        let feasible = feasibleHalfExtents
        guard abs(p.x) <= feasible.x + slack,
              abs(p.y) <= feasible.y + slack else { return nil }
        return Vec2(min(max(p.x, -feasible.x), feasible.x),
                    min(max(p.y, -feasible.y), feasible.y))
    }

    /// The reporting invariant: the point lies inside the feasible
    /// envelope. Tolerates floating-point noise from the tracker's
    /// smoothing (a convex combination of admitted points can land an ulp
    /// outside), never a physical distance.
    public func contains(_ p: Vec2) -> Bool {
        let feasible = feasibleHalfExtents
        return abs(p.x) <= feasible.x + 1e-9 && abs(p.y) <= feasible.y + 1e-9
    }
}
