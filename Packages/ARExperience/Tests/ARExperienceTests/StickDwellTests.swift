//
//  StickDwellTests.swift
//  ARExperienceTests
//
//  The property that makes dwell usable at all: it must never call a cue
//  "resting" while someone is actually aiming with it. Suppressing a
//  discarded cue is worth nothing if it also suppresses the player.
//

import CueSyncCore
import Foundation
import Testing
@testable import ARExperience

@Suite("Stick dwell")
struct StickDwellTests {
    private let rate = 1.0 / 4.5   // the device's observed frame cadence

    @Test("A cue with no history is never called resting")
    func needsAFullWindowFirst() {
        var dwell = StickDwell()
        // Perfectly still, but only for two seconds.
        for i in 0..<9 {
            dwell.record(Vec2(0.5, 0.2), at: Double(i) * rate)
        }
        #expect(!dwell.isStatic)
        #expect(dwell.observedSeconds < 8)
    }

    @Test("A cue that sits still for a full window is resting")
    func staticOverAFullWindowIsResting() {
        var dwell = StickDwell()
        for i in 0..<50 {
            // A centimetre of detector noise, no real movement.
            let jitter = Vec2(Double(i % 3) * 0.005, Double(i % 2) * 0.005)
            dwell.record(Vec2(0.5, 0.2) + jitter, at: Double(i) * rate)
        }
        #expect(dwell.observedSeconds >= 8)
        #expect(dwell.isStatic)
    }

    @Test("A cue being handled is not resting, even over a long window")
    func movementDefeatsIt() {
        var dwell = StickDwell()
        for i in 0..<50 {
            // Half a metre of travel across the window: addressing, drawing
            // back, stroking.
            let t = Double(i) * rate
            dwell.record(Vec2(0.5 + sin(t) * 0.3, 0.2), at: t)
        }
        #expect(dwell.observedSeconds >= 8)
        #expect(!dwell.isStatic)
    }

    @Test("Leaving the window behind clears the verdict")
    func movingAfterRestingClearsIt() {
        var dwell = StickDwell()
        for i in 0..<50 { dwell.record(Vec2(0.5, 0.2), at: Double(i) * rate) }
        #expect(dwell.isStatic)
        // Picked up and moved a metre: the old samples age out.
        for i in 50..<100 {
            dwell.record(Vec2(0.5 + Double(i - 50) * 0.02, 0.2), at: Double(i) * rate)
        }
        #expect(!dwell.isStatic)
    }

    @Test("Time running backwards starts a fresh history")
    func timeGoingBackwardsResets() {
        var dwell = StickDwell()
        for i in 0..<50 { dwell.record(Vec2(0.5, 0.2), at: Double(i) * rate) }
        #expect(dwell.isStatic)
        // A new session, or a replay rewind.
        dwell.record(Vec2(0.5, 0.2), at: 0)
        #expect(!dwell.isStatic)
    }

    @Test("The centroid is the quad's average corner")
    func centroidIsTheAverage() throws {
        let quad = [Vec2(0, 0), Vec2(2, 0), Vec2(2, 2), Vec2(0, 2)]
        let centre = try #require(StickDwell.centroid(of: quad))
        #expect(centre.distance(to: Vec2(1, 1)) < 1e-12)
        #expect(StickDwell.centroid(of: []) == nil)
    }
}
