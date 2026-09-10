//
//  DetectionPreviewModel.swift
//  CueSync AR
//
//  The hosted-model Detection Preview loop (M2-01 evaluation tooling),
//  lifted out of `SessionModel` so that file stays under SwiftLint's
//  1000-line ceiling. It is a self-contained concern: pick a Roboflow
//  model, run it against live camera frames on a throttle, publish the
//  boxes and a latency number. Nothing else in the app depends on it —
//  the MVP runs offline on the bundled Core ML detector.
//
//  It is its own `@Observable` rather than an extension because the
//  state it owns is *stored*, and `@Observable` instruments only the
//  class body: stored properties cannot move to an extension file.
//  `SessionModel` forwards the handful of members the views read, so the
//  views keep talking to one façade and this split stays invisible to
//  them.
//
//  The camera-buffer rule in `ingestPreviewFrame` is load-bearing and is
//  restated there; do not let a frame outlive the synchronous encode.
//

import CueSyncCore
import DetectionRoboflow
import Foundation
import Observation
import PerceptionKit

@MainActor
@Observable
final class DetectionPreviewModel {

    struct PreviewStats {
        var latencyMilliseconds: Int = 0
        var detectionCount: Int = 0
        var lastError: String?
    }

    /// Currently selected hosted model; nil = preview off.
    private(set) var selectedModel: RoboflowModelRef?
    private(set) var latestDetections: [Detection2D] = []
    private(set) var previewStats = PreviewStats()
    var hasRoboflowKey: Bool { !(secrets.secret(for: .roboflowAPIKey) ?? "").isEmpty }

    /// Handed each successful pass on the main actor, so the session can
    /// fold the boxes into cloth-plane estimation. A closure rather than a
    /// back-reference: this type must not know what a `SessionModel` is.
    ///
    /// The frame passed here is pose-and-intrinsics only — it carries no
    /// pixel buffer, by construction (see `ingestPreviewFrame`).
    @ObservationIgnored var onDetections: (([Detection2D], CapturedFrame) -> Void)?

    /// Builds the JPEG encoder. Injected because the concrete encoder is
    /// platform-conditional and `SessionModel` already owns that choice.
    @ObservationIgnored private let makeEncoder: @MainActor () -> any FrameJPEGEncoding

    private let secrets: any SecretsProviding
    @ObservationIgnored private var detectTask: Task<Void, Never>?
    @ObservationIgnored private var provider: RoboflowRemoteProvider?
    /// Encodes preview frames to JPEG *before* the upload task starts so the
    /// ARKit pixel buffer inside the frame is released immediately (see
    /// `ingestPreviewFrame`).
    @ObservationIgnored private var frameEncoder: (any FrameJPEGEncoding)?
    /// Skips detection passes while the camera is still: full cadence while
    /// moving, ~2 s heartbeat once settled (battery / API quota / thermals).
    @ObservationIgnored private var motionGate = MotionGate()
    /// Seconds between hosted-API calls (keep the free tier happy).
    @ObservationIgnored private let previewInterval: TimeInterval = 0.5
    @ObservationIgnored private var lastDetectionAt: Date = .distantPast

    private static let selectedModelKey = "selectedDetectionModelID"

    init(secrets: any SecretsProviding,
         makeEncoder: @escaping @MainActor () -> any FrameJPEGEncoding) {
        self.secrets = secrets
        self.makeEncoder = makeEncoder
    }

    /// Restore the last-used preview model. Called from `bootstrap()`.
    func restoreSelectedModel() {
        guard let saved = UserDefaults.standard.string(forKey: Self.selectedModelKey),
              let match = DetectionModelCatalog.candidates.first(where: { $0.id == saved })
        else { return }
        selectModel(match)
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

    /// Drop the published boxes and stats without touching the selected
    /// model. Called when live tracking takes over: spatial overlays replace
    /// the 2-D preview, and stale boxes would otherwise linger frozen over
    /// the camera.
    func clearPreviewOutput() {
        latestDetections = []
        previewStats = PreviewStats()
    }

    /// The selected hosted provider, if any, as the generic detection seam.
    /// Live tracking borrows it when Settings prefers the hosted detector —
    /// which is why this type owns the provider but does not own the choice.
    var hostedProvider: (any DetectionProviding)? { provider }

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
        // Pose and intrinsics only — a value type. The rule above forbids
        // capturing `frame` itself past this point because it wraps one of
        // ARKit's few pixel buffers; this copy holds no buffer.
        let poseOnly = CapturedFrame(timestamp: frame.timestamp,
                                     cameraTransform: frame.cameraTransform,
                                     intrinsics: frame.intrinsics)
        let jpeg: Data
        do {
            jpeg = try frameEncoder.encodeJPEG(from: frame).data
        } catch {
            previewStats.lastError = Self.shortDescription(of: error)
            return
        }
        detectTask = Task { [weak self] in
            let started = Date()
            do {
                let detections = try await provider.detect(jpegData: jpeg)
                await MainActor.run {
                    guard let self else { return }
                    self.latestDetections = detections
                    self.onDetections?(detections, poseOnly)
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
                    self.previewStats.lastError = Self.shortDescription(of: error)
                }
            }
            await MainActor.run { self?.detectTask = nil }
        }
    }

    static func shortDescription(of error: Error) -> String {
        if case RoboflowError.missingAPIKey = error {
            return "No Roboflow key — add it to Secrets.xcconfig"
        }
        if case let RoboflowError.badResponse(detail) = error {
            return "API: \(detail.prefix(80))"
        }
        return String(describing: error).prefix(80).description
    }
}
