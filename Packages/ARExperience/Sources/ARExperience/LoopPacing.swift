//
//  LoopPacing.swift
//  ARExperience
//
//  How long the AR loop rests at the end of a tick.
//
//  The loop used to sleep a fixed 150 ms after every tick, whatever the tick
//  had cost. Measured on an iPad (stage timers, 2026-11-12): detection 27 ms,
//  the whole pipeline 30 ms, the hand-off to the main actor about 40 ms, and
//  yet 3.8 ticks a second and 165 ms of overlay latency, because the sleep
//  was added on top of the work instead of covering what was left of the
//  period. Pacing to a period keeps a steady cadence and gives the time the
//  work did not use back to the next frame.
//

import Foundation

public enum LoopPacing {
    /// The rest that makes a tick last `period` in total, given the time its
    /// work has already taken.
    ///
    /// Never shorter than `floor`: the loop runs on the main actor, and a
    /// tick that overran its period must still let touches, layout and the
    /// renderer in before the next one starts.
    public static func rest(period: Duration, elapsed: Duration,
                            floor: Duration = .milliseconds(10)) -> Duration {
        let remaining = period - elapsed
        return remaining > floor ? remaining : floor
    }
}
