//
//  BallTrackerSparseTests.swift
//  PerceptionKitTests
//
//  A far-row ball the detector only sees on some frames (the far-tile pass
//  runs on alternate frames, its confidence hovers around the pipeline
//  floor) must keep ONE track id. On the iPad it kept restarting (ids 47, 51
//  and 55 inside 24 s, tentativeCount 1 or 2 in nearly every sample): the
//  tracker retired it between sightings and handed out fresh ids.
//
//  The tests drive the real BallTracker with a scene of fifteen steady balls
//  plus the ball under test, far-row jitter (about 2 cm along the table, 1 cm
//  across), and optionally a stray detection that matches nothing: that stray
//  is what puts an unmatched track on the short "ball was struck" budget.
//

import CueSyncCore
import Foundation
import Testing
@testable import PerceptionKit

private struct SparseScene {
    var tracker: BallTracker
    var rng: SplitMix64
    /// Far-row spot of the ball under test (table metres).
    let spot = Vec2(0.87, 0.03)
    /// Fifteen steady balls, seen on every frame.
    let others: [Vec2] = (0..<15).map {
        Vec2(-0.85 + 0.12 * Double($0), -0.3 + 0.04 * Double($0 % 3))
    }

    init(config: TrackerConfig = .default, seed: UInt64) {
        tracker = BallTracker(config: config)
        rng = SplitMix64(seed: seed)
    }

    struct Outcome {
        var ids: Set<Int> = []
        var reportedAtEnd = false
        /// Frames, after the first confirmation, on which the ball was missing.
        var gapsAfterFirstSight = 0
        /// Separate stretches of missing frames after the first sighting.
        var blinkEvents = 0
        var firstSight: Int?
    }

    mutating func jittered(_ p: Vec2) -> Vec2 {
        Vec2(p.x + Double.random(in: -0.02...0.02, using: &rng),
             p.y + Double.random(in: -0.01...0.01, using: &rng))
    }

    /// `seen` says on which frames the detector reports the target; `kind`
    /// is the label it carries on those frames.
    mutating func run(seconds: Double, dt: Double, strayEvery: Int = 0,
                      kind: (Int) -> Ball.Kind = { _ in .unknown },
                      seen: (Int) -> Bool) -> Outcome {
        var outcome = Outcome()
        var previouslyReported = false
        for frame in 0..<Int(seconds / dt) {
            var observations = others.map {
                BallObservation(kind: .unknown, position: jittered($0), confidence: 0.8)
            }
            if seen(frame) {
                observations.append(BallObservation(kind: kind(frame), position: jittered(spot),
                                                    confidence: 0.45))
            }
            if strayEvery > 0, frame % strayEvery == 0 {
                let at = Vec2(Double.random(in: -0.5...0.5, using: &rng),
                              Double.random(in: 0.5...0.6, using: &rng))
                observations.append(BallObservation(kind: .unknown, position: at, confidence: 0.4))
            }
            let balls = tracker.update(observations: observations, timestamp: 1 + Double(frame) * dt)
            let near = balls.filter { $0.position.distance(to: spot) < 0.05 }
            for ball in near { outcome.ids.insert(ball.id.rawValue) }
            outcome.reportedAtEnd = !near.isEmpty
            let wasReported = previouslyReported
            previouslyReported = !near.isEmpty
            if near.isEmpty {
                if outcome.firstSight != nil {
                    outcome.gapsAfterFirstSight += 1
                    if wasReported { outcome.blinkEvents += 1 }
                }
            } else if outcome.firstSight == nil {
                outcome.firstSight = frame
            }
        }
        return outcome
    }
}

@Suite("BallTracker: a ball seen on some frames only")
struct BallTrackerSparseTests {
    private static let rates: [(name: String, dt: Double)] = [("4 Hz", 0.25), ("9 Hz", 0.11)]

    /// Sixty seconds, one frame in two: ONE id, held to the end.
    @Test(arguments: rates) func oneFrameInTwoKeepsOneIdForSixtySeconds(rate: (name: String, dt: Double)) {
        for seed in [7, 8, 9] as [UInt64] {
            var scene = SparseScene(seed: seed)
            let outcome = scene.run(seconds: 60, dt: rate.dt) { $0 % 2 == 0 }
            #expect(outcome.ids.count == 1, "seed \(seed) \(rate.name): ids \(outcome.ids.sorted())")
            #expect(outcome.reportedAtEnd)
            #expect(outcome.gapsAfterFirstSight == 0)
        }
    }

