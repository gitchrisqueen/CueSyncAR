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

import BilliardsPhysics
import CueSyncCore
import DetectionRoboflow
import Foundation
import Observation

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

    // MARK: Detection preview state

    /// Currently selected hosted model; nil = preview off.
    private(set) var selectedModel: RoboflowModelRef?
    private(set) var latestDetections: [Detection2D] = []
    private(set) var previewStats = PreviewStats()
    var hasRoboflowKey: Bool { !(secrets.secret(for: .roboflowAPIKey) ?? "").isEmpty }

    private let secrets: any SecretsProviding = AppSecrets()
    private var detectTask: Task<Void, Never>?
    @ObservationIgnored private var provider: RoboflowRemoteProvider?
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
            return
        }
        provider = RoboflowRemoteProvider(
            model: model,
            apiKey: secrets.secret(for: .roboflowAPIKey) ?? "",
            transport: URLSessionTransport(),
            encoder: makeEncoder())
    }

    /// Feed one camera frame into the preview loop. Skipped while a request
    /// is in flight or inside the throttle window — latest state wins.
    private var lastDetectionAt: Date = .distantPast
    func ingestPreviewFrame(_ frame: CapturedFrame) {
        guard let provider, detectTask == nil,
              Date().timeIntervalSince(lastDetectionAt) >= previewInterval else { return }
        lastDetectionAt = Date()
        detectTask = Task { [weak self] in
            let started = Date()
            do {
                let detections = try await provider.detect(in: frame)
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
