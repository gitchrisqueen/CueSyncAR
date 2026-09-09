//
//  OverlayLayout.swift
//  ARExperience
//
//  Task M3-04 (logic): converts a ShotPrediction into placement data for
//  RealityKit entities — one strip per trajectory segment (midpoint, length,
//  rotation about the plane normal), the ghost ball, and pocket highlights.
//  Pure and unit-tested; OverlayRenderer (ARKit/RealityKit-gated) turns
//  these into entities 1:1.
//

import CueSyncCore
import Foundation
import TableSpace

public struct OverlayLayout: Sendable, Equatable {
    public struct Strip: Sendable, Equatable {
        public var ballID: BallID
        /// Segment ends in WORLD space, lying on the cloth.
        ///
        /// Endpoints, not a heading. This used to carry `angle`, a
        /// TABLE-space heading (`atan2` over table x/y) that the renderer
        /// then applied as a rotation about the anchor's local Y — and the
        /// table anchor is created with identity rotation, so nothing ever
        /// mapped table axes onto world axes. Every strip's midpoint was
        /// right and its direction was wrong by the table's yaw: on a
        /// calibration whose long axis ran along world +z, that is a right
        /// angle. It rendered correctly only when the table happened to be
        /// aligned with the session's world axes, which is exactly the
        /// fixture the unit tests used.
        ///
        /// World endpoints cannot express a heading in the wrong frame.
        public var start: Vec3
        public var end: Vec3
        /// Strip center in world space, lying on the cloth.
        public var midpoint: Vec3
        public var length: Double
        public var dashed: Bool
        public var color: UInt32 // 0xRRGGBB token value
        /// Whether this strip is the live aim or the recommended shot.
        ///
        /// Kept out of `color` on purpose: both lines use the same
        /// semantic colours (amber for the cue's approach, green for the
        /// object ball's path), so a player learns one colour language.
        /// What separates them is weight — the plan is drawn thinner and
        /// more transparent, the way a guide line differs from a result.
        public var role: Role = .live

        public enum Role: String, Sendable, Equatable {
            /// Where the player's current aim actually goes.
            case live
            /// Where the cue ball would go to make the chosen shot.
            case plan
        }

        /// Unit direction in world space, or nil for a degenerate strip.
        public var direction: Vec3? {
            let v = end - start
            return v.length > 1e-12 ? v.normalized : nil
        }
    }

    public struct Marker: Sendable, Equatable {
        public var position: Vec3
        public var radius: Double
    }

    /// A tracked ball's footprint on the cloth — always rendered during
    /// live tracking (independent of any shot prediction) so the user can
    /// SEE where the app believes each ball is. Doubles as the visual
    /// target for tap-to-designate: a marker off the real ball instantly
    /// reveals a projection/calibration problem.
    public struct BallMarker: Sendable, Equatable {
        public var position: Vec3
        public var radius: Double
        public var isCue: Bool
    }

    public var strips: [Strip]
    public var ghostBall: Marker?
    public var highlightedPockets: [Marker]
    /// Tracked-ball rings (cue rendered distinctly).
    public var balls: [BallMarker] = []
    /// The user's called pocket (M6-02), rendered as a distinct ring.
    public var calledPocket: Marker?
    /// True when the current prediction sends an OBJECT ball (not the cue
    /// ball) into the called pocket — the "on line" state.
    public var calledPocketSatisfied: Bool = false
    /// The recommended shot: how to make the ball the player picked (or
    /// the one the app suggests). Empty when there is no target.
    public var targetStrips: [Strip] = []
    /// Where the cue ball's centre has to arrive to make that shot.
    public var targetGhostBall: Marker?
    /// A ring on the ball being shot at, so the player can see which one
    /// the percentage refers to without reading the card.
    public var targetBall: Marker?
    /// The pocket the recommended shot is going into.
    public var targetPocket: Marker?
    /// The cloth's up-normal in world space, so the renderer can rotate a
    /// strip about the right axis rather than assuming world up.
    public var planeNormal: Vec3 = Vec3(0, 1, 0)

    /// The shot the app is recommending, ready to lay out: the solved
    /// ideal shot plus which ball and pocket it is for.
    public struct Target: Sendable, Equatable {
        public var prediction: ShotPrediction
        public var ball: BallID
        public var pocket: PocketID
        /// Where the cue ball's centre must arrive, in table space.
        public var ghostBall: Vec2

        public init(prediction: ShotPrediction, ball: BallID,
                    pocket: PocketID, ghostBall: Vec2) {
            self.prediction = prediction
            self.ball = ball
            self.pocket = pocket
            self.ghostBall = ghostBall
        }
    }

