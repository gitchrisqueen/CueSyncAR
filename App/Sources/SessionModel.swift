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
import PerceptionKit
import TableSpace

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
        calibration.handle(.resetRequested)
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
    @ObservationIgnored private var pipeline: PerceptionPipeline?
    @ObservationIgnored private var statesTask: Task<Void, Never>?
    @ObservationIgnored private let aimEngine = AimEngine()
    @ObservationIgnored private let solver: any TrajectorySolving = AnalyticSolver()
    @ObservationIgnored private var lastTrackingIngestAt: Date = .distantPast

    var isLiveTracking: Bool { pipeline != nil }

    /// Build the perception pipeline once a calibration is locked and a
    /// detection provider is selected. Balls detected from then on are
    /// projected onto the locked table plane (intrinsics unprojection —
    /// no per-point ARKit raycasts) and tracked into TableState.
    func startLiveTrackingIfReady() {
        guard pipeline == nil, let calibration = tableCalibration,
              let provider else { return }
        let newPipeline = PerceptionPipeline(
            detector: provider,
            calibration: calibration,
            raycaster: PlaneGeometryRaycaster(calibration: calibration))
        pipeline = newPipeline
        statesTask = Task { [weak self] in
            for await state in await newPipeline.states {
                await MainActor.run { self?.tableState = state }
            }
        }
    }

    func stopLiveTracking() {
        statesTask?.cancel()
        statesTask = nil
        pipeline = nil
        tableState = nil
        shotPrediction = nil
    }

    /// Feed a frame to the pipeline, throttled to the hosted-API-friendly
    /// preview cadence. No motion gate here: during live tracking the BALLS
    /// move while the phone may be still — scene changes matter.
    func ingestTrackingFrame(_ frame: CapturedFrame) {
        guard let pipeline,
              Date().timeIntervalSince(lastTrackingIngestAt) >= previewInterval else { return }
        lastTrackingIngestAt = Date()
        Task { await pipeline.ingest(frame) }
    }

    /// Recompute the aim ray + shot prediction + coaching guide from the
    /// current device pose (called at UI cadence — solver is sub-ms).
    func updateAim(cameraTransform: Transform3D) {
        guard let calibration = tableCalibration,
              let state = tableState,
              let cue = state.cueBall,
              let aim = aimEngine.aimRay(cameraTransform: cameraTransform,
                                         cueBall: cue.position,
                                         calibration: calibration) else {
            shotPrediction = nil
            shotGuide = nil
            return
        }
        let prediction = solver.predict(state: state, aim: aim, options: .default)
        shotPrediction = prediction
        shotGuide = ShotGuide.recommend(state: state, prediction: prediction)
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