    /// The same with a stray detection every seventh frame: each stray makes
    /// every unmatched track look like a ball that was struck away.
    @Test(arguments: rates) func oneFrameInTwoWithStraysKeepsOneId(rate: (name: String, dt: Double)) {
        for seed in [7, 8, 9] as [UInt64] {
            var scene = SparseScene(seed: seed)
            let outcome = scene.run(seconds: 60, dt: rate.dt, strayEvery: 7) { $0 % 2 == 0 }
            #expect(outcome.ids.count == 1, "seed \(seed) \(rate.name): ids \(outcome.ids.sorted())")
            #expect(outcome.reportedAtEnd)
            #expect(outcome.gapsAfterFirstSight == 0)
        }
    }

    /// Seen on 2 frames in 5 at random (the iPad: 8 samples of 20) with
    /// strays. This is the case that produced a new id every few seconds.
    @Test(arguments: rates) func twoFramesInFiveWithStraysKeepsOneId(rate: (name: String, dt: Double)) {
        for seed in [7, 8, 9] as [UInt64] {
            var scene = SparseScene(seed: seed)
            var dice = SplitMix64(seed: seed &+ 1000)
            let outcome = scene.run(seconds: 60, dt: rate.dt, strayEvery: 7) { _ in
                Double.random(in: 0..<1, using: &dice) < 0.4
            }
            #expect(outcome.ids.count == 1, "seed \(seed) \(rate.name): ids \(outcome.ids.sorted())")
            #expect(outcome.reportedAtEnd)
            // A rare blink happens (a run of misses far above the ball's own
            // pattern): the track retires, the SAME id comes back, and three
            // fresh sightings re-confirm it, about 8 frames at 40 % detection.
            // A restart under a new id does not happen (asserted above).
            #expect(outcome.blinkEvents <= 1,
                    "seed \(seed) \(rate.name): \(outcome.blinkEvents) blinks, \(outcome.gapsAfterFirstSight) frames")
            #expect(outcome.gapsAfterFirstSight <= 16)
        }
    }

    @Test func aTrackThatNeverConfirmedIsNotRetiredOnTheStrikeBudget() {
        var tracker = BallTracker()
        let spot = Vec2(0.5, 0.0)
        // One sighting, then a stray every frame so the track is "presumed
        // moved", then silence for 1.5 s: past the 0.75 s strike budget, well
        // inside the 2.5 s visible one. An unconfirmed track has no ring to
        // clear, so it must still be there to take the second sighting.
        _ = tracker.update(observations: [BallObservation(kind: .unknown, position: spot, confidence: 0.5)],
                           timestamp: 1)
        for step in 1...6 {
            _ = tracker.update(observations: [BallObservation(kind: .unknown, position: Vec2(-0.5, 0.2),
                                                              confidence: 0.5)],
                               timestamp: 1 + Double(step) * 0.25)
        }
        #expect(tracker.tentativeCount >= 1)
        let idBefore = tracker.nextTrackID
        _ = tracker.update(observations: [BallObservation(kind: .unknown, position: spot, confidence: 0.5)],
                           timestamp: 3)
        _ = tracker.update(observations: [BallObservation(kind: .unknown, position: spot, confidence: 0.5)],
                           timestamp: 3.25)
        // Two more sightings confirm the ORIGINAL track: no new id was minted.
        #expect(tracker.nextTrackID == idBefore)
    }

    @Test func aReclaimedIdentityReturnsToMemoryWhenItsTrackDiesUnconfirmed() {
        let config = TrackerConfig(appearanceFrames: 3, visibleMissGrace: 1, strikeMissGrace: 0.5,
                                   gapGraceMultiple: 0)
        var tracker = BallTracker(config: config)
        let spot = Vec2(0.5, 0.0)
        func see(at time: TimeInterval) {
            _ = tracker.update(observations: [BallObservation(kind: .unknown, position: spot, confidence: 0.5)],
                               timestamp: time)
        }
        func look(at time: TimeInterval) {
            _ = tracker.update(observations: [], timestamp: time)
        }
        // Confirm a ball, then lose it long enough to retire it.
        for i in 0..<3 { see(at: 1 + Double(i) * 0.1) }
        for i in 1...12 { look(at: 1.3 + Double(i) * 0.25) }
        #expect(tracker.tracks.isEmpty)
        let minted = tracker.nextTrackID
        // One sighting reclaims the id; then it dies before confirming ...
        see(at: 5)
        for i in 1...12 { look(at: 5 + Double(i) * 0.25) }
        #expect(tracker.tracks.isEmpty)
        // ... and the id is still on offer: the ball is back as the SAME id.
        for i in 0..<3 { see(at: 10 + Double(i) * 0.1) }
        #expect(tracker.nextTrackID == minted)
        #expect(tracker.update(observations: [BallObservation(kind: .unknown, position: spot, confidence: 0.5)],
                               timestamp: 10.3).map(\.id.rawValue) == [0])
    }

    @Test(arguments: [0.125, 0.25])
    func aWellDetectedBallStillClearsItsRingWithinTheStrikeBudget(step: Double) {
        var tracker = BallTracker()
        let spot = Vec2(0.0, 0.0)
        // Seen every frame (at 8 Hz and at 4 Hz), then struck: it vanishes and a ball shows
        // up elsewhere. The gap-scaled budget must not stretch for a ball
        // whose own gap is one frame.
        var time = 1.0
        for _ in 0..<40 {
            _ = tracker.update(observations: [BallObservation(kind: .unknown, position: spot, confidence: 0.9)],
                               timestamp: time)
            time += step
        }
        var visibleSeconds = 0.0
        var balls: [Ball] = []
        while visibleSeconds < 2 {
            balls = tracker.update(observations: [BallObservation(kind: .unknown, position: Vec2(0.5, 0.5),
                                                                  confidence: 0.9)],
                                   timestamp: time)
            time += step
            visibleSeconds += step
            if !balls.contains(where: { $0.position.distance(to: spot) < 0.05 }) { break }
        }
        #expect(visibleSeconds <= 1.0, "ring still up after \(visibleSeconds) s")
    }
}