    /// Colors mirror TableScene's path styling rules (05-UX-DESIGN).
    public static func compose(state: TableState,
                               prediction: ShotPrediction,
                               calibration: TableCalibration,
                               calledPocket calledPocketID: PocketID? = nil,
                               target: Target? = nil,
                               aimColor: UInt32 = 0xF5A623,
                               objectColor: UInt32 = 0x2FA36B,
                               cueAfterColor: UInt32 = 0x4A90D9,
                               scratchColor: UInt32 = 0xE8604C) -> OverlayLayout {
        let cueID = state.cueBall?.id

        func buildStrips(_ prediction: ShotPrediction, role: Strip.Role) -> [Strip] {
        var seenContact = false
        let contact = prediction.firstContact?.contact
        let cueScratched = cueID.map { prediction.pocketedBalls.contains($0) } ?? false
        return prediction.segments.compactMap { segment -> Strip? in
            let vector = segment.end - segment.start
            guard vector.length > 1e-6 else { return nil }
            let isCue = segment.ballID == cueID
            let afterContact: Bool
            if isCue, let contact {
                if seenContact {
                    afterContact = true
                } else if segment.end == contact {
                    seenContact = true
                    afterContact = false
                } else {
                    afterContact = false
                }
            } else {
                afterContact = false
            }

            let color: UInt32
            let dashed: Bool
            if isCue {
                if afterContact {
                    color = cueScratched ? scratchColor : cueAfterColor
                    dashed = true
                } else {
                    color = aimColor
                    dashed = false
                }
            } else {
                color = objectColor
                dashed = false
            }

            let mid = (segment.start + segment.end) * 0.5
            let worldStart = calibration.tableToWorld(segment.start)
            let worldEnd = calibration.tableToWorld(segment.end)
            return Strip(ballID: segment.ballID,
                         start: worldStart,
                         end: worldEnd,
                         midpoint: calibration.tableToWorld(mid),
                         length: vector.length,
                         dashed: dashed,
                         color: color,
                         role: role)
        }
        }

        let strips = buildStrips(prediction, role: .live)

        var ghost: Marker?
        if let contact = prediction.firstContact?.contact {
            let radius = state.cueBall?.radius ?? Ball.standardRadius
            ghost = Marker(position: calibration.tableToWorld(contact), radius: radius)
        }

        var litPockets: Set<PocketID> = []
        for event in prediction.events {
            if case let .pocket(_, pocket) = event { litPockets.insert(pocket) }
        }
        let highlights = state.table.pockets
            .filter { litPockets.contains($0.id) }
            .map { Marker(position: calibration.tableToWorld($0.position),
                          radius: $0.captureRadius) }

        // Called-shot state (M6-02): ring the called pocket; "on line"
        // when an object ball is predicted into it (the cue ball going in
        // is a scratch, not a make).
        var calledMarker: Marker?
        var satisfied = false
        if let calledPocketID,
           let pocket = state.table.pockets.first(where: { $0.id == calledPocketID }) {
            calledMarker = Marker(position: calibration.tableToWorld(pocket.position),
                                  radius: pocket.captureRadius * 1.3)
            satisfied = prediction.events.contains { event in
                if case let .pocket(ball, pocketID) = event {
                    return pocketID == calledPocketID && ball != cueID
                }
                return false
            }
        }

        var targetStrips: [Strip] = []
        var targetGhost: Marker?
        var targetBallMarker: Marker?
        var targetPocketMarker: Marker?
        if let target {
            let radius = state.cueBall?.radius ?? Ball.standardRadius
            targetStrips = buildStrips(target.prediction, role: .plan)
            targetGhost = Marker(position: calibration.tableToWorld(target.ghostBall),
                                 radius: radius)
            if let ball = state.ball(target.ball) {
                targetBallMarker = Marker(position: calibration.tableToWorld(ball.position),
                                          radius: ball.radius * 1.45)
            }
            if let pocket = state.table.pockets.first(where: { $0.id == target.pocket }) {
                targetPocketMarker = Marker(position: calibration.tableToWorld(pocket.position),
                                            radius: pocket.captureRadius)
            }
        }

        return OverlayLayout(strips: strips, ghostBall: ghost,
                             highlightedPockets: highlights,
                             balls: ballMarkers(state: state, calibration: calibration),
                             calledPocket: calledMarker,
                             calledPocketSatisfied: satisfied,
                             targetStrips: targetStrips,
                             targetGhostBall: targetGhost,
                             targetBall: targetBallMarker,
                             targetPocket: targetPocketMarker,
                             planeNormal: calibration.normal)
    }

    /// Ball rings without a prediction — rendered whenever live tracking
    /// has a state, so the overlay never goes fully dark just because no
    /// shot line exists yet (e.g. no cue ball designated).
    /// Rings only — plus the recommended shot, if there is one.
    ///
    /// The target layer belongs here and not only in `compose` because the
    /// case that matters most is exactly this one: the player has picked a
    /// ball but is not yet down on the shot, so there is no live aim to
    /// draw. Showing them how to make it is the whole point.
    public static func ballsOnly(state: TableState,
                                 calibration: TableCalibration,
                                 target: Target? = nil) -> OverlayLayout {
        compose(state: state, prediction: ShotPrediction(),
                calibration: calibration, target: target)
    }

    static func ballMarkers(state: TableState,
                            calibration: TableCalibration) -> [BallMarker] {
        let cueID = state.cueBall?.id
        return state.balls.map { ball in
            BallMarker(position: calibration.tableToWorld(ball.position),
                       radius: ball.radius,
                       isCue: ball.id == cueID)
        }
    }
}
