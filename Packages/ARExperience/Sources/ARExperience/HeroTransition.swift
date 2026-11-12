//
//  HeroTransition.swift
//  ARExperience
//
//  The motion of the suggested shot, as state a test can read.
//
//  When the suggestion changes (a different ball or a different pocket) the
//  old hero line fades out and the new one fades in over `fadeDuration`, and
//  the pocket ring pulses once. Nothing here draws: the renderer asks "how
//  opaque is the incoming line, the outgoing line, how big is the ring right
//  now" and applies the answers. With Reduce Motion on, or while a session
//  is being recorded (the metric palette must stay opaque to be
//  colour-keyable), every answer is the settled one at once: an instant
//  swap, no animation.
//
//  Pure value type over an injected clock, so it is tested on Linux.
//

import Foundation

public struct HeroTransition: Sendable, Equatable {
    /// Cross-fade length in seconds. Inside the 200 to 300 ms band that
    /// reads as a change rather than a flicker or a lag.
    public static let fadeDuration: TimeInterval = 0.25
    /// The pocket ring's single pulse, in seconds.
    public static let pulseDuration: TimeInterval = 0.45
    /// How much bigger than rest the ring gets at the top of its pulse.
    public static let pulsePeak = 1.3

    /// The suggestion currently shown.
    public private(set) var shot: OverlayLayout.ShotID?
    /// The suggestion that was shown before it, while it is still fading out.
    public private(set) var previousShot: OverlayLayout.ShotID?
    /// When `shot` last changed, on the caller's clock. Nil before the first.
    public private(set) var changedAt: TimeInterval?
    /// Whether the last change was an instant swap.
    public private(set) var instant = false

    public init() {}

    /// Report the suggestion for this frame.
    ///
    /// - Parameters:
    ///   - shot: the suggested shot, nil when there is none.
    ///   - now: seconds on a monotonic clock.
    ///   - reduceMotion: Reduce Motion is on (or the palette must stay opaque).
    /// - Returns: true when the suggestion CHANGED, so the caller knows to
    ///   park the old line for its fade-out.
    @discardableResult
    public mutating func note(shot newShot: OverlayLayout.ShotID?,
                              at now: TimeInterval,
                              reduceMotion: Bool) -> Bool {
        guard newShot != shot else { return false }
        previousShot = shot
        shot = newShot
        changedAt = now
        instant = reduceMotion
        return true
    }

    /// Opacity 0...1 of the line fading IN, `elapsed` seconds after a change.
    ///
    /// 0 at the change, 1 once `fadeDuration` has passed, non-decreasing in
    /// between (a smoothstep, so it eases at both ends). With Reduce Motion
    /// it is 1 immediately.
    public static func fadeIn(elapsed: TimeInterval, reduceMotion: Bool) -> Double {
        if reduceMotion { return 1 }
        guard elapsed.isFinite else { return 1 }
        let t = min(1, max(0, elapsed / fadeDuration))
        return t * t * (3 - 2 * t)
    }

    /// Opacity of the line fading OUT: the complement of `fadeIn`, so the
    /// two always sum to one and the cross-fade never dips or doubles.
    public static func fadeOut(elapsed: TimeInterval, reduceMotion: Bool) -> Double {
        1 - fadeIn(elapsed: elapsed, reduceMotion: reduceMotion)
    }

    /// Scale of the pocket ring, `elapsed` seconds after a change: rest (1),
    /// up to `pulsePeak` and back to rest, once. Always 1 with Reduce Motion.
    public static func pulseScale(elapsed: TimeInterval, reduceMotion: Bool) -> Double {
        if reduceMotion { return 1 }
        guard elapsed.isFinite, elapsed > 0, elapsed < pulseDuration else { return 1 }
        let phase = elapsed / pulseDuration
        // A half sine: 0 at both ends, 1 in the middle.
        return 1 + (pulsePeak - 1) * sin(phase * .pi)
    }

    // MARK: Reading the state at a time

    /// Seconds since the last change; a large number when there has been none.
    private func elapsed(at now: TimeInterval) -> TimeInterval {
        changedAt.map { max(0, now - $0) } ?? .infinity
    }

    /// Opacity of the current hero line at `now`.
    public func incomingOpacity(at now: TimeInterval) -> Double {
        Self.fadeIn(elapsed: elapsed(at: now), reduceMotion: instant)
    }

    /// Opacity of the previous hero line at `now`. Zero when there was none.
    public func outgoingOpacity(at now: TimeInterval) -> Double {
        guard previousShot != nil else { return 0 }
        return Self.fadeOut(elapsed: elapsed(at: now), reduceMotion: instant)
    }

    /// Scale of the pocket ring at `now`.
    public func ringScale(at now: TimeInterval) -> Double {
        shot == nil ? 1 : Self.pulseScale(elapsed: elapsed(at: now), reduceMotion: instant)
    }

    /// Whether every answer is final: the renderer can stop its timer and
    /// drop the outgoing line.
    public func isSettled(at now: TimeInterval) -> Bool {
        instant || elapsed(at: now) >= max(Self.fadeDuration, Self.pulseDuration)
    }
}
