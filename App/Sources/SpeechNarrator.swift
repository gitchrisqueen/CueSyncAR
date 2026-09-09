//
//  SpeechNarrator.swift
//  CueSync AR
//
//  The platform half of spoken guidance: it pronounces what
//  `CoachKit.SpokenGuidance` decides to say, and knows nothing about when
//  or whether anything should be said. Every rule about repetition, gaps,
//  priority and the on-line hysteresis lives in the pure type, where it is
//  tested on Linux without a speaker.
//
//  Everything here is free and on-device. `AVSpeechSynthesizer` ships with
//  iOS, needs no entitlement, no account, no API key and no network — the
//  voices are the ones already installed for VoiceOver. Nothing in this
//  feature calls out to a service, so there is no key to manage and no
//  degraded no-key state to design (playbook rule 7 has nothing to bite on).
//
//  Two device behaviours are deliberate and worth stating:
//
//  * The audio session is `.playback` / `.voicePrompt` with `.duckOthers`
//    and `.interruptSpokenAudioAndMixWithOthers`. Music playing in the room
//    dips for the prompt and comes back afterwards rather than being
//    killed; a podcast pauses, because two voices at once is neither.
//  * `.playback` ignores the ring/silent switch, the same choice
//    turn-by-turn navigation makes: a coach that goes silent because a
//    phone was flipped to silent hours ago reads as broken. The protection
//    against surprise is at the other end — the feature ships OFF and the
//    player turns it on in Settings.
//

import AVFAudio
import CoachKit
import Foundation
import os

/// Speaks the app's guidance out loud.
///
/// Owns one synthesizer and one `SpokenGuidance`. Feed it situations with
/// `consider(_:at:)` as often as they change; it will mostly say nothing.
@MainActor
final class SpeechNarrator {
    /// Diagnostics channel — filter the Xcode console with "cuesync".
    static let log = Logger(subsystem: "com.cuesync.ar", category: "speech")

    private let synthesizer = AVSpeechSynthesizer()
    /// Retained because `AVSpeechSynthesizer.delegate` is weak.
    private var synthesizerDelegate: SpeechSynthesizerDelegate?
    private var guidance = SpokenGuidance()
    /// True between handing an utterance to the synthesizer and the
    /// delegate reporting it done. Never polled from `isSpeaking` on a
    /// timer: the delegate is the only thing that moves it back.
    private(set) var isSpeaking = false
    /// The last thing actually said, for the HUD and the debug mirror.
    private(set) var lastSpoken: String?
    private(set) var spokenCount = 0
    /// Whether the audio session is currently active (and therefore
    /// ducking whatever else is playing).
    private var audioSessionActive = false

    var verbosity: SpeechVerbosity { guidance.verbosity }

    init() {
        let delegate = SpeechSynthesizerDelegate { [weak self] in
            self?.speechDidFinish()
        }
        synthesizerDelegate = delegate
        synthesizer.delegate = delegate
    }

    // MARK: Control

    /// Change the level. Turning it off stops mid-sentence rather than
    /// finishing the thought — the player just asked for quiet.
    func setVerbosity(_ level: SpeechVerbosity) {
        guard level != guidance.verbosity else { return }
        guidance.update(verbosity: level)
        Self.log.info("speech verbosity -> \(level.rawValue, privacy: .public)")
        if !level.isOn { stop() }
    }

    /// Offer the current situation. Says something only when
    /// `SpokenGuidance` decides it is worth saying.
    ///
    /// - Parameter now: monotonic seconds (system uptime), the same clock
    ///   the aim hold uses. Never wall time.
    func consider(_ situation: SpokenGuidance.Situation, at now: TimeInterval) {
        guard let utterance = guidance.next(for: situation, at: now) else { return }
        guard admit(utterance) else { return }
        speak(utterance.text)
    }

    /// Say something regardless of the guidance rules — the Settings
    /// preview and the debug mirror's test button, nothing else.
    func say(_ text: String) {
        guard !text.isEmpty else { return }
        speak(text, interrupting: true)
    }

    /// Stop talking now and drop anything queued.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        deactivateAudioSession()
    }

    /// Forget the conversation so far — tracking stopped, or the table was
    /// recalibrated, and the next shot is a fresh start.
    func reset() {
        guidance.reset()
        stop()
    }

    // MARK: Speaking

    /// Whether a decided utterance survives contact with the speaker.
    ///
    /// `SpokenGuidance` reasons in wall-clock gaps and cannot know how long
    /// a sentence takes to say, so this is the one thing the platform half
    /// decides: a nudge arriving on top of speech is dropped rather than
    /// queued (a backlog of stale aim advice is worse than silence), while
    /// a state change cuts the current sentence off, which is what "it
    /// pre-empts" has to mean out loud.
    private func admit(_ utterance: Utterance) -> Bool {
        guard isSpeaking else { return true }
        guard utterance.priority == .moment else {
            Self.log.debug("dropped nudge while speaking: \(utterance.text, privacy: .public)")
            return false
        }
        return true
    }

    private func speak(_ text: String, interrupting: Bool = true) {
        if isSpeaking, interrupting {
            // At a word boundary, not mid-syllable.
            synthesizer.stopSpeaking(at: .word)
        }
        guard activateAudioSession() else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        // A beat of silence in front, so the duck has landed before the
        // first syllable and the player hears the whole word.
        utterance.preUtteranceDelay = 0.1
        isSpeaking = true
        lastSpoken = text
        spokenCount += 1
        synthesizer.speak(utterance)
        Self.log.info("speaking: \(text, privacy: .public)")
    }

    private func speechDidFinish() {
        guard !synthesizer.isSpeaking else { return }
        isSpeaking = false
        deactivateAudioSession()
    }

    // MARK: Audio session

    /// Bring the session up just in time. Ducking only applies while the
    /// session is active, so it is activated per prompt and released after
    /// — otherwise the room's music would stay quiet for the whole rack.
    private func activateAudioSession() -> Bool {
        guard !audioSessionActive else { return true }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .voicePrompt,
                                    options: [.duckOthers,
                                              .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true)
            audioSessionActive = true
            return true
        } catch {
            // Never silently: a coach that says nothing and logs nothing is
            // indistinguishable from one that is switched off.
            Self.log.error("audio session failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func deactivateAudioSession() {
        guard audioSessionActive else { return }
        audioSessionActive = false
        do {
            try AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation)
        } catch {
            Self.log.error("audio session release failed: \(String(describing: error), privacy: .public)")
        }
    }
}

/// Delegate shim for `AVSpeechSynthesizer`.
///
/// Its own class because `AVSpeechSynthesizerDelegate` is not main-actor
/// isolated: a `@MainActor` type cannot conform to it under Swift 6 strict
/// concurrency. This object is `nonisolated`, holds nothing but an
/// immutable main-actor closure, and hops back to the main actor to report.
private final class SpeechSynthesizerDelegate: NSObject, AVSpeechSynthesizerDelegate,
                                               @unchecked Sendable {
    private let finished: @Sendable @MainActor () -> Void

    init(finished: @escaping @Sendable @MainActor () -> Void) {
        self.finished = finished
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        report()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        report()
    }

    private func report() {
        let finished = self.finished
        Task { @MainActor in finished() }
    }
}
