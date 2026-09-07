//
//  SessionModel+Providers.swift
//  CueSync AR
//
//  Provider plumbing split out of SessionModel.swift to keep the
//  composition root under SwiftLint's file_length limit: bundled on-device
//  detector loading (the `.cpuOnly` pin and its history live here — see
//  09-SESSION-STATE.md "ANE re-export" before changing the compute units)
//  and the preview-frame JPEG encoder bridges.
//

import CueSyncCore
import DetectionRoboflow
import Foundation
import PerceptionKit
#if canImport(CoreML)
import CoreML
#endif
#if canImport(CoreVideo)
import CoreVideo
#endif

extension SessionModel {
    #if canImport(CoreML)
    /// Load the bundled BallDetector OFF the main actor (MLModel init can
    /// take seconds) and hand back the Sendable provider.
    nonisolated static func loadBundledDetector() async -> (any DetectionProviding)? {
        await Task.detached(priority: .userInitiated) {
            guard let url = Bundle.main.url(forResource: "BallDetector",
                                            withExtension: "mlmodelc") else { return nil }
            let configuration = MLModelConfiguration()
            // Still CPU-only. T1.3 negative result (2026-07-23, crash logs
            // on file): even the iOS16-target/CoreML6 re-export with fp32
            // pipeline outputs aborts in MPSGraph's MLIR optimization
            // passes on iOS 26 the moment GPU/ANE compiles it — the
            // boundary-cast theory is dead; the bug is in MPSGraph's
            // ingestion of coremltools-9 mlprograms generally. Next
            // candidates: iOS17-target export, then fp32 GPU-only.
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

    func makeEncoder() -> any FrameJPEGEncoding {
        #if canImport(CoreImage)
        PixelBufferJPEGEncoder()
        #else
        UnsupportedEncoder()
        #endif
    }
}

#if !canImport(CoreImage)
struct UnsupportedEncoder: FrameJPEGEncoding {
    func encodeJPEG(from frame: CapturedFrame) throws -> (data: Data, width: Int, height: Int) {
        throw RoboflowError.frameNotEncodable
    }
}
#endif

#if canImport(CoreVideo)
// Bridge PerceptionKit's frame image type to DetectionRoboflow's encoder seam.
extension PixelBufferImage: @retroactive DetectionRoboflow.PixelBufferProviding {
    public var cvPixelBuffer: CVPixelBuffer { pixelBuffer }
}
#endif
