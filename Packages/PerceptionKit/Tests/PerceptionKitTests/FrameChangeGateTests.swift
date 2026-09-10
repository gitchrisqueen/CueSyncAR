//
//  FrameChangeGateTests.swift
//  CueSync AR
//

import Foundation
import Testing
@testable import PerceptionKit

@Suite("Frame change gate")
struct FrameChangeGateTests {

    /// A 24x24 grid of dark cloth, which is what this table mostly is.
    static func cloth(_ level: Double = 0.12) -> FrameSignature {
        FrameSignature(cells: Array(repeating: level, count: 24 * 24))
    }

    /// The same cloth with `count` cells lit up — a ball arriving.
    static func cloth(withBallAt index: Int, brightness: Double = 0.75,
                      cells count: Int = 3) -> FrameSignature {
        var values = Array(repeating: 0.12, count: 24 * 24)
        for offset in 0..<count where index + offset < values.count {
            values[index + offset] = brightness
        }
        return FrameSignature(cells: values)
    }

    /// Sensor noise: every cell wobbles a little.
    static func noisy(_ base: FrameSignature, amplitude: Double = 0.01,
                      seed: UInt64 = 42) -> FrameSignature {
        var state = seed
        let cells = base.cells.map { value -> Double in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Double(state >> 11) / Double(UInt64.max >> 11)
            return min(1, max(0, value + (unit - 0.5) * 2 * amplitude))
        }
        return FrameSignature(cells: cells)
    }

    @Test("The first frame always goes through")
    func firstFrameProcesses() {
        var gate = FrameChangeGate()
        let ran1 = gate.shouldProcess(Self.cloth(), at: 0)
        #expect(ran1)
        #expect(gate.processed == 1)
        #expect(gate.skipped == 0)
    }

    @Test("An unchanged table is skipped")
    func staticSceneSkips() {
        var gate = FrameChangeGate()
        _ = gate.shouldProcess(Self.cloth(), at: 0)
        for tick in 1...4 {
            let ran = gate.shouldProcess(Self.cloth(), at: Double(tick) * 0.2)
            #expect(!ran, "an identical frame at tick \(tick) should not be re-processed")
        }
        #expect(gate.skipped == 4)
    }

    @Test("A ball moving is NOT skipped — the case the gate must never get wrong")
    func aMovedBallAlwaysProcesses() {
        var gate = FrameChangeGate()
        _ = gate.shouldProcess(Self.cloth(), at: 0)
        // Three cells go from cloth to ball. Averaged over 576 cells that
        // is a mean change of ~0.003 — which is why this gate reads the
        // MAXIMUM cell change and not the mean.
        let moved = Self.cloth(withBallAt: 200)
        let delta = moved.difference(from: Self.cloth())
        #expect((delta?.mean ?? 1) < 0.005, "a mean-based gate would miss this")
        #expect((delta?.maximum ?? 0) > 0.6, "the maximum is what makes it visible")
        let ran2 = gate.shouldProcess(moved, at: 0.2)
        #expect(ran2)
    }

    @Test("Sensor noise alone does not force a pass")
    func noiseDoesNotTrip() {
        var gate = FrameChangeGate()
        let base = Self.cloth()
        _ = gate.shouldProcess(base, at: 0)
        for tick in 1...4 {
            let ran = gate.shouldProcess(Self.noisy(base, seed: UInt64(tick)),
                                         at: Double(tick) * 0.2)
            #expect(!ran, "noise at tick \(tick) tripped the gate")
        }
    }

    @Test("A lighting change trips it even though no single cell moves much")
    func globalLightingChangeTrips() {
        var gate = FrameChangeGate()
        _ = gate.shouldProcess(Self.cloth(0.12), at: 0)
        // Every cell shifts by 0.02: under the per-cell threshold, over the
        // whole-frame one. This is the case the mean is kept for.
        let ran3 = gate.shouldProcess(Self.cloth(0.14), at: 0.2)
        #expect(ran3)
    }

    @Test("The heartbeat means it can never stall")
    func heartbeatAlwaysFires() {
        var gate = FrameChangeGate()
        let same = Self.cloth()
        _ = gate.shouldProcess(same, at: 0)
        let ran4 = gate.shouldProcess(same, at: 0.5)
        #expect(!ran4)
        // At the heartbeat, an identical frame goes through anyway. The
        // tracker's visible-miss grace is 2.5 s, so a skipped stretch this
        // short can never retire a track.
        let ran5 = gate.shouldProcess(same, at: 1.0)
        #expect(ran5)
    }

    @Test("A frame that could not be read is always processed")
    func unreadableFramesProcess() {
        var gate = FrameChangeGate()
        _ = gate.shouldProcess(Self.cloth(), at: 0)
        // The gate skips work it can PROVE is redundant. It can prove
        // nothing about a frame it could not sample.
        let ran6 = gate.shouldProcess(nil, at: 0.1)
        #expect(ran6)
    }

    @Test("Signatures of different sizes are treated as changed")
    func mismatchedGridsProcess() {
        var gate = FrameChangeGate()
        _ = gate.shouldProcess(Self.cloth(), at: 0)
        let ran7 = gate.shouldProcess(FrameSignature(cells: [0.1, 0.2]), at: 0.1)
        #expect(ran7)
    }

    @Test("Disabled, it lets everything through and says so")
    func disabledIsATrueBypass() {
        var gate = FrameChangeGate(isEnabled: false)
        let same = Self.cloth()
        for tick in 0...5 {
            let ran8 = gate.shouldProcess(same, at: Double(tick) * 0.1)
            #expect(ran8)
        }
        #expect(gate.skipped == 0)
        #expect(gate.skipRate == 0)
    }

    @Test("Skip rate is reported, so the win can be measured rather than assumed")
    func skipRateIsReported() {
        var gate = FrameChangeGate()
        #expect(gate.skipRate == nil)
        let same = Self.cloth()
        _ = gate.shouldProcess(same, at: 0)
        for tick in 1...3 { _ = gate.shouldProcess(same, at: Double(tick) * 0.1) }
        #expect(gate.skipRate == 0.75)
    }

    @Test("Reset forgets the last frame, so the next one is processed")
    func resetClears() {
        var gate = FrameChangeGate()
        let same = Self.cloth()
        _ = gate.shouldProcess(same, at: 0)
        let ran9 = gate.shouldProcess(same, at: 0.1)
        #expect(!ran9)
        gate.reset()
        let ran10 = gate.shouldProcess(same, at: 0.2)
        #expect(ran10)
        #expect(gate.skipped == 0)
    }
}
