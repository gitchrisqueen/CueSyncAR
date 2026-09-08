//
//  SessionRecorder.swift
//  CueSync AR
//
//  The on-device session recorder: owns one bundle directory under
//  Documents/Sessions/<id>/ for the duration of a recording and is the
//  FrameRecordingSink the live pipeline's detector seam calls (see
//  SessionReplay.RecordingDetectionProvider). Everything it writes is what
//  SessionReplay.ReplayRunner reads back on Linux.
//
//  Retention (CLAUDE.md "Camera buffers"): this actor never sees an
//  ARFrame. It receives CapturedFrames whose PixelBufferImage wraps the
//  coordinator's DEEP COPY of the camera buffer; the only thing done with
//  it is a synchronous, non-blocking `VideoFrameWriter.append`, after which
//  the frame is released. Nothing here stores a frame or a buffer.
//
//  Alignment: `willDetect` writes the frames.jsonl line BEFORE the pixels
//  go to the encoder, so a frame the encoder refuses is still in the
//  record (flagged `videoDropped`) and never silently shifts the video
//  against detections.jsonl.
//

import ARExperience
import CoreVideo
import CueSyncCore
import Foundation
import os
import PerceptionKit
import SessionReplay
import TableSpace

/// Live numbers for the HUD badge and the mirror's `/state.json`.
struct RecordingStatus: Sendable, Equatable {
    var sessionID: String
    var frames = 0
    var detectionFrames = 0
    var videoFrames = 0
    var videoDropped = 0
    var snapshots = 0
    var events = 0
    /// Seconds of recorded frames (frame-timestamp based, not wall clock).
    var seconds: Double = 0
    var capSeconds: Int
    var capReached = false
    var estimatedMegabytes: Double = 0
    var lastError: String?

