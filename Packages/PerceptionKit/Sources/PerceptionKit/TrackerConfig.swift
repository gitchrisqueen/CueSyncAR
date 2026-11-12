//
//  TrackerConfig.swift
//  PerceptionKit
//
//  Tuning for `BallTracker`: association gate, confirmation and retirement
//  budgets, re-identification, Kalman noise.
//

import CueSyncCore
import Foundation

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
    /// Sparse-detection tolerance; 0 (off) by default.
    ///
    /// A far-row ball the detector reports on 2 frames in 5 (confidence
    /// hovering at the pipeline floor) was retired between sightings: a stray
    /// detection anywhere puts every unmatched track on the short strike
    /// budget, and the ball died before its third sighting, so every restart
    /// minted a fresh id. With this above 0 (`tolerantOfSparseDetection()`
    /// uses 6), unconfirmed tracks skip the strike budget and a confirmed
    /// track is never retired for missing fewer than this many of its OWN
    /// longest recent detection gaps. A ball seen every frame keeps the plain
    /// budgets.
    ///
    /// Off by default because it changes which intermittent detections earn a
    /// track: on the recorded aiming clips the held tracks re-solve the shot
    /// plan more often (planChangedRate 0.2367 against the 0.23 bar). The app
    /// turns it on when the far tile is on, which is what makes a far-row ball
    /// sparse in the first place.
    public var gapGraceMultiple: Double
    /// Ceiling (seconds) on that gap-scaled budget, so a ball that really
    /// was struck away cannot leave its phantom ring up indefinitely.
    public var gapGraceCeiling: TimeInterval
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
                gapGraceMultiple: Double = 0,
                gapGraceCeiling: TimeInterval = 6,
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
        self.gapGraceMultiple = gapGraceMultiple
        self.gapGraceCeiling = gapGraceCeiling
        self.reidentificationDistance = reidentificationDistance
        self.reidentificationMemory = reidentificationMemory
        self.maxRememberedIdentities = maxRememberedIdentities
        self.processNoise = processNoise
        self.measurementNoise = measurementNoise
        self.maxKindVotes = maxKindVotes
    }

    public static let `default` = TrackerConfig()

    /// This configuration with sparse-detection tolerance on.
    public func tolerantOfSparseDetection() -> TrackerConfig {
        var tolerant = self
        tolerant.gapGraceMultiple = 6
        return tolerant
    }
}
