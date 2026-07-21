import CueSyncCore
import Foundation
import Testing
@testable import PerceptionKit

@Suite("StickAim")
struct StickAimTests {
    /// Thin stick lying along +x, tip at (−0.1, 0), butt at (−1.1, 0),
    /// slightly rotated so its bbox has real height. Image-order corners:
    /// the stick axis is the (TL, BR) diagonal.
    private func quadAlongX(tipX: Double = -0.1, buttX: Double = -1.1,
                            halfWidth: Double = 0.02) -> [Vec2] {
        [
            Vec2(buttX, halfWidth),   // TL (butt side)
            Vec2(tipX, halfWidth),    // TR
            Vec2(tipX, -halfWidth),   // BR (tip side)
            Vec2(buttX, -halfWidth)   // BL
        ]
    }

    @Test func aimsFromButtThroughTheCueBall() throws {
        let cue = Vec2(0, 0)
        // Diagonal (TL,BR): (-1.1, 0.02) → (-0.1, -0.02) — essentially +x.
        let ray = try #require(StickAim.estimate(stickQuad: quadAlongX(), cueBall: cue))
        #expect(ray.origin == cue)
        #expect(ray.direction.x > 0.99)
        #expect(abs(ray.direction.y) < 0.05)
    }

    @Test func directionFollowsTheStickWhenAimingTheOtherWay() throws {
        // Same stick mirrored: butt at +1.1, tip at +0.1 → aim along −x.
        let quad = [
            Vec2(0.1, 0.02),   // TL (tip side)
            Vec2(1.1, 0.02),   // TR
            Vec2(1.1, -0.02),  // BR (butt side)
            Vec2(0.1, -0.02)   // BL
        ]
        let ray = try #require(StickAim.estimate(stickQuad: quad, cueBall: .zero))
        #expect(ray.direction.x < -0.99)
    }

    @Test func rejectsAStickWhoseLineMissesTheBall() {
        // Stick along x but offset 0.5 m sideways — not aiming at this ball.
        let quad = quadAlongX().map { $0 + Vec2(0, 0.5) }
        #expect(StickAim.estimate(stickQuad: quad, cueBall: .zero) == nil)
    }

    @Test func rejectsAStickTooFarFromTheBall() {
        // Aligned but the tip is 1.4 m away — nobody is addressing the ball.
        #expect(StickAim.estimate(stickQuad: quadAlongX(tipX: -1.4, buttX: -2.4),
                                  cueBall: .zero) == nil)
    }

    @Test func rejectsStubbyQuadsAndBadInput() {
        #expect(StickAim.estimate(stickQuad: quadAlongX(tipX: -0.1, buttX: -0.3),
                                  cueBall: .zero) == nil)
        #expect(StickAim.estimate(stickQuad: [Vec2(0, 0)], cueBall: .zero) == nil)
    }

    @Test func picksTheDiagonalClosestToTheBall() throws {
        // A wider quad where the wrong diagonal would point well off the
        // ball: correct one still passes within tolerance.
        let quad = [
            Vec2(-1.1, 0.10),  // TL
            Vec2(-0.1, 0.14),  // TR
            Vec2(-0.1, -0.10), // BR
            Vec2(-1.1, -0.14)  // BL
        ]
        let ray = try #require(StickAim.estimate(stickQuad: quad, cueBall: .zero))
        // (TL,BR) diagonal: (-1.1,0.10)→(-0.1,-0.10): heads toward the
        // ball; direction dominated by +x.
        #expect(ray.direction.x > 0.95)
    }
}
