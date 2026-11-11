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
//  Off by default in every build, Debug included: a Debug build that
//  unlocked itself looked unfinished to anyone who ran it. It unlocks by
//  the seven-tap idiom on the version row (the same gesture iOS itself
//  trained everyone on), which is remembered so the owner unlocks once per
//  install, or by the launch argument `-developerModeUnlocked YES`
//  (Scripts/device-push.sh --dev, UI tests). Only the labels and controls
//  are gated: the debug mirror server runs in Debug builds regardless.
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
        // An answer in UserDefaults (persisted, or `-developerModeUnlocked
        // YES|NO` on the launch line, which UserDefaults surfaces under the
        // same key) decides; with none, it is off.
        let stored: Bool? = store.object(forKey: Self.storageKey) == nil
            ? nil : store.bool(forKey: Self.storageKey)
        isUnlocked = DeveloperUnlock.initialState(stored: stored)
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
