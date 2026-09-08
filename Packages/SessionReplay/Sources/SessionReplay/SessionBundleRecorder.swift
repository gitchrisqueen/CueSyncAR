//
//  SessionBundleRecorder.swift
//  SessionReplay
//
//  The streaming half of the bundle writer, for recording ON a device:
//  files are opened at start and each record is appended as one canonical
//  JSONL line the moment it exists, so a crash mid-session still leaves a
//  readable prefix. `finish` writes manifest.json last, with a sha256 for
//  every other file. The batch `SessionBundleWriter` and this recorder
//  produce byte-identical files for the same records (tested).
//
//  1:1 alignment with the live pipeline is NOT this type's job — it
//  writes what it is told. `RecordingDetectionProvider` below is what
//  guarantees it: it sits at the detector seam, the one place every frame
//  the pipeline processes passes through exactly once, and nowhere else.
//

import ARExperience
import CueSyncCore
import Foundation
import TableSpace

/// Appends bundle records to files under one directory. Not thread-safe:
/// own it from a single actor (the app's SessionRecorder).
public final class SessionBundleRecorder {
    public let directory: URL
    public private(set) var frameCount = 0
    public private(set) var detectionFrameCount = 0
    public private(set) var eventCount = 0
    public private(set) var snapshotCount = 0
    public private(set) var videoFrameCount = 0
    public private(set) var videoDroppedCount = 0
    public private(set) var firstFrameTimestamp: TimeInterval?
    public private(set) var lastFrameTimestamp: TimeInterval?
    /// Bytes of JSONL written so far (video excluded — the writer knows).
    public private(set) var textBytesWritten = 0
    public private(set) var isFinished = false

    private var handles: [SessionBundleFile: FileHandle] = [:]

    /// Index the next frame will get; `frameCount - 1` is the latest.
    public var nextFrameIndex: Int { frameCount }
    public var latestFrameIndex: Int { frameCount - 1 }

    /// Create the directory, write calibration.json, and open the JSONL
    /// files for appending. Throws if the directory already holds a bundle.
    /// - Parameter lockAnchorTransform: the table anchor's transform the
    ///   calibration was expressed against (B3); nil pins it under replay.
    public init(directory: URL, calibration: TableCalibration,
                lockAnchorTransform: Transform3D? = nil) throws {
        self.directory = directory
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.appendingPathComponent(
            SessionBundleFile.manifest.rawValue).path) {
            throw CocoaError(.fileWriteFileExists)
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let recorded = RecordedCalibration(calibration, anchorTransform: lockAnchorTransform)
        let calibrationText = CanonicalJSON.serialize(recorded.canonical()) + "\n"
        try Data(calibrationText.utf8).write(to: directory.appendingPathComponent(
            SessionBundleFile.calibration.rawValue))
        for file in [SessionBundleFile.frames, .detections, .events, .snapshots] {
            let url = directory.appendingPathComponent(file.rawValue)
            manager.createFile(atPath: url.path, contents: nil)
            handles[file] = try FileHandle(forWritingTo: url)
        }
    }

    /// Record a processed frame with what happened to its pixels and, when
    /// the AR layer knows it, the frame's side channel (anchor pose, display
    /// transform, orientation).
    @discardableResult
    public func appendFrame(_ frame: CapturedFrame, video: VideoOutcome,
                            delivered: DeliveredFrameMeta? = nil) throws -> RecordedFrameMeta {
        var meta = RecordedFrameMeta(index: frameCount, frame: frame)
        if let delivered {
            meta.tableAnchorTransform = delivered.tableAnchorTransform.map {
                $0.columns.flatMap { [$0.x, $0.y, $0.z, $0.w] }
            }
            meta.displayTransform = delivered.displayTransform
            meta.interfaceOrientation = delivered.viewport.interfaceOrientation
        }
        switch video {
        case .frame(let videoIndex):
            meta.image?.videoFrame = videoIndex
            videoFrameCount += 1
        case .dropped:
            meta.videoDropped = true
            videoDroppedCount += 1
        case .none:
            break
        }
        try append(meta.canonical(), to: .frames)
        frameCount += 1
        if firstFrameTimestamp == nil { firstFrameTimestamp = frame.timestamp }
        lastFrameTimestamp = frame.timestamp
        return meta
    }

    /// What happened to a frame's pixels.
    public enum VideoOutcome: Sendable, Equatable {
        /// Appended to the video as this frame index.
        case frame(Int)
        /// Encoder back-pressure: pixels skipped, frame still recorded.
        case dropped
        /// No video in this bundle.
        case none
    }

    public func appendDetections(frame index: Int, timestamp: TimeInterval,
                                 detections: [Detection2D]) throws {
        let record = RecordedDetectionFrame(frame: index, timestamp: timestamp,
                                            detections: detections.map(RecordedDetection.init))
        try append(record.canonical(), to: .detections)
        detectionFrameCount += 1
    }

