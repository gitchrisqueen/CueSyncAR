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
        /// Strip center in world space, lying on the cloth.
        public var midpoint: Vec3
        public var length: Double
        /// Rotation about the plane normal, radians, measured from the
        /// table-space +x axis to the strip direction.
        public var angle: Double
        public var dashed: Bool
        public var color: UInt32 // 0xRRGGBB token value
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

    /// The shot advisor's recommended shot (arcade "do this" layer), kept
    /// separate from the live-aim prediction so both can show at once: the
    /// player lines their stick up with the advised line.
    public struct Suggestion: Sendable, Equatable {
        /// Cue ball → ghost ball.
        public var aimStrip: Strip
        /// Target ball → pocket.
        public var objectStrip: Strip
        public var ghost: Marker
        /// Ring around the ball to hit.
        public var target: Marker
        public var pocket: Marker
        public var color: UInt32
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
    /// The advised shot, if the advisor has one (see `withSuggestion`).
    public var suggestion: Suggestion?

    /// An advised shot in TABLE space, as primitives (the app converts
    /// CoachKit's `ShotOption` to this; ARExperience does not depend on
    /// CoachKit). Ghost and target markers use the standard ball radius.
    public struct AdvisedShot: Equatable, Sendable {
        public var cue: Vec2
        public var ghost: Vec2
        public var target: Vec2
        public var pocket: Vec2
        public var pocketRadius: Double
        public var color: UInt32
        public var cueID: BallID
        public var targetID: BallID

        public init(cue: Vec2, ghost: Vec2, target: Vec2, pocket: Vec2,
                    pocketRadius: Double, color: UInt32,
                    cueID: BallID, targetID: BallID) {
            self.cue = cue
            self.ghost = ghost
            self.target = target
            self.pocket = pocket
            self.pocketRadius = pocketRadius
            self.color = color
            self.cueID = cueID
            self.targetID = targetID
        }
    }

    /// A copy of this layout carrying the advised shot.
    public func withSuggestion(_ shot: AdvisedShot,
                               calibration: TableCalibration) -> OverlayLayout {
        let (cue, ghost, target, pocket) = (shot.cue, shot.ghost, shot.target, shot.pocket)
        let (color, ballRadius) = (shot.color, Ball.standardRadius)
        let (cueID, targetID, pocketRadius) = (shot.cueID, shot.targetID, shot.pocketRadius)
        func strip(_ ballID: BallID, from a: Vec2, to b: Vec2,
                   dashed: Bool) -> Strip {
            let vector = b - a
            return Strip(ballID: ballID,
                         midpoint: calibration.tableToWorld((a + b) * 0.5),
                         length: vector.length,
                         angle: atan2(vector.y, vector.x),
                         dashed: dashed, color: color)
        }
        var copy = self
        copy.suggestion = Suggestion(
            aimStrip: strip(cueID, from: cue, to: ghost, dashed: false),
            objectStrip: strip(targetID, from: target, to: pocket, dashed: true),
            ghost: Marker(position: calibration.tableToWorld(ghost), radius: ballRadius),
            target: Marker(position: calibration.tableToWorld(target),
                           radius: ballRadius * 1.6),
            pocket: Marker(position: calibration.tableToWorld(pocket),
                           radius: pocketRadius * 1.25),
            color: color)
        return copy
    }

    /// Colors mirror TableScene's path styling rules (05-UX-DESIGN).
    public static func compose(state: TableState,
                               prediction: ShotPrediction,
                               calibration: TableCalibration,
                               calledPocket calledPocketID: PocketID? = nil,
                               aimColor: UInt32 = 0xF5A623,
                               objectColor: UInt32 = 0x2FA36B,
                               cueAfterColor: UInt32 = 0x4A90D9,
                               scratchColor: UInt32 = 0xE8604C) -> OverlayLayout {
        let cueID = state.cueBall?.id
        let contact = prediction.firstContact?.contact
        let cueScratched = cueID.map { prediction.pocketedBalls.contains($0) } ?? false

        var seenContact = false
        let strips = prediction.segments.compactMap { segment -> Strip? in
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
            return Strip(ballID: segment.ballID,
                         midpoint: calibration.tableToWorld(mid),
                         length: vector.length,
                         angle: atan2(vector.y, vector.x),
                         dashed: dashed,
                         color: color)
        }

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

        return OverlayLayout(strips: strips, ghostBall: ghost,
                             highlightedPockets: highlights,
                             balls: ballMarkers(state: state, calibration: calibration),
                             calledPocket: calledMarker,
                             calledPocketSatisfied: satisfied)
    }

    /// Ball rings without a prediction — rendered whenever live tracking
    /// has a state, so the overlay never goes fully dark just because no
    /// shot line exists yet (e.g. no cue ball designated).
    public static func ballsOnly(state: TableState,
                                 calibration: TableCalibration) -> OverlayLayout {
        OverlayLayout(strips: [], ghostBall: nil, highlightedPockets: [],
                      balls: ballMarkers(state: state, calibration: calibration),
                      calledPocket: nil, calledPocketSatisfied: false)
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
