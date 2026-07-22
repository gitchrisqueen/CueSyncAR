//
//  CoreMLDetectionProvider.swift
//  PerceptionKit
//
//  Task M2-02: DetectionProviding over an on-device Core ML object-detection
//  model via Vision. The model itself (task M2-01) ships in the app bundle;
//  this adapter is model-agnostic — any detector whose classes map through
//  Ball.Kind(classLabel:) plugs in.
//
//  Verification note: unit-level label/box mapping is covered by
//  VisionBoxMapping tests (cross-platform); end-to-end inference needs the
//  bundled model and is part of the M2-01/M2-04 device work.
//

import CueSyncCore
import Foundation

/// Vision reports boxes in normalized coordinates with a BOTTOM-left origin;
/// core uses top-left. Pure helper so the flip is testable everywhere.
/// (Fully qualified: Vision ships its own `NormalizedRect` on iOS 18+.)
public enum VisionBoxMapping {
    public static func topLeftRect(fromVisionX x: Double, y: Double,
                                   width: Double, height: Double) -> CueSyncCore.NormalizedRect {
        CueSyncCore.NormalizedRect(x: x, y: 1 - y - height, width: width, height: height)
    }
}

#if canImport(Vision) && canImport(CoreML) && canImport(CoreVideo)
import CoreML
import CoreVideo
import Vision

/// Apple-platform image buffer carrying the camera pixel buffer.
public struct PixelBufferImage: ImageBufferProviding, @unchecked Sendable {
    // CVPixelBuffer is CF-bridged and safely transferable here: the capture
    // pipeline hands each buffer to exactly one consumer.
    public let pixelBuffer: CVPixelBuffer

    public init(pixelBuffer: CVPixelBuffer) {
        self.pixelBuffer = pixelBuffer
    }

    public var width: Int { CVPixelBufferGetWidth(pixelBuffer) }
    public var height: Int { CVPixelBufferGetHeight(pixelBuffer) }
}

public enum CoreMLDetectionError: Error {
    case unsupportedFrame
    case modelNotPrepared
}

/// VNCoreMLModel is immutable after creation and Vision request handlers are
/// per-call, so the type is safe to share across the pipeline actor boundary.
///
/// Inference runs on a DEDICATED serial queue, never on the caller's thread:
/// `handler.perform` is synchronous, and the first request additionally
/// triggers Neural Engine model specialization (seconds). Blocking the
/// pipeline actor with it starves the cooperative thread pool — observed on
/// device as a frozen camera right after calibration lock.
public final class CoreMLDetectionProvider: DetectionProviding, @unchecked Sendable {
    private let visionModel: VNCoreMLModel
    private let inferenceQueue = DispatchQueue(label: "cuesync.coreml.inference",
                                               qos: .userInitiated)

    public init(model: MLModel) throws {
        visionModel = try VNCoreMLModel(for: model)
    }

    public func prepare() async throws {
        // Model compilation happened in init; nothing further. Kept for the
        // DetectionProviding contract (idempotent by construction).
    }

    public func detect(in frame: CapturedFrame) async throws -> [Detection2D] {
        guard let image = frame.image as? PixelBufferImage else {
            throw CoreMLDetectionError.unsupportedFrame
        }
        let buffer = image.pixelBuffer
        let model = visionModel
        return try await withCheckedThrowingContinuation { continuation in
            inferenceQueue.async {
                do {
                    let request = VNCoreMLRequest(model: model)
                    // scaleFill matches training: the dataset version was
                    // generated with "Stretch to 640x640", so inference
                    // must stretch the same way; box coords map straight
                    // back to the full image.
                    request.imageCropAndScaleOption = .scaleFill
                    let handler = VNImageRequestHandler(cvPixelBuffer: buffer,
                                                        orientation: .up)
                    try handler.perform([request])
                    let observations = request.results as? [VNRecognizedObjectObservation] ?? []
                    let detections = observations.compactMap { observation -> Detection2D? in
                        guard let label = observation.labels.first else { return nil }
                        let box = observation.boundingBox
                        return Detection2D(
                            classLabel: label.identifier,
                            boundingBox: VisionBoxMapping.topLeftRect(
                                fromVisionX: box.origin.x, y: box.origin.y,
                                width: box.size.width, height: box.size.height),
                            confidence: Double(observation.confidence))
                    }
                    continuation.resume(returning: detections)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
#endif
