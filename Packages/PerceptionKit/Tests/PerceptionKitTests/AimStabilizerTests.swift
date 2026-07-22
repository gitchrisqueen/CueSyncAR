import CueSyncCore
import Foundation
import Testing
@testable import PerceptionKit

@Suite("AimStabilizer")
struct AimStabilizerTests {
    @Test func firstSampleEmitsImmediately() {
        var stabilizer = AimStabilizer()
        let raw = AimRay(origin: Vec2(0.1, 0.2), direction: Vec2(1, 0))
        let (aim, changed) = stabilizer.stabilize(raw)
        #expect(changed)
        #expect(aim == raw)
    }

    @Test func noiseInsideDeadbandKeepsThePreviousAim() {
        var stabilizer = AimStabilizer()
        _ = stabilizer.stabilize(AimRay(origin: .zero, direction: Vec2(1, 0)))
        // ~0.5° of detector noise, alternating sign — must never re-emit.
        for i in 0..<20 {
            let angle = (i.isMultiple(of: 2) ? 1.0 : -1.0) * 0.009
            let noisy = AimRay(origin: Vec2(0.001, -0.001),
                               direction: Vec2(Foundation.cos(angle), Foundation.sin(angle)))
            let (aim, changed) = stabilizer.stabilize(noisy)
            #expect(!changed)
            #expect(aim.direction == Vec2(1, 0))
        }
    }

    @Test func intentionalSwingPassesThroughAfterSmoothing() {
        var stabilizer = AimStabilizer()
        _ = stabilizer.stabilize(AimRay(origin: .zero, direction: Vec2(1, 0)))
        // A real 20° aim change: within a few samples the stabilizer must
        // emit an updated direction approaching the new heading.
        let target = Vec2(Foundation.cos(0.35), Foundation.sin(0.35))
        var lastEmitted = Vec2(1, 0)
        var sawChange = false
        for _ in 0..<10 {
            let (aim, changed) = stabilizer.stabilize(AimRay(origin: .zero, direction: target))
            if changed { sawChange = true }
            lastEmitted = aim.direction
        }
        #expect(sawChange)
        #expect(Foundation.acos(max(-1, min(1, lastEmitted.dot(target)))) < 0.05)
    }

    @Test func originDriftAloneTriggersReEmit() {
        var stabilizer = AimStabilizer()
        _ = stabilizer.stabilize(AimRay(origin: .zero, direction: Vec2(0, 1)))
        var emitted = false
        for _ in 0..<10 {
            let (_, changed) = stabilizer.stabilize(
                AimRay(origin: Vec2(0.05, 0), direction: Vec2(0, 1)))
            if changed { emitted = true }
        }
        #expect(emitted)
    }

    @Test func resetForgetsHistory() {
        var stabilizer = AimStabilizer()
        _ = stabilizer.stabilize(AimRay(origin: .zero, direction: Vec2(1, 0)))
        stabilizer.reset()
        let fresh = AimRay(origin: Vec2(1, 1), direction: Vec2(0, 1))
        let (aim, changed) = stabilizer.stabilize(fresh)
        #expect(changed)
        #expect(aim == fresh)
    }
}
