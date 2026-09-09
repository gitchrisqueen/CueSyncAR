//
//  DetectionHealthTests.swift
//  CueSyncUITests
//
//  Most of these are about NOT warning. A warning that fires while a
//  player clears a rack, or flickers at its own threshold, teaches them
//  to ignore the status line — which costs more than the warning ever
//  earns.
//

import Foundation
import Testing

@testable import CueSyncUI

@Suite("Detection health")
struct DetectionHealthTests {

    /// Feed `counts` one per second from `start`, and return the verdict
    /// after the last one.
    private func run(_ counts: [Int], luminance: Double? = nil,
                     config: DetectionHealth.Config = .default,
                     start: TimeInterval = 1000) -> DetectionHealth.Verdict {
        var health = DetectionHealth(config: config)
        var time = start
        var verdict = DetectionHealth.Verdict.healthy
        for count in counts {
            health.observe(detected: count, luminance: luminance, at: time)
            verdict = health.verdict(at: time)
            time += 1
        }
        return verdict
    }

    // MARK: - It warns when it should

    @Test("Six balls falling to two is reported, with the numbers")
    func collapseIsReported() {
        // The measured evening case.
        let verdict = run(Array(repeating: 6, count: 10) + Array(repeating: 2, count: 6))
        guard case .thin(let seen, let peak, _) = verdict else {
            Issue.record("expected thin, got \(verdict)")
            return
        }
        #expect(seen == 2)
        #expect(peak == 6)
    }

    @Test("A dim scene is told it is dim; a bright one is not given a cause")
    func causeIsOnlyClaimedWhenMeasured() {
        let dim = run(Array(repeating: 6, count: 10) + Array(repeating: 2, count: 6),
                      luminance: 0.25)
        guard case .thin(_, _, let dark) = dim else {
            Issue.record("expected thin, got \(dim)")
            return
        }
        #expect(dark, "0.25 mean luminance should read as dark")

        // Same collapse in good light: the app knows it has stopped
        // seeing balls, and does NOT know why. It must not blame the
        // lamp when the real cause might be a coat over the camera.
        let bright = run(Array(repeating: 6, count: 10) + Array(repeating: 2, count: 6),
                         luminance: 0.55)
        guard case .thin(_, _, let brightDark) = bright else {
            Issue.record("expected thin, got \(bright)")
            return
        }
        #expect(!brightDark)
    }

    @Test("No luminance reported at all is not treated as darkness")
    func missingLuminanceIsNotDarkness() {
        // Replay bundles carry detections but no pixels.
        let verdict = run(Array(repeating: 6, count: 10) + Array(repeating: 2, count: 6),
                          luminance: nil)
        guard case .thin(_, _, let dark) = verdict else {
            Issue.record("expected thin, got \(verdict)")
            return
        }
        #expect(!dark)
    }

    // MARK: - It stays quiet when it should

    @Test("A cold start does not announce a collapse before it has seen anything")
    func coldStartIsQuiet() {
        #expect(run([0, 0, 1, 2]) == .healthy)
    }

    @Test("A player setting up two balls for a drill is not a fault")
    func smallLayoutIsNotAFault() {
        // Peak never reaches minimumPeak, so there is no peak to fall from.
        #expect(run(Array(repeating: 2, count: 15) + [1, 1, 1]) == .healthy)
    }

    @Test("Steady tracking is healthy however long it runs")
    func steadyTrackingIsHealthy() {
        #expect(run(Array(repeating: 7, count: 40)) == .healthy)
    }

    @Test("One dropped frame is not a collapse")
    func singleDroppedFrameIsIgnored() {
        #expect(run([6, 6, 6, 6, 6, 6, 6, 6, 0, 6, 6, 6]) == .healthy)
    }

    @Test("A rack genuinely being cleared stops looking like a fault")
    func clearedRackRecoversOnceTheWindowMovesOn() {
        var health = DetectionHealth()
        var time = 1000.0
        // Full table, then balls pocketed one at a time over a few minutes.
        for count in [7, 7, 7, 7, 7, 7, 6, 5, 4, 3, 2, 1] {
            health.observe(detected: count, at: time)
            time += 3
        }
        // Immediately after the run-out the peak is still in the window,
        // so it does warn — correctly, it cannot tell a run-out from a
        // failure yet.
        // Well past the window, the peak has aged out and one ball on the
        // cloth is simply one ball on the cloth.
        for _ in 0..<12 {
            health.observe(detected: 1, at: time)
            time += 3
        }
        #expect(health.verdict(at: time) == .healthy)
    }

    // MARK: - Hysteresis

    @Test("Recall hovering at the threshold does not flicker the warning")
    func thresholdDoesNotFlicker() {
        var health = DetectionHealth()
        var time = 1000.0
        for _ in 0..<10 { health.observe(detected: 8, at: time); time += 1 }
        // Fall to exactly the thin fraction: warns.
        for _ in 0..<5 { health.observe(detected: 4, at: time); time += 1 }
        guard case .thin = health.verdict(at: time) else {
            Issue.record("expected thin at half the peak")
            return
        }
        // Creep back up past the thin line but NOT past the healthy line.
        // A single-threshold design would clear here and re-warn on the
        // next dip, twice a second, forever.
        for _ in 0..<5 { health.observe(detected: 5, at: time); time += 1 }
        guard case .thin = health.verdict(at: time) else {
            Issue.record("cleared too eagerly at 5/8")
            return
        }
        // Genuinely recovered.
        for _ in 0..<5 { health.observe(detected: 7, at: time); time += 1 }
        #expect(health.verdict(at: time) == .healthy)
    }

    @Test("Reset forgets everything, so a new table starts clean")
    func resetClearsHistory() {
        var health = DetectionHealth()
        var time = 1000.0
        for _ in 0..<10 { health.observe(detected: 8, at: time); time += 1 }
        for _ in 0..<5 { health.observe(detected: 1, at: time); time += 1 }
        guard case .thin = health.verdict(at: time) else {
            Issue.record("expected thin before reset")
            return
        }
        health.reset()
        health.observe(detected: 1, at: time)
        #expect(health.verdict(at: time) == .healthy)
        #expect(health.peak == 1)
    }

    // MARK: - The copy

    @Test("The status line names the numbers, and only blames the light when it is dark")
    func copyIsCheckableAndHonest() {
        #expect(HUDStatus.losingBalls(seen: 2, peak: 6, dark: true).label
            == "Only seeing 2 of 6 balls — more light would help")
        #expect(HUDStatus.losingBalls(seen: 2, peak: 6, dark: false).label
            == "Only seeing 2 of 6 balls")
    }

    @Test("Overlays fade when the app is seeing a fraction of the table")
    func overlaysFadeWhileThin() {
        #expect(HUDStatus.losingBalls(seen: 2, peak: 6, dark: true).overlayOpacity < 1.0)
        #expect(HUDStatus.tracking(ballCount: 6).overlayOpacity == 1.0)
    }
}
