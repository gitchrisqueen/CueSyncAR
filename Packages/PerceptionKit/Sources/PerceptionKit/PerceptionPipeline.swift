//
//  PerceptionPipeline.swift
//  PerceptionKit
//
//  Task M2-03: camera frames in → coherent TableStates out.
//  Detection runs through the injected DetectionProviding; detections are
//  projected onto the calibrated table plane via the injected raycaster and
//  TableSpace math; the BallTracker smooths and stabilizes the result.
//
//  Backpressure: latest-wins. `ingest` never queues more than one pending
//  frame — if the detector is busy, older pending frames are replaced, so
//  the pipeline degrades to a lower rate instead of building latency.
//

import CueSyncCore
import Foundation
import TableSpace

/// One processed frame's worth of perception: the coherent ball state plus
/// auxiliary (non-ball) observations like the cue stick's footprint.
public struct PerceptionOutput: Sendable {
    public var state: TableState
    /// Table-space projection of the strongest cue-stick detection's
    /// bounding-box corners, in image order TL, TR, BR, BL — StickAim's
    /// input. Nil when no stick is confidently visible.
    public var stickQuad: [Vec2]?

    public init(state: TableState, stickQuad: [Vec2]? = nil) {
        self.state = state
        self.stickQuad = stickQuad
    }
}

public actor PerceptionPipeline {
    private let detector: any DetectionProviding
    private let calibration: TableCalibration
    private let raycaster: any PlaneRaycasting
    private let config: PerceptionConfig
    private var tracker: BallTracker

    private var pendingFrame: CapturedFrame?
    private var isProcessing = false
    private var prepared = false

    private let stream: AsyncStream<PerceptionOutput>
    private let continuation: AsyncStream<PerceptionOutput>.Continuation

    /// One output per processed frame.
    public var outputs: AsyncStream<PerceptionOutput> { stream }

    public init(detector: any DetectionProviding,
                calibration: TableCalibration,
                raycaster: any PlaneRaycasting,
                config: PerceptionConfig = .default,
                trackerConfig: TrackerConfig = .default) {
        self.detector = detector
        self.calibration = calibration
        self.raycaster = raycaster
        self.config = config
        self.tracker = BallTracker(config: trackerConfig)
        (stream, continuation) = AsyncStream.makeStream(of: PerceptionOutput.self)
    }

    deinit {
        continuation.finish()
    }

    /// Offer a frame. Returns immediately; processing is asynchronous and
    /// drops stale frames (latest wins).
    public func ingest(_ frame: CapturedFrame) {
        pendingFrame = frame
        guard !isProcessing else { return }
        isProcessing = true
        Task { await self.drain() }
    }

    /// Process pending frames until none remain. Runs on the actor; detector
    /// inference suspends without blocking ingest.
    private func drain() async {
        while let frame = takePending() {
            await process(frame)
        }
        isProcessing = false
    }

    private func takePending() -> CapturedFrame? {
        defer { pendingFrame = nil }
        return pendingFrame
    }

    private func process(_ frame: CapturedFrame) async {
        do {
            if !prepared {
                try await detector.prepare()
                prepared = true
            }
            let detections = try await detector.detect(in: frame)
            let observations = detections.compactMap { detection -> BallObservation? in
                // Cue-stick detections are not balls — feeding them to the
                // tracker corrupts the cue-ball estimate (stick boxes span
                // half the table). They'll drive stick-based aiming later.
                guard !detection.isCueStick else { return nil }
                guard detection.confidence >= config.confidenceFloor else { return nil }
                // The bounding box's bottom-center is where the ball meets
                // the cloth — the right point to project onto the plane.
                guard let world = raycaster.raycastToTablePlane(
                    imagePoint: detection.boundingBox.footPoint, frame: frame)
                else { return nil }
                let table = calibration.worldToTable(world)
                return BallObservation(kind: detection.ballKind,
                                       position: table,
                                       confidence: detection.confidence)
            }
            let balls = tracker.update(observations: observations)
            let state = TableState(table: Table(size: calibration.size),
                                   balls: balls,
                                   timestamp: frame.timestamp)
            continuation.yield(PerceptionOutput(state: state,
                                                stickQuad: stickQuad(in: detections,
                                                                     frame: frame)))
        } catch {
            // A failed frame is dropped; the previous state stands. The
            // detector's own health surfaces through HUDStatus (M3-05).
        }
    }

    /// Project the strongest stick detection's box corners onto the table
    /// plane (image order TL, TR, BR, BL) for StickAim.
    private func stickQuad(in detections: [Detection2D],
                           frame: CapturedFrame) -> [Vec2]? {
        guard let stick = detections.filter({ $0.isCueStick && $0.confidence >= 0.3 })
            .max(by: { $0.confidence < $1.confidence }) else { return nil }
        let box = stick.boundingBox
        let corners = [
            Vec2(box.x, box.y),
            Vec2(box.x + box.width, box.y),
            Vec2(box.x + box.width, box.y + box.height),
            Vec2(box.x, box.y + box.height)
        ]
        let projected = corners.compactMap { corner -> Vec2? in
            raycaster.raycastToTablePlane(imagePoint: corner, frame: frame)
                .map(calibration.worldToTable)
        }
        return projected.count == 4 ? projected : nil
    }
}
