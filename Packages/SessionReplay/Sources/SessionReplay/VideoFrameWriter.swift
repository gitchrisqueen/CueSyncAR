//
//  VideoFrameWriter.swift
//  SessionReplay
//
//  Encodes the recorded frames' pixels to an H.264 .mp4 with the frames'
//  own capture timestamps as presentation times (variable rate — the
//  pipeline processes 5–15 frames/s depending on the detector). Frame N of
//  the file is the frame whose frames.jsonl line says `videoFrame: N`.
//
//  Retention: the buffers appended here are the coordinator's deep copies
//  (ARSessionCoordinator.copyPixelBuffer), never ARKit's pool buffers —
//  the encoder may hold one for a few milliseconds without touching the
//  capture pool. Back-pressure is reported, never queued: a frame the
//  encoder cannot take right now is dropped and flagged by the caller.
//

#if canImport(AVFoundation) && canImport(CoreVideo)
import AVFoundation
import CoreVideo
import Foundation

/// Single-owner by contract: exactly one actor (the app's SessionRecorder)
/// calls `append` and `finish`, so the mutable bookkeeping is never touched
/// from two isolation domains. Declared `@unchecked Sendable` only so that
/// owner can await `finish()` (a nonisolated async call) on an instance it
/// stores — Swift 6 otherwise rejects sending a non-Sendable value it
/// still references.
public final class VideoFrameWriter: @unchecked Sendable {
    public enum AppendResult: Equatable, Sendable {
        case appended(index: Int)
        case dropped(reason: String)
    }

    public enum WriterError: Error, Equatable {
        case finished
        case failed(String)
    }

    /// Average H.264 bitrate. 6 Mbit/s at 1920×1440 keeps ball edges crisp
    /// for a later detector re-run; the size shown in the HUD derives from
    /// this constant so the two never disagree.
    public static let defaultBitRate = 6_000_000
    public static let fileName = "video.mp4"
    public static let codecName = "h264"

    /// Megabytes of video per minute at `bitRate` — what the record
    /// confirmation shows before the user commits.
    public static func megabytesPerMinute(bitRate: Int = defaultBitRate) -> Double {
        Double(bitRate) * 60 / 8 / 1_000_000
    }

    public let url: URL
    public let width: Int
    public let height: Int
    public private(set) var frameCount = 0
    public private(set) var droppedCount = 0
    public private(set) var isFinished = false

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var firstSeconds: TimeInterval?
    private var lastPresentation: CMTime = .invalid

    /// - Parameters:
    ///   - pixelFormat: the format of the buffers that will be appended
    ///     (ARKit captures 420YpCbCr8BiPlanarFullRange).
    public init(url: URL, width: Int, height: Int, pixelFormat: OSType,
                bitRate: Int = VideoFrameWriter.defaultBitRate) throws {
        self.url = url
        self.width = width
        self.height = height
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                // No B-frames: decode order == display order, so "frame N
                // of the file" is unambiguous for every tool that reads it.
                AVVideoAllowFrameReorderingKey: false,
                // Keyframe every ~2 s of wall time at the pipeline's rate,
                // so seeking to any recorded frame is cheap.
                AVVideoMaxKeyFrameIntervalKey: 20
            ]
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ])
        guard writer.canAdd(input) else {
            throw WriterError.failed("cannot add video input")
        }
        writer.add(input)
    }

    /// Whether the encoder would take a frame right now. `append` checks
    /// this itself; exposed so callers (and tests) can pace themselves.
    public var isReadyForMoreFrames: Bool {
        !isFinished && (writer.status == .unknown || input.isReadyForMoreMediaData)
    }

    /// Append one frame at its capture time (seconds, any monotonic base;
    /// the first appended frame defines t = 0). Never blocks: an encoder
    /// that is not ready yields `.dropped`.
    public func append(_ buffer: CVPixelBuffer, at seconds: TimeInterval) -> AppendResult {
        guard !isFinished else { return .dropped(reason: "writer finished") }
        if writer.status == .unknown {
            guard writer.startWriting() else {
                return dropped("start failed: \(writer.error?.localizedDescription ?? "unknown")")
            }
            writer.startSession(atSourceTime: .zero)
        }
        guard writer.status == .writing else {
            return dropped("writer status \(writer.status.rawValue)")
        }
        let first = firstSeconds ?? seconds
        firstSeconds = first
        let presentation = CMTime(value: Int64(((seconds - first) * 1_000_000).rounded()),
                                  timescale: 1_000_000)
        guard lastPresentation == .invalid || presentation > lastPresentation else {
            return dropped("non-monotonic timestamp")
        }
        guard input.isReadyForMoreMediaData else {
            return dropped("encoder busy")
        }
        guard adaptor.append(buffer, withPresentationTime: presentation) else {
            return dropped("append failed: \(writer.error?.localizedDescription ?? "unknown")")
        }
        lastPresentation = presentation
        let index = frameCount
        frameCount += 1
        return .appended(index: index)
    }

    /// Finalize the file. Safe to call once; a writer that never received
    /// a frame produces no file.
    public func finish() async throws {
        guard !isFinished else { throw WriterError.finished }
        isFinished = true
        guard writer.status == .writing else {
            writer.cancelWriting()
            return
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw WriterError.failed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
    }

    private func dropped(_ reason: String) -> AppendResult {
        droppedCount += 1
        return .dropped(reason: reason)
    }
}
#endif
