//
//  SessionModel.swift
//  CueSync AR
//
//  The app's single source of truth and composition root: registers the
//  default provider implementations (see docs/roadmap/02-ARCHITECTURE.md),
//  exposes session state to SwiftUI, and — while model selection (M2-01)
//  is in progress — drives the Detection Preview loop that runs a chosen
//  Roboflow hosted model against live camera frames.
//

import ARExperience
import BilliardsPhysics
import CoachKit
import CueSyncCore
import DetectionRoboflow
import Foundation
import Observation
import os
import PerceptionKit
import TableSpace
#if canImport(CoreML)
import CoreML
#endif

@MainActor
@Observable
final class SessionModel {
    enum Phase {
        case launching
        case findingTable
        case ready
    }

    struct PreviewStats {
        var latencyMilliseconds: Int = 0
        var detectionCount: Int = 0
        var lastError: String?
    }

    /// Diagnostics channel — filter the Xcode console with "cuesync".
    static let log = Logger(subsystem: "com.cuesync.ar", category: "session")

    let registry = ProviderRegistry()
    private(set) var phase: Phase = .launching
    /// Set when the user has denied camera access (drives an explicit
    /// error state instead of a silent black screen).
    var cameraDenied = false
    /// Latest AR session health message (errors/interruptions/tracking
    /// limits), mirrored from the coordinator for the HUD.
    var sessionEvent: String?

    // MARK: Calibration (M3-02)

    /// The calibration state machine (find plane → tap corners → adjust →
    /// lock). The AR layer feeds it events; views render its state.
    private(set) var calibration = CalibrationController()
    /// Corners tapped so far while waiting for all four (world space).
    private(set) var pendingCorners: [Vec3] = []
    /// Whether the calibration overlay is on screen. Calibration is
    /// re-enterable from the HUD at any time (05-UX-DESIGN).
    private(set) var calibrationVisible = false

    /// The locked world-space calibration, when one exists.
    var tableCalibration: TableCalibration? { calibration.calibration }

    func beginCalibration() {
        stopLiveTracking() // recalibration invalidates the pipeline's plane
        // Abandon the saved venue too: re-entering calibration means the
        // stored one is wrong (or the table moved). Prevents a stale bad
        // lock from relocalizing back over the fresh flow on next launch.
        CalibrationStore.clear()
        pendingCorners = []
        cornerAnchorBase = nil
        calibration.handle(.resetRequested)
        calibrationVisible = true
    }

    func cancelCalibration() {
        calibrationVisible = false
    }

    func calibrationPlaneDetected() {
        calibration.handle(.planeDetected)
    }

    /// Add one tapped corner; proposes the (perimeter-ordered) rectangle to
    /// the controller once all four are down.
    func placeCorner(_ world: Vec3, planeNormal: Vec3) {
        guard case .planeFound = calibration.state, pendingCorners.count < 4 else { return }
        pendingCorners.append(world)
        if pendingCorners.count == 4 {
            let ordered = CornerOrdering.orderedAroundCentroid(pendingCorners,
                                                               planeNormal: planeNormal)
            calibration.handle(.cornersProposed(ordered))
        }
    }

    /// Throw away tapped/proposed corners and start corner placement over
    /// (stays in the flow; the AR layer re-reports the plane on next tick).
    func restartCorners() {
        pendingCorners = []
        cornerAnchorBase = nil
        calibration.handle(.resetRequested)
    }

    // MARK: Corner anchor rebasing (mid-calibration drift)

    /// Position of the shared calibration cluster anchor when it was last
    /// synced. ARKit refines anchors as its map improves; corners rebase by
    /// the anchor's delta so the rectangle stays glued to the real cloth
    /// while the device moves mid-calibration.
    @ObservationIgnored private var cornerAnchorBase: Vec3?

    func setCornerAnchorBase(_ position: Vec3) {
        cornerAnchorBase = position
    }

    func rebaseCorners(clusterAnchorAt current: Vec3) {
        guard let base = cornerAnchorBase else { return }
        let delta = current - base
        guard delta.length > 1e-6 else { return }
        cornerAnchorBase = current
        if !pendingCorners.isEmpty {
            pendingCorners = pendingCorners.map { $0 + delta }
        }
        if case let .adjusting(corners) = calibration.state {
            for (index, corner) in corners.enumerated() {
                calibration.handle(.cornerMoved(index: index, to: corner + delta))
            }
        }
    }