    public func appendEvent(_ event: RecordedEvent) throws {
        try append(event.canonical(), to: .events)
        eventCount += 1
    }

    public func appendSnapshot(_ snapshot: RecordedSnapshot) throws {
        try append(snapshot.canonical(), to: .snapshots)
        snapshotCount += 1
    }

    /// Seconds of frames recorded so far (0 until two frames exist).
    public var recordedSeconds: TimeInterval {
        guard let first = firstFrameTimestamp, let last = lastFrameTimestamp else { return 0 }
        return last - first
    }

    /// Close the JSONL files, drop an empty snapshots.jsonl, hash every
    /// file and write manifest.json. The recorder is unusable afterwards.
    @discardableResult
    public func finish(sessionID: String, recordedAt: String, description: String,
                       video: SessionManifest.VideoInfo?, recording: RecordingInfo?) throws -> SessionManifest {
        closeHandles()
        isFinished = true
        let snapshotsURL = directory.appendingPathComponent(SessionBundleFile.snapshots.rawValue)
        if snapshotCount == 0 {
            try? FileManager.default.removeItem(at: snapshotsURL)
        }
        let manifest = SessionManifest(sessionID: sessionID, recordedAt: recordedAt,
                                       source: "device", description: description,
                                       frameCount: frameCount, video: video,
                                       recording: recording,
                                       files: try SessionBundleIntegrity.hashFiles(in: directory))
        let text = CanonicalJSON.serialize(manifest.canonical()) + "\n"
        try Data(text.utf8).write(to: directory.appendingPathComponent(
            SessionBundleFile.manifest.rawValue))
        return manifest
    }

    /// Close files without a manifest (start-up failure). What was written
    /// stays on disk for inspection; the reader will report the missing
    /// manifest.
    public func abort() {
        closeHandles()
        isFinished = true
    }

    private func closeHandles() {
        for handle in handles.values {
            try? handle.synchronize()
            try? handle.close()
        }
        handles.removeAll()
    }

    private func append(_ value: JSONValue, to file: SessionBundleFile) throws {
        guard !isFinished, let handle = handles[file] else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let line = Data((CanonicalJSON.serialize(value) + "\n").utf8)
        try handle.write(contentsOf: line)
        textBytesWritten += line.count
    }
}

// MARK: - The detector seam

/// Where a recorder receives frames. `willDetect` runs before the detector
/// sees the frame and returns the frame's index (nil = not recording this
/// frame, e.g. the cap was reached); `didDetect` runs after the detector
/// returned. A detector that throws produces no `didDetect` — the frame
/// stays in frames.jsonl without detections, and the replay drops it
/// exactly as the live pipeline did.
public protocol FrameRecordingSink: Sendable {
    func willDetect(_ frame: CapturedFrame) async -> Int?
    func didDetect(frame index: Int, timestamp: TimeInterval, detections: [Detection2D]) async
}

/// The switch the app flips: a sink installed here is seen by every
/// `RecordingDetectionProvider` built from the tap. Installing/removing
/// never restarts the pipeline; with no sink the provider is a passthrough.
public final class RecordingTap: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (any FrameRecordingSink)?

    public init() {}

    public var current: (any FrameRecordingSink)? {
        lock.lock()
        defer { lock.unlock() }
        return sink
    }

    public func install(_ sink: any FrameRecordingSink) {
        lock.lock()
        self.sink = sink
        lock.unlock()
    }

    public func remove() {
        lock.lock()
        sink = nil
        lock.unlock()
    }

    /// Wrap a detector so every frame it is asked about is recorded.
    public func wrapping(_ inner: any DetectionProviding) -> any DetectionProviding {
        RecordingDetectionProvider(inner: inner, tap: self)
    }
}

/// DetectionProviding decorator: the pipeline calls `detect` exactly once
/// per frame it processes (frames dropped by its latest-wins ingest never
/// get here), so recording at this seam is what makes frames.jsonl,
/// detections.jsonl and the video 1:1 with what the tracker actually saw.
public struct RecordingDetectionProvider: DetectionProviding {
    public let inner: any DetectionProviding
    public let tap: RecordingTap

    public init(inner: any DetectionProviding, tap: RecordingTap) {
        self.inner = inner
        self.tap = tap
    }

    public func prepare() async throws {
        try await inner.prepare()
    }

    public func detect(in frame: CapturedFrame) async throws -> [Detection2D] {
        guard let sink = tap.current, let index = await sink.willDetect(frame) else {
            return try await inner.detect(in: frame)
        }
        let detections = try await inner.detect(in: frame)
        await sink.didDetect(frame: index, timestamp: frame.timestamp, detections: detections)
        return detections
    }
}
