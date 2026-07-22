//
//  PracticeMode.swift
//  CoachKit
//
//  M6-01: the practice-modes FRAMEWORK (docs/roadmap/08-PRACTICE-MODES.md).
//  A mode is a named bundle of behavior flags the app layer honors; the
//  framework stays pure so mode semantics are testable everywhere. Drill
//  CONTENT (step sequences, ghost-ball targets) arrives with M6-03 and
//  plugs into `guidedDrill` without touching this contract.
//

import Foundation

/// What a practice mode turns on or off. The app layer reads these flags;
/// modes never reach into app state themselves.
public struct ModeConfiguration: Sendable, Equatable {
    /// Draw trajectory strips + ghost ball + the tip-contact guide card.
    public var showsShotGuides: Bool
    /// The HUD nudges the player to call a pocket before shooting, and
    /// "on line" status only lights for the CALLED pocket.
    public var requiresCalledPocket: Bool
    /// Reserved for M6-03: renders drill target markers (ghost-ball
    /// placement positions) on the cloth.
    public var showsDrillTargets: Bool

    public init(showsShotGuides: Bool,
                requiresCalledPocket: Bool,
                showsDrillTargets: Bool) {
        self.showsShotGuides = showsShotGuides
        self.requiresCalledPocket = requiresCalledPocket
        self.showsDrillTargets = showsDrillTargets
    }
}

/// The selectable practice modes (05-UX + 08-PRACTICE-MODES).
public enum PracticeMode: String, CaseIterable, Sendable, Codable {
    /// Everything on, nothing required — the default sandbox.
    case freePlay
    /// Competition discipline: call your pocket before every shot.
    case calledShots
    /// Guided drills (content lands in M6-03; the mode exists so the
    /// selection UI and persistence are stable from day one).
    case guidedDrill

    public var configuration: ModeConfiguration {
        switch self {
        case .freePlay:
            ModeConfiguration(showsShotGuides: true,
                              requiresCalledPocket: false,
                              showsDrillTargets: false)
        case .calledShots:
            ModeConfiguration(showsShotGuides: true,
                              requiresCalledPocket: true,
                              showsDrillTargets: false)
        case .guidedDrill:
            ModeConfiguration(showsShotGuides: true,
                              requiresCalledPocket: false,
                              showsDrillTargets: true)
        }
    }

    /// HUD label.
    public var title: String {
        switch self {
        case .freePlay: "Free play"
        case .calledShots: "Called shots"
        case .guidedDrill: "Guided drill"
        }
    }

    /// One-line HUD hint shown when the mode needs something from the
    /// player before guidance is complete; nil when nothing is pending.
    public func pendingHint(hasCalledPocket: Bool) -> String? {
        switch self {
        case .calledShots where !hasCalledPocket:
            "Call your pocket — tap one to commit"
        case .guidedDrill:
            "Drills arrive in a coming update — free practice until then"
        default:
            nil
        }
    }
}
