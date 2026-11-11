//
//  FeedbackTests.swift
//  CoachKitTests
//
//  The arcade layer's data and its debouncing: every event has a plan,
//  nothing small buzzes the hand, jitter is not an event, and the log line a
//  remote tester greps is stable.
//

import Foundation
import Testing
@testable import CoachKit

@Suite("FeedbackPlan")
struct FeedbackPlanTests {
    @Test("Every event has an entry that is internally consistent")
    func everyEventHasAPlan() {
        for event in FeedbackEvent.allCases {
            let entry = FeedbackPlan.entry(for: event)
            #expect(entry.cooldown > 0, "\(event) needs a cooldown")
            if entry.banner != nil {
                #expect(entry.bannerDuration > 0, "\(event) has a banner with no duration")
            }
            if entry.announce || entry.speak {
                #expect(entry.banner != nil, "\(event) is announced but has no words")
            }
            if entry.priority == .ambient {
                #expect(entry.haptic == .none && entry.sound == .none, "\(event) is ambient and must be quiet")
            }
        }
    }

    @Test("The moments that matter are felt, heard and announced")
    func importantMoments() {
        for event in [FeedbackEvent.tableLocked, .shotMade, .shotMissed, .scratch, .trackingLost] {
            let entry = FeedbackPlan.entry(for: event)
            #expect(entry.priority == .important)
            #expect(entry.haptic != .none)
            #expect(entry.sound != .none)
            #expect(entry.announce, "\(event) must reach VoiceOver")
        }
    }

    @Test("Only the events SpokenGuidance does not already say are spoken")
    func spokenSet() {
        let spoken = Set(FeedbackEvent.allCases.filter { FeedbackPlan.entry(for: $0).speak })
        #expect(spoken == [.shotMade, .shotMadeOther, .shotMissed, .scratch])
    }

    @Test("Made and missed feel and sound different")
    func madeVersusMissed() {
        let made = FeedbackPlan.entry(for: .shotMade)
        let missed = FeedbackPlan.entry(for: .shotMissed)
        #expect(made.haptic == .success && made.sound == .made && made.tone == .good)
        #expect(missed.haptic == .warning && missed.sound == .miss && missed.tone == .caution)
    }

    @Test("Detail is folded into the banner where it helps, and ignored where it does not")
    func bannerText() {
        #expect(FeedbackPlan.bannerText(for: .shotMade, detail: "blue ball") == "Made it: blue ball")
        #expect(FeedbackPlan.bannerText(for: .shotMade, detail: nil) == "Made it")
        #expect(FeedbackPlan.bannerText(for: .shotMade, detail: "  ") == "Made it")
        #expect(FeedbackPlan.bannerText(for: .tableLocked, detail: "8-ft") == "Table locked: 8-ft")
        #expect(FeedbackPlan.bannerText(for: .shotMissed, detail: "blue ball") == "Missed. Line it up again")
        #expect(FeedbackPlan.bannerText(for: .shotChanged, detail: nil) == nil)
        #expect(FeedbackPlan.bannerText(for: .calibrationRefused, detail: "degenerateCorners") == "Couldn't lock the table")
    }

    @Test("The log line is stable, greppable and names what was played")
    func logLine() {
        let played = FeedbackRecord(event: .shotMade, time: 1, haptic: .success, sound: .made,
                                    banner: "Made it")
        #expect(played.logLine.hasPrefix("feedback: shotMade haptic=success sound=made"))
        let dropped = FeedbackRecord(event: .shotMade, time: 1, suppressed: "cooldown",
                                     haptic: .success, sound: .made, banner: "Made it")
        #expect(dropped.logLine == "feedback: shotMade suppressed=cooldown")
    }

    @Test("The log keeps the last twenty records, newest last")
    func logIsBounded() {
        var log = FeedbackLog()
        for i in 0..<35 {
            log.append(FeedbackRecord(event: .shotSelected, time: Double(i), haptic: .none,
                                      sound: .none, banner: nil))
        }
        #expect(log.records.count == FeedbackLog.capacity)
        #expect(log.records.first?.time == 15)
        #expect(log.records.last?.time == 34)
    }
}

@Suite("FeedbackThrottle")
struct FeedbackThrottleTests {
    @Test("The same event inside its cooldown is dropped, and allowed again after it")
    func cooldown() {
        var throttle = FeedbackThrottle()
        let cooldown = FeedbackPlan.entry(for: .shotSelected).cooldown
        #expect(throttle.admit(.shotSelected, at: 0) == .admit)
        #expect(throttle.admit(.shotSelected, at: cooldown / 2) == .cooldown)
        #expect(throttle.admit(.shotSelected, at: cooldown + 0.01) == .admit)
    }

