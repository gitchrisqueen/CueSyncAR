//
//  SpokenGuidance.swift
//  CoachKit
//
//  What the app says out loud, and — the part that actually matters —
//  when it says nothing.
//
//  Producing the words is easy: the HUD already has them. The hard problem
//  is that the pipeline recomputes the situation many times a second, and a
//  coach that says "aim a little left" sixty times a second is unusable.
//  So this type owns the silence rules, all of them, in one place:
//
//  * de-duplication — a line is said once per situation, and becomes
//    sayable again only when it stops being on offer and later returns;
//  * a minimum gap — nothing follows anything else immediately;
//  * priority — a state change ("blocked", "on line", "no cue ball")
//    interrupts a running aim nudge; a nudge never interrupts a state
//    change, it waits;
//  * hysteresis — once "on line" has been said, aim nudges stop entirely
//    until the aim leaves the deadband by a real margin. Without this the
//    voice chatters across the boundary while the player holds still.
//
//  It is pure and Linux-testable: no AVFoundation, no audio, and never
//  `Date()` — the caller supplies a monotonic timestamp, so every rule
//  above is exercised deterministically in tests rather than by standing
//  at a table with a stopwatch. The platform half (App/Sources/
//  SpeechNarrator.swift) only knows how to pronounce what this returns.
//
//  The copy is written to be HEARD, not read: no "%" (which a synthesizer
//  reads as a symbol), no em dashes, sentences that end. Where the HUD
//  already has a phrase for something, the spoken form carries the same
//  facts in the same order — `ShotRating.spokenLine` sits next to
//  `ShotRating.headline` on purpose, so the two cannot quietly diverge.
//

import CueSyncCore
import Foundation

// MARK: - Verbosity

/// How much the app says out loud.
///
/// "Tells me what to do next" and "narrates every degree of aim error" are
/// different products; this is where the player picks which one they want.
public enum SpeechVerbosity: String, Sendable, Equatable, CaseIterable, Codable {
    /// Silent. The default, always: a new build must never start talking
    /// at someone unannounced.
    case off
    /// Setup prompts and shot announcements only — what is expected next.
    case keyMoments
    /// The above plus continuous aim corrections while down on the shot.
    case coaching

    /// Picker label.
    public var title: String {
        switch self {
        case .off: "Off"
        case .keyMoments: "Key moments"
        case .coaching: "Coaching"
        }
    }

    /// One line of picker footer explaining what the level costs in noise.
    public var detail: String {
        switch self {
        case .off: "Nothing is spoken."
        case .keyMoments: "Setup prompts and the shot it offers you."
        case .coaching: "Also nudges your aim onto the line while you are down on the shot."
        }
    }

    /// Whether continuous aim corrections are spoken at this level.
    public var speaksNudges: Bool { self == .coaching }

    /// Whether anything at all is spoken.
    public var isOn: Bool { self != .off }
}

// MARK: - The situation being described

/// Where the session is, in the only terms the voice cares about.
///
/// A deliberate mirror of the HUD's status states rather than a second
/// vocabulary: the app maps its `HUDStatus` onto this so the voice says
/// what the screen says. Live tracking collapses to `.tracking` — "tracking
/// five balls" is a fine thing to show and a terrible thing to say aloud,
/// because the count changes constantly and carries no instruction.
public enum GuidanceStage: Sendable, Equatable {
    case starting
    case findingTable
    /// Waiting on the four playing-field corners; `placed` are already down.
    case placingCorners(placed: Int)
    case confirmingRails
    case needsCalibration
    /// Tracking runs but there is no cue ball, so nothing can be aimed.
    case awaitingCueBall
    case tracking
    case degraded(GuidanceTrouble)
}

/// Why tracking is degraded — the spoken half of the HUD's warning capsule.
public enum GuidanceTrouble: String, Sendable, Equatable, CaseIterable {
    case fastMotion
    case lowLight
    case trackingLost
}

/// How far the player's aim is from the shot on offer, and which way to
/// move.
///
/// A local restatement of `ARExperience.TargetGuide.Correction`, so CoachKit
/// stays free of ARKit and this whole file keeps building on Linux. The app
/// converts at the seam; the degree thresholds below match the ones the
/// on-screen advice already uses.
public enum AimNudge: Sendable, Equatable {
    case onLine
    case left(degrees: Double)
    case right(degrees: Double)

    /// Size of the error, in degrees. Zero when on line.
    public var degrees: Double {
        switch self {
        case .onLine: 0
        case .left(let degrees), .right(let degrees): degrees
        }
    }

