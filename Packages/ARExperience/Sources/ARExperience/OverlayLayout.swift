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
        /// The live aim keeps the semantic colours (amber for the cue's
        /// approach, white for the object ball's path). The plan is the
        /// hero: the object ball's leg is the heaviest mark on the table and
        /// the cue ball's leg a narrower one in its own colour (see
        /// OverlayStyle for the weights).
        public var role: Role = .live
        /// Which leg of the recommended shot this is. Only the plan's solid
        /// strips carry one; it tells the two legs apart for styling.
        public var leg: Leg = .none

        public enum Leg: String, Sendable, Equatable {
            case none
            /// The cue ball's approach to the ghost ball.
            case cue
            /// The target ball's path to the pocket.
            case object
        }

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
        /// The ball the suggested shot is for. While a shot is suggested,
        /// the cue ball and this one are the only balls with a marker.
        public var isTarget: Bool = false
    }

    /// Which shot is suggested: the thing that "changes" for the hero
    /// line's cross-fade. Two layouts with the same id are the same shot,
    /// however much a ball has jittered between them.
    public struct ShotID: Sendable, Hashable {
        public var ball: BallID
        public var pocket: PocketID
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
    /// The ball being shot at. Its ring is drawn from `balls` (the entry
    /// with `isTarget`), so the renderer does not draw this marker again.
    public var targetBall: Marker?
    /// The pocket the recommended shot is going into. The marker's centre is
    /// the pocket's position and its radius the pocket's capture radius; the
    /// renderer draws a ring there and the hero line ends at its centre.
    public var targetPocket: Marker?
    /// The suggested shot this layout carries; nil when there is none.
    public var shotID: ShotID?
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

    /// How many overlay primitives (lines, ghost spheres, pocket marks,
    /// rings) do NOT belong to the suggested shot: the measure behind "one
    /// line to follow, one pocket to hit, everything else quiet or gone".
    /// The suggested shot's own marks are the hero strips, the target ghost,
    /// the target pocket, and the rings on the cue ball and the target ball.
    public var primitivesOutsideSuggestion: Int {
        strips.count
            + (ghostBall == nil ? 0 : 1)
            + highlightedPockets.count
            + (calledPocket == nil ? 0 : 1)
            + balls.filter { !$0.isCue && !$0.isTarget }.count
    }

    /// The layout for one frame of the live loop: which of the three shapes
    /// the overlay takes, decided in one tested place.
    ///
    /// - Parameters:
    ///   - prediction: the live aim's prediction; nil when there is no live
    ///     aim (no cue held while parked, no cue ball, no stable direction).
    ///     Nil draws no live line and no live ghost ball.
    ///   - showsShotGuides: false in a game with friends: rings only.
    ///   - showsSecondaryLines: the test switch that restores the lines
    ///     hidden while a shot is suggested.
    public static func frame(state: TableState,
                             calibration: TableCalibration,
                             prediction: ShotPrediction?,
                             showsShotGuides: Bool,
                             calledPocket: PocketID? = nil,
                             target: Target? = nil,
                             showsSecondaryLines: Bool = false) -> OverlayLayout {
        guard showsShotGuides else {
            return ballsOnly(state: state, calibration: calibration, target: nil)
        }
        guard let prediction else {
            return ballsOnly(state: state, calibration: calibration, target: target,
                             showsSecondaryLines: showsSecondaryLines)
        }
        return compose(state: state, prediction: prediction, calibration: calibration,
                       calledPocket: calledPocket, target: target,
                       showsSecondaryLines: showsSecondaryLines)
    }

    /// Colors mirror TableScene's path styling rules (05-UX-DESIGN).
    ///
    /// While a shot is SUGGESTED (`target` non-nil) the table shows one line
    /// to follow and one pocket to hit: the hero line, the target ring, a
    /// ring on the cue ball and one on the target ball. Of the live aim only
    /// the cue's approach line stays (where the cue points now, to compare
    /// against the hero). The ghost ball, the cue ball after contact, the
    /// object ball's own predicted path, other balls' chains and the
    /// predicted-pocket marks are secondary and come back only with
    /// `showsSecondaryLines`. With no suggestion nothing is hidden.
    public static func compose(state: TableState,
                               prediction: ShotPrediction,
                               calibration: TableCalibration,
                               calledPocket calledPocketID: PocketID? = nil,
                               target: Target? = nil,
                               showsSecondaryLines: Bool = false,
                               aimColor: UInt32 = OverlayStyle.aimColor,
                               objectColor: UInt32 = OverlayStyle.objectPathColor,
                               cueAfterColor: UInt32 = OverlayStyle.postContactColor,
                               scratchColor: UInt32 = OverlayStyle.scratchColor) -> OverlayLayout {
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

            var color: UInt32
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
            // The recommended shot is the hero (OverlayStyle): white for the
            // cue ball's leg, green for the object ball's. Amber means
            // "where you are aiming" and nothing else, so the plan's
            // cue-ball leg is not amber.
            if role == .plan, !dashed {
                color = isCue ? OverlayStyle.heroCueColor : OverlayStyle.heroObjectColor
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
                         role: role,
                         leg: role == .plan && !dashed ? (isCue ? .cue : .object) : .none)
        }
        }

        var strips = buildStrips(prediction, role: .live)

        var ghost: Marker?
        if let contact = prediction.firstContact?.contact {
            let radius = state.cueBall?.radius ?? Ball.standardRadius
            ghost = Marker(position: calibration.tableToWorld(contact), radius: radius)
        }

        var litPockets: Set<PocketID> = []
        for event in prediction.events {
            if case let .pocket(_, pocket) = event { litPockets.insert(pocket) }
        }
        var highlights = state.table.pockets
            .filter { litPockets.contains($0.id) }
            .map { Marker(position: calibration.tableToWorld($0.position),
                          radius: $0.captureRadius) }

        // A suggestion owns the table. The live aim keeps only the cue's
        // approach line; its ghost sphere (which read as a second ghost
        // ball) and the rest are secondary.
        if target != nil, !showsSecondaryLines {
            strips = strips.filter { $0.ballID == cueID && !$0.dashed }
            ghost = nil
            highlights = []
        }

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

        let planStrips = target.map { buildStrips($0.prediction, role: .plan) } ?? []
        let layer = targetLayer(for: target, planStrips: planStrips, state: state,
                                calibration: calibration, showsSecondaryLines: showsSecondaryLines)

        return OverlayLayout(strips: strips, ghostBall: ghost,
                             highlightedPockets: highlights,
                             balls: ballMarkers(state: state, calibration: calibration, target: target),
                             calledPocket: calledMarker,
                             calledPocketSatisfied: satisfied,
                             targetStrips: layer.strips,
                             targetGhostBall: layer.ghost,
                             targetBall: layer.ball,
                             targetPocket: layer.pocket,
                             shotID: target.map { ShotID(ball: $0.ball, pocket: $0.pocket) },
                             planeNormal: calibration.normal)
    }

    /// The recommended shot's marks, laid out.
    private struct TargetLayer {
        var strips: [Strip] = []
        var ghost: Marker?
        var ball: Marker?
        var pocket: Marker?
    }

    /// The hero: the cue ball's approach to the ghost ball, then the object
    /// ball's leg from ITS CENTRE to the POCKET'S CENTRE. The object leg is
    /// the straight line the ranking aimed at, not the solver's roll-out,
    /// which stops where the ball is captured and so ended short of the
    /// pocket the ring marks. `planStrips` are the solver's strips for the
    /// ideal aim; only the cue ball's approach is kept from them, plus the
    /// rest when `showsSecondaryLines` is on.
    private static func targetLayer(for target: Target?, planStrips: [Strip],
                                    state: TableState, calibration: TableCalibration,
                                    showsSecondaryLines: Bool) -> TargetLayer {
        guard let target else { return TargetLayer() }
        let cueID = state.cueBall?.id
        var layer = TargetLayer()
        layer.ghost = Marker(position: calibration.tableToWorld(target.ghostBall),
                             radius: state.cueBall?.radius ?? Ball.standardRadius)
        let ball = state.ball(target.ball)
        let pocket = state.table.pockets.first(where: { $0.id == target.pocket })
        if let ball {
            layer.ball = Marker(position: calibration.tableToWorld(ball.position),
                                radius: ball.radius)
        }
        if let pocket {
            layer.pocket = Marker(position: calibration.tableToWorld(pocket.position),
                                  radius: pocket.captureRadius)
        }

        let cueLeg = planStrips.filter { $0.ballID == cueID && !$0.dashed }
        let objectLeg: [Strip]
        if let ball, let pocket {
            let start = calibration.tableToWorld(ball.position)
            let end = calibration.tableToWorld(pocket.position)
            objectLeg = [Strip(ballID: ball.id, start: start, end: end,
                               midpoint: (start + end) * 0.5,
                               length: (pocket.position - ball.position).length,
                               dashed: false, color: OverlayStyle.heroObjectColor,
                               role: .plan, leg: .object)]
        } else {
            // The ball or pocket is not in this state: draw what the solver
            // predicted rather than no object leg at all.
            objectLeg = planStrips.filter { $0.ballID == target.ball && !$0.dashed }
        }
        let secondary = showsSecondaryLines
            ? planStrips.filter { $0.dashed || ($0.ballID != cueID && $0.ballID != target.ball) }
            : []
        // Secondary first, so the hero is placed after it and never buried
        // under a line it crosses.
        layer.strips = secondary + cueLeg + objectLeg
        return layer
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
                                 target: Target? = nil,
                                 showsSecondaryLines: Bool = false) -> OverlayLayout {
        compose(state: state, prediction: ShotPrediction(),
                calibration: calibration, target: target,
                showsSecondaryLines: showsSecondaryLines)
    }

    /// One ring per tracked ball, or, while a shot is suggested, a ring on
    /// the cue ball and one on the target ball and nothing under the rest.
    static func ballMarkers(state: TableState,
                            calibration: TableCalibration,
                            target: Target? = nil) -> [BallMarker] {
        let cueID = state.cueBall?.id
        return state.balls.compactMap { ball in
            let isCue = ball.id == cueID
            let isTarget = !isCue && ball.id == target?.ball
            if target != nil, !isCue, !isTarget { return nil }
            return BallMarker(position: calibration.tableToWorld(ball.position),
                              radius: ball.radius,
                              isCue: isCue,
                              isTarget: isTarget)
        }
    }
}
