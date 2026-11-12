//
//  LoopPacingTests.swift
//  CueSync AR
//

import Foundation
import Testing
@testable import ARExperience

@Suite("Loop pacing")
struct LoopPacingTests {
    private let period = Duration.milliseconds(100)

    @Test("A cheap tick rests for what is left of the period")
    func restsForTheRemainder() {
        #expect(LoopPacing.rest(period: period, elapsed: .milliseconds(30)) == .milliseconds(70))
        #expect(LoopPacing.rest(period: period, elapsed: .zero) == period)
    }

    @Test("Work plus rest adds up to the period, so the cadence is steady")
    func cadenceIsThePeriod() {
        for work in stride(from: 0, through: 90, by: 15) {
            let elapsed = Duration.milliseconds(work)
            #expect(elapsed + LoopPacing.rest(period: period, elapsed: elapsed) == period)
        }
    }

    @Test("A tick that overran still yields the main actor")
    func overrunStillRests() {
        #expect(LoopPacing.rest(period: period, elapsed: .milliseconds(100)) == .milliseconds(10))
        #expect(LoopPacing.rest(period: period, elapsed: .milliseconds(260)) == .milliseconds(10))
        // Close to the period: the floor wins over a shorter remainder.
        #expect(LoopPacing.rest(period: period, elapsed: .milliseconds(95)) == .milliseconds(10))
    }

    @Test("The floor is the caller's to set, and never negative work shortens it")
    func customFloor() {
        #expect(LoopPacing.rest(period: period, elapsed: .milliseconds(99),
                                floor: .milliseconds(25)) == .milliseconds(25))
        #expect(LoopPacing.rest(period: period, elapsed: .milliseconds(20),
                                floor: .milliseconds(25)) == .milliseconds(80))
    }
}