    func moveCorner(index: Int, to world: Vec3) {
        calibration.handle(.cornerMoved(index: index, to: world))
    }

    /// Ask the controller to lock. On success the overlay dismisses; the
    /// caller (AR layer) then anchors + persists via `persistCalibration`.
    func requestCalibrationLock() -> Bool {
        calibration.handle(.lockRequested)
        guard calibration.isLocked else { return false }
        calibrationVisible = false
        return true
    }

    /// Persist a locked calibration relative to its world anchor so a
    /// returning visit relocalizes straight to Ready.
    func persistCalibration(_ locked: TableCalibration, anchorTransform: Transform3D) {
        CalibrationStore.save(AnchoredCalibration(calibration: locked,
                                                  anchorTransform: anchorTransform))
    }

    /// A saved venue relocalized — jump to locked (unless the user already
    /// locked a fresh calibration this session; the controller ignores it).
    func restoreCalibration(_ restored: TableCalibration) {
        calibration.handle(.restored(restored))
    }

    // MARK: Live tracking (M3-05: pipeline → solver → overlay)

    /// Latest coherent table state from the perception pipeline.
    private(set) var tableState: TableState?
    /// Latest shot prediction for the current aim; nil when no stable aim.
    private(set) var shotPrediction: ShotPrediction?
    /// CoachKit's cue-tip recommendation for the current shot.
    private(set) var shotGuide: ShotGuide?
    /// Latest cue-stick footprint (table space) from the pipeline.
    private(set) var stickQuad: [Vec2]?
    /// Where the current aim comes from: the detected cue stick when one
    /// is addressing the ball, else the device-pose sighting model.
    enum AimSource { case stick, devicePose }
    private(set) var aimSource: AimSource = .devicePose
    /// The user's called pocket (M6-02); nil = no call.
    private(set) var calledPocket: PocketID?
    /// True when the current prediction sends an object ball into the
    /// called pocket.
    private(set) var calledShotOnLine = false

    func togglePocketCall(_ pocket: PocketID) {
        calledPocket = calledPocket == pocket ? nil : pocket
        if calledPocket == nil { calledShotOnLine = false }
    }

    /// Manual cue-ball designation: the detector can miss non-plain cue
    /// balls (practice/measle balls with red dots read as color-ball).
    /// Tapping a tracked ball marks it as the cue ball by its stable track
    /// id; tapping the designated ball again clears the override.
    private(set) var designatedCueBallID: BallID?

    /// Transient feedback line for the HUD after a tap — designation
    /// success/misses must never be silent (device debugging showed taps
    /// swallowed by guards with no visible reaction).
    private(set) var tapFeedback: String?
    @ObservationIgnored private var tapFeedbackTask: Task<Void, Never>?

