import CueSyncCore
import Foundation
import Testing
@testable import PerceptionKit

/// Deterministic RNG for reproducible noise.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("Kalman smoothing")
struct KalmanTests {
    @Test func convergesOnNoisyStationaryMeasurements() {
        var rng = SplitMix64(seed: 11)
        let truth = 0.3
        var filter = ScalarKalman(initial: 0.35, initialVariance: 4e-4,
                                  processNoise: 4e-5, measurementNoise: 4e-4)
        for _ in 0..<40 {
            let noise = Double.random(in: -0.01...0.01, using: &rng)
            filter.update(measurement: truth + noise)
        }
        #expect(abs(filter.estimate - truth) < 0.005)
        #expect(filter.variance < 4e-4)
    }

    @Test func reconvergesAfterStep() {
        var filter = ScalarKalman(initial: 0.0, initialVariance: 4e-4,
                                  processNoise: 4e-5, measurementNoise: 4e-4)
        for _ in 0..<30 { filter.update(measurement: 0.0) }
        // Ball moved 20 cm; estimate must follow within a few dozen frames.
        for _ in 0..<40 { filter.update(measurement: 0.2) }
        #expect(abs(filter.estimate - 0.2) < 0.01)
    }
}

@Suite("BallTracker")
struct BallTrackerTests {
    let config = TrackerConfig()

    @Test func appearanceGatingSuppressesFlicker() {
        var tracker = BallTracker(config: config)
        let obs = [BallObservation(kind: .cue, position: Vec2(0.1, 0.1), confidence: 0.9)]
        // Below appearanceFrames → nothing reported.
        #expect(tracker.update(observations: obs).isEmpty)
        #expect(tracker.update(observations: obs).isEmpty)
        // Third consecutive frame confirms.
        let balls = tracker.update(observations: obs)
        #expect(balls.count == 1)
        #expect(balls[0].kind == .cue)
    }

    @Test func disappearanceGatingSurvivesShortDropouts() {
        var tracker = BallTracker(config: config)
        let obs = [BallObservation(kind: .solid(3), position: Vec2(0.2, -0.1), confidence: 0.9)]
        for _ in 0..<5 { _ = tracker.update(observations: obs) }

        // A few missed frames: ball must still be reported (no flicker)...
        for _ in 0..<(config.disappearanceFrames - 1) {
            let balls = tracker.update(observations: [])
            #expect(balls.count == 1)
        }
        // ...but a sustained absence drops it.
        let after = tracker.update(observations: [])
        #expect(after.isEmpty)
    }

    @Test func identitiesPersistWhenBallsPassClose() {
        var tracker = BallTracker(config: config)
        // Two balls approach, come within ~6 cm, and separate. Steps of
        // 1 cm/frame are far below the 8 cm gate.
        func frame(at t: Double) -> [BallObservation] {
            [
                BallObservation(kind: .solid(1), position: Vec2(-0.3 + 0.01 * t, 0.03), confidence: 0.9),
                BallObservation(kind: .solid(2), position: Vec2(0.3 - 0.01 * t, -0.03), confidence: 0.9)
            ]
        }
        var idForSolid1: BallID?
        for t in 0..<60 {
            let balls = tracker.update(observations: frame(at: Double(t)))
            guard let one = balls.first(where: { $0.kind == .solid(1) }) else { continue }
            if let expected = idForSolid1 {
                #expect(one.id == expected, "identity swapped at frame \(t)")
                // The solid-1 track keeps moving right.
            } else {
                idForSolid1 = one.id
            }
        }
        #expect(idForSolid1 != nil)
    }

    @Test func kindSettlesByMajorityVote() {
        var tracker = BallTracker(config: config)
        let position = Vec2(0.4, 0.2)
        // Misclassified for 2 frames, then correctly for 8.
        for _ in 0..<2 {
            _ = tracker.update(observations: [BallObservation(kind: .solid(2), position: position, confidence: 0.6)])
        }
        var last: [Ball] = []
        for _ in 0..<8 {
            last = tracker.update(observations: [BallObservation(kind: .stripe(10), position: position, confidence: 0.9)])
        }
        #expect(last.count == 1)
        #expect(last[0].kind == .stripe(10))
    }