    var clock: String {
        let whole = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// Static facts about the run, known when recording starts; the recorder
/// fills in the dynamic ones (resolution, counts, duration, stop reason).
struct RecordingInfoSeed: Sendable {
    var appCommit: String
    var appBranch: String
    var appDirty: Bool
    var appVersion: String
    var detector: String
    var modelName: String?
    var modelSHA256: String?
    var hardwareModel: String
    var systemVersion: String
    var viewport: ViewportInfo
    var tickMilliseconds: Int
    var guideSpeed: Double
    var visibleMissGrace: Double
    var practiceMode: String
    var metricPalette: Bool
    /// B3 A/B switch in force (replayed the same way).
    var followsTableAnchor: Bool
    /// Table anchor transform the calibration was expressed against (B3).
    var lockAnchorTransform: Transform3D?
}

/// What a finished recording amounts to.
struct RecordingSummary: Sendable, Equatable {
    var sessionID: String
    var directory: URL
    var frames: Int
    var videoFrames: Int
    var videoDropped: Int
    var seconds: Double
    var bytesOnDisk: Int
    var stopReason: String
}

actor SessionRecorder: FrameRecordingSink {
    /// Hard cap on one recording. Five minutes at ~45 MB/min of video is
    /// the size a Wi-Fi pull and a later fixture commit can live with.
    static let capSeconds = 300
    static let snapshotInterval: TimeInterval = 1
    static let sessionsDirectoryName = "Sessions"
    /// Refuse to start with less free space than a full recording plus headroom.
    static let requiredFreeMegabytes = 400.0
    static let log = Logger(subsystem: "com.cuesync.ar", category: "recorder")

    /// Documents/Sessions — visible in Files.app / Finder via file sharing
    /// (the fallback when the Wi-Fi pull is not an option).
    nonisolated static func sessionsRoot() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(sessionsDirectoryName, isDirectory: true)
    }

    /// `device-20260907T213045Z`: derived from the clock, never random,
    /// so the bundle's identity is reproducible from its manifest.
    nonisolated static func makeSessionID(at date: Date = Date()) -> (id: String, recordedAt: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        let recordedAt = formatter.string(from: date)
        let compact = recordedAt.replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
        return ("device-\(compact)", recordedAt)
    }

    nonisolated static func freeMegabytes() -> Double? {
        let values = try? sessionsRoot().deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map { Double($0) / 1_000_000 }
    }

    /// "About 45 MB per minute; the 5-minute cap is ≈ 225 MB."
    nonisolated static var sizeSummary: String {
        let perMinute = VideoFrameWriter.megabytesPerMinute()
        let cap = perMinute * Double(capSeconds) / 60
        return String(format: "About %.0f MB per minute of video; the %d-minute cap is about %.0f MB.",
                      perMinute, capSeconds / 60, cap)
    }

    let sessionID: String
    let recordedAt: String
    let directory: URL
    private let bundle: SessionBundleRecorder
    private let seed: RecordingInfoSeed
    private let sideChannel: @Sendable (TimeInterval) -> DeliveredFrameMeta?
    private let videoBitRate: Int
    private var video: VideoFrameWriter?
    private var nativeSize = (width: 0, height: 0)
    private var firstFrameTimestamp: TimeInterval?
    private var capReached = false
    private var stopped = false
    private var lastError: String?

    init(calibration: TableCalibration, seed: RecordingInfoSeed,
         sideChannel: @escaping @Sendable (TimeInterval) -> DeliveredFrameMeta?,
         videoBitRate: Int = VideoFrameWriter.defaultBitRate) throws {
        let (id, recordedAt) = Self.makeSessionID()
        sessionID = id
        self.recordedAt = recordedAt
        directory = Self.sessionsRoot().appendingPathComponent(id, isDirectory: true)
        bundle = try SessionBundleRecorder(directory: directory, calibration: calibration,
                                           lockAnchorTransform: seed.lockAnchorTransform)
        self.seed = seed
        self.sideChannel = sideChannel
        self.videoBitRate = videoBitRate
        Self.log.notice("recording \(id, privacy: .public) started")
    }

    // MARK: FrameRecordingSink (called from the pipeline's detector seam)

    func willDetect(_ frame: CapturedFrame) async -> Int? {
        guard !stopped, !capReached else { return nil }
        if let first = firstFrameTimestamp, frame.timestamp - first >= Double(Self.capSeconds) {
            capReached = true
            Self.log.notice("recording \(self.sessionID, privacy: .public): \(Self.capSeconds) s cap reached")
            return nil
        }
        if firstFrameTimestamp == nil { firstFrameTimestamp = frame.timestamp }
        let image = frame.image as? PixelBufferImage
        // Decide the video outcome BEFORE writing the line, so the line can
        // name the video frame index; the pixels go to the encoder only
        // after the line is on disk.
        var outcome = SessionBundleRecorder.VideoOutcome.none
        if let image {
            if video == nil { openVideo(for: image) }
            if let video {
                outcome = video.isReadyForMoreFrames ? .frame(video.frameCount) : .dropped
            }
        }
        let index: Int
        do {
            index = try bundle.appendFrame(frame, video: outcome,
                                           delivered: sideChannel(frame.timestamp)).index
        } catch {
            fail("frames.jsonl write failed: \(error.localizedDescription)")
            return nil
        }
        if case .frame(let expected) = outcome, let image, let video {
            let result = video.append(image.pixelBuffer, at: frame.timestamp)
            if result != .appended(index: expected) {
                // The line already claims a video frame that does not exist
                // — never let that stand silently: note it in the record
                // and stop, the manifest's stopReason says why.
                let reason = "video append failed at frame \(index): \(result)"
                try? bundle.appendEvent(RecordedEvent(frame: index, timestamp: frame.timestamp,
                                                      kind: .note, note: reason))
                fail(reason)
                return nil
            }
        }
        if index == 0 || index % 100 == 0 {
            Self.log.info("recording frame #\(index) video=\(String(describing: outcome), privacy: .public)")
        }
        return index
    }

    func didDetect(frame index: Int, timestamp: TimeInterval, detections: [Detection2D]) async {
        guard !stopped else { return }
        do {
            try bundle.appendDetections(frame: index, timestamp: timestamp, detections: detections)
        } catch {
            fail("detections.jsonl write failed: \(error.localizedDescription)")
        }
    }

    private func openVideo(for image: PixelBufferImage) {
        nativeSize = (image.width, image.height)
        do {
            video = try VideoFrameWriter(
                url: directory.appendingPathComponent(VideoFrameWriter.fileName),
                width: image.width, height: image.height,
                pixelFormat: CVPixelBufferGetPixelFormatType(image.pixelBuffer),
                bitRate: videoBitRate)
        } catch {
            // Recording continues WITHOUT video (frames + detections are
            // what the replay needs); the HUD and manifest say so.
            lastError = "video unavailable: \(error.localizedDescription)"
            Self.log.error("recording \(self.sessionID, privacy: .public): \(self.lastError ?? "", privacy: .public)")
        }
    }

    // MARK: User events and snapshots (from the main actor)

    func recordEvent(kind: RecordedEvent.Kind, x: Double? = nil, y: Double? = nil,
                     pocket: String? = nil, note: String? = nil) {
        guard !stopped else { return }
        let event = RecordedEvent(frame: bundle.latestFrameIndex,
                                  timestamp: bundle.lastFrameTimestamp ?? ProcessInfo.processInfo.systemUptime,
                                  kind: kind, x: x, y: y, pocket: pocket, note: note)
        do {
            try bundle.appendEvent(event)
            Self.log.info("recording event \(kind.rawValue, privacy: .public) at frame \(event.frame)")
        } catch {
            fail("events.jsonl write failed: \(error.localizedDescription)")
        }
    }

    func recordSnapshot(_ projection: ProjectionSnapshot) {
        guard !stopped else { return }
        let snapshot = RecordedSnapshot(index: bundle.snapshotCount, frame: bundle.latestFrameIndex,
                                        projection: projection)
        do {
            try bundle.appendSnapshot(snapshot)
        } catch {
            fail("snapshots.jsonl write failed: \(error.localizedDescription)")
        }
    }

    // MARK: Status and finish

    func status() -> RecordingStatus {
        let seconds = bundle.recordedSeconds
        let videoBytes = Double(videoBitRate) / 8 * seconds
        return RecordingStatus(
            sessionID: sessionID,
            frames: bundle.frameCount,
            detectionFrames: bundle.detectionFrameCount,
            videoFrames: bundle.videoFrameCount,
            videoDropped: bundle.videoDroppedCount,
            snapshots: bundle.snapshotCount,
            events: bundle.eventCount,
            seconds: seconds,
            capSeconds: Self.capSeconds,
            capReached: capReached,
            estimatedMegabytes: (videoBytes + Double(bundle.textBytesWritten)) / 1_000_000,
            lastError: lastError)
    }

    /// Stop accepting frames, finalize the video and write the manifest.
    func finish(reason: String) async throws -> RecordingSummary {
        stopped = true
        let stopReason = lastError.map { "error: \($0)" } ?? reason
        var videoInfo: SessionManifest.VideoInfo?
        if let video {
            do {
                try await video.finish()
                if video.frameCount > 0 {
                    videoInfo = SessionManifest.VideoInfo(fileName: VideoFrameWriter.fileName,
                                                          width: video.width, height: video.height)
                }
            } catch {
                let reason = "video finalize failed: \(String(describing: error))"
                Self.log.error("recording \(self.sessionID, privacy: .public): \(reason, privacy: .public)")
            }
        }
        let info = RecordingInfo(
            appCommit: seed.appCommit, appBranch: seed.appBranch, appDirty: seed.appDirty,
            appVersion: seed.appVersion, detector: seed.detector,
            modelName: seed.modelName, modelSHA256: seed.modelSHA256,
            hardwareModel: seed.hardwareModel, systemVersion: seed.systemVersion,
            displayScale: seed.viewport.displayScale,
            viewWidth: seed.viewport.width, viewHeight: seed.viewport.height,
            nativeWidth: nativeSize.width, nativeHeight: nativeSize.height,
            tickMilliseconds: seed.tickMilliseconds,
            snapshotIntervalSeconds: Self.snapshotInterval,
            capSeconds: Self.capSeconds, durationSeconds: bundle.recordedSeconds,
            videoCodec: videoInfo == nil ? nil : VideoFrameWriter.codecName,
            videoFrames: bundle.videoFrameCount, videoDroppedFrames: bundle.videoDroppedCount,
            guideSpeed: seed.guideSpeed, visibleMissGrace: seed.visibleMissGrace,
            practiceMode: seed.practiceMode, metricPalette: seed.metricPalette,
            followsTableAnchor: seed.followsTableAnchor, stopReason: stopReason)
        let description = "Device recording; \(seed.detector) detector; "
            + "\(bundle.frameCount) frames over \(String(format: "%.1f", bundle.recordedSeconds)) s"
        try bundle.finish(sessionID: sessionID, recordedAt: recordedAt, description: description,
                          video: videoInfo, recording: info)
        let summary = RecordingSummary(sessionID: sessionID, directory: directory,
                                       frames: bundle.frameCount,
                                       videoFrames: bundle.videoFrameCount,
                                       videoDropped: bundle.videoDroppedCount,
                                       seconds: bundle.recordedSeconds,
                                       bytesOnDisk: Self.bytesOnDisk(directory),
                                       stopReason: stopReason)
        let line = "\(summary.frames) frames, \(summary.videoFrames) video frames "
            + "(\(summary.videoDropped) dropped), \(String(format: "%.1f", summary.seconds)) s, "
            + "\(summary.bytesOnDisk / 1_000_000) MB, stop=\(stopReason)"
        Self.log.notice("recording \(self.sessionID, privacy: .public) finished: \(line, privacy: .public)")
        return summary
    }

    /// Something went wrong mid-recording: remember it, stop taking frames.
    /// The HUD shows it on the next status poll; finish() records it.
    private func fail(_ reason: String) {
        guard lastError == nil else { return }
        lastError = reason
        stopped = true
        Self.log.error("recording \(self.sessionID, privacy: .public) stopped: \(reason, privacy: .public)")
    }

    nonisolated static func bytesOnDisk(_ directory: URL) -> Int {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return 0 }
        return names.reduce(0) { total, name in
            let attributes = try? manager.attributesOfItem(
                atPath: directory.appendingPathComponent(name).path)
            return total + ((attributes?[.size] as? Int) ?? 0)
        }
    }
}
