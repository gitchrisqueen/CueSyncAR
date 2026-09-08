#if canImport(AVFoundation) && canImport(CoreVideo)
import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import SessionReplay

// Apple-platform only: the encoder is AVFoundation. Runs in the macOS
// package-test job; the Linux job compiles none of this.

private func temporaryDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SessionReplayTests-\(name)-\(UInt64.random(in: 0...UInt64.max))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeBuffer(width: Int, height: Int, gray: UInt8) throws -> CVPixelBuffer {
    var created: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                        attributes, &created)
    let buffer = try #require(created)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = try #require(CVPixelBufferGetBaseAddress(buffer))
    memset(base, Int32(gray), CVPixelBufferGetBytesPerRow(buffer) * height)
    return buffer
}

/// Decoded frame presentation times, in display order.
private func readBack(_ url: URL) async throws -> [Double] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    #expect(reader.startReading())
    var times: [Double] = []
    while let sample = output.copyNextSampleBuffer() {
        guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        if time.isValid { times.append(time.seconds) }
    }
    return times
}

/// The device appends at the pipeline's 5–15 Hz, well inside the
/// encoder's pace; a test appending back-to-back must wait its turn or
/// it is (correctly) told the encoder is busy.
private func waitUntilReady(_ writer: VideoFrameWriter) async {
    for _ in 0..<200 where !writer.isReadyForMoreFrames {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@Suite("VideoFrameWriter")
struct VideoFrameWriterTests {
    @Test func writesEveryAppendedFrameAtItsCaptureTime() async throws {
        let directory = try temporaryDirectory("video")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(VideoFrameWriter.fileName)
        let writer = try VideoFrameWriter(url: url, width: 64, height: 48,
                                          pixelFormat: kCVPixelFormatType_32BGRA)
        // Capture times on an arbitrary base (system uptime on device);
        // the first frame becomes t = 0.
        let base = 12_345.678
        for index in 0..<6 {
            let buffer = try makeBuffer(width: 64, height: 48, gray: UInt8(40 * index))
            await waitUntilReady(writer)
            let result = writer.append(buffer, at: base + Double(index) * 0.1)
            #expect(result == .appended(index: index))
        }
        #expect(writer.frameCount == 6)
        try await writer.finish()
        #expect(writer.isFinished)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let times = try await readBack(url)
        #expect(times.count == 6)
        for (index, time) in times.enumerated() {
            #expect(abs(time - Double(index) * 0.1) < 1e-4, "frame \(index) at \(time)")
        }
    }

    @Test func rejectsNonMonotonicTimestampsAndAppendsAfterFinish() async throws {
        let directory = try temporaryDirectory("video-order")
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try VideoFrameWriter(url: directory.appendingPathComponent("v.mp4"),
                                          width: 64, height: 48,
                                          pixelFormat: kCVPixelFormatType_32BGRA)
        let buffer = try makeBuffer(width: 64, height: 48, gray: 128)
        #expect(writer.append(buffer, at: 1.0) == .appended(index: 0))
        await waitUntilReady(writer)
        #expect(writer.append(buffer, at: 1.0) == .dropped(reason: "non-monotonic timestamp"))
        #expect(writer.append(buffer, at: 0.5) == .dropped(reason: "non-monotonic timestamp"))
        #expect(writer.droppedCount == 2)
        try await writer.finish()
        #expect(writer.append(buffer, at: 2.0) == .dropped(reason: "writer finished"))
        await #expect(throws: VideoFrameWriter.WriterError.finished) {
            try await writer.finish()
        }
    }

    @Test func aWriterThatNeverGotAFrameFinishesQuietly() async throws {
        let directory = try temporaryDirectory("video-empty")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("v.mp4")
        let writer = try VideoFrameWriter(url: url, width: 64, height: 48,
                                          pixelFormat: kCVPixelFormatType_32BGRA)
        try await writer.finish()
        #expect(writer.frameCount == 0)
    }

    @Test func sizeEstimateFollowsTheBitRate() {
        #expect(VideoFrameWriter.megabytesPerMinute(bitRate: 8_000_000) == 60)
        #expect(VideoFrameWriter.megabytesPerMinute() == 45)
    }
}
#endif
