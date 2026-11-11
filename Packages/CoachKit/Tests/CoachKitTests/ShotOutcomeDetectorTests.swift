//
//  ShotOutcomeDetectorTests.swift
//  CoachKitTests
//
//  Synthetic tracked-table sequences at 15 Hz for each outcome, and the
//  false-positive guards that matter more than the outcomes: a ball hidden
//  by a hand is not a made ball, and tracker jitter is not a shot.
//

import CueSyncCore
import Foundation
import Testing
@testable import CoachKit

@Suite("ShotOutcomeDetector")
struct ShotOutcomeDetectorTests {
    private let table = Table(size: .nineFoot)
    private let hz = 15.0
    private var hx: Double { table.halfExtents.x }
    private var hy: Double { table.halfExtents.y }

    // MARK: Helpers

    private func ball(_ id: Int, _ position: Vec2, cue: Bool = false) -> Ball {
        Ball(id: BallID(id), kind: cue ? .cue : .solid(max(1, id % 7)), position: position)
    }

    private func state(_ frame: Int, _ balls: [Ball]) -> TableState {
        TableState(table: table, balls: balls, timestamp: Double(frame) / hz)
    }

    /// Feed frames `range`, collecting every outcome with the frame it came on.
    private func run(_ detector: inout ShotOutcomeDetector, frames range: Range<Int>,
                     advised: AdvisedShot?,
                     build: (Int) -> [Ball]) -> [(frame: Int, outcome: ShotOutcome)] {
        var outcomes: [(Int, ShotOutcome)] = []
        for frame in range {
            if let outcome = detector.observe(state(frame, build(frame)), advised: advised) {
                outcomes.append((frame, outcome))
            }
        }
        return outcomes
    }

    /// The cue ball at rest until frame 10, struck there, and rolling to rest
    /// at frame 15.
    private func cuePosition(_ frame: Int) -> Vec2 {
        let rest = Vec2(-0.8, 0)
        let path: [Vec2] = [Vec2(-0.55, 0.0), Vec2(-0.3, 0.02), Vec2(-0.1, 0.03),
                            Vec2(0.0, 0.04), Vec2(0.03, 0.04), Vec2(0.03, 0.04)]
        switch frame {
        case ..<10: return rest
        case 10...15: return path[frame - 10]
        default: return path[5]
        }
    }

    /// An object ball resting at `start` that is hit at frame 12 and rolls
    /// along `toward` at ~1 m/s. Nil once it has moved for more than
    /// `lastSeen` frames (it has gone out of sight).
    private func rolling(from start: Vec2, toward target: Vec2, frame: Int,
                         lastSeen: Int) -> Vec2? {
        let moved = frame - 12
        guard moved > 0 else { return start }
        guard moved <= lastSeen else { return nil }
        let direction = (target - start).normalized
        return start + direction * (1.0 / hz) * Double(moved)
    }

    private let advisedTopRight = AdvisedShot(ball: BallID(3), pocket: .cornerTopRight)

    /// A sequence in which ball 3 is hit toward the top-right corner and
    /// disappears from the table state at the pocket.
    private func pottedInTopRight(_ frame: Int, coast: Int = 0) -> [Ball] {
        let start = Vec2(hx - 0.40, hy - 0.30)
        let pocket = Vec2(hx, hy)
        var balls = [ball(0, cuePosition(frame), cue: true), ball(5, Vec2(-0.9, -0.4))]
        if let p = rolling(from: start, toward: pocket, frame: min(frame, 18), lastSeen: 6),
           frame <= 18 + coast {
            balls.append(ball(3, p))
        }
        return balls
    }

    // MARK: Made

