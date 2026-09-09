//
//  HUDMessage.swift
//  CueSyncUI
//
//  One toast, not a log. The top of the HUD used to stack up to eight
//  independent capsules — status, recording, camera-denied, AR session
//  event, detector error, tap feedback, mirror URL, practice hint — in
//  five colours with no order between them, so on a bad frame the status
//  capsule (the one line that tells the player what to do) was pushed down
//  the screen by four diagnostics.
//
//  The fix is a priority, and a priority is a pure function: which single
//  transient message deserves the slot right now. Kept here, next to
//  HUDStatus, so it is decided (and tested) on Linux rather than argued
//  about inside a view builder.
//

import Foundation

/// A transient, self-dismissing line under the status capsule.
///
/// Exactly one is shown at a time. `Kind` is the priority order, highest
/// first, and it is the whole design: a message only appears when nothing
/// more important is already speaking.
public struct HUDMessage: Sendable, Equatable {
    /// What kind of message this is — and, by its declaration order, how
    /// it ranks against the others.
    ///
    /// The order is argued rather than arbitrary:
    /// 1. `cameraDenied` — the app cannot work at all; nothing else matters.
    /// 2. `calibrationError` — the user just acted and the action failed.
    /// 3. `tapFeedback` — the user just acted and something happened.
    /// 4. `modeHint` — standing advice, true for minutes at a time.
    public enum Kind: Int, Sendable, Comparable, CaseIterable {
        case cameraDenied
        case calibrationError
        case tapFeedback
        case modeHint

        public static func < (lhs: Kind, rhs: Kind) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// How loudly the message should read. Views map these onto colours;
    /// the mapping of *meaning* to tone lives here so it is consistent.
    public enum Tone: Sendable, Equatable {
        /// Something is broken and the player has to act (red).
        case critical
        /// Standing advice — true, useful, not urgent (yellow).
        case advisory
        /// An acknowledgement of what just happened (primary).
        case neutral
    }

    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }

    public var tone: Tone {
        switch kind {
        case .cameraDenied, .calibrationError: .critical
        case .modeHint: .advisory
        case .tapFeedback: .neutral
        }
    }

    /// The copy for a denied camera, in one place: the app's only truly
    /// terminal state, and the one message that must not be paraphrased
    /// differently in two views.
    public static let cameraDenied = HUDMessage(
        kind: .cameraDenied,
        text: "Camera access denied — enable it in Settings → CueSync AR")

    /// The single message that gets the toast slot, or nil when the player
    /// has nothing to be told.
    ///
    /// Ties cannot happen — each kind is contributed at most once — but the
    /// resolution is deliberately order-independent all the same, so the
    /// caller's argument order can never change what a player sees.
    public static func highestPriority(among candidates: [HUDMessage?]) -> HUDMessage? {
        candidates.compactMap { $0 }.min { $0.kind < $1.kind }
    }

    /// Convenience over the four transient fields RootView actually holds.
    /// Empty strings are treated as absent — a blank capsule is a bug that
    /// looks like a rendering glitch.
    public static func resolve(cameraDenied: Bool,
                               calibrationError: String? = nil,
                               tapFeedback: String? = nil,
                               modeHint: String? = nil) -> HUDMessage? {
        highestPriority(among: [
            cameraDenied ? Self.cameraDenied : nil,
            Self.message(.calibrationError, calibrationError),
            Self.message(.tapFeedback, tapFeedback),
            Self.message(.modeHint, modeHint)
        ])
    }

    private static func message(_ kind: Kind, _ text: String?) -> HUDMessage? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return HUDMessage(kind: kind, text: text)
    }
}

#if canImport(SwiftUI)
import SwiftUI

/// The one transient line under the status capsule. Same geometry as
/// `StatusCapsule` so the two read as one stack rather than two designs.
public struct HUDToast: View {
    public let message: HUDMessage

    public init(message: HUDMessage) {
        self.message = message
    }

    public var body: some View {
        Text(message.text)
            .font(.caption)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(Self.color(for: message.tone))
            .transition(.opacity)
            .accessibilityIdentifier("hud-toast")
    }

    static func color(for tone: HUDMessage.Tone) -> Color {
        switch tone {
        case .critical: .red
        case .advisory: .yellow
        case .neutral: .primary
        }
    }
}
#endif
