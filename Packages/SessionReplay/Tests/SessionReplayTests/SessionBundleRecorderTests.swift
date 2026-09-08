import ARExperience
import CueSyncCore
import Foundation
import TableSpace
import Testing
@testable import SessionReplay

private func temporaryDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SessionReplayTests-\(name)-\(UInt64.random(in: 0...UInt64.max))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func recordingInfo(stopReason: String = "user") -> RecordingInfo {
    RecordingInfo(appCommit: "abc1234", appBranch: "claude/session-recorder", appDirty: false,
                  appVersion: "1.0 (1)", detector: "on-device",
                  modelName: "BallDetector", modelSHA256: String(repeating: "0", count: 64),
                  hardwareModel: "iPad13,18", systemVersion: "26.0",
                  displayScale: 2, viewWidth: 1024, viewHeight: 768,
                  nativeWidth: 1920, nativeHeight: 1440,
                  tickMilliseconds: 150, snapshotIntervalSeconds: 1,
                  capSeconds: 300, durationSeconds: 4.4,
                  videoCodec: "h264", videoFrames: 44, videoDroppedFrames: 1,
                  guideSpeed: 3.5, visibleMissGrace: 0.75, practiceMode: "freePlay",
                  metricPalette: true, followsTableAnchor: true, stopReason: stopReason)
}

/// Stream the scripted bundle through the recorder the way the device
/// would: frame line, then detections line, events as they happen.
private func streamScriptedBundle(into directory: URL,
                                  dropVideoAt droppedFrame: Int? = nil,
                                  delivered: DeliveredFrameMeta? = nil) throws -> SessionBundleRecorder {
    let bundle = ScriptedFiveBall.makeBundle()
    let recorder = try SessionBundleRecorder(directory: directory,
                                             calibration: ScriptedFiveBall.calibration)
    let detectionsByFrame = Dictionary(uniqueKeysWithValues: bundle.detections.map { ($0.frame, $0) })
    let eventsByFrame = Dictionary(grouping: bundle.events, by: \.frame)
    var videoIndex = 0
    for index in 0..<ScriptedFiveBall.frameCount {
        let frame = ScriptedFiveBall.capturedFrame(index)
        let outcome: SessionBundleRecorder.VideoOutcome
        if let droppedFrame {
            if index == droppedFrame {
                outcome = .dropped
            } else {
                outcome = .frame(videoIndex)
                videoIndex += 1
            }
        } else {
            outcome = .none
        }
        let meta = try recorder.appendFrame(frame, video: outcome,
                                            delivered: delivered.map {
                                                var d = $0
                                                d.timestamp = frame.timestamp
                                                return d
                                            })
        #expect(meta.index == index)
        if let recorded = detectionsByFrame[index] {
            try recorder.appendDetections(frame: index, timestamp: frame.timestamp,
                                          detections: recorded.detections.map(\.detection2D))
        }
        for event in eventsByFrame[index] ?? [] {
            try recorder.appendEvent(event)
        }
    }
    return recorder
}

