//
//  SessionModel+Recording.swift
//  CueSync AR
//
//  Start/stop plumbing for the on-device session recorder and the user-
//  facing rules around it: what has to be true before a recording can
//  begin, what the HUD says at every step, and how user actions during a
//  recording become events.jsonl lines. Every guard that declines a
//  record request logs under com.cuesync.ar AND puts a line on the HUD —
//  a record button that does nothing visible is the failure mode this
//  file exists to prevent.
//

import ARExperience
import CueSyncCore
import Foundation
import SessionReplay
import TableSpace
#if canImport(UIKit)
import UIKit
#endif

/// What the AR layer lends the recorder: the per-frame side channel and
/// the current viewport. Installed by ARCameraView when its loop starts.
struct RecordingHooks: Sendable {
    let sideChannel: @Sendable (TimeInterval) -> DeliveredFrameMeta?
    let viewport: @MainActor @Sendable () -> ViewportInfo
}

extension SessionModel {
    enum RecordingStopReason: String {
        case user
        case cap
    }

    /// The AR loop's sleep between ticks (ARCameraView) — recorded in the
    /// manifest so a replay knows the pull cadence.
    static let loopTickMilliseconds = 150

    /// Reads the observed shadow, not `recorder != nil`: `recorder` is
    /// `@ObservationIgnored`, so a computed property over it is invisible
    /// to Observation and no view gated on it ever re-renders. The shadow
    /// is maintained by `recorder`'s `didSet`, so it cannot drift.
    var isRecording: Bool { isRecordingFlag }
    var recordingCapMinutes: Int { SessionRecorder.capSeconds / 60 }

    /// The size cost, stated before the user commits — with the free
    /// space on the device so the number means something at the table.
    var recordingSizeSummary: String {
        var summary = SessionRecorder.sizeSummary
        if let free = SessionRecorder.freeMegabytes() {
            summary += String(format: " Free space now: %.1f GB.", free / 1000)
        }
        summary += " Saved on this device under Sessions; pull it with Scripts/pull-session.sh."
        return summary
    }

    /// The reason a recording cannot start right now, in HUD words; nil
    /// when everything is in place.
    var recordingBlocker: String? {
        if isRecording { return "Already recording" }
        if !calibration.isLocked { return "Calibrate the table first (rectangle button)" }
        if !isLiveTracking { return "Live tracking has not started — point at the table" }
        if usingFrontCamera { return "Recording needs the back (AR) camera" }
        if let free = SessionRecorder.freeMegabytes(), free < SessionRecorder.requiredFreeMegabytes {
            return String(format: "Not enough free space (%.0f MB; need %.0f MB)",
                          free, SessionRecorder.requiredFreeMegabytes)
        }
        return nil
    }

    /// Record button / mirror `startRecording`. Restarts the pipeline so
    /// the tracker starts fresh at frame 0 — the replay starts fresh too,
    /// and the two must see the same history.
    func startRecording() async {
        if let blocker = recordingBlocker {
            Self.log.error("startRecording refused: \(blocker, privacy: .public)")
            showTapFeedback("Can't record: \(blocker)")
            return
        }
        guard let locked = tableCalibration else { return }
        let modelDigest = await Self.bundledModelDigest()
        let seed = RecordingInfoSeed(
            appCommit: AppBuild.identity.commit,
            appBranch: AppBuild.identity.branch,
            appDirty: AppBuild.identity.isDirty,
            appVersion: AppBuild.identity.versionLabel,
            detector: usingOnDeviceDetection ? "on-device" : "hosted",
            modelName: usingOnDeviceDetection ? "BallDetector" : nil,
            modelSHA256: usingOnDeviceDetection ? modelDigest : nil,
            hardwareModel: Self.hardwareModel(),
            systemVersion: Self.systemVersion(),
            viewport: recordingHooks?.viewport() ?? .unknown,
            tickMilliseconds: SessionModel.loopTickMilliseconds,
            guideSpeed: guideSpeed,
            visibleMissGrace: settings.visibleMissGrace,
            practiceMode: practiceMode.rawValue,
            metricPalette: true,
            followsTableAnchor: followsTableAnchor,
            lockAnchorTransform: lockAnchorTransform)
        let sideChannel = recordingHooks?.sideChannel ?? { @Sendable _ in nil }
        let recorder: SessionRecorder
        do {
            recorder = try SessionRecorder(calibration: locked, seed: seed, sideChannel: sideChannel)
        } catch {
            Self.log.error("startRecording: recorder failed: \(String(describing: error), privacy: .public)")
            showTapFeedback("Recording failed to start: \(error.localizedDescription)")
            return
        }
        // Order matters: install the sink, THEN rebuild the pipeline, so
        // the fresh tracker's very first frame is frame 0 of the record.
        recordingTap.install(recorder)
        self.recorder = recorder
        overlayPaletteMode = .metric
        stopLiveTracking()
        startLiveTrackingIfReady()
        guard isLiveTracking else {
            // The pipeline refused to come back (detector vanished?) — do
            // not leave a recorder collecting nothing.
            recordingTap.remove()
            self.recorder = nil
            overlayPaletteMode = .design
            Self.log.error("startRecording: pipeline did not restart — recording abandoned")
            showTapFeedback("Recording aborted: tracking did not restart")
            return
        }
        recordingStatus = await recorder.status()
        debugMirror?.setActiveSession(recorder.sessionID)
        // The restart forgot the cue-ball designation (fresh track ids);
        // re-tapping it now becomes a designate event in the record.
        showTapFeedback("● Recording — re-tap the cue ball if its ring isn't white; tap ● to stop")
    }

