//
//  BallAppearancePass.swift
//  PerceptionKit
//
//  One frame's worth of "what colour is each tracked ball".
//
//  Kept out of PerceptionPipeline because it is a self-contained
//  decision that wants testing on its own: which track owns which
//  detection box, which ball is the illuminant, and what to do when the
//  answer is "cannot say". The pipeline calls it and forwards the result.
//
//  The association is by table position, not by detector order. Track
//  ids come out of a Kalman filter whose estimate stays inside the hull
//  of the observations that fed it, so the nearest admitted observation
//  to a track is that track's observation — and when nothing is within
//  a ball's width, the honest answer is no patch rather than the colour
//  of its neighbour.
//

import CueSyncCore
import Foundation

/// A detection that survived projection and the playing-surface gate,
/// paired with the image box it came from.
public struct LocatedDetection: Sendable, Equatable {
    public var position: Vec2
    public var box: NormalizedRect
    public var kind: Ball.Kind

    public init(position: Vec2, box: NormalizedRect, kind: Ball.Kind) {
        self.position = position
        self.box = box
        self.kind = kind
    }
}

public enum BallAppearancePass {
    public struct Config: Sendable, Equatable {
        /// How far a track may be from an observation and still own it,
        /// as a multiple of the ball radius. One diameter: two balls
        /// cannot be closer than that without touching, so a match this
        /// close is unambiguous.
        public var associationRadii: Double
        public var sampler: BallPatchSampler.Config
        public var appearance: BallAppearance.Config
        /// Pick the cue ball from the picture when the detector named
        /// none. Off switch for the fallback only; a detector or tapped
        /// cue ball is never overridden either way.
        public var inferCueBall: Bool
        /// How far the best candidate's brightness-times-neutrality score
        /// must beat the runner-up's before it is trusted as the cue
        /// ball. Measured over 31 labelled frames the real cue ball won
        /// every one, by 1.15x at the narrowest (a purple stripe with a
        /// cream band) and about 2x typically, so 1.10 only refuses a
        /// dead heat.
        public var inferredCueMargin: Double
        /// Confidence of the white look an inferred cue ball casts. Below
        /// the 0.9 a detector-named cue ball casts, so a guess is
        /// outvoted by a real colour reading rather than the reverse.
        public var inferredCueConfidence: Double

        public init(associationRadii: Double = 2.0,
                    sampler: BallPatchSampler.Config = .default,
                    appearance: BallAppearance.Config = .default,
                    inferCueBall: Bool = true,
                    inferredCueMargin: Double = 1.10,
                    inferredCueConfidence: Double = 0.6) {
            self.associationRadii = associationRadii
            self.sampler = sampler
            self.appearance = appearance
            self.inferCueBall = inferCueBall
            self.inferredCueMargin = inferredCueMargin
            self.inferredCueConfidence = inferredCueConfidence
        }

        public static let `default` = Config()
    }

    /// Classify every tracked ball this frame can speak to.
    ///
    /// Returns an empty dictionary rather than guesses when there is no
    /// cue ball in frame: `BallAppearance.classify` refuses to name a
    /// colour without a white reference, because under this room's light
    /// an unreferenced reading makes every ball the same colour.
    public static func run(balls: [Ball],
                           detections: [LocatedDetection],
                           image: some PixelSampling,
                           config: Config = .default) -> [BallID: AppearanceObservation] {
        guard !balls.isEmpty, !detections.isEmpty else { return [:] }
        let maximumDistance = config.associationRadii * Ball.standardRadius

        var patches: [(id: BallID, patch: BallPatch, isCue: Bool)] = []
        for ball in balls {
            guard let match = nearest(to: ball.position, in: detections,
                                      within: maximumDistance) else { continue }
            guard let patch = BallPatchSampler.sample(box: match.box, from: image,
                                                      config: config.sampler) else { continue }
            // The detector's own class decides the illuminant, not the
            // classifier's — using the classifier's answer to build the
            // reference the classifier needs would be circular.
            patches.append((ball.id, patch, ball.kind == .cue || match.kind == .cue))
        }
        // The detector or the player named a cue ball (tracked kind, or a
        // detection's class): that is final, and when its patch could not
        // be read this frame the honest answer is nothing, not a guess
        // at some other ball.
        let cueNamed = balls.contains { $0.kind == .cue } || detections.contains { $0.kind == .cue }
        var inferredCue: BallID?
        var cue = patches.first(where: \.isCue)
        if cue == nil, !cueNamed, config.inferCueBall,
           let pick = brightestLeastColoured(in: patches.map { ($0.id, $0.patch) },
                                             margin: config.inferredCueMargin) {
            inferredCue = pick
            cue = patches.first { $0.id == pick }
        }
        guard let cue else { return [:] }
        let reference = WhiteReference(meanRGB: cue.patch.meanRGB)

        var result: [BallID: AppearanceObservation] = [:]
        for entry in patches {
            guard var observation = BallAppearance.classify(entry.patch, reference: reference,
                                                           config: config.appearance) else {
                continue
            }
            if entry.id == inferredCue {
                // Its own reference, so it reads white by construction:
                // say so, but as a guess.
                observation.family = .white
                observation.confidence = config.inferredCueConfidence
            }
            result[entry.id] = observation
        }
        return result
    }

    /// The ball that looks most like a cue ball with no reference to go
    /// by: the brightest and least saturated, scored on raw (unbalanced)
    /// RGB as `value * (1 - saturation)`.
    ///
    /// Measured to pick the cue ball in 31 of 31 labelled frames (9 clip
    /// frames, 22 iPad frames) where the detector's own `white-ball`
    /// class fired in 1 of the 9 clip frames. Needs two balls to compare
    /// and a winner clearly ahead of the runner-up, else nil. Known to be
    /// foolable by a spotted cue ball or an eight showing its white
    /// number disc, which is why the caller uses it only when nothing has
    /// named a cue ball, and `BallIdentity` still wants several agreeing
    /// looks before it renames anything.
    public static func brightestLeastColoured(in candidates: [(id: BallID, patch: BallPatch)],
                                              margin: Double = 1.10) -> BallID? {
        guard candidates.count >= 2 else { return nil }
        let scored = candidates.map { (id: $0.id, score: neutralBrightness($0.patch)) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.id.rawValue < $1.id.rawValue }
        guard let best = scored.first, best.score > 0, scored[1].score * margin <= best.score else {
            return nil
        }
        return best.id
    }

    /// Raw value times (1 - saturation): high only for a ball that is
    /// both bright and close to neutral.
    static func neutralBrightness(_ patch: BallPatch) -> Double {
        let rgb = patch.meanRGB
        let high = Swift.max(rgb.x, Swift.max(rgb.y, rgb.z))
        let low = Swift.min(rgb.x, Swift.min(rgb.y, rgb.z))
        guard high > 1e-6 else { return 0 }
        return high * (1 - (high - low) / high)
    }

    static func nearest(to position: Vec2, in detections: [LocatedDetection],
                        within distance: Double) -> LocatedDetection? {
        var best: LocatedDetection?
        var bestDistance = distance
        for detection in detections {
            let candidate = detection.position.distance(to: position)
            guard candidate <= bestDistance else { continue }
            best = detection
            bestDistance = candidate
        }
        return best
    }
}
