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

    public init(detectionRate: Double = 15,
                appearanceFrames: Int = 3,
                disappearanceFrames: Int = 10,
                confidenceFloor: Double = 0.35) {
        self.detectionRate = detectionRate
        self.appearanceFrames = appearanceFrames
        self.disappearanceFrames = disappearanceFrames
        self.confidenceFloor = confidenceFloor
    }

    public static let `default` = PerceptionConfig()
}

public extension PlaneRaycasting {
    func projectToImage(worldPoint: Vec3, frame: CapturedFrame) -> Vec2? { nil }
}
