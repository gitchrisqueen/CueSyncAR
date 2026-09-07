//
//  SyntheticDetectionProvider.swift
//  CueSyncTestSupport
//
//  DetectionProviding over a synthetic scene: balls at exact table
//  positions, imaged by SyntheticBallImager into the boxes a detector would
//  emit. Feeds the real provider seam (PerceptionPipeline never knows), so
//  the whole box → foot/centre → unprojection → table-space chain runs with
//  known ground truth and zero hardware.
//

import CueSyncCore
import Foundation
import TableSpace

/// One ball in a synthetic scene.
public struct SyntheticBall: Sendable, Equatable {
    /// Ground-truth centre on the cloth, table space.
    public var position: Vec2
    /// Detector class label (dataset semantics: "white-ball" = cue ball,
    /// "color-ball" = object ball, "cue" = the STICK).
    public var label: String
    public var confidence: Double

    public init(position: Vec2, label: String = "color-ball", confidence: Double = 0.95) {
        self.position = position
        self.label = label
        self.confidence = confidence
    }
}

/// Which camera images the scene.
public enum SyntheticImagingSource: Sendable, Equatable {
    /// Image with the pose + intrinsics carried by each incoming frame — the
    /// self-consistent case (what ARKit delivers).
    case frame
    /// Image with THIS camera regardless of what the frame claims — the
    /// mismatch case (frame intrinsics/orientation disagree with the
    /// camera that actually produced the boxes).
    case fixed(SyntheticCamera)
}

/// Synthetic detections for any frame. Pure value type; `prepare` is a
/// no-op and `detect` is deterministic.
public struct SyntheticDetectionProvider: DetectionProviding {
    /// TRUE table geometry the balls rest on.
    public var calibration: TableCalibration
    public var balls: [SyntheticBall]
    public var imaging: SyntheticImagingSource
    /// Orientation applied to boxes when imaging from the frame (`.fixed`
    /// cameras carry their own).
    public var orientation: ImageOrientation
    public var ballRadius: Double

    public init(calibration: TableCalibration,
                balls: [SyntheticBall],
                imaging: SyntheticImagingSource = .frame,
                orientation: ImageOrientation = .up,
                ballRadius: Double = Ball.standardRadius) {
        self.calibration = calibration
        self.balls = balls
        self.imaging = imaging
        self.orientation = orientation
        self.ballRadius = ballRadius
    }

    public func prepare() async throws {}

    /// The camera that images `frame`, or nil when the frame carries no
    /// intrinsics and no fixed camera stands in (nothing can be imaged).
    public func camera(for frame: CapturedFrame) -> SyntheticCamera? {
        switch imaging {
        case .fixed(let camera):
            return camera
        case .frame:
            guard let intrinsics = frame.intrinsics else { return nil }
            return SyntheticCamera(intrinsics: intrinsics,
                                   transform: frame.cameraTransform,
                                   orientation: orientation)
        }
    }

    /// Boxes for every ball whose silhouette is a bounded ellipse and whose
    /// centre lands inside the image. Frames without intrinsics yield [].
    public func detect(in frame: CapturedFrame) async throws -> [Detection2D] {
        guard let camera = camera(for: frame) else { return [] }
        let imager = SyntheticBallImager(camera: camera, calibration: calibration,
                                         ballRadius: ballRadius)
        return balls.compactMap { ball in
            guard let silhouette = imager.silhouette(ballAt: ball.position),
                  camera.contains(normalized: silhouette.box.center)
            else { return nil }
            return Detection2D(classLabel: ball.label,
                               boundingBox: silhouette.box,
                               confidence: ball.confidence)
        }
    }
}
