//
//  Sweep.swift
//  detection-eval
//
//  Batch variant sweep for the far-recall measurement:
//
//    detection-eval --sweep-dir <frames> --model <BallDetector.mlpackage> --out <results.jsonl>
//        [--setting name=conf,iou ...]   NMS threshold overrides ("-" keeps the model's own)
//        [--tile name=x,y,size ...]      zoomed tile windows (fractions of the frame)
//        [--compute cpu|gpu|all]
//
//  For every image (png/jpg, sorted by name) and every setting it writes one
//  JSON line per variant: the full-frame pass, and for every tile window the
//  tile-only boxes (mapped to frame space, after the edge/stick filters) and
//  the merged result, exactly as `FarTileDetector` produces them. Boxes are
//  normalized top-left (x, y, width, height). Per-pass inference seconds are
//  recorded. Scoring against a ground-truth layout lives outside this tool.
//

import CoreGraphics
import CoreML
import CoreVideo
import CueSyncCore
import Foundation
import PerceptionKit

struct SweepSetting {
    var name: String
    var confidence: Double?
    var iou: Double?
}

struct SweepTile {
    var name: String
    var region: FarTileRegion
}

struct SweepArguments {
    var modelPath = ""
    var directory = ""
    var outPath = ""
    var computeUnits: MLComputeUnits = .cpuOnly
    var settings: [SweepSetting] = []
    var tiles: [SweepTile] = []

    static func parse(_ arguments: [String]) throws -> SweepArguments {
        var result = SweepArguments()
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            guard flag.hasPrefix("--"), index + 1 < arguments.count else {
                throw EvalError.usage("unexpected argument '\(flag)'")
            }
            let value = arguments[index + 1]
            switch flag {
            case "--sweep-dir": result.directory = value
            case "--model": result.modelPath = value
            case "--out": result.outPath = value
            case "--compute":
                switch value {
                case "cpu": result.computeUnits = .cpuOnly
                case "gpu": result.computeUnits = .cpuAndGPU
                case "all": result.computeUnits = .all
                default: throw EvalError.usage("--compute must be cpu|gpu|all")
                }
            case "--setting":
                let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
                let numbers = (parts.count == 2 ? parts[1] : "").split(separator: ",").map(String.init)
                guard numbers.count == 2 else {
                    throw EvalError.usage("--setting needs name=conf,iou (use - to keep a default)")
                }
                result.settings.append(SweepSetting(name: parts[0],
                                                    confidence: Double(numbers[0]),
                                                    iou: Double(numbers[1])))
            case "--tile":
                let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
                let numbers = (parts.count == 2 ? parts[1] : "").split(separator: ",").compactMap { Double($0) }
                guard numbers.count == 3,
                      let region = FarTileRegion(x: numbers[0], y: numbers[1], size: numbers[2]) else {
                    throw EvalError.usage("--tile needs name=x,y,size with the window inside the frame")
                }
                result.tiles.append(SweepTile(name: parts[0], region: region))
            default:
                throw EvalError.usage("unknown flag '\(flag)'")
            }
            index += 2
        }
        guard !result.directory.isEmpty, !result.modelPath.isEmpty, !result.outPath.isEmpty else {
            throw EvalError.usage("--sweep-dir, --model and --out are required")
        }
        if result.settings.isEmpty {
            result.settings = [SweepSetting(name: "base", confidence: nil, iou: nil)]
        }
        return result
    }
}

private struct SweepBox: Codable {
    var label: String
    var confidence: Double
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ detection: Detection2D) {
        label = detection.classLabel
        confidence = detection.confidence
        x = detection.boundingBox.x
        y = detection.boundingBox.y
        width = detection.boundingBox.width
        height = detection.boundingBox.height
    }
}

private struct SweepTileResult: Codable {
    var tile: String
    var tileSeconds: Double
    var tileOnly: [SweepBox]
    var merged: [SweepBox]
}

private struct SweepRow: Codable {
    var image: String
    var setting: String
    var fullSeconds: Double
    var full: [SweepBox]
    var tiles: [SweepTileResult]
}

private func seconds(since start: ContinuousClock.Instant) -> Double {
    let elapsed = ContinuousClock.now - start
    return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
}

func runSweep(_ arguments: SweepArguments) async throws {
    let compiled = try await MLModel.compileModel(at: URL(fileURLWithPath: arguments.modelPath))
    let configuration = MLModelConfiguration()
    configuration.computeUnits = arguments.computeUnits
    let model = try MLModel(contentsOf: compiled, configuration: configuration)

    var providers = [(SweepSetting, CoreMLDetectionProvider)]()
    for setting in arguments.settings {
        providers.append((setting, try CoreMLDetectionProvider(model: model,
                                                               confidenceThreshold: setting.confidence,
                                                               iouThreshold: setting.iou)))
    }

    let names = try FileManager.default.contentsOfDirectory(atPath: arguments.directory)
        .filter { $0.hasSuffix(".png") || $0.hasSuffix(".jpg") }
        .sorted()
    guard !names.isEmpty else { throw EvalError.imageLoad(arguments.directory) }

    FileManager.default.createFile(atPath: arguments.outPath, contents: nil)
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: arguments.outPath))
    defer { try? handle.close() }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    // One untimed inference so Core ML's first-call setup is not counted
    // against the first image's variants.
    if let first = names.first, let (_, provider) = providers.first {
        let warm = try pixelBuffer(from: try loadCGImage(at: arguments.directory + "/" + first))
        _ = try await provider.detect(in: CapturedFrame(timestamp: 0, cameraTransform: .identity,
                                                        image: PixelBufferImage(pixelBuffer: warm)))
    }

    for name in names {
        let cgImage = try loadCGImage(at: arguments.directory + "/" + name)
        let buffer = try pixelBuffer(from: cgImage)
        let frame = CapturedFrame(timestamp: 0, cameraTransform: .identity,
                                  image: PixelBufferImage(pixelBuffer: buffer))
        for (setting, provider) in providers {
            let fullStart = ContinuousClock.now
            let full = try await provider.detect(in: frame)
            let fullSeconds = seconds(since: fullStart)

            var tileResults = [SweepTileResult]()
            for tile in arguments.tiles {
                guard let crop = tile.region.pixelCrop(frameWidth: cgImage.width,
                                                       frameHeight: cgImage.height) else { continue }
                let start = ContinuousClock.now
                let cropped = try PixelBufferCropper.crop(buffer, to: crop)
                let raw = try await provider.detect(in: CapturedFrame(
                    timestamp: 0, cameraTransform: .identity,
                    image: PixelBufferImage(pixelBuffer: cropped)))
                let tileSeconds = seconds(since: start)
                let mapped = FarTileMerge.frameDetections(fromTile: raw, crop: crop)
                tileResults.append(SweepTileResult(
                    tile: tile.name, tileSeconds: tileSeconds,
                    tileOnly: mapped.map(SweepBox.init),
                    merged: FarTileMerge.merge(full: full, tile: mapped).map(SweepBox.init)))
            }
            let row = SweepRow(image: name, setting: setting.name, fullSeconds: fullSeconds,
                               full: full.map(SweepBox.init), tiles: tileResults)
            try handle.write(contentsOf: encoder.encode(row))
            try handle.write(contentsOf: Data("\n".utf8))
        }
        FileHandle.standardError.write(Data("swept \(name)\n".utf8))
    }
}
