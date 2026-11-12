//
//  FarTileDetector.swift
//  PerceptionKit
//
//  DetectionProviding wrapper: the normal full-frame pass, plus (when
//  enabled) a zoomed second pass over a crop of the frame on every Nth call,
//  merged into one result. The pipeline sees an ordinary provider.
//
//  Cost: a tile pass is a second inference (about 27 ms on the iPad, measured:
//  `detect` 26.9 ms tile off, 39.8 ms tile on), so by default it runs on
//  every frame; `period` thins it out. With the tile OFF, `detect` is the
//  inner provider's `detect` and nothing else: same call, same result.
//
//  Where the window goes: with a locked table the window is placed from the
//  table and the frame's pose (`FarTilePlacement`); without one, `.on` uses a
//  fixed region and `.automatic` does nothing.
//
//  Inference stays wherever the inner provider runs it (the Core ML
//  provider's dedicated queue), never on the caller's actor. The crop is a
//  small deep copy; no camera buffer is retained.
//

import CueSyncCore
import Foundation
import Synchronization
import TableSpace

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
    /// Seconds the full-frame pass took on this frame.
    public var fullSeconds: Double
    /// The period in force when this pass ran (it moves in budget mode).
    public var period: Int
    /// The window used, and whether it was placed from the locked table
    /// (false: the fixed fallback region).
    public var region: FarTileRegion
    public var placedFromTable: Bool
    /// Set when the tile pass failed; the full-frame result was returned.
    public var failure: String?
}

/// When the tile pass runs.
public enum FarTileMode: String, Sendable, Equatable {
    /// Never: `detect` is the inner provider's `detect`.
    case off
    /// Every scheduled frame, with or without a locked table (the fixed
    /// region stands in for a missing or unusable placement).
    case on
    /// Only while a table is locked, and only when the placement finds balls
    /// narrow enough to need it. The default in the app.
    case automatic
}

public final class FarTileDetector: DetectionProviding, @unchecked Sendable {
    /// Produces the cropped frame for the tile pass, or nil when the frame
    /// cannot be cropped (no image, unsupported format).
    public typealias Cropper = @Sendable (CapturedFrame, FarTilePixelCrop) throws -> CapturedFrame?
    /// The locked table, if any. Called once per frame; keep it cheap.
    public typealias TableSource = @Sendable () -> TableCalibration?

    private struct State {
        var mode: FarTileMode
        var schedule: FarTileSchedule
        var onEvent: (@Sendable (FarTileEvent) -> Void)?
        var tableSource: TableSource?
        /// Non-nil: the period follows this budget; `schedule`'s period is
        /// kept equal to `budget.period`.
        var budget: FarTileBudget?
    }

    private let inner: any DetectionProviding
    private let fallbackRegion: FarTileRegion
    private let narrowerThanPixels: Double
    private let cropper: Cropper
    private let now: @Sendable () -> UInt64
    private let state: Mutex<State>

    /// Default OFF, every frame (`period` 1).
    public init(inner: any DetectionProviding,
                fallbackRegion: FarTileRegion = .default,
                narrowerThanPixels: Double = 32,
                period: Int = 1,
                budgetMilliseconds: Double? = nil,
                mode: FarTileMode = .off,
                tableSource: TableSource? = nil,
                now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
                cropper: @escaping Cropper) {
        self.now = now
        self.inner = inner
        self.fallbackRegion = fallbackRegion
        self.narrowerThanPixels = narrowerThanPixels
        self.cropper = cropper
        let budget = budgetMilliseconds.map { FarTileBudget(budgetMilliseconds: $0) }
        self.state = Mutex(State(mode: mode,
                                 schedule: FarTileSchedule(period: budget?.period ?? period),
                                 onEvent: nil, tableSource: tableSource, budget: budget))
    }

    public var mode: FarTileMode { state.withLock { $0.mode } }
    /// Whether a tile pass can happen at all right now (mode is not `.off`).
    public var isEnabled: Bool { mode != .off }
    public var period: Int { state.withLock { $0.schedule.period } }

    public func setMode(_ mode: FarTileMode) {
        state.withLock { $0.mode = mode }
    }

