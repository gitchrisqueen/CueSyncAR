//
//  TableCount.swift
//  CueSyncUI
//
//  ONE rule for every ball count a player reads: object balls, never the cue
//  ball. A full rack is "15 balls", not 16; "Only seeing 4 of 15 balls" and
//  "Tracking 15 balls" count the same things. The tracker's table state
//  includes the cue ball (it must: it is the ball being aimed), so every
//  count shown goes through here.
//

import CueSyncCore
import Foundation

extension TableState {
    /// Balls on the table other than the cue ball.
    public var objectBallCount: Int {
        balls.count - (cueBall == nil ? 0 : 1)
    }
}
