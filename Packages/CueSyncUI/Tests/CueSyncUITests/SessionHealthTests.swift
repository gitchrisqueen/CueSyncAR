//
//  SessionHealthTests.swift
//  CueSync AR
//

import Foundation
import Testing
@testable import CueSyncUI

@Suite("Session health")
struct SessionHealthTests {

    @Test("Frame rate needs two frames before it says anything")
    func rateNeedsTwoFrames() {
        var health = SessionHealth()
        #expect(health.framesPerSecond == nil)
        health.note(cameraTimestamp: 0, publishedAt: 0)
        #expect(health.framesPerSecond == nil)
        health.note(cameraTimestamp: 0.2, publishedAt: 0.2)
        #expect(health.framesPerSecond == 5)
    }

    @Test("A steady 5 Hz reads as 5 Hz, which is what the device actually does")
    func measuredDeviceCadence() {
        var health = SessionHealth()
        for tick in 0..<20 {
            let time = Double(tick) * 0.2
            health.note(cameraTimestamp: time, publishedAt: time)
        }
        let rate = try? #require(health.framesPerSecond)
        #expect(abs((rate ?? 0) - 5) < 0.001)
    }

    @Test("Latency is the camera-to-overlay gap, in milliseconds")
    func latency() {
        var health = SessionHealth()
        health.note(cameraTimestamp: 100.0, publishedAt: 100.040)
        health.note(cameraTimestamp: 100.2, publishedAt: 100.260)
        health.note(cameraTimestamp: 100.4, publishedAt: 100.450)
        let median = try? #require(health.overlayLatencyMilliseconds)
        #expect(abs((median ?? 0) - 50) < 0.001)
        let worst = try? #require(health.worstLatencyMilliseconds)
        #expect(abs((worst ?? 0) - 60) < 0.001)
    }

    @Test("Nonsense gaps are dropped rather than published")
    func rejectsImpossibleLatencies() {
        var health = SessionHealth()
        // Two clocks that do not agree produce a negative or enormous gap.
        // Publishing one is worse than publishing nothing, because someone
        // will quote it back as a measurement.
        health.note(cameraTimestamp: 500, publishedAt: 100)
        #expect(health.overlayLatencyMilliseconds == nil)
        health.note(cameraTimestamp: 0, publishedAt: 100)
        #expect(health.overlayLatencyMilliseconds == nil)
        health.note(cameraTimestamp: 100.0, publishedAt: 100.05)
        #expect(health.overlayLatencyMilliseconds != nil)
    }

    @Test("The window slides, so a recovered session stops reporting the stall")
    func windowSlides() {
        var health = SessionHealth()
        // A long stall, then a steady run longer than the window.
        health.note(cameraTimestamp: 0, publishedAt: 0)
        health.note(cameraTimestamp: 5, publishedAt: 5)
        for tick in 1...SessionHealth.window {
            let time = 5 + Double(tick) * 0.2
            health.note(cameraTimestamp: time, publishedAt: time)
        }
        let rate = try? #require(health.framesPerSecond)
        #expect(abs((rate ?? 0) - 5) < 0.001)
    }

    @Test("Reset clears both readings")
    func reset() {
        var health = SessionHealth()
        health.note(cameraTimestamp: 0, publishedAt: 0.05)
        health.note(cameraTimestamp: 0.2, publishedAt: 0.25)
        health.reset()
        #expect(health.framesPerSecond == nil)
        #expect(health.overlayLatencyMilliseconds == nil)
    }
}

@Suite("Thermal naming")
struct ThermalNameTests {
    @Test("Every thermal reading has a distinct word, not an enum case number")
    func everyStateIsNamed() {
        let names = ThermalReading.allCases.map(\.rawValue)
        #expect(names == ["nominal", "fair", "serious", "critical", "unknown"])
        // The mirror publishes these; a raw case number would be exactly the
        // "Running on: onDevice" mistake in a different file.
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { $0 == $0.lowercased() && !$0.isEmpty })
    }
}