@Suite("SessionBundleRecorder — streaming writer")
struct SessionBundleRecorderTests {
    @Test func streamedFilesAreByteIdenticalToTheBatchWriter() throws {
        let directory = try temporaryDirectory("stream")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try streamScriptedBundle(into: directory)
        #expect(recorder.frameCount == ScriptedFiveBall.frameCount)
        #expect(recorder.latestFrameIndex == ScriptedFiveBall.frameCount - 1)
        #expect(recorder.detectionFrameCount == ScriptedFiveBall.makeBundle().detections.count)
        #expect(recorder.eventCount == 3)
        #expect(recorder.recordedSeconds == ScriptedFiveBall.timestamp(44) - ScriptedFiveBall.timestamp(0))
        #expect(recorder.textBytesWritten > 0)

        let manifest = try recorder.finish(sessionID: "device-test", recordedAt: "2026-09-07T00:00:00Z",
                                           description: "streamed", video: nil,
                                           recording: recordingInfo())
        #expect(recorder.isFinished)
        #expect(manifest.frameCount == ScriptedFiveBall.frameCount)
        #expect(manifest.source == "device")

        let batch = SessionBundleWriter.inputTexts(for: ScriptedFiveBall.makeBundle())
        for file in [SessionBundleFile.calibration, .frames, .detections, .events] {
            let streamed = try Data(contentsOf: directory.appendingPathComponent(file.rawValue))
            #expect(streamed == Data(batch[file]!.utf8), Comment(rawValue: file.rawValue))
        }
        // No snapshots were recorded, so the (empty) file is gone.
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(SessionBundleFile.snapshots.rawValue).path))
    }

    @Test func recordedBundleReadsBackValidatesAndReplaysLikeTheOriginal() async throws {
        let directory = try temporaryDirectory("replay")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try streamScriptedBundle(into: directory)
        try recorder.finish(sessionID: "device-test", recordedAt: "2026-09-07T00:00:00Z",
                            description: "streamed", video: nil, recording: recordingInfo())
        let reread = try SessionBundleReader().read(from: directory)
        #expect(reread.manifest.recording == recordingInfo())
        #expect(reread.manifest.files?.keys.sorted()
                == ["calibration.json", "detections.jsonl", "events.jsonl", "frames.jsonl"])

        // Judge from the six-decimal values CI reads, as the golden does:
        // the batch-written bundle read back replays byte-equal to the
        // streamed one read back.
        let batchDirectory = try temporaryDirectory("replay-batch")
        defer { try? FileManager.default.removeItem(at: batchDirectory) }
        try SessionBundleWriter().write(ScriptedFiveBall.makeBundle(), to: batchDirectory)
        let expected = try await ReplayRunner().run(SessionBundleReader().read(from: batchDirectory))
        let actual = try await ReplayRunner().run(reread)
        #expect(actual.outputsText == expected.outputsText)
        #expect(actual.droppedFrames.isEmpty)
        #expect(actual.outputs.count == ScriptedFiveBall.frameCount)
    }

    @Test func manifestHashesVerifyAndTamperingIsCaught() throws {
        let directory = try temporaryDirectory("integrity")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try streamScriptedBundle(into: directory)
        let manifest = try recorder.finish(sessionID: "device-test", recordedAt: "2026-09-07T00:00:00Z",
                                           description: "streamed", video: nil,
                                           recording: recordingInfo())
        for (name, digest) in try #require(manifest.files) {
            #expect(try SHA256.hexDigest(ofFileAt: directory.appendingPathComponent(name)) == digest)
        }
        #expect(try SessionBundleIntegrity.verify(directory: directory)
                == ["calibration.json", "detections.jsonl", "events.jsonl", "frames.jsonl"])

        let events = directory.appendingPathComponent(SessionBundleFile.events.rawValue)
        var text = try String(contentsOf: events, encoding: .utf8)
        text += "\n"
        try Data(text.utf8).write(to: events)
        #expect(throws: SessionBundleError.integrityMismatch("events.jsonl")) {
            try SessionBundleIntegrity.verify(directory: directory)
        }
        try FileManager.default.removeItem(at: events)
        #expect(throws: SessionBundleError.integrityFileMissing("events.jsonl")) {
            try SessionBundleIntegrity.verify(directory: directory)
        }
    }

    @Test func scriptedBundlesHaveNoHashesToVerify() throws {
        let directory = try temporaryDirectory("nohash")
        defer { try? FileManager.default.removeItem(at: directory) }
        try SessionBundleWriter().write(ScriptedFiveBall.makeBundle(), to: directory)
        #expect(throws: SessionBundleError.manifestWithoutHashes) {
            try SessionBundleIntegrity.verify(directory: directory)
        }
    }

    @Test func videoOutcomesAndSideChannelLandOnTheFrameLine() throws {
        let directory = try temporaryDirectory("video")
        defer { try? FileManager.default.removeItem(at: directory) }
        let delivered = DeliveredFrameMeta(
            timestamp: 0, tableAnchorTransform: .identity, displayTransform: [0, 1, -1, 0, 1, 0],
            viewport: ViewportInfo(width: 390, height: 844, displayScale: 3,
                                   interfaceOrientation: "portrait"))
        let recorder = try streamScriptedBundle(into: directory, dropVideoAt: 7, delivered: delivered)
        #expect(recorder.videoFrameCount == ScriptedFiveBall.frameCount - 1)
        #expect(recorder.videoDroppedCount == 1)
        try recorder.finish(sessionID: "device-test", recordedAt: "2026-09-07T00:00:00Z",
                            description: "streamed",
                            video: SessionManifest.VideoInfo(fileName: "video.mp4", width: 1920, height: 1440),
                            recording: recordingInfo())
        let reread = try SessionBundleReader().read(from: directory)
        #expect(reread.manifest.video?.fileName == "video.mp4")
        #expect(reread.frames[6].image?.videoFrame == 6)
        #expect(reread.frames[6].videoDropped == nil)
        #expect(reread.frames[7].image?.videoFrame == nil)
        #expect(reread.frames[7].videoDropped == true)
        // Frame 8's pixels became video frame 7: indices stay contiguous
        // in the FILE while the flag marks the gap in the RECORD.
        #expect(reread.frames[8].image?.videoFrame == 7)
        #expect(reread.frames[0].tableAnchorTransform?.count == 16)
        #expect(reread.frames[0].displayTransform == [0, 1, -1, 0, 1, 0])
        #expect(reread.frames[0].interfaceOrientation == "portrait")
        // The textual form carries the flag only where it is set.
        let lines = try String(contentsOf: directory.appendingPathComponent("frames.jsonl"),
                               encoding: .utf8).split(separator: "\n")
        #expect(lines[7].contains("\"videoDropped\":true"))
        #expect(!lines[6].contains("videoDropped"))
    }

    @Test func snapshotsRoundTripThroughTheRecorderAndTheBatchWriter() throws {
        let directory = try temporaryDirectory("snapshots")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try streamScriptedBundle(into: directory)
        let pose = PoseSample(frameTimestamp: ScriptedFiveBall.timestamp(3),
                              cameraTransform: ScriptedFiveBall.cameraTransform(frame: 3),
                              tableAnchorTransform: .identity)
        let projection = ProjectionSnapshot(
            before: pose, after: pose,
            markers: [ProjectedMarker(marker: RenderedMarker(kind: .cueBall, id: 0,
                                                             world: Vec3(0.1, 0.2, 0.3)),
                                      screen: Vec2(120.5, 300.25)),
                      ProjectedMarker(marker: RenderedMarker(kind: .ghostBall, world: Vec3(1, 2, 3)),
                                      screen: nil)],
            viewport: ViewportInfo(width: 390, height: 844, displayScale: 3,
                                   interfaceOrientation: "portrait"),
            displayTransform: [0, 1, -1, 0, 1, 0], paletteMode: .metric)
        let snapshot = RecordedSnapshot(index: 0, frame: 3, projection: projection)
        #expect(snapshot.poseStable)
        #expect(snapshot.metricPalette)
        #expect(snapshot.markers[0].screen == [120.5, 300.25])
        #expect(snapshot.markers[1].screen == nil)
        #expect(snapshot.markers[1].id == nil)
        try recorder.appendSnapshot(snapshot)
        try recorder.finish(sessionID: "device-test", recordedAt: "2026-09-07T00:00:00Z",
                            description: "streamed", video: nil, recording: recordingInfo())

        let reread = try SessionBundleReader().read(from: directory)
        // Values pass through the six-decimal grid on the way to disk, so
        // compare on the grid: the text is the fixed point.
        #expect(reread.snapshots.count == 1)
        #expect(reread.snapshots[0].markers == snapshot.markers)
        #expect(reread.snapshots[0].poseStable)
        #expect(reread.snapshots[0].frame == 3)
        #expect(reread.snapshots[0].displayTransform == snapshot.displayTransform)
        #expect(reread.manifest.files?["snapshots.jsonl"] != nil)
        let streamed = try String(contentsOf: directory.appendingPathComponent("snapshots.jsonl"),
                                  encoding: .utf8)
        #expect(streamed == CanonicalJSON.serializeLines([snapshot.canonical()]))
        // The batch writer emits the same bytes for the reread snapshot.
        #expect(SessionBundleWriter.inputTexts(for: reread)[.snapshots] == streamed)
    }

    @Test func lockAnchorTransformLandsInCalibrationJSON() throws {
        let directory = try temporaryDirectory("anchor")
        defer { try? FileManager.default.removeItem(at: directory) }
        var lock = Transform3D.identity
        lock.columns[3] = SIMD4(0.25, -0.5, 1.0, 1)
        let recorder = try SessionBundleRecorder(directory: directory,
                                                 calibration: ScriptedFiveBall.calibration,
                                                 lockAnchorTransform: lock)
        try recorder.appendFrame(ScriptedFiveBall.capturedFrame(0), video: .none)
        try recorder.finish(sessionID: "x", recordedAt: "y", description: "z", video: nil,
                            recording: recordingInfo())
        let reread = try SessionBundleReader().read(from: directory)
        #expect(try reread.calibration.anchorTransform3D() == lock)
        #expect(reread.manifest.recording?.followsTableAnchor == true)
        // Without one the key is absent (scripted bundles stay byte-identical).
        #expect(RecordedCalibration(ScriptedFiveBall.calibration).anchorTransform == nil)
        #expect(!CanonicalJSON.serialize(RecordedCalibration(ScriptedFiveBall.calibration).canonical())
            .contains("anchorTransform"))
    }

    @Test func abortLeavesNoManifestAndRefusesFurtherWrites() throws {
        let directory = try temporaryDirectory("abort")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try SessionBundleRecorder(directory: directory,
                                                 calibration: ScriptedFiveBall.calibration)
        try recorder.appendFrame(ScriptedFiveBall.capturedFrame(0), video: .none)
        recorder.abort()
        #expect(recorder.isFinished)
        #expect(throws: (any Error).self) {
            try recorder.appendFrame(ScriptedFiveBall.capturedFrame(1), video: .none)
        }
        #expect(throws: SessionBundleError.missingFile("manifest.json")) {
            try SessionBundleReader().read(from: directory)
        }
        // A second recorder refuses a directory that already holds a bundle.
        try recorder.finish(sessionID: "x", recordedAt: "y", description: "z",
                            video: nil, recording: nil)
        #expect(throws: (any Error).self) {
            try SessionBundleRecorder(directory: directory, calibration: ScriptedFiveBall.calibration)
        }
    }

    @Test func nothingHostSpecificReachesTheManifest() throws {
        let directory = try temporaryDirectory("privacy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try streamScriptedBundle(into: directory)
        try recorder.finish(sessionID: "device-20260907T000000Z", recordedAt: "2026-09-07T00:00:00Z",
                            description: "Device recording; on-device detector; 8-ft table",
                            video: nil, recording: recordingInfo())
        let text = try String(contentsOf: directory.appendingPathComponent("manifest.json"),
                              encoding: .utf8)
        #expect(!text.contains(directory.path), "manifest must not carry the bundle's own path")
        #expect(!text.contains("/Users"))
        #expect(!text.contains("/var"))
        #expect(!text.contains(NSUserName()))
    }
}

