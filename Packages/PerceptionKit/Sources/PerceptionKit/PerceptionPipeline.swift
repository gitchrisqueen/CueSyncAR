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

public actor PerceptionPipeline {
    private let detector: any DetectionProviding
    private let calibration: TableCalibration
    private let raycaster: any PlaneRaycasting
    private let config: PerceptionConfig
    private var tracker: BallTracker

    private var pendingFrame: CapturedFrame?
    private var isProcessing = false
    private var prepared = false

    private let stream: AsyncStream<TableState>
    private let continuation: AsyncStream<TableState>.Continuation

    /// Confirmed table states, one per processed frame.
    public var states: AsyncStream<TableState> { stream }

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
        (stream, continuation) = AsyncStream.makeStream(of: TableState.self)
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
            continuation.yield(state)
        } catch {
            // A failed frame is dropped; the previous state stands. The
            // detector's own health surfaces through HUDStatus (M3-05).
        }
    }
}
