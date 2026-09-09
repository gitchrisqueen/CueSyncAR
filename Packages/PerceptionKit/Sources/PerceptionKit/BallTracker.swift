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
    /// Seconds of frame time this track has gone unmatched WHILE VISIBLE.
    /// Reset on every match; frames where the track is out of view do not
    /// contribute, so this is a "looked and did not find it" stopwatch.
    var visibleMissSeconds: TimeInterval
    /// Set when this track went unmatched on a frame where a ball turned up
    /// somewhere new — the signature of it having MOVED rather than been
    /// hidden. Sticky, because the giveaway happens once (on the frame the
    /// ball is first seen at its destination) while the stale track lingers
    /// for many frames afterwards. Cleared the moment the track is matched
    /// again.
    var presumedMoved = false
    var confirmed: Bool

    var position: Vec2 { Vec2(x.estimate, y.estimate) }

    /// Everything a retired track hands to its successor (`DormantIdentity`).
    var identity: DormantIdentity {
        DormantIdentity(id: id, position: position, radius: radius,
                        kindVotes: kindVotes, retiredAt: 0)
    }

    var votedKind: Ball.Kind {
        kindVotes.max { a, b in
            a.value != b.value ? a.value < b.value : describe(a.key) < describe(b.key)
        }?.key ?? .unknown
    }

    private func describe(_ kind: Ball.Kind) -> String { String(describing: kind) }
}

/// A retired track's identity, held so that the same ball — re-acquired at
/// the same spot after a detection gap no grace could bridge — gets its
/// OWN id back rather than a fresh one.
///
/// This exists because a grace period cannot solve identity on its own. On
/// the operator's aiming recording the detector loses a given ball for tens
/// of seconds at a time (it sees 2–4 of 7 balls per frame while he stands
/// over the table), and no retirement budget large enough to bridge that is
/// compatible with clearing a pocketed ball's ring in about a second. The
/// budget decides how long a ring is allowed to be WRONG; re-identification
/// decides what the ball is called when it comes back.
struct DormantIdentity: Sendable, Equatable {
    let id: BallID
    let position: Vec2
    var radius: Double
    var kindVotes: [Ball.Kind: Int]
    /// Frame-clock time of retirement; 0 when the caller passes no clock.
    var retiredAt: TimeInterval
}

public struct TrackerConfig: Sendable, Equatable {
    /// Max distance (m) between a track and an observation to associate them.
    public var gatingDistance: Double
    /// Frames a new track must persist before it is reported.
    public var appearanceFrames: Int
    /// Consecutive VISIBLE misses before a track is dropped. Misses only
    /// accrue while the track's position is actually in view (visibility-
    /// gated track management): a ball is a static object — walking the
    /// camera away must never erase it.
    public var disappearanceFrames: Int
    /// Seconds a VISIBLE track may go unmatched before it is retired.
    /// Frame counts are not a clock: `disappearanceFrames` at the observed
    /// device tick rate (~8.7 Hz) is ~3.5 s, long enough for a struck ball
    /// to leave a phantom ring frozen at the shot origin while its new
    /// track runs on at the destination. Time-based retirement keeps the
    /// behaviour identical whatever the pipeline's tick rate. Set to 0 to
    /// disable and fall back to the frame count alone.
    ///
    /// 2.5 s, raised from 0.75 s on the owner's instruction after the cost
    /// and the benefit were both measured on real recordings of his table.
    /// The benefit: while a player is addressing the ball, their own bridge
    /// hand and cue occlude the cue ball for a median of 2.7 s, and 0.75 s
    /// retired its track — 49 % of frames in an aiming recording had no cue
    /// ball, which is the largest single reason no guide was drawn. At
    /// 2.5 s the cue ball is present on 62 % of frames rather than 51 %,
    /// guides are drawn on 48 % rather than 39 %, and track churn FALLS
    /// (14 to 10), because tracks survive occlusion instead of dying and
    /// being reborn under new ids.
    ///
    /// The cost, stated because it is the other side of the same knob: a
    /// POCKETED ball also keeps its ring this long. That is the phantom
    /// ring #7 shortened, and this is a deliberate trade back toward it.
    /// The owner reviewed the numbers and chose 2.5 s; the setting is live
    /// in Settings and via the debug mirror, so it can be moved from the
    /// table without a build.
    public var visibleMissGrace: TimeInterval
    /// The shorter budget used on a frame where an observation appeared
    /// that matched no existing track — the signature of a ball having
    /// moved rather than been hidden. Keeps a struck ball's phantom ring at
    /// the shot origin inside the ~1 s the operator asked for, while
    /// `visibleMissGrace` stays long enough to survive a bridge hand.
    public var strikeMissGrace: TimeInterval
    /// Radius (m) within which a new observation reclaims a RETIRED track's
    /// id instead of being issued a new one.
    ///
    /// Two different balls cannot have centres closer than one diameter
    /// (5.7 cm), so a default of 1.6 radii (4.6 cm) cannot hand one ball's
    /// identity to another: nothing else can physically be there. It is the
    /// same bound `mergePhysicalOverlaps` uses for "one ball seen twice",
    /// for the same reason. Set to 0 to disable re-identification.
    public var reidentificationDistance: Double
    /// Seconds a retired identity is remembered. Only ever consulted for an
    /// observation that matched no live track, so a long memory costs
    /// nothing while the ball is being tracked normally; it bounds how stale
    /// a layout may be before a re-racked table starts fresh.
    public var reidentificationMemory: TimeInterval
    /// Cap on remembered identities; the oldest is evicted first. A rack is
    /// 16 balls, so 32 holds a full table twice over.
    public var maxRememberedIdentities: Int
    /// Kalman noise parameters (m²).
    public var processNoise: Double
    public var measurementNoise: Double
    /// Kind votes retained (sliding influence; votes cap at this count).
    public var maxKindVotes: Int

