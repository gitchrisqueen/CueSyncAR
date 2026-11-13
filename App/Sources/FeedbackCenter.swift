//
//  FeedbackCenter.swift
//  CueSync AR
//
//  The arcade feel, played. It consumes `FeedbackEvent`s (CoachKit) and, for
//  each one that gets past the throttle, does what `FeedbackPlan` says: a
//  haptic, a sound, a banner, an optional spoken line, a VoiceOver
//  announcement. Every event, including the ones the throttle dropped, is
//  written to the `feedback` log category, so a tester with no device in
//  hand reads what was asked of the phone from the debug mirror's /logs:
//
//      feedback: shotMade haptic=success sound=made banner="Made it: blue ball"
//
//  The decisions (what, when, how often) are CoachKit's and tested on Linux.
//  The wiring from the session model is SessionModel+Feedback.swift.
//

import CoachKit
import CueSyncCore
import CueSyncUI
import Foundation
import Observation
import os
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
final class FeedbackCenter {
    static let log = Logger(subsystem: "com.cuesync.ar", category: "feedback")
    /// Where the scoreboard survives a relaunch.
    private static let scoreKey = "sessionScore"

    /// The transient capsule under the status capsule.
    struct Banner: Equatable, Identifiable {
        let id: Int
        let text: String
        let tone: BannerTone
        let symbol: String
    }

    /// What the player allows. Passed in per event rather than held, so the
    /// settings stay the one source of truth.
    struct Prefs {
        var sounds: Bool
        var haptics: Bool
        /// Fold the score into a payoff ("+1 · 3 of 3") instead of a chip.
        var scoreboard = false
    }

    // MARK: Observed by the views

    private(set) var banner: Banner?
    /// A made shot, a miss or a scratch, while it holds the shot card's slot
    /// (CueSyncUI.PayoffEvent). Nil the rest of the time.
    private(set) var payoff: PayoffEvent?
    /// Bumped on each table lock and made ball; the views animate on change.
    private(set) var lockFlashCount = 0
    private(set) var madePulseCount = 0
    private(set) var lastMadePocket: PocketID?
    private(set) var score: SessionScore

    // MARK: Not observed

    @ObservationIgnored private(set) var records = FeedbackLog()
    @ObservationIgnored private var throttle = FeedbackThrottle()
    @ObservationIgnored private var watcher = FeedbackWatcher()
    @ObservationIgnored var detector = ShotOutcomeDetector()
    /// The advised ball's name, remembered while it is still on the table:
    /// once it is pocketed there is nothing left to ask.
    @ObservationIgnored var advisedName: (id: BallID, name: String)?
    @ObservationIgnored private(set) var lastFedTimestamp: TimeInterval?
    @ObservationIgnored private let haptics = FeedbackHaptics()
    @ObservationIgnored private let sounds = FeedbackSounds()
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var payoffTask: Task<Void, Never>?
    @ObservationIgnored private var samplingTask: Task<Void, Never>?
    @ObservationIgnored private var nextBannerID = 0
    /// Keeps a banner up at least this long. Set only by the Simulator's
    /// mirror command, so a screenshot that takes seconds still catches it.
    @ObservationIgnored var bannerHoldOverride: TimeInterval?

    init() {
        score = SessionScore.decoded(from: UserDefaults.standard.data(forKey: Self.scoreKey))
    }

    // MARK: Playing

    /// Play one event, unless the throttle says it is too soon.
    ///
    /// - Parameters:
    ///   - now: monotonic seconds (the session clock).
    ///   - speak: says a line out loud; nil when voice guidance is off.
    ///   - voiceBusy: the narrator is mid-sentence, so the audio session
    ///     must not be re-categorised under it.
    ///   - force: skip the throttle (the simulator's mirror command, so a
    ///     tester can fire the same event twice in a row).
    func post(_ event: FeedbackEvent, detail: String? = nil, now: TimeInterval,
              prefs: Prefs, speak: ((String) -> Void)?, voiceBusy: Bool, force: Bool = false) {
        let entry = FeedbackPlan.entry(for: event)
        let text = FeedbackPlan.bannerText(for: event, detail: detail)
        let verdict = throttle.admit(event, at: now)
        guard verdict == .admit || force else {
            let reason = verdict == .cooldown ? "cooldown" : "quiet"
            record(FeedbackRecord(event: event, time: now, detail: detail, suppressed: reason,
                                  haptic: entry.haptic, sound: entry.sound, banner: text))
            return
        }

        let haptic = prefs.haptics ? entry.haptic : .none
        let sound = prefs.sounds ? entry.sound : .none
        record(FeedbackRecord(event: event, time: now, detail: detail, haptic: haptic, sound: sound,
                              banner: text))

        haptics.play(haptic)
        sounds.play(sound, voiceActive: voiceBusy)

        switch event {
        case .tableLocked: lockFlashCount += 1
        case .shotMade, .shotMadeOther: madePulseCount += 1
        default: break
        }

        guard let text else { return }
        // Where a sighted player sees it: a pill, the shot card's slot, or
        // nowhere because something else on screen already says it. It is
        // announced and spoken either way.
        switch entry.placement {
        case .pill:
            show(Banner(id: nextBannerID, text: text, tone: entry.tone, symbol: entry.symbol),
                 for: entry.bannerDuration)
        case .cardSlot:
            showPayoff(for: event, showsScore: prefs.scoreboard)
        case .none:
            break
        }
        if entry.announce {
            #if canImport(UIKit)
            UIAccessibility.post(notification: .announcement, argument: text)
            #endif
        }
        if entry.speak, let speak {
            speak(text.replacingOccurrences(of: ": ", with: ", "))
        }
    }