    /// Record button / mirror `stopRecording` / the cap. Detaches the sink
    /// first so no frame lands after the manifest is written; tracking
    /// itself keeps running.
    func stopRecording(reason: RecordingStopReason) async {
        guard let recorder else {
            Self.log.info("stopRecording: nothing is recording")
            showTapFeedback("Nothing is recording")
            return
        }
        recordingTap.remove()
        self.recorder = nil
        overlayPaletteMode = .design
        debugMirror?.setActiveSession(nil)
        do {
            let summary = try await recorder.finish(reason: reason.rawValue)
            lastRecordingSummary = summary
            recordingStatus = nil
            let dropped = summary.videoDropped > 0 ? ", \(summary.videoDropped) video frames dropped" : ""
            let prefix = reason == .cap ? "Stopped at the \(recordingCapMinutes)-min cap. " : "Saved. "
            showTapFeedback(prefix + "\(summary.frames) frames, \(String(format: "%.0f", summary.seconds)) s, "
                            + "\(summary.bytesOnDisk / 1_000_000) MB\(dropped) → pull-session.sh")
        } catch {
            recordingStatus = nil
            Self.log.error("stopRecording: finish failed: \(String(describing: error), privacy: .public)")
            showTapFeedback("Recording save FAILED: \(error.localizedDescription)")
        }
    }

    /// Loop tick: refresh the HUD numbers and enforce the cap / error stop.
    func refreshRecordingStatus() async {
        guard let recorder else { return }
        let status = await recorder.status()
        recordingStatus = status
        if status.capReached {
            await stopRecording(reason: .cap)
        } else if let error = status.lastError {
            Self.log.error("recording error surfaced: \(error, privacy: .public)")
            await stopRecording(reason: .user)
        }
    }

    /// Loop tick, ~1 Hz while recording: a bracketed projection snapshot.
    func recordProjectionSnapshot(_ projection: ProjectionSnapshot) async {
        await recorder?.recordSnapshot(projection)
    }

    /// A user action that changes tracking state, mirrored into events.jsonl
    /// so the replay applies it at the same frame.
    func noteRecordingEvent(_ kind: RecordedEvent.Kind, x: Double? = nil, y: Double? = nil,
                            pocket: PocketID? = nil, note: String? = nil) {
        guard let recorder else { return }
        Task {
            await recorder.recordEvent(kind: kind, x: x, y: y, pocket: pocket?.rawValue, note: note)
        }
    }

    /// The bundled detector's compiled directory, hashed off the main
    /// actor (CryptoKit; ~5 MB, milliseconds). Nil in a build without it.
    private nonisolated static func bundledModelDigest() async -> String? {
        await Task.detached(priority: .utility) {
            guard let url = Bundle.main.url(forResource: "BallDetector", withExtension: "mlmodelc") else {
                return nil
            }
            return try? SHA256.hexDigest(ofDirectoryAt: url)
        }.value
    }

    /// Hardware class ("iPad13,18"), never the user-assigned device name.
    private nonisolated static func hardwareModel() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { cString in
                let length = strnlen(cString, Int(_SYS_NAMELEN))
                return cString.withMemoryRebound(to: UInt8.self, capacity: length) { bytes in
                    String(bytes: UnsafeBufferPointer(start: bytes, count: length), encoding: .utf8)
                        ?? "unknown"
                }
            }
        }
    }

    private nonisolated static func systemVersion() -> String {
        #if canImport(UIKit)
        return ProcessInfo.processInfo.operatingSystemVersionString
        #else
        return "unknown"
        #endif
    }
}