    func showTapFeedback(_ message: String) {
        tapFeedback = message
        tapFeedbackTask?.cancel()
        tapFeedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.tapFeedback = nil
        }
    }

    // MARK: Debug mirror (remote table-side debugging)

    /// LAN HTTP server exposing the rendered screen + tracking state, so a
    /// browser on the Mac can watch the iPad propped at the table (no cable).
    @ObservationIgnored private(set) var debugMirror: DebugMirrorServer?
    private(set) var debugMirrorURL: String?

    func toggleDebugMirror() {
        if let server = debugMirror {
            server.stop()
            debugMirror = nil
            debugMirrorURL = nil
            showTapFeedback("Debug mirror off")
            return
        }
        do {
            let server = try DebugMirrorServer()
            debugMirror = server
            let host = DebugMirrorServer.deviceIPAddress() ?? "<device-ip>"
            debugMirrorURL = "http://\(host):\(DebugMirrorServer.port)"
            Self.log.info("debug mirror at \(self.debugMirrorURL ?? "?", privacy: .public)")
        } catch {
            Self.log.error("debug mirror failed: \(String(describing: error), privacy: .public)")
            showTapFeedback("Mirror failed to start (port in use?)")
        }
    }

    /// Publish the newest rendered frame + a state snapshot (~1 Hz).
    func publishMirrorFrame(_ jpeg: Data?) {
        guard let server = debugMirror else { return }
        server.update(jpeg: jpeg, stateJSON: mirrorStateJSON())
    }

    private func mirrorStateJSON() -> Data? {
        var state: [String: Any] = [
            "liveTracking": isLiveTracking,
            "onDeviceDetection": usingOnDeviceDetection,
            "calibrationLocked": calibration.isLocked,
            "designatedCueBall": designatedCueBallID != nil,
            "aimSource": String(describing: aimSource),
            "calledShotOnLine": calledShotOnLine
        ]
        if let size = tableCalibration?.size {
            state["tableSize"] = String(format: "%.2f x %.2f m",
                                        size.playField.width, size.playField.height)
        }
        if let balls = tableState?.balls {
            state["ballCount"] = balls.count
            state["balls"] = balls.map { ball -> [String: Any] in
                ["kind": String(describing: ball.kind),
                 "x": (ball.position.x * 100).rounded() / 100,
                 "y": (ball.position.y * 100).rounded() / 100,
                 "confidence": (ball.confidence * 100).rounded() / 100]
            }
        }
        if let guide = shotGuide {
            state["shotGuide"] = guide.headline
        }
        state["hasPrediction"] = shotPrediction != nil
        if let calledPocket { state["calledPocket"] = String(describing: calledPocket) }
        if let sessionEvent { state["sessionEvent"] = sessionEvent }
        if let error = previewStats.lastError { state["lastError"] = error }
        if let tapFeedback { state["tapFeedback"] = tapFeedback }
        return try? JSONSerialization.data(withJSONObject: state,
                                           options: [.sortedKeys])
    }

    func designateCueBall(near tablePoint: Vec2, maxDistance: Double = 0.25) {
        guard let balls = tableState?.balls, !balls.isEmpty else {
            Self.log.info("designateCueBall: no tracked balls (tableState \(self.tableState == nil ? "nil" : "empty", privacy: .public))")
            showTapFeedback("No tracked balls yet — keep the table in view")
            return
        }
        guard let nearest = balls.min(by: {
            $0.position.distance(to: tablePoint) < $1.position.distance(to: tablePoint)
        }) else { return }
        let distance = nearest.position.distance(to: tablePoint)
        Self.log.info("designateCueBall: tap table=(\(tablePoint.x, format: .fixed(precision: 2)), \(tablePoint.y, format: .fixed(precision: 2))) nearest ball=(\(nearest.position.x, format: .fixed(precision: 2)), \(nearest.position.y, format: .fixed(precision: 2))) d=\(distance, format: .fixed(precision: 2))m of \(balls.count) balls")
        guard distance <= maxDistance else {
            showTapFeedback(String(format: "Nearest tracked ball is %.2f m from your tap", distance))
            return
        }
        if designatedCueBallID == nearest.id {
            designatedCueBallID = nil
            showTapFeedback("Cue-ball mark cleared")
        } else {
            designatedCueBallID = nearest.id
            showTapFeedback("Marked as cue ball")
        }
        // Re-apply immediately so the HUD/overlays react on this frame
        // instead of waiting for the next pipeline output.
        if let state = tableState {
            tableState = applyingCueDesignation(state)
        }
    }

    /// Apply the cue-ball designation to a pipeline state: the designated
    /// ball becomes .cue; any other .cue claims demote to .unknown so
    /// exactly one cue ball exists.
    private func applyingCueDesignation(_ state: TableState) -> TableState {
        guard let designatedCueBallID,
              state.balls.contains(where: { $0.id == designatedCueBallID }) else {
            return state
        }
        var adjusted = state
        adjusted.balls = state.balls.map { ball in
            var ball = ball
            if ball.id == designatedCueBallID {
                ball.kind = .cue
            } else if ball.kind == .cue {
                ball.kind = .unknown
            }
            return ball
        }
        return adjusted
    }
    @ObservationIgnored private var pipeline: PerceptionPipeline?
    @ObservationIgnored private var statesTask: Task<Void, Never>?
    /// Bundled on-device detector (M2-01/02); nil when the compiled model
    /// resource is missing (e.g. simulator-only CI builds).
    @ObservationIgnored private var onDeviceProvider: (any DetectionProviding)?
    /// True when live tracking runs on the bundled Core ML model rather
    /// than the hosted evaluation API.
    private(set) var usingOnDeviceDetection = false
    @ObservationIgnored private let aimEngine = AimEngine()
    @ObservationIgnored private let solver: any TrajectorySolving = AnalyticSolver()
    @ObservationIgnored private var lastTrackingIngestAt: Date = .distantPast

    var isLiveTracking: Bool { pipeline != nil }

    /// Build the perception pipeline once a calibration is locked and a
    /// detection provider is selected. Balls detected from then on are
    /// projected onto the locked table plane (intrinsics unprojection —
    /// no per-point ARKit raycasts) and tracked into TableState.
    func startLiveTrackingIfReady() {
        guard pipeline == nil, let calibration = tableCalibration else { return }
        // Bundled on-device model first (offline, ~15 Hz); hosted picker
        // model as evaluation fallback when the bundle resource is absent.
        guard let detector = onDeviceProvider.map({ $0 })
                ?? provider.map({ $0 as any DetectionProviding }) else {
            Self.log.error("startLiveTracking: no detector (bundled model missing AND no hosted model selected) — live tracking cannot start")
            return
        }
        usingOnDeviceDetection = onDeviceProvider != nil
        Self.log.info("startLiveTracking: detector=\(self.usingOnDeviceDetection ? "on-device BallDetector" : "hosted API", privacy: .public) table=\(calibration.size.playField.width, format: .fixed(precision: 2))x\(calibration.size.playField.height, format: .fixed(precision: 2))m")
        let newPipeline = PerceptionPipeline(
            detector: detector,
            calibration: calibration,
            raycaster: PlaneGeometryRaycaster(calibration: calibration))
        pipeline = newPipeline
        // Spatial overlays take over — stale 2D preview boxes would linger
        // frozen over the camera otherwise.
        latestDetections = []
        previewStats = PreviewStats()
        statesTask = Task { [weak self] in
            var outputCount = 0
            for await output in await newPipeline.outputs {
                outputCount += 1
                let count = outputCount
                await MainActor.run {
                    guard let self else { return }
                    self.tableState = self.applyingCueDesignation(output.state)
                    self.stickQuad = output.stickQuad
                    if count == 1 || count % 40 == 0 {
                        let state = self.tableState
                        let cue = state?.cueBall != nil
                        Self.log.info("pipeline output #\(count): balls=\(state?.balls.count ?? 0) cueBall=\(cue) stick=\(output.stickQuad != nil) designated=\(self.designatedCueBallID != nil)")
                    }
                }
            }
        }
    }

    func stopLiveTracking() {
        statesTask?.cancel()
        statesTask = nil
        pipeline = nil
        tableState = nil
        shotPrediction = nil
        shotGuide = nil
        stickQuad = nil
        aimSource = .devicePose
        calledPocket = nil
        calledShotOnLine = false
        designatedCueBallID = nil
        usingOnDeviceDetection = false
    }

    /// Feed a frame to the pipeline. On-device detection takes every frame
    /// the loop pulls (~6-7 Hz; the pipeline's latest-wins scheduling and
    /// the tracker handle the rest); the hosted API stays throttled to the
    /// quota-friendly preview cadence. No motion gate in either case:
    /// during live tracking the BALLS move while the phone may be still.
    func ingestTrackingFrame(_ frame: CapturedFrame) {
        guard let pipeline else { return }
        if !usingOnDeviceDetection {
            guard Date().timeIntervalSince(lastTrackingIngestAt) >= previewInterval else {
                return
            }
        }
        lastTrackingIngestAt = Date()
        Task { await pipeline.ingest(frame) }
    }

    /// Recompute the aim ray + shot prediction + coaching guide (called at
    /// UI cadence — solver is sub-ms). The detected cue stick wins when
    /// it's addressing the ball; the device-pose sighting model is the
    /// fallback so aiming always works without a stick in frame.
    @ObservationIgnored private var lastAimNilLogAt: Date = .distantPast

    func updateAim(cameraTransform: Transform3D) {
        guard let calibration = tableCalibration,
              let state = tableState,
              let cue = state.cueBall else {
            shotPrediction = nil
            shotGuide = nil
            // Throttled: explain WHY no guides render (the #1 question
            // when the screen shows nothing).
            if Date().timeIntervalSince(lastAimNilLogAt) > 5 {
                lastAimNilLogAt = Date()
                let reason = tableCalibration == nil ? "no calibration"
                    : tableState == nil ? "no pipeline output yet"
                    : "no cue ball among \(tableState?.balls.count ?? 0) tracked balls (tap one to mark it)"
                Self.log.info("updateAim: no guides — \(reason, privacy: .public)")
            }
            return
        }
        let aim: AimRay?
        if let stickQuad,
           let stickAim = StickAim.estimate(stickQuad: stickQuad,
                                            cueBall: cue.position) {
            aim = stickAim
            aimSource = .stick
        } else {
            aim = aimEngine.aimRay(cameraTransform: cameraTransform,
                                   cueBall: cue.position,
                                   calibration: calibration)
            aimSource = .devicePose
        }
        guard let aim else {
            shotPrediction = nil
            shotGuide = nil
            return
        }
        let prediction = solver.predict(state: state, aim: aim, options: .default)
        shotPrediction = prediction
        shotGuide = ShotGuide.recommend(state: state, prediction: prediction)
        calledShotOnLine = calledPocket.map { called in
            prediction.events.contains { event in
                if case let .pocket(ball, pocket) = event {
                    return pocket == called && ball != cue.id
                }
                return false
            }
        } ?? false
    }

    // MARK: Camera selection

    /// Detection-preview-only front camera mode (M2-01 evaluation). AR,
    /// calibration, and live tracking are back-camera features — ARKit
    /// world tracking cannot run on the front camera.
    var usingFrontCamera = false

    // MARK: Detection preview state

    /// Currently selected hosted model; nil = preview off.
    private(set) var selectedModel: RoboflowModelRef?
    private(set) var latestDetections: [Detection2D] = []
    private(set) var previewStats = PreviewStats()
    var hasRoboflowKey: Bool { !(secrets.secret(for: .roboflowAPIKey) ?? "").isEmpty }

    private let secrets: any SecretsProviding = AppSecrets()
    private var detectTask: Task<Void, Never>?
    @ObservationIgnored private var provider: RoboflowRemoteProvider?
    /// Encodes preview frames to JPEG *before* the upload task starts so the
    /// ARKit pixel buffer inside the frame is released immediately (see
    /// `ingestPreviewFrame`).
    @ObservationIgnored private var frameEncoder: (any FrameJPEGEncoding)?
    /// Skips detection passes while the camera is still: full cadence while
    /// moving, ~2 s heartbeat once settled (battery / API quota / thermals).
    @ObservationIgnored private var motionGate = MotionGate()
    /// Seconds between hosted-API calls (keep the free tier happy).
    private let previewInterval: TimeInterval = 0.5

    private static let selectedModelKey = "selectedDetectionModelID"

    func bootstrap() async {
        await registry.register(AnalyticSolver() as any TrajectorySolving)
        await registry.register(AppSecrets() as any SecretsProviding)
        // M2-01 winner, bundled: YOLOv11n on the pool-ball-agzev fork,
        // mAP50 0.896 / mAP50-95 0.765 (Linux fine-tune, epoch 19).
        // The MVP works offline on this model; the hosted picker remains
        // as evaluation tooling. Loaded OFF the main actor: MLModel init +
        // Neural Engine specialization can take seconds.
        #if canImport(CoreML)
        onDeviceProvider = await Self.loadBundledDetector()
        #endif
        phase = .findingTable
        // Restore the last-used preview model.
        if let saved = UserDefaults.standard.string(forKey: Self.selectedModelKey),
           let match = DetectionModelCatalog.candidates.first(where: { $0.id == saved }) {
            selectModel(match)
        }
    }

    func selectModel(_ model: RoboflowModelRef?) {
        selectedModel = model
        latestDetections = []
        previewStats = PreviewStats()
        UserDefaults.standard.set(model?.id, forKey: Self.selectedModelKey)
        guard let model else {
            provider = nil
            frameEncoder = nil
            return
        }
        // Fresh gate per model so a newly picked candidate detects
        // immediately even if the phone is resting on the rail.
        motionGate = MotionGate()
        let encoder = makeEncoder()
        frameEncoder = encoder
        provider = RoboflowRemoteProvider(
            model: model,
            apiKey: secrets.secret(for: .roboflowAPIKey) ?? "",
            transport: URLSessionTransport(),
            encoder: encoder)
    }

    /// Whether the preview loop should bother pulling a camera frame now.
    var wantsPreviewFrame: Bool {
        provider != nil && detectTask == nil
            && Date().timeIntervalSince(lastDetectionAt) >= previewInterval
    }

    /// Feed one camera frame into the preview loop. Skipped while a request
    /// is in flight or inside the throttle window — latest state wins.
    ///
    /// The frame wraps one of ARKit's few camera pixel buffers; retaining it
    /// across the hosted-API round trip (200–800 ms every 0.5 s) starves the
    /// capture pool — black camera feed, `(Fig) err=-12710`, and CAMetalLayer
    /// drawable failures. So: encode to JPEG synchronously (~640 px, a few ms
    /// at 2 Hz) and let `frame` die *before* any async work starts. Nothing
    /// below this method may capture `frame`.
    private var lastDetectionAt: Date = .distantPast
    func ingestPreviewFrame(_ frame: CapturedFrame) {
        guard let provider, let frameEncoder, detectTask == nil,
              Date().timeIntervalSince(lastDetectionAt) >= previewInterval else { return }
        // Motion gate: full cadence while the camera moves; slow heartbeat
        // when it's still. Uses the frame's own monotonic capture timestamp.
        // Poseless sources (front camera / plain AVCapture send .identity)
        // bypass the gate — there's no motion signal to gate on.
        if frame.cameraTransform != .identity {
            guard motionGate.shouldRunDetection(pose: frame.cameraTransform,
                                                timestamp: frame.timestamp) else { return }
        }
        lastDetectionAt = Date()
        let jpeg: Data
        do {
            jpeg = try frameEncoder.encodeJPEG(from: frame).data
        } catch {
            previewStats.lastError = shortDescription(of: error)
            return
        }
        detectTask = Task { [weak self] in
            let started = Date()
            do {
                let detections = try await provider.detect(jpegData: jpeg)
                await MainActor.run {
                    guard let self else { return }
                    self.latestDetections = detections
                    // The HUD count is BALLS, not raw boxes: cue-stick
                    // detections and low-confidence noise (server floor is
                    // 0.2 for evaluation) don't belong in "Tracking N".
                    let ballCount = detections.filter {
                        !$0.isCueStick && $0.confidence >= 0.35
                    }.count
                    self.previewStats = PreviewStats(
                        latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
                        detectionCount: ballCount,
                        lastError: nil)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.previewStats.lastError = self.shortDescription(of: error)
                }
            }
            await MainActor.run { self?.detectTask = nil }
        }
    }

    private func shortDescription(of error: Error) -> String {
        if case RoboflowError.missingAPIKey = error {
            return "No Roboflow key — add it to Secrets.xcconfig"
        }
        if case let RoboflowError.badResponse(detail) = error {
            return "API: \(detail.prefix(80))"
        }
        return String(describing: error).prefix(80).description
    }

    #if canImport(CoreML)
    /// Load the bundled BallDetector OFF the main actor (MLModel init can
    /// take seconds) and hand back the Sendable provider.
    private nonisolated static func loadBundledDetector() async -> (any DetectionProviding)? {
        await Task.detached(priority: .userInitiated) {
            guard let url = Bundle.main.url(forResource: "BallDetector",
                                            withExtension: "mlmodelc") else { return nil }
            let configuration = MLModelConfiguration()
            // CPU-only for now: the coremltools-9 mlprogram trips
            // "MLIR pass manager failed" assertions in MPSGraph when the
            // GPU/ANE graph compiler ingests it (crash at first Vision
            // request on device). YOLOv11n@640 on CPU is still far faster
            // than the hosted API. TODO(M2): re-export targeting an older
            // opset / neuralnetwork backend and restore .all.
            configuration.computeUnits = .cpuOnly
            guard let model = try? MLModel(contentsOf: url,
                                           configuration: configuration),
                  let provider = try? CoreMLDetectionProvider(model: model) else {
                return nil
            }
            return provider as (any DetectionProviding)
        }.value
    }
    #endif

    private func makeEncoder() -> any FrameJPEGEncoding {
        #if canImport(CoreImage)
        PixelBufferJPEGEncoder()
        #else
        UnsupportedEncoder()
        #endif
    }
}

#if !canImport(CoreImage)
private struct UnsupportedEncoder: FrameJPEGEncoding {
    func encodeJPEG(from frame: CapturedFrame) throws -> (data: Data, width: Int, height: Int) {
        throw RoboflowError.frameNotEncodable
    }
}
#endif

#if canImport(CoreVideo)
import CoreVideo
import PerceptionKit

// Bridge PerceptionKit's frame image type to DetectionRoboflow's encoder seam.
extension PixelBufferImage: @retroactive DetectionRoboflow.PixelBufferProviding {
    public var cvPixelBuffer: CVPixelBuffer { pixelBuffer }
}
#endif
