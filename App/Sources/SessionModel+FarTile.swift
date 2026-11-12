//
//  SessionModel+FarTile.swift
//  CueSync AR
//
//  Far-tile detection pass (default OFF). `FarTileDetector` in PerceptionKit
//  wraps the bundled detector: with the tile off it is a pass-through; with it
//  on, every `period`-th frame also runs a zoomed crop of the table through
//  the same model and merges the result, to recover small far-row balls.
//  `/cmd?action=farTile&v=0|1` flips it so the two modes can be compared on
//  the device. SessionModel.swift is at its line cap, so the process-wide
//  handle lives here (same pattern as `DetectorCompute`).
//

import CueSyncCore
import Foundation
import PerceptionKit
import Synchronization
import os

enum FarTileControl {
    /// A tile pass every this-many frames. At the iPad's ~200 ms CPU
    /// inference, every frame would halve the tracking rate; every second
    /// frame costs a third of it, and the tracker's miss grace (2.5 s) spans
    /// the 2-frame gap for a ball only the tile sees.
    static let period = 2

    private static let detector = Mutex<FarTileDetector?>(nil)
    private static let passes = Mutex(0)
    private static let log = Logger(subsystem: "com.cuesync.ar", category: "pipeline")

    /// Wrap the bundled detector. Idempotent per process: the last wrapper
    /// installed is the one the command controls.
    static func install(around inner: any DetectionProviding) -> any DetectionProviding {
        #if canImport(CoreML) && canImport(Vision)
        let wrapper = FarTileDetector(inner: inner, period: period, enabled: false,
                                      cropper: FarTileDetector.pixelBufferCropper)
        wrapper.setEventHandler { event in
            if let failure = event.failure {
                log.error("far tile: pass FAILED, full-frame result used: \(failure, privacy: .public)")
                return
            }
            // Throttled: one line in ten, plus every pass that added a ball.
            let count = passes.withLock { total -> Int in total += 1; return total }
            if event.added > 0 || count % 10 == 1 {
                log.notice("""
                    far tile: pass \(count) frame \(event.frameIndex) \
                    tile=\(event.tileDetections) added=\(event.added) \
                    \(event.seconds, format: .fixed(precision: 3)) s
                    """)
            }
        }
        detector.withLock { $0 = wrapper }
        return wrapper
        #else
        return inner
        #endif
    }

    /// False when no on-device detector is loaded (hosted-only session).
    static func setEnabled(_ on: Bool) -> Bool {
        guard let wrapper = detector.withLock({ $0 }) else { return false }
        wrapper.setEnabled(on)
        if on { passes.withLock { $0 = 0 } }
        return true
    }

    static var isEnabled: Bool { detector.withLock { $0 }?.isEnabled ?? false }

    /// Block for the mirror's `/state.json` (`farTile`).
    static var mirrorState: [String: Any] {
        ["installed": detector.withLock { $0 } != nil, "enabled": isEnabled, "period": period]
    }
}

extension SessionModel {
    /// `/cmd?action=farTile&v=0|1`: the A/B switch for the far-tile pass.
    func setFarTileEnabled(_ on: Bool) {
        guard FarTileControl.setEnabled(on) else {
            Self.log.error("far tile: no on-device detector loaded; command ignored")
            showRemoteFeedback("Far tile unavailable: no on-device detector")
            return
        }
        Self.log.notice("far tile \(on ? "ON" : "OFF", privacy: .public) (remote), every \(FarTileControl.period) frames")
        showRemoteFeedback(on ? "Far tile on (every \(FarTileControl.period) frames)" : "Far tile off")
    }
}
