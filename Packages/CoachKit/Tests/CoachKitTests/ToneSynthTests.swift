//
//  ToneSynthTests.swift
//  CoachKitTests
//

import Foundation
import CueSyncCore
import Testing
@testable import CoachKit

@Suite("ToneSynth")
struct ToneSynthTests {
    private let audible = SoundID.allCases.filter { $0 != .none }

    @Test("Rendering is deterministic")
    func deterministic() {
        for sound in audible {
            #expect(ToneSynth.samples(for: sound) == ToneSynth.samples(for: sound), "\(sound)")
        }
    }

    @Test("Each sound is the length its notes say, and under half a second")
    func length() {
        for sound in audible {
            let samples = ToneSynth.samples(for: sound)
            let expected = ToneSynth.duration(of: sound) * Double(ToneSynth.sampleRate)
            #expect(abs(Double(samples.count) - expected) <= 1, "\(sound)")
            #expect(Double(samples.count) / Double(ToneSynth.sampleRate) < 0.5, "\(sound) is too long")
            #expect(samples.count > 500, "\(sound) is too short to hear")
        }
    }

    @Test("Nothing exceeds the peak limit, and nothing clips")
    func amplitudeBound() {
        for sound in audible {
            let samples = ToneSynth.samples(for: sound)
            let peak = samples.map { abs($0) }.max() ?? 0
            #expect(peak <= ToneSynth.peakLimit, "\(sound) peaks at \(peak)")
            #expect(peak > 0.2, "\(sound) is inaudibly quiet (\(peak))")
            #expect(samples.allSatisfy { $0.isFinite })
            // No run of samples pinned at the limit is what clipping looks like.
            var pinned = 0
            var longest = 0
            for sample in samples {
                pinned = abs(sample) >= ToneSynth.peakLimit * 0.995 ? pinned + 1 : 0
                longest = max(longest, pinned)
            }
            #expect(longest < 4, "\(sound) is flat-topped")
        }
    }

    @Test("Each sound starts and ends at silence, so there is no click")
    func edges() {
        for sound in audible {
            let samples = ToneSynth.samples(for: sound)
            #expect(abs(samples.first ?? 1) < 0.01, "\(sound) starts with a click")
            #expect(abs(samples.last ?? 1) < 0.001, "\(sound) ends with a click")
        }
    }

    @Test("Silence is empty, and an empty note list renders nothing")
    func none() {
        #expect(ToneSynth.samples(for: .none).isEmpty)
        #expect(ToneSynth.duration(of: .none) == 0)
        #expect(ToneSynth.render([]).isEmpty)
    }

    @Test("The sounds are different from each other")
    func distinct() {
        let rendered = audible.map { ToneSynth.samples(for: $0) }
        for (i, a) in rendered.enumerated() {
            for b in rendered[(i + 1)...] { #expect(a != b) }
        }
    }

    @Test("The lock chime rises and the miss falls")
    func shapes() {
        let lock = ToneSynth.notes(for: .lock)
        #expect(lock.count == 2 && lock[1].frequency > lock[0].frequency)
        let made = ToneSynth.notes(for: .made)
        #expect(made.map(\.frequency) == made.map(\.frequency).sorted(), "the arpeggio climbs")
        let miss = ToneSynth.notes(for: .miss)
        #expect(miss.count == 1 && miss[0].endFrequency < miss[0].frequency && miss[0].frequency < 200)
        #expect(ToneSynth.notes(for: .error).count == 2)
    }

    @Test("A pure tone has the energy near its own frequency")
    func pitch() {
        // Count zero crossings of a steady 1 kHz note: ~2000 a second.
        let notes = [SynthNote(frequency: 1_000, start: 0, duration: 0.2)]
        let samples = ToneSynth.render(notes)
        var crossings = 0
        for i in 1..<samples.count where (samples[i - 1] < 0) != (samples[i] < 0) { crossings += 1 }
        let seconds = 0.2
        let measured = Double(crossings) / 2 / seconds
        #expect(abs(measured - 1_000) < 60, "measured \(measured) Hz")
    }
}

@Suite("SessionScore")
struct SessionScoreTests {
    @Test("Made, missed and scratch keep the count and the streak")
    func counting() {
        var score = SessionScore()
        score.record(.madeAsAdvised(ball: BallID(1), pocket: .sideTop))
        score.record(.madeOther(ball: BallID(2), pocket: .sideTop))
        #expect(score.made == 2 && score.attempted == 2 && score.streak == 2)
        score.record(.missed)
        #expect(score.made == 2 && score.attempted == 3 && score.streak == 0 && score.bestStreak == 2)
        score.record(.scratch(pocket: .sideTop))
        #expect(score.attempted == 4 && score.made == 2)
        #expect(score.chipText == "2 of 4")
    }

    @Test("Reset starts a new session")
    func reset() {
        var score = SessionScore()
        score.record(.missed)
        score.reset()
        #expect(score == SessionScore())
        #expect(score.spokenText == "No shots yet this session")
    }

    @Test("It survives a round trip, and a corrupt blob is an empty score")
    func persistence() {
        var score = SessionScore()
        score.record(.madeOther(ball: BallID(2), pocket: .sideTop))
        score.record(.missed)
        #expect(SessionScore.decoded(from: score.encoded()) == score)
        #expect(SessionScore.decoded(from: Data("not json".utf8)) == SessionScore())
        #expect(SessionScore.decoded(from: nil) == SessionScore())
        let impossible = Data(#"{"made":5,"attempted":2,"streak":0,"bestStreak":0}"#.utf8)
        #expect(SessionScore.decoded(from: impossible) == SessionScore())
    }

    @Test("Feedback settings default to sounds and haptics on, scoreboard off, and persist")
    func settingsDefaults() {
        let fresh = SettingsModel()
        #expect(fresh.soundsEnabled && fresh.hapticsEnabled && !fresh.showScoreboard)
        var changed = fresh
        changed.soundsEnabled = false
        changed.showScoreboard = true
        let store = InMemorySettingsStore()
        changed.persist(to: store)
        let loaded = SettingsModel(loading: store)
        #expect(!loaded.soundsEnabled && loaded.hapticsEnabled && loaded.showScoreboard)
        #expect(changed.snapshot[SettingsKey.soundsEnabled] == .bool(false))
    }
}