    /// Which way the player moves, or nil when they are already on line.
    public var side: String? {
        switch self {
        case .onLine: nil
        case .left: "left"
        case .right: "right"
        }
    }
}

// MARK: - What comes out

/// One thing to say, ready to be pronounced.
public struct Utterance: Sendable, Equatable, Identifiable {
    /// What kind of thing this is, and therefore what it may interrupt.
    public enum Priority: Int, Sendable, Equatable, Comparable {
        /// A continuous aim correction. Cheap to miss, expensive to repeat.
        case nudge = 0
        /// A change of state the player has to know about.
        case moment = 1

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Identity of the *content*, not of the occasion: two utterances with
    /// the same id say the same thing about the same situation, which is
    /// exactly what the de-duplication rule keys on.
    public let id: String
    /// The words, as they should be heard.
    public let text: String
    public let priority: Priority

    public init(id: String, text: String, priority: Priority) {
        self.id = id
        self.text = text
        self.priority = priority
    }
}

// MARK: - The engine

/// Decides what to say next, and how often it is allowed to say anything.
///
/// Drive it by calling `next(for:at:)` as often as you like — once per
/// pipeline output is expected. It returns at most one utterance, and
/// usually nil.
public struct SpokenGuidance: Sendable, Equatable {

    /// The silence rules, as numbers.
    public struct Config: Sendable, Equatable {
        /// Shortest time between two announcements. A state change may
        /// still cut in earlier when a mere nudge is what came last.
        public var momentGap: TimeInterval = 1.5
        /// Shortest time between an aim nudge and ANY previous speech.
        /// Far larger than `momentGap`: a player down on the shot needs a
        /// quiet room, not a running commentary.
        public var nudgeGap: TimeInterval = 4
        /// How long before the *same* nudge may be said again. Moments are
        /// never repeated while they stand; a nudge is, because the player
        /// is actively trying to act on it and may have lost it.
        public var nudgeRepeat: TimeInterval = 6
        /// How far the aim must leave the deadband, in degrees, before
        /// nudges resume after "on line" has been said. Anything smaller
        /// and the voice chatters at the boundary while the player is
        /// holding as still as a human can.
        public var onLineHysteresisDegrees: Double = 3

        public init() {}
    }

    /// Everything the voice is allowed to know.
    public struct Situation: Sendable, Equatable {
        public var stage: GuidanceStage
        /// The shot on offer: the player's pick when they have one, else
        /// the app's suggestion (`ShotSelection.active`).
        public var shot: ShotRating?
        /// True when `shot` is the player's own choice.
        public var chosenByPlayer: Bool
        /// The live aim correction, when the player is aiming at all.
        public var nudge: AimNudge?

        public init(stage: GuidanceStage,
                    shot: ShotRating? = nil,
                    chosenByPlayer: Bool = false,
                    nudge: AimNudge? = nil) {
            self.stage = stage
            self.shot = shot
            self.chosenByPlayer = chosenByPlayer
            self.nudge = nudge
        }
    }

    /// Silent by default.
    public var verbosity: SpeechVerbosity
    public var config: Config

    /// When each currently-offered line was last said. Pruned every call to
    /// the lines still on offer, which is what makes "do not repeat while
    /// the situation is unchanged" mean exactly that: a line forgotten
    /// because it stopped being on offer is sayable again when it returns.
    private var spokenAt: [String: TimeInterval] = [:]
    private var lastSpokenAt: TimeInterval?
    private var lastPriority: Utterance.Priority?
    /// True between saying "on line" and the aim leaving the deadband.
    private var onLineAnnounced = false
    /// Which shot the above refers to; a different shot re-arms it.
    private var shotKey: String?

    public init(verbosity: SpeechVerbosity = .off, config: Config = Config()) {
        self.verbosity = verbosity
        self.config = config
    }

    /// The identity of the "on line" call, referenced by the hysteresis.
    static let onLineID = "aim.onLine"

    // MARK: Driving it

