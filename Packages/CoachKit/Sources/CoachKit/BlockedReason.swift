//
//  BlockedReason.swift
//  CoachKit
//
//  The TRUE reason a ball cannot be shot, in a player's words.
//
//  `ShotRanking.best` keeps one rating per ball, and when every pocket is
//  blocked they all rate 0, so the tie breaks on pocket id: the card got the
//  blocker of whichever pocket sorts first, which can be a pocket BEHIND the
//  ball ("No angle — that cut is past 90°") while another ball sits plainly
//  on the line to the pockets in front. The reason on the card has to be
//  the reason a player can see on the table.
//
//  Two entry points:
//  * `reason(for:name:)` — for ONE rating (a called pocket): that pocket's
//    own blocker.
//  * `reason(forBall:name:)` — for a ball with no pocket in mind: the blocker
//    of the pocket it comes closest to making, or "No angle to any pocket"
//    when every pocket is behind it or across its mouth.
//
//  Pure copy over `ShotRating`; the ranking itself is untouched.
//

import CueSyncCore
import Foundation

public enum BlockedReason {

    /// The reason for one rating's own blocker. `name` turns a ball id into
    /// the words the card uses for it ("2 Blue").
    public static func reason(for rating: ShotRating, name: (BallID) -> String) -> String {
        switch rating.blocker {
        case .cuePath(let id)?: "\(name(id)) is in the cue ball's way"
        case .objectPath(let id)?: "\(name(id)) is between it and the pocket"
        case .cueScratch?: "The cue ball would drop in a pocket first"
        case .pocketInTheWay?: "It would drop in a different pocket"
        case .cutTooThin?, .pocketFacingAway?: "No angle to that pocket"
        case nil: "Clear shot"
        }
    }

    /// The reason for a ball when no pocket is chosen, from every rating of
    /// that ball (one per pocket).
    public static func reason(forBall ratings: [ShotRating], name: (BallID) -> String) -> String {
        // A pocket a ball is in the way of, or that would swallow the cue
        // ball, is a pocket the player can actually see being missed. A
        // pocket behind the ball or across its mouth is not a reason worth
        // naming while another pocket has a real obstruction.
        let physical = ratings.filter {
            switch $0.blocker {
            case .cuePath?, .objectPath?, .cueScratch?, .pocketInTheWay?: true
            default: false
            }
        }
        guard let nearest = physical.min(by: { $0.cutAngleDegrees < $1.cutAngleDegrees }) else {
            return "No angle to any pocket"
        }
        return reason(for: nearest, name: name)
    }
}
