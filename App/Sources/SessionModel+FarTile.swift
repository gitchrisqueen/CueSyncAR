//
//  SessionModel+FarTile.swift
//  CueSync AR
//
//  Far-tile detection pass. `FarTileDetector` in PerceptionKit wraps the
//  bundled detector: with the tile off it is a pass-through; with it on, each
//  frame also runs a zoomed crop of the table through the same model and
//  merges the result, to recover small far-row balls and lift the cue ball
//  over the confidence floor.
//
//  Default: AUTOMATIC. The tile runs on every frame once a table is locked,
//  with its window placed from the locked table and the frame's pose, and
//  does nothing before that. `/cmd?action=farTile&v=0|1|auto` and
//  `period=N` switch it, so the modes can be compared on the device.
//  SessionModel.swift is at its line cap, so the process-wide handle lives
//  here (same pattern as `DetectorCompute`).
//

import CueSyncCore
import Foundation
import Observation
import PerceptionKit
import Synchronization
import TableSpace
import os

enum FarTileControl {
    /// A tile pass on every frame. Measured on the iPad: `detect` 26.9 ms with
    /// the tile off, 39.8 ms on, so a pass costs about 13 ms.
    static let defaultPeriod = 1

    private static let detector = Mutex<FarTileDetector?>(nil)
    private static let table = Mutex<TableCalibration?>(nil)
    private static let passes = Mutex(0)
    private static let lastRegion = Mutex<String?>(nil)
    private static let log = Logger(subsystem: "com.cuesync.ar", category: "pipeline")

    /// Wrap the bundled detector. The last wrapper installed is the one the
    /// command controls.
    static func install(around inner: any DetectionProviding) -> any DetectionProviding {
        #if canImport(CoreML) && canImport(Vision)
        let wrapper = FarTileDetector(inner: inner, period: defaultPeriod, mode: .automatic,
                                      tableSource: { table.withLock { $0 } },
                                      cropper: FarTileDetector.pixelBufferCropper)
        wrapper.setEventHandler { event in
            if let failure = event.failure {
                log.error("far tile: pass FAILED, full-frame result used: \(failure, privacy: .public)")
                return
            }
            let region = String(format: "x%.3f y%.3f size%.3f %@", event.region.x, event.region.y,
                                event.region.size, event.placedFromTable ? "placed" : "fixed")
            let moved = lastRegion.withLock { last -> Bool in
                defer { last = region }
                return last != region
            }
            // Throttled: one line in forty, plus every pass that added a
            // ball and every change of window.
            let count = passes.withLock { total -> Int in total += 1; return total }
            if event.added > 0 || moved || count % 40 == 1 {
                log.notice("""
                    far tile: pass \(count) frame \(event.frameIndex) \
                    tile=\(event.tileDetections) added=\(event.added) \
                    \(event.seconds, format: .fixed(precision: 3)) s window \(region, privacy: .public)
                    """)
            }
        }
        detector.withLock { $0 = wrapper }
        return wrapper
        #else
        return inner
        #endif
    }

    /// The locked table, as the placement needs it. nil = none locked.
    static func setTable(_ calibration: TableCalibration?) {
        table.withLock { $0 = calibration }
    }

    /// False when no on-device detector is loaded (hosted-only session).
    @discardableResult
    static func apply(mode: FarTileMode?, period: Int?) -> Bool {
        guard let wrapper = detector.withLock({ $0 }) else { return false }
        if let mode { wrapper.setMode(mode) }
        if let period { wrapper.setPeriod(period) }
        passes.withLock { $0 = 0 }
        return true
    }

    static var mode: FarTileMode { detector.withLock { $0 }?.mode ?? .off }
    static var period: Int { detector.withLock { $0 }?.period ?? defaultPeriod }

    /// Block for the mirror's `/state.json` (`farTile`).
    static var mirrorState: [String: Any] {
        var state: [String: Any] = [
            "installed": detector.withLock { $0 } != nil,
            "enabled": mode != .off,
            "mode": mode.rawValue,
            "period": period,
            "tableLocked": table.withLock { $0 } != nil
        ]
        if let region = lastRegion.withLock({ $0 }) { state["window"] = region }
        return state
    }
}

extension SessionModel {
    /// Keep `FarTileControl` told which table is locked, from now on. Called
    /// once at start-up; re-arms itself on every change of the calibration
    /// (a lock, a re-lock, an anchor-follow update).
    func followTableForFarTile() {
        FarTileControl.setTable(tableCalibration)
        withObservationTracking {
            _ = tableCalibration
        } onChange: { [weak self] in
            Task { @MainActor in self?.followTableForFarTile() }
        }
    }

    /// `/cmd?action=farTile&v=0|1|auto&period=N`: the A/B switch for the
    /// far-tile pass. `v` and `period` are each optional.
    func setFarTile(value: String?, period: Int?) {
        let mode: FarTileMode?
        switch value {
        case nil: mode = nil
        case "0": mode = .off
        case "1": mode = .on
        case "auto": mode = .automatic
        default:
            Self.log.error("far tile: ignored v=\(value ?? "", privacy: .public) (use 0, 1 or auto)")
            showRemoteFeedback("Far tile: v must be 0, 1 or auto")
            return
        }
        guard FarTileControl.apply(mode: mode, period: period) else {
            Self.log.error("far tile: no on-device detector loaded; command ignored")
            showRemoteFeedback("Far tile unavailable: no on-device detector")
            return
        }
        let summary = "\(FarTileControl.mode.rawValue), every \(FarTileControl.period) frame(s)"
        Self.log.notice("far tile \(summary, privacy: .public) (remote)")
        showRemoteFeedback("Far tile: \(summary)")
    }
}
