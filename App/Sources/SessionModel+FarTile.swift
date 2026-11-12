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
//  Default: AUTOMATIC with a detect-time budget. The tile runs once a table
//  is locked, with its window placed from the locked table and the frame's
//  pose, and does nothing before that; how OFTEN it runs follows a budget
//  (45 ms average detect time) from the measured pass times, so it costs the
//  same on any device. `/cmd?action=farTile&v=0|1|auto` and
//  `period=N|auto` switch it, so the modes can be compared on the device:
//  `period=1` pins every frame, `period=auto` goes back to the budget.
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
    /// Average detect time the tile may cost, milliseconds. Measured on the
    /// iPad: the full-frame pass is 27-30 ms and a tile pass about 57 ms, so
    /// the tile on every frame gave 84.6 ms; this budget gives period 4,
    /// about 41 ms.
    static let detectBudgetMilliseconds = 45.0

    private static let detector = Mutex<FarTileDetector?>(nil)
    private static let table = Mutex<TableCalibration?>(nil)
    private static let passes = Mutex(0)
    private static let lastRegion = Mutex<String?>(nil)
    private static let log = Logger(subsystem: "com.cuesync.ar", category: "pipeline")

    /// Wrap the bundled detector. The last wrapper installed is the one the
    /// command controls.
    static func install(around inner: any DetectionProviding) -> any DetectionProviding {
        #if canImport(CoreML) && canImport(Vision)
        let wrapper = FarTileDetector(inner: inner, budgetMilliseconds: detectBudgetMilliseconds,
                                      mode: .automatic,
                                      tableSource: { table.withLock { $0 } },
                                      cropper: FarTileDetector.pixelBufferCropper)
        wrapper.setEventHandler { event in
            if let failure = event.failure {
                log.error("far tile: pass FAILED, full-frame result used: \(failure, privacy: .public)")
                return
            }
            let region = String(format: "x%.3f y%.3f size%.3f %@", event.region.x, event.region.y,
                                event.region.size, event.placedFromTable ? "placed" : "fixed")
            let times = String(format: "full %.1f ms tile %.1f ms period %d", event.fullSeconds * 1000,
                               event.seconds * 1000, event.period)
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
                    \(times, privacy: .public) window \(region, privacy: .public)
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

    /// How the period is set from the command.
    enum PeriodSetting {
        case fixed(Int)
        case budget
    }

    /// False when no on-device detector is loaded (hosted-only session).
    @discardableResult
    static func apply(mode: FarTileMode?, period: PeriodSetting?) -> Bool {
        guard let wrapper = detector.withLock({ $0 }) else { return false }
        if let mode { wrapper.setMode(mode) }
        switch period {
        case .fixed(let value): wrapper.setPeriod(value)
        case .budget: wrapper.setBudget(milliseconds: detectBudgetMilliseconds)
        case nil: break
        }
        passes.withLock { $0 = 0 }
        return true
    }

    static var mode: FarTileMode { detector.withLock { $0 }?.mode ?? .off }
    static var period: Int { detector.withLock { $0 }?.period ?? 1 }
    static var periodDescription: String {
        let wrapper = detector.withLock { $0 }
        return wrapper?.budget != nil ? "auto (\(period))" : "\(period)"
    }

    /// Block for the mirror's `/state.json` (`farTile`).
    static var mirrorState: [String: Any] {
        var state: [String: Any] = [
            "installed": detector.withLock { $0 } != nil,
            "enabled": mode != .off,
            "mode": mode.rawValue,
            "period": period,
            "periodSetting": detector.withLock { $0 }?.budget != nil ? "auto" : "fixed",
            "budgetMs": detectBudgetMilliseconds,
            "tableLocked": table.withLock { $0 } != nil
        ]
        if let budget = detector.withLock({ $0 })?.budget {
            if let full = budget.fullMilliseconds { state["fullPassMs"] = (full * 10).rounded() / 10 }
            if let tile = budget.tileMilliseconds { state["tilePassMs"] = (tile * 10).rounded() / 10 }
            if let expected = budget.expectedMilliseconds { state["expectedDetectMs"] = (expected * 10).rounded() / 10 }
        }
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

    /// `/cmd?action=farTile&v=0|1|auto&period=N|auto`: the A/B switch for the
    /// far-tile pass. `v` and `period` are each optional.
    func setFarTile(value: String?, period periodText: String?) {
        let period: FarTileControl.PeriodSetting?
        switch periodText {
        case nil: period = nil
        case "auto": period = .budget
        default:
            guard let count = periodText.flatMap(Int.init), count >= 1 else {
                Self.log.error("far tile: ignored period=\(periodText ?? "", privacy: .public) (use N >= 1 or auto)")
                showRemoteFeedback("Far tile: period must be N or auto")
                return
            }
            period = .fixed(count)
        }
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
        let summary = "\(FarTileControl.mode.rawValue), period \(FarTileControl.periodDescription)"
        Self.log.notice("far tile \(summary, privacy: .public) (remote)")
        showRemoteFeedback("Far tile: \(summary)")
    }
}
