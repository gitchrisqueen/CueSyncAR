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
#if canImport(os)
import os
#endif

/// One processed frame's worth of perception: the coherent ball state plus
/// auxiliary (non-ball) observations like the cue stick's footprint.
public struct PerceptionOutput: Sendable {
    public var state: TableState
    /// Table-space projection of the strongest cue-stick detection's
    /// bounding-box corners, in image order TL, TR, BR, BL — StickAim's
    /// input. Nil when no stick is confidently visible.
    public var stickQuad: [Vec2]?
    /// Raw detector labels for this frame ("white-ball 82%"), strongest
    /// first — ground truth for debugging class/kind mapping live.
    public var detectionLabels: [String]

    public init(state: TableState, stickQuad: [Vec2]? = nil,
                detectionLabels: [String] = []) {
        self.state = state
        self.stickQuad = stickQuad
        self.detectionLabels = detectionLabels
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
    private var frameCount = 0
    private var errorCount = 0
    #if canImport(os)
    private static let log = Logger(subsystem: "com.cuesync.ar", category: "pipeline")
    #endif

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
            // Playing-surface gate: a detection whose box is clipped by the
            // frame edge, or that matches something OFF the table (window
            // reflections, balls on a shelf), unprojects to a point far
            // outside the cloth — observed live as phantom tracks at
            // (-4.5, -3.3) on a 2.34 m table. A ball can legitimately sit
            // against a cushion, so allow a small margin beyond half-extents.
            let bounds = Table(size: calibration.size).halfExtents
            let margin = Ball.standardRadius * 2
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
                guard abs(table.x) <= bounds.x + margin,
                      abs(table.y) <= bounds.y + margin else { return nil }
                return BallObservation(kind: detection.ballKind,
                                       position: table,
                                       confidence: detection.confidence)
            }
            let balls = tracker.update(observations: observations)
            let state = TableState(table: Table(size: calibration.size),
                                   balls: balls,
                                   timestamp: frame.timestamp)
            frameCount += 1
            #if canImport(os)
            if frameCount == 1 || frameCount % 40 == 0 {
                let kinds = balls.map { String(describing: $0.kind) }.joined(separator: ",")
                let summary = "detections=\(detections.count) projected=\(observations.count)"
                    + " confirmed=\(balls.count) kinds=[\(kinds)]"
                Self.log.info("frame #\(self.frameCount): \(summary, privacy: .public)")
                // Ball table positions — sanity-check the projection math
                // against the real cloth layout.
                if !balls.isEmpty {
                    let positions = balls.map {
                        String(format: "(%.2f,%.2f)", $0.position.x, $0.position.y)
                    }.joined(separator: " ")
                    Self.log.info("frame #\(self.frameCount): table positions \(positions, privacy: .public)")
                }
            }
            #endif
            let labels = detections
                .sorted { $0.confidence > $1.confidence }
                .prefix(12)
                .map { "\($0.classLabel) \(Int($0.confidence * 100))%" }
            continuation.yield(PerceptionOutput(state: state,
                                                stickQuad: stickQuad(in: detections,
                                                                     frame: frame),
                                                detectionLabels: Array(labels)))
        } catch {
            // A failed frame is dropped; the previous state stands — but
            // NEVER silently: a permanently-failing detector looks like
            // "no guides, no reaction" on device, which cost us a debugging
            // session to identify. Log the first few, then throttle.
            errorCount += 1
            #if canImport(os)
            if errorCount <= 5 || errorCount % 50 == 0 {
                Self.log.error("detect failed (#\(self.errorCount)): \(String(describing: error), privacy: .public)")
            }
            #endif
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
