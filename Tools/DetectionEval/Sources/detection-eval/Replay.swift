//
//  Replay.swift
//  detection-eval
//
//  Whole-pipeline replay of a device recording, with the real model:
//
//    detection-eval --replay <bundle-dir> --frames-dir <png-dir> --model <BallDetector.mlpackage>
//        --truth <truth.json> [--tile off|on|auto] [--period N] [--floor 0.35] [--out <report.json>]
//
//  Every frame of `frames.jsonl` (pose, intrinsics, timestamp) is paired with
//  its decoded picture (`<png-dir>/f001.png` is frame 0: extract with
//  `ffmpeg -i video.mp4 f%03d.png`) and pushed, in order, through the real
//  PerceptionPipeline: model, far-tile wrapper, projection, playing-surface
//  gate, tracker. The truth file lists the balls by image position (the
//  layout is hand-measured and stays local, like the recording):
//
//    {"balls": {"name": [cx, cy], ...}}     normalized, top-left origin
//
//  Each is projected onto the recorded table once (the camera is parked) and
//  scored: does a CONFIRMED track sit on it, and does it keep one id?
//

import CoreGraphics
import CoreML
import CoreVideo
import CueSyncCore
import Foundation
import PerceptionKit
import TableSpace

struct ReplayArguments {
    var bundle = ""
    var framesDirectory = ""
    var modelPath = ""
    var truthPath = ""
    var outPath: String?
    var tile: FarTileMode = .off
    var period = 1
    var floor = 0.35

    static func parse(_ arguments: [String]) throws -> ReplayArguments {
        var result = ReplayArguments()
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            guard flag.hasPrefix("--"), index + 1 < arguments.count else {
                throw EvalError.usage("unexpected argument '\(flag)'")
            }
            let value = arguments[index + 1]
            switch flag {
            case "--replay": result.bundle = value
            case "--frames-dir": result.framesDirectory = value
            case "--model": result.modelPath = value
            case "--truth": result.truthPath = value
            case "--out": result.outPath = value
            case "--tile":
                guard let mode = FarTileMode(rawValue: value == "auto" ? "automatic" : value) else {
                    throw EvalError.usage("--tile must be off|on|auto")
                }
                result.tile = mode
            case "--period": result.period = max(1, Int(value) ?? 1)
            case "--floor": result.floor = Double(value) ?? 0.35
            default: throw EvalError.usage("unknown flag '\(flag)'")
            }
            index += 2
        }
        guard !result.bundle.isEmpty, !result.framesDirectory.isEmpty,
              !result.modelPath.isEmpty, !result.truthPath.isEmpty else {
            throw EvalError.usage("--replay, --frames-dir, --model and --truth are required")
        }
        return result
    }
}

private func jsonObject(at path: String) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(
        with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any] else {
        throw EvalError.imageLoad(path)
    }
    return object
}

private func loadCalibration(_ directory: String) throws -> TableCalibration {
    let json = try jsonObject(at: directory + "/calibration.json")
    guard let origin = json["origin"] as? [Double], let xAxis = json["xAxis"] as? [Double],
          let yAxis = json["yAxis"] as? [Double], origin.count == 3, xAxis.count == 3, yAxis.count == 3,
          let name = (json["size"] as? [String: Any])?["name"] as? String else {
        throw EvalError.imageLoad(directory + "/calibration.json")
    }
    let size: TableSize
    switch name {
    case "sevenFoot": size = .sevenFoot
    case "eightFoot": size = .eightFoot
    case "nineFoot": size = .nineFoot
    default: throw EvalError.imageLoad("table size \(name)")
    }
    return TableCalibration(origin: Vec3(origin[0], origin[1], origin[2]),
                            xAxis: Vec3(xAxis[0], xAxis[1], xAxis[2]),
                            yAxis: Vec3(yAxis[0], yAxis[1], yAxis[2]), size: size)
}

/// Pose and intrinsics of every recorded frame; the picture is added later.
private func loadFrameMeta(_ directory: String) throws -> [CapturedFrame] {
    let text = try String(contentsOfFile: directory + "/frames.jsonl", encoding: .utf8)
    return try text.split(separator: "\n").map { line in
        guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let m = object["cameraTransform"] as? [Double], m.count == 16,
              let k = object["intrinsics"] as? [String: Double],
              let timestamp = object["timestamp"] as? Double else {
            throw EvalError.imageLoad(directory + "/frames.jsonl")
        }
        let columns = (0..<4).map { SIMD4(m[$0 * 4], m[$0 * 4 + 1], m[$0 * 4 + 2], m[$0 * 4 + 3]) }
        return CapturedFrame(
            timestamp: timestamp, cameraTransform: Transform3D(columns: columns),
            intrinsics: CameraIntrinsics(focalX: k["focalX"] ?? 0, focalY: k["focalY"] ?? 0,
                                         principalX: k["principalX"] ?? 0, principalY: k["principalY"] ?? 0,
                                         imageWidth: k["imageWidth"] ?? 0, imageHeight: k["imageHeight"] ?? 0))
    }
}