    @Test("A burst of jitter events produces one admitted event")
    func burst() {
        var throttle = FeedbackThrottle()
        let verdicts = (0..<60).map { throttle.admit(.shotChanged, at: Double($0) * 0.03) }
        #expect(verdicts.filter { $0 == .admit }.count == 1)
    }

    @Test("Small events are quiet right after an important one")
    func quietAfterImportant() {
        var throttle = FeedbackThrottle()
        #expect(throttle.admit(.shotMade, at: 10) == .admit)
        #expect(throttle.admit(.ballCountChanged, at: 11) == .quiet)
        #expect(throttle.admit(.shotSelected, at: 11.2) == .quiet)
        #expect(throttle.admit(.shotChanged, at: 11.5) == .quiet)
        // ...and not for ever.
        #expect(throttle.admit(.ballCountChanged, at: 10 + throttle.quietAfterImportant + 0.1) == .admit)
    }

    @Test("An important event is never made quiet by another important one")
    func importantNotQuiet() {
        var throttle = FeedbackThrottle()
        #expect(throttle.admit(.shotMade, at: 0) == .admit)
        #expect(throttle.admit(.shotMissed, at: 0.2) == .admit)
    }

    @Test("Reset forgets everything")
    func reset() {
        var throttle = FeedbackThrottle()
        _ = throttle.admit(.shotMade, at: 0)
        throttle.reset()
        #expect(throttle.admit(.shotMade, at: 0.1) == .admit)
    }
}

@Suite("FeedbackWatcher")
struct FeedbackWatcherTests {
    private func events(_ watcher: inout FeedbackWatcher,
                        _ observations: [FeedbackObservation]) -> [FeedbackEvent] {
        observations.flatMap { watcher.observe($0).map(\.event) }
    }

    /// Observations every 0.25 s from `start`, each built by `make`.
    private func ticks(from start: Double, count: Int,
                       _ make: (Double) -> FeedbackObservation) -> [FeedbackObservation] {
        (0..<count).map { make(start + Double($0) * 0.25) }
    }

    @Test("A calibration already locked at launch is a baseline, not an event")
    func lockedAtLaunch() {
        var watcher = FeedbackWatcher()
        let seen = events(&watcher, ticks(from: 0, count: 8) { FeedbackObservation(time: $0, locked: true) })
        #expect(seen.isEmpty)
    }

    @Test("Locking the table fires once")
    func lock() {
        var watcher = FeedbackWatcher()
        var all = ticks(from: 0, count: 4) { FeedbackObservation(time: $0, locked: false) }
        all += ticks(from: 1, count: 8) { FeedbackObservation(time: $0, locked: true) }
        #expect(events(&watcher, all) == [.tableLocked])
    }

    @Test("A refusal fires once per distinct reason, and not when the table then locks")
    func refusal() {
        var watcher = FeedbackWatcher()
        let all = ticks(from: 0, count: 2) { FeedbackObservation(time: $0) }
            + ticks(from: 1, count: 4) { FeedbackObservation(time: $0, refusal: "Corners too close") }
            + ticks(from: 2, count: 2) { FeedbackObservation(time: $0, refusal: "Table looks tilted") }
        #expect(events(&watcher, all) == [.calibrationRefused, .calibrationRefused])
    }

    @Test("Recording start and stop")
    func recording() {
        var watcher = FeedbackWatcher()
        let all = ticks(from: 0, count: 2) { FeedbackObservation(time: $0) }
            + ticks(from: 1, count: 2) { FeedbackObservation(time: $0, recording: true) }
            + ticks(from: 2, count: 2) { FeedbackObservation(time: $0, recording: false) }
        #expect(events(&watcher, all) == [.recordingStarted, .recordingStopped])
    }

    @Test("The first balls after none are 'balls found'")
    func ballsFound() {
        var watcher = FeedbackWatcher()
        let all = ticks(from: 0, count: 3) { FeedbackObservation(time: $0, live: true, ballCount: 0) }
            + ticks(from: 1, count: 8) { FeedbackObservation(time: $0, live: true, ballCount: 6) }
        #expect(events(&watcher, all) == [.ballsFound])
    }

