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

/// What the playing-surface gate did to one frame.
///
/// These three numbers were already computed every frame and thrown away
/// into a log line every fortieth frame. They are the offline proxy the
/// device checklist names for row 7 ("nothing renders past the cushion
/// nose"), which could not be scored without them — a log is not a
/// measurement, and nobody can read one from a table.
public struct SurfaceGateCounts: Sendable, Equatable, Codable {
    /// Projected outside the admit band entirely: reflections, balls on a
    /// shelf, bad unprojections. Never seeded a track.
    public var rejected: Int
    /// Admitted within the calibration-error band and pulled back onto the
    /// envelope — a ball resting against a cushion draws on the rail.
    public var clamped: Int
    /// Tracks that WERE outside the surface this frame and so were kept out
    /// of `TableState`. Suppressed, not retired: retiring would lose the
    /// ball's identity over a transient wobble.
    public var suppressed: Int

    public init(rejected: Int = 0, clamped: Int = 0, suppressed: Int = 0) {
        self.rejected = rejected
        self.clamped = clamped
        self.suppressed = suppressed
    }
}

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
    /// This frame's colour reading of each tracked ball, for whichever
    /// balls could be read. Empty on frames where appearance was not
    /// sampled, where no cue ball was in view to serve as the white
    /// reference, or where the frame carried no readable pixels — all of
    /// which are normal, and none of which the consumer must special-case
    /// beyond feeding what arrives to `BallIdentity`.
    public var appearances: [BallID: AppearanceObservation]
    /// This frame's raw ball detections, and the pose they were taken
    /// against.
    ///
    /// Carried out because the cloth-plane estimator needs both, and
    /// until now the only thing that fed it was the pre-tracking preview
    /// path — so the estimate froze the moment tracking started and a bad
    /// one could never recover. Measured on device: the app sat on a
    /// cloth height of -0.307 m for a whole session while the same maths
    /// over the recording of that session said -0.488.
    ///
    /// `pose` carries NO pixel buffer (ARKit's pool is tiny and the rule
    /// is that nothing outlives the frame), only the transform and
    /// intrinsics.
    public var detections: [Detection2D]
    public var pose: CapturedFrame?
    /// Mean brightness of the frame, 0...1, or nil when the frame carried
    /// no readable pixels. The HUD uses it to decide whether "more light
    /// would help" is a measurement or a guess.
    public var luminance: Double?
    /// What the playing-surface gate did to this frame.
    public var surfaceGate: SurfaceGateCounts

    public init(state: TableState, stickQuad: [Vec2]? = nil,
                detectionLabels: [String] = [],
                appearances: [BallID: AppearanceObservation] = [:],
                detections: [Detection2D] = [],
                pose: CapturedFrame? = nil,
                luminance: Double? = nil,
                surfaceGate: SurfaceGateCounts = SurfaceGateCounts()) {
        self.state = state
        self.stickQuad = stickQuad
        self.detectionLabels = detectionLabels
        self.appearances = appearances
        self.detections = detections
        self.pose = pose
        self.luminance = luminance
        self.surfaceGate = surfaceGate
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
    /// Frames whose pixel buffer the colour sampler could not read.
    private var unreadableBufferCount = 0
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

    /// Process ONE frame inline and return its output — the deterministic
    /// replay seam (SessionReplay drives this; the live path uses `ingest`).
    /// Every frame is processed, in call order, with no latest-wins
    /// dropping, so the tracker sees exactly the recorded sequence. Returns
    /// nil when the detector throws (the frame is dropped, as live). The
    /// result is NOT yielded on `outputs`. Do not interleave with `ingest`
    /// on the same instance: both mutate the tracker.
    /// - Parameter tableAnchorTransform: as for `ingest`. A recorded bundle
    ///   stores its calibration in the same world frame as its frame poses,
    ///   so replay passes nil and anchor following stays inert (B3's
    ///   `followTableAnchor` guards on a non-nil transform); a bundle that
    ///   records per-frame anchor transforms can thread them through here.
    public func processFrame(_ frame: CapturedFrame,
                             tableAnchorTransform: Transform3D? = nil) async -> PerceptionOutput? {
        await process(frame, tableAnchorTransform: tableAnchorTransform)
    }

    /// Process pending frames until none remain. Runs on the actor; detector
    /// inference suspends without blocking ingest.
    private func drain() async {
        while let (frame, anchorTransform) = takePending() {
            if let output = await process(frame, tableAnchorTransform: anchorTransform) {
                continuation.yield(output)
            }
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

    /// Anchor following runs FIRST — before anything reads `calibration`
    /// or `raycaster` — so the whole frame is processed in one world frame.
    private func process(_ frame: CapturedFrame,
                         tableAnchorTransform: Transform3D?) async -> PerceptionOutput? {
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
            var located: [LocatedDetection] = []
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
                located.append(LocatedDetection(position: position, box: box,
                                                kind: detection.ballKind))
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
            let suppressed = tracked.count - balls.count
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
            // Total order (confidence desc, label asc, detector order asc):
            // equal confidences must not depend on sort stability, or the
            // label list — part of the replay golden — could reorder.
            let labels = detections.enumerated()
                .sorted { a, b in
                    if a.element.confidence != b.element.confidence {
                        return a.element.confidence > b.element.confidence
                    }
                    if a.element.classLabel != b.element.classLabel {
                        return a.element.classLabel < b.element.classLabel
                    }
                    return a.offset < b.offset
                }
                .prefix(12)
                .map { "\($0.element.classLabel) \(Int($0.element.confidence * 100))%" }
            return PerceptionOutput(state: state,
                                    stickQuad: stickQuad(in: detections, frame: frame),
                                    detectionLabels: Array(labels),
                                    appearances: appearances(of: balls, at: located,
                                                             in: frame),
                                    detections: detections,
                                    pose: CapturedFrame(timestamp: frame.timestamp,
                                                        cameraTransform: frame.cameraTransform,
                                                        intrinsics: frame.intrinsics),
                                    luminance: luminance(of: frame),
                                    surfaceGate: SurfaceGateCounts(rejected: rejected,
                                                                   clamped: clamped,
                                                                   suppressed: suppressed))
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
            return nil
        }
    }

    /// Read this frame's colour off each tracked ball.
    ///
    /// Rate-limited rather than run every frame. Appearance is a
    /// property of the ball, not of the moment: it changes only when the
    /// ball rolls, and `BallIdentity` accumulates over dozens of looks
    /// anyway. Sampling a sixth of the frames keeps a few thousand pixel
    /// reads per second off the pipeline actor, which shares a
    /// cooperative pool with detector inference and must never be the
    /// thing that starves it.
    ///
    /// Returns empty when the frame carries no readable image — replay
    /// bundles have detections but no pixels, and appearance is simply
    /// absent there rather than fabricated.
    private func appearances(of balls: [Ball], at located: [LocatedDetection],
                             in frame: CapturedFrame) -> [BallID: AppearanceObservation] {
        guard config.colourFrameInterval > 0,
              frameCount % config.colourFrameInterval == 0 else { return [:] }
        #if canImport(CoreVideo)
        guard let image = frame.image as? PixelBufferImage else { return [:] }
        guard let result = image.withReader({ reader in
            BallAppearancePass.run(balls: balls, detections: located, image: reader,
                                   config: config.colour)
        }) else {
            // A format the reader does not understand. Colour goes quiet
            // and everything else keeps working — but never silently:
            // "no ball is ever named" with no explanation is exactly the
            // kind of thing that costs a debugging session.
            unreadableBufferCount += 1
            #if canImport(os)
            if unreadableBufferCount == 1 || unreadableBufferCount % 100 == 0 {
                Self.log.error(
                    "ball colour unavailable (#\(self.unreadableBufferCount)): unsupported pixel format")
            }
            #endif
            return [:]
        }
        return result
        #else
        return [:]
        #endif
    }

    /// Mean brightness of a frame, from a sparse grid.
    ///
    /// A grid rather than every pixel: this runs on the pipeline actor
    /// once a frame, and a few hundred samples give the mean to well
    /// inside the precision anyone needs to answer "is this room dark".
    /// Measured on the owner's table, afternoon against dusk: 0.528 and
    /// 0.399 over the whole frame.
    private func luminance(of frame: CapturedFrame) -> Double? {
        #if canImport(CoreVideo)
        guard let image = frame.image as? PixelBufferImage else { return nil }
        return image.withReader { reader -> Double? in
            let steps = 24
            guard reader.pixelWidth > steps, reader.pixelHeight > steps else { return nil }
            let dx = reader.pixelWidth / steps
            let dy = reader.pixelHeight / steps
            var total = 0.0
            var count = 0
            for row in 0..<steps {
                for column in 0..<steps {
                    guard let rgb = reader.rgb(x: column * dx, y: row * dy) else { continue }
                    // Rec. 601 luma, matching the buffers this reads.
                    total += 0.299 * rgb.x + 0.587 * rgb.y + 0.114 * rgb.z
                    count += 1
                }
            }
            return count > 0 ? total / Double(count) : nil
        } ?? nil
        #else
        return nil
        #endif
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
