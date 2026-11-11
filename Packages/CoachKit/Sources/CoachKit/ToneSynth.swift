//
//  ToneSynth.swift
//  CoachKit
//
//  The app's sounds, made of arithmetic: a note list in, PCM samples out.
//  No audio files, so nothing to license, nothing to ship, and the sounds are
//  tested the way any other function is. The app (FeedbackSounds) wraps the
//  samples in an AVAudioPCMBuffer; this file knows nothing about AVFoundation.
//
//  Rules every recipe obeys, held by tests:
//  - deterministic: the same call returns the same samples;
//  - peak at or under `peakLimit`, so a sound never clips the output stage;
//  - starts and ends at zero (short attack, decaying release), so there is
//    no click at either edge;
//  - a few hundred milliseconds at most.
//

import Foundation

/// One note of a recipe.
public struct SynthNote: Sendable, Equatable {
    /// Start frequency in Hz.
    public var frequency: Double
    /// Frequency at the end of the note; equal for a steady pitch, lower for
    /// the downward glide of a thud.
    public var endFrequency: Double
    /// Seconds from the start of the sound.
    public var start: TimeInterval
    public var duration: TimeInterval
    /// 0...1 before the master gain.
    public var amplitude: Double
    /// Level of the second harmonic relative to the fundamental: a little
    /// adds sparkle to a chime; none keeps a thud round.
    public var overtone: Double

    public init(frequency: Double, endFrequency: Double? = nil, start: TimeInterval,
                duration: TimeInterval, amplitude: Double = 1, overtone: Double = 0) {
        self.frequency = frequency
        self.endFrequency = endFrequency ?? frequency
        self.start = start
        self.duration = duration
        self.amplitude = amplitude
        self.overtone = overtone
    }
}

public enum ToneSynth {
    public static let sampleRate = 44_100
    /// No sample exceeds this: headroom under 1.0 for the output stage.
    public static let peakLimit: Float = 0.9
    /// Loudness of everything before the limiter. Sounds are accents on top
    /// of a game, not the main event.
    static let outputGain = 0.5
    static let attack = 0.004
    /// Silence appended after the last note so a release is never cut.
    static let tail = 0.02

    /// The notes of a sound.
    public static func notes(for sound: SoundID) -> [SynthNote] {
        switch sound {
        case .none:
            []
        case .lock:
            // Rising two notes: G5 then C6.
            [SynthNote(frequency: 784, start: 0, duration: 0.11, amplitude: 0.8, overtone: 0.25),
             SynthNote(frequency: 1_047, start: 0.09, duration: 0.2, amplitude: 0.9, overtone: 0.25)]
        case .made:
            // Bright major arpeggio: C5 E5 G5 C6, a little overlapped.
            [SynthNote(frequency: 523, start: 0, duration: 0.12, amplitude: 0.7, overtone: 0.3),
             SynthNote(frequency: 659, start: 0.07, duration: 0.12, amplitude: 0.75, overtone: 0.3),
             SynthNote(frequency: 784, start: 0.14, duration: 0.12, amplitude: 0.8, overtone: 0.3),
             SynthNote(frequency: 1_047, start: 0.21, duration: 0.26, amplitude: 0.9, overtone: 0.3)]
        case .miss:
            // A soft low thud: a short sine that falls in pitch.
            [SynthNote(frequency: 140, endFrequency: 70, start: 0, duration: 0.2, amplitude: 0.9)]
        case .select:
            // A soft tick.
            [SynthNote(frequency: 1_800, start: 0, duration: 0.035, amplitude: 0.5)]
        case .error:
            // A low double beep.
            [SynthNote(frequency: 220, start: 0, duration: 0.1, amplitude: 0.8, overtone: 0.1),
             SynthNote(frequency: 220, start: 0.16, duration: 0.1, amplitude: 0.8, overtone: 0.1)]
        }
    }

    /// Mono samples for `sound`; empty for `.none`.
    public static func samples(for sound: SoundID, sampleRate: Int = sampleRate) -> [Float] {
        render(notes(for: sound), sampleRate: sampleRate)
    }

    /// Total length in seconds of a rendered sound.
    public static func duration(of sound: SoundID) -> TimeInterval {
        let notes = notes(for: sound)
        guard !notes.isEmpty else { return 0 }
        return notes.map { $0.start + $0.duration }.max()! + tail
    }

    /// Mix `notes` into one buffer.
    public static func render(_ notes: [SynthNote], sampleRate: Int = sampleRate) -> [Float] {
        guard !notes.isEmpty, sampleRate > 0 else { return [] }
        let end = notes.map { $0.start + $0.duration }.max()! + tail
        let count = Int((end * Double(sampleRate)).rounded(.up))
        var mix = [Double](repeating: 0, count: count)

        for note in notes where note.duration > 0 {
            let first = Int((note.start * Double(sampleRate)).rounded())
            let length = Int((note.duration * Double(sampleRate)).rounded())
            var phase = 0.0
            for i in 0..<length where first + i < count {
                let t = Double(i) / Double(length)
                // Linear glide; phase is integrated so a glide stays smooth.
                let frequency = note.frequency + (note.endFrequency - note.frequency) * t
                phase += 2 * Double.pi * frequency / Double(sampleRate)
                let wave = sin(phase) + note.overtone * sin(2 * phase)
                mix[first + i] += wave * envelope(second: Double(i) / Double(sampleRate),
                                                  duration: note.duration) * note.amplitude
            }
        }

        let limit = Double(peakLimit)
        return mix.map { Float(limit * tanh($0 * outputGain / limit * 1.6)) }
    }

    /// Short linear attack, then an exponential decay that reaches (near)
    /// zero exactly at the end of the note.
    static func envelope(second: Double, duration: Double) -> Double {
        let rise = min(1, second / attack)
        let remaining = max(0, 1 - second / duration)
        // remaining^2 falls to exactly zero at the end: no click.
        return rise * remaining * remaining
    }
}
