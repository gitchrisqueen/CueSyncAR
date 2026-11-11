//
//  DeveloperUnlock.swift
//  CueSync AR
//
//  The "tap the version row seven times" gesture, as a value.
//
//  It is here rather than in the view because the interesting part is a
//  rule — how many taps, how long a pause is allowed to break the run —
//  and a rule with a clock in it is exactly the kind of thing that is
//  easy to get subtly wrong and impossible to check by hand.
//

import Foundation

/// Counts taps toward unlocking the developer surfaces.
public struct DeveloperUnlock: Sendable, Equatable {

    /// Taps needed. Seven is the idiom users already know from iOS.
    public static let tapsRequired = 7
    /// A pause longer than this starts the count over, so idle taps
    /// scattered across a session never add up to an unlock.
    public static let runTimeout: TimeInterval = 2.0

    private var count = 0
    private var lastTapAt: TimeInterval?

    public init() {}

    /// Whether the developer surfaces are showing at launch.
    ///
    /// A development build is a developer build, so with nothing stored it
    /// starts unlocked: the remote table loop identifies builds by the
    /// badge. An explicit stored answer always wins, in either kind of
    /// build, which is what lets a debug build be viewed the way a player
    /// sees it (`-developerModeUnlocked NO` on the launch line, or
    /// "Hide developer options" in Settings). A release build starts
    /// locked unless the owner unlocked it before.
    ///
    /// - Parameters:
    ///   - stored: the persisted answer, nil when none has been stored.
    ///   - isDebugBuild: true for a development build.
    public static func initialState(stored: Bool?, isDebugBuild: Bool) -> Bool {
        stored ?? isDebugBuild
    }

    /// Taps still needed, once the current run is taken into account.
    /// Zero means the next tap unlocks; nil means it just did.
    public private(set) var remaining: Int?

    /// Register a tap at `now` (monotonic seconds). Returns true when this
    /// tap completes the run.
    public mutating func tap(at now: TimeInterval) -> Bool {
        if let last = lastTapAt, now - last > Self.runTimeout { count = 0 }
        lastTapAt = now
        count += 1
        if count >= Self.tapsRequired {
            count = 0
            remaining = nil
            return true
        }
        remaining = Self.tapsRequired - count
        return false
    }

    /// Whether to tell the user anything yet. Silent for the first few, so
    /// the gesture stays out of the way of someone who is not looking for
    /// it — and then counts down, so someone who is knows it is working.
    public var hint: String? {
        guard let remaining, remaining <= 3 else { return nil }
        return remaining == 1
            ? "1 more tap for developer options"
            : "\(remaining) more taps for developer options"
    }
}
