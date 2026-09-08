//
//  SessionModel+Providers.swift
//  CueSync AR
//
//  Provider plumbing split out of SessionModel.swift to keep the
//  composition root under SwiftLint's file_length limit: bundled on-device
//  detector loading — including the T1.3 Neural Engine probe that replaced
//  the `.cpuOnly` pin (see 09-SESSION-STATE.md "ANE re-export" for the
//  history before changing the compute units) — and the preview-frame
//  JPEG encoder bridges.
//

import CoachKit
import CueSyncCore
import DetectionRoboflow
import Foundation
import PerceptionKit
import Synchronization
import os
#if canImport(CoreML)
import CoreML
#endif
#if canImport(CoreVideo)
import CoreVideo
#endif

/// Process-wide state of the T1.3 compute-unit probe (`DetectorComputeProbe`
/// in PerceptionKit holds the tested state machine; this owns the file, the
/// persistence ORDER, and the one copy the mirror and Settings read).
///
/// Ordering is the safety argument: the marker is written and fsync'd
/// BEFORE each Neural Engine step that can abort the process (model load,
/// first inference) and cleared AFTER it returns. Nothing about the write
/// is asynchronous, so a SIGABRT in between leaves the marker on disk for
/// the next launch to find — which then pins the CPU and reports it.
enum DetectorCompute {
    /// Application Support (not Caches — the system may purge those).
    static let store: FileDetectorComputeProbeStore = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return FileDetectorComputeProbeStore(
            url: base.appendingPathComponent("CueSync/detector-compute-probe.json"))
    }()

    /// nil until `SessionModel.loadBundledDetector` has run this launch.
    private static let probe = Mutex<DetectorComputeProbe?>(nil)
    /// Guards the first-inference window so exactly one call arms it.
    private static let firstInferenceStarted = Mutex(false)

    /// Not `SessionModel.log`: that static is main-actor isolated and the
    /// loader runs detached.
    fileprivate static let log = Logger(subsystem: "com.cuesync.ar", category: "session")

    /// The probe as it stands right now (a copy).
    static var current: DetectorComputeProbe? { probe.withLock { $0 } }

    /// Decide this launch's units from the record on disk plus the owner's
    /// Settings pin. Reads the settings store directly (the same store
    /// `SessionModel.bootstrap` loaded seconds earlier) so the loader's
    /// signature — and its call site in SessionModel.swift — stay put.
    static func launch() -> DetectorComputeProbe {
        let optedOut = SettingsModel(loading: appSettingsStore).detectorPinnedToCPU
        let launched = DetectorComputeProbe(launching: store.load(), optedOut: optedOut)
        probe.withLock { $0 = launched }
        if launched.crashedLastRun {
            log.error("""
                detector compute: the previous run died inside a Neural Engine step \
                (marker still set at \(store.url.path, privacy: .public)); \
                crash #\(launched.record.crashes) — pinned to .cpuOnly until reset
                """)
        }
        log.notice("detector compute: \(launched.summary, privacy: .public)")
        return launched
    }

    /// Mutate the shared probe and persist the result. Returns false when
    /// the record could not be written. The model-load path treats that
    /// as "do not load on the Neural Engine"; the first-inference path
    /// cannot swap units any more and proceeds unguarded (logged).
    @discardableResult
    static func update(_ change: (inout DetectorComputeProbe) -> Void) -> Bool {
        let record: DetectorComputeProbeRecord? = probe.withLock { slot in
            guard var value = slot else { return nil }
            change(&value)
            slot = value
            return value.record
        }
        guard let record else { return false }
        do {
            try store.save(record)
            return true
        } catch {
            log.error("detector compute: marker write FAILED: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Called by `ProbedDetector` around the first inference. Returns true
    /// when this call is the probing one and the marker is on disk.
    static func beginFirstInference() -> Bool {
        let first = firstInferenceStarted.withLock { started -> Bool in
            defer { started = true }
            return !started
        }
        guard first, current?.units == .cpuAndNeuralEngine else { return false }
        return update { $0.arm() }
    }

    /// The probing inference returned. A thrown Swift error is NOT an
    /// abort: the marker is cleared, but the success is only counted
    /// when a result came back — the next call probes again.
    static func endFirstInference(succeeded: Bool) {
        if succeeded {
            update { $0.recordSuccess() }
            log.notice("detector compute: first Neural Engine inference returned — probe passed")
        } else {
            update { $0.disarm() }
            firstInferenceStarted.withLock { $0 = false }
        }
    }

    /// Lift a crash pin; effective on the next launch.
    static func reset() {
        update { $0.reset() }
    }

    /// Block served under `detectorCompute` in the mirror's `/state.json`.
    static var mirrorState: [String: Any] {
        guard let probe = current else { return ["units": "notLoaded"] }
        return [
            "units": probe.units.rawValue,
            "phase": probe.phase.rawValue,
            "crashedLastRun": probe.crashedLastRun,
            "crashes": probe.record.crashes,
            "successes": probe.record.successes,
            "pinnedToCPU": probe.record.pinnedToCPU,
            "relaunchNeeded": probe.relaunchNeeded,
            "summary": probe.summary,
            "marker": store.url.path
        ]
    }
}

extension SessionModel {
    #if canImport(CoreML)
    /// Load the bundled BallDetector OFF the main actor (MLModel init can
    /// take seconds) and hand back the Sendable provider.
    ///
    /// Compute units come from `DetectorCompute.launch()`: `.cpuAndNeuralEngine`
    /// unless the last run died inside a Neural Engine step or the owner
    /// pinned the CPU in Settings. NEVER `.all`: the GPU/MPSGraph compile
    /// path is the one proven to SIGABRT on iOS 26 (2026-07-23, crash logs
    /// on file). Whether the ANE path shares the bug is what this probe
    /// finds out — safely, because a crash here is detected on the next
    /// launch rather than repeated.
    nonisolated static func loadBundledDetector() async -> (any DetectionProviding)? {
        await Task.detached(priority: .userInitiated) {
            guard let url = Bundle.main.url(forResource: "BallDetector",
                                            withExtension: "mlmodelc") else { return nil }
            var probe = DetectorCompute.launch()
            var provider: CoreMLDetectionProvider?
            if probe.units == .cpuAndNeuralEngine {
                // Marker on disk BEFORE Core ML sees the model: the ANE
                // specialization happens inside these two inits.
                if DetectorCompute.update({ $0.arm() }) {
                    provider = Self.makeProvider(url: url, units: .cpuAndNeuralEngine)
                    if provider == nil {
                        DetectorCompute.update { $0.recordLoadFailure() }
                    } else {
                        DetectorCompute.update { $0.disarm() }
                    }
                } else {
                    // Marker unwritable ⇒ a crash here would go undetected
                    // and loop. Not worth it: CPU this run, retry next launch.
                    DetectorCompute.update { $0.recordLoadFailure() }
                }
                probe = DetectorCompute.current ?? probe
            }
            if provider == nil {
                provider = Self.makeProvider(url: url, units: .cpuOnly)
            }
            guard let provider else { return nil }
            DetectorCompute.log.notice("detector loaded: \(probe.summary, privacy: .public)")
            return probe.units == .cpuAndNeuralEngine
                ? ProbedDetector(inner: provider) as (any DetectionProviding)
                : provider as (any DetectionProviding)
        }.value
    }

    private nonisolated static func makeProvider(url: URL,
                                                 units: DetectorComputeUnits) -> CoreMLDetectionProvider? {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units == .cpuAndNeuralEngine ? .cpuAndNeuralEngine : .cpuOnly
        guard let model = try? MLModel(contentsOf: url, configuration: configuration) else { return nil }
        return try? CoreMLDetectionProvider(model: model)
    }
    #endif

    /// Owner action (Settings sheet, or `/cmd?action=resetComputeProbe` on
    /// the mirror): lift the crash pin so the next launch tries the Neural
    /// Engine again. No reinstall needed.
    func resetDetectorComputeProbe() {
        DetectorCompute.reset()
        let summary = DetectorCompute.current?.summary ?? "detector not loaded"
        Self.log.notice("detector compute: probe reset — \(summary, privacy: .public)")
        showTapFeedback(DetectorCompute.current?.relaunchNeeded == true
                        ? "Neural Engine will be retried on next launch"
                        : "Neural Engine probe reset")
    }

    /// Second stage of the mirror's `/cmd` dispatch: provider-related
    /// commands that `handleMirrorCommand` (SessionModel.swift) does not
    /// recognise land here, so that switch stays under its complexity cap.
    func handleProviderMirrorCommand(_ params: [String: String]) {
        switch params["action"] {
        case "resetComputeProbe":
            resetDetectorComputeProbe()
        default:
            Self.log.info("mirror command ignored: \(String(describing: params), privacy: .public)")
        }
    }

    func makeEncoder() -> any FrameJPEGEncoding {
        #if canImport(CoreImage)
        PixelBufferJPEGEncoder()
        #else
        UnsupportedEncoder()
        #endif
    }
}

#if canImport(CoreML)
/// Wraps the Neural Engine provider so the FIRST inference is bracketed by
/// the probe marker: armed and fsync'd before `detect`, cleared after it
/// returns. Later calls pass straight through — once one inference has
/// returned the compiled graph is known not to abort.
private struct ProbedDetector: DetectionProviding {
    let inner: CoreMLDetectionProvider

    func prepare() async throws {
        try await inner.prepare()
    }

    func detect(in frame: CapturedFrame) async throws -> [Detection2D] {
        guard DetectorCompute.beginFirstInference() else {
            return try await inner.detect(in: frame)
        }
        do {
            let detections = try await inner.detect(in: frame)
            DetectorCompute.endFirstInference(succeeded: true)
            return detections
        } catch {
            DetectorCompute.endFirstInference(succeeded: false)
            throw error
        }
    }
}
#endif

// `UnsupportedEncoder` and the `PixelBufferImage` encoder bridge live in
// App/Sources/FrameEncodingBridges.swift — declaring them here too is a
// redeclaration and a redundant retroactive conformance.
