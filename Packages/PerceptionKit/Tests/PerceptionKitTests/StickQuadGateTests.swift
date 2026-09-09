//
//  StickQuadGateTests.swift
//  PerceptionKit
//
//  The on-table gate for stick quads, driven by the 2026-07-23 device
//  session where the far rail (classified "cue" at 74%) beat the real
//  stick on confidence and pinned aim to devicePose forever.
//

import CueSyncCore
import Testing
@testable import PerceptionKit

@Suite struct StickQuadGateTests {
    /// 8 ft table half-extents.
    private let halfExtents = Vec2(1.17, 0.585)

    @Test func realRailQuadFromDeviceSessionIsRejected() {
        // Verbatim quads captured over the mirror while aim was stuck on
        // the rail: every corner beyond the cushions (worst corner only
        // ~7 cm out in x — the margin must stay below that).
        let sampledRailQuads = [
            [Vec2(-0.69, 0.83), Vec2(1.29, 0.27), Vec2(1.25, 0.85), Vec2(-0.18, 1.31)],
            [Vec2(-0.83, 0.84), Vec2(1.30, 0.25), Vec2(1.25, 0.87), Vec2(-0.24, 1.35)],
        ]
        for quad in sampledRailQuads {
            #expect(!StickAim.quadOnTable(quad, halfExtents: halfExtents))
        }
    }

    @Test func aimingStickWithButtOverhangingNearRailIsAccepted() {
        // Tip end over the cloth near the cue ball, butt well past the
        // near cushion (normal address stance).
        let quad = [Vec2(-0.1, -0.1), Vec2(-0.05, -0.15),
                    Vec2(-0.9, -1.1), Vec2(-0.95, -1.0)]
        #expect(StickAim.quadOnTable(quad, halfExtents: halfExtents))
    }

    @Test func quadEntirelyOffTableIsRejected() {
        let quad = [Vec2(1.5, 0.9), Vec2(2.0, 1.1), Vec2(1.9, 1.4), Vec2(1.4, 1.2)]
        #expect(!StickAim.quadOnTable(quad, halfExtents: halfExtents))
    }

    @Test func marginForgivesACornerJustOutsideTheNose() {
        let quad = [Vec2(1.2, 0.6), Vec2(1.5, 0.9), Vec2(1.6, 1.0), Vec2(1.3, 0.8)]
        // (1.2, 0.6) is within the 0.1 m margin of (1.17, 0.585).
        #expect(StickAim.quadOnTable(quad, halfExtents: halfExtents))
    }
}

/// The 171-degree aim reversal, measured on a real recording and fixed by
/// choosing readings by agreement with the last accepted one.
@Suite("Stick aim continuity")
struct StickAimContinuityTests {
    /// A near-square quad: its two diagonals are near mirrors, so which one
    /// "passes closest to the cue ball" is decided by noise.
    private func quad(around centre: Vec2, half: Double) -> [Vec2] {
        [Vec2(centre.x - half, centre.y + half), Vec2(centre.x + half, centre.y + half),
         Vec2(centre.x + half, centre.y - half), Vec2(centre.x - half, centre.y - half)]
    }

    @Test("With no previous aim, the tip is simply the end nearer the ball")
    func geometryDecidesWithoutHistory() throws {
        let cueBall = Vec2(0, 0)
        // A clean stick along +x: near end at 0.1, far end at 1.1.
        let stick = [Vec2(0.1, 0.01), Vec2(1.1, 0.01), Vec2(1.1, -0.01), Vec2(0.1, -0.01)]
        let aim = try #require(StickAim.estimate(stickQuad: stick, cueBall: cueBall))
        // Aim runs from the butt THROUGH the ball, so it points away from
        // the stick: -x.
        #expect(aim.direction.x < -0.99)
    }

    @Test("A reversed reading is refused when a previous aim disagrees")
    func previousAimSuppressesAReversal() throws {
        // The cue ball sits almost exactly MIDWAY along the stick's axis,
        // so the two ends are near-equidistant and which one is called the
        // tip is decided by a hair. This is the configuration that produced
        // a 171-degree flip between consecutive frames on the device.
        let cueBall = Vec2(0.01, 0)
        let symmetric = [Vec2(-0.5, 0.02), Vec2(0.5, 0.02),
                         Vec2(0.5, -0.02), Vec2(-0.5, -0.02)]
        let forward = AimRay(origin: cueBall, direction: Vec2(1, 0))
        let backward = AimRay(origin: cueBall, direction: Vec2(-1, 0))

        let withForward = try #require(
            StickAim.estimate(stickQuad: symmetric, cueBall: cueBall, previous: forward))
        let withBackward = try #require(
            StickAim.estimate(stickQuad: symmetric, cueBall: cueBall, previous: backward))

        // Same quad, opposite histories: each keeps its own heading rather
        // than both collapsing onto whichever end geometry happens to pick.
        #expect(withForward.direction.dot(forward.direction) > 0)
        #expect(withBackward.direction.dot(backward.direction) > 0)
        #expect(withForward.direction.dot(withBackward.direction) < 0)
    }

    @Test("A previous aim that agrees with neither reading falls back to geometry")
    func disagreeingHistoryDoesNotOverrideGeometry() throws {
        let cueBall = Vec2.zero
        let stick = [Vec2(0.1, 0.01), Vec2(1.1, 0.01), Vec2(1.1, -0.01), Vec2(0.1, -0.01)]
        // Perpendicular to both possible readings.
        let sideways = AimRay(origin: cueBall, direction: Vec2(0, 1))
        let aim = try #require(
            StickAim.estimate(stickQuad: stick, cueBall: cueBall, previous: sideways))
        #expect(aim.direction.x < -0.99)
    }

    @Test("The gate's bounds still reject what they always rejected")
    func boundsStillApply() {
        let cueBall = Vec2.zero
        // Too short.
        let stub = quad(around: Vec2(0.2, 0), half: 0.05)
        #expect(StickAim.estimate(stickQuad: stub, cueBall: cueBall) == nil)
        // Line passes far from the cue ball.
        let elsewhere = [Vec2(0.5, 0.6), Vec2(1.5, 0.6), Vec2(1.5, 0.58), Vec2(0.5, 0.58)]
        #expect(StickAim.estimate(stickQuad: elsewhere, cueBall: cueBall) == nil)
    }
}
