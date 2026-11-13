//
//  FeedbackEvent.swift
//  CoachKit
//
//  The arcade "feel" layer, as data. Every moment the app wants to react to
//  is a `FeedbackEvent`; `FeedbackPlan` says what each one looks, sounds and
//  feels like. Nothing here touches UIKit or AVFoundation: the app's
//  FeedbackCenter plays the plan, and this file is what keeps the plan
//  testable on Linux (and keeps a remote tester able to read it from the
//  mirror's /logs, where every event is written by name).
//
//  Two rules live in the data rather than in the player:
//  - an event that is not important is quiet (no haptic) so a stream of small
//    changes never buzzes the player's hand;
//  - spoken lines are only the ones SpokenGuidance does not already say.
//

import Foundation

/// A moment worth reacting to.
public enum FeedbackEvent: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    case tableLocked
    case calibrationRefused
    /// Tracking found its first balls after having none.
    case ballsFound
    /// The settled ball count changed (after the debounce in `FeedbackWatcher`).
    case ballCountChanged
    /// The player tapped a ball to shoot at.
    case shotSelected
    /// The app's own suggestion moved to a different ball or pocket.
    case shotChanged
    /// The advised ball went into the advised pocket.
    case shotMade
    /// Some other ball went down (or the advised ball, in another pocket).
    case shotMadeOther
    case shotMissed
    /// The cue ball was pocketed.
    case scratch
    case trackingLost
    case trackingRecovered
    case noCleanShot
    case recordingStarted
    case recordingStopped
}

/// A haptic, named for what the player should feel rather than for the UIKit
/// generator that makes it. `none` means silent to the hand.
public enum HapticStyle: String, Sendable, Equatable, CaseIterable {
    case none
    case selection
    case light
    case medium
    case rigid
    case success
    case warning
    case error
}

/// A synthesised sound (`ToneSynth`); `none` means no sound.
public enum SoundID: String, Sendable, Equatable, CaseIterable {
    case none
    case lock
    case made
    case miss
    case select
    case error
}

/// How loudly a banner reads. Views map tones onto the text-grade colours.
public enum BannerTone: String, Sendable, Equatable, CaseIterable {
    case good
    case neutral
    case caution
    case bad
}

/// How much an event matters: important events always get through the rate
/// limit's "quiet after" window and are announced to VoiceOver.
public enum FeedbackPriority: Int, Sendable, Equatable, Comparable {
    case ambient = 0
    case normal = 1
    case important = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Where an event's words are drawn. Words are always announced to
/// VoiceOver; this says what a sighted player sees.
public enum BannerPlacement: String, Sendable, Equatable, CaseIterable {
    /// A small pill under the shot card.
    case pill
    /// Takes the shot card's own slot for a moment (a made shot, a miss,
    /// a scratch), so nothing stacks under the card.
    case cardSlot
    /// Nothing: something else on screen already says it. The status
    /// capsule carries tracking lost, the shot card says "Your pick",
    /// the empty-shot card says "No clean shot".
    case none
}

/// What one event does.
public struct FeedbackEntry: Sendable, Equatable {
    public var haptic: HapticStyle
    public var sound: SoundID
    /// The banner line, nil for an event that is only felt or heard.
    public var banner: String?
    public var tone: BannerTone
    /// SF Symbol for the banner.
    public var symbol: String
    /// Say the banner out loud when voice guidance is on. Only for lines
    /// `SpokenGuidance` does not already say.
    public var speak: Bool
    /// Post to VoiceOver (`UIAccessibility.post(.announcement)`).
    public var announce: Bool
    /// The same event is dropped again within this many seconds.
    public var cooldown: TimeInterval
    /// How long the banner stays.
    public var bannerDuration: TimeInterval
    public var priority: FeedbackPriority
    /// Where a sighted player sees the words. Defaults to a pill.
    public var placement: BannerPlacement = .pill
}

public enum FeedbackPlan {

