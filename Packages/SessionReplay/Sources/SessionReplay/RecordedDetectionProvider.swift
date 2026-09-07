//
//  RecordedDetectionProvider.swift
//  SessionReplay
//
//  DetectionProviding over a bundle's detections.jsonl: the pipeline asks
//  for a frame's detections and gets back exactly what the detector emitted
//  when the session was recorded, keyed by the frame's timestamp — the one
//  identity a `CapturedFrame` carries. No model, no pixels, no platform.
//

import CueSyncCore
import Foundation

public struct RecordedDetectionProvider: DetectionProviding {
    /// Thrown for a frame the bundle has no detections for. The pipeline
    /// drops that frame (as it would a live detector failure) and the
    /// replay counts it, so a gap in the recording is visible, not silent.
    public struct MissingFrame: Error, Equatable {
        public let timestamp: TimeInterval
    }

    private let byTimestamp: [TimeInterval: [Detection2D]]

    public init(detections: [RecordedDetectionFrame]) {
        var map: [TimeInterval: [Detection2D]] = [:]
        for frame in detections {
            map[frame.timestamp] = frame.detections.map(\.detection2D)
        }
        byTimestamp = map
    }

    public init(bundle: SessionBundle) {
        self.init(detections: bundle.detections)
    }

    public func prepare() async throws {}

    public func detect(in frame: CapturedFrame) async throws -> [Detection2D] {
        guard let detections = byTimestamp[frame.timestamp] else {
            throw MissingFrame(timestamp: frame.timestamp)
        }
        return detections
    }
}
