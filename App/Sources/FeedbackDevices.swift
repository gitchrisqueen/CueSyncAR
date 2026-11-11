//
//  FeedbackDevices.swift
//  CueSync AR
//
//  The two things that reach the player's body: the Taptic Engine and the
//  speaker. Both are thin. What to play and when is CoachKit's FeedbackPlan
//  and ToneSynth; this file only turns a named haptic into a UIKit
//  generator and a list of samples into an AVAudioEngine buffer.
//
//  Neither can be felt or heard in the Simulator (it has no Taptic Engine,
//  and its audio goes to the Mac). The proof that they were ASKED to play is
//  the `feedback` log line FeedbackCenter writes for every event.
//

import AVFAudio
import CoachKit
import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Haptics

@MainActor
final class FeedbackHaptics {
    private let notification = UINotificationFeedbackGenerator()
    private let selection = UISelectionFeedbackGenerator()
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)

    init() { prepare() }

    /// Wake the Taptic Engine. It idles after a few seconds, and the first
    /// tap after that lags by tens of milliseconds, which is the difference
    /// between feeling the ball drop and feeling it a moment later.
    func prepare() {
        notification.prepare()
        selection.prepare()
        light.prepare()
        medium.prepare()
        rigid.prepare()
    }

    func play(_ style: HapticStyle) {
        switch style {
        case .none: return
        case .selection: selection.prepare(); selection.selectionChanged()
        case .light: light.prepare(); light.impactOccurred()
        case .medium: medium.prepare(); medium.impactOccurred()
        case .rigid: rigid.prepare(); rigid.impactOccurred()
        case .success: notification.prepare(); notification.notificationOccurred(.success)
        case .warning: notification.prepare(); notification.notificationOccurred(.warning)
        case .error: notification.prepare(); notification.notificationOccurred(.error)
        }
        // Keep the engine warm for the next one.
        prepare()
    }
}

// MARK: - Sounds

/// Plays `ToneSynth` recipes through one AVAudioEngine.
///
/// The audio session is `.ambient`: it mixes with the player's music and
/// obeys the ring/silent switch, which is the right manners for game
/// accents. (Voice guidance, SpeechNarrator, deliberately does the opposite
/// and speaks over silent, like navigation.) The narrator switches the
/// shared session to `.playback` while it speaks and leaves it there, so
/// this puts it back to `.ambient` before each sound, except while the
/// narrator is mid-sentence, when changing category would cut it off.
@MainActor
final class FeedbackSounds {
    private static let log = Logger(subsystem: "com.cuesync.ar", category: "feedback")

    private let engine = AVAudioEngine()
    private let format: AVAudioFormat
    private var players: [SoundID: AVAudioPlayerNode] = [:]
    private var buffers: [SoundID: AVAudioPCMBuffer] = [:]
    /// The last thing that went wrong, for the mirror. Nil when all is well.
    private(set) var lastError: String?
    private(set) var playCount = 0

    init() {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                               sampleRate: Double(ToneSynth.sampleRate),
                               channels: 1, interleaved: false)!
        for sound in SoundID.allCases where sound != .none {
            guard let buffer = Self.buffer(for: sound, format: format) else { continue }
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            players[sound] = player
            buffers[sound] = buffer
        }
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engineConfigurationChanged() }
        }
    }

    private static func buffer(for sound: SoundID, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let samples = ToneSynth.samples(for: sound)
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() { channel[index] = sample }
        return buffer
    }

    /// Bring the engine up ahead of the sound that is about to need it:
    /// the first start costs ~100 ms.
    func prewarm(voiceActive: Bool) {
        _ = ensureRunning(voiceActive: voiceActive)
    }

    @discardableResult
    func play(_ sound: SoundID, voiceActive: Bool) -> Bool {
        guard sound != .none, let player = players[sound], let buffer = buffers[sound] else { return false }
        guard ensureRunning(voiceActive: voiceActive) else { return false }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
        playCount += 1
        return true
    }

    private func ensureRunning(voiceActive: Bool) -> Bool {
        do {
            if !voiceActive {
                let session = AVAudioSession.sharedInstance()
                if session.category != .ambient {
                    try session.setCategory(.ambient, mode: .default)
                }
                try session.setActive(true)
            }
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            lastError = nil
            return true
        } catch {
            // Never silently: a game with no sound and no log line is
            // indistinguishable from a game with sounds switched off.
            lastError = String(describing: error)
            Self.log.error("sound engine failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func engineConfigurationChanged() {
        // A route change or an interruption stopped the engine and its
        // players. The next `play` restarts them.
        for player in players.values { player.stop() }
        Self.log.info("sound engine configuration changed")
    }

    var status: String {
        lastError ?? (engine.isRunning ? "running" : "idle")
    }
}