    @Test("A count that flickers is not a change; one that holds is")
    func ballCountDebounce() {
        var watcher = FeedbackWatcher()
        _ = events(&watcher, ticks(from: 0, count: 4) { FeedbackObservation(time: $0, live: true, ballCount: 6) })
        // 6, 5, 6, 5, 6... every tick for five seconds: tracker flicker.
        let flicker = ticks(from: 1, count: 20) { time in
            FeedbackObservation(time: time, live: true, ballCount: Int(time * 4) % 2 == 0 ? 5 : 6)
        }
        #expect(events(&watcher, flicker).isEmpty)
        // Five holds for two seconds.
        let held = ticks(from: 6, count: 10) { FeedbackObservation(time: $0, live: true, ballCount: 5) }
        #expect(events(&watcher, held) == [.ballCountChanged])
    }

    @Test("The player's tap is acknowledged at once; the suggestion changing waits to hold")
    func shots() {
        var watcher = FeedbackWatcher()
        var all = ticks(from: 0, count: 4) {
            FeedbackObservation(time: $0, live: true, ballCount: 5, shot: "3.sideTop")
        }
        // The app's own suggestion flips back and forth: jitter.
        all += ticks(from: 1, count: 12) { time in
            FeedbackObservation(time: time, live: true, ballCount: 5,
                                shot: Int(time * 4) % 2 == 0 ? "5.sideTop" : "3.sideTop")
        }
        #expect(events(&watcher, all).isEmpty)

        // A suggestion that holds.
        let held = ticks(from: 4, count: 8) {
            FeedbackObservation(time: $0, live: true, ballCount: 5, shot: "5.cornerTopLeft")
        }
        #expect(events(&watcher, held) == [.shotChanged])

        // The player taps a ball: immediate, once.
        let tapped = ticks(from: 6, count: 4) {
            FeedbackObservation(time: $0, live: true, ballCount: 5, shot: "7.sideTop",
                                shotChosenByPlayer: true)
        }
        #expect(events(&watcher, tapped) == [.shotSelected])
    }

    @Test("The first suggestion is the card appearing, not a change")
    func firstSuggestion() {
        var watcher = FeedbackWatcher()
        let all = ticks(from: 0, count: 2) { FeedbackObservation(time: $0, live: true, ballCount: 5) }
            + ticks(from: 1, count: 8) { FeedbackObservation(time: $0, live: true, ballCount: 5, shot: "3.sideTop") }
        #expect(events(&watcher, all).isEmpty)
    }

    @Test("No clean shot fires once after it holds, and again only after it clears")
    func noCleanShot() {
        var watcher = FeedbackWatcher()
        let first = ticks(from: 0, count: 20) {
            FeedbackObservation(time: $0, live: true, ballCount: 2, noCleanShot: true)
        }
        #expect(events(&watcher, first) == [.noCleanShot])
        let cleared = ticks(from: 5, count: 4) { FeedbackObservation(time: $0, live: true, ballCount: 2) }
        #expect(events(&watcher, cleared).isEmpty)
        let again = ticks(from: 6, count: 10) {
            FeedbackObservation(time: $0, live: true, ballCount: 2, noCleanShot: true)
        }
        #expect(events(&watcher, again) == [.noCleanShot])
    }

    @Test("A one-tick tracking wobble is not 'lost'; a held one is, and recovery follows")
    func trackingLostAndRecovered() {
        var watcher = FeedbackWatcher()
        var all = ticks(from: 0, count: 4) { FeedbackObservation(time: $0, live: true, ballCount: 5) }
        all += [FeedbackObservation(time: 1, live: true, degraded: true, ballCount: 5),
                FeedbackObservation(time: 1.25, live: true, ballCount: 5)]
        #expect(events(&watcher, all).isEmpty)

        let lost = ticks(from: 2, count: 8) {
            FeedbackObservation(time: $0, live: true, degraded: true, ballCount: 5)
        }
        #expect(events(&watcher, lost) == [.trackingLost])

        let back = ticks(from: 4, count: 8) { FeedbackObservation(time: $0, live: true, ballCount: 5) }
        #expect(events(&watcher, back) == [.trackingRecovered])
    }

    @Test("Tracking stopping resets the live debounces")
    func liveReset() {
        var watcher = FeedbackWatcher()
        _ = events(&watcher, ticks(from: 0, count: 4) { FeedbackObservation(time: $0, live: true, ballCount: 5) })
        _ = events(&watcher, ticks(from: 1, count: 2) { FeedbackObservation(time: $0, live: false) })
        let again = ticks(from: 2, count: 4) { FeedbackObservation(time: $0, live: true, ballCount: 5) }
        #expect(events(&watcher, again) == [.ballsFound])
    }
}
