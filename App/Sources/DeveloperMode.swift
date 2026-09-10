//
//  DeveloperMode.swift
//  CueSync AR
//
//  Whether the developer surfaces are visible.
//
//  Roughly thirteen of the twenty-two Settings rows are instruments, not
//  settings: a detector picker, a CPU pin, a millisecond latency readout,
//  a box-rotation nudge, the mirror switch and its address. Add the git
//  SHA sitting permanently on the play screen, and a shipping build was
//  showing a stranger more of the workshop than the product.
//
//  Development builds are developer builds, so nothing changes there. A
//  Release build hides all of it behind the seven-tap idiom on the version
//  row — the same gesture iOS itself trained everyone on — and remembers
//  the answer, so the owner unlocks once per install rather than once per
//  launch.
//

import CueSyncUI
import Foundation
import Observation

@MainActor
@Observable
final class DeveloperMode {

    /// One per process. The surfaces this gates are scattered across
    /// several views that do not otherwise share state.
    static let shared = DeveloperMode()

    private static let storageKey = "developerModeUnlocked"

    private(set) var isUnlocked: Bool
    /// The countdown shown while someone is tapping, or nil.
    private(set) var hint: String?

    @ObservationIgnored private var unlock = DeveloperUnlock()
    @ObservationIgnored private let store: UserDefaults
    @ObservationIgnored var clock: () -> TimeInterval = {
        ProcessInfo.processInfo.systemUptime
    }

    init(store: UserDefaults = .standard) {
        self.store = store
        #if DEBUG
        // A development build IS a developer build. Gating it would only
        // mean tapping seven times before every debugging session, and the
        // remote table loop would lose the build badge it identifies
        // builds by.
        isUnlocked = true
        #else
        isUnlocked = store.bool(forKey: Self.storageKey)
        #endif
    }

    /// Called when the version row is tapped.
    func noteVersionTap() {
        guard !isUnlocked else { return }
        if unlock.tap(at: clock()) {
            isUnlocked = true
            hint = "Developer options unlocked"
            store.set(true, forKey: Self.storageKey)
        } else {
            hint = unlock.hint
        }
    }

    /// Put it away again. Worth having: an owner who unlocked once should
    /// be able to hand the phone to someone without reinstalling.
    func lock() {
        isUnlocked = false
        hint = nil
        unlock = DeveloperUnlock()
        store.set(false, forKey: Self.storageKey)
    }
}
