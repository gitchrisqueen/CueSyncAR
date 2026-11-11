//
//  ShotAvailability.swift
//  CoachKit
//
//  Why there is, or is not, a shot to show.
//
//  When the ranking offered nothing the shot card simply vanished, and a
//  player cannot tell "nothing clean to pot" from "the app has stopped".
//  A full rack is the same blank on the most common shot of every game.
//  This names the three situations so the HUD can say something in each.
//

import CueSyncCore
import Foundation

public enum ShotAvailability: Sendable, Equatable {
    /// A shot is on offer; the card shows it (or why it is blocked).
    case shot
    /// Balls on the table and none can be potted cleanly: play safe.
    case noCleanShot
    /// A full rack, untouched: nothing to rank, a break to play.
    case breakRack
    /// Nothing worth saying: no cue ball (the status line already asks
    /// for one) or nothing to shoot at.
    case notApplicable

    /// An object ball further than this from the group's centre is not
    /// part of a rack. A standard rack is 0.23 m across at the base.
    static let rackRadius = 0.30
    /// Object balls needed before a cluster counts as a rack. Fifteen when
    /// whole; the tracker may miss a few in a tight triangle.
    static let rackMinimumBalls = 10

    /// - Parameters:
    ///   - state: the tracked table.
    ///   - active: the shot on offer, if any (`ShotSelection.active`).
    public static func classify(state: TableState, active: ShotRating?) -> ShotAvailability {
        guard state.cueBall != nil else { return .notApplicable }
        let objects = state.balls.filter { $0.kind != .cue }
        guard !objects.isEmpty else { return .notApplicable }
        // The rack first: a full triangle can still rate a blocked shot
        // into its apex, and "blocked" is the wrong thing to tell
        // someone who is about to break.
        if isRack(objects) { return .breakRack }
        return active == nil ? .noCleanShot : .shot
    }

    private static func isRack(_ objects: [Ball]) -> Bool {
        guard objects.count >= rackMinimumBalls else { return false }
        let centre = objects.reduce(Vec2(0, 0)) { $0 + $1.position } / Double(objects.count)
        return objects.allSatisfy { $0.position.distance(to: centre) <= rackRadius }
    }
}
