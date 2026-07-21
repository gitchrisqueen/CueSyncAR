//
//  Ball.swift
//  CueSyncCore
//

import Foundation

public struct BallID: Hashable, Sendable, Codable, RawRepresentable {
    public var rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public init(_ rawValue: Int) { self.rawValue = rawValue }
}

public struct Ball: Identifiable, Sendable, Equatable, Codable {
    public enum Kind: Sendable, Equatable, Hashable, Codable {
        case cue
        case eight
        case solid(Int)   // 1...7
        case stripe(Int)  // 9...15
        case unknown

        /// Map a detector class label (e.g. "cue", "8", "ball-9", "solid-3")
        /// to a kind. Unrecognized labels become `.unknown` — never a trap.
        public init(classLabel: String) {
            let label = classLabel.lowercased()
                .replacingOccurrences(of: "ball-", with: "")
                .replacingOccurrences(of: "-ball", with: "")
                .replacingOccurrences(of: "ball", with: "")
                .replacingOccurrences(of: "solid-", with: "")
                .replacingOccurrences(of: "stripe-", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
            if label == "cue" || label == "white" || label == "0" {
                self = .cue
            } else if let n = Int(label) {
                switch n {
                case 8: self = .eight
                case 1...7: self = .solid(n)
                case 9...15: self = .stripe(n)
                default: self = .unknown
                }
            } else {
                self = .unknown
            }
        }

        public var isCue: Bool { self == .cue }
    }

    public let id: BallID
    public var kind: Kind
    /// Center position in table space, meters.
    public var position: Vec2
    /// Ball radius, meters. Standard American pool ball: 57.15 mm diameter.
    public var radius: Double
    /// Detection confidence 0...1 (1 for synthetic/fixture states).
    public var confidence: Double

    public static let standardRadius = 0.028575

    public init(id: BallID, kind: Kind, position: Vec2,
                radius: Double = Ball.standardRadius, confidence: Double = 1) {
        self.id = id
        self.kind = kind
        self.position = position
        self.radius = radius
        self.confidence = confidence
    }
}

/// One coherent snapshot of everything on the table at a moment in time.
public struct TableState: Sendable, Equatable, Codable {
    public var table: Table
    public var balls: [Ball]
    /// Seconds, monotonic within a session (e.g. frame timestamp).
    public var timestamp: TimeInterval

    public init(table: Table, balls: [Ball], timestamp: TimeInterval = 0) {
        self.table = table
        self.balls = balls
        self.timestamp = timestamp
    }

    public var cueBall: Ball? { balls.first { $0.kind == .cue } }

    public func ball(_ id: BallID) -> Ball? { balls.first { $0.id == id } }
}

/// Where the player is aiming, in table space.
public struct AimRay: Sendable, Equatable, Codable {
    /// Ray origin — the cue ball's center.
    public var origin: Vec2
    /// Unit direction of the intended shot.
    public var direction: Vec2

    public init(origin: Vec2, direction: Vec2) {
        self.origin = origin
        self.direction = direction.normalized
    }
}
