//
//  PerceptionKit.swift
//  PerceptionKit
//
//  Perception pipeline: detection scheduling, image→table projection, and
//  multi-frame ball tracking. Implementation lands in milestone M2 (tasks
//  M2-02/M2-03, see docs/roadmap/06-MILESTONES.md). The seams below are part
//  of the frozen contract so ARExperience and fixtures can build against them.
//

import CueSyncCore
import Foundation

/// Raycasts an image-space point onto the calibrated table plane, returning
/// a world-space hit. ARExperience provides the ARKit implementation;
/// fixtures provide scripted ones. Injected so the pipeline stays testable.
public protocol PlaneRaycasting: Sendable {
    /// `point` is in normalized image coordinates (0...1, top-left origin).
    func raycastToTablePlane(imagePoint: Vec2, frame: CapturedFrame) -> Vec3?
    /// Forward projection (world → normalized image point). Optional
    /// capability: implementations that can't invert their raycast return
    /// nil, and callers must treat "unknown" as "assume visible".
    func projectToImage(worldPoint: Vec3, frame: CapturedFrame) -> Vec2?
    /// Height-aware raycast: intersect a plane lifted `planeHeightOffset`
    /// above the cloth and drop the hit back to cloth level (the sphere-
    /// centre method, see `PlaneGeometryRaycaster`).
    ///
    /// This is a protocol REQUIREMENT, not merely the extension method
    /// below, because the pipeline holds its raycaster as
    /// `any PlaneRaycasting`. As an extension-only method the call bound
    /// statically to the fallback, the lift never engaged, and every ball
    /// projected r / tan(elevation) long — 6.1 cm at 25 degrees of camera
    /// elevation, 2.9 cm at 45. The extension below stays as the default so
    /// implementations without the capability keep working unchanged.
    func raycastToTablePlane(imagePoint: Vec2, frame: CapturedFrame,
                             planeHeightOffset: Double) -> Vec3?
}

public struct PerceptionConfig: Sendable, Equatable {
    /// Target detector cadence, Hz. Frames beyond this are dropped
    /// (latest-wins) rather than queued.
    public var detectionRate: Double
    /// Frames a ball must persist before it appears in TableState.
    public var appearanceFrames: Int
    /// Missed frames before a tracked ball is dropped.
    public var disappearanceFrames: Int
    /// Minimum detector confidence to consider at all.
    public var confidenceFloor: Double
    /// B3: re-express the table calibration from the table anchor's
    /// CURRENT transform on every frame that carries one (see
    /// `PerceptionPipeline.ingest(_:tableAnchorTransform:)`). ARKit keeps
    /// refining anchors as its map improves, while camera poses always
    /// arrive in the refined world frame — a calibration frozen at lock
    /// time then projects balls into a stale table frame. OFF reproduces
    /// the frozen-at-lock behaviour so the two can be A/B'd at the table.
    public var followsTableAnchor: Bool
    /// Sample each tracked ball's COLOUR every Nth frame; 0 disables it.
    ///
    /// Not `appearanceFrames` above, which is about persistence — this
    /// is the sampler that reads pixels off the ball to tell a stripe
    /// from a solid. Rate-limited because colour is a property of the
    /// ball rather than of the moment, and because the reads happen on
    /// the pipeline actor, which shares a cooperative pool with detector
    /// inference.
    public var colourFrameInterval: Int
    /// How ball colour is sampled and classified.
    public var colour: BallAppearancePass.Config
    /// Skip detection on frames whose picture has not changed. Applies to
    /// the LIVE path only — the replay seam processes every frame, so
    /// goldens stay deterministic.
    public var frameChange: FrameChangeGate.Config
    /// Whether that gate runs at all. Switchable from the debug mirror,
    /// because it is a perception change and the first thing to try when
    /// something looks stale is turning it off.
    public var skipsUnchangedFrames: Bool

    public init(detectionRate: Double = 15,
                appearanceFrames: Int = 3,
                disappearanceFrames: Int = 10,
                confidenceFloor: Double = 0.35,
                followsTableAnchor: Bool = true,
                colourFrameInterval: Int = 6,
                colour: BallAppearancePass.Config = .default,
                frameChange: FrameChangeGate.Config = FrameChangeGate.Config(),
                skipsUnchangedFrames: Bool = true) {
        self.detectionRate = detectionRate
        self.appearanceFrames = appearanceFrames
        self.disappearanceFrames = disappearanceFrames
        self.confidenceFloor = confidenceFloor
        self.followsTableAnchor = followsTableAnchor
        self.frameChange = frameChange
        self.skipsUnchangedFrames = skipsUnchangedFrames
        self.colourFrameInterval = colourFrameInterval
        self.colour = colour
    }

    public static let `default` = PerceptionConfig()
}

public extension PlaneRaycasting {
    func projectToImage(worldPoint: Vec3, frame: CapturedFrame) -> Vec2? { nil }

    /// Height-aware raycast (see PlaneGeometryRaycaster). Implementations
    /// without the capability fall back to the cloth-plane raycast.
    func raycastToTablePlane(imagePoint: Vec2, frame: CapturedFrame,
                             planeHeightOffset: Double) -> Vec3? {
        raycastToTablePlane(imagePoint: imagePoint, frame: frame)
    }
}