    @Test("The advised ball into the advised pocket is made as advised")
    func madeAsAdvised() throws {
        var detector = ShotOutcomeDetector()
        let outcomes = run(&detector, frames: 0..<120, advised: advisedTopRight) { pottedInTopRight($0) }
        #expect(outcomes.map(\.outcome) == [.madeAsAdvised(ball: BallID(3), pocket: .cornerTopRight)])
        // Not on the first missing frame: the absence has to be confirmed.
        let vanishFrame = 19
        #expect(try #require(outcomes.first).frame >= vanishFrame + 11)
    }

    @Test("A pocketed ball that lingers as a stale ring is made, never missed")
    func staleRingThenMade() {
        var detector = ShotOutcomeDetector()
        // The tracker's longest coast: 2.5 s at 15 Hz.
        let outcomes = run(&detector, frames: 0..<240, advised: advisedTopRight) {
            pottedInTopRight($0, coast: 37)
        }
        #expect(outcomes.map(\.outcome) == [.madeAsAdvised(ball: BallID(3), pocket: .cornerTopRight)])
    }

    @Test("Another ball going down while the advised one stays is made-other")
    func madeOther() {
        var detector = ShotOutcomeDetector()
        let outcomes = run(&detector, frames: 0..<120,
                           advised: AdvisedShot(ball: BallID(5), pocket: .cornerBottomLeft)) {
            pottedInTopRight($0)
        }
        #expect(outcomes.map(\.outcome) == [.madeOther(ball: BallID(3), pocket: .cornerTopRight)])
    }

    @Test("The advised ball into a different pocket is made-other")
    func advisedBallWrongPocket() {
        var detector = ShotOutcomeDetector()
        let outcomes = run(&detector, frames: 0..<120,
                           advised: AdvisedShot(ball: BallID(3), pocket: .sideTop)) {
            pottedInTopRight($0)
        }
        #expect(outcomes.map(\.outcome) == [.madeOther(ball: BallID(3), pocket: .cornerTopRight)])
    }

    @Test("With no advised shot a made ball is still reported, as made-other")
    func madeWithNoAdvice() {
        var detector = ShotOutcomeDetector()
        let outcomes = run(&detector, frames: 0..<120, advised: nil) { pottedInTopRight($0) }
        #expect(outcomes.map(\.outcome) == [.madeOther(ball: BallID(3), pocket: .cornerTopRight)])
    }

    // MARK: Missed

    @Test("A struck shot with the advised ball still up is missed, but not before the coast is over")
    func missed() throws {
        var detector = ShotOutcomeDetector()
        let outcomes = run(&detector, frames: 0..<200, advised: advisedTopRight) { f in
            [ball(0, cuePosition(f), cue: true), ball(3, Vec2(0.5, 0.3)), ball(5, Vec2(-0.4, -0.4))]
        }
        #expect(outcomes.map(\.outcome) == [.missed])
        let strikeTime = 10.0 / hz
        let calledAt = try #require(outcomes.first).frame
        #expect(Double(calledAt) / hz - strikeTime >= detector.config.missDelay)
    }

    @Test("A moved ball whose id churns is a miss, not a made ball")
    func churnedIdsAreAMiss() {
        var detector = ShotOutcomeDetector()
        let outcomes = run(&detector, frames: 0..<200, advised: advisedTopRight) { f in
            var balls = [ball(0, cuePosition(f), cue: true), ball(5, Vec2(-0.4, -0.4))]
            // The ball is struck at frame 12 and outruns the tracker's gate,
            // so its id changes twice on the way to rest mid-table.
            switch f {
            case ..<13: balls.append(ball(3, Vec2(0.5, 0.3)))
            case 13...14: balls.append(ball(3, Vec2(0.62, 0.25)))
            case 15...17: balls.append(ball(20, Vec2(0.8, 0.2)))
            default: balls.append(ball(21, Vec2(0.95, 0.15)))
            }
            return balls
        }
        #expect(outcomes.map(\.outcome) == [.missed])
    }

