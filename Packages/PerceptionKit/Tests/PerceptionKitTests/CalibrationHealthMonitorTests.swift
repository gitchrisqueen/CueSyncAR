//
//  CalibrationHealthMonitorTests.swift
//  CueSync AR
//

import Foundation
import Testing
@testable import PerceptionKit

@Suite("Calibration health monitor")
struct CalibrationHealthMonitorTests {

    /// Pipeline rate seen on the iPad: about 5 frames a second.
    static let step = 0.2

    /// A frame of `detections` balls of which `offTable` were rejected and
    /// `clamped` were pulled onto the rail.
    static func sample(_ t: Double, detections: Int, offTable: Int = 0,
                       clamped: Int = 0) -> CalibrationHealthSample {
        CalibrationHealthSample(timestamp: t, detections: detections,
                                admitted: detections - offTable,
                                offTable: offTable, clamped: clamped)
    }

    /// Feed `seconds` of identical frames starting at `start`; returns the
    /// time after the last frame and every status seen on the way.
    @discardableResult
    static func run(_ monitor: inout CalibrationHealthMonitor, from start: Double,
                    seconds: Double, detections: Int, offTable: Int = 0,
                    clamped: Int = 0) -> (end: Double, seen: [CalibrationHealthMonitor.Status]) {
        var t = start
        var seen: [CalibrationHealthMonitor.Status] = []
        while t < start + seconds - 1e-9 {
            seen.append(monitor.ingest(sample(t, detections: detections,
                                              offTable: offTable, clamped: clamped)))
            t += step
        }
        return (t, seen)
    }

    @Test("Starts healthy and a well-calibrated table stays healthy")
    func healthyTable() {
        var monitor = CalibrationHealthMonitor()
        #expect(monitor.status == .healthy)
        let result = Self.run(&monitor, from: 0, seconds: 20, detections: 10, offTable: 1)
        #expect(result.seen.allSatisfy { $0 == .healthy })
    }

    @Test("An empty table never trips it")
    func emptyTable() {
        var monitor = CalibrationHealthMonitor()
        // Zero, one and two detections are all below the per-frame floor,
        // even when every one of them is rejected.
        for detections in 0...2 {
            let result = Self.run(&monitor, from: Double(detections) * 100, seconds: 30,
                                  detections: detections, offTable: detections)
            #expect(result.seen.allSatisfy { $0 == .healthy })
        }
        #expect(monitor.suspectFraction == nil)
    }

    @Test("One ball at the rail is not a bumped camera")
    func oneBallAtTheRail() {
        var monitor = CalibrationHealthMonitor()
        // Seven balls, one resting on the cushion and clamped to the rail.
        let result = Self.run(&monitor, from: 0, seconds: 30, detections: 7, clamped: 1)
        #expect(result.seen.allSatisfy { $0 == .healthy })
        // Even three balls with one clamped (33%) is under the line.
        var small = CalibrationHealthMonitor()
        let few = Self.run(&small, from: 0, seconds: 30, detections: 3, clamped: 1)
        #expect(few.seen.allSatisfy { $0 == .healthy })
    }

    @Test("Three balls alone are too few to be evidence, even all rejected")
    func tooFewBalls() {
        var monitor = CalibrationHealthMonitor()
        // 3 per frame passes the per-frame floor but the window mean is
        // under 4, so it is not evidence either way.
        let result = Self.run(&monitor, from: 0, seconds: 20, detections: 3, offTable: 3)
        #expect(result.seen.allSatisfy { $0 == .healthy })
    }

    @Test("The bumped-camera sequence from the iPad goes stale, not instantly")
    func bumpedCamera() throws {
        var monitor = CalibrationHealthMonitor()
        var (t, seen) = Self.run(&monitor, from: 0, seconds: 10, detections: 17, offTable: 1)
        #expect(seen.allSatisfy { $0 == .healthy })
        // 15 of 17 rejected, as in the log.
        let bump = Self.run(&monitor, from: t, seconds: 8, detections: 17, offTable: 15)
        t = bump.end
        #expect(bump.seen.first == .healthy, "one bad frame is not enough")
        #expect(bump.seen.contains(.suspect), "evidence builds through suspect")
        let index = try #require(bump.seen.firstIndex { $0.isStale })
        // Latency is bounded: the window must turn (<= 3 s) and then hold
        // for 2 s, so well under 6 s at 5 Hz.
        #expect(index <= Int(6 / Self.step))
        #expect(monitor.status == .stale(.offTable))
        #expect(monitor.status.label == "stale:offTable")
    }

    @Test("Stale is reported while it persists")
    func staysStale() {
        var monitor = CalibrationHealthMonitor()
        let bad = Self.run(&monitor, from: 0, seconds: 8, detections: 12, offTable: 10)
        let more = Self.run(&monitor, from: bad.end, seconds: 30, detections: 12, offTable: 10)
        #expect(more.seen.allSatisfy { $0 == .stale(.offTable) })
    }

