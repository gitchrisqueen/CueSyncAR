//
//  FrameAnalyzer.swift
//  CueSync AR
//
//  One clip's perception + planning state. Per frame:
//    CoreMLDetectionProvider -> ball detections -> homography to the cloth
//    -> the REAL BallTracker -> TableState -> ShotPlanner.plan + select.
//  PerceptionPipeline itself is not used: it is welded to PlaneRaycasting
//  and CapturedFrame camera poses, which video has not got. Its per-frame
//  gates (confidence floor, cue sticks are not balls, off-table rejection)
//  and BallTracker call are reproduced here; the tracker is the app's own
//  value type, so tracking behavior is real.
//

import CoachKit
import CueSyncCore
import Foundation
import PerceptionKit
import CoreGraphics

/// Which point of a ball's bounding box is mapped through the homography.
public enum BallAnchor: String, Sendable {
    /// Bottom-center of the box: the nearest thing to the cloth contact point.
    case foot
    /// Box center: closer to the sphere center for a near top-down camera.
    case center
}

public enum CueStatus: Sendable, Equatable {
    case ok
    case missing
    case ambiguous(Int)

    public var isOK: Bool { self == .ok }
}

public struct FrameResult: Sendable {
    public var index: Int
    public var imageSize: CGSize
    /// Everything the detector returned at or above the draw floor.
    public var detections: [Detection2D]
    /// Ball detections that passed the confidence floor, class gate and
    /// off-table gate (these fed the tracker).
    public var usedObservations: Int
    /// Of those, how many were classified `white-ball` (the cue ball).
    public var cueObservations: Int
    public var rejectedOffTable: Int
    /// Per used observation: detector box width / ball diameter predicted by
    /// the homography at that spot. ~1 (a little over: boxes include the
    /// shadow) means the calibration scale agrees with the ball size.
    public var scaleRatios: [Double]
    public var tracked: [Ball]
    public var cueStatus: CueStatus
    public var stickDetections: Int
    /// A stick detection whose projected box quad passes StickAim.quadOnTable.
    public var stickOnTable: Bool
    public var options: [ShotOption]
    public var selected: ShotOption?
}

public struct AnalyzerConfig: Sendable {
    public var minConfidence: Double
    public var drawFloor: Double
    public var anchor: BallAnchor
    public var tracker: TrackerConfig

    public init(minConfidence: Double = PerceptionConfig.default.confidenceFloor,
                drawFloor: Double = 0.25,
                anchor: BallAnchor = .foot,
                tracker: TrackerConfig = .default) {
        self.minConfidence = minConfidence
        self.drawFloor = drawFloor
        self.anchor = anchor
        self.tracker = tracker
    }
}

public final class FrameAnalyzer {
    private let detector: any DetectionProviding
    private let geometry: ClipGeometry
    private let config: AnalyzerConfig
    private var tracker: BallTracker
    private var previousSelection: String?
    private var frameIndex = 0

    public init(detector: any DetectionProviding, geometry: ClipGeometry,
                config: AnalyzerConfig = AnalyzerConfig()) {
        self.detector = detector
        self.geometry = geometry
        self.config = config
        self.tracker = BallTracker(config: config.tracker)
    }

    public func process(image: CGImage) async throws -> FrameResult {
        let buffer = try FrameIO.pixelBuffer(from: image)
        let frame = CapturedFrame(timestamp: Double(frameIndex), cameraTransform: .identity,
                                  image: PixelBufferImage(pixelBuffer: buffer))
        let all = try await detector.detect(in: frame)
        let detections = all.filter { $0.confidence >= config.drawFloor }
        let size = CGSize(width: image.width, height: image.height)

        // Same gates as PerceptionPipeline.process: sticks are not balls, a
        // confidence floor, and nothing far outside the cloth.
        let bounds = geometry.table.halfExtents
        let margin = Ball.standardRadius * 2
        var rejected = 0
        var scaleRatios: [Double] = []
        var observations: [BallObservation] = []
        for detection in detections where !detection.isCueStick
            && detection.confidence >= config.minConfidence {
            guard let table = tablePoint(of: detection, imageSize: size) else {
                rejected += 1
                continue
            }
            guard abs(table.x) <= bounds.x + margin, abs(table.y) <= bounds.y + margin else {
                rejected += 1
                continue
            }
            observations.append(BallObservation(kind: detection.ballKind, position: table,
                                                confidence: detection.confidence))
            if let expected = predictedDiameterPixels(at: table) {
                scaleRatios.append(detection.boundingBox.width * Double(size.width) / expected)
            }
        }
        let tracked = tracker.update(observations: observations)

        // Cue ball: exactly one `white-ball` track, else no plan (and say so).
        let cueCount = tracked.filter { $0.kind == .cue }.count
        let cueStatus: CueStatus = cueCount == 1 ? .ok : (cueCount == 0 ? .missing : .ambiguous(cueCount))
        var options: [ShotOption] = []
        if cueStatus.isOK {
            let state = TableState(table: geometry.table, balls: tracked, timestamp: Double(frameIndex))
            options = ShotPlanner.plan(state: state)
        }
        let selected = ShotPlanner.select(previous: previousSelection, among: options)
        previousSelection = selected?.id

        let sticks = detections.filter { $0.isCueStick && $0.confidence >= 0.3 }
        let result = FrameResult(
            index: frameIndex, imageSize: size, detections: detections,
            usedObservations: observations.count,
            cueObservations: observations.filter { $0.kind == .cue }.count,
            rejectedOffTable: rejected, scaleRatios: scaleRatios,
            tracked: tracked, cueStatus: cueStatus,
            stickDetections: sticks.count, stickOnTable: stickOnTable(sticks, imageSize: size),
            options: options, selected: selected)
        frameIndex += 1
        return result
    }

    /// Box anchor in pixels -> table space through the homography.
    private func tablePoint(of detection: Detection2D, imageSize: CGSize) -> Vec2? {
        let box = detection.boundingBox
        let y = config.anchor == .foot ? box.y + box.height : box.y + box.height / 2
        let pixel = Vec2((box.x + box.width / 2) * Double(imageSize.width), y * Double(imageSize.height))
        return geometry.imageToTable.apply(pixel)
    }

    /// Pixel diameter of a standard ball on the cloth at `table`, averaged over
    /// the image of its x and y extents.
    private func predictedDiameterPixels(at table: Vec2) -> Double? {
        let radius = Ball.standardRadius
        let map = geometry.tableToImage
        guard let xPlus = map.apply(table + Vec2(radius, 0)), let xMinus = map.apply(table - Vec2(radius, 0)),
              let yPlus = map.apply(table + Vec2(0, radius)), let yMinus = map.apply(table - Vec2(0, radius))
        else { return nil }
        return (xPlus.distance(to: xMinus) + yPlus.distance(to: yMinus)) / 2
    }

    private func stickOnTable(_ sticks: [Detection2D], imageSize: CGSize) -> Bool {
        sticks.contains { stick in
            let box = stick.boundingBox
            let corners = [Vec2(box.x, box.y), Vec2(box.x + box.width, box.y),
                           Vec2(box.x + box.width, box.y + box.height), Vec2(box.x, box.y + box.height)]
            let projected = corners.compactMap {
                geometry.imageToTable.apply(Vec2($0.x * Double(imageSize.width), $0.y * Double(imageSize.height)))
            }
            return projected.count == 4
                && StickAim.quadOnTable(projected, halfExtents: geometry.table.halfExtents)
        }
    }
}