    private func record(_ record: FeedbackRecord) {
        records.append(record)
        Self.log.notice("\(record.logLine, privacy: .public)")
    }

    /// Put a payoff in the card's slot for `PayoffTiming.holdSeconds`.
    private func showPayoff(for event: FeedbackEvent, showsScore: Bool) {
        let kind: PayoffEvent.Kind
        switch event {
        case .shotMade: kind = .made
        case .shotMadeOther: kind = .madeOther
        case .shotMissed: kind = .missed
        case .scratch: kind = .scratch
        default: return
        }
        nextBannerID += 1
        payoff = PayoffEvent(id: nextBannerID, kind: kind, streak: score.streak,
                             made: score.made, attempted: score.attempted,
                             showsScore: showsScore)
        payoffTask?.cancel()
        let hold = max(PayoffTiming.holdSeconds(for: kind), bannerHoldOverride ?? 0)
        payoffTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(hold))
            guard !Task.isCancelled else { return }
            self?.payoff = nil
        }
    }

    private func show(_ next: Banner, for duration: TimeInterval) {
        nextBannerID += 1
        banner = next
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(duration, self?.bannerHoldOverride ?? 0)))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    /// Wake the haptics and the sound engine ahead of a moment that is
    /// about to need them (a shot has just been struck).
    func warm(voiceBusy: Bool) {
        haptics.prepare()
        sounds.prewarm(voiceActive: voiceBusy)
    }

    /// The Settings preview: proof of life when sounds are switched on.
    func previewSound(_ sound: SoundID, voiceBusy: Bool) {
        sounds.play(sound, voiceActive: voiceBusy)
    }

    // MARK: Watching

    /// Call `tick` four times a second until the app exits. Idempotent.
    func startSampling(_ tick: @escaping @MainActor () -> Void) {
        guard samplingTask == nil else { return }
        samplingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                tick()
            }
        }
    }

    func ingest(_ observation: FeedbackObservation) -> [DetectedFeedback] {
        watcher.observe(observation)
    }

    /// True once per distinct frame time. `recomputeRanking` runs on every
    /// pipeline output and also when the player changes a setting; the
    /// detector must see each frame once.
    func shouldFeed(timestamp: TimeInterval) -> Bool {
        guard timestamp != lastFedTimestamp else { return false }
        lastFedTimestamp = timestamp
        return true
    }

    /// Forget everything about the shot in progress: tracking stopped.
    func resetShotTracking() {
        detector.reset()
        advisedName = nil
        lastFedTimestamp = nil
    }

    // MARK: Score

    func recordOutcome(_ outcome: ShotOutcome, pocket: PocketID?) {
        score.record(outcome)
        if outcome.isMade { lastMadePocket = pocket }
        persistScore()
    }

    /// A new table lock is a new session.
    func resetScore() {
        guard score != SessionScore() else { return }
        score.reset()
        persistScore()
    }

    private func persistScore() {
        if let data = score.encoded() { UserDefaults.standard.set(data, forKey: Self.scoreKey) }
    }

    // MARK: Mirror

    /// The `feedback` block in /state.json: the last twenty events, newest
    /// last, with what each one asked of the phone.
    func mirrorState(prefs: Prefs) -> [String: Any] {
        let events: [[String: Any]] = records.records.map { record in
            var entry: [String: Any] = ["event": record.event.rawValue,
                                        "t": (record.time * 10).rounded() / 10,
                                        "haptic": record.haptic.rawValue,
                                        "sound": record.sound.rawValue]
            if let banner = record.banner { entry["banner"] = banner }
            if let detail = record.detail { entry["detail"] = detail }
            if let suppressed = record.suppressed { entry["suppressed"] = suppressed }
            return entry
        }
        var state: [String: Any] = [
            "sounds": prefs.sounds,
            "haptics": prefs.haptics,
            "soundEngine": sounds.status,
            "soundsPlayed": sounds.playCount,
            "score": ["made": score.made, "attempted": score.attempted,
                      "streak": score.streak, "bestStreak": score.bestStreak],
            "shotInFlight": detector.isShotInFlight,
            "events": events
        ]
        if let banner { state["banner"] = banner.text }
        return state
    }
}