    @Test("A ball struck away from a pocket leaves a stale ring there; that is not a made ball")
    func phantomRingNearPocket() {
        var detector = ShotOutcomeDetector()
        let rest = Vec2(hx - 0.08, hy - 0.08)
        let outcomes = run(&detector, frames: 0..<200, advised: advisedTopRight) { f in
            var balls = [ball(0, cuePosition(f), cue: true), ball(5, Vec2(-0.4, -0.4))]
            if f < 13 + 20 { balls.append(ball(3, rest)) } // stale ring until it retires
            if f >= 13 { balls.append(ball(30, Vec2(0.7, 0.2))) } // the ball, found elsewhere
            return balls
        }
        #expect(outcomes.map(\.outcome) == [.missed])
    }

    // MARK: Scratch

    @Test("The cue ball vanishing into a pocket is a scratch")
    func scratch() {
        var detector = ShotOutcomeDetector()
        let outcomes = run(&detector, frames: 0..<120, advised: advisedTopRight) { f in
            var balls = [ball(3, Vec2(0.5, 0.3)), ball(5, Vec2(-0.4, -0.4))]
            switch f {
            case ..<10: balls.append(ball(0, Vec2(0, -0.1), cue: true))
            case 10...12: balls.append(ball(0, Vec2(0, -0.1 + 0.2 * Double(f - 9)), cue: true))
            default: break // gone, heading up the table at 3 m/s into the side pocket
            }
            return balls
        }
        #expect(outcomes.map(\.outcome) == [.scratch(pocket: .sideTop)])
    }

    // MARK: False-positive guards

    @Test("A ball hidden by a hand for a few frames is not made")
    func briefOcclusionIsNotMade() {
        var detector = ShotOutcomeDetector()
        let nearPocket = Vec2(hx - 0.05, hy - 0.05)
        let outcomes = run(&detector, frames: 0..<200, advised: advisedTopRight) { f in
            var balls = [ball(0, cuePosition(f), cue: true), ball(5, Vec2(-0.4, -0.4))]
            if !(20..<28).contains(f) { balls.append(ball(3, nearPocket)) } // 8 frames hidden
            return balls
        }
        #expect(!outcomes.contains { $0.outcome.isMade })
        #expect(outcomes.map(\.outcome) == [.missed])
    }

    @Test("A ball hidden and re-found under a new id at the same spot is not made")
    func occlusionThenReacquiredUnderNewID() {
        var detector = ShotOutcomeDetector()
        let nearPocket = Vec2(hx - 0.05, hy - 0.05)
        let outcomes = run(&detector, frames: 0..<240, advised: advisedTopRight) { f in
            var balls = [ball(0, cuePosition(f), cue: true), ball(5, Vec2(-0.4, -0.4))]
            if f < 20 { balls.append(ball(3, nearPocket)) }
            if f >= 29 { balls.append(ball(40, nearPocket)) } // 0.6 s later, same spot
            return balls
        }
        #expect(!outcomes.contains { $0.outcome.isMade })
    }

    @Test("A ball that vanishes in mid-table says nothing at all")
    func unexplainedVanishIsSilent() {
        var detector = ShotOutcomeDetector()
        let outcomes = run(&detector, frames: 0..<400, advised: advisedTopRight) { f in
            var balls = [ball(0, cuePosition(f), cue: true), ball(5, Vec2(-0.4, -0.4))]
            if f < 20 { balls.append(ball(3, Vec2(0.2, 0.1))) }
            return balls
        }
        #expect(outcomes.isEmpty)
        #expect(!detector.isShotInFlight, "the shot must end quietly, not hang")
    }

    @Test("Tracker jitter on every ball is never a shot")
    func jitterIsNotAShot() {
        var detector = ShotOutcomeDetector()
        let outcomes = run(&detector, frames: 0..<600, advised: advisedTopRight) { f in
            let wobble = (f % 2 == 0 ? 1.0 : -1.0) * 0.015
            return [ball(0, Vec2(-0.5 + wobble, 0.1 - wobble), cue: true),
                    ball(3, Vec2(0.5 - wobble, 0.3 + wobble)),
                    ball(5, Vec2(-0.4, -0.4 + wobble))]
        }
        #expect(outcomes.isEmpty)
        #expect(!detector.isShotInFlight)
    }

