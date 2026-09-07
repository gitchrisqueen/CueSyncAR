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
