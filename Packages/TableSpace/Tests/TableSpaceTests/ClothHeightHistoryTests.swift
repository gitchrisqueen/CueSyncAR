//
//  ClothHeightHistoryTests.swift
//  CueSync AR
//
//  The case that matters is the real one: an estimate that looks
//  excellent and is still moving.
//

import Foundation
import Testing
@testable import TableSpace

@Suite("Cloth height history")
struct ClothHeightHistoryTests {

    /// Feed a series at 1 Hz starting from t = 100.
    private func history(_ heights: [Double], window: TimeInterval = 12) -> ClothHeightHistory {
        var history = ClothHeightHistory(window: window)
        for (index, height) in heights.enumerated() {
            history.record(height: height, at: 100 + Double(index))
        }
        return history
    }

    @Test("Too little history is not settled — the whole point")
    func thinHistoryIsNotSettled() {
        // Three identical readings a second apart. Perfectly consistent,
        // and worth nothing: this is exactly what the old spread check
        // saw right before the estimate moved 145 mm.
        let thin = history([-0.367, -0.367, -0.367])
        #expect(thin.drift == nil)
        #expect(!thin.hasSettled())
        #expect(thin.driftMillimetres == nil)
    }

    @Test("A settled estimate reads settled")
    func settledEstimateIsTrusted() {
        let steady = history(Array(repeating: -0.481, count: 14))
        #expect(steady.drift == 0)
        #expect(steady.hasSettled())
    }

    @Test("The real convergence is caught")
    func measuredConvergenceIsCaught() throws {
        // The readings taken off the device, interpolated: the estimate
        // walked 145 mm while every batch of balls agreed with itself.
        let converging = history(stride(from: -0.367, through: -0.512, by: -0.011).map { $0 })
        let drift = try #require(converging.drift)
        #expect(drift > 0.1, "a 145 mm walk was not seen as drift")
        #expect(!converging.hasSettled())
    }

    @Test("Jitter around a settled answer is not drift")
    func smallJitterStillSettles() {
        let jittery = history((0..<14).map { -0.481 + (($0 % 2 == 0) ? 0.003 : -0.003) })
        #expect(jittery.hasSettled())
        #expect((jittery.drift ?? 1) < 0.015)
    }

    @Test("Old readings fall out of the window")
    func windowForgets() {
        var history = ClothHeightHistory(window: 12)
        history.record(height: -0.200, at: 0)          // long ago and very wrong
        for index in 0..<14 { history.record(height: -0.481, at: 100 + Double(index)) }
        #expect(history.recent.allSatisfy { $0.height == -0.481 })
        #expect(history.hasSettled(), "a reading from 100 s ago still counted")
    }

    @Test("Time going backwards restarts rather than lying about coverage")
    func rewindResets() {
        var history = self.history(Array(repeating: -0.481, count: 14))
        #expect(history.hasSettled())
        history.record(height: -0.481, at: 5)
        #expect(history.drift == nil, "a rewound clock reported coverage it did not have")
    }

    @Test("The latest reading is still available while unsettled")
    func latestSurvivesUnsettled() {
        let converging = history([-0.367, -0.400, -0.450, -0.512])
        #expect(converging.latest == -0.512)
    }
}