    /// The entry for `event`. A total function: adding an event without an
    /// entry does not compile, and the test walks `allCases` anyway.
    public static func entry(for event: FeedbackEvent) -> FeedbackEntry {
        switch event {
        case .tableLocked:
            FeedbackEntry(haptic: .success, sound: .lock, banner: "Table locked",
                          tone: .good, symbol: "checkmark.circle.fill", speak: false,
                          announce: true, cooldown: 3, bannerDuration: 2.2, priority: .important)
        case .calibrationRefused:
            FeedbackEntry(haptic: .error, sound: .error, banner: "Couldn't lock the table",
                          tone: .bad, symbol: "exclamationmark.triangle.fill", speak: false,
                          announce: false, cooldown: 2, bannerDuration: 2.5, priority: .important)
        case .ballsFound:
            FeedbackEntry(haptic: .light, sound: .select, banner: "Balls found",
                          tone: .good, symbol: "circle.grid.3x3.fill", speak: false,
                          announce: false, cooldown: 6, bannerDuration: 1.6, priority: .normal)
        case .ballCountChanged:
            FeedbackEntry(haptic: .none, sound: .none, banner: "Now tracking",
                          tone: .neutral, symbol: "circle.grid.3x3", speak: false,
                          announce: false, cooldown: 4, bannerDuration: 1.4, priority: .ambient,
                          placement: .none)
        case .shotSelected:
            FeedbackEntry(haptic: .selection, sound: .select, banner: "Shot selected",
                          tone: .neutral, symbol: "scope", speak: false,
                          announce: false, cooldown: 0.4, bannerDuration: 1.4, priority: .normal,
                          placement: .none)
        case .shotChanged:
            FeedbackEntry(haptic: .none, sound: .none, banner: nil,
                          tone: .neutral, symbol: "scope", speak: false,
                          announce: false, cooldown: 2, bannerDuration: 0, priority: .ambient)
        case .shotMade:
            FeedbackEntry(haptic: .success, sound: .made, banner: "Made it",
                          tone: .good, symbol: "checkmark.circle.fill", speak: true,
                          announce: true, cooldown: 1.5, bannerDuration: 2.4, priority: .important,
                          placement: .cardSlot)
        case .shotMadeOther:
            FeedbackEntry(haptic: .success, sound: .made, banner: "Ball down",
                          tone: .good, symbol: "checkmark.circle", speak: true,
                          announce: true, cooldown: 1.5, bannerDuration: 2.4, priority: .important,
                          placement: .cardSlot)
        case .shotMissed:
            FeedbackEntry(haptic: .warning, sound: .miss, banner: "Missed. Line it up again",
                          tone: .caution, symbol: "arrow.uturn.left.circle", speak: true,
                          announce: true, cooldown: 1.5, bannerDuration: 2.4, priority: .important,
                          placement: .cardSlot)
        case .scratch:
            FeedbackEntry(haptic: .error, sound: .miss, banner: "Scratch",
                          tone: .bad, symbol: "exclamationmark.circle.fill", speak: true,
                          announce: true, cooldown: 1.5, bannerDuration: 2.4, priority: .important,
                          placement: .cardSlot)
        case .trackingLost:
            FeedbackEntry(haptic: .warning, sound: .error, banner: "Lost the table",
                          tone: .bad, symbol: "exclamationmark.triangle.fill", speak: false,
                          announce: true, cooldown: 5, bannerDuration: 2.2, priority: .important,
                          placement: .none)
        case .trackingRecovered:
            FeedbackEntry(haptic: .light, sound: .select, banner: "Tracking again",
                          tone: .good, symbol: "checkmark.circle", speak: false,
                          announce: false, cooldown: 5, bannerDuration: 1.6, priority: .normal)
        case .noCleanShot:
            FeedbackEntry(haptic: .none, sound: .none, banner: "No clean shot. Pick a ball to try",
                          tone: .caution, symbol: "scope", speak: false,
                          announce: false, cooldown: 8, bannerDuration: 2.2, priority: .normal,
                          placement: .none)
        case .recordingStarted:
            FeedbackEntry(haptic: .medium, sound: .select, banner: "Recording",
                          tone: .neutral, symbol: "record.circle", speak: false,
                          announce: false, cooldown: 1, bannerDuration: 1.6, priority: .normal)
        case .recordingStopped:
            FeedbackEntry(haptic: .light, sound: .select, banner: "Recording saved",
                          tone: .neutral, symbol: "stop.circle", speak: false,
                          announce: false, cooldown: 1, bannerDuration: 1.8, priority: .normal)
        }
    }

