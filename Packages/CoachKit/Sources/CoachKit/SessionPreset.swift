//
//  SessionPreset.swift
//  CueSync AR
//
//  What kind of session this is — which is really a question about where
//  the phone is and who the overlay is for.
//
//  The competitive research is blunt about this: a player cannot hold a
//  phone and shoot, so every shipping CV sports app mounts the device, and
//  the three ways to use this app differ mainly by where it sits and who
//  is looking. That makes the preset the FIRST decision rather than the
//  sixth icon in a bar.
//
//  It also does one thing the practice modes cannot. `PracticeMode` is a
//  bundle of behaviour flags — and all three of its flags have been read by
//  nothing outside their own file since July, because every mode set
//  `showsShotGuides: true` and there was never a reason to check. A preset
//  that turns the guides OFF gives them their first real consumer, and it
//  is the same preset that makes the app usable where aiming aids are not.
//

import Foundation

/// How this session is being played.
public enum SessionPreset: String, CaseIterable, Sendable, Codable {

    /// Practising alone. Everything on; the phone is usually propped.
    case solo
    /// A game with someone. **Guides off, scoring only** — the owner's
    /// ruling, and the same posture that makes the app legal to have on the
    /// table in sanctioned play, where CSI 1-3-1-f, 1-3-2 and 1-41 and the
    /// APA training-aid ban all prohibit an aiming aid. Naming that
    /// constraint costs nothing when there is a mode that satisfies it.
    case withFriends
    /// Spectators watching on a TV; the phone is a camera on a tripod.
    case tv

    public var title: String {
        switch self {
        case .solo: "Solo practice"
        case .withFriends: "Game — guides off"
        case .tv: "TV / spectators"
        }
    }

    /// One line under the title, saying what changes.
    public var detail: String {
        switch self {
        case .solo:
            "Aim lines, ghost ball and shot ranking. Prop the phone where it can see the whole table."
        case .withFriends:
            "No aim lines. The app keeps score and stays out of the game — and this is the mode to use where aiming aids are not allowed."
        case .tv:
            "A clean table view for the room. Put the phone on a tripod and leave it."
        }
    }

    /// The practice mode this preset selects.
    public var practiceMode: PracticeMode {
        switch self {
        case .solo: .freePlay
        case .withFriends: .calledShots
        case .tv: .freePlay
        }
    }

    /// Whether the phone is expected to be parked rather than held. It
    /// disables the device-pose aim source, which from a tripod is a fixed
    /// line to wherever the mount happens to face.
    public var deviceParked: Bool {
        switch self {
        case .solo: false
        case .withFriends, .tv: true
        }
    }

    /// Whether this preset wants a second scene on an external display.
    public var wantsExternalScene: Bool { self == .tv }

    /// What the overlay actually does. Derived from the practice mode, with
    /// the guides forced off for a game — which is the one place a preset
    /// overrides its mode rather than merely selecting it.
    public var configuration: ModeConfiguration {
        var configuration = practiceMode.configuration
        if self == .withFriends { configuration.showsShotGuides = false }
        return configuration
    }
}