    /// Shorthand for `setMode(on ? .on : .off)`.
    public func setEnabled(_ on: Bool) {
        setMode(on ? .on : .off)
    }

    /// Pin the period (leaves budget mode).
    public func setPeriod(_ period: Int) {
        state.withLock {
            $0.budget = nil
            $0.schedule.setPeriod(period)
        }
    }

    /// Follow a detect-time budget: the period is chosen from measured pass
    /// times (`FarTileBudget`).
    public func setBudget(milliseconds: Double) {
        state.withLock {
            let budget = FarTileBudget(budgetMilliseconds: milliseconds)
            $0.schedule.setPeriod(budget.period)
            $0.budget = budget
        }
    }

    /// The budget's view of the passes, nil outside budget mode.
    public var budget: FarTileBudget? { state.withLock { $0.budget } }

    public func setTableSource(_ source: TableSource?) {
        state.withLock { $0.tableSource = source }
    }

    /// Called after every tile pass (including a failed one). Not called for
    /// frames without a tile pass.
    public func setEventHandler(_ handler: (@Sendable (FarTileEvent) -> Void)?) {
        state.withLock { $0.onEvent = handler }
    }

    public func prepare() async throws {
        try await inner.prepare()
    }

    /// The window for this frame, or nil for "no tile pass".
    private func window(for frame: CapturedFrame, mode: FarTileMode,
                        table: TableCalibration?) -> (region: FarTileRegion, placed: Bool)? {
        if let table,
           let plan = FarTilePlacement.plan(calibration: table, frame: frame,
                                            narrowerThanPixels: narrowerThanPixels) {
            return (plan.region, true)
        }
        // No placement. A forced tile falls back to the fixed region; the
        // automatic one has nothing to do (no table, or no narrow ball).
        return mode == .on ? (fallbackRegion, false) : nil
    }

    public func detect(in frame: CapturedFrame) async throws -> [Detection2D] {
        let (mode, runTile, index, onEvent, table) = state.withLock { state in
            let index = state.schedule.frameIndex
            let mode = state.mode
            return (mode, state.schedule.advance(enabled: mode != .off), index,
                    state.onEvent, state.tableSource?())
        }
        let fullStart = now()
        let full = try await inner.detect(in: frame)
        let fullSeconds = Double(now() &- fullStart) / 1e9
        if mode != .off {
            state.withLock { state in
                guard state.budget != nil else { return }
                state.budget?.noteFullPass(milliseconds: fullSeconds * 1000)
                state.schedule.setPeriod(state.budget?.period ?? state.schedule.period)
            }
        }
        guard runTile, let image = frame.image,
              let (region, placed) = window(for: frame, mode: mode, table: table),
              let crop = region.pixelCrop(frameWidth: image.width, frameHeight: image.height)
        else { return full }

        let start = now()
        let clock = now
        func seconds() -> Double { Double(clock() &- start) / 1e9 }
        let period = state.withLock { $0.schedule.period }
        do {
            guard let tileFrame = try cropper(frame, crop) else { return full }
            let raw = try await inner.detect(in: tileFrame)
            let tile = FarTileMerge.frameDetections(fromTile: raw, crop: crop)
            let merged = FarTileMerge.merge(full: full, tile: tile)
            let tileSeconds = seconds()
            state.withLock { state in
                guard state.budget != nil else { return }
                state.budget?.noteTilePass(milliseconds: tileSeconds * 1000)
                state.schedule.setPeriod(state.budget?.period ?? state.schedule.period)
            }
            onEvent?(FarTileEvent(frameIndex: index, tileDetections: tile.count,
                                  added: max(0, merged.count - full.count),
                                  seconds: tileSeconds, fullSeconds: fullSeconds, period: period,
                                  region: region, placedFromTable: placed, failure: nil))
            return merged
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The tile is an extra. Its failure must never cost the frame.
            onEvent?(FarTileEvent(frameIndex: index, tileDetections: 0, added: 0,
                                  seconds: seconds(), fullSeconds: fullSeconds, period: period,
                                  region: region, placedFromTable: placed,
                                  failure: String(describing: error)))
            return full
        }
    }
}