    /// The next thing to say, or nil to stay quiet.
    ///
    /// - Parameters:
    ///   - situation: the app's current state.
    ///   - now: a monotonic timestamp in seconds (system uptime, an
    ///     ARFrame timestamp, or a test's own counter). Never wall time:
    ///     the gaps below must survive a clock change mid-rack.
    public mutating func next(for situation: Situation, at now: TimeInterval) -> Utterance? {
        guard verbosity.isOn else {
            if lastSpokenAt != nil || !spokenAt.isEmpty { reset() }
            return nil
        }
        noteShotChange(in: situation)
        rearmOnLine(for: situation.nudge)

        let script = script(for: situation)
        forgetLinesNoLongerOffered(in: script)

        // The FIRST unsaid line wins or nothing does. Falling through to a
        // lower-priority line when the top one is merely rate-limited is
        // how a nudge would end up jumping the queue in front of a state
        // change that is waiting its turn.
        guard let next = script.first(where: { isUnsaid($0, at: now) }),
              clearToSpeak(next, at: now) else { return nil }

        spokenAt[next.id] = now
        lastSpokenAt = now
        lastPriority = next.priority
        if next.id == Self.onLineID { onLineAnnounced = true }
        return next
    }

    /// Forget everything said and every hold. Call when tracking stops, or
    /// when the player changes the verbosity — the new setting should not
    /// inherit the old one's silences.
    public mutating func reset() {
        spokenAt.removeAll()
        lastSpokenAt = nil
        lastPriority = nil
        onLineAnnounced = false
        shotKey = nil
    }

    /// Change the level, resetting the history when it actually changes.
    public mutating func update(verbosity newValue: SpeechVerbosity) {
        guard newValue != verbosity else { return }
        verbosity = newValue
        reset()
    }

    // MARK: Suppression

    /// Has this line already been said for the situation it belongs to?
    private func isUnsaid(_ utterance: Utterance, at now: TimeInterval) -> Bool {
        guard let said = spokenAt[utterance.id] else { return true }
        // Moments stand until they stop being offered. Nudges come round
        // again, because the player is mid-action on the last one.
        guard utterance.priority == .nudge else { return false }
        return now - said >= config.nudgeRepeat
    }

    /// The gap rule, including pre-emption.
    private func clearToSpeak(_ utterance: Utterance, at now: TimeInterval) -> Bool {
        guard let lastSpokenAt else { return true }
        let elapsed = now - lastSpokenAt
        switch utterance.priority {
        case .moment:
            // A state change cuts a nudge off; behind another state change
            // it queues like everything else.
            return lastPriority == .nudge || elapsed >= config.momentGap
        case .nudge:
            return elapsed >= config.nudgeGap
        }
    }

    private mutating func forgetLinesNoLongerOffered(in script: [Utterance]) {
        let offered = Set(script.map(\.id))
        spokenAt = spokenAt.filter { offered.contains($0.key) }
    }

    /// A different shot is a different conversation: the "on line" hold
    /// belongs to the shot it was said about.
    private mutating func noteShotChange(in situation: Situation) {
        let key = situation.shot.map { "\($0.ball.rawValue).\($0.pocket.rawValue)" } ?? "none"
        guard key != shotKey else { return }
        shotKey = key
        releaseOnLineHold()
    }

    /// Leave the deadband by a real margin and the nudges come back.
    private mutating func rearmOnLine(for nudge: AimNudge?) {
        guard let nudge, nudge.side != nil,
              nudge.degrees > config.onLineHysteresisDegrees else { return }
        releaseOnLineHold()
    }

    /// Both halves of re-arming: the hold that silences the nudges, AND
    /// the memory of having already said "on line". Clearing only the
    /// first leaves the call itself de-duplicated forever, so the player
    /// gets told once per session instead of once per shot.
    private mutating func releaseOnLineHold() {
        onLineAnnounced = false
        spokenAt.removeValue(forKey: Self.onLineID)
    }

    // MARK: Writing the lines

    /// Everything worth saying right now, most important first.
    private func script(for situation: Situation) -> [Utterance] {
        var lines: [Utterance] = []
        if let stage = Self.stageLine(situation.stage) { lines.append(stage) }
        if let shot = Self.shotLine(situation) { lines.append(shot) }
        if let onLine = onLineLine(situation) { lines.append(onLine) }
        if verbosity.speaksNudges, !onLineAnnounced,
           let nudge = Self.nudgeLine(situation) { lines.append(nudge) }
        return lines
    }

    /// What is expected next, when the app is not yet playing.
    private static func stageLine(_ stage: GuidanceStage) -> Utterance? {
        switch stage {
        case .starting, .tracking:
            // Nothing to ask for, and "tracking five balls" is a status,
            // not an instruction.
            return nil
        case .findingTable:
            return moment("stage.findingTable", "Point the camera at the table.")
        case .needsCalibration:
            return moment("stage.needsCalibration", "Tap anywhere to calibrate the table.")
        case .confirmingRails:
            return moment("stage.confirmingRails",
                          "Drag the dots onto the cushion noses, then lock it in.")
        case .awaitingCueBall:
            return moment("stage.awaitingCueBall",
                          "I cannot see the cue ball. Put it on the table, or tap a ball to mark it.")
        case .placingCorners(let placed):
            return cornersLine(placed: placed)
        case .degraded(let trouble):
            return troubleLine(trouble)
        }
    }