    @Test("A cue ball carried slowly across the table by a hand is not a shot")
    func slowDragIsNotAShot() {
        var detector = ShotOutcomeDetector()
        let outcomes = run(&detector, frames: 0..<300, advised: advisedTopRight) { f in
            // 0.3 m/s for a metre.
            let x = -0.8 + min(1.0, 0.3 / hz * Double(f))
            return [ball(0, Vec2(x, 0), cue: true), ball(3, Vec2(0.5, 0.3))]
        }
        #expect(outcomes.isEmpty)
        #expect(!detector.isShotInFlight)
    }

    @Test("The cue label flickering onto another ball for one frame is not a shot")
    func labelFlickerIsNotAShot() {
        var detector = ShotOutcomeDetector()
        let outcomes = run(&detector, frames: 0..<300, advised: advisedTopRight) { f in
            let flicker = f == 20
            return [ball(0, Vec2(-0.8, 0), cue: !flicker),
                    ball(3, Vec2(0.5, 0.3), cue: flicker)]
        }
        #expect(outcomes.isEmpty)
        #expect(!detector.isShotInFlight)
    }

    @Test("The cue label moving to another ball for good is a re-designation, not a shot")
    func relabelIsNotAShot() {
        var detector = ShotOutcomeDetector()
        let outcomes = run(&detector, frames: 0..<300, advised: advisedTopRight) { f in
            let swapped = f >= 20
            return [ball(0, Vec2(-0.8, 0), cue: !swapped),
                    ball(3, Vec2(0.5, 0.3), cue: swapped)]
        }
        #expect(outcomes.isEmpty)
        #expect(!detector.isShotInFlight)
    }

    // MARK: Lifecycle

    @Test("Two shots a few seconds apart give two outcomes")
    func twoShots() {
        var detector = ShotOutcomeDetector()
        let outcomes = run(&detector, frames: 0..<500, advised: advisedTopRight) { f in
            // The second shot is the first one repeated 200 frames later.
            let local = f < 200 ? f : f - 200
            var balls = [ball(3, Vec2(0.5, 0.3)), ball(5, Vec2(-0.4, -0.4))]
            // The player picks the cue ball up and sets it down again.
            if !(190..<200).contains(f) { balls.append(ball(0, cuePosition(local), cue: true)) }
            return balls
        }
        #expect(outcomes.map(\.outcome) == [.missed, .missed])
    }

    @Test("A clock that runs backwards starts a fresh session")
    func backwardsClockResets() {
        var detector = ShotOutcomeDetector()
        _ = run(&detector, frames: 0..<14, advised: advisedTopRight) { f in
            [ball(0, cuePosition(f), cue: true), ball(3, Vec2(0.5, 0.3))]
        }
        #expect(detector.isShotInFlight)
        _ = detector.observe(TableState(table: table, balls: [ball(0, Vec2(0, 0), cue: true)],
                                        timestamp: 0.1), advised: nil)
        #expect(!detector.isShotInFlight)
    }

    @Test("Outcomes map to the right feedback events")
    func eventMapping() {
        #expect(ShotOutcome.madeAsAdvised(ball: BallID(1), pocket: .sideTop).event == .shotMade)
        #expect(ShotOutcome.madeOther(ball: BallID(1), pocket: .sideTop).event == .shotMadeOther)
        #expect(ShotOutcome.missed.event == .shotMissed)
        #expect(ShotOutcome.scratch(pocket: .sideTop).event == .scratch)
        #expect(ShotOutcome.madeOther(ball: BallID(1), pocket: .sideTop).isMade)
        #expect(!ShotOutcome.scratch(pocket: .sideTop).isMade)
    }
}