/// A sink that remembers the order in which the seam called it.
private actor SpySink: FrameRecordingSink {
    var calls: [String] = []
    var recording = true
    private var nextIndex = 0

    func willDetect(_ frame: CapturedFrame) async -> Int? {
        calls.append("will \(frame.timestamp)")
        guard recording else { return nil }
        defer { nextIndex += 1 }
        return nextIndex
    }

    func didDetect(frame index: Int, timestamp: TimeInterval, detections: [Detection2D]) async {
        calls.append("did \(index) \(timestamp) \(detections.count)")
    }

    func stop() { recording = false }
}

private struct ThrowingDetector: DetectionProviding {
    struct Boom: Error {}
    func prepare() async throws {}
    func detect(in frame: CapturedFrame) async throws -> [Detection2D] { throw Boom() }
}

@Suite("RecordingDetectionProvider — the 1:1 seam")
struct RecordingDetectionProviderTests {
    @Test func recordsBeforeAndAfterEveryDetectionInOrder() async throws {
        let tap = RecordingTap()
        let sink = SpySink()
        tap.install(sink)
        let detector = tap.wrapping(RecordedDetectionProvider(bundle: ScriptedFiveBall.makeBundle()))
        try await detector.prepare()
        for index in 0..<3 {
            let frame = ScriptedFiveBall.capturedFrame(index)
            let detections = try await detector.detect(in: frame)
            #expect(detections.count == 5)
        }
        let calls = await sink.calls
        let expected = (0..<3).flatMap { index -> [String] in
            let t = ScriptedFiveBall.timestamp(index)
            return ["will \(t)", "did \(index) \(t) 5"]
        }
        #expect(calls == expected)
    }

