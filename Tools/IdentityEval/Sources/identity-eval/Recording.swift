//
//  Recording.swift
//  identity-eval
//
//  Reads the parts of a device recording this tool needs (calibration,
//  per-frame pose and intrinsics, detector boxes) with plain Foundation,
//  and decodes the video one frame at a time into the same bi-planar
//  YCbCr buffers ARKit delivers, so the app's own PixelBufferReader does
//  the colour conversion.
//

import AVFoundation
import CoreVideo
import CueSyncCore
import Foundation
import PerceptionKit
import TableSpace

struct RecordedFrame {
    var index: Int
    var videoFrame: Int
    var frame: CapturedFrame
    var detections: [Detection2D]
}

struct Recording {
    var calibration: TableCalibration
    var frames: [RecordedFrame]
    var videoURL: URL
}

enum RecordingError: Error, CustomStringConvertible {
    case missing(String)
    case malformed(String)

    var description: String {
        switch self {
        case .missing(let what): "missing \(what)"
        case .malformed(let what): "malformed \(what)"
        }
    }
}

enum RecordingLoader {
    static func load(directory: URL) throws -> Recording {
        let calibration = try loadCalibration(directory.appendingPathComponent("calibration.json"))
        let detectionLines = try jsonLines(directory.appendingPathComponent("detections.jsonl"))
        var detectionsByFrame: [Int: [Detection2D]] = [:]
        for line in detectionLines {
            guard let frame = line["frame"] as? Int,
                  let list = line["detections"] as? [[String: Any]] else { continue }
            detectionsByFrame[frame] = list.compactMap { entry in
                guard let label = entry["label"] as? String,
                      let x = entry["x"] as? Double, let y = entry["y"] as? Double,
                      let width = entry["width"] as? Double, let height = entry["height"] as? Double,
                      let confidence = entry["confidence"] as? Double else { return nil }
                return Detection2D(classLabel: label,
                                   boundingBox: NormalizedRect(x: x, y: y, width: width, height: height),
                                   confidence: confidence)
            }
        }
        var frames: [RecordedFrame] = []
        for line in try jsonLines(directory.appendingPathComponent("frames.jsonl")) {
            guard let index = line["index"] as? Int,
                  let flat = line["cameraTransform"] as? [Double], flat.count == 16,
                  let timestamp = line["timestamp"] as? Double else {
                throw RecordingError.malformed("frames.jsonl line")
            }
            var intrinsics: CameraIntrinsics?
            if let raw = line["intrinsics"] as? [String: Double] {
                intrinsics = CameraIntrinsics(
                    focalX: raw["focalX"] ?? 0, focalY: raw["focalY"] ?? 0,
                    principalX: raw["principalX"] ?? 0, principalY: raw["principalY"] ?? 0,
                    imageWidth: raw["imageWidth"] ?? 0, imageHeight: raw["imageHeight"] ?? 0)
            }
            let image = line["image"] as? [String: Any]
            if image?["videoDropped"] as? Bool == true { continue }
            let videoFrame = image?["videoFrame"] as? Int ?? index
            let transform = Transform3D(columns: (0..<4).map { column in
                SIMD4(flat[column * 4], flat[column * 4 + 1], flat[column * 4 + 2], flat[column * 4 + 3])
            })
            frames.append(RecordedFrame(
                index: index, videoFrame: videoFrame,
                frame: CapturedFrame(timestamp: timestamp, cameraTransform: transform,
                                     image: nil, intrinsics: intrinsics),
                detections: detectionsByFrame[index] ?? []))
        }
        frames.sort { $0.index < $1.index }
        return Recording(calibration: calibration, frames: frames,
                         videoURL: directory.appendingPathComponent("video.mp4"))
    }

    private static func loadCalibration(_ url: URL) throws -> TableCalibration {
        guard let data = try? Data(contentsOf: url),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let origin = object["origin"] as? [Double], origin.count == 3,
              let xAxis = object["xAxis"] as? [Double], xAxis.count == 3,
              let yAxis = object["yAxis"] as? [Double], yAxis.count == 3,
              let size = object["size"] as? [String: Any], let name = size["name"] as? String else {
            throw RecordingError.malformed("calibration.json")
        }
        let tableSize: TableSize
        switch name {
        case "sevenFoot": tableSize = .sevenFoot
        case "eightFoot": tableSize = .eightFoot
        case "nineFoot": tableSize = .nineFoot
        default: throw RecordingError.malformed("table size \(name)")
        }
        return TableCalibration(origin: Vec3(origin[0], origin[1], origin[2]),
                                xAxis: Vec3(xAxis[0], xAxis[1], xAxis[2]),
                                yAxis: Vec3(yAxis[0], yAxis[1], yAxis[2]), size: tableSize)
    }

    private static func jsonLines(_ url: URL) throws -> [[String: Any]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw RecordingError.missing(url.lastPathComponent)
        }
        return try text.split(separator: "\n").map { line in
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                throw RecordingError.malformed(url.lastPathComponent)
            }
            return object
        }
    }
}

/// Sequential decoder: frame `n` is the n-th video sample.
final class VideoDecoder {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput

    init(url: URL) throws {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else {
            throw RecordingError.missing("video track")
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        reader.add(output)
        guard reader.startReading() else { throw RecordingError.malformed("video (cannot start reading)") }
        self.reader = reader
        self.output = output
    }

    func nextBuffer() -> CVPixelBuffer? {
        guard let sample = output.copyNextSampleBuffer() else { return nil }
        return CMSampleBufferGetImageBuffer(sample)
    }
}
