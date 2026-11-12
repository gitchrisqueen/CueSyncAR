//
//  FarTileDetector.swift
//  PerceptionKit
//
//  DetectionProviding wrapper: the normal full-frame pass, plus (when
//  enabled) a zoomed second pass over a crop of the frame on every Nth call,
//  merged into one result. The pipeline sees an ordinary provider.
//
//  Cost: a tile pass is a second inference (~200 ms on the iPad CPU), so it
//  runs on a schedule, not every frame. With the tile OFF, `detect` is the
//  inner provider's `detect` and nothing else: same call, same result.
//
//  Inference stays wherever the inner provider runs it (the Core ML
//  provider's dedicated queue), never on the caller's actor. The crop is a
//  small deep copy; no camera buffer is retained.
//

import CueSyncCore
import Foundation
import Synchronization

/// What one tile pass found, for logging and the owner's A/B comparison.
public struct FarTileEvent: Sendable, Equatable {
    /// 0-based count of `detect` calls so far.
    public var frameIndex: Int
    /// Tile detections that survived the edge and stick filters.
    public var tileDetections: Int
    /// Of those, how many added a ball the full frame had not reported.
    public var added: Int
    /// Seconds spent on the crop plus the second inference.
    public var seconds: Double
    /// Set when the tile pass failed; the full-frame result was returned.
    public var failure: String?
}

public final class FarTileDetector: DetectionProviding, @unchecked Sendable {
    /// Produces the cropped frame for the tile pass, or nil when the frame
    /// cannot be cropped (no image, unsupported format).
    public typealias Cropper = @Sendable (CapturedFrame, FarTilePixelCrop) throws -> CapturedFrame?

    private struct State {
        var enabled: Bool
        var schedule: FarTileSchedule
        var onEvent: (@Sendable (FarTileEvent) -> Void)?
    }

    private let inner: any DetectionProviding
    private let region: FarTileRegion
    private let cropper: Cropper
    private let state: Mutex<State>

    /// Default OFF. `period` 2 = a tile pass on every second frame.
    public init(inner: any DetectionProviding,
                region: FarTileRegion = .default,
                period: Int = 2,
                enabled: Bool = false,
                cropper: @escaping Cropper) {
        self.inner = inner
        self.region = region
        self.cropper = cropper
        self.state = Mutex(State(enabled: enabled,
                                 schedule: FarTileSchedule(period: period),
                                 onEvent: nil))
    }

    public var isEnabled: Bool { state.withLock { $0.enabled } }

    public func setEnabled(_ on: Bool) {
        state.withLock { $0.enabled = on }
    }

    /// Called after every tile pass (including a failed one). Not called for
    /// frames without a tile pass.
    public func setEventHandler(_ handler: (@Sendable (FarTileEvent) -> Void)?) {
        state.withLock { $0.onEvent = handler }
    }

    public func prepare() async throws {
        try await inner.prepare()
    }

    public func detect(in frame: CapturedFrame) async throws -> [Detection2D] {
        let (runTile, index, onEvent) = state.withLock { state in
            let index = state.schedule.frameIndex
            return (state.schedule.advance(enabled: state.enabled), index, state.onEvent)
        }
        let full = try await inner.detect(in: frame)
        guard runTile, let image = frame.image else { return full }

        let start = ContinuousClock.now
        func seconds() -> Double {
            let elapsed = ContinuousClock.now - start
            return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        }
        guard let crop = region.pixelCrop(frameWidth: image.width, frameHeight: image.height) else {
            return full
        }
        do {
            guard let tileFrame = try cropper(frame, crop) else { return full }
            let raw = try await inner.detect(in: tileFrame)
            let tile = FarTileMerge.frameDetections(fromTile: raw, crop: crop)
            let merged = FarTileMerge.merge(full: full, tile: tile)
            onEvent?(FarTileEvent(frameIndex: index, tileDetections: tile.count,
                                  added: max(0, merged.count - full.count),
                                  seconds: seconds(), failure: nil))
            return merged
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The tile is an extra. Its failure must never cost the frame.
            onEvent?(FarTileEvent(frameIndex: index, tileDetections: 0, added: 0,
                                  seconds: seconds(), failure: String(describing: error)))
            return full
        }
    }
}