@Suite("BallTracker: one cue ball")
struct BallTrackerCueUniquenessTests {
    private let cueSpot = Vec2(-0.27, 0.04)
    private let farSpot = Vec2(0.87, 0.03)

    private func frame(_ tracker: inout BallTracker, time: TimeInterval,
                       farKind: Ball.Kind?, cueSeen: Bool = true) -> [Ball] {
        var observations: [BallObservation] = []
        if cueSeen { observations.append(BallObservation(kind: .cue, position: cueSpot, confidence: 0.6)) }
        if let farKind {
            observations.append(BallObservation(kind: farKind, position: farSpot, confidence: 0.5))
        }
        return tracker.update(observations: observations, timestamp: time)
    }

    /// The far ball's FIRST box is labelled white-ball. With one vote each
    /// the tie used to go to `.cue`, so for a frame or two there were two.
    @Test func aWhiteBallBoxOnAnotherBallNeverMakesASecondCueBall() {
        var tracker = BallTracker()
        var cueID: BallID?
        for step in 0..<80 {
            // Cue ball first (the real one holds its id for the whole run).
            let farKind: Ball.Kind = step < 2 ? .cue : .unknown
            let balls = frame(&tracker, time: 1 + Double(step) * 0.11, farKind: farKind)
            let cues = balls.filter { $0.kind == .cue }
            #expect(cues.count <= 1, "frame \(step): \(cues.count) cue balls")
            if let cue = cues.first {
                cueID = cueID ?? cue.id
                #expect(cue.id == cueID)
                #expect(cue.position.distance(to: cueSpot) < 0.05)
            }
        }
        #expect(cueID != nil)
    }

    /// A far ball that keeps drawing white-ball boxes on some frames (a
    /// pale ball, a tile box) does not take the cue ball's role or its id.
    @Test func aFarBallThatKeepsGettingWhiteBallBoxesDoesNotStealTheCueBall() {
        var tracker = BallTracker()
        var cueID: BallID?
        for step in 0..<400 {
            let farKind: Ball.Kind? = step % 3 == 0 ? .cue : (step % 3 == 1 ? .unknown : nil)
            let balls = frame(&tracker, time: 1 + Double(step) * 0.11, farKind: farKind)
            let cues = balls.filter { $0.kind == .cue }
            #expect(cues.count <= 1, "frame \(step): \(cues.count) cue balls")
            if let cue = cues.first {
                cueID = cueID ?? cue.id
                #expect(cue.id == cueID)
            }
        }
        let final = frame(&tracker, time: 100, farKind: .unknown)
        #expect(final.first { $0.kind == .cue }?.position.distance(to: cueSpot) ?? 1 < 0.05)
    }

    @Test func theCueBallKeepsOneIdWhileTheDetectorMissesItHalfTheTime() {
        var tracker = BallTracker()
        var ids = Set<Int>()
        for step in 0..<400 {
            let balls = frame(&tracker, time: 1 + Double(step) * 0.11, farKind: .unknown,
                              cueSeen: step % 2 == 0)
            for cue in balls where cue.kind == .cue { ids.insert(cue.id.rawValue) }
        }
        #expect(ids.count == 1)
    }

    @Test func withNoOtherClaimantTheOnlyCueVotedTrackStaysTheCueBall() {
        var tracker = BallTracker()
        var balls: [Ball] = []
        for step in 0..<6 { balls = frame(&tracker, time: 1 + Double(step) * 0.1, farKind: nil) }
        #expect(balls.filter { $0.kind == .cue }.count == 1)
    }
}