    private static func cornersLine(placed: Int) -> Utterance? {
        let remaining = 4 - placed
        guard remaining > 0, placed >= 0 else { return nil }
        let text = switch placed {
        case 0: "Tap the four corners of the playing surface, where the cushions meet."
        case 3: "One more corner."
        default: "\(remaining == 3 ? "Three" : "Two") more corners."
        }
        return moment("stage.corners.\(placed)", text)
    }

    private static func troubleLine(_ trouble: GuidanceTrouble) -> Utterance {
        let text = switch trouble {
        case .fastMotion: "Hold the camera steady."
        case .lowLight: "It is too dark to track. More light would help."
        case .trackingLost: "I have lost the table. Point back at it."
        }
        return moment("stage.degraded.\(trouble.rawValue)", text)
    }

    /// The shot on offer, said once per shot.
    private static func shotLine(_ situation: Situation) -> Utterance? {
        guard case .tracking = situation.stage, let shot = situation.shot else { return nil }
        let id = "shot.\(shot.ball.rawValue).\(shot.pocket.rawValue)"
            + ".\(Self.blockerKey(shot.blocker)).\(situation.chosenByPlayer)"
        return moment(id, shot.spokenLine(chosenByPlayer: situation.chosenByPlayer))
    }

    /// "On line" is a state change, not a nudge: it is the one thing the
    /// player is waiting to hear, and it ends the coaching for this shot.
    private func onLineLine(_ situation: Situation) -> Utterance? {
        guard case .tracking = situation.stage, situation.nudge == .onLine,
              let shot = situation.shot, shot.blocker == nil, !onLineAnnounced else { return nil }
        return Self.moment(Self.onLineID, "On line. Send it.")
    }

    /// Which way to move, in the same words and at the same threshold the
    /// on-screen advice uses (`TargetGuide.Correction.advice`).
    private static func nudgeLine(_ situation: Situation) -> Utterance? {
        guard case .tracking = situation.stage, let shot = situation.shot, shot.blocker == nil,
              let nudge = situation.nudge, let side = nudge.side else { return nil }
        let small = nudge.degrees < 5
        return Utterance(id: "aim.\(side).\(small ? "small" : "large")",
                         text: small ? "Aim a little \(side)." : "Aim \(side).",
                         priority: .nudge)
    }

    private static func moment(_ id: String, _ text: String) -> Utterance {
        Utterance(id: id, text: text, priority: .moment)
    }

    private static func blockerKey(_ blocker: ShotRating.Blocker?) -> String {
        switch blocker {
        case .none: "open"
        case .cuePath: "cuePath"
        case .objectPath: "objectPath"
        case .cutTooThin: "cutTooThin"
        case .pocketFacingAway: "pocketFacingAway"
        }
    }
}

// MARK: - Speakable copy

extension ShotRating {
    /// The spoken twin of `headline`: the same facts, in a form a
    /// synthesizer pronounces.
    ///
    /// Kept beside `headline` deliberately. The two must say the same
    /// thing — the voice reading out something the HUD does not show is a
    /// second, unmaintained vocabulary — and the only way to notice them
    /// drifting is to have them in one file. The differences are all
    /// pronunciation: "62 percent" rather than "62 %", full sentences
    /// rather than an em dash, and "past ninety degrees" rather than a
    /// degree sign.
    ///
    /// - Parameter chosenByPlayer: whether this is the player's own pick,
    ///   which changes the lead-in. A suggestion should never be read out
    ///   as though the player made it.
    public func spokenLine(chosenByPlayer: Bool) -> String {
        switch blocker {
        case .cuePath:
            return "That one is blocked. A ball is in the cue ball's way."
        case .objectPath:
            return "That one is blocked. A ball is between it and the pocket."
        case .cutTooThin:
            return "No angle there. That cut is past ninety degrees."
        case .pocketFacingAway:
            return "No angle there. It would cross the pocket mouth."
        case nil:
            let lead = chosenByPlayer ? "Your ball" : "Best shot"
            return "\(lead), \(percentage) percent into the \(pocket.spokenName)."
        }
    }
}