    /// The banner line for `event`, with `detail` folded in where it helps
    /// ("Made it: blue ball"). A refusal's detail is only the log's: the
    /// calibration overlay already words the reason beside the Lock button.
    public static func bannerText(for event: FeedbackEvent, detail: String?) -> String? {
        guard let base = entry(for: event).banner else { return nil }
        guard let detail, !detail.trimmingCharacters(in: .whitespaces).isEmpty else { return base }
        switch event {
        case .tableLocked, .shotMade, .shotMadeOther, .ballCountChanged, .ballsFound:
            return "\(base): \(detail)"
        default:
            return base
        }
    }
}

/// One line of the feedback log: what fired, or why it did not.
public struct FeedbackRecord: Sendable, Equatable {
    public var event: FeedbackEvent
    public var time: TimeInterval
    public var detail: String?
    /// nil when it played; else why not ("cooldown", "quiet").
    public var suppressed: String?
    public var haptic: HapticStyle
    public var sound: SoundID
    public var banner: String?

    public init(event: FeedbackEvent, time: TimeInterval, detail: String? = nil,
                suppressed: String? = nil, haptic: HapticStyle, sound: SoundID,
                banner: String?) {
        self.event = event
        self.time = time
        self.detail = detail
        self.suppressed = suppressed
        self.haptic = haptic
        self.sound = sound
        self.banner = banner
    }

    /// The `/logs` line: `feedback: shotMade haptic=success sound=made`.
    public var logLine: String {
        var line = "feedback: \(event.rawValue)"
        if let suppressed { return line + " suppressed=\(suppressed)" }
        line += " haptic=\(haptic.rawValue) sound=\(sound.rawValue)"
        if let banner { line += " banner=\"\(banner)\"" }
        if let detail { line += " detail=\"\(detail)\"" }
        return line
    }
}

/// A bounded history of records, newest last, for the mirror's state.json.
public struct FeedbackLog: Sendable, Equatable {
    public static let capacity = 20
    public private(set) var records: [FeedbackRecord] = []

    public init() {}

    public mutating func append(_ record: FeedbackRecord) {
        records.append(record)
        if records.count > Self.capacity { records.removeFirst(records.count - Self.capacity) }
    }
}

/// Rate limit and de-duplication for the arcade layer.
///
/// Two rules, both visible in the plan's data:
/// 1. an event is dropped again within its own `cooldown`;
/// 2. for `quietAfterImportant` seconds after an important event, anything
///    less important is dropped, so a made shot is not immediately followed
///    by "ball count changed" and a tick.
public struct FeedbackThrottle: Sendable, Equatable {
    public var quietAfterImportant: TimeInterval = 2.5
    private var lastFired: [FeedbackEvent: TimeInterval] = [:]
    private var lastImportantAt: TimeInterval?

    public init(quietAfterImportant: TimeInterval = 2.5) {
        self.quietAfterImportant = quietAfterImportant
    }

    public enum Verdict: Sendable, Equatable {
        case admit
        case cooldown
        case quiet
    }

    /// Decide, and when admitted remember it. `now` is monotonic seconds.
    public mutating func admit(_ event: FeedbackEvent, at now: TimeInterval) -> Verdict {
        let entry = FeedbackPlan.entry(for: event)
        if let last = lastFired[event], now - last < entry.cooldown { return .cooldown }
        if entry.priority < .important, let important = lastImportantAt,
           now - important < quietAfterImportant {
            return .quiet
        }
        lastFired[event] = now
        if entry.priority == .important { lastImportantAt = now }
        return .admit
    }

    public mutating func reset() {
        lastFired = [:]
        lastImportantAt = nil
    }
}