    @Test("Recovery takes sustained good evidence, then clears")
    func recovery() throws {
        var monitor = CalibrationHealthMonitor()
        let bad = Self.run(&monitor, from: 0, seconds: 8, detections: 12, offTable: 10)
        #expect(monitor.status.isStale)
        // Re-calibrated (or the camera was put back): frames are clean.
        let good = Self.run(&monitor, from: bad.end, seconds: 10, detections: 12, offTable: 0)
        let index = try #require(good.seen.firstIndex { $0 == .healthy })
        // The window has to drain, then 2 s of good evidence.
        #expect(index >= Int(2 / Self.step), "must not clear on the first clean frame")
        #expect(index <= Int(6 / Self.step))
        #expect(monitor.status == .healthy)
        // And once healthy it stays healthy.
        let after = Self.run(&monitor, from: good.end, seconds: 5, detections: 12, offTable: 0)
        #expect(after.seen.allSatisfy { $0 == .healthy })
    }

    @Test("Flicker is rejected in both directions")
    func flicker() {
        var monitor = CalibrationHealthMonitor()
        // Entering: a 1 s burst of bad frames inside healthy ones.
        var t = 0.0
        var seen: [CalibrationHealthMonitor.Status] = []
        for _ in 0..<6 {
            let clean = Self.run(&monitor, from: t, seconds: 4, detections: 12, offTable: 0)
            let burst = Self.run(&monitor, from: clean.end, seconds: 1, detections: 12, offTable: 12)
            seen += clean.seen + burst.seen
            t = burst.end
        }
        #expect(!seen.contains { $0.isStale }, "a 1 s glitch must not raise the banner")

        // Leaving: a 1 s clean run inside a stale one must not clear it.
        var stale = CalibrationHealthMonitor()
        var u = Self.run(&stale, from: 0, seconds: 8, detections: 12, offTable: 12).end
        #expect(stale.status.isStale)
        var leftEarly = false
        for _ in 0..<5 {
            let clean = Self.run(&stale, from: u, seconds: 1, detections: 12, offTable: 0)
            let bad = Self.run(&stale, from: clean.end, seconds: 3, detections: 12, offTable: 12)
            leftEarly = leftEarly || clean.seen.contains(.healthy) || bad.seen.contains(.healthy)
            u = bad.end
        }
        #expect(!leftEarly)
        #expect(stale.status.isStale)
    }

    @Test("Frames below the floor in the middle of a bad run do not reset it")
    func ignoredFramesKeepTheRun() {
        var monitor = CalibrationHealthMonitor()
        var t = 0.0
        var seen: [CalibrationHealthMonitor.Status] = []
        for index in 0..<60 {
            // Every third frame the detector finds only two balls.
            let sample = index % 3 == 2
                ? Self.sample(t, detections: 2, offTable: 2)
                : Self.sample(t, detections: 12, offTable: 11)
            seen.append(monitor.ingest(sample))
            t += Self.step
        }
        #expect(seen.last == .stale(.offTable))
    }

    @Test("Rail clamping is reported as its own reason")
    func railClamped() {
        var monitor = CalibrationHealthMonitor()
        // The table is shifted a little: everything lands on the rail.
        Self.run(&monitor, from: 0, seconds: 8, detections: 10, clamped: 9)
        #expect(monitor.status == .stale(.railClamped))
    }

    @Test("A moved camera over a nearly empty table says nothing")
    func fewBallsAfterBump() {
        var monitor = CalibrationHealthMonitor()
        Self.run(&monitor, from: 0, seconds: 10, detections: 10, offTable: 0)
        // Two balls left, both off: below the per-frame floor, ignored.
        let result = Self.run(&monitor, from: 10, seconds: 20, detections: 2, offTable: 2)
        #expect(result.seen.allSatisfy { $0 == .healthy })
    }

    @Test("Reset returns to healthy with an empty window")
    func reset() {
        var monitor = CalibrationHealthMonitor()
        Self.run(&monitor, from: 0, seconds: 8, detections: 12, offTable: 12)
        #expect(monitor.status.isStale)
        monitor.reset()
        #expect(monitor.status == .healthy)
        #expect(monitor.suspectFraction == nil)
        #expect(monitor.meanDetections == nil)
    }

    @Test("Same samples, same verdicts: no clock inside")
    func deterministic() {
        func verdicts() -> [CalibrationHealthMonitor.Status] {
            var monitor = CalibrationHealthMonitor()
            var all = Self.run(&monitor, from: 500, seconds: 6, detections: 9, offTable: 1).seen
            all += Self.run(&monitor, from: 506, seconds: 8, detections: 9, offTable: 8).seen
            return all
        }
        #expect(verdicts() == verdicts())
    }

    @Test("Inconsistent counts cannot push the fraction past one")
    func clampsFraction() {
        var monitor = CalibrationHealthMonitor()
        monitor.ingest(CalibrationHealthSample(timestamp: 0, detections: 5, admitted: 0,
                                               offTable: 5, clamped: 5))
        #expect(monitor.suspectFraction == 1)
    }

    @Test("The mirror block is plain JSON numbers, and empty until there is a window")
    func mirrorStateIsSerialisable() {
        var monitor = CalibrationHealthMonitor()
        #expect(monitor.mirrorState["windowFrames"] as? Int == 0)
        #expect(monitor.mirrorState["suspectFraction"] == nil)
        monitor.ingest(Self.sample(0, detections: 10, offTable: 5))
        let state = monitor.mirrorState
        #expect(state["suspectFraction"] as? Double == 0.5)
        #expect(state["meanDetections"] as? Double == 10)
        #expect(JSONSerialization.isValidJSONObject(state))
        #expect(JSONSerialization.isValidJSONObject(["status": monitor.status.label]))
    }
}
