//
//  ShotPrediction.swift
//  CueSyncCore
//
//  Solver output / renderer input. Everything is table-space geometry so the
//  AR overlay, the 2D table view, and tests all consume the same value.
//

import Foundation

public struct TrajectorySegment: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        /// Free roll from start to end.
        case roll
        /// Roll that ends by entering a pocket.
        case intoPocket
    }

    public var ballID: BallID
    public var start: Vec2
    public var end: Vec2
    public var kind: Kind
    /// Speed at the start of the segment, m/s.
    public var entrySpeed: Double

    public init(ballID: BallID, start: Vec2, end: Vec2,
                kind: Kind = .roll, entrySpeed: Double = 0) {
        self.ballID = ballID
        self.start = start
        self.end = end
        self.kind = kind
        self.entrySpeed = entrySpeed
    }

    public var length: Double { start.distance(to: end) }
}

public enum CollisionEvent: Sendable, Equatable, Codable {
    /// Moving ball struck a stationary ball at `contact` (ghost-ball center).
    case ballBall(moving: BallID, struck: BallID, contact: Vec2)
    /// Ball bounced off a cushion at `point`.
    case cushion(ball: BallID, point: Vec2)
    /// Ball was captured by a pocket.
    case pocket(ball: BallID, pocket: PocketID)
    /// Ball rolled to a stop at `point`.
    case rest(ball: BallID, point: Vec2)
}

public struct ShotPrediction: Sendable, Equatable, Codable {
    /// Polyline segments per ball, in simulation order.
    public var segments: [TrajectorySegment]
    /// Discrete events, in simulation order.
    public var events: [CollisionEvent]
    /// Balls predicted to be pocketed by this shot.
    public var pocketedBalls: [BallID]

    public init(segments: [TrajectorySegment] = [],
                events: [CollisionEvent] = [],
                pocketedBalls: [BallID] = []) {
        self.segments = segments
        self.events = events
        self.pocketedBalls = pocketedBalls
    }

    public func segments(for ball: BallID) -> [TrajectorySegment] {
        segments.filter { $0.ballID == ball }
    }

    /// The first ball-ball contact of the shot, if any (drives the ghost-ball UI).
    public var firstContact: (moving: BallID, struck: BallID, contact: Vec2)? {
        for event in events {
            if case let .ballBall(moving, struck, contact) = event {
                return (moving, struck, contact)
            }
        }
        return nil
    }

    /// Whether the cue ball is predicted to scratch (be pocketed).
    public func isScratch(cueBall: BallID) -> Bool {
        pocketedBalls.contains(cueBall)
    }
}