private struct BallScore: Codable {
    var name: String
    var tablePosition: [Double]
    var firstConfirmedFrame: Int?
    var confirmedFrames: Int
    var ids: [Int]
    /// Confirmed on every frame from the first confirmation to the end.
    var heldToTheEnd: Bool
    var longestGap: Int
}

private struct ReplayReport: Codable {
    var tile: String
    var period: Int
    var frames: Int
    var tracksMinted: Int
    var balls: [BallScore]
    var heldToTheEnd: Int
    var confirmedAtTheEnd: Int
    var singleIdBalls: Int
    var confirmedPerFrame: [Int]
}

func runReplay(_ arguments: ReplayArguments) async throws {
    let calibration = try loadCalibration(arguments.bundle)
    var frames = try loadFrameMeta(arguments.bundle)
    let truth = ((try jsonObject(at: arguments.truthPath))["balls"] as? [String: [Double]]) ?? [:]
    guard !truth.isEmpty else { throw EvalError.usage("truth.json has no balls") }

    let compiled = try await MLModel.compileModel(at: URL(fileURLWithPath: arguments.modelPath))
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuOnly
    let provider = try CoreMLDetectionProvider(model: try MLModel(contentsOf: compiled,
                                                                  configuration: configuration))
    let detector = FarTileDetector(inner: provider, period: arguments.period, mode: arguments.tile,
                                   tableSource: { calibration },
                                   cropper: FarTileDetector.pixelBufferCropper)
    let raycaster = PlaneGeometryRaycaster(calibration: calibration)
    var perception = PerceptionConfig.default
    perception.confidenceFloor = arguments.floor
    let pipeline = PerceptionPipeline(detector: detector, calibration: calibration, raycaster: raycaster,
                                      config: perception)

    // Truth balls on the table, from the first frame's pose (parked camera).
    var truthTable: [(name: String, position: Vec2)] = []
    for (name, point) in truth.sorted(by: { $0.key < $1.key }) {
        guard point.count == 2,
              let world = raycaster.raycastToTablePlane(imagePoint: Vec2(point[0], point[1]), frame: frames[0],
                                                        planeHeightOffset: Ball.standardRadius) else { continue }
        truthTable.append((name, calibration.worldToTable(world)))
    }

    var confirmed = [[Int?]](repeating: [], count: truthTable.count)
    var minted = 0
    var perFrame: [Int] = []
    for index in frames.indices {
        let path = String(format: "%@/f%03d.png", arguments.framesDirectory, index + 1)
        let buffer = try pixelBuffer(from: try loadCGImage(at: path))
        frames[index].image = PixelBufferImage(pixelBuffer: buffer)
        guard let output = await pipeline.processFrame(frames[index]) else {
            for ball in confirmed.indices { confirmed[ball].append(nil) }
            perFrame.append(0)
            continue
        }
        minted = output.diagnostics.nextTrackID
        perFrame.append(output.state.balls.count)
        for (ball, entry) in truthTable.enumerated() {
            let near = output.state.balls.filter { $0.position.distance(to: entry.position) < 0.05 }
                .min { $0.position.distance(to: entry.position) < $1.position.distance(to: entry.position) }
            confirmed[ball].append(near?.id.rawValue)
        }
        if index % 20 == 0 { FileHandle.standardError.write(Data("replayed frame \(index)\n".utf8)) }
    }

    var scores: [BallScore] = []
    for (ball, entry) in truthTable.enumerated() {
        let series = confirmed[ball]
        let first = series.firstIndex { $0 != nil }
        var longestGap = 0, gap = 0
        if let first {
            for value in series[first...] {
                gap = value == nil ? gap + 1 : 0
                longestGap = max(longestGap, gap)
            }
        }
        scores.append(BallScore(
            name: entry.name, tablePosition: [entry.position.x, entry.position.y],
            firstConfirmedFrame: first, confirmedFrames: series.compactMap { $0 }.count,
            ids: Array(Set(series.compactMap { $0 })).sorted(),
            heldToTheEnd: first != nil && series[first!...].allSatisfy { $0 != nil },
            longestGap: longestGap))
    }
    let report = ReplayReport(
        tile: arguments.tile.rawValue, period: arguments.period, frames: frames.count,
        tracksMinted: minted, balls: scores,
        heldToTheEnd: scores.filter(\.heldToTheEnd).count,
        confirmedAtTheEnd: scores.filter { confirmed[scores.firstIndex(of: $0)!].last! != nil }.count,
        singleIdBalls: scores.filter { $0.ids.count == 1 }.count,
        confirmedPerFrame: perFrame)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    if let out = arguments.outPath { try data.write(to: URL(fileURLWithPath: out)) }
    print(String(decoding: data, as: UTF8.self))
}

extension BallScore: Equatable {
    static func == (lhs: BallScore, rhs: BallScore) -> Bool { lhs.name == rhs.name }
}
