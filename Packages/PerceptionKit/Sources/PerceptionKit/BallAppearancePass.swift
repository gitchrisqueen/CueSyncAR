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

        public init(associationRadii: Double = 2.0,
                    sampler: BallPatchSampler.Config = .default,
                    appearance: BallAppearance.Config = .default) {
            self.associationRadii = associationRadii
            self.sampler = sampler
            self.appearance = appearance
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
        guard let cue = patches.first(where: \.isCue) else { return [:] }
        let reference = WhiteReference(meanRGB: cue.patch.meanRGB)

        var result: [BallID: AppearanceObservation] = [:]
        for entry in patches {
            guard let observation = BallAppearance.classify(entry.patch, reference: reference,
                                                           config: config.appearance) else {
                continue
            }
            result[entry.id] = observation
        }
        return result
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
