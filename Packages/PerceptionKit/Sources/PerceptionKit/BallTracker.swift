//
//  BallTracker.swift
//  PerceptionKit
//
//  Multi-frame ball tracking in table space (task M2-03). Pure value type:
//  greedy nearest-neighbor association with a gating distance, per-axis
//  constant-position Kalman smoothing, appearance/disappearance stability
//  gating (no flicker), and majority-vote kind classification.
//
//  Model choice: balls are stationary while the player aims — a constant-
//  position Kalman with modest process noise smooths detector jitter well
//  and re-converges quickly after balls move. Revisit with a velocity state
//  if shot-in-motion tracking becomes a requirement.
//

import CueSyncCore
import Foundation

/// One projected detection: a candidate ball position in table space.
public struct BallObservation: Sendable, Equatable {
    public var kind: Ball.Kind
    public var position: Vec2
    public var confidence: Double
    public var radius: Double

    public init(kind: Ball.Kind, position: Vec2, confidence: Double,
                radius: Double = Ball.standardRadius) {
        self.kind = kind
        self.position = position
        self.confidence = confidence
        self.radius = radius
    }
}

/// Scalar constant-position Kalman filter.
struct ScalarKalman: Sendable, Equatable {
    var estimate: Double
    var variance: Double
    let processNoise: Double
    let measurementNoise: Double

    init(initial: Double, initialVariance: Double,
         processNoise: Double, measurementNoise: Double) {
        estimate = initial
        variance = initialVariance
        self.processNoise = processNoise
        self.measurementNoise = measurementNoise
    }

    mutating func update(measurement: Double) {
        // Predict (constant model): only uncertainty grows.
        variance += processNoise
        // Correct.
        let gain = variance / (variance + measurementNoise)
        estimate += gain * (measurement - estimate)
        variance *= (1 - gain)
    }
}

struct BallTrack: Sendable, Equatable {
    let id: BallID
    var x: ScalarKalman
    var y: ScalarKalman
    var radius: Double
    var kindVotes: [Ball.Kind: Int]
    var lastConfidence: Double
    var hits: Int
    var consecutiveMisses: Int
    var confirmed: Bool

    var position: Vec2 { Vec2(x.estimate, y.estimate) }

    var votedKind: Ball.Kind {
        kindVotes.max { a, b in
            a.value != b.value ? a.value < b.value : describe(a.key) < describe(b.key)
        }?.key ?? .unknown
    }

    private func describe(_ kind: Ball.Kind) -> String { String(describing: kind) }
}

public struct TrackerConfig: Sendable, Equatable {
    /// Max distance (m) between a track and an observation to associate them.
    public var gatingDistance: Double
    /// Frames a new track must persist before it is reported.
    public var appearanceFrames: Int
    /// Consecutive missed frames before a track is dropped.
    public var disappearanceFrames: Int
    /// Kalman noise parameters (m²).
    public var processNoise: Double
    public var measurementNoise: Double
    /// Kind votes retained (sliding influence; votes cap at this count).
    public var maxKindVotes: Int

    public init(gatingDistance: Double = 0.08,
                appearanceFrames: Int = 3,
                disappearanceFrames: Int = 10,
                processNoise: Double = 4e-5,
                measurementNoise: Double = 4e-4,
                maxKindVotes: Int = 15) {
        self.gatingDistance = gatingDistance
        self.appearanceFrames = appearanceFrames
        self.disappearanceFrames = disappearanceFrames
        self.processNoise = processNoise
        self.measurementNoise = measurementNoise
        self.maxKindVotes = maxKindVotes
    }

    public static let `default` = TrackerConfig()
}

public struct BallTracker: Sendable {
    public var config: TrackerConfig
    var tracks: [BallTrack] = []
    private var nextID = 0

    public init(config: TrackerConfig = .default) {
        self.config = config
    }

    /// Ingest one frame of observations; returns the confirmed balls.
    public mutating func update(observations: [BallObservation]) -> [Ball] {
        // Greedy association: consider all (track, observation) pairs within
        // the gate, closest first; each side is used at most once. With
        // per-frame motion far below ball spacing this preserves identities
        // even when balls pass close by each other.
        var pairs: [(trackIndex: Int, obsIndex: Int, distance: Double)] = []
        for (ti, track) in tracks.enumerated() {
            for (oi, obs) in observations.enumerated() {
                let d = track.position.distance(to: obs.position)
                if d <= config.gatingDistance {
                    pairs.append((ti, oi, d))
                }
            }
        }
        pairs.sort { $0.distance < $1.distance }

        var usedTracks = Set<Int>()
        var usedObs = Set<Int>()
        for pair in pairs {
            guard !usedTracks.contains(pair.trackIndex),
                  !usedObs.contains(pair.obsIndex) else { continue }
            usedTracks.insert(pair.trackIndex)
            usedObs.insert(pair.obsIndex)
            apply(observations[pair.obsIndex], toTrackAt: pair.trackIndex)
        }

        // Unmatched tracks miss a frame.
        for index in tracks.indices where !usedTracks.contains(index) {
            tracks[index].consecutiveMisses += 1
        }
        tracks.removeAll { $0.consecutiveMisses >= config.disappearanceFrames }

        // Unmatched observations spawn tentative tracks.
        for (oi, obs) in observations.enumerated() where !usedObs.contains(oi) {
            tracks.append(makeTrack(for: obs))
        }

        return confirmedBalls()
    }

    private mutating func apply(_ obs: BallObservation, toTrackAt index: Int) {
        tracks[index].x.update(measurement: obs.position.x)
        tracks[index].y.update(measurement: obs.position.y)
        tracks[index].radius = obs.radius
        tracks[index].lastConfidence = obs.confidence
        tracks[index].hits += 1
        tracks[index].consecutiveMisses = 0
        let votes = tracks[index].kindVotes[obs.kind] ?? 0
        if votes < config.maxKindVotes {
            tracks[index].kindVotes[obs.kind] = votes + 1
        }
        if tracks[index].hits >= config.appearanceFrames {
            tracks[index].confirmed = true
        }
    }

    private mutating func makeTrack(for obs: BallObservation) -> BallTrack {
        defer { nextID += 1 }
        return BallTrack(
            id: BallID(nextID),
            x: ScalarKalman(initial: obs.position.x, initialVariance: config.measurementNoise,
                            processNoise: config.processNoise,
                            measurementNoise: config.measurementNoise),
            y: ScalarKalman(initial: obs.position.y, initialVariance: config.measurementNoise,
                            processNoise: config.processNoise,
                            measurementNoise: config.measurementNoise),
            radius: obs.radius,
            kindVotes: [obs.kind: 1],
            lastConfidence: obs.confidence,
            hits: 1,
            consecutiveMisses: 0,
            confirmed: config.appearanceFrames <= 1)
    }

    private func confirmedBalls() -> [Ball] {
        tracks.filter(\.confirmed)
            .sorted { $0.id.rawValue < $1.id.rawValue }
            .map { track in
                Ball(id: track.id, kind: track.votedKind,
                     position: track.position, radius: track.radius,
                     confidence: track.lastConfidence)
            }
    }
}