    public init(gatingDistance: Double = 0.08,
                appearanceFrames: Int = 3,
                disappearanceFrames: Int = 30,
                visibleMissGrace: TimeInterval = 2.5,
                strikeMissGrace: TimeInterval = 0.75,
                reidentificationDistance: Double = Ball.standardRadius * 1.6,
                reidentificationMemory: TimeInterval = 120,
                maxRememberedIdentities: Int = 32,
                processNoise: Double = 4e-5,
                measurementNoise: Double = 4e-4,
                maxKindVotes: Int = 15) {
        self.gatingDistance = gatingDistance
        self.appearanceFrames = appearanceFrames
        self.disappearanceFrames = disappearanceFrames
        self.visibleMissGrace = visibleMissGrace
        self.strikeMissGrace = strikeMissGrace
        self.reidentificationDistance = reidentificationDistance
        self.reidentificationMemory = reidentificationMemory
        self.maxRememberedIdentities = maxRememberedIdentities
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
    /// Timestamp of the previous `update`, for per-frame elapsed time.
    private var lastTimestamp: TimeInterval?
    /// Identities of retired tracks, newest last. Only CONFIRMED tracks are
    /// remembered: an unconfirmed track's id was never reported to anyone,
    /// so bringing it back would only let a one-frame phantom keep a name.
    var dormant: [DormantIdentity] = []
    /// Frame clock, for dormant-identity expiry. Zero until a timestamped
    /// frame arrives, so a caller that passes no clock never expires.
    private var clock: TimeInterval = 0

    /// Closer than this and two tracks are one ball seen twice.
    ///
    /// Two distinct ball centres cannot be nearer than one diameter (2 r,
    /// 5.7 cm); 1.6 r (4.6 cm) sits below that, so nothing here can ever
    /// conflate two real balls. This is the only distance allowed to decide
    /// "same ball" — the association gate is larger on purpose (a ball
    /// moves between frames) and must never be used for the question.
    static let duplicateDistance = Ball.standardRadius * 1.6

    public init(config: TrackerConfig = .default) {
        self.config = config
    }

    /// Ingest one frame of observations; returns the confirmed balls.
    /// `isVisible` reports whether a table-space position is inside the
    /// camera's current view — unmatched tracks OUTSIDE the view are
    /// frozen, not penalized (best practice from MOT track management:
    /// an object can only be declared gone where you actually looked).
    /// `timestamp` is the frame's own clock (seconds, monotonic); pass it
    /// so retirement of visible-but-unmatched tracks runs on wall clock
    /// rather than on tick rate. Omitting it falls back to the frame count.
    public mutating func update(observations: [BallObservation],
                                timestamp: TimeInterval? = nil,
                                isVisible: (Vec2) -> Bool = { _ in true }) -> [Ball] {
        // Elapsed frame time. Non-monotonic or first-ever timestamps
        // contribute nothing rather than a garbage delta.
        let elapsed: TimeInterval
        if let timestamp, let previous = lastTimestamp, timestamp > previous {
            elapsed = timestamp - previous
        } else {
            elapsed = 0
        }
        lastTimestamp = timestamp ?? lastTimestamp
        if let timestamp { clock = timestamp }
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
        // Total order: ties on distance (a symmetric layout, an observation
        // exactly between two tracks) fall back to array position, never to
        // sort stability — replay goldens require byte-identical tracks.
        pairs.sort { a, b in
            if a.distance != b.distance { return a.distance < b.distance }
            if a.trackIndex != b.trackIndex { return a.trackIndex < b.trackIndex }
            return a.obsIndex < b.obsIndex
        }

        var usedTracks = Set<Int>()
        var usedObs = Set<Int>()
        for pair in pairs {
            guard !usedTracks.contains(pair.trackIndex),
                  !usedObs.contains(pair.obsIndex) else { continue }
            usedTracks.insert(pair.trackIndex)
            usedObs.insert(pair.obsIndex)
            apply(observations[pair.obsIndex], toTrackAt: pair.trackIndex)
        }

        // Unmatched tracks. A track that lost the competition for a ball to
        // ANOTHER track CLOSE ENOUGH TO BE THE SAME BALL is a duplicate
        // (spawned when a fast ball outran association) — absorb it into the
        // winner immediately. Everything else misses a frame only where the
        // camera can actually see (out-of-view static balls persist
        // untouched).
        //
        // "Close enough to be the same ball" is `Self.duplicateDistance`,
        // NOT the association gate. The gate is 8 cm because a ball moves
        // between frames; two distinct ball CENTRES can be 5.7 cm apart
        // (frozen, in contact), well inside it. Judging duplicates by the
        // gate therefore destroyed a frozen ball's identity the first frame
        // the detector missed it: its neighbour was matched and 5.7 cm away,
        // so it was absorbed as a phantom of that neighbour — silently, and
        // without even the retirement path's chance to be re-identified.
        // `scripted-frozen-pair` is the regression fixture for exactly this.
        let somethingAppeared = observations.indices.contains { !usedObs.contains($0) }
        var absorbed: [Int] = []
        for index in tracks.indices where !usedTracks.contains(index) {
            if let winner = tracks.indices.first(where: { candidate in
                candidate != index && usedTracks.contains(candidate)
                    && tracks[candidate].position.distance(to: tracks[index].position)
                        < Self.duplicateDistance
            }) {
                for (kind, votes) in tracks[index].kindVotes {
                    let merged = (tracks[winner].kindVotes[kind] ?? 0) + votes
                    tracks[winner].kindVotes[kind] = min(merged, config.maxKindVotes)
                }
                tracks[winner].hits += tracks[index].hits
                absorbed.append(index)
            } else if isVisible(tracks[index].position) {
                tracks[index].consecutiveMisses += 1
                tracks[index].visibleMissSeconds += elapsed
                if somethingAppeared { tracks[index].presumedMoved = true }
            }
        }
        for index in absorbed.sorted(by: >) {
            tracks.remove(at: index)
        }
        // Did a ball turn up somewhere new this frame? An observation that
        // matched no existing track is the signature of a ball having MOVED
        // — most often struck — because a ball that merely went behind a
        // hand produces no observation anywhere.
        //
        // That distinction is what lets one grace serve two opposite cases.
        // A player addressing the ball occludes it with their own bridge
        // hand and cue for a median of 2.7 s, and retiring it in 0.75 s left
        // 49 % of an aiming recording with no cue ball at all. A struck ball
        // meanwhile must give up its old position within about a second or
        // it leaves a phantom ring at the shot origin. Occlusion gets the
        // long budget; a frame where something appeared elsewhere gets the
        // short one.
        // Retire on whichever budget runs out first. Both are gated on
        // visibility, so an occluded or out-of-frame ball still persists
        // indefinitely — neither counter moves while nobody is looking.
        // Retire, remembering every CONFIRMED identity so the same ball can
        // reclaim it (see `DormantIdentity`). Retirement means "stop drawing
        // a ring here", which is a question about this position; it is not a
        // decision that the ball has ceased to exist.
        var retired: [BallTrack] = []
        tracks.removeAll { track in
            let expired: Bool
            if track.consecutiveMisses >= config.disappearanceFrames {
                expired = true
            } else {
                let grace = track.presumedMoved
                    ? config.strikeMissGrace : config.visibleMissGrace
                expired = grace > 0 && track.visibleMissSeconds >= grace
            }
            if expired, track.confirmed { retired.append(track) }
            return expired
        }
        for track in retired {
            remember(track)
        }

        // Unmatched observations spawn tentative tracks, reclaiming a
        // retired identity when one was left at this spot.
        for (oi, obs) in observations.enumerated() where !usedObs.contains(oi) {
            tracks.append(makeTrack(for: obs))
        }
        expireDormantIdentities()

        mergePhysicalOverlaps()
        return confirmedBalls()
    }

    /// Two ball centers can never sit closer than one ball diameter — a
    /// pair of tracks inside ~0.8 diameters is one ball seen twice (the
    /// detector occasionally emits overlapping boxes, keeping BOTH tracks
    /// matched so competition absorption never fires). The better-
    /// established track absorbs the other.
    private mutating func mergePhysicalOverlaps() {
        let overlapDistance = Self.duplicateDistance
        var index = 0
        while index < tracks.count {
            var other = index + 1
            while other < tracks.count {
                if tracks[index].position.distance(to: tracks[other].position)
                    < overlapDistance {
                    let (keep, drop) = tracks[index].hits >= tracks[other].hits
                        ? (index, other) : (other, index)
                    for (kind, votes) in tracks[drop].kindVotes {
                        let merged = (tracks[keep].kindVotes[kind] ?? 0) + votes
                        tracks[keep].kindVotes[kind] = min(merged, config.maxKindVotes)
                    }
                    tracks[keep].hits += tracks[drop].hits
                    tracks.remove(at: drop)
                    if drop < index { index -= 1 }
                    other = index + 1
                } else {
                    other += 1
                }
            }
            index += 1
        }
    }

    private mutating func apply(_ obs: BallObservation, toTrackAt index: Int) {
        tracks[index].x.update(measurement: obs.position.x)
        tracks[index].y.update(measurement: obs.position.y)
        tracks[index].radius = obs.radius
        tracks[index].lastConfidence = obs.confidence
        tracks[index].hits += 1
        tracks[index].consecutiveMisses = 0
        tracks[index].presumedMoved = false
        tracks[index].visibleMissSeconds = 0
        let votes = tracks[index].kindVotes[obs.kind] ?? 0
        if votes < config.maxKindVotes {
            tracks[index].kindVotes[obs.kind] = votes + 1
        }
        if tracks[index].hits >= config.appearanceFrames {
            tracks[index].confirmed = true
        }
    }

    /// File a retired track's identity for re-use at the same spot.
    private mutating func remember(_ track: BallTrack) {
        guard config.reidentificationDistance > 0, config.maxRememberedIdentities > 0 else {
            return
        }
        var identity = track.identity
        identity.retiredAt = clock
        // One identity per spot: a track retiring onto a remembered position
        // replaces it rather than stacking a second name on the same ball.
        dormant.removeAll {
            $0.position.distance(to: identity.position) <= config.reidentificationDistance
        }
        dormant.append(identity)
        if dormant.count > config.maxRememberedIdentities {
            dormant.removeFirst(dormant.count - config.maxRememberedIdentities)
        }
    }

    private mutating func expireDormantIdentities() {
        guard config.reidentificationMemory > 0, clock > 0 else { return }
        dormant.removeAll { clock - $0.retiredAt > config.reidentificationMemory }
    }

    /// The identity an observation inherits: the nearest retired track left
    /// within `reidentificationDistance`, if any. That radius is below one
    /// ball diameter, so at most one real ball can be there and this cannot
    /// take an identity from a different ball.
    private mutating func reclaimIdentity(at position: Vec2) -> DormantIdentity? {
        guard config.reidentificationDistance > 0 else { return nil }
        // Total order on (distance, id): never rely on sort stability, the
        // replay goldens require byte-identical tracks.
        let best = dormant.indices
            .filter {
                dormant[$0].position.distance(to: position)
                    <= config.reidentificationDistance
            }
            .min { a, b in
                let da = dormant[a].position.distance(to: position)
                let db = dormant[b].position.distance(to: position)
                if da != db { return da < db }
                return dormant[a].id.rawValue < dormant[b].id.rawValue
            }
        guard let best else { return nil }
        return dormant.remove(at: best)
    }

    private mutating func makeTrack(for obs: BallObservation) -> BallTrack {
        // A ball re-acquired where a retired one was left is that ball: it
        // keeps its id, its radius and the kind it had voted for, so the
        // player's chosen target and cue-ball designation (both keyed on
        // BallID downstream) survive a detection gap. It does NOT keep its
        // confirmation — the appearance gate runs again from scratch, so a
        // one-frame phantom over a remembered spot still earns nothing.
        let inherited = reclaimIdentity(at: obs.position)
        let id: BallID
        if let inherited {
            id = inherited.id
        } else {
            id = BallID(nextID)
            nextID += 1
        }
        var votes = inherited?.kindVotes ?? [:]
        votes[obs.kind] = min((votes[obs.kind] ?? 0) + 1, config.maxKindVotes)
        return BallTrack(
            id: id,
            x: ScalarKalman(initial: obs.position.x, initialVariance: config.measurementNoise,
                            processNoise: config.processNoise,
                            measurementNoise: config.measurementNoise),
            y: ScalarKalman(initial: obs.position.y, initialVariance: config.measurementNoise,
                            processNoise: config.processNoise,
                            measurementNoise: config.measurementNoise),
            radius: obs.radius,
            kindVotes: votes,
            lastConfidence: obs.confidence,
            hits: 1,
            consecutiveMisses: 0,
            visibleMissSeconds: 0,
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