    @Test func passesThroughWithoutASinkOrWhenTheSinkDeclines() async throws {
        let tap = RecordingTap()
        let detector = tap.wrapping(RecordedDetectionProvider(bundle: ScriptedFiveBall.makeBundle()))
        #expect(try await detector.detect(in: ScriptedFiveBall.capturedFrame(0)).count == 5)

        let sink = SpySink()
        await sink.stop()
        tap.install(sink)
        #expect(tap.current != nil)
        #expect(try await detector.detect(in: ScriptedFiveBall.capturedFrame(1)).count == 5)
        #expect(await sink.calls == ["will 100.1"], "declined frame: no didDetect, detector still ran")

        tap.remove()
        #expect(tap.current == nil)
        #expect(try await detector.detect(in: ScriptedFiveBall.capturedFrame(2)).count == 5)
        #expect(await sink.calls == ["will 100.1"])
    }

    @Test func aThrowingDetectorLeavesTheFrameWithoutDetections() async throws {
        let tap = RecordingTap()
        let sink = SpySink()
        tap.install(sink)
        let detector = tap.wrapping(ThrowingDetector())
        await #expect(throws: ThrowingDetector.Boom.self) {
            try await detector.detect(in: ScriptedFiveBall.capturedFrame(0))
        }
        #expect(await sink.calls == ["will 100.0"])
    }
}
