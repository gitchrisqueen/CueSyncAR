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
        guard motionGate.shouldRunDetection(pose: frame.cameraTransform,
                                            timestamp: frame.timestamp) else { return }
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
                    self.previewStats = PreviewStats(
                        latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
                        detectionCount: detections.count,
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
