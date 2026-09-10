//
//  DeveloperUnlockTests.swift
//  CueSync AR
//

import Testing
@testable import CueSyncUI

@Suite("Developer unlock")
struct DeveloperUnlockTests {

    @Test("Seven taps in a run unlock, and six do not")
    func sevenTapsUnlock() {
        var unlock = DeveloperUnlock()
        for tap in 1..<DeveloperUnlock.tapsRequired {
            let unlocked = unlock.tap(at: Double(tap) * 0.2)
            #expect(!unlocked, "tap \(tap) should not unlock")
        }
        let seventh = unlock.tap(at: 1.4)
        #expect(seventh)
    }

    @Test("A long pause starts the run over")
    func pauseResetsTheRun() {
        var unlock = DeveloperUnlock()
        for tap in 1..<DeveloperUnlock.tapsRequired {
            _ = unlock.tap(at: Double(tap) * 0.2)
        }
        // Six in the bank, then a pause longer than the timeout. The
        // seventh tap must NOT unlock — otherwise stray taps spread over a
        // session eventually add up on their own.
        let afterPause = unlock.tap(at: 1.2 + DeveloperUnlock.runTimeout + 0.1)
        #expect(!afterPause)
    }

    @Test("The run can be completed after a reset")
    func canUnlockAfterAReset() {
        var unlock = DeveloperUnlock()
        _ = unlock.tap(at: 0)
        _ = unlock.tap(at: 100)          // reset; this is run-tap 1
        for tap in 2...6 { _ = unlock.tap(at: 100 + Double(tap) * 0.2) }
        let completed = unlock.tap(at: 101.6)
        #expect(completed)
    }

    @Test("It stays quiet until the user is nearly there")
    func hintAppearsLate() {
        var unlock = DeveloperUnlock()
        _ = unlock.tap(at: 0.0)
        #expect(unlock.hint == nil)      // 6 remaining
        _ = unlock.tap(at: 0.2)
        _ = unlock.tap(at: 0.4)
        #expect(unlock.hint == nil)      // 4 remaining
        _ = unlock.tap(at: 0.6)
        #expect(unlock.hint == "3 more taps for developer options")
        _ = unlock.tap(at: 0.8)
        _ = unlock.tap(at: 1.0)
        #expect(unlock.hint == "1 more tap for developer options")
    }

    @Test("Unlocking twice needs a fresh run each time")
    func unlockingIsNotSticky() {
        var unlock = DeveloperUnlock()
        for tap in 1...7 { _ = unlock.tap(at: Double(tap) * 0.2) }
        // The counter reset on unlock, so one more tap is tap 1 of a new
        // run, not an eighth that unlocks again.
        let eighth = unlock.tap(at: 1.6)
        #expect(!eighth)
    }
}