    @Test func smoothingReducesJitter() {
        var rng = SplitMix64(seed: 42)
        var tracker = BallTracker(config: config)
        let truth = Vec2(0.5, 0.25)
        var last: [Ball] = []
        for _ in 0..<50 {
            let noisy = truth + Vec2(Double.random(in: -0.008...0.008, using: &rng),
                                     Double.random(in: -0.008...0.008, using: &rng))
            last = tracker.update(observations: [BallObservation(kind: .eight, position: noisy, confidence: 0.9)])
        }
        #expect(last.count == 1)
        #expect(last[0].position.distance(to: truth) < 0.005)
    }

    @Test func distinctBallsGetDistinctStableIDs() {
        var tracker = BallTracker(config: config)
        let obs = [
            BallObservation(kind: .cue, position: Vec2(-0.5, 0), confidence: 0.95),
            BallObservation(kind: .eight, position: Vec2(0.5, 0), confidence: 0.95)
        ]
        var balls: [Ball] = []
        for _ in 0..<5 { balls = tracker.update(observations: obs) }
        #expect(balls.count == 2)
        #expect(Set(balls.map(\.id)).count == 2)
        let idsBefore = balls.map(\.id)
        for _ in 0..<5 { balls = tracker.update(observations: obs) }
        #expect(balls.map(\.id) == idsBefore)
    }
}

@Suite("Vision box mapping")
struct VisionBoxMappingTests {
    @Test func flipsBottomLeftToTopLeft() {
        // A box occupying the bottom-left quarter in Vision coordinates
        // (origin bottom-left) is the top-left quarter... no: bottom-left
        // quarter in Vision is y ∈ [0, 0.5] from the bottom → top-left y is
        // 1 - 0 - 0.5 = 0.5 (lower half in top-left coords).
        let rect = VisionBoxMapping.topLeftRect(fromVisionX: 0, y: 0, width: 0.5, height: 0.5)
        #expect(rect == NormalizedRect(x: 0, y: 0.5, width: 0.5, height: 0.5))
        // Full-frame box is unchanged.
        let full = VisionBoxMapping.topLeftRect(fromVisionX: 0, y: 0, width: 1, height: 1)
        #expect(full == NormalizedRect(x: 0, y: 0, width: 1, height: 1))
    }
    @Test func outOfViewTracksDoNotDecay() {
        var tracker = BallTracker(config: TrackerConfig(appearanceFrames: 1,
                                                        disappearanceFrames: 3))
        let obs = BallObservation(kind: .cue, position: Vec2(0.5, 0.2), confidence: 0.9)
        _ = tracker.update(observations: [obs])
        // Camera looks elsewhere for far longer than the disappearance
        // budget — the static ball must survive untouched.
        for _ in 0..<20 {
            let balls = tracker.update(observations: [], isVisible: { _ in false })
            #expect(balls.count == 1)
        }
        // Back in view with no matching detection: NOW it decays.
        for _ in 0..<3 {
            _ = tracker.update(observations: [], isVisible: { _ in true })
        }
        #expect(tracker.update(observations: []).isEmpty)
    }

    @Test func duplicateTrackBeatenToItsBallIsAbsorbed() {
        var tracker = BallTracker(config: TrackerConfig(gatingDistance: 0.08,
                                                        appearanceFrames: 1))
        // Two tracks spawn a gate-width apart (the fast-ball duplicate).
        _ = tracker.update(observations: [
            BallObservation(kind: .cue, position: Vec2(0, 0), confidence: 0.9),
            BallObservation(kind: .unknown, position: Vec2(0.06, 0), confidence: 0.9)
        ])
        // One real ball between them: one track wins the association, the
        // other sits inside the winner's gate — absorbed, not decayed.
        let balls = tracker.update(observations: [
            BallObservation(kind: .cue, position: Vec2(0.03, 0), confidence: 0.9)
        ])
        #expect(balls.count == 1)
        // The merged track carries the combined vote history.
        #expect(balls[0].kind == .cue)
    }

}
