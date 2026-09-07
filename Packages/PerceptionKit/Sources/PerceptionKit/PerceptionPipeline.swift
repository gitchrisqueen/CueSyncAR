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
    /// World-space calibration + its raycaster. Both are re-expressed from
    /// the table anchor's current transform per frame (B3, see
    /// `followTableAnchor`) — never mutated anywhere else.
    private var calibration: TableCalibration
    private var raycaster: any PlaneRaycasting
    /// `calibration` relative to the table anchor at lock/restore time.
    /// Nil when the caller supplied no anchor transform: the calibration
    /// then stays pinned at its initial world-space value.
    private let anchoredCalibration: AnchoredCalibration?
    private let config: PerceptionConfig
    /// Playing-surface gate for both projected detections and reported
    /// balls; built once from the calibration, which is immutable here.
    private let surface: PlayingSurfaceGate
    private var tracker: BallTracker

    private var pendingFrame: CapturedFrame?
    /// Anchor transform sampled with `pendingFrame` — travels with it so a
    /// frame is always processed against the world frame it was captured in.
    private var pendingAnchorTransform: Transform3D?
    private var isProcessing = false
    private var prepared = false
    private var frameCount = 0
    private var errorCount = 0
    private var suppressedCount = 0
    #if canImport(os)
    private static let log = Logger(subsystem: "com.cuesync.ar", category: "pipeline")
    #endif

    private let stream: AsyncStream<PerceptionOutput>
    private let continuation: AsyncStream<PerceptionOutput>.Continuation

    /// One output per processed frame.
    public var outputs: AsyncStream<PerceptionOutput> { stream }

    /// - Parameter tableAnchorTransform: the table ARAnchor's transform at
    ///   the moment `calibration` was expressed (lock or relocalization).
    ///   Required for anchor following; without it the calibration is
    ///   pinned regardless of `config.followsTableAnchor`.
    public init(detector: any DetectionProviding,
                calibration: TableCalibration,
                raycaster: any PlaneRaycasting,
                config: PerceptionConfig = .default,
                trackerConfig: TrackerConfig = .default,
                tableAnchorTransform: Transform3D? = nil) {
        self.detector = detector
        self.calibration = calibration
        self.raycaster = raycaster
        self.anchoredCalibration = tableAnchorTransform.map {
            AnchoredCalibration(calibration: calibration, anchorTransform: $0)
        }
        self.config = config
        self.surface = PlayingSurfaceGate(table: Table(size: calibration.size))
        self.tracker = BallTracker(config: trackerConfig)
        (stream, continuation) = AsyncStream.makeStream(of: PerceptionOutput.self)
    }

    deinit {
        continuation.finish()
    }

    /// Offer a frame. Returns immediately; processing is asynchronous and
    /// drops stale frames (latest wins).
    /// - Parameter tableAnchorTransform: the table anchor's CURRENT
    ///   transform, sampled alongside the frame; the calibration is
    ///   re-derived from it before the frame is processed (B3). Nil keeps
    ///   the last calibration.
    public func ingest(_ frame: CapturedFrame, tableAnchorTransform: Transform3D? = nil) {
        pendingFrame = frame
        pendingAnchorTransform = tableAnchorTransform
        guard !isProcessing else { return }
        isProcessing = true
        Task { await self.drain() }
    }

    /// Process pending frames until none remain. Runs on the actor; detector
    /// inference suspends without blocking ingest.
    private func drain() async {
        while let (frame, anchorTransform) = takePending() {
            await process(frame, tableAnchorTransform: anchorTransform)
        }
        isProcessing = false
    }

    private func takePending() -> (CapturedFrame, Transform3D?)? {
        defer {
            pendingFrame = nil
            pendingAnchorTransform = nil
        }
        return pendingFrame.map { ($0, pendingAnchorTransform) }
    }

    /// B3: re-express the calibration in the world frame this frame was
    /// captured in. Skipped (calibration stays pinned) when following is
    /// off, no anchor transform came with the frame, the pipeline was
    /// built without a lock-time anchor transform, or the raycaster cannot
    /// move its plane — a frozen plane under a moving calibration would be
    /// worse than both frozen.
    private func followTableAnchor(_ transform: Transform3D?) {
        guard config.followsTableAnchor,
              let transform, let anchoredCalibration,
              let following = raycaster as? any CalibrationFollowingRaycaster else { return }
        let refreshed = anchoredCalibration.worldCalibration(anchorTransform: transform)
        guard refreshed != calibration else { return }
        calibration = refreshed
        raycaster = following.following(refreshed)
    }

    private func process(_ frame: CapturedFrame, tableAnchorTransform: Transform3D?) async {
        followTableAnchor(tableAnchorTransform)
        do {
            if !prepared {
                try await detector.prepare()
                prepared = true
            }
            // Playing-surface gate: a detection whose box is clipped by the
            // frame edge, or that matches something OFF the table (window
            // reflections, balls on a shelf), unprojects to a point far
            // outside the cloth — observed live as phantom tracks at
            // (-4.5, -3.3) on a 2.34 m table. A ball CAN sit against a
            // cushion, with its centre one radius inside the nose line, and
            // calibration is never exact, so the gate admits a small band
            // beyond that envelope and pulls those observations back onto
            // it (`PlayingSurfaceGate`). Anything further is not a ball on
            // this table and must never seed a track.
            var rejected = 0
            var clamped = 0
            let detections = try await detector.detect(in: frame)
            let observations = detections.compactMap { detection -> BallObservation? in
                // Cue-stick detections are not balls — feeding them to the
                // tracker corrupts the cue-ball estimate (stick boxes span
                // half the table). They'll drive stick-based aiming later.
                guard !detection.isCueStick else { return nil }
                guard detection.confidence >= config.confidenceFloor else { return nil }
                // Locate the ball by its SPHERE CENTER: box center ray →
                // plane lifted one ball radius → dropped to cloth. The box
                // FOOT point is biased short (boxes include the contact
                // shadow) and the bias direction follows the camera.
                let box = detection.boundingBox
                let center = Vec2(box.x + box.width / 2, box.y + box.height / 2)
                guard let world = raycaster.raycastToTablePlane(
                    imagePoint: center, frame: frame,
                    planeHeightOffset: Ball.standardRadius)
                else { return nil }
                let table = calibration.worldToTable(world)
                guard let position = surface.admit(table) else {
                    rejected += 1
                    return nil
                }
                if position != table { clamped += 1 }
                return BallObservation(kind: detection.ballKind,
                                       position: position,
                                       confidence: detection.confidence)
            }
            // Visibility-gated misses: an unmatched track only decays when
            // its spot on the cloth is actually inside this frame's view
            // (with an edge margin — boxes clip near edges). Balls are
            // static objects; pointing the camera elsewhere, or resting the
            // device on the rail, must never erase the known layout.
            let tracked = tracker.update(observations: observations,
                                         timestamp: frame.timestamp) { position in
                let world = calibration.tableToWorld(position)
                // Grazing view (device resting on the rail): sightlines run
                // nearly parallel to the cloth, detections can't project —
                // we cannot judge absence, so nothing decays. The bar for
                // JUDGING absence (~3.5°) sits below the bar for TRUSTING a
                // projection (~7°): otherwise stale tracks in the flat far
                // half of the view are frozen forever.
                let sightline = (world - frame.cameraTransform.translation).normalized
                guard abs(sightline.dot(calibration.normal)) > 0.06 else { return false }
                guard let image = raycaster.projectToImage(
                    worldPoint: world, frame: frame) else { return true }
                return image.x > 0.05 && image.x < 0.95
                    && image.y > 0.05 && image.y < 0.95
            }
            // Reporting invariant: a ball in TableState is inside the
            // playing surface, always. Tracks are smoothed ESTIMATES, not
            // observations — today's constant-position Kalman stays within
            // the hull of what it was fed, but a velocity model would
            // predict straight through a cushion, and the invariant must
            // not depend on the filter. An offending track is SUPPRESSED
            // from output, not retired: retiring loses the ball's identity
            // (and the user's cue-ball designation) over a transient wobble,
            // while a suppressed track either re-converges onto admitted
            // observations within a few frames or, unfed and in view,
            // retires through the tracker's own visible-miss grace.
            let balls = tracked.filter { surface.contains($0.position) }
            if balls.count != tracked.count {
                suppressedCount += 1
                #if canImport(os)
                if suppressedCount <= 5 || suppressedCount % 50 == 0 {
                    let offTable = tracked.filter { !surface.contains($0.position) }.map {
                        "#\($0.id.rawValue)" + String(format: "(%.3f,%.3f)", $0.position.x, $0.position.y)
                    }.joined(separator: " ")
                    Self.log.notice("frame #\(self.frameCount + 1): suppressed off-table tracks \(offTable, privacy: .public)")
                }
                #endif
            }
            let state = TableState(table: Table(size: calibration.size),
                                   balls: balls,
                                   timestamp: frame.timestamp)
            frameCount += 1
            #if canImport(os)
            if frameCount == 1 || frameCount % 40 == 0 {
                let kinds = balls.map { String(describing: $0.kind) }.joined(separator: ",")
                let summary = "detections=\(detections.count) projected=\(observations.count)"
                    + " offTable=\(rejected) railClamped=\(clamped)"
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

    /// Project stick detections' box corners onto the table plane (image
    /// order TL, TR, BR, BL) and return the strongest candidate whose quad
    /// is plausibly ON the table — rail edges also classify as "cue" and
    /// project beyond the cushions, and picking by confidence alone locked
    /// aim onto the rail (2026-07-23 device session).
    private func stickQuad(in detections: [Detection2D],
                           frame: CapturedFrame) -> [Vec2]? {
        let halfExtents = Table(size: calibration.size).halfExtents
        let candidates = detections
            .filter { $0.isCueStick && $0.confidence >= 0.3 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(4)
        for stick in candidates {
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
            guard projected.count == 4,
                  StickAim.quadOnTable(projected, halfExtents: halfExtents) else {
                continue
            }
            return projected
        }
        return nil
    }
}
